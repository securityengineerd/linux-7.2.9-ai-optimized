/*
 * folio_split: Task 8 — exercise reclaim / deferred-split of large anon folios.
 *
 * Modes (-m):
 *   partial (default): allocate PMD anon THPs (MADV_HUGEPAGE), punch a
 *     fraction of pages inside each 2 MiB folio (partially mapped), then
 *     allocate a reclaim-driving hog so shrink_folio_list /
 *     deferred_split_scan split them. Proves thp_deferred_split_page /
 *     thp_split_page / thp_split_pmd under stock.
 *   swapfb: fully populate THPs, pre-fragment swap with order-0 anon
 *     (swap out via madvise MADV_PAGEOUT if available, else pressure), then
 *     reclaim THPs so folio_alloc_swap(order) fails → THP_SWPOUT_FALLBACK
 *     + split_folio_to_list.
 *   underused: touch only the first page of each THP (rest stay zero /
 *     shared-zero-like), then pressure so deferred_split underused path
 *     fires (gated by transparent_hugepage/shrink_underused).
 *
 * Safety: mlocked cushion; abort if oom_kill rises. Does not require root
 * beyond optional shrink_underused / memlock raise from the wrapper.
 */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
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
#ifndef MADV_PAGEOUT
#define MADV_PAGEOUT 21
#endif

enum mode { MODE_PARTIAL = 0, MODE_SWAPFB = 1, MODE_UNDERUSED = 2 };

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
	uint64_t thp_split_page, thp_split_page_failed, thp_deferred_split_page;
	uint64_t thp_split_pmd, thp_swpout, thp_swpout_fallback;
	uint64_t thp_fault_alloc, thp_fault_fallback;
	uint64_t pgscan_direct, pgscan_kswapd, pgsteal_direct, pgsteal_kswapd;
	uint64_t pswpin, pswpout, oom_kill, pgmajfault, pgfault;
	uint64_t nr_anon_transparent_hugepages;
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
	s->thp_split_page = vmstat_one("thp_split_page");
	s->thp_split_page_failed = vmstat_one("thp_split_page_failed");
	s->thp_deferred_split_page = vmstat_one("thp_deferred_split_page");
	s->thp_split_pmd = vmstat_one("thp_split_pmd");
	s->thp_swpout = vmstat_one("thp_swpout");
	s->thp_swpout_fallback = vmstat_one("thp_swpout_fallback");
	s->thp_fault_alloc = vmstat_one("thp_fault_alloc");
	s->thp_fault_fallback = vmstat_one("thp_fault_fallback");
	s->pgscan_direct = vmstat_one("pgscan_direct");
	s->pgscan_kswapd = vmstat_one("pgscan_kswapd");
	s->pgsteal_direct = vmstat_one("pgsteal_direct");
	s->pgsteal_kswapd = vmstat_one("pgsteal_kswapd");
	s->pswpin = vmstat_one("pswpin");
	s->pswpout = vmstat_one("pswpout");
	s->oom_kill = vmstat_one("oom_kill");
	s->pgmajfault = vmstat_one("pgmajfault");
	s->pgfault = vmstat_one("pgfault");
	s->nr_anon_transparent_hugepages = vmstat_one("nr_anon_transparent_hugepages");
}

static uint64_t write_touch(unsigned char *p, size_t bytes, size_t stride)
{
	size_t off;
	uint64_t acc = 0, idx = 0;
	for (off = 0; off < bytes; off += stride) {
		unsigned char v = (unsigned char)(((idx + 1) * 131) & 0xff);
		if (!v)
			v = 1;
		p[off] = v;
		acc = (acc + v) * 1099511628211ULL;
		idx++;
	}
	return acc;
}

/* Punch every other page inside each PMD-sized region to create partial maps. */
static int punch_partial_in_thps(unsigned char *p, size_t bytes, size_t page,
				 size_t thp_bytes, int punch_every_n)
{
	size_t off, thp_off;
	int rc = 0;
	if (punch_every_n < 2)
		punch_every_n = 2;
	for (thp_off = 0; thp_off + thp_bytes <= bytes; thp_off += thp_bytes) {
		for (off = page; off < thp_bytes; off += (size_t)punch_every_n * page) {
			if (madvise(p + thp_off + off, page, MADV_DONTNEED) != 0)
				rc = -1;
		}
	}
	return rc;
}

static void emit_delta(FILE *out, const char *name, uint64_t a, uint64_t b)
{
	fprintf(out, "wl_%s_delta=%llu\n", name,
		(unsigned long long)(b >= a ? b - a : 0));
}

static void usage(const char *a0)
{
	fprintf(stderr,
		"usage: %s [-m partial|swapfb|underused] [-r CUSHION_MIB]\n"
		"          [-t THP_MIB] [-h HOG_MIB] [-p PUNCH_EVERY_N] [-o FILE]\n",
		a0);
}

int main(int argc, char **argv)
{
	long cushion_mib = 1024;
	long thp_mib = 2048;
	long hog_mib = 0; /* 0 = auto from MemAvailable */
	int punch_every_n = 2;
	enum mode mode = MODE_PARTIAL;
	const char *out_path = NULL;
	int opt;
	size_t page, thp_bytes, cushion_bytes, thp_region_bytes, hog_bytes;
	unsigned char *cushion = MAP_FAILED, *thps = MAP_FAILED, *hog = MAP_FAILED;
	unsigned char *swapfrag = MAP_FAILED;
	size_t swapfrag_bytes = 0;
	uint64_t t0, t1, checksum = 0;
	uint64_t phase_alloc_ns = 0, phase_punch_ns = 0, phase_reclaim_ns = 0;
	int mlock_rc = 0, punch_rc = 0, pageout_rc = 0, thp_madv_rc = 0;
	int thp_count = 0;
	struct vmstat_snap before, after, mid;
	FILE *out;
	long mem_avail_kb, swap_free_kb;
	long avail_after_thp = -1, avail_end = -1;

	while ((opt = getopt(argc, argv, "m:r:t:h:p:o:")) != -1) {
		switch (opt) {
		case 'm':
			if (!strcmp(optarg, "partial"))
				mode = MODE_PARTIAL;
			else if (!strcmp(optarg, "swapfb"))
				mode = MODE_SWAPFB;
			else if (!strcmp(optarg, "underused"))
				mode = MODE_UNDERUSED;
			else {
				usage(argv[0]);
				return 2;
			}
			break;
		case 'r':
			cushion_mib = atol(optarg);
			break;
		case 't':
			thp_mib = atol(optarg);
			break;
		case 'h':
			hog_mib = atol(optarg);
			break;
		case 'p':
			punch_every_n = atoi(optarg);
			break;
		case 'o':
			out_path = optarg;
			break;
		default:
			usage(argv[0]);
			return 2;
		}
	}
	if (cushion_mib < 256 || thp_mib < 64)
		return 2;

	page = (size_t)sysconf(_SC_PAGESIZE);
	if (!page)
		page = 4096;
	thp_bytes = 512UL * page; /* PMD = 2 MiB on 4k */
	cushion_bytes = (size_t)cushion_mib * 1024ULL * 1024ULL;
	thp_region_bytes = (size_t)thp_mib * 1024ULL * 1024ULL;
	/* Align thp region down to whole THPs */
	thp_region_bytes = (thp_region_bytes / thp_bytes) * thp_bytes;
	if (!thp_region_bytes)
		return 2;
	thp_count = (int)(thp_region_bytes / thp_bytes);

	{
		struct rlimit rl;
		if (getrlimit(RLIMIT_MEMLOCK, &rl) == 0) {
			rl.rlim_cur = rl.rlim_max;
			(void)setrlimit(RLIMIT_MEMLOCK, &rl);
		}
	}

	mem_avail_kb = read_meminfo_kb("MemAvailable");
	swap_free_kb = read_meminfo_kb("SwapFree");
	if (mem_avail_kb < 0)
		mem_avail_kb = read_meminfo_kb("MemFree");
	if (mem_avail_kb < (cushion_mib + thp_mib + 512) * 1024L) {
		fprintf(stderr, "not enough MemAvailable for cushion+thp\n");
		return 3;
	}

	snap_vmstat(&before);

	/* Cushion (mlocked, NOHUGEPAGE) */
	cushion = mmap(NULL, cushion_bytes, PROT_READ | PROT_WRITE,
		       MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
	if (cushion == MAP_FAILED) {
		perror("mmap cushion");
		return 4;
	}
	(void)madvise(cushion, cushion_bytes, MADV_NOHUGEPAGE);
	(void)write_touch(cushion, cushion_bytes, page);
	mlock_rc = mlock(cushion, cushion_bytes);

	/* Optional: fragment swap with order-0 pages before THP reclaim (swapfb). */
	if (mode == MODE_SWAPFB && swap_free_kb > 64 * 1024L) {
		/* Use ~60% of SwapFree as order-0 swap bait, capped. */
		long bait_mib = swap_free_kb / 1024 * 60 / 100;
		if (bait_mib > 400)
			bait_mib = 400;
		if (bait_mib < 64)
			bait_mib = 64;
		swapfrag_bytes = (size_t)bait_mib * 1024ULL * 1024ULL;
		swapfrag = mmap(NULL, swapfrag_bytes, PROT_READ | PROT_WRITE,
				MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
		if (swapfrag != MAP_FAILED) {
			(void)madvise(swapfrag, swapfrag_bytes, MADV_NOHUGEPAGE);
			(void)write_touch(swapfrag, swapfrag_bytes, page);
			/* Prefer PAGEOUT; ignore ENOSYS / EINVAL. */
			if (madvise(swapfrag, swapfrag_bytes, MADV_PAGEOUT) != 0)
				pageout_rc = errno ? -errno : -1;
			else
				pageout_rc = 0;
		}
	}

	/* Allocate THP region */
	t0 = now_ns();
	thps = mmap(NULL, thp_region_bytes, PROT_READ | PROT_WRITE,
		    MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
	if (thps == MAP_FAILED) {
		perror("mmap thps");
		goto fail;
	}
	thp_madv_rc = madvise(thps, thp_region_bytes, MADV_HUGEPAGE);

	if (mode == MODE_UNDERUSED) {
		/* Touch only first page of each THP so most pages stay zero. */
		size_t off;
		for (off = 0; off < thp_region_bytes; off += thp_bytes) {
			thps[off] = 0x5a;
			checksum = (checksum + 0x5a) * 1099511628211ULL;
		}
	} else {
		checksum = write_touch(thps, thp_region_bytes, page);
	}
	t1 = now_ns();
	phase_alloc_ns = t1 - t0;
	avail_after_thp = read_meminfo_kb("MemAvailable");
	snap_vmstat(&mid);

	/* Partial unmap inside THPs */
	t0 = now_ns();
	if (mode == MODE_PARTIAL)
		punch_rc = punch_partial_in_thps(thps, thp_region_bytes, page,
						 thp_bytes, punch_every_n);
	t1 = now_ns();
	phase_punch_ns = t1 - t0;

	if (vmstat_one("oom_kill") > before.oom_kill) {
		fprintf(stderr, "oom during thp setup\n");
		goto fail_oom;
	}

	/* Reclaim hog: consume remaining available past cushion so kswapd /
	 * direct reclaim target the THP region (and swapfrag if any). */
	{
		long av = read_meminfo_kb("MemAvailable");
		long target_mib;
		if (hog_mib > 0)
			target_mib = hog_mib;
		else {
			/* Leave ~384 MiB free beyond cushion; eat the rest. */
			target_mib = (av / 1024) - 384;
			if (target_mib < 256)
				target_mib = 256;
		}
		hog_bytes = (size_t)target_mib * 1024ULL * 1024ULL;
	}

	t0 = now_ns();
	hog = mmap(NULL, hog_bytes, PROT_READ | PROT_WRITE,
		   MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
	if (hog == MAP_FAILED) {
		perror("mmap hog");
		hog_bytes = 0;
	} else {
		size_t off;
		(void)madvise(hog, hog_bytes, MADV_NOHUGEPAGE);
		/* Touch in 64 KiB strides then densify — push reclaim without
		 * being too abrupt for OOM. */
		for (off = 0; off < hog_bytes; off += page) {
			hog[off] = (unsigned char)((off / page) & 0xff);
			if ((off & ((1UL << 22) - 1)) == 0) { /* every 4 MiB */
				if (vmstat_one("oom_kill") > before.oom_kill) {
					fprintf(stderr, "oom during hog; stopping\n");
					hog_bytes = off + page;
					break;
				}
			}
		}
		/* Ask kernel to page out THPs preferentially via PAGEOUT on thps
		 * (best-effort) after hog has created pressure. */
		(void)madvise(thps, thp_region_bytes, MADV_PAGEOUT);
	}
	t1 = now_ns();
	phase_reclaim_ns = t1 - t0;

	/* Brief settle for kswapd / deferred split shrinker. */
	usleep(500000);

	snap_vmstat(&after);
	avail_end = read_meminfo_kb("MemAvailable");

	out = out_path ? fopen(out_path, "w") : stdout;
	if (!out)
		return 6;

	fprintf(out, "wl_engine=c\n");
	fprintf(out, "wl_mode=%s\n",
		mode == MODE_PARTIAL ? "partial" :
		mode == MODE_SWAPFB ? "swapfb" : "underused");
	fprintf(out, "wl_cushion_mib=%ld\n", cushion_mib);
	fprintf(out, "wl_mlock_rc=%d\n", mlock_rc);
	fprintf(out, "wl_thp_mib=%ld\n", thp_mib);
	fprintf(out, "wl_thp_region_bytes=%zu\n", thp_region_bytes);
	fprintf(out, "wl_thp_count=%d\n", thp_count);
	fprintf(out, "wl_thp_bytes=%zu\n", thp_bytes);
	fprintf(out, "wl_hog_bytes=%zu\n", hog_bytes);
	fprintf(out, "wl_punch_every_n=%d\n", punch_every_n);
	fprintf(out, "wl_punch_rc=%d\n", punch_rc);
	fprintf(out, "wl_pageout_rc=%d\n", pageout_rc);
	fprintf(out, "wl_thp_madv_rc=%d\n", thp_madv_rc);
	fprintf(out, "wl_swapfrag_bytes=%zu\n", swapfrag_bytes);
	fprintf(out, "wl_mem_avail_before_kb=%ld\n", mem_avail_kb);
	fprintf(out, "wl_swap_free_before_kb=%ld\n", swap_free_kb);
	fprintf(out, "wl_mem_avail_after_thp_kb=%ld\n", avail_after_thp);
	fprintf(out, "wl_mem_avail_end_kb=%ld\n", avail_end);
	fprintf(out, "wl_phase_alloc_ns=%llu\n", (unsigned long long)phase_alloc_ns);
	fprintf(out, "wl_phase_punch_ns=%llu\n", (unsigned long long)phase_punch_ns);
	fprintf(out, "wl_phase_reclaim_ns=%llu\n", (unsigned long long)phase_reclaim_ns);
	fprintf(out, "wl_checksum=%llu\n", (unsigned long long)checksum);

	/* Mid deltas (THP install only) */
	emit_delta(out, "thp_fault_alloc_install", before.thp_fault_alloc, mid.thp_fault_alloc);
	emit_delta(out, "thp_fault_fallback_install", before.thp_fault_fallback, mid.thp_fault_fallback);

	/* Full-run deltas */
	emit_delta(out, "thp_split_page", before.thp_split_page, after.thp_split_page);
	emit_delta(out, "thp_split_page_failed", before.thp_split_page_failed, after.thp_split_page_failed);
	emit_delta(out, "thp_deferred_split_page", before.thp_deferred_split_page, after.thp_deferred_split_page);
	emit_delta(out, "thp_split_pmd", before.thp_split_pmd, after.thp_split_pmd);
	emit_delta(out, "thp_swpout", before.thp_swpout, after.thp_swpout);
	emit_delta(out, "thp_swpout_fallback", before.thp_swpout_fallback, after.thp_swpout_fallback);
	emit_delta(out, "thp_fault_alloc", before.thp_fault_alloc, after.thp_fault_alloc);
	emit_delta(out, "thp_fault_fallback", before.thp_fault_fallback, after.thp_fault_fallback);
	emit_delta(out, "pgscan_direct", before.pgscan_direct, after.pgscan_direct);
	emit_delta(out, "pgscan_kswapd", before.pgscan_kswapd, after.pgscan_kswapd);
	emit_delta(out, "pgsteal_direct", before.pgsteal_direct, after.pgsteal_direct);
	emit_delta(out, "pgsteal_kswapd", before.pgsteal_kswapd, after.pgsteal_kswapd);
	emit_delta(out, "pswpin", before.pswpin, after.pswpin);
	emit_delta(out, "pswpout", before.pswpout, after.pswpout);
	emit_delta(out, "oom_kill", before.oom_kill, after.oom_kill);
	emit_delta(out, "pgmajfault", before.pgmajfault, after.pgmajfault);
	emit_delta(out, "pgfault", before.pgfault, after.pgfault);
	fprintf(out, "wl_nr_anon_thp_before=%llu\n",
		(unsigned long long)before.nr_anon_transparent_hugepages);
	fprintf(out, "wl_nr_anon_thp_after=%llu\n",
		(unsigned long long)after.nr_anon_transparent_hugepages);

	if (out_path)
		fclose(out);

	/* Cleanup */
	if (hog != MAP_FAILED && hog_bytes)
		munmap(hog, hog_bytes);
	if (thps != MAP_FAILED)
		munmap(thps, thp_region_bytes);
	if (swapfrag != MAP_FAILED)
		munmap(swapfrag, swapfrag_bytes);
	if (mlock_rc == 0)
		munlock(cushion, cushion_bytes);
	munmap(cushion, cushion_bytes);
	usleep(200000);

	printf("folio_split mode=%s thp=%d hog=%zu split_d=%llu deferred_d=%llu "
	       "swpout_d=%llu swpout_fb_d=%llu pgscan_d=%llu+%llu oom_d=%llu\n",
	       mode == MODE_PARTIAL ? "partial" :
	       mode == MODE_SWAPFB ? "swapfb" : "underused",
	       thp_count, hog_bytes,
	       (unsigned long long)(after.thp_split_page - before.thp_split_page),
	       (unsigned long long)(after.thp_deferred_split_page - before.thp_deferred_split_page),
	       (unsigned long long)(after.thp_swpout - before.thp_swpout),
	       (unsigned long long)(after.thp_swpout_fallback - before.thp_swpout_fallback),
	       (unsigned long long)(after.pgscan_direct - before.pgscan_direct),
	       (unsigned long long)(after.pgscan_kswapd - before.pgscan_kswapd),
	       (unsigned long long)(after.oom_kill - before.oom_kill));

	return (after.oom_kill > before.oom_kill) ? 7 : 0;

fail_oom:
	if (thps != MAP_FAILED)
		munmap(thps, thp_region_bytes);
fail:
	if (swapfrag != MAP_FAILED)
		munmap(swapfrag, swapfrag_bytes);
	if (cushion != MAP_FAILED) {
		if (mlock_rc == 0)
			munlock(cushion, cushion_bytes);
		munmap(cushion, cushion_bytes);
	}
	return 4;
}
