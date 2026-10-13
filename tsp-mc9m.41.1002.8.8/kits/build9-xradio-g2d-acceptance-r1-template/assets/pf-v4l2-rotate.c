// SPDX-License-Identifier: MIT
/* Public V4L2 mem2mem exerciser for the sun8i rotate driver. */
#include <errno.h>
#include <dirent.h>
#include <fcntl.h>
#include <inttypes.h>
#include <linux/videodev2.h>
#include <poll.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

#define SW 1280u
#define SH 720u
#define PIXELS (SW * SH)

struct mapping { void *p; size_t n; };
struct buffer_pool { struct mapping *maps; unsigned requested, returned; };
struct buffer_counts { unsigned output_requested, output_returned, capture_requested, capture_returned; };
struct sample { uint64_t us; int error; };
struct tar_header {
	char name[100], mode[8], uid[8], gid[8], size[12], mtime[12], chksum[8];
	char typeflag, linkname[100], magic[6], version[2], uname[32], gname[32];
	char devmajor[8], devminor[8], prefix[155], padding[12];
};
struct device_info { const char *node; char driver[17], card[33], bus[33]; uint32_t caps; };
struct transform { const char *name; int rotate, hf, vf; };
static const struct transform transforms[] = {
	{"identity", 0, 0, 0}, {"rotate90", 90, 0, 0},
	{"rotate180", 180, 0, 0}, {"rotate270", 270, 0, 0},
	{"hflip", 0, 1, 0}, {"vflip", 0, 0, 1}, {"hvflip", 0, 1, 1},
};

static int output_error(const char *reason)
{
	fprintf(stderr, "PF_V4L2_ROTATE state=error stage=output_prepare reason=%s\n", reason);
	return -1;
}

static void report_errno(const char *step, const char *name, const char *reason, int error)
{
	fprintf(stderr, "PF_V4L2_ROTATE_FAIL step=%s case=%s reason=%s detail=errno_%d\n",
		step, name, reason, error ? error : EIO);
}

static void report_count(const char *step, const char *name, const char *reason, uint64_t count)
{
	fprintf(stderr, "PF_V4L2_ROTATE_FAIL step=%s case=%s reason=%s detail=count_%" PRIu64 "\n",
		step, name, reason, count);
}

static int prepare_output(const char *path)
{
	DIR *dir;
	struct dirent *entry;

	if (!mkdir(path, 0755))
		return 0;
	if (errno != EEXIST)
		return output_error("create_failed");
	dir = opendir(path);
	if (!dir)
		return output_error("not_directory");
	errno = 0;
	while ((entry = readdir(dir))) {
		if (strcmp(entry->d_name, ".") && strcmp(entry->d_name, "..")) {
			closedir(dir);
			return output_error("not_empty");
		}
	}
	if (errno || closedir(dir))
		return output_error("inspect_failed");
	return 0;
}

static int xioctl(int fd, unsigned long op, void *arg)
{
	int rc;
	do rc = ioctl(fd, op, arg); while (rc < 0 && errno == EINTR);
	return rc;
}

static void pixel(uint8_t *p, unsigned x, unsigned y)
{
	p[0] = (x * 13 + y * 7) & 255;
	p[1] = (x * 5 + y * 11) & 255;
	p[2] = (x * 17 + y * 3) & 255;
	p[3] = 255;
}

static void source(uint8_t *p)
{
	for (unsigned y = 0; y < SH; y++)
		for (unsigned x = 0; x < SW; x++) pixel(p + ((size_t)y * SW + x) * 4, x, y);
}

static void dims(const struct transform *t, unsigned *w, unsigned *h)
{
	*w = (t->rotate == 90 || t->rotate == 270) ? SH : SW;
	*h = (t->rotate == 90 || t->rotate == 270) ? SW : SH;
}

static void coordinates(const struct transform *t, unsigned x, unsigned y, unsigned *sx, unsigned *sy)
{
	if (t->rotate == 90) { *sx = y; *sy = SH - 1 - x; }
	else if (t->rotate == 180) { *sx = SW - 1 - x; *sy = SH - 1 - y; }
	else if (t->rotate == 270) { *sx = SW - 1 - y; *sy = x; }
	else { *sx = x; *sy = y; }
	if (t->hf) *sx = SW - 1 - *sx;
	if (t->vf) *sy = SH - 1 - *sy;
}

static uint64_t reference(uint8_t *dst, const struct transform *t)
{
	unsigned w, h, sx, sy;
	dims(t, &w, &h);
	for (unsigned y = 0; y < h; y++) for (unsigned x = 0; x < w; x++) {
		coordinates(t, x, y, &sx, &sy);
		pixel(dst + ((size_t)y * w + x) * 4, sx, sy);
	}
	return (uint64_t)w * h;
}

static uint64_t compare_rgb(const uint8_t *a, const uint8_t *b, size_t pixels)
{
	uint64_t n = 0;
	for (size_t i = 0; i < pixels; i++) if (memcmp(a + i * 4, b + i * 4, 3)) n++;
	return n;
}

static int write_file(const char *dir, const char *name, const void *p, size_t n)
{
	char path[512]; FILE *f; int error = 0;
	if (snprintf(path, sizeof(path), "%s/%s", dir, name) >= (int)sizeof(path)) {
		errno = ENAMETOOLONG;
		return -1;
	}
	f = fopen(path, "wb");
	if (!f) return -1;
	if (fwrite(p, 1, n, f) != n)
		error = errno ? errno : EIO;
	if (fclose(f) && !error)
		error = errno ? errno : EIO;
	if (error) {
		errno = error;
		return -1;
	}
	return 0;
}

static void tar_octal(char *field, size_t size, uint64_t value)
{
	snprintf(field, size, "%0*llo", (int)size - 1, (unsigned long long)value);
}

static int archive_results(const char *out, const uint8_t *all, size_t n)
{
	char path[512];
	struct tar_header header = {0};
	unsigned char zeros[1024] = {0};
	FILE *file;
	unsigned checksum = 0;
	size_t padding;
	int error = 0;

	if (sizeof(header) != 512 ||
	    snprintf(path, sizeof(path), "%s/rotate-results.tar", out) >= (int)sizeof(path)) {
		errno = sizeof(header) != 512 ? EPROTO : ENAMETOOLONG;
		return -1;
	}
	snprintf(header.name, sizeof(header.name), "rotate-results");
	tar_octal(header.mode, sizeof(header.mode), 0644);
	tar_octal(header.uid, sizeof(header.uid), 0);
	tar_octal(header.gid, sizeof(header.gid), 0);
	tar_octal(header.size, sizeof(header.size), n);
	tar_octal(header.mtime, sizeof(header.mtime), 0);
	memset(header.chksum, ' ', sizeof(header.chksum));
	header.typeflag = '0';
	memcpy(header.magic, "ustar", 5);
	memcpy(header.version, "00", 2);
	for (size_t i = 0; i < sizeof(header); i++)
		checksum += ((const unsigned char *)&header)[i];
	snprintf(header.chksum, 7, "%06o", checksum);
	header.chksum[6] = '\0';
	header.chksum[7] = ' ';
	file = fopen(path, "wb");
	if (!file)
		return -1;
	padding = (512 - (n % 512)) % 512;
	if (fwrite(&header, 1, sizeof(header), file) != sizeof(header) ||
	    fwrite(all, 1, n, file) != n ||
	    (padding && fwrite(zeros, 1, padding, file) != padding) ||
	    fwrite(zeros, 1, sizeof(zeros), file) != sizeof(zeros))
		error = errno ? errno : EIO;
	if (fclose(file) && !error)
		error = errno ? errno : EIO;
	if (error) {
		errno = error;
		return -1;
	}
	return 0;
}

static uint64_t now_ns(void)
{
	struct timespec ts; clock_gettime(CLOCK_MONOTONIC, &ts);
	return (uint64_t)ts.tv_sec * 1000000000ull + ts.tv_nsec;
}

static int setup_format(int fd, enum v4l2_buf_type type, unsigned w, unsigned h)
{
	struct v4l2_format f = {.type = type};
	f.fmt.pix.width = w; f.fmt.pix.height = h; f.fmt.pix.pixelformat = V4L2_PIX_FMT_XRGB32;
	f.fmt.pix.field = V4L2_FIELD_NONE; f.fmt.pix.bytesperline = w * 4; f.fmt.pix.sizeimage = w * h * 4;
	return xioctl(fd, VIDIOC_S_FMT, &f);
}

static int map_buffers(int fd, enum v4l2_buf_type type, struct buffer_pool *pool)
{
	struct v4l2_requestbuffers req = {.count = 1, .type = type, .memory = V4L2_MEMORY_MMAP};
	pool->requested = req.count;
	if (xioctl(fd, VIDIOC_REQBUFS, &req)) return -1;
	pool->returned = req.count;
	if (!req.count) { errno = EPROTO; return -1; }
	pool->maps = calloc(req.count, sizeof(*pool->maps));
	if (!pool->maps) { errno = ENOMEM; return -1; }
	for (unsigned i = 0; i < req.count; i++) {
		struct v4l2_buffer b = {.index = i, .type = type, .memory = V4L2_MEMORY_MMAP};
		if (xioctl(fd, VIDIOC_QUERYBUF, &b)) return -1;
		pool->maps[i].n = b.length;
		pool->maps[i].p = mmap(NULL, b.length, PROT_READ | PROT_WRITE,
					 MAP_SHARED, fd, b.m.offset);
		if (pool->maps[i].p == MAP_FAILED)
			return -1;
	}
	return 0;
}

static void unmap_buffers(struct buffer_pool *pool)
{
	if (pool->maps) {
		for (unsigned i = 0; i < pool->returned; i++)
			if (pool->maps[i].p && pool->maps[i].p != MAP_FAILED)
				munmap(pool->maps[i].p, pool->maps[i].n);
	}
	free(pool->maps);
	pool->maps = NULL;
}

static int queue_buffers(int fd, enum v4l2_buf_type type, struct buffer_pool *pool,
			 const uint8_t *src)
{
	for (unsigned i = 0; i < pool->returned; i++) {
		struct v4l2_buffer b = {.index = i, .type = type, .memory = V4L2_MEMORY_MMAP};
		if (src) {
			if (pool->maps[i].n < PIXELS * 4) { errno = EPROTO; return -1; }
			memcpy(pool->maps[i].p, src, PIXELS * 4);
			b.bytesused = PIXELS * 4;
		}
		if (xioctl(fd, VIDIOC_QBUF, &b))
			return -1;
	}
	return 0;
}

static int control(int fd, uint32_t id, int value)
{
	struct v4l2_control c = {.id = id, .value = value}; return xioctl(fd, VIDIOC_S_CTRL, &c);
}

static int dequeue(int fd, struct v4l2_buffer *b, short event)
{
	struct pollfd pfd = {.fd = fd, .events = event};
	uint64_t deadline = now_ns() + 1000000000ull;
	for (;;) {
		if (!xioctl(fd, VIDIOC_DQBUF, b)) return 0;
		if (errno != EAGAIN) return -1;
		uint64_t now = now_ns();
		if (now >= deadline) { errno = ETIMEDOUT; return -1; }
		int ms = (int)((deadline - now + 999999ull) / 1000000ull);
		int rc = poll(&pfd, 1, ms);
		if (rc < 0 && errno == EINTR) continue;
		if (rc <= 0 || (pfd.revents & (POLLERR | POLLHUP | POLLNVAL))) return -1;
	}
}

static int one_live(int fd, const struct transform *t, const uint8_t *src, uint8_t *dst,
			unsigned *dw, unsigned *dh, uint64_t *elapsed, int *failure_errno,
			struct buffer_counts *counts)
{
	struct buffer_pool output = {0}, capture = {0};
	enum v4l2_buf_type ot = V4L2_BUF_TYPE_VIDEO_OUTPUT, ct = V4L2_BUF_TYPE_VIDEO_CAPTURE;
	struct v4l2_buffer ob = {.type = ot, .memory = V4L2_MEMORY_MMAP}, cb = {.type = ct, .memory = V4L2_MEMORY_MMAP};
	bool os = false, cs = false; int rc = -1, error = 0;
	*failure_errno = 0;
	dims(t, dw, dh);
	if (setup_format(fd, ot, SW, SH) || control(fd, V4L2_CID_ROTATE, t->rotate) ||
	    control(fd, V4L2_CID_HFLIP, t->hf) || control(fd, V4L2_CID_VFLIP, t->vf) ||
	    setup_format(fd, ct, *dw, *dh) || map_buffers(fd, ot, &output) ||
	    map_buffers(fd, ct, &capture)) {
		error = errno ? errno : EIO;
		goto done;
	}
	counts->output_requested = output.requested;
	counts->output_returned = output.returned;
	counts->capture_requested = capture.requested;
	counts->capture_returned = capture.returned;
	uint64_t start = now_ns();
	if (queue_buffers(fd, ot, &output, src) || queue_buffers(fd, ct, &capture, NULL) ||
	    xioctl(fd, VIDIOC_STREAMON, &ot)) {
		error = errno ? errno : EIO;
		goto done;
	}
	os = true;
	if (xioctl(fd, VIDIOC_STREAMON, &ct)) {
		error = errno ? errno : EIO;
		goto done;
	}
	cs = true;
	if (dequeue(fd, &cb, POLLIN) || dequeue(fd, &ob, POLLOUT)) {
		error = errno ? errno : EIO;
		goto done;
	}
	if (cb.index >= capture.returned ||
	    capture.maps[cb.index].n < (size_t)*dw * *dh * 4 || ob.index >= output.returned) {
		error = EPROTO;
		goto done;
	}
	*elapsed = (now_ns() - start) / 1000;
	memcpy(dst, capture.maps[cb.index].p, (size_t)*dw * *dh * 4);
	rc = 0;
done:
	if (cs && xioctl(fd, VIDIOC_STREAMOFF, &ct)) {
		if (!error) error = errno ? errno : EIO;
		rc = -1;
	}
	if (os && xioctl(fd, VIDIOC_STREAMOFF, &ot)) {
		if (!error) error = errno ? errno : EIO;
		rc = -1;
	}
	unmap_buffers(&output);
	unmap_buffers(&capture);
	struct v4l2_requestbuffers z1 = {.type = ot, .memory = V4L2_MEMORY_MMAP};
	struct v4l2_requestbuffers z2 = {.type = ct, .memory = V4L2_MEMORY_MMAP};
	if (xioctl(fd, VIDIOC_REQBUFS, &z1) || xioctl(fd, VIDIOC_REQBUFS, &z2)) {
		if (!error) error = errno ? errno : EIO;
		rc = -1;
	}
	if (rc && !error) error = EIO;
	*failure_errno = error;
	return rc;
}

static int cmp_sample(const void *a, const void *b)
{
	uint64_t x = ((const struct sample *)a)->us, y = ((const struct sample *)b)->us;
	return x > y ? 1 : x < y ? -1 : 0;
}

static int receipt(const char *out, const struct device_info *info, uint64_t mismatch[7],
		   uint64_t neg[3], const struct sample samples[100], int errors,
		   int latency_errors,
		   const struct buffer_counts *counts)
{
	char path[512]; FILE *f; uint64_t sum = 0; int error = 0;
	struct sample sorted[100];
	memcpy(sorted, samples, sizeof(sorted));
	qsort(sorted, 100, sizeof(*sorted), cmp_sample);
	for (int i = 0; i < 100; i++) sum += sorted[i].us;
	if (snprintf(path, sizeof(path), "%s/rotate-receipt.tsv", out) >= (int)sizeof(path)) {
		errno = ENAMETOOLONG;
		return -1;
	}
	f = fopen(path, "w");
	if (!f) return -1;
	fprintf(f, "result\t%s\n", errors ? "fail" : "pass");
	fprintf(f, "node\t%s\ndriver\t%s\ncard\t%s\nbus\t%s\ndevice_caps\t0x%08" PRIx32 "\n",
		info->node, info->driver, info->card, info->bus, info->caps);
	fprintf(f, "output_buffers_requested\t%u\noutput_buffers_returned\t%u\n"
		"capture_buffers_requested\t%u\ncapture_buffers_returned\t%u\n",
		counts->output_requested, counts->output_returned,
		counts->capture_requested, counts->capture_returned);
	for (size_t i = 0; i < 7; i++) fprintf(f, "%s_mismatches\t%" PRIu64 "\n", transforms[i].name, mismatch[i]);
	fprintf(f, "shifted_negative_mismatches\t%" PRIu64 "\nrb_swapped_negative_mismatches\t%" PRIu64 "\nwrong_direction_negative_mismatches\t%" PRIu64 "\n", neg[0], neg[1], neg[2]);
	fprintf(f, "latency_samples\t100\nlatency_median_us\t%" PRIu64 "\nlatency_p95_us\t%" PRIu64 "\nlatency_max_us\t%" PRIu64 "\nlatency_errors\t%d\n",
		sorted[50].us, sorted[94].us, sorted[99].us, latency_errors);
	for (int i = 0; i < 100; i++) {
		fprintf(f, "latency_sample_%03d_us\t%" PRIu64 "\n", i, samples[i].us);
		if (samples[i].error) {
			fprintf(f, "latency_sample_%03d_error_errno\t%d\n", i, samples[i].error);
			fprintf(f, "latency_sample_%03d_error_kind\t%s\n", i,
				samples[i].error == ETIMEDOUT ? "timeout" : "errno");
		}
	}
	fprintf(f, "bytes_per_frame\t7372800\nthroughput_mib_s\t%.3f\n",
		sum ? ((double)PIXELS * 8.0 * 100.0 * 1000000.0 / (1048576.0 * (double)sum)) : 0.0);
	if (ferror(f))
		error = errno ? errno : EIO;
	if (fclose(f) && !error)
		error = errno ? errno : EIO;
	if (error) {
		errno = error;
		return -1;
	}
	return 0;
}

int main(int argc, char **argv)
{
	const char *dev = NULL, *out = NULL, *fixture = NULL;
	for (int i = 1; i < argc; i++) {
		if (i + 1 < argc && !strcmp(argv[i], "--device")) dev = argv[++i];
		else if (i + 1 < argc && !strcmp(argv[i], "--out")) out = argv[++i];
		else if (i + 1 < argc && !strcmp(argv[i], "--fixture")) fixture = argv[++i];
		else {
			fprintf(stderr, "PF_V4L2_ROTATE state=error stage=arguments reason=invalid\n");
			return 2;
		}
	}
	if (!out || (!dev && !fixture) || (fixture && strcmp(fixture, "pass"))) {
		fprintf(stderr, "PF_V4L2_ROTATE state=error stage=arguments reason=invalid\n");
		return 2;
	}
	if (prepare_output(out))
		return 2;
	uint8_t *src = malloc(PIXELS * 4), *actual = malloc(PIXELS * 4), *ref = malloc(PIXELS * 4);
	uint8_t *archive = malloc(7ull * PIXELS * 4); uint64_t mismatch[7] = {0}, neg[3] = {0};
	struct sample samples[100] = {{0}}; int errors = 0, latency_errors = 0, fd = -1;
	size_t archive_n = 0;
	struct buffer_counts counts = {0};
	struct device_info info = {.node = fixture ? "fixture" : dev, .driver = "fixture", .card = "fixture", .bus = "fixture"};
	if (!src || !actual || !ref || !archive) {
		report_errno("allocate", "all", "memory", ENOMEM);
		return 1;
	}
	source(src);
	if (!fixture) {
		struct v4l2_capability cap = {0};
		fd = open(dev, O_RDWR | O_CLOEXEC | O_NONBLOCK);
		if (fd < 0) {
			report_errno("open", "all", "device", errno);
			return 1;
		}
		if (xioctl(fd, VIDIOC_QUERYCAP, &cap)) {
			report_errno("querycap", "all", "ioctl", errno);
			return 1;
		}
		snprintf(info.driver, sizeof(info.driver), "%s", (char *)cap.driver);
		snprintf(info.card, sizeof(info.card), "%s", (char *)cap.card);
		snprintf(info.bus, sizeof(info.bus), "%s", (char *)cap.bus_info);
		info.caps = cap.device_caps ? cap.device_caps : cap.capabilities;
	}
	for (size_t i = 0; i < 7; i++) {
		unsigned w, h; uint64_t us = 0; int live_errno = 0;
		dims(&transforms[i], &w, &h); size_t n = (size_t)w * h * 4;
		reference(ref, &transforms[i]);
		if (fixture) memcpy(actual, ref, n);
		else if (one_live(fd, &transforms[i], src, actual, &w, &h, &us, &live_errno,
				  &counts)) {
			report_errno("transform", transforms[i].name, "one_live", live_errno);
			errors++;
			memset(actual, 0, n);
		}
		mismatch[i] = compare_rgb(actual, ref, (size_t)w * h);
		char name[80]; snprintf(name, sizeof(name), "%s.xrgb", transforms[i].name);
		if (write_file(out, name, actual, n)) {
			int error = errno;
			report_errno("output", transforms[i].name, "write", error);
			errors++;
		}
		memcpy(archive + archive_n, actual, n); archive_n += n;
	}
	/* Controls operate on identity; the wrong-direction control compares 90 with 270. */
	reference(actual, &transforms[0]); reference(ref, &transforms[0]);
	for (unsigned y = 0; y < SH; y++) for (unsigned x = 0; x < SW; x++) {
		unsigned sx = (x + 1) % SW; if (memcmp(actual + ((size_t)y * SW + x) * 4, ref + ((size_t)y * SW + sx) * 4, 3)) neg[0]++;
		uint8_t *p = actual + ((size_t)y * SW + x) * 4; uint8_t *q = ref + ((size_t)y * SW + x) * 4; if (p[0] != q[2] || p[1] != q[1] || p[2] != q[0]) neg[1]++;
	}
	reference(actual, &transforms[1]); reference(ref, &transforms[3]); neg[2] = compare_rgb(actual, ref, PIXELS);
	for (int i = 0; i < 100; i++) {
		if (fixture) samples[i].us = 3000 + i;
		else {
			unsigned w, h; int live_errno = 0;
			if (one_live(fd, &transforms[1], src, actual, &w, &h,
				     &samples[i].us, &live_errno, &counts)) {
				char sample_name[32];
				snprintf(sample_name, sizeof(sample_name), "latency_%03d", i);
				samples[i].error = live_errno ? live_errno : EIO;
				report_errno("timing", sample_name, "one_live", samples[i].error);
				latency_errors++;
				errors++;
			}
		}
	}
	if (fd >= 0)
		close(fd);
	if (archive_results(out, archive, archive_n)) {
		int error = errno;
		report_errno("archive", "all", "write_tar", error);
		errors++;
	}
	for (size_t i = 0; i < 7; i++) if (mismatch[i]) {
		report_count("compare", transforms[i].name, "pixel_mismatch", mismatch[i]);
		errors++;
	}
	static const char *negative_names[] = {"shifted", "rb_swapped", "wrong_direction"};
	for (size_t i = 0; i < 3; i++) if (!neg[i]) {
		report_count("negative_control", negative_names[i], "unexpected_match", neg[i]);
		errors++;
	}
	if (receipt(out, &info, mismatch, neg, samples, errors, latency_errors, &counts)) {
		int error = errno;
		report_errno("receipt", "all", "write", error);
		errors++;
	}
	free(src); free(actual); free(ref); free(archive); return errors ? 1 : 0;
}
