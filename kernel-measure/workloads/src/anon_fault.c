/*
 * anon_fault: Task 6 — amortize anonymous write-fault zeroing via PMD / mTHP.
 *
 * Roadmap: do_anonymous_page zeros on write faults; PMD THP
 * (do_huge_pmd_anonymous_page) amortizes that work. Multi-size THP below PMD
 * installs as PTEs (set_pte_range). Anonymous PUD (1 GiB) is still missing
 * (create_huge_pud returns FALLBACK for anon). This workload measures the
 * policy path that already exists — not a new 1 GiB anon page type.
 *
 * For a fixed SIZE MiB anonymous mapping, write-touch every page under:
 *   1. MADV_NOHUGEPAGE  — force order-0 (4 KiB) faults + zeroing
 *   2. MADV_HUGEPAGE    — allow PMD / enabled mTHP sizes per sysfs policy
 *
 * Same byte budget both paths. Pass signal: hugeprefer finishes with lower
 * wall_ns and fewer minor faults when THP/mTHP is available.
 *
 * Output: wl_* key=value to -o FILE and a short summary on stdout.
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

static uint64_t now_ns(void)
{
	struct timespec ts;
	clock_gettime(CLOCK_MONOTONIC, &ts);
	return (uint64_t)ts.tv_sec * 1000000000ULL + (uint64_t)ts.tv_nsec;
}

static void usage(const char *argv0)
{
	fprintf(stderr,
		"usage: %s [-s SIZE_MIB] [-p PAGE_STRIDE] [-r RETOUCH] [-o FILE]\n"
		"  -s  anonymous region size MiB (default 1024)\n"
		"  -p  touch stride in bytes (default 4096 = every page)\n"
		"  -r  second-pass re-touch count after fault-in (default 1)\n"
		"  -o  metrics output file\n",
		argv0);
}

/* Force a store so the compiler cannot elide the write fault. */
static uint64_t write_touch(unsigned char *p, size_t bytes, size_t stride)
{
	size_t off;
	uint64_t acc = 0;
	uint64_t idx = 0;

	for (off = 0; off < bytes; off += stride) {
		/* stride is usually a multiple of 256, so off&0xff is always 0 —
		 * use the page index so the checksum is a real same-work proof.
		 */
		unsigned char v = (unsigned char)((idx * 131) & 0xff);
		p[off] = v;
		acc = (acc + v) * 1099511628211ULL;
		idx++;
	}
	return acc;
}

/* Read-touch already-faulted pages (TLB / bandwidth second pass). */
static uint64_t read_touch(volatile unsigned char *p, size_t bytes, size_t stride)
{
	size_t off;
	uint64_t acc = 0;

	for (off = 0; off < bytes; off += stride)
		acc += p[off];
	return acc;
}

struct path_result {
	const char *name;
	uint64_t fault_ns;
	uint64_t retouch_ns;
	uint64_t minor_faults;
	uint64_t checksum;
	int madvise_rc;
	int madvise_errno;
};

static long read_ru_minflt(void)
{
	struct rusage ru;
	if (getrusage(RUSAGE_SELF, &ru) != 0)
		return -1;
	return ru.ru_minflt;
}

static int run_path(struct path_result *out, size_t bytes, size_t stride,
		    int retouch_passes, int madvise_advice)
{
	unsigned char *p;
	long flt0, flt1;
	uint64_t t0, t1;
	int i;

	out->madvise_rc = 0;
	out->madvise_errno = 0;
	out->checksum = 0;
	out->retouch_ns = 0;

	p = mmap(NULL, bytes, PROT_READ | PROT_WRITE,
		 MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
	if (p == MAP_FAILED)
		return -1;

	if (madvise(p, bytes, madvise_advice) != 0) {
		out->madvise_rc = -1;
		out->madvise_errno = errno;
		/* Continue — NOHUGEPAGE/HUGEPAGE may be unsupported on some kernels. */
	}

	flt0 = read_ru_minflt();
	t0 = now_ns();
	out->checksum = write_touch(p, bytes, stride);
	t1 = now_ns();
	flt1 = read_ru_minflt();

	out->fault_ns = t1 - t0;
	if (flt0 >= 0 && flt1 >= flt0)
		out->minor_faults = (uint64_t)(flt1 - flt0);
	else
		out->minor_faults = 0;

	t0 = now_ns();
	for (i = 0; i < retouch_passes; i++)
		out->checksum += read_touch(p, bytes, stride);
	t1 = now_ns();
	out->retouch_ns = t1 - t0;

	munmap(p, bytes);
	return 0;
}

static void emit(FILE *fp, const char *k, unsigned long long v)
{
	fprintf(fp, "%s=%llu\n", k, v);
}

static void emit_str(FILE *fp, const char *k, const char *v)
{
	fprintf(fp, "%s=%s\n", k, v);
}

static void emit_double(FILE *fp, const char *k, double v)
{
	fprintf(fp, "%s=%.6f\n", k, v);
}

/* Best-effort snapshot of THP policy for the run record. */
static void emit_thp_policy(FILE *fp)
{
	FILE *f;
	char buf[256];
	const char *path = "/sys/kernel/mm/transparent_hugepage/enabled";

	f = fopen(path, "r");
	if (!f) {
		emit_str(fp, "wl_thp_enabled", "unknown");
		return;
	}
	if (fgets(buf, sizeof(buf), f)) {
		char *nl = strchr(buf, '\n');
		if (nl)
			*nl = '\0';
		emit_str(fp, "wl_thp_enabled", buf);
	}
	fclose(f);
}

int main(int argc, char **argv)
{
	size_t size_mib = 1024;
	size_t stride = 4096;
	int retouch = 1;
	const char *out_path = NULL;
	size_t bytes;
	struct path_result nohuge = { .name = "nohuge" };
	struct path_result huge = { .name = "hugeprefer" };
	FILE *out = stdout;
	FILE *metrics = NULL;
	int opt;
	double ratio;

	while ((opt = getopt(argc, argv, "s:p:r:o:h")) != -1) {
		switch (opt) {
		case 's':
			size_mib = strtoul(optarg, NULL, 10);
			break;
		case 'p':
			stride = strtoul(optarg, NULL, 10);
			break;
		case 'r':
			retouch = atoi(optarg);
			break;
		case 'o':
			out_path = optarg;
			break;
		case 'h':
		default:
			usage(argv[0]);
			return opt == 'h' ? 0 : 1;
		}
	}

	if (size_mib < 16 || size_mib > 16384) {
		fprintf(stderr, "error: -s SIZE_MIB must be 16..16384\n");
		return 1;
	}
	if (stride < 64 || (stride & (stride - 1)) != 0) {
		fprintf(stderr, "error: -p stride must be power-of-two >= 64\n");
		return 1;
	}
	if (retouch < 0 || retouch > 64) {
		fprintf(stderr, "error: -r RETOUCH must be 0..64\n");
		return 1;
	}

	bytes = size_mib * 1024ULL * 1024ULL;

	if (out_path) {
		metrics = fopen(out_path, "w");
		if (!metrics) {
			perror(out_path);
			return 1;
		}
		out = metrics;
	}

	/* Warm getrusage / clock once. */
	(void)read_ru_minflt();
	(void)now_ns();

	if (run_path(&nohuge, bytes, stride, retouch, MADV_NOHUGEPAGE) != 0) {
		perror("mmap nohuge");
		if (metrics)
			fclose(metrics);
		return 1;
	}
	if (run_path(&huge, bytes, stride, retouch, MADV_HUGEPAGE) != 0) {
		perror("mmap hugeprefer");
		if (metrics)
			fclose(metrics);
		return 1;
	}

	ratio = nohuge.fault_ns > 0
			? (double)huge.fault_ns / (double)nohuge.fault_ns
			: 0.0;

	emit_str(out, "wl_engine", "c");
	emit(out, "wl_size_mib", (unsigned long long)size_mib);
	emit(out, "wl_bytes", (unsigned long long)bytes);
	emit(out, "wl_stride", (unsigned long long)stride);
	emit(out, "wl_retouch_passes", (unsigned long long)retouch);
	emit_thp_policy(out);

	emit(out, "wl_nohuge_fault_ns", nohuge.fault_ns);
	emit(out, "wl_nohuge_retouch_ns", nohuge.retouch_ns);
	emit(out, "wl_nohuge_minflt", nohuge.minor_faults);
	emit(out, "wl_nohuge_checksum", nohuge.checksum);
	emit(out, "wl_nohuge_madvise_rc", (unsigned long long)(nohuge.madvise_rc < 0 ? 1 : 0));

	emit(out, "wl_hugeprefer_fault_ns", huge.fault_ns);
	emit(out, "wl_hugeprefer_retouch_ns", huge.retouch_ns);
	emit(out, "wl_hugeprefer_minflt", huge.minor_faults);
	emit(out, "wl_hugeprefer_checksum", huge.checksum);
	emit(out, "wl_hugeprefer_madvise_rc", (unsigned long long)(huge.madvise_rc < 0 ? 1 : 0));

	emit_double(out, "wl_hugeprefer_vs_nohuge_fault_ns_ratio", ratio);
	if (nohuge.fault_ns > 0) {
		double gbps_n = ((double)bytes / 1e9) / ((double)nohuge.fault_ns / 1e9);
		double gbps_h = ((double)bytes / 1e9) / ((double)huge.fault_ns / 1e9);
		emit_double(out, "wl_nohuge_fault_GBps", gbps_n);
		emit_double(out, "wl_hugeprefer_fault_GBps", gbps_h);
	}
	if (nohuge.minor_faults > 0) {
		emit_double(out, "wl_hugeprefer_vs_nohuge_minflt_ratio",
			    (double)huge.minor_faults / (double)nohuge.minor_faults);
	}

	if (metrics) {
		fclose(metrics);
		/* Also print a one-line human summary to stdout for logs. */
		printf("anon_fault size_mib=%zu nohuge_fault_ns=%llu hugeprefer_fault_ns=%llu "
		       "ratio=%.4f nohuge_minflt=%llu hugeprefer_minflt=%llu\n",
		       size_mib,
		       (unsigned long long)nohuge.fault_ns,
		       (unsigned long long)huge.fault_ns,
		       ratio,
		       (unsigned long long)nohuge.minor_faults,
		       (unsigned long long)huge.minor_faults);
	}

	return 0;
}
