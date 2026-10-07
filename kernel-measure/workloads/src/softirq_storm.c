/*
 * softirq_storm — Task 12: generate TIMER / NET_RX / RCU softirq work and
 * sample wake-to-run latency under that load so irq-exit softirq cost is
 * visible in /proc/softirqs and wl_* metrics.
 *
 * Phases (each ~duration/3):
 *   timer   — many timerfd expirations (TIMER softirq)
 *   net     — UDP loopback flood (NET_TX / NET_RX softirq)
 *   mixed   — both + rapid mmap/munmap to queue RCU callbacks
 *
 * A latency sampler thread (nanosleep wake) runs the whole time.
 * Softirq / ksoftirqd / RCU accounting is done by the wrapper script from
 * /proc before and after; this binary only reports latency + work counts.
 */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <inttypes.h>
#include <netinet/in.h>
#include <pthread.h>
#include <sched.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/socket.h>
#include <sys/timerfd.h>
#include <time.h>
#include <unistd.h>

static volatile int g_stop;
static volatile int g_phase; /* 0=timer 1=net 2=mixed */

struct lat {
	uint64_t n;
	uint64_t sum_ns;
	uint64_t max_ns;
	uint64_t hist[64]; /* log2 buckets */
};

static uint64_t now_ns(void)
{
	struct timespec ts;
	clock_gettime(CLOCK_MONOTONIC, &ts);
	return (uint64_t)ts.tv_sec * 1000000000ull + (uint64_t)ts.tv_nsec;
}

static void lat_add(struct lat *L, uint64_t d)
{
	unsigned b = 0;
	uint64_t x = d;
	L->n++;
	L->sum_ns += d;
	if (d > L->max_ns)
		L->max_ns = d;
	while (x > 1 && b < 63) {
		x >>= 1;
		b++;
	}
	L->hist[b]++;
}

static uint64_t lat_pct(const struct lat *L, double p)
{
	uint64_t want, acc = 0;
	unsigned b;
	if (!L->n)
		return 0;
	want = (uint64_t)(p * (double)L->n);
	if (want < 1)
		want = 1;
	if (want > L->n)
		want = L->n;
	for (b = 0; b < 64; b++) {
		acc += L->hist[b];
		if (acc >= want)
			return 1ull << b;
	}
	return L->max_ns;
}

static void *latency_thread(void *arg)
{
	struct lat *L = arg;
	struct timespec req = { .tv_sec = 0, .tv_nsec = 1000 * 1000 }; /* 1 ms */
	while (!g_stop) {
		uint64_t t0 = now_ns();
		nanosleep(&req, NULL);
		lat_add(L, now_ns() - t0);
	}
	return NULL;
}

static void *timer_worker(void *arg)
{
	long id = (long)arg;
	int tfd = timerfd_create(CLOCK_MONOTONIC, 0);
	struct itimerspec its;
	uint64_t exp, n = 0;
	(void)id;
	if (tfd < 0)
		return NULL;
	its.it_value.tv_sec = 0;
	its.it_value.tv_nsec = 100 * 1000; /* 100 us */
	its.it_interval = its.it_value;
	if (timerfd_settime(tfd, 0, &its, NULL)) {
		close(tfd);
		return NULL;
	}
	while (!g_stop) {
		if (g_phase == 1) {
			/* net-only phase: idle briefly */
			usleep(500);
			continue;
		}
		if (read(tfd, &exp, sizeof(exp)) != (ssize_t)sizeof(exp))
			break;
		n += exp;
	}
	close(tfd);
	fprintf(stderr, "timer_worker done expirations=%" PRIu64 "\n", n);
	return (void *)(uintptr_t)n;
}

static void *net_worker(void *arg)
{
	long id = (long)arg;
	int s, c;
	struct sockaddr_in addr;
	char buf[1400];
	uint64_t sent = 0, recvd = 0;
	memset(buf, 'N', sizeof(buf));
	s = socket(AF_INET, SOCK_DGRAM, 0);
	c = socket(AF_INET, SOCK_DGRAM, 0);
	if (s < 0 || c < 0)
		return NULL;
	memset(&addr, 0, sizeof(addr));
	addr.sin_family = AF_INET;
	addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
	addr.sin_port = htons(19000 + (int)(id % 64));
	if (bind(s, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
		/* port busy: bind ephemeral and connect peer to self via getsockname */
		addr.sin_port = 0;
		if (bind(s, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
			close(s);
			close(c);
			return NULL;
		}
	}
	{
		socklen_t alen = sizeof(addr);
		getsockname(s, (struct sockaddr *)&addr, &alen);
	}
	connect(c, (struct sockaddr *)&addr, sizeof(addr));
	/* nonblock recv */
	{
		int fl = fcntl(s, F_GETFL, 0);
		fcntl(s, F_SETFL, fl | O_NONBLOCK);
	}
	while (!g_stop) {
		if (g_phase == 0) {
			usleep(500);
			continue;
		}
		if (send(c, buf, sizeof(buf), 0) > 0)
			sent++;
		for (;;) {
			ssize_t r = recv(s, buf, sizeof(buf), 0);
			if (r <= 0)
				break;
			recvd++;
		}
	}
	close(s);
	close(c);
	fprintf(stderr, "net_worker%ld sent=%" PRIu64 " recvd=%" PRIu64 "\n",
		id, sent, recvd);
	return (void *)(uintptr_t)(sent + recvd);
}

static void *rcu_worker(void *arg)
{
	uint64_t n = 0;
	(void)arg;
	while (!g_stop) {
		if (g_phase != 2) {
			usleep(1000);
			continue;
		}
		/* map/unmap forces RCU for page tables / vma in many paths */
		void *p = mmap(NULL, 4096, PROT_READ | PROT_WRITE,
			       MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
		if (p != MAP_FAILED) {
			*(volatile char *)p = 1;
			munmap(p, 4096);
			n++;
		}
	}
	fprintf(stderr, "rcu_worker maps=%" PRIu64 "\n", n);
	return (void *)(uintptr_t)n;
}

static void usage(const char *argv0)
{
	fprintf(stderr,
		"usage: %s [-d sec] [-t timer_threads] [-n net_threads] [-r rcu_threads]\n",
		argv0);
}

int main(int argc, char **argv)
{
	int duration = 15;
	int ntimer = 4;
	int nnet = 4;
	int nrcu = 2;
	int i, opt;
	pthread_t lat_th, *ths;
	struct lat L = { 0 };
	uint64_t t0, t1;
	int nthreads;

	while ((opt = getopt(argc, argv, "d:t:n:r:h")) != -1) {
		switch (opt) {
		case 'd':
			duration = atoi(optarg);
			break;
		case 't':
			ntimer = atoi(optarg);
			break;
		case 'n':
			nnet = atoi(optarg);
			break;
		case 'r':
			nrcu = atoi(optarg);
			break;
		default:
			usage(argv[0]);
			return 2;
		}
	}
	if (duration < 3)
		duration = 3;
	if (ntimer < 1)
		ntimer = 1;
	if (nnet < 1)
		nnet = 1;
	if (nrcu < 0)
		nrcu = 0;

	nthreads = ntimer + nnet + nrcu;
	ths = calloc((size_t)nthreads, sizeof(*ths));
	if (!ths)
		return 1;

	g_stop = 0;
	g_phase = 0;
	pthread_create(&lat_th, NULL, latency_thread, &L);
	for (i = 0; i < ntimer; i++)
		pthread_create(&ths[i], NULL, timer_worker, (void *)(long)i);
	for (i = 0; i < nnet; i++)
		pthread_create(&ths[ntimer + i], NULL, net_worker, (void *)(long)i);
	for (i = 0; i < nrcu; i++)
		pthread_create(&ths[ntimer + nnet + i], NULL, rcu_worker,
			       (void *)(long)i);

	t0 = now_ns();
	/* phase 0: timer */
	g_phase = 0;
	usleep((useconds_t)(duration / 3) * 1000000u);
	/* phase 1: net */
	g_phase = 1;
	usleep((useconds_t)(duration / 3) * 1000000u);
	/* phase 2: mixed */
	g_phase = 2;
	usleep((useconds_t)(duration - 2 * (duration / 3)) * 1000000u);
	g_stop = 1;
	t1 = now_ns();

	pthread_join(lat_th, NULL);
	for (i = 0; i < nthreads; i++)
		pthread_join(ths[i], NULL);
	free(ths);

	printf("wl_softirq_storm_duration_sec=%.3f\n",
	       (double)(t1 - t0) / 1e9);
	printf("wl_wake_lat_n=%" PRIu64 "\n", L.n);
	printf("wl_wake_lat_p50_ns=%" PRIu64 "\n", lat_pct(&L, 0.50));
	printf("wl_wake_lat_p90_ns=%" PRIu64 "\n", lat_pct(&L, 0.90));
	printf("wl_wake_lat_p99_ns=%" PRIu64 "\n", lat_pct(&L, 0.99));
	printf("wl_wake_lat_max_ns=%" PRIu64 "\n", L.max_ns);
	printf("wl_wake_lat_avg_ns=%" PRIu64 "\n",
	       L.n ? L.sum_ns / L.n : 0);
	printf("wl_ntimer=%d\n", ntimer);
	printf("wl_nnet=%d\n", nnet);
	printf("wl_nrcu=%d\n", nrcu);
	return 0;
}
