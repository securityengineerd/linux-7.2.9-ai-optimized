// wake_storm: short-lived wake storm for kernel-measure Task 1 (LLC idle search).
//
// M messenger threads each own W worker threads. Every period a messenger
// stamps a wake time for each of its workers and futex-wakes them in a burst.
// Each worker records wake-to-run latency (CLOCK_MONOTONIC, waker stamp to
// first instruction after futex_wait returns), the CPU it landed on, spins
// BUSY_US, and goes back to sleep. With nproc workers per messenger the burst
// lands on every CPU in the LLC, so select_idle_sibling/select_idle_cpu runs
// on nearly every wake.
//
// Two phases of equal length:
//   phase "idle": only the wake storm runs (mostly idle LLC).
//   phase "busy": S spinner threads also run, so part of the LLC is busy and
//                 the idle search has to skip busy CPUs.
//
// Output (key=value, one per line) goes to -o FILE and stdout.
// Not a benchmark score; numbers are only comparable on the same box,
// same binary, same arguments.
#define _GNU_SOURCE
#include <errno.h>
#include <linux/futex.h>
#include <pthread.h>
#include <sched.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/syscall.h>
#include <time.h>
#include <unistd.h>

#define T1_STEP 250ULL          /* ns */
#define T1_MAX 2000000ULL       /* 2 ms */
#define T1_N (T1_MAX / T1_STEP)
#define T2_STEP 100000ULL       /* 100 us */
#define T2_MAX 1000000000ULL    /* 1 s */
#define T2_N ((T2_MAX - T1_MAX) / T2_STEP)
#define HN (T1_N + T2_N + 1)

struct hist {
	uint32_t b[HN];
	uint64_t n, sum, max;
	uint64_t cpu_changed, on_waker_cpu;
};

struct worker {
	_Atomic uint32_t seq;
	_Atomic uint64_t wake_ts;
	_Atomic int waker_cpu;
	int prev_cpu;
	struct messenger *m;
	struct hist h[2];
	pthread_t tid;
} __attribute__((aligned(64)));

struct messenger {
	_Atomic uint32_t pending;
	struct worker *w;
	int nw;
	uint64_t rounds[2], missed[2];
	pthread_t tid;
} __attribute__((aligned(64)));

static _Atomic int stop_flag;
static _Atomic int phase;
static _Atomic uint32_t spin_gate;
static uint64_t period_ns = 1000000, busy_ns = 20000;
static uint64_t deadline_ns;

static uint64_t now_ns(void)
{
	struct timespec ts;
	clock_gettime(CLOCK_MONOTONIC, &ts);
	return (uint64_t)ts.tv_sec * 1000000000ULL + ts.tv_nsec;
}

static long futex(_Atomic uint32_t *a, int op, uint32_t v, const struct timespec *t)
{
	return syscall(SYS_futex, (uint32_t *)a, op, v, t, NULL, 0);
}

static void spin_for(uint64_t ns)
{
	uint64_t end = now_ns() + ns;
	while (now_ns() < end)
		__asm__ __volatile__("" ::: "memory");
}

static void hist_add(struct hist *h, uint64_t v)
{
	size_t i;
	if (v < T1_MAX)
		i = v / T1_STEP;
	else if (v < T2_MAX)
		i = T1_N + (v - T1_MAX) / T2_STEP;
	else
		i = HN - 1;
	h->b[i]++;
	h->n++;
	h->sum += v;
	if (v > h->max)
		h->max = v;
}

static uint64_t bucket_upper(size_t i)
{
	if (i < T1_N)
		return (i + 1) * T1_STEP;
	if (i < T1_N + T2_N)
		return T1_MAX + (i - T1_N + 1) * T2_STEP;
	return T2_MAX;
}

static uint64_t hist_pct(const struct hist *h, double p)
{
	uint64_t want, acc = 0;
	size_t i;
	if (h->n == 0)
		return 0;
	want = (uint64_t)(p * (double)h->n);
	if (want >= h->n)
		want = h->n - 1;
	for (i = 0; i < HN; i++) {
		acc += h->b[i];
		if (acc > want)
			return bucket_upper(i) < h->max ? bucket_upper(i) : h->max;
	}
	return h->max;
}

static void *worker_main(void *arg)
{
	struct worker *w = arg;
	uint32_t seen = atomic_load(&w->seq);
	w->prev_cpu = -1;
	for (;;) {
		uint32_t cur;
		while ((cur = atomic_load(&w->seq)) == seen)
			futex(&w->seq, FUTEX_WAIT_PRIVATE, seen, NULL);
		uint64_t t = now_ns();
		seen = cur;
		if (atomic_load(&stop_flag))
			break;
		int ph = atomic_load(&phase);
		int cpu = sched_getcpu();
		struct hist *h = &w->h[ph];
		uint64_t ts = atomic_load(&w->wake_ts);
		hist_add(h, t > ts ? t - ts : 0);
		if (w->prev_cpu >= 0 && cpu != w->prev_cpu)
			h->cpu_changed++;
		if (cpu == atomic_load(&w->waker_cpu))
			h->on_waker_cpu++;
		w->prev_cpu = cpu;
		spin_for(busy_ns);
		if (atomic_fetch_sub(&w->m->pending, 1) == 1)
			futex(&w->m->pending, FUTEX_WAKE_PRIVATE, 1, NULL);
	}
	return NULL;
}

static void *messenger_main(void *arg)
{
	struct messenger *m = arg;
	struct timespec next;
	clock_gettime(CLOCK_MONOTONIC, &next);
	while (now_ns() < deadline_ns) {
		int ph = atomic_load(&phase);
		int cpu = sched_getcpu();
		int i;
		atomic_store(&m->pending, (uint32_t)m->nw);
		for (i = 0; i < m->nw; i++) {
			struct worker *w = &m->w[i];
			atomic_store(&w->waker_cpu, cpu);
			atomic_store(&w->wake_ts, now_ns());
			atomic_fetch_add(&w->seq, 1);
			futex(&w->seq, FUTEX_WAKE_PRIVATE, 1, NULL);
		}
		uint32_t p;
		struct timespec to = { 0, 100000000 };
		while ((p = atomic_load(&m->pending)) != 0) {
			if (now_ns() > deadline_ns + 2000000000ULL)
				break;
			futex(&m->pending, FUTEX_WAIT_PRIVATE, p, &to);
		}
		m->rounds[ph]++;
		next.tv_nsec += period_ns;
		while (next.tv_nsec >= 1000000000L) {
			next.tv_nsec -= 1000000000L;
			next.tv_sec++;
		}
		struct timespec n2;
		clock_gettime(CLOCK_MONOTONIC, &n2);
		if (n2.tv_sec > next.tv_sec || (n2.tv_sec == next.tv_sec && n2.tv_nsec > next.tv_nsec)) {
			m->missed[ph]++;
			next = n2;
		} else {
			clock_nanosleep(CLOCK_MONOTONIC, TIMER_ABSTIME, &next, NULL);
		}
	}
	return NULL;
}

static void *spinner_main(void *arg)
{
	(void)arg;
	while (!atomic_load(&stop_flag)) {
		uint32_t g = atomic_load(&spin_gate);
		if (g == 0) {
			futex(&spin_gate, FUTEX_WAIT_PRIVATE, 0, NULL);
			continue;
		}
		spin_for(1000000);
	}
	return NULL;
}

static void usage(void)
{
	fprintf(stderr, "usage: wake_storm -d SEC [-m MESSENGERS] [-w WORKERS_PER_MSG] [-s SPINNERS] "
			"[-p PERIOD_US] [-b BUSY_US] [-o FILE]\n");
	exit(2);
}

int main(int argc, char **argv)
{
	int dur = 10, nm = 2, nw = 0, ns = -1, opt, i, j, ph;
	const char *out = NULL;
	long ncpu = sysconf(_SC_NPROCESSORS_ONLN);
	if (ncpu < 1)
		ncpu = 1;
	while ((opt = getopt(argc, argv, "d:m:w:s:p:b:o:")) != -1) {
		switch (opt) {
		case 'd': dur = atoi(optarg); break;
		case 'm': nm = atoi(optarg); break;
		case 'w': nw = atoi(optarg); break;
		case 's': ns = atoi(optarg); break;
		case 'p': period_ns = strtoull(optarg, NULL, 10) * 1000ULL; break;
		case 'b': busy_ns = strtoull(optarg, NULL, 10) * 1000ULL; break;
		case 'o': out = optarg; break;
		default: usage();
		}
	}
	if (dur < 2 || nm < 1)
		usage();
	if (nw <= 0)
		nw = (int)ncpu;
	if (ns < 0)
		ns = (int)(ncpu / 2);

	struct messenger *ms = calloc((size_t)nm, sizeof(*ms));
	pthread_t *sp = calloc((size_t)(ns > 0 ? ns : 1), sizeof(*sp));
	if (!ms || !sp)
		return 1;
	uint64_t start = now_ns();
	deadline_ns = start + (uint64_t)dur * 1000000000ULL;
	for (i = 0; i < nm; i++) {
		ms[i].nw = nw;
		ms[i].w = aligned_alloc(64, sizeof(struct worker) * (size_t)nw);
		if (!ms[i].w)
			return 1;
		memset(ms[i].w, 0, sizeof(struct worker) * (size_t)nw);
		for (j = 0; j < nw; j++) {
			ms[i].w[j].m = &ms[i];
			pthread_create(&ms[i].w[j].tid, NULL, worker_main, &ms[i].w[j]);
		}
	}
	for (i = 0; i < ns; i++)
		pthread_create(&sp[i], NULL, spinner_main, NULL);
	usleep(50000);
	start = now_ns();
	deadline_ns = start + (uint64_t)dur * 1000000000ULL;
	for (i = 0; i < nm; i++)
		pthread_create(&ms[i].tid, NULL, messenger_main, &ms[i]);

	/* phase 0 for the first half, phase 1 (spinners on) for the second half */
	struct timespec half = { dur / 2, (dur % 2) ? 500000000L : 0 };
	nanosleep(&half, NULL);
	if (ns > 0) {
		atomic_store(&spin_gate, 1);
		futex(&spin_gate, FUTEX_WAKE_PRIVATE, ns, NULL);
	}
	atomic_store(&phase, 1);
	for (i = 0; i < nm; i++)
		pthread_join(ms[i].tid, NULL);
	atomic_store(&stop_flag, 1);
	atomic_store(&spin_gate, 1);
	futex(&spin_gate, FUTEX_WAKE_PRIVATE, ns + 1, NULL);
	for (i = 0; i < nm; i++)
		for (j = 0; j < nw; j++) {
			atomic_fetch_add(&ms[i].w[j].seq, 1);
			futex(&ms[i].w[j].seq, FUTEX_WAKE_PRIVATE, 1, NULL);
		}
	for (i = 0; i < nm; i++)
		for (j = 0; j < nw; j++)
			pthread_join(ms[i].w[j].tid, NULL);
	for (i = 0; i < ns; i++)
		pthread_join(sp[i], NULL);

	FILE *f = out ? fopen(out, "w") : NULL;
	static struct hist tot[2];
	uint64_t rounds[2] = { 0, 0 }, missed[2] = { 0, 0 };
	for (ph = 0; ph < 2; ph++) {
		for (i = 0; i < nm; i++) {
			rounds[ph] += ms[i].rounds[ph];
			missed[ph] += ms[i].missed[ph];
			for (j = 0; j < nw; j++) {
				struct hist *h = &ms[i].w[j].h[ph];
				size_t k;
				for (k = 0; k < HN; k++)
					tot[ph].b[k] += h->b[k];
				tot[ph].n += h->n;
				tot[ph].sum += h->sum;
				if (h->max > tot[ph].max)
					tot[ph].max = h->max;
				tot[ph].cpu_changed += h->cpu_changed;
				tot[ph].on_waker_cpu += h->on_waker_cpu;
			}
		}
	}
	const char *pn[2] = { "idle", "busy" };
	for (int pass = 0; pass < 2; pass++) {
		FILE *o = pass == 0 ? stdout : f;
		if (!o)
			continue;
		fprintf(o, "wl_engine=wake_storm_c\n");
		fprintf(o, "wl_args=d=%d m=%d w=%d s=%d period_us=%llu busy_us=%llu ncpu=%ld\n", dur, nm, nw, ns,
			(unsigned long long)(period_ns / 1000), (unsigned long long)(busy_ns / 1000), ncpu);
		for (ph = 0; ph < 2; ph++) {
			struct hist *h = &tot[ph];
			fprintf(o, "wl_%s_wakes=%llu\n", pn[ph], (unsigned long long)h->n);
			fprintf(o, "wl_%s_rounds=%llu\n", pn[ph], (unsigned long long)rounds[ph]);
			fprintf(o, "wl_%s_missed_periods=%llu\n", pn[ph], (unsigned long long)missed[ph]);
			if (h->n == 0) {
				fprintf(o, "wl_%s_wake_lat_mean_ns=n/a\nwl_%s_wake_lat_p50_ns=n/a\nwl_%s_wake_lat_p90_ns=n/a\n"
					   "wl_%s_wake_lat_p99_ns=n/a\nwl_%s_wake_lat_p999_ns=n/a\nwl_%s_wake_lat_max_ns=n/a\n"
					   "wl_%s_cpu_changed_permille=n/a\nwl_%s_on_waker_cpu_permille=n/a\n",
					pn[ph], pn[ph], pn[ph], pn[ph], pn[ph], pn[ph], pn[ph], pn[ph]);
				continue;
			}
			fprintf(o, "wl_%s_wake_lat_mean_ns=%llu\n", pn[ph], (unsigned long long)(h->sum / h->n));
			fprintf(o, "wl_%s_wake_lat_p50_ns=%llu\n", pn[ph], (unsigned long long)hist_pct(h, 0.50));
			fprintf(o, "wl_%s_wake_lat_p90_ns=%llu\n", pn[ph], (unsigned long long)hist_pct(h, 0.90));
			fprintf(o, "wl_%s_wake_lat_p99_ns=%llu\n", pn[ph], (unsigned long long)hist_pct(h, 0.99));
			fprintf(o, "wl_%s_wake_lat_p999_ns=%llu\n", pn[ph], (unsigned long long)hist_pct(h, 0.999));
			fprintf(o, "wl_%s_wake_lat_max_ns=%llu\n", pn[ph], (unsigned long long)h->max);
			fprintf(o, "wl_%s_cpu_changed_permille=%llu\n", pn[ph],
				(unsigned long long)(h->cpu_changed * 1000 / h->n));
			fprintf(o, "wl_%s_on_waker_cpu_permille=%llu\n", pn[ph],
				(unsigned long long)(h->on_waker_cpu * 1000 / h->n));
		}
	}
	if (f)
		fclose(f);
	return 0;
}
