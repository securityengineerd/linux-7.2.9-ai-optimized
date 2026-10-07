/*
 * hot_read: Task 5 — page-cache copy cost on hot reads.
 *
 * Creates a file on a real filesystem (not tmpfs), warms it into the page
 * cache, then reads the same byte budget three ways:
 *   1. buffered pread  — filemap_read -> copy_folio_to_iter every pass
 *   2. mmap            — filemap_map_pages once, then userspace DRAM loads
 *   3. O_DIRECT pread  — mapping->a_ops->direct_IO, no page-cache copy
 *
 * Pass criterion is application-path: mmap / O_DIRECT should need fewer
 * wall-ns (and typically fewer CPU cycles under perf) for the same bytes
 * than buffered pread once the file is hot. This is NOT a new kernel read
 * syscall; IOCB_DONTCACHE only drops after a buffered copy and does not
 * remove the copy on hot hits.
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
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

#ifndef O_DIRECT
#define O_DIRECT 00040000
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
		"usage: %s [-d SECONDS] [-s FILE_MB] [-b CHUNK_KB] [-t TARGET_MIB]\n"
		"          [-p PARENT_DIR] [-o FILE]\n"
		"  -d  approx total measure wall budget seconds (default 12);\n"
		"      used only to size TARGET if -t omitted\n"
		"  -s  backing file size MiB (default 64)\n"
		"  -b  pread/O_DIRECT chunk KiB (default 128; O_DIRECT needs align)\n"
		"  -t  bytes to read through EACH path, in MiB (default auto)\n"
		"  -p  parent dir for the temp file (must support O_DIRECT; not tmpfs)\n"
		"  -o  metrics output file\n",
		argv0);
}

/* Touch every byte so the compiler cannot elide the load.
 * FNV-1a style mix — weak hash was colliding to 1 on long inputs.
 */
static uint64_t checksum_buf(const unsigned char *p, size_t n, uint64_t acc)
{
	size_t i;
	for (i = 0; i + 8 <= n; i += 8) {
		uint64_t v;
		memcpy(&v, p + i, 8);
		acc ^= v;
		acc *= 1099511628211ULL;
	}
	for (; i < n; i++) {
		acc ^= p[i];
		acc *= 1099511628211ULL;
	}
	return acc;
}

static int fill_file(int fd, size_t bytes)
{
	const size_t chunk = 1024 * 1024;
	unsigned char *buf = aligned_alloc(4096, chunk);
	size_t left = bytes;
	uint64_t seed = 0xC0FFEEULL;

	if (!buf)
		return -1;
	while (left) {
		size_t n = left < chunk ? left : chunk;
		size_t i;
		for (i = 0; i < n; i++) {
			seed = seed * 6364136223846793005ULL + 1;
			buf[i] = (unsigned char)(seed >> 56);
		}
		if (write(fd, buf, n) != (ssize_t)n) {
			free(buf);
			return -1;
		}
		left -= n;
	}
	free(buf);
	if (fsync(fd) != 0)
		return -1;
	return 0;
}

static int warm_buffered(const char *path, size_t file_bytes, size_t chunk)
{
	int fd = open(path, O_RDONLY);
	unsigned char *buf;
	size_t off = 0;

	if (fd < 0)
		return -1;
	buf = malloc(chunk);
	if (!buf) {
		close(fd);
		return -1;
	}
	while (off < file_bytes) {
		size_t n = file_bytes - off;
		ssize_t r;
		if (n > chunk)
			n = chunk;
		r = pread(fd, buf, n, (off_t)off);
		if (r <= 0) {
			free(buf);
			close(fd);
			return -1;
		}
		off += (size_t)r;
	}
	free(buf);
	close(fd);
	return 0;
}

struct path_result {
	uint64_t bytes;
	uint64_t wall_ns;
	uint64_t checksum;
	int err;
};

static struct path_result run_buffered(const char *path, size_t file_bytes,
				       size_t chunk, uint64_t target_bytes)
{
	struct path_result r = {0};
	int fd = open(path, O_RDONLY);
	unsigned char *buf;
	uint64_t done = 0, acc = 1;
	size_t off = 0;
	uint64_t t0;

	if (fd < 0) {
		r.err = errno;
		return r;
	}
	buf = malloc(chunk);
	if (!buf) {
		r.err = ENOMEM;
		close(fd);
		return r;
	}
	t0 = now_ns();
	while (done < target_bytes) {
		size_t n = file_bytes - off;
		ssize_t got;
		if (n > chunk)
			n = chunk;
		if (n > target_bytes - done)
			n = (size_t)(target_bytes - done);
		got = pread(fd, buf, n, (off_t)off);
		if (got <= 0) {
			r.err = got < 0 ? errno : EIO;
			break;
		}
		acc = checksum_buf(buf, (size_t)got, acc);
		done += (uint64_t)got;
		off += (size_t)got;
		if (off >= file_bytes)
			off = 0;
	}
	r.wall_ns = now_ns() - t0;
	r.bytes = done;
	r.checksum = acc;
	free(buf);
	close(fd);
	return r;
}

static struct path_result run_mmap(const char *path, size_t file_bytes,
				   uint64_t target_bytes)
{
	struct path_result r = {0};
	int fd = open(path, O_RDONLY);
	unsigned char *map;
	uint64_t done = 0, acc = 1;
	size_t off = 0;
	uint64_t t0;
	const size_t stride = 4096;

	if (fd < 0) {
		r.err = errno;
		return r;
	}
	map = mmap(NULL, file_bytes, PROT_READ, MAP_SHARED, fd, 0);
	if (map == MAP_FAILED) {
		r.err = errno;
		close(fd);
		return r;
	}
	/* Fault the whole mapping in once (filemap_map_pages path). */
	{
		size_t i;
		volatile unsigned char sink = 0;
		for (i = 0; i < file_bytes; i += stride)
			sink ^= map[i];
		(void)sink;
	}
	t0 = now_ns();
	while (done < target_bytes) {
		size_t n = file_bytes - off;
		if (n > 1024 * 1024)
			n = 1024 * 1024;
		if (n > target_bytes - done)
			n = (size_t)(target_bytes - done);
		acc = checksum_buf(map + off, n, acc);
		done += n;
		off += n;
		if (off >= file_bytes)
			off = 0;
	}
	r.wall_ns = now_ns() - t0;
	r.bytes = done;
	r.checksum = acc;
	munmap(map, file_bytes);
	close(fd);
	return r;
}

static struct path_result run_odirect(const char *path, size_t file_bytes,
				      size_t chunk, uint64_t target_bytes)
{
	struct path_result r = {0};
	int fd;
	unsigned char *buf;
	uint64_t done = 0, acc = 1;
	size_t off = 0;
	uint64_t t0;
	size_t align = 4096;

	/* O_DIRECT requires buffer, offset, and length alignment. */
	if (chunk < align)
		chunk = align;
	chunk &= ~(align - 1);
	file_bytes &= ~(align - 1);
	if (file_bytes == 0 || chunk == 0) {
		r.err = EINVAL;
		return r;
	}

	fd = open(path, O_RDONLY | O_DIRECT);
	if (fd < 0) {
		r.err = errno;
		return r;
	}
	buf = aligned_alloc(align, chunk);
	if (!buf) {
		r.err = ENOMEM;
		close(fd);
		return r;
	}
	t0 = now_ns();
	while (done < target_bytes) {
		size_t n = file_bytes - off;
		ssize_t got;
		if (n > chunk)
			n = chunk;
		n &= ~(align - 1);
		if (n == 0) {
			off = 0;
			continue;
		}
		if (n > target_bytes - done) {
			n = (size_t)(target_bytes - done);
			n &= ~(align - 1);
			if (n == 0)
				break;
		}
		got = pread(fd, buf, n, (off_t)off);
		if (got <= 0) {
			r.err = got < 0 ? errno : EIO;
			break;
		}
		acc = checksum_buf(buf, (size_t)got, acc);
		done += (uint64_t)got;
		off += (size_t)got;
		if (off >= file_bytes)
			off = 0;
	}
	r.wall_ns = now_ns() - t0;
	r.bytes = done;
	r.checksum = acc;
	free(buf);
	close(fd);
	return r;
}

static double bps(uint64_t bytes, uint64_t ns)
{
	if (ns == 0)
		return 0.0;
	return (double)bytes * 1e9 / (double)ns;
}

int main(int argc, char **argv)
{
	int duration = 12;
	int file_mb = 64;
	int chunk_kb = 128;
	int target_mib = -1;
	const char *parent = NULL;
	const char *out_path = NULL;
	int opt;
	char path[512];
	size_t file_bytes, chunk;
	uint64_t target_bytes;
	int fd;
	struct path_result buf_r, map_r, dio_r;
	FILE *mout = NULL;
	double buf_bps, map_bps, dio_bps;

	while ((opt = getopt(argc, argv, "d:s:b:t:p:o:h")) != -1) {
		switch (opt) {
		case 'd':
			duration = atoi(optarg);
			break;
		case 's':
			file_mb = atoi(optarg);
			break;
		case 'b':
			chunk_kb = atoi(optarg);
			break;
		case 't':
			target_mib = atoi(optarg);
			break;
		case 'p':
			parent = optarg;
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
	if (duration < 3)
		duration = 3;
	if (file_mb < 4)
		file_mb = 4;
	if (chunk_kb < 4)
		chunk_kb = 4;

	if (!parent) {
		parent = getenv("HOTREAD_PARENT");
		if (!parent || !parent[0])
			parent = getenv("HOME");
		if (!parent || !parent[0])
			parent = "/var/tmp";
	}

	file_bytes = (size_t)file_mb * 1024ULL * 1024ULL;
	chunk = (size_t)chunk_kb * 1024ULL;
	if (target_mib > 0)
		target_bytes = (uint64_t)target_mib * 1024ULL * 1024ULL;
	else {
		/*
		 * Aim ~duration/3 seconds per path at ~4 GiB/s buffered
		 * copy bandwidth (conservative). Cap so a slow box still
		 * finishes inside the outer harness timeout.
		 */
		target_bytes = (uint64_t)duration * 1500ULL * 1024ULL * 1024ULL / 3ULL;
		if (target_bytes < 256ULL * 1024ULL * 1024ULL)
			target_bytes = 256ULL * 1024ULL * 1024ULL;
		if (target_bytes > 8ULL * 1024ULL * 1024ULL * 1024ULL)
			target_bytes = 8ULL * 1024ULL * 1024ULL * 1024ULL;
	}

	snprintf(path, sizeof(path), "%s/hot_read.XXXXXX", parent);
	fd = mkstemp(path);
	if (fd < 0) {
		fprintf(stderr, "mkstemp(%s): %s\n", path, strerror(errno));
		return 1;
	}
	/* mkstemp makes a small empty file; extend then fill. */
	if (ftruncate(fd, (off_t)file_bytes) != 0) {
		fprintf(stderr, "ftruncate: %s\n", strerror(errno));
		close(fd);
		unlink(path);
		return 1;
	}
	if (lseek(fd, 0, SEEK_SET) < 0 || fill_file(fd, file_bytes) != 0) {
		fprintf(stderr, "fill_file: %s\n", strerror(errno));
		close(fd);
		unlink(path);
		return 1;
	}
	close(fd);

	if (warm_buffered(path, file_bytes, chunk) != 0) {
		fprintf(stderr, "warm failed: %s\n", strerror(errno));
		unlink(path);
		return 1;
	}

	buf_r = run_buffered(path, file_bytes, chunk, target_bytes);
	map_r = run_mmap(path, file_bytes, target_bytes);
	dio_r = run_odirect(path, file_bytes, chunk, target_bytes);

	unlink(path);

	buf_bps = bps(buf_r.bytes, buf_r.wall_ns);
	map_bps = bps(map_r.bytes, map_r.wall_ns);
	dio_bps = bps(dio_r.bytes, dio_r.wall_ns);

	if (out_path) {
		mout = fopen(out_path, "w");
		if (!mout) {
			fprintf(stderr, "open metrics %s: %s\n", out_path,
				strerror(errno));
			return 1;
		}
	} else {
		mout = stdout;
	}

	fprintf(mout, "wl_engine=hot_read\n");
	fprintf(mout, "wl_file_mb=%d\n", file_mb);
	fprintf(mout, "wl_chunk_kb=%d\n", chunk_kb);
	fprintf(mout, "wl_target_bytes=%llu\n",
		(unsigned long long)target_bytes);
	fprintf(mout, "wl_parent=%s\n", parent);

	fprintf(mout, "wl_buffered_bytes=%llu\n",
		(unsigned long long)buf_r.bytes);
	fprintf(mout, "wl_buffered_ns=%llu\n",
		(unsigned long long)buf_r.wall_ns);
	fprintf(mout, "wl_buffered_bytes_per_sec=%.0f\n", buf_bps);
	fprintf(mout, "wl_buffered_errno=%d\n", buf_r.err);

	fprintf(mout, "wl_mmap_bytes=%llu\n",
		(unsigned long long)map_r.bytes);
	fprintf(mout, "wl_mmap_ns=%llu\n", (unsigned long long)map_r.wall_ns);
	fprintf(mout, "wl_mmap_bytes_per_sec=%.0f\n", map_bps);
	fprintf(mout, "wl_mmap_errno=%d\n", map_r.err);

	fprintf(mout, "wl_odirect_bytes=%llu\n",
		(unsigned long long)dio_r.bytes);
	fprintf(mout, "wl_odirect_ns=%llu\n",
		(unsigned long long)dio_r.wall_ns);
	fprintf(mout, "wl_odirect_bytes_per_sec=%.0f\n", dio_bps);
	fprintf(mout, "wl_odirect_errno=%d\n", dio_r.err);

	if (buf_r.wall_ns > 0 && map_r.wall_ns > 0)
		fprintf(mout, "wl_mmap_vs_buffered_ns_ratio=%.3f\n",
			(double)map_r.wall_ns / (double)buf_r.wall_ns);
	else
		fprintf(mout, "wl_mmap_vs_buffered_ns_ratio=n/a\n");
	if (buf_r.wall_ns > 0 && dio_r.wall_ns > 0 && dio_r.err == 0)
		fprintf(mout, "wl_odirect_vs_buffered_ns_ratio=%.3f\n",
			(double)dio_r.wall_ns / (double)buf_r.wall_ns);
	else
		fprintf(mout, "wl_odirect_vs_buffered_ns_ratio=n/a\n");

	/* Keep checksums so a future compare can spot silent elision. */
	fprintf(mout, "wl_buffered_checksum=%llu\n",
		(unsigned long long)buf_r.checksum);
	fprintf(mout, "wl_mmap_checksum=%llu\n",
		(unsigned long long)map_r.checksum);
	fprintf(mout, "wl_odirect_checksum=%llu\n",
		(unsigned long long)dio_r.checksum);
	fprintf(mout,
		"wl_note=hot_page_cache_then_buffered_vs_mmap_vs_odirect\n");

	if (out_path && mout) {
		printf("wl_buffered_bytes_per_sec=%.0f wl_mmap_bytes_per_sec=%.0f wl_odirect_bytes_per_sec=%.0f\n",
		       buf_bps, map_bps, dio_bps);
		printf("wl_mmap_vs_buffered_ns_ratio=%.3f wl_odirect_vs_buffered_ns_ratio=",
		       (buf_r.wall_ns && map_r.wall_ns)
			   ? (double)map_r.wall_ns / (double)buf_r.wall_ns
			   : -1.0);
		if (buf_r.wall_ns && dio_r.wall_ns && dio_r.err == 0)
			printf("%.3f\n",
			       (double)dio_r.wall_ns / (double)buf_r.wall_ns);
		else
			printf("n/a\n");
		fclose(mout);
	}

	if (buf_r.err || map_r.err)
		return 1;
	/* O_DIRECT failure is recorded but does not fail the whole run if
	 * buffered+mmap succeeded — tmpfs hosts still get the mmap win. */
	return 0;
}
