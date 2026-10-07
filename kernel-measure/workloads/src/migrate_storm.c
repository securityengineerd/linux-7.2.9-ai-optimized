// migrate_storm: affinity storm with cache-hot workers, for kernel-measure Task 2.
//
// W worker threads (default nproc + nproc/2, so the load balancer has work)
// each pointer-chase a private buffer of BUF_KB (default 256 KiB, sized so two
// SMT siblings roughly fit one core's L2 on the test box). Work done is the
// number of dependent loads completed.
//
// Three phases of equal length:
//   free:   no affinity changes; only the kernel balancer/placement moves tasks
//   storm:  every STORM_MS the controller alternates between pinning each worker
//           to a rotating single CPU ((i + rot) % ncpu) and restoring the full mask
//   settle: full mask restored; measures how placement recovers after the storm
//
// Per phase it reports loads/sec, observed CPU changes (sched_getcpu sampled
// every chunk), and the sum of se.nr_migrations from /proc/self/task/TID/sched
// when that file exposes it.
//
// It also reports NUMA node count and the number of distinct L3 domains. On a
// single-node, single-LLC box the NUMA and cross-LLC parts of Task 2 cannot be
// demonstrated; only migration rate and L1/L2 refill cost are visible.
#define _GNU_SOURCE
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

#define NPH 3
#define CHUNK 4096

struct worker {
	_Atomic uint64_t loads[NPH];
	_Atomic uint64_t cpu_changes[NPH];
	_Atomic pid_t tid;
	uint32_t *buf;
	size_t lines;
	pthread_t th;
	int idx;
} __attribute__((aligned(64)));

static _Atomic int phase;
static _Atomic int stop_flag;
static volatile uint64_t sink;

static uint64_t now_ns(void)
{
	struct timespec ts;
	clock_gettime(CLOCK_MONOTONIC, &ts);
	return (uint64_t)ts.tv_sec * 1000000000ULL + ts.tv_nsec;
}

static uint64_t xs(uint64_t *s)
{
	uint64_t x = *s;
	x ^= x << 13;
	x ^= x >> 7;
	x ^= x << 17;
	return *s = x;
}

static void *worker_main(void *arg)
{
	struct worker *w = arg;
	const size_t stride = 64 / sizeof(uint32_t);
	size_t i;
	uint64_t seed = 0x9e3779b97f4a7c15ULL ^ (uint64_t)(w->idx + 1);
	atomic_store(&w->tid, (pid_t)syscall(SYS_gettid));
	/* random cyclic permutation over cache lines (Sattolo) */
	uint32_t *perm = malloc(w->lines * sizeof(uint32_t));
	if (!perm)
		return NULL;
	for (i = 0; i < w->lines; i++)
		perm[i] = (uint32_t)i;
	for (i = w->lines - 1; i > 0; i--) {
		size_t j = xs(&seed) % i;
		uint32_t t = perm[i];
		perm[i] = perm[j];
		perm[j] = t;
	}
	for (i = 0; i < w->lines; i++)
		w->buf[perm[i] * stride] = perm[(i + 1) % w->lines];
	free(perm);
	uint32_t p = 0;
	int prev = sched_getcpu();
	while (!atomic_load_explicit(&stop_flag, memory_order_relaxed)) {
		for (i = 0; i < CHUNK; i++)
			p = w->buf[p * stride];
		int ph = atomic_load_explicit(&phase, memory_order_relaxed);
		atomic_fetch_add_explicit(&w->loads[ph], CHUNK, memory_order_relaxed);
		int cpu = sched_getcpu();
		if (cpu != prev) {
			atomic_fetch_add_explicit(&w->cpu_changes[ph], 1, memory_order_relaxed);
			prev = cpu;
		}
	}
	sink += p;
	return NULL;
}

static long read_nr_migrations(pid_t tid)
{
	char path[64], line[256];
	long v = -1;
	snprintf(path, sizeof(path), "/proc/self/task/%d/sched", (int)tid);
	FILE *f = fopen(path, "r");
	if (!f)
		return -1;
	while (fgets(line, sizeof(line), f)) {
		if (strncmp(line, "se.nr_migrations", 16) == 0) {
			char *c = strchr(line, ':');
			if (c)
				v = strtol(c + 1, NULL, 10);
			break;
		}
	}
	fclose(f);
	return v;
}

static long sum_migr(struct worker *ws, int n)
{
	long s = 0;
	for (int i = 0; i < n; i++) {
		long v = read_nr_migrations(atomic_load(&ws[i].tid));
		if (v < 0)
			return -1;
		s += v;
	}
	return s;
}

static int count_nodes(void)
{
	int n = 0;
	char path[64];
	for (int i = 0; i < 1024; i++) {
		snprintf(path, sizeof(path), "/sys/devices/system/node/node%d", i);
		if (access(path, F_OK) == 0)
			n++;
	}
	return n ? n : 1;
}

static int count_llc(long ncpu)
{
	char seen[64][128];
	int n = 0;
	for (long c = 0; c < ncpu; c++) {
		char path[128], buf[128];
		snprintf(path, sizeof(path), "/sys/devices/system/cpu/cpu%ld/cache/index3/shared_cpu_list", c);
		FILE *f = fopen(path, "r");
		if (!f)
			continue;
		if (!fgets(buf, sizeof(buf), f)) {
			fclose(f);
			continue;
		}
		fclose(f);
		int dup = 0;
		for (int k = 0; k < n; k++)
			if (strcmp(seen[k], buf) == 0)
				dup = 1;
		if (!dup && n < 64)
			strcpy(seen[n++], buf);
	}
	return n;
}

static void sleep_until(uint64_t t)
{
	struct timespec ts = { (time_t)(t / 1000000000ULL), (long)(t % 1000000000ULL) };
	clock_nanosleep(CLOCK_MONOTONIC, TIMER_ABSTIME, &ts, NULL);
}

int main(int argc, char **argv)
{
	int dur = 15, nw = 0, buf_kb = 256, storm_ms = 10, opt, i;
	const char *out = NULL;
	long ncpu = sysconf(_SC_NPROCESSORS_ONLN);
	if (ncpu < 1)
		ncpu = 1;
	while ((opt = getopt(argc, argv, "d:w:k:t:o:")) != -1) {
		switch (opt) {
		case 'd': dur = atoi(optarg); break;
		case 'w': nw = atoi(optarg); break;
		case 'k': buf_kb = atoi(optarg); break;
		case 't': storm_ms = atoi(optarg); break;
		case 'o': out = optarg; break;
		default:
			fprintf(stderr, "usage: migrate_storm -d SEC [-w WORKERS] [-k BUF_KB] [-t STORM_MS] [-o FILE]\n");
			return 2;
		}
	}
	if (dur < 3 || buf_kb < 4 || storm_ms < 1)
		return 2;
	if (nw <= 0)
		nw = (int)(ncpu + ncpu / 2);
	struct worker *ws = aligned_alloc(64, sizeof(*ws) * (size_t)nw);
	if (!ws)
		return 1;
	memset(ws, 0, sizeof(*ws) * (size_t)nw);
	for (i = 0; i < nw; i++) {
		ws[i].idx = i;
		ws[i].lines = (size_t)buf_kb * 1024 / 64;
		ws[i].buf = aligned_alloc(64, (size_t)buf_kb * 1024);
		if (!ws[i].buf)
			return 1;
		memset(ws[i].buf, 0, (size_t)buf_kb * 1024);
	}
	for (i = 0; i < nw; i++)
		pthread_create(&ws[i].th, NULL, worker_main, &ws[i]);
	for (i = 0; i < nw; i++)
		while (atomic_load(&ws[i].tid) == 0)
			usleep(1000);
	usleep(200000); /* let permutation setup finish before phase 0 counts */
	for (i = 0; i < nw; i++)
		for (int ph = 0; ph < NPH; ph++) {
			atomic_store(&ws[i].loads[ph], 0);
			atomic_store(&ws[i].cpu_changes[ph], 0);
		}

	uint64_t phase_ns = (uint64_t)dur * 1000000000ULL / NPH;
	uint64_t t0 = now_ns();
	long migr[NPH + 1];
	uint64_t pt[NPH + 1];
	uint64_t storm_steps = 0;
	cpu_set_t full;
	CPU_ZERO(&full);
	for (long c = 0; c < ncpu; c++)
		CPU_SET((int)c, &full);

	migr[0] = sum_migr(ws, nw);
	pt[0] = t0;
	/* phase 0: free */
	sleep_until(t0 + phase_ns);
	migr[1] = sum_migr(ws, nw);
	pt[1] = now_ns();
	atomic_store(&phase, 1);
	/* phase 1: storm */
	{
		uint64_t end = t0 + 2 * phase_ns, next = now_ns();
		int rot = 0, pinned = 0;
		while (now_ns() < end) {
			for (i = 0; i < nw; i++) {
				if (!pinned) {
					cpu_set_t one;
					CPU_ZERO(&one);
					CPU_SET((int)((i + rot) % ncpu), &one);
					pthread_setaffinity_np(ws[i].th, sizeof(one), &one);
				} else {
					pthread_setaffinity_np(ws[i].th, sizeof(full), &full);
				}
			}
			if (pinned)
				rot++;
			pinned = !pinned;
			storm_steps++;
			next += (uint64_t)storm_ms * 1000000ULL;
			if (next > end)
				next = end;
			sleep_until(next);
		}
		for (i = 0; i < nw; i++)
			pthread_setaffinity_np(ws[i].th, sizeof(full), &full);
	}
	migr[2] = sum_migr(ws, nw);
	pt[2] = now_ns();
	atomic_store(&phase, 2);
	/* phase 2: settle */
	sleep_until(t0 + 3 * phase_ns);
	migr[3] = sum_migr(ws, nw);
	pt[3] = now_ns();
	atomic_store(&stop_flag, 1);
	for (i = 0; i < nw; i++)
		pthread_join(ws[i].th, NULL);

	const char *pn[NPH] = { "free", "storm", "settle" };
	int nodes = count_nodes(), llcs = count_llc(ncpu);
	FILE *f = out ? fopen(out, "w") : NULL;
	for (int pass = 0; pass < 2; pass++) {
		FILE *o = pass == 0 ? stdout : f;
		if (!o)
			continue;
		fprintf(o, "wl_engine=migrate_storm_c\n");
		fprintf(o, "wl_args=d=%d w=%d buf_kb=%d storm_ms=%d ncpu=%ld\n", dur, nw, buf_kb, storm_ms, ncpu);
		fprintf(o, "wl_numa_nodes=%d\n", nodes);
		fprintf(o, "wl_llc_domains=%d\n", llcs);
		fprintf(o, "wl_storm_affinity_steps=%llu\n", (unsigned long long)storm_steps);
		for (int ph = 0; ph < NPH; ph++) {
			uint64_t loads = 0, ch = 0;
			for (i = 0; i < nw; i++) {
				loads += atomic_load(&ws[i].loads[ph]);
				ch += atomic_load(&ws[i].cpu_changes[ph]);
			}
			uint64_t ns = pt[ph + 1] - pt[ph];
			double sec = (double)ns / 1e9;
			fprintf(o, "wl_%s_loads=%llu\n", pn[ph], (unsigned long long)loads);
			fprintf(o, "wl_%s_mloads_per_sec=%.0f\n", pn[ph], sec > 0 ? (double)loads / sec / 1e6 : 0.0);
			fprintf(o, "wl_%s_cpu_changes=%llu\n", pn[ph], (unsigned long long)ch);
			if (migr[ph] >= 0 && migr[ph + 1] >= 0)
				fprintf(o, "wl_%s_nr_migrations=%ld\n", pn[ph], migr[ph + 1] - migr[ph]);
			else
				fprintf(o, "wl_%s_nr_migrations=n/a\n", pn[ph]);
		}
		if (nodes <= 1)
			fprintf(o, "wl_numa_note=single NUMA node: Task 2 NUMA/preferred-node behavior cannot be shown on this box\n");
		if (llcs <= 1)
			fprintf(o, "wl_llc_note=single L3 domain: cross-LLC preference cannot be shown; only migration rate and L1/L2 refill cost are visible\n");
	}
	if (f)
		fclose(f);
	return 0;
}
