/*
 * mem_pressure: Task 7 — exercise direct reclaim / compaction on the
 * allocating (fault) path under intentional memory pressure.
 *
 * Modes (-m):
 *   fragment (default): mlock cushion, fill+punch checkerboard, keep THP
 *     chunks mapped to drain high-order free, timed THP fault hammer.
 *   reclaim: mlock cushion, fill most RAM (no punch), timed anon alloc
 *     past watermarks to drive pgscan_direct.
 *
 * Safety: mlocked cushion held until exit. Abort if oom_kill rises.
 */
#define _GNU_SOURCE
#include <errno.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/resource.h>
#include <time.h>
#include <unistd.h>

#ifndef MADV_HUGEPAGE
#define MADV_HUGEPAGE 14
#endif
#ifndef MADV_NOHUGEPAGE
#define MADV_NOHUGEPAGE 15
#endif
#ifndef MADV_DONTNEED
#define MADV_DONTNEED 4
#endif

enum mode { MODE_FRAGMENT = 0, MODE_RECLAIM = 1 };

static uint64_t now_ns(void)
{
	struct timespec ts;
	clock_gettime(CLOCK_MONOTONIC, &ts);
	return (uint64_t)ts.tv_sec * 1000000000ULL + (uint64_t)ts.tv_nsec;
}

static long read_meminfo_kb(const char *key)
{
	FILE *f = fopen("/proc/meminfo", "r");
	char line[256];
	long val = -1;
	size_t klen = strlen(key);
	if (!f)
		return -1;
	while (fgets(line, sizeof(line), f)) {
		if (strncmp(line, key, klen) == 0 && line[klen] == ':') {
			if (sscanf(line + klen + 1, "%ld", &val) == 1)
				break;
		}
	}
	fclose(f);
	return val;
}

struct vmstat_snap {
	uint64_t compact_stall, compact_success, compact_fail, compact_daemon_wake;
	uint64_t pgscan_direct, pgsteal_direct, pgscan_kswapd, pgsteal_kswapd;
	uint64_t oom_kill, thp_fault_alloc, thp_fault_fallback, thp_collapse_alloc;
	uint64_t pgmajfault, pgfault;
};

static uint64_t vmstat_one(const char *name)
{
	FILE *f = fopen("/proc/vmstat", "r");
	char key[128];
	unsigned long long v;
	uint64_t out = 0;
	if (!f)
		return 0;
	while (fscanf(f, "%127s %llu", key, &v) == 2) {
		if (strcmp(key, name) == 0) {
			out = (uint64_t)v;
			break;
		}
	}
	fclose(f);
	return out;
}

static void snap_vmstat(struct vmstat_snap *s)
{
	memset(s, 0, sizeof(*s));
	s->compact_stall = vmstat_one("compact_stall");
	s->compact_success = vmstat_one("compact_success");
	s->compact_fail = vmstat_one("compact_fail");
	s->compact_daemon_wake = vmstat_one("compact_daemon_wake");
	s->pgscan_direct = vmstat_one("pgscan_direct");
	s->pgsteal_direct = vmstat_one("pgsteal_direct");
	s->pgscan_kswapd = vmstat_one("pgscan_kswapd");
	s->pgsteal_kswapd = vmstat_one("pgsteal_kswapd");
	s->oom_kill = vmstat_one("oom_kill");
	s->thp_fault_alloc = vmstat_one("thp_fault_alloc");
	s->thp_fault_fallback = vmstat_one("thp_fault_fallback");
	s->thp_collapse_alloc = vmstat_one("thp_collapse_alloc");
	s->pgmajfault = vmstat_one("pgmajfault");
	s->pgfault = vmstat_one("pgfault");
}

static uint64_t write_touch(unsigned char *p, size_t bytes, size_t stride)
{
	size_t off;
	uint64_t acc = 0, idx = 0;
	for (off = 0; off < bytes; off += stride) {
		unsigned char v = (unsigned char)((idx * 131) & 0xff);
		p[off] = v;
		acc = (acc + v) * 1099511628211ULL;
		idx++;
	}
	return acc;
}

static int punch_alternate(unsigned char *p, size_t bytes, size_t page)
{
	size_t off;
	int rc = 0;
	for (off = 0; off < bytes; off += 2 * page) {
		if (madvise(p + off, page, MADV_DONTNEED) != 0)
			rc = -1;
	}
	return rc;
}

static void emit_buddy(FILE *out, const char *tag)
{
	FILE *f = fopen("/proc/buddyinfo", "r");
	char line[512];
	if (!f) {
		fprintf(out, "wl_buddy_%s=unreadable\n", tag);
		return;
	}
	while (fgets(line, sizeof(line), f)) {
		const char *zn = NULL;
		unsigned long c[11];
		char *pp;
		if (strstr(line, "Normal"))
			zn = "Normal";
		else if (strstr(line, "DMA32"))
			zn = "DMA32";
		else
			continue;
		pp = strstr(line, zn);
		if (!pp)
			continue;
		if (sscanf(pp, "%*s %lu %lu %lu %lu %lu %lu %lu %lu %lu %lu %lu",
			   &c[0], &c[1], &c[2], &c[3], &c[4], &c[5],
			   &c[6], &c[7], &c[8], &c[9], &c[10]) == 11) {
			fprintf(out,
				"wl_buddy_%s_%s=%lu,%lu,%lu,%lu,%lu,%lu,%lu,%lu,%lu,%lu,%lu\n",
				tag, zn, c[0], c[1], c[2], c[3], c[4], c[5],
				c[6], c[7], c[8], c[9], c[10]);
		}
	}
	fclose(f);
}

static void usage(const char *a0)
{
	fprintf(stderr,
		"usage: %s [-m fragment|reclaim] [-r CUSHION_MIB] [-f FILL_PCT]\n"
		"          [-c CHUNK_MIB] [-n ROUNDS] [-o FILE]\n",
		a0);
}

int main(int argc, char **argv)
{
	long cushion_mib = 1024;
	int fill_pct = 95;
	long chunk_mib = 64;
	int rounds = 32;
	enum mode mode = MODE_FRAGMENT;
	const char *out_path = NULL;
	int opt;
	long mem_avail_kb, fill_mib;
	size_t page, cushion_bytes, fill_bytes, chunk_bytes;
	unsigned char *cushion = MAP_FAILED, *fill = MAP_FAILED;
	unsigned char **chunks = NULL;
	uint64_t t_cush0, t_cush1, t_fill0, t_fill1, t_punch0, t_punch1;
	uint64_t t_alloc0, t_alloc1, checksum = 0, alloc_fault_ns = 0;
	long long alloc_minflt = 0;
	int i, punch_rc = 0, thp_madv_rc = 0, rounds_done = 0, mlock_rc = 0;
	struct vmstat_snap before, after;
	struct rusage ru0, ru1;
	FILE *out;
	long avail_after_cushion_kb = -1, avail_after_fill_kb = -1;
	long avail_after_punch_kb = -1, avail_end_kb = -1;

	while ((opt = getopt(argc, argv, "m:r:f:c:n:o:h")) != -1) {
		switch (opt) {
		case 'm':
			if (!strcmp(optarg, "fragment"))
				mode = MODE_FRAGMENT;
			else if (!strcmp(optarg, "reclaim"))
				mode = MODE_RECLAIM;
			else {
				usage(argv[0]);
				return 2;
			}
			break;
		case 'r':
			cushion_mib = atol(optarg);
			break;
		case 'f':
			fill_pct = atoi(optarg);
			break;
		case 'c':
			chunk_mib = atol(optarg);
			break;
		case 'n':
			rounds = atoi(optarg);
			break;
		case 'o':
			out_path = optarg;
			break;
		default:
			usage(argv[0]);
			return 2;
		}
	}
	if (cushion_mib < 256 || fill_pct < 50 || fill_pct > 98 ||
	    chunk_mib < 8 || rounds < 1)
		return 2;

	page = (size_t)sysconf(_SC_PAGESIZE);
	if (!page)
		page = 4096;
	cushion_bytes = (size_t)cushion_mib * 1024ULL * 1024ULL;
	chunk_bytes = (size_t)chunk_mib * 1024ULL * 1024ULL;

	{
		struct rlimit rl;
		if (getrlimit(RLIMIT_MEMLOCK, &rl) == 0) {
			rl.rlim_cur = rl.rlim_max;
			(void)setrlimit(RLIMIT_MEMLOCK, &rl);
		}
	}

	mem_avail_kb = read_meminfo_kb("MemAvailable");
	if (mem_avail_kb < 0)
		mem_avail_kb = read_meminfo_kb("MemFree");
	if (mem_avail_kb < (cushion_mib + 1024) * 1024L) {
		fprintf(stderr, "not enough MemAvailable\n");
		return 3;
	}

	snap_vmstat(&before);

	/* Cushion */
	t_cush0 = now_ns();
	cushion = mmap(NULL, cushion_bytes, PROT_READ | PROT_WRITE,
		       MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
	if (cushion == MAP_FAILED) {
		perror("mmap cushion");
		return 4;
	}
	(void)madvise(cushion, cushion_bytes, MADV_NOHUGEPAGE);
	(void)write_touch(cushion, cushion_bytes, page);
	mlock_rc = mlock(cushion, cushion_bytes);
	t_cush1 = now_ns();
	avail_after_cushion_kb = read_meminfo_kb("MemAvailable");

	fill_mib = ((avail_after_cushion_kb > 0 ? avail_after_cushion_kb
						: mem_avail_kb) /
		    1024) *
		   fill_pct / 100;
	if (mode == MODE_RECLAIM) {
		/* Leave a little headroom for timed allocs to push watermarks. */
		if (fill_pct > 88)
			fill_mib = ((avail_after_cushion_kb > 0 ? avail_after_cushion_kb
							       : mem_avail_kb) /
				    1024) *
				   88 / 100;
	}
	if (fill_mib < 256) {
		munmap(cushion, cushion_bytes);
		return 3;
	}
	fill_bytes = (size_t)fill_mib * 1024ULL * 1024ULL;

	t_fill0 = now_ns();
	fill = mmap(NULL, fill_bytes, PROT_READ | PROT_WRITE,
		    MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
	if (fill == MAP_FAILED) {
		perror("mmap fill");
		munmap(cushion, cushion_bytes);
		return 4;
	}
	(void)madvise(fill, fill_bytes, MADV_NOHUGEPAGE);
	(void)write_touch(fill, fill_bytes, page);
	t_fill1 = now_ns();
	avail_after_fill_kb = read_meminfo_kb("MemAvailable");

	t_punch0 = t_punch1 = now_ns();
	if (mode == MODE_FRAGMENT) {
		t_punch0 = now_ns();
		punch_rc = punch_alternate(fill, fill_bytes, page);
		t_punch1 = now_ns();
	}
	avail_after_punch_kb = read_meminfo_kb("MemAvailable");

	chunks = calloc((size_t)rounds, sizeof(*chunks));
	if (!chunks) {
		munmap(fill, fill_bytes);
		munmap(cushion, cushion_bytes);
		return 4;
	}

	getrusage(RUSAGE_SELF, &ru0);
	t_alloc0 = now_ns();
	for (i = 0; i < rounds; i++) {
		uint64_t t0, t1, cs;
		int advice = (mode == MODE_FRAGMENT) ? MADV_HUGEPAGE : MADV_NOHUGEPAGE;

		/* Stop if free collapses toward cushion-only. */
		{
			long av = read_meminfo_kb("MemAvailable");
			if (av >= 0 && av < 256 * 1024L) {
				fprintf(stderr, "stop: MemAvailable %ld kB\n", av);
				break;
			}
		}

		chunks[i] = mmap(NULL, chunk_bytes, PROT_READ | PROT_WRITE,
				 MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
		if (chunks[i] == MAP_FAILED) {
			perror("mmap chunk");
			break;
		}
		thp_madv_rc = madvise(chunks[i], chunk_bytes, advice);
		t0 = now_ns();
		cs = write_touch(chunks[i], chunk_bytes, page);
		t1 = now_ns();
		alloc_fault_ns += (t1 - t0);
		checksum ^= cs + (uint64_t)i * 0x9e3779b97f4a7c15ULL;
		rounds_done++;

		if (vmstat_one("oom_kill") > before.oom_kill) {
			fprintf(stderr, "oom_kill rose; stopping\n");
			break;
		}
	}
	t_alloc1 = now_ns();
	getrusage(RUSAGE_SELF, &ru1);
	alloc_minflt = (long long)ru1.ru_minflt - (long long)ru0.ru_minflt;
	if (alloc_minflt < 0)
		alloc_minflt = 0;

	snap_vmstat(&after);
	avail_end_kb = read_meminfo_kb("MemAvailable");

	out = out_path ? fopen(out_path, "w") : stdout;
	if (!out)
		return 6;

	fprintf(out, "wl_engine=c\n");
	fprintf(out, "wl_mode=%s\n", mode == MODE_FRAGMENT ? "fragment" : "reclaim");
	fprintf(out, "wl_cushion_mib=%ld\n", cushion_mib);
	fprintf(out, "wl_mlock_rc=%d\n", mlock_rc);
	fprintf(out, "wl_fill_pct=%d\n", fill_pct);
	fprintf(out, "wl_fill_mib=%ld\n", fill_mib);
	fprintf(out, "wl_fill_bytes=%zu\n", fill_bytes);
	fprintf(out, "wl_chunk_mib=%ld\n", chunk_mib);
	fprintf(out, "wl_rounds=%d\n", rounds);
	fprintf(out, "wl_rounds_done=%d\n", rounds_done);
	fprintf(out, "wl_page_bytes=%zu\n", page);
	fprintf(out, "wl_mem_avail_before_kb=%ld\n", mem_avail_kb);
	fprintf(out, "wl_mem_avail_after_cushion_kb=%ld\n", avail_after_cushion_kb);
	fprintf(out, "wl_mem_avail_after_fill_kb=%ld\n", avail_after_fill_kb);
	fprintf(out, "wl_mem_avail_after_punch_kb=%ld\n", avail_after_punch_kb);
	fprintf(out, "wl_mem_avail_end_kb=%ld\n", avail_end_kb);
	fprintf(out, "wl_cushion_ns=%llu\n", (unsigned long long)(t_cush1 - t_cush0));
	fprintf(out, "wl_fill_ns=%llu\n", (unsigned long long)(t_fill1 - t_fill0));
	fprintf(out, "wl_punch_ns=%llu\n", (unsigned long long)(t_punch1 - t_punch0));
	fprintf(out, "wl_alloc_wall_ns=%llu\n", (unsigned long long)(t_alloc1 - t_alloc0));
	fprintf(out, "wl_alloc_fault_ns=%llu\n", (unsigned long long)alloc_fault_ns);
	fprintf(out, "wl_alloc_minflt=%lld\n", alloc_minflt);
	fprintf(out, "wl_checksum=%llu\n", (unsigned long long)checksum);
	fprintf(out, "wl_punch_rc=%d\n", punch_rc);
	fprintf(out, "wl_thp_madv_rc=%d\n", thp_madv_rc);
	emit_buddy(out, "end");
	fprintf(out, "wl_compact_stall_delta=%llu\n",
		(unsigned long long)(after.compact_stall - before.compact_stall));
	fprintf(out, "wl_compact_success_delta=%llu\n",
		(unsigned long long)(after.compact_success - before.compact_success));
	fprintf(out, "wl_compact_fail_delta=%llu\n",
		(unsigned long long)(after.compact_fail - before.compact_fail));
	fprintf(out, "wl_compact_daemon_wake_delta=%llu\n",
		(unsigned long long)(after.compact_daemon_wake - before.compact_daemon_wake));
	fprintf(out, "wl_pgscan_direct_delta=%llu\n",
		(unsigned long long)(after.pgscan_direct - before.pgscan_direct));
	fprintf(out, "wl_pgsteal_direct_delta=%llu\n",
		(unsigned long long)(after.pgsteal_direct - before.pgsteal_direct));
	fprintf(out, "wl_pgscan_kswapd_delta=%llu\n",
		(unsigned long long)(after.pgscan_kswapd - before.pgscan_kswapd));
	fprintf(out, "wl_pgsteal_kswapd_delta=%llu\n",
		(unsigned long long)(after.pgsteal_kswapd - before.pgsteal_kswapd));
	fprintf(out, "wl_oom_kill_delta=%llu\n",
		(unsigned long long)(after.oom_kill - before.oom_kill));
	fprintf(out, "wl_thp_fault_alloc_delta=%llu\n",
		(unsigned long long)(after.thp_fault_alloc - before.thp_fault_alloc));
	fprintf(out, "wl_thp_fault_fallback_delta=%llu\n",
		(unsigned long long)(after.thp_fault_fallback - before.thp_fault_fallback));
	fprintf(out, "wl_thp_collapse_alloc_delta=%llu\n",
		(unsigned long long)(after.thp_collapse_alloc - before.thp_collapse_alloc));
	fprintf(out, "wl_pgmajfault_delta=%llu\n",
		(unsigned long long)(after.pgmajfault - before.pgmajfault));
	fprintf(out, "wl_pgfault_delta=%llu\n",
		(unsigned long long)(after.pgfault - before.pgfault));
	if (out_path)
		fclose(out);

	for (i = 0; i < rounds_done; i++)
		munmap(chunks[i], chunk_bytes);
	free(chunks);
	if (mlock_rc == 0)
		munlock(cushion, cushion_bytes);
	munmap(fill, fill_bytes);
	munmap(cushion, cushion_bytes);
	usleep(300000);

	printf("mem_pressure mode=%s cushion=%ld fill=%ld rounds=%d "
	       "fault_ns=%llu stall_d=%llu pgscan_d=%llu oom_d=%llu "
	       "thp_a=%llu thp_f=%llu\n",
	       mode == MODE_FRAGMENT ? "fragment" : "reclaim",
	       cushion_mib, fill_mib, rounds_done,
	       (unsigned long long)alloc_fault_ns,
	       (unsigned long long)(after.compact_stall - before.compact_stall),
	       (unsigned long long)(after.pgscan_direct - before.pgscan_direct),
	       (unsigned long long)(after.oom_kill - before.oom_kill),
	       (unsigned long long)(after.thp_fault_alloc - before.thp_fault_alloc),
	       (unsigned long long)(after.thp_fault_fallback - before.thp_fault_fallback));
	return (after.oom_kill > before.oom_kill) ? 7 : 0;
}
