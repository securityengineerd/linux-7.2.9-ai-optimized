/*
 * io_uring_submit: single-issuer SQE hammer for kernel-measure Task 9.
 *
 * Creates a ring with IORING_SETUP_SINGLE_ISSUER | IORING_SETUP_DEFER_TASKRUN
 * (implies IO_RING_F_LOCKLESS_CQ) and floods IORING_OP_NOP SQEs through
 * io_uring_enter, draining CQEs each batch. Measures submission-path cost
 * with no disk I/O and no io-wq punts — the uring_lock on submit is the
 * hot mutex the Task 9 patch targets.
 *
 * Output: key=value lines to -o FILE and stdout (wl_* metrics).
 * Not a score; compare only same binary, same args, same box.
 */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <linux/io_uring.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/syscall.h>
#include <time.h>
#include <unistd.h>

#ifndef IORING_OFF_SQ_RING
#define IORING_OFF_SQ_RING 0ULL
#endif
#ifndef IORING_OFF_CQ_RING
#define IORING_OFF_CQ_RING 0x8000000ULL
#endif
#ifndef IORING_OFF_SQES
#define IORING_OFF_SQES 0x10000000ULL
#endif

struct app_sq_ring {
	unsigned *head;
	unsigned *tail;
	unsigned *ring_mask;
	unsigned *ring_entries;
	unsigned *flags;
	unsigned *dropped;
	unsigned *array;
};

struct app_cq_ring {
	unsigned *head;
	unsigned *tail;
	unsigned *ring_mask;
	unsigned *ring_entries;
	struct io_uring_cqe *cqes;
};

static int io_uring_setup(unsigned entries, struct io_uring_params *p)
{
	return (int)syscall(__NR_io_uring_setup, entries, p);
}

static int io_uring_enter(int fd, unsigned to_submit, unsigned min_complete,
			  unsigned flags)
{
	return (int)syscall(__NR_io_uring_enter, fd, to_submit, min_complete,
			    flags, NULL, 0);
}

static uint64_t now_ns(void)
{
	struct timespec ts;
	clock_gettime(CLOCK_MONOTONIC, &ts);
	return (uint64_t)ts.tv_sec * 1000000000ULL + (uint64_t)ts.tv_nsec;
}

static void usage(const char *argv0)
{
	fprintf(stderr,
		"usage: %s [-d SECONDS] [-b BATCH] [-e ENTRIES] [-o FILE]\n"
		"  -d  duration seconds (default 12)\n"
		"  -b  SQEs per enter (default 32)\n"
		"  -e  ring entries power-of-two (default 256)\n"
		"  -o  metrics output file\n",
		argv0);
}

int main(int argc, char **argv)
{
	int duration = 12, batch = 32, entries = 256;
	const char *out_path = NULL;
	int opt, ring_fd = -1, ret;
	struct io_uring_params p;
	void *sq_ptr = MAP_FAILED, *cq_ptr = MAP_FAILED, *sqes_ptr = MAP_FAILED;
	size_t sq_bytes, cq_bytes, sqes_bytes;
	struct app_sq_ring sq;
	struct app_cq_ring cq;
	struct io_uring_sqe *sqes;
	uint64_t t0, deadline, submitted = 0, completed = 0, enters = 0;
	uint64_t enter_fail = 0, wall_ns;
	FILE *out = stdout;
	FILE *mout = NULL;

	while ((opt = getopt(argc, argv, "d:b:e:o:h")) != -1) {
		switch (opt) {
		case 'd':
			duration = atoi(optarg);
			break;
		case 'b':
			batch = atoi(optarg);
			break;
		case 'e':
			entries = atoi(optarg);
			break;
		case 'o':
			out_path = optarg;
			break;
		default:
			usage(argv[0]);
			return 2;
		}
	}
	if (duration <= 0 || batch <= 0 || entries < 4 ||
	    (entries & (entries - 1)) != 0) {
		fprintf(stderr, "bad args: duration>0 batch>0 entries=pow2>=4\n");
		return 2;
	}
	if (batch > entries)
		batch = entries;

	memset(&p, 0, sizeof(p));
	p.flags = IORING_SETUP_SINGLE_ISSUER | IORING_SETUP_DEFER_TASKRUN |
		  IORING_SETUP_COOP_TASKRUN;
	ring_fd = io_uring_setup((unsigned)entries, &p);
	if (ring_fd < 0) {
		perror("io_uring_setup");
		return 1;
	}

	sq_bytes = p.sq_off.array + p.sq_entries * sizeof(unsigned);
	cq_bytes = p.cq_off.cqes + p.cq_entries * sizeof(struct io_uring_cqe);
	sqes_bytes = p.sq_entries * sizeof(struct io_uring_sqe);

	sq_ptr = mmap(NULL, sq_bytes, PROT_READ | PROT_WRITE,
		      MAP_SHARED | MAP_POPULATE, ring_fd, IORING_OFF_SQ_RING);
	cq_ptr = mmap(NULL, cq_bytes, PROT_READ | PROT_WRITE,
		      MAP_SHARED | MAP_POPULATE, ring_fd, IORING_OFF_CQ_RING);
	sqes_ptr = mmap(NULL, sqes_bytes, PROT_READ | PROT_WRITE,
			MAP_SHARED | MAP_POPULATE, ring_fd, IORING_OFF_SQES);
	if (sq_ptr == MAP_FAILED || cq_ptr == MAP_FAILED ||
	    sqes_ptr == MAP_FAILED) {
		perror("mmap io_uring rings");
		ret = 1;
		goto out;
	}

	sq.head = sq_ptr + p.sq_off.head;
	sq.tail = sq_ptr + p.sq_off.tail;
	sq.ring_mask = sq_ptr + p.sq_off.ring_mask;
	sq.ring_entries = sq_ptr + p.sq_off.ring_entries;
	sq.flags = sq_ptr + p.sq_off.flags;
	sq.dropped = sq_ptr + p.sq_off.dropped;
	sq.array = sq_ptr + p.sq_off.array;
	cq.head = cq_ptr + p.cq_off.head;
	cq.tail = cq_ptr + p.cq_off.tail;
	cq.ring_mask = cq_ptr + p.cq_off.ring_mask;
	cq.ring_entries = cq_ptr + p.cq_off.ring_entries;
	cq.cqes = cq_ptr + p.cq_off.cqes;
	sqes = sqes_ptr;

	if (out_path) {
		mout = fopen(out_path, "w");
		if (!mout) {
			perror("fopen metrics");
			ret = 1;
			goto out;
		}
		out = mout;
	}

	t0 = now_ns();
	deadline = t0 + (uint64_t)duration * 1000000000ULL;

	while (now_ns() < deadline) {
		unsigned tail = *sq.tail;
		unsigned mask = *sq.ring_mask;
		unsigned i, to_submit;
		unsigned cq_head, cq_tail, nr;

		/* Drain CQ first so the ring never fills. */
		cq_head = *cq.head;
		cq_tail = *cq.tail;
		nr = cq_tail - cq_head;
		if (nr) {
			*cq.head = cq_head + nr;
			completed += nr;
		}

		to_submit = (unsigned)batch;
		for (i = 0; i < to_submit; i++) {
			unsigned idx = (tail + i) & mask;
			struct io_uring_sqe *sqe = &sqes[idx];

			memset(sqe, 0, sizeof(*sqe));
			sqe->opcode = IORING_OP_NOP;
			sqe->user_data = submitted + i;
			sq.array[idx] = idx;
		}
		*sq.tail = tail + to_submit;

		ret = io_uring_enter(ring_fd, to_submit, to_submit,
				     IORING_ENTER_GETEVENTS);
		enters++;
		if (ret < 0) {
			enter_fail++;
			if (enter_fail < 5)
				fprintf(stderr, "io_uring_enter: %s\n",
					strerror(errno));
			continue;
		}
		submitted += (uint64_t)ret;

		cq_head = *cq.head;
		cq_tail = *cq.tail;
		nr = cq_tail - cq_head;
		if (nr) {
			*cq.head = cq_head + nr;
			completed += nr;
		}
	}

	wall_ns = now_ns() - t0;
	{
		double sec = (double)wall_ns / 1e9;
		double nops = (double)completed / (sec > 0 ? sec : 1.0);

		fprintf(out, "wl_engine=io_uring_submit_nop\n");
		fprintf(out, "wl_flags=SINGLE_ISSUER|DEFER_TASKRUN|COOP_TASKRUN\n");
		fprintf(out, "wl_duration_sec=%d\n", duration);
		fprintf(out, "wl_batch=%d\n", batch);
		fprintf(out, "wl_entries=%d\n", entries);
		fprintf(out, "wl_submitted=%llu\n",
			(unsigned long long)submitted);
		fprintf(out, "wl_completed=%llu\n",
			(unsigned long long)completed);
		fprintf(out, "wl_enters=%llu\n", (unsigned long long)enters);
		fprintf(out, "wl_enter_fail=%llu\n",
			(unsigned long long)enter_fail);
		fprintf(out, "wl_wall_ns=%llu\n", (unsigned long long)wall_ns);
		fprintf(out, "wl_nops_per_sec=%.0f\n", nops);
		fprintf(out, "wl_sqe_features=0x%x\n", p.features);
		fflush(out);
		if (mout) {
			/* also mirror to stdout for logs */
			printf("wl_engine=io_uring_submit_nop\n");
			printf("wl_completed=%llu wl_nops_per_sec=%.0f\n",
			       (unsigned long long)completed, nops);
		}
	}

	ret = (enter_fail && completed == 0) ? 1 : 0;
out:
	if (mout)
		fclose(mout);
	if (sqes_ptr != MAP_FAILED)
		munmap(sqes_ptr, sqes_bytes);
	if (cq_ptr != MAP_FAILED)
		munmap(cq_ptr, cq_bytes);
	if (sq_ptr != MAP_FAILED)
		munmap(sq_ptr, sq_bytes);
	if (ring_fd >= 0)
		close(ring_fd);
	return ret;
}
