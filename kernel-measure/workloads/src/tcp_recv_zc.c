/*
 * tcp_recv_zc: localhost TCP receive hammer for kernel-measure Task 4.
 *
 * Measures classic recv() copy cost on loopback (the path that holds the
 * socket lock around skb_copy_datagram_msg in tcp_recvmsg_locked).
 *
 * Also probes the two in-tree zero-copy receive mechanisms:
 *   - MSG_SOCK_DEVMEM / tcp_recvmsg_dmabuf (needs dmabuf skbs from a NIC
 *     with header/data split + memory provider)
 *   - io_uring zcrx IORING_REGISTER_ZCRX_IFQ (same NIC requirements;
 *     ZCRX_REG_NODEV is copy-fallback only and is NOT counted as ZC)
 *
 * On hosts without a supporting NIC (e.g. Intel X550/ixgbe), probes report
 * wl_zc_available=0 and the classic path is still measured for a stock
 * baseline. Not a score; compare only same binary, same args, same box.
 */
#define _GNU_SOURCE
#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <linux/if_packet.h>
#include <linux/io_uring.h>
#include <net/if.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <sys/socket.h>
#include <sys/syscall.h>
#include <sys/types.h>
#include <time.h>
#include <unistd.h>

#ifndef MSG_SOCK_DEVMEM
#define MSG_SOCK_DEVMEM 0x2000000
#endif

#ifndef IORING_REGISTER_ZCRX_IFQ
#define IORING_REGISTER_ZCRX_IFQ 32
#endif

#ifndef IORING_SETUP_CQE32
#define IORING_SETUP_CQE32 (1U << 11)
#endif

/* From uapi/linux/io_uring/zcrx.h — duplicated so we build without that header. */
#ifndef ZCRX_REG_NODEV
#define ZCRX_REG_NODEV 2
#endif

struct io_uring_zcrx_offsets_local {
	__u32 head;
	__u32 tail;
	__u32 rqes;
	__u32 __resv2;
	__u64 __resv[2];
};

struct io_uring_zcrx_area_reg_local {
	__u64 addr;
	__u64 len;
	__u64 rq_area_token;
	__u32 flags;
	__u32 dmabuf_fd;
	__u64 __resv2[2];
};

struct io_uring_zcrx_ifq_reg_local {
	__u32 if_idx;
	__u32 if_rxq;
	__u32 rq_entries;
	__u32 flags;
	__u64 area_ptr;
	__u64 region_ptr;
	struct io_uring_zcrx_offsets_local offsets;
	__u32 zcrx_id;
	__u32 rx_buf_len;
	__u64 event_desc;
	__u64 __resv[2];
};

struct io_uring_region_desc_local {
	__u64 user_addr;
	__u64 size;
	__u32 flags;
	__u32 id;
	__u64 mmap_offset;
	__u64 __resv[4];
};

#ifndef IORING_MEM_REGION_TYPE_USER
#define IORING_MEM_REGION_TYPE_USER 1
#endif
#ifndef IORING_MEM_REGION_REG_WAIT_ARG
/* region_desc lives in io_uring.h on newer trees; keep a local copy. */
#endif

static int io_uring_setup(unsigned entries, struct io_uring_params *p)
{
	return (int)syscall(__NR_io_uring_setup, entries, p);
}

static int io_uring_register(int fd, unsigned opcode, void *arg,
			     unsigned nr_args)
{
	return (int)syscall(__NR_io_uring_register, fd, opcode, arg, nr_args);
}

static uint64_t now_ns(void)
{
	struct timespec ts;
	clock_gettime(CLOCK_MONOTONIC, &ts);
	return (uint64_t)ts.tv_sec * 1000000000ULL + (uint64_t)ts.tv_nsec;
}

struct sender_arg {
	int port;
	size_t chunk;
	volatile int ready;
	volatile int stop;
	uint64_t sent;
};

static void *sender_thread(void *arg)
{
	struct sender_arg *sa = arg;
	int srv, cli;
	struct sockaddr_in addr;
	char *buf;
	ssize_t n;

	buf = malloc(sa->chunk);
	if (!buf)
		return NULL;
	memset(buf, 'T', sa->chunk);

	srv = socket(AF_INET, SOCK_STREAM, 0);
	if (srv < 0) {
		free(buf);
		return NULL;
	}
	{
		int one = 1;
		setsockopt(srv, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
	}
	memset(&addr, 0, sizeof(addr));
	addr.sin_family = AF_INET;
	addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
	addr.sin_port = htons((uint16_t)sa->port);
	if (bind(srv, (struct sockaddr *)&addr, sizeof(addr)) < 0 ||
	    listen(srv, 1) < 0) {
		close(srv);
		free(buf);
		return NULL;
	}
	sa->ready = 1;
	cli = accept(srv, NULL, NULL);
	close(srv);
	if (cli < 0) {
		free(buf);
		return NULL;
	}
	{
		int one = 1;
		setsockopt(cli, IPPROTO_TCP, TCP_NODELAY, &one, sizeof(one));
	}
	while (!sa->stop) {
		n = send(cli, buf, sa->chunk, MSG_NOSIGNAL);
		if (n > 0)
			sa->sent += (uint64_t)n;
		else if (n < 0 && (errno == EINTR || errno == EAGAIN))
			continue;
		else
			break;
	}
	close(cli);
	free(buf);
	return NULL;
}

static int classic_recv_bench(int duration, size_t chunk, size_t total_target,
			      uint64_t *recv_out, uint64_t *wall_ns_out)
{
	struct sender_arg sa;
	pthread_t thr;
	int port = 15301;
	int fd = -1;
	struct sockaddr_in addr;
	char *buf;
	uint64_t t0, deadline, received = 0;
	int tries;

	buf = malloc(chunk);
	if (!buf)
		return -1;

	for (tries = 0; tries < 20; tries++) {
		sa.port = port + tries;
		sa.chunk = chunk;
		sa.ready = 0;
		sa.stop = 0;
		sa.sent = 0;
		if (pthread_create(&thr, NULL, sender_thread, &sa) != 0) {
			free(buf);
			return -1;
		}
		while (!sa.ready)
			usleep(1000);

		fd = socket(AF_INET, SOCK_STREAM, 0);
		if (fd < 0) {
			sa.stop = 1;
			pthread_join(thr, NULL);
			free(buf);
			return -1;
		}
		memset(&addr, 0, sizeof(addr));
		addr.sin_family = AF_INET;
		addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
		addr.sin_port = htons((uint16_t)sa.port);
		if (connect(fd, (struct sockaddr *)&addr, sizeof(addr)) == 0)
			break;
		close(fd);
		fd = -1;
		sa.stop = 1;
		pthread_join(thr, NULL);
	}
	if (fd < 0) {
		free(buf);
		return -1;
	}
	{
		int one = 1;
		setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof(one));
	}

	t0 = now_ns();
	deadline = t0 + (uint64_t)duration * 1000000000ULL;
	while (now_ns() < deadline) {
		ssize_t n = recv(fd, buf, chunk, 0);
		if (n > 0) {
			received += (uint64_t)n;
			if (total_target && received >= total_target)
				break;
		} else if (n == 0) {
			break;
		} else if (errno == EINTR) {
			continue;
		} else {
			break;
		}
	}
	*wall_ns_out = now_ns() - t0;
	*recv_out = received;
	sa.stop = 1;
	shutdown(fd, SHUT_RDWR);
	close(fd);
	pthread_join(thr, NULL);
	free(buf);
	return 0;
}

static int probe_msg_sock_devmem(int *errno_out)
{
	/*
	 * MSG_SOCK_DEVMEM only returns dmabuf tokens for skbs that arrived via
	 * a memory-provider NIC path. On loopback / unsupported NICs, recvmsg
	 * with the flag either copies normally or errors. We open a connected
	 * pair, send a small payload, and try MSG_SOCK_DEVMEM — success with
	 * SCM_DEVMEM_* cmsg would mean ZC; anything else is unavailable.
	 */
	int sv[2];
	char payload[64];
	char rbuf[64];
	char cbuf[256];
	struct msghdr msg;
	struct iovec iov;
	ssize_t n;

	*errno_out = 0;
	if (socketpair(AF_UNIX, SOCK_STREAM, 0, sv) == 0) {
		/* UNIX socketpair cannot carry TCP dmabuf; close and use TCP. */
		close(sv[0]);
		close(sv[1]);
	}

	{
		int lis, cli, acc;
		struct sockaddr_in addr;
		socklen_t alen = sizeof(addr);
		int one = 1;

		lis = socket(AF_INET, SOCK_STREAM, 0);
		if (lis < 0) {
			*errno_out = errno;
			return 0;
		}
		setsockopt(lis, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
		memset(&addr, 0, sizeof(addr));
		addr.sin_family = AF_INET;
		addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
		addr.sin_port = 0;
		if (bind(lis, (struct sockaddr *)&addr, sizeof(addr)) < 0 ||
		    listen(lis, 1) < 0) {
			*errno_out = errno;
			close(lis);
			return 0;
		}
		getsockname(lis, (struct sockaddr *)&addr, &alen);
		cli = socket(AF_INET, SOCK_STREAM, 0);
		if (cli < 0) {
			*errno_out = errno;
			close(lis);
			return 0;
		}
		if (connect(cli, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
			*errno_out = errno;
			close(cli);
			close(lis);
			return 0;
		}
		acc = accept(lis, NULL, NULL);
		close(lis);
		if (acc < 0) {
			*errno_out = errno;
			close(cli);
			return 0;
		}
		memset(payload, 'D', sizeof(payload));
		send(cli, payload, sizeof(payload), 0);
		close(cli);

		memset(&msg, 0, sizeof(msg));
		iov.iov_base = rbuf;
		iov.iov_len = sizeof(rbuf);
		msg.msg_iov = &iov;
		msg.msg_iovlen = 1;
		msg.msg_control = cbuf;
		msg.msg_controllen = sizeof(cbuf);
		n = recvmsg(acc, &msg, MSG_SOCK_DEVMEM);
		if (n < 0) {
			*errno_out = errno;
			close(acc);
			return 0;
		}
		/* Look for SCM_DEVMEM_DMABUF / SCM_DEVMEM_LINEAR in cmsg. */
		{
			struct cmsghdr *c;
			int saw = 0;
			for (c = CMSG_FIRSTHDR(&msg); c;
			     c = CMSG_NXTHDR(&msg, c)) {
				/* linux/socket.h: SCM_DEVMEM_DMABUF=0x55, LINEAR=0x56 typical */
				if (c->cmsg_level == SOL_SOCKET &&
				    (c->cmsg_type == 0x55 ||
				     c->cmsg_type == 0x56))
					saw = 1;
			}
			close(acc);
			if (saw)
				return 1;
			*errno_out = ENODATA; /* received copy, no dmabuf token */
			return 0;
		}
	}
}

static int probe_zcrx_ifq(const char *ifname, int *errno_out)
{
	struct io_uring_params p;
	struct io_uring_zcrx_ifq_reg_local reg;
	struct io_uring_zcrx_area_reg_local area;
	struct io_uring_region_desc_local region;
	void *area_ptr = MAP_FAILED, *ring_ptr = MAP_FAILED;
	size_t page, area_size, ring_size;
	unsigned if_idx;
	int ring_fd = -1, ret = 0;

	*errno_out = 0;
	page = (size_t)sysconf(_SC_PAGESIZE);
	if (!page)
		page = 4096;
	area_size = 128 * page;
	ring_size = 4096 * 16 + page;
	ring_size = (ring_size + page - 1) & ~(page - 1);

	if_idx = if_nametoindex(ifname);
	if (!if_idx) {
		*errno_out = ENODEV;
		return 0;
	}

	memset(&p, 0, sizeof(p));
	p.flags = IORING_SETUP_SINGLE_ISSUER | IORING_SETUP_DEFER_TASKRUN |
		  IORING_SETUP_CQE32;
	ring_fd = io_uring_setup(64, &p);
	if (ring_fd < 0) {
		*errno_out = errno;
		return 0;
	}

	area_ptr = mmap(NULL, area_size, PROT_READ | PROT_WRITE,
			MAP_ANONYMOUS | MAP_PRIVATE, -1, 0);
	ring_ptr = mmap(NULL, ring_size, PROT_READ | PROT_WRITE,
			MAP_ANONYMOUS | MAP_PRIVATE, -1, 0);
	if (area_ptr == MAP_FAILED || ring_ptr == MAP_FAILED) {
		*errno_out = errno;
		ret = 0;
		goto out;
	}

	memset(&area, 0, sizeof(area));
	area.addr = (uint64_t)(uintptr_t)area_ptr;
	area.len = area_size;

	memset(&region, 0, sizeof(region));
	region.user_addr = (uint64_t)(uintptr_t)ring_ptr;
	region.size = ring_size;
	region.flags = IORING_MEM_REGION_TYPE_USER;

	memset(&reg, 0, sizeof(reg));
	reg.if_idx = if_idx;
	reg.if_rxq = 0;
	reg.rq_entries = 4096;
	reg.area_ptr = (uint64_t)(uintptr_t)&area;
	reg.region_ptr = (uint64_t)(uintptr_t)&region;

	if (io_uring_register(ring_fd, IORING_REGISTER_ZCRX_IFQ, &reg, 1) == 0) {
		ret = 1;
		*errno_out = 0;
	} else {
		*errno_out = errno;
		ret = 0;
	}
out:
	if (ring_ptr != MAP_FAILED)
		munmap(ring_ptr, ring_size);
	if (area_ptr != MAP_FAILED)
		munmap(area_ptr, area_size);
	if (ring_fd >= 0)
		close(ring_fd);
	return ret;
}

static void usage(const char *argv0)
{
	fprintf(stderr,
		"usage: %s [-d SECONDS] [-c CHUNK_KB] [-o FILE] [-i IFACE]\n"
		"  -d  duration seconds (default 10)\n"
		"  -c  recv chunk KiB (default 64)\n"
		"  -i  iface to probe for zcrx (default enp3s0f0; also probes lo)\n"
		"  -o  metrics output file\n",
		argv0);
}

int main(int argc, char **argv)
{
	int duration = 10, chunk_kb = 64;
	const char *out_path = NULL;
	const char *iface = "enp3s0f0";
	int opt;
	uint64_t received = 0, wall_ns = 0;
	int zc_devmem = 0, zc_zcrx = 0, zc_zcrx_lo = 0;
	int err_devmem = 0, err_zcrx = 0, err_zcrx_lo = 0;
	FILE *out = stdout;
	FILE *mout = NULL;
	size_t chunk;

	while ((opt = getopt(argc, argv, "d:c:o:i:h")) != -1) {
		switch (opt) {
		case 'd':
			duration = atoi(optarg);
			break;
		case 'c':
			chunk_kb = atoi(optarg);
			break;
		case 'o':
			out_path = optarg;
			break;
		case 'i':
			iface = optarg;
			break;
		default:
			usage(argv[0]);
			return 2;
		}
	}
	if (duration <= 0 || chunk_kb <= 0) {
		fprintf(stderr, "bad args\n");
		return 2;
	}
	chunk = (size_t)chunk_kb * 1024;

	if (out_path) {
		mout = fopen(out_path, "w");
		if (!mout) {
			perror("fopen metrics");
			return 1;
		}
		out = mout;
	}

	zc_devmem = probe_msg_sock_devmem(&err_devmem);
	zc_zcrx = probe_zcrx_ifq(iface, &err_zcrx);
	zc_zcrx_lo = probe_zcrx_ifq("lo", &err_zcrx_lo);

	if (classic_recv_bench(duration, chunk, 0, &received, &wall_ns) != 0) {
		fprintf(stderr, "classic_recv_bench failed\n");
		if (mout)
			fclose(mout);
		return 1;
	}

	{
		double sec = (double)wall_ns / 1e9;
		double bps = (double)received / (sec > 0 ? sec : 1.0);
		int zc_avail = (zc_devmem || zc_zcrx) ? 1 : 0;

		fprintf(out, "wl_engine=tcp_recv_zc\n");
		fprintf(out, "wl_path=classic_recv\n");
		fprintf(out, "wl_duration_sec=%d\n", duration);
		fprintf(out, "wl_chunk_kb=%d\n", chunk_kb);
		fprintf(out, "wl_recv_bytes=%llu\n",
			(unsigned long long)received);
		fprintf(out, "wl_wall_ns=%llu\n", (unsigned long long)wall_ns);
		fprintf(out, "wl_bytes_per_sec=%.0f\n", bps);
		fprintf(out, "wl_zc_available=%d\n", zc_avail);
		fprintf(out, "wl_zc_devmem=%d\n", zc_devmem);
		fprintf(out, "wl_zc_devmem_errno=%d\n", err_devmem);
		fprintf(out, "wl_zc_zcrx_iface=%d\n", zc_zcrx);
		fprintf(out, "wl_zc_zcrx_iface_errno=%d\n", err_zcrx);
		fprintf(out, "wl_zc_zcrx_lo=%d\n", zc_zcrx_lo);
		fprintf(out, "wl_zc_zcrx_lo_errno=%d\n", err_zcrx_lo);
		fprintf(out, "wl_probe_iface=%s\n", iface);
		fprintf(out,
			"wl_note=zc_needs_nic_hds_memory_provider_flow_steer\n");
		fflush(out);
		if (mout) {
			printf("wl_recv_bytes=%llu wl_bytes_per_sec=%.0f wl_zc_available=%d\n",
			       (unsigned long long)received, bps, zc_avail);
		}
	}

	if (mout)
		fclose(mout);
	return 0;
}
