// util_est_burst: on/off CPU bursts to excite PELT lag vs util_est placement.
//
// B burst workers each: busy-spin ON_US, then sleep OFF_US, for DURATION seconds.
// After a long ON, util_est snaps high; during OFF, PELT util_avg decays while
// util_est EWMA decays slowly. On wake, task_util_est = max(util_avg, util_est)
// so placement underestimates less than pure PELT (when UTIL_EST is on).
//
// H optional always-on hogs create competing load so wake placement has a
// real choice of busy vs idle CPUs.
//
// Reports (key=value) to -o FILE and stdout. Compare only same binary/args.
#define _GNU_SOURCE
#include <errno.h>
#include <pthread.h>
#include <sched.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

struct burst_stats {
	uint64_t bursts;
	uint64_t busy_ns;
	uint64_t sleep_ns;
	uint64_t wake_lat_sum_ns;
	uint64_t wake_lat_max_ns;
	uint64_t wake_lat_p50; /* filled after hist merge; placeholder per-thread */
	uint64_t cpu_changes;
	uint64_t samples;
};

struct hist {
	uint32_t b[64]; /* log-ish buckets for wake lat */
	uint64_t n, sum, max;
};

struct worker {
	int id;
	int is_hog;
	pthread_t tid;
	struct burst_stats st;
	struct hist wake_h;
} __attribute__((aligned(64)));

static _Atomic int stop_flag;
static uint64_t on_ns = 2000000;   /* 2 ms busy */
static uint64_t off_ns = 8000000;  /* 8 ms sleep — PELT decays, util_est holds */
static uint64_t deadline_ns;
static int nburst = 0, nhog = 0;

static uint64_t now_ns(void)
{
	struct timespec ts;
	clock_gettime(CLOCK_MONOTONIC, &ts);
	return (uint64_t)ts.tv_sec * 1000000000ULL + ts.tv_nsec;
}

static void busy_for(uint64_t ns)
{
	uint64_t end = now_ns() + ns;
	while (now_ns() < end) {
		/* prevent compiler elision */
		__asm__ __volatile__("" ::: "memory");
	}
}

static void sleep_for(uint64_t ns)
{
	struct timespec ts = {
		.tv_sec = (time_t)(ns / 1000000000ULL),
		.tv_nsec = (long)(ns % 1000000000ULL),
	};
	while (nanosleep(&ts, &ts) && errno == EINTR)
		;
}

static unsigned hist_bucket(uint64_t ns)
{
	/* ~log2 buckets: 0..<1us, 1us, 2us, 4us, ... up to ~2ms+, then overflow */
	unsigned i = 0;
	uint64_t edge = 1000; /* 1 us */
	if (ns < edge)
		return 0;
	while (i + 1 < 63 && ns >= edge) {
		edge <<= 1;
		i++;
	}
	return i < 63 ? i : 63;
}

static void hist_add(struct hist *h, uint64_t ns)
{
	unsigned b = hist_bucket(ns);
	h->b[b]++;
	h->n++;
	h->sum += ns;
	if (ns > h->max)
		h->max = ns;
}

static uint64_t hist_percentile(const struct hist *h, double pct)
{
	uint64_t need, seen = 0;
	unsigned i;
	uint64_t edge, lo;
	if (!h->n)
		return 0;
	need = (uint64_t)((pct / 100.0) * (double)h->n);
	if (need == 0)
		need = 1;
	if (need > h->n)
		need = h->n;
	for (i = 0; i < 64; i++) {
		seen += h->b[i];
		if (seen >= need) {
			if (i == 0)
				return 500; /* mid of <1us */
			lo = 1000ULL << (i - 1);
			edge = 1000ULL << i;
			return (lo + edge) / 2;
		}
	}
	return h->max;
}

static void *burst_fn(void *arg)
{
	struct worker *w = arg;
	int prev_cpu = sched_getcpu();
	uint64_t t0, t1, wake_lat;

	while (!atomic_load_explicit(&stop_flag, memory_order_relaxed)) {
		if (now_ns() >= deadline_ns)
			break;

		t0 = now_ns();
		busy_for(on_ns);
		t1 = now_ns();
		w->st.busy_ns += t1 - t0;
		w->st.bursts++;

		{
			int cpu = sched_getcpu();
			if (cpu >= 0) {
				w->st.samples++;
				if (prev_cpu >= 0 && cpu != prev_cpu)
					w->st.cpu_changes++;
				prev_cpu = cpu;
			}
		}

		if (atomic_load_explicit(&stop_flag, memory_order_relaxed))
			break;
		if (now_ns() >= deadline_ns)
			break;

		t0 = now_ns();
		sleep_for(off_ns);
		t1 = now_ns();
		w->st.sleep_ns += t1 - t0;
		/* wake latency approx: how late we returned vs requested sleep */
		if (t1 > t0 + off_ns)
			wake_lat = t1 - (t0 + off_ns);
		else
			wake_lat = 0;
		w->st.wake_lat_sum_ns += wake_lat;
		if (wake_lat > w->st.wake_lat_max_ns)
			w->st.wake_lat_max_ns = wake_lat;
		hist_add(&w->wake_h, wake_lat);
	}
	return NULL;
}

static void *hog_fn(void *arg)
{
	struct worker *w = arg;
	int prev_cpu = sched_getcpu();
	uint64_t t0 = now_ns();

	while (!atomic_load_explicit(&stop_flag, memory_order_relaxed) &&
	       now_ns() < deadline_ns) {
		busy_for(1000000); /* 1 ms slices */
		{
			int cpu = sched_getcpu();
			if (cpu >= 0) {
				w->st.samples++;
				if (prev_cpu >= 0 && cpu != prev_cpu)
					w->st.cpu_changes++;
				prev_cpu = cpu;
			}
		}
	}
	w->st.busy_ns += now_ns() - t0;
	return NULL;
}

static void usage(const char *argv0)
{
	fprintf(stderr,
		"Usage: %s -d SECS [-b NBURST] [-h NHOG] [-o ON_US] [-f OFF_US] [-O outfile]\n"
		"  -d duration seconds (required)\n"
		"  -b burst workers (default nproc)\n"
		"  -h always-on hog workers (default nproc/2)\n"
		"  -o busy spin microseconds per burst (default 2000)\n"
		"  -f sleep microseconds per burst (default 8000)\n"
		"  -O metrics outfile (also printed to stdout)\n",
		argv0);
}

int main(int argc, char **argv)
{
	int duration = 0, opt;
	const char *outfile = NULL;
	FILE *out = stdout;
	struct worker *W = NULL;
	int n, i, ncpu;
	struct burst_stats tot = {0};
	struct hist wake_all = {0};
	uint64_t wall0, wall1;

	ncpu = (int)sysconf(_SC_NPROCESSORS_ONLN);
	if (ncpu < 1)
		ncpu = 1;
	nburst = ncpu;
	nhog = ncpu / 2;
	if (nhog < 1)
		nhog = 1;

	while ((opt = getopt(argc, argv, "d:b:h:o:f:O:")) != -1) {
		switch (opt) {
		case 'd':
			duration = atoi(optarg);
			break;
		case 'b':
			nburst = atoi(optarg);
			break;
		case 'h':
			nhog = atoi(optarg);
			break;
		case 'o':
			on_ns = (uint64_t)atoi(optarg) * 1000ULL;
			break;
		case 'f':
			off_ns = (uint64_t)atoi(optarg) * 1000ULL;
			break;
		case 'O':
			outfile = optarg;
			break;
		default:
			usage(argv[0]);
			return 2;
		}
	}
	if (duration <= 0 || nburst < 1) {
		usage(argv[0]);
		return 2;
	}
	if (outfile) {
		out = fopen(outfile, "w");
		if (!out) {
			perror(outfile);
			return 1;
		}
	}

	n = nburst + nhog;
	W = calloc((size_t)n, sizeof(*W));
	if (!W) {
		perror("calloc");
		return 1;
	}

	atomic_store(&stop_flag, 0);
	deadline_ns = now_ns() + (uint64_t)duration * 1000000000ULL;
	wall0 = now_ns();

	for (i = 0; i < nhog; i++) {
		W[i].id = i;
		W[i].is_hog = 1;
		if (pthread_create(&W[i].tid, NULL, hog_fn, &W[i])) {
			perror("pthread_create hog");
			return 1;
		}
	}
	for (i = 0; i < nburst; i++) {
		int idx = nhog + i;
		W[idx].id = i;
		W[idx].is_hog = 0;
		if (pthread_create(&W[idx].tid, NULL, burst_fn, &W[idx])) {
			perror("pthread_create burst");
			return 1;
		}
	}

	/* wait until deadline, then stop */
	while (now_ns() < deadline_ns)
		sleep_for(200000000ULL); /* 200 ms */
	atomic_store(&stop_flag, 1);

	for (i = 0; i < n; i++)
		pthread_join(W[i].tid, NULL);
	wall1 = now_ns();

	for (i = nhog; i < n; i++) {
		tot.bursts += W[i].st.bursts;
		tot.busy_ns += W[i].st.busy_ns;
		tot.sleep_ns += W[i].st.sleep_ns;
		tot.wake_lat_sum_ns += W[i].st.wake_lat_sum_ns;
		if (W[i].st.wake_lat_max_ns > tot.wake_lat_max_ns)
			tot.wake_lat_max_ns = W[i].st.wake_lat_max_ns;
		tot.cpu_changes += W[i].st.cpu_changes;
		tot.samples += W[i].st.samples;
		/* merge wake hist */
		{
			unsigned b;
			for (b = 0; b < 64; b++)
				wake_all.b[b] += W[i].wake_h.b[b];
			wake_all.n += W[i].wake_h.n;
			wake_all.sum += W[i].wake_h.sum;
			if (W[i].wake_h.max > wake_all.max)
				wake_all.max = W[i].wake_h.max;
		}
	}

	{
		uint64_t hog_busy = 0, hog_mig = 0, hog_samp = 0;
		for (i = 0; i < nhog; i++) {
			hog_busy += W[i].st.busy_ns;
			hog_mig += W[i].st.cpu_changes;
			hog_samp += W[i].st.samples;
		}
		fprintf(out, "wl_engine=util_est_burst\n");
		fprintf(out, "wl_nburst=%d\n", nburst);
		fprintf(out, "wl_nhog=%d\n", nhog);
		fprintf(out, "wl_on_us=%llu\n", (unsigned long long)(on_ns / 1000ULL));
		fprintf(out, "wl_off_us=%llu\n", (unsigned long long)(off_ns / 1000ULL));
		fprintf(out, "wl_duration_sec=%d\n", duration);
		fprintf(out, "wl_wall_ns=%llu\n", (unsigned long long)(wall1 - wall0));
		fprintf(out, "wl_bursts=%llu\n", (unsigned long long)tot.bursts);
		fprintf(out, "wl_bursts_per_sec=%.3f\n",
			(wall1 > wall0) ? (double)tot.bursts * 1e9 / (double)(wall1 - wall0) : 0.0);
		fprintf(out, "wl_busy_ns=%llu\n", (unsigned long long)tot.busy_ns);
		fprintf(out, "wl_sleep_ns=%llu\n", (unsigned long long)tot.sleep_ns);
		fprintf(out, "wl_wake_lat_avg_ns=%.0f\n",
			tot.bursts ? (double)tot.wake_lat_sum_ns / (double)tot.bursts : 0.0);
		fprintf(out, "wl_wake_lat_p50_ns=%llu\n",
			(unsigned long long)hist_percentile(&wake_all, 50.0));
		fprintf(out, "wl_wake_lat_p99_ns=%llu\n",
			(unsigned long long)hist_percentile(&wake_all, 99.0));
		fprintf(out, "wl_wake_lat_max_ns=%llu\n", (unsigned long long)tot.wake_lat_max_ns);
		fprintf(out, "wl_burst_cpu_changes=%llu\n", (unsigned long long)tot.cpu_changes);
		fprintf(out, "wl_burst_cpu_samples=%llu\n", (unsigned long long)tot.samples);
		fprintf(out, "wl_burst_migrate_frac=%.6f\n",
			tot.samples ? (double)tot.cpu_changes / (double)tot.samples : 0.0);
		fprintf(out, "wl_hog_busy_ns=%llu\n", (unsigned long long)hog_busy);
		fprintf(out, "wl_hog_cpu_changes=%llu\n", (unsigned long long)hog_mig);
		fprintf(out, "wl_hog_cpu_samples=%llu\n", (unsigned long long)hog_samp);
		fprintf(out, "wl_hog_migrate_frac=%.6f\n",
			hog_samp ? (double)hog_mig / (double)hog_samp : 0.0);
	}

	if (out != stdout)
		fclose(out);
	/* also mirror to stdout when writing a file */
	if (outfile) {
		FILE *m = fopen(outfile, "r");
		char buf[4096];
		size_t nread;
		if (m) {
			while ((nread = fread(buf, 1, sizeof buf, m)) > 0)
				fwrite(buf, 1, nread, stdout);
			fclose(m);
		}
	}
	free(W);
	return 0;
}
