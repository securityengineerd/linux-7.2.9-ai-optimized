/*
 * folio_wait — Task 15: stress hashed folio wait queues (writeback + page lock).
 *
 * Creates many independent dirty folios across NFILES, then drives concurrent
 * fsync / sync_file_range so waiters sleep on PG_writeback via folio_wait_bit.
 * With PAGE_WAIT_TABLE_BITS=8 (256 buckets), many unrelated folio waiters share
 * hashed wait_queue_head_t buckets — the collision case the roadmap names.
 *
 * Modes:
 *   writeback (default) — files partitioned across workers; write+fdatasync
 *   mixed               — half writers / half readers on partitioned files
 *   lockwait            — writers use sync_file_range WAIT_*; readers pread
 *
 * Each worker opens only its file slice (avoids EMFILE with many files).
 */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <inttypes.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/resource.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <time.h>
#include <unistd.h>

struct lat {
	uint64_t n;
	uint64_t sum_ns;
	uint64_t max_ns;
	uint64_t hist[64];
};

struct worker_arg {
	int id;
	int file_lo; /* inclusive */
	int file_hi; /* exclusive */
	int file_kb;
	int chunk_kb;
	int mode; /* 0=wb writer, 1=reader, 2=lockwait writer */
	char **paths;
	volatile int *stop;
	struct lat *lat;
	uint64_t ops;
	uint64_t bytes;
	uint64_t errors;
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

static void lat_merge(struct lat *dst, const struct lat *src)
{
	unsigned b;
	dst->n += src->n;
	dst->sum_ns += src->sum_ns;
	if (src->max_ns > dst->max_ns)
		dst->max_ns = src->max_ns;
	for (b = 0; b < 64; b++)
		dst->hist[b] += src->hist[b];
}

static int ensure_file(const char *path, size_t bytes)
{
	int fd = open(path, O_RDWR | O_CREAT, 0644);
	char buf[4096];
	size_t left;
	ssize_t w;
	if (fd < 0)
		return -1;
	if (ftruncate(fd, (off_t)bytes) != 0) {
		close(fd);
		return -1;
	}
	memset(buf, 0xA5, sizeof(buf));
	left = bytes;
	lseek(fd, 0, SEEK_SET);
	while (left) {
		size_t n = left < sizeof(buf) ? left : sizeof(buf);
		w = write(fd, buf, n);
		if (w <= 0)
			break;
		left -= (size_t)w;
	}
	fsync(fd);
	close(fd);
	return 0;
}

static void raise_nofile(int want)
{
	struct rlimit rl;
	if (getrlimit(RLIMIT_NOFILE, &rl) != 0)
		return;
	if ((int)rl.rlim_cur >= want)
		return;
	rl.rlim_cur = (rlim_t)want;
	if (rl.rlim_max < rl.rlim_cur)
		rl.rlim_cur = rl.rlim_max;
	setrlimit(RLIMIT_NOFILE, &rl);
}

static void *worker_fn(void *argp)
{
	struct worker_arg *a = argp;
	size_t chunk = (size_t)a->chunk_kb * 1024;
	size_t fsz = (size_t)a->file_kb * 1024;
	int nlocal = a->file_hi - a->file_lo;
	char *buf;
	int *fds;
	int i;
	uint64_t rng = (uint64_t)a->id * 0x9E3779B97F4A7C15ull + 1;

	if (nlocal < 1) {
		a->errors++;
		return NULL;
	}
	buf = malloc(chunk);
	fds = calloc((size_t)nlocal, sizeof(int));
	if (!buf || !fds) {
		a->errors++;
		free(buf);
		free(fds);
		return NULL;
	}
	memset(buf, (int)(0x40 + (a->id & 0x3f)), chunk);

	for (i = 0; i < nlocal; i++) {
		fds[i] = open(a->paths[a->file_lo + i], O_RDWR);
		if (fds[i] < 0)
			a->errors++;
	}

	while (!*(a->stop)) {
		int li, fd;
		off_t off;
		uint64_t t0, t1;
		ssize_t n;

		rng = rng * 6364136223846793005ull + 1;
		li = (int)((rng >> 33) % (uint64_t)nlocal);
		fd = fds[li];
		if (fd < 0) {
			a->errors++;
			continue;
		}
		rng = rng * 6364136223846793005ull + 1;
		off = (off_t)(((rng >> 33) % (fsz / chunk)) * chunk);

		if (a->mode == 1) {
			t0 = now_ns();
			n = pread(fd, buf, chunk, off);
			t1 = now_ns();
			if (n < 0)
				a->errors++;
			else {
				a->ops++;
				a->bytes += (uint64_t)n;
				lat_add(a->lat, t1 - t0);
			}
			continue;
		}

		n = pwrite(fd, buf, chunk, off);
		if (n < 0) {
			a->errors++;
			continue;
		}
		a->bytes += (uint64_t)n;

		t0 = now_ns();
		if (a->mode == 2) {
			if (sync_file_range(fd, off, (off_t)chunk,
					    SYNC_FILE_RANGE_WRITE |
					    SYNC_FILE_RANGE_WAIT_BEFORE |
					    SYNC_FILE_RANGE_WAIT_AFTER) != 0)
				a->errors++;
		} else {
			if (fdatasync(fd) != 0)
				a->errors++;
		}
		t1 = now_ns();
		a->ops++;
		lat_add(a->lat, t1 - t0);
	}

	for (i = 0; i < nlocal; i++)
		if (fds[i] >= 0)
			close(fds[i]);
	free(fds);
	free(buf);
	return NULL;
}

static void usage(const char *argv0)
{
	fprintf(stderr,
		"Usage: %s -d SECS [-t THREADS] [-f NFILES] [-s FILE_KB] [-c CHUNK_KB] [-m MODE] [-p DIR]\n"
		"  MODE: writeback|mixed|lockwait  (default writeback)\n",
		argv0);
}

int main(int argc, char **argv)
{
	int duration = 15, nthreads = 0, nfiles = 512, file_kb = 64, chunk_kb = 4;
	int mode_code = 0;
	const char *dir = NULL;
	const char *mode_str = "writeback";
	char tmpdir_buf[256];
	char **paths = NULL;
	pthread_t *tids = NULL;
	struct worker_arg *args = NULL;
	struct lat *lats = NULL;
	struct lat total;
	volatile int stop = 0;
	int i, opt;
	uint64_t t_start, t_end, ops = 0, bytes = 0, errors = 0;
	int created_dir = 0;

	while ((opt = getopt(argc, argv, "d:t:f:s:c:m:p:h")) != -1) {
		switch (opt) {
		case 'd': duration = atoi(optarg); break;
		case 't': nthreads = atoi(optarg); break;
		case 'f': nfiles = atoi(optarg); break;
		case 's': file_kb = atoi(optarg); break;
		case 'c': chunk_kb = atoi(optarg); break;
		case 'm': mode_str = optarg; break;
		case 'p': dir = optarg; break;
		default: usage(argv[0]); return 2;
		}
	}
	if (duration < 1 || nfiles < 1 || file_kb < 4 || chunk_kb < 1 ||
	    chunk_kb > file_kb) {
		usage(argv[0]);
		return 2;
	}
	if (!strcmp(mode_str, "writeback"))
		mode_code = 0;
	else if (!strcmp(mode_str, "mixed"))
		mode_code = 1;
	else if (!strcmp(mode_str, "lockwait"))
		mode_code = 2;
	else {
		fprintf(stderr, "unknown mode %s\n", mode_str);
		return 2;
	}
	if (nthreads <= 0) {
		long n = sysconf(_SC_NPROCESSORS_ONLN);
		nthreads = (n > 0) ? (int)n : 4;
	}
	if (nfiles < nthreads)
		nfiles = nthreads;

	raise_nofile(nfiles + nthreads + 64);

	if (!dir) {
		snprintf(tmpdir_buf, sizeof(tmpdir_buf),
			 "/tmp/folio_wait.%d", (int)getpid());
		dir = tmpdir_buf;
		if (mkdir(dir, 0755) != 0 && errno != EEXIST) {
			perror("mkdir");
			return 1;
		}
		created_dir = 1;
	}

	paths = calloc((size_t)nfiles, sizeof(char *));
	if (!paths)
		return 1;
	for (i = 0; i < nfiles; i++) {
		paths[i] = malloc(512);
		if (!paths[i])
			return 1;
		snprintf(paths[i], 512, "%s/f%05d.dat", dir, i);
		if (ensure_file(paths[i], (size_t)file_kb * 1024) != 0) {
			fprintf(stderr, "ensure_file %s failed: %s\n",
				paths[i], strerror(errno));
			return 1;
		}
	}

	tids = calloc((size_t)nthreads, sizeof(pthread_t));
	args = calloc((size_t)nthreads, sizeof(struct worker_arg));
	lats = calloc((size_t)nthreads, sizeof(struct lat));
	if (!tids || !args || !lats)
		return 1;

	for (i = 0; i < nthreads; i++) {
		int lo = (i * nfiles) / nthreads;
		int hi = ((i + 1) * nfiles) / nthreads;
		int wmode;
		if (mode_code == 1)
			wmode = (i & 1) ? 1 : 0; /* alternate reader/writer */
		else if (mode_code == 2)
			wmode = (i & 1) ? 1 : 2; /* alternate lockwait writer / reader */
		else
			wmode = 0;
		args[i].id = i;
		args[i].file_lo = lo;
		args[i].file_hi = hi;
		args[i].file_kb = file_kb;
		args[i].chunk_kb = chunk_kb;
		args[i].mode = wmode;
		args[i].paths = paths;
		args[i].stop = &stop;
		args[i].lat = &lats[i];
		if (pthread_create(&tids[i], NULL, worker_fn, &args[i]) != 0) {
			perror("pthread_create");
			stop = 1;
			return 1;
		}
	}

	t_start = now_ns();
	sleep((unsigned)duration);
	stop = 1;
	for (i = 0; i < nthreads; i++)
		pthread_join(tids[i], NULL);
	t_end = now_ns();

	memset(&total, 0, sizeof(total));
	for (i = 0; i < nthreads; i++) {
		lat_merge(&total, &lats[i]);
		ops += args[i].ops;
		bytes += args[i].bytes;
		errors += args[i].errors;
	}

	{
		double sec = (double)(t_end - t_start) / 1e9;
		printf("wl_folio_wait_mode=%s\n", mode_str);
		printf("wl_folio_wait_threads=%d\n", nthreads);
		printf("wl_folio_wait_nfiles=%d\n", nfiles);
		printf("wl_folio_wait_file_kb=%d\n", file_kb);
		printf("wl_folio_wait_chunk_kb=%d\n", chunk_kb);
		printf("wl_folio_wait_duration_sec=%.3f\n", sec);
		printf("wl_folio_wait_ops=%" PRIu64 "\n", ops);
		printf("wl_folio_wait_ops_per_sec=%.2f\n", sec > 0 ? ops / sec : 0);
		printf("wl_folio_wait_bytes=%" PRIu64 "\n", bytes);
		printf("wl_folio_wait_mib_per_sec=%.2f\n",
		       sec > 0 ? (bytes / (1024.0 * 1024.0)) / sec : 0);
		printf("wl_folio_wait_errors=%" PRIu64 "\n", errors);
		printf("wl_folio_wait_lat_n=%" PRIu64 "\n", total.n);
		printf("wl_folio_wait_lat_p50_ns=%" PRIu64 "\n", lat_pct(&total, 0.50));
		printf("wl_folio_wait_lat_p90_ns=%" PRIu64 "\n", lat_pct(&total, 0.90));
		printf("wl_folio_wait_lat_p99_ns=%" PRIu64 "\n", lat_pct(&total, 0.99));
		printf("wl_folio_wait_lat_max_ns=%" PRIu64 "\n", total.max_ns);
		printf("wl_folio_wait_lat_avg_ns=%.0f\n",
		       total.n ? (double)total.sum_ns / (double)total.n : 0);
		printf("wl_page_wait_table_bits=8\n");
		printf("wl_page_wait_table_size=256\n");
	}

	for (i = 0; i < nfiles; i++) {
		unlink(paths[i]);
		free(paths[i]);
	}
	free(paths);
	free(tids);
	free(args);
	free(lats);
	if (created_dir)
		rmdir(dir);
	return errors > ops ? 1 : 0; /* soft fail only if errors dominate */
}
