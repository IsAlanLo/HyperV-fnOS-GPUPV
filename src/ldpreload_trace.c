/*
 * ldpreload_trace.c — who is actually failing: loader, payload, DXCore or kernel.
 *
 * Build:
 *   gcc -shared -fPIC -O0 -o /tmp/trace.so scripts/ldpreload_trace.c -ldl
 * Run:
 *   LD_PRELOAD=/tmp/trace.so nvidia-smi 2>&1 | grep -E '^\[(dlopen|open|mmap|dxg|escape)'
 *   LD_PRELOAD=/tmp/trace.so python3 -c "import ctypes;ctypes.CDLL('libcuda.so.1').cuInit(0)"
 *
 * What each line is for:
 *   [dlopen] … -> FAIL      the exact library path the stack wanted and did not
 *                           get. This is how the missing driver-store folder
 *                           (…/drivers/nv_dispi.inf_amd64_<hash>/libfoo) shows up.
 *   [open]   … -> -1 …      missing device/files (e.g. /dev/nvidia-uvm, which is
 *                           absent on working WSL too — check before believing it).
 *   [mmap]                  mappings of /dev/dxg; a FAIL here means the BAR/MMIO
 *                           side is broken, not the userland.
 *   [dxg] nr=0x..           every dxg ioctl with its return code (0x3e enum3,
 *                           0x09 query, 0x02 createdevice, 0x0d escape, …).
 *   [escape] changed=N …    NVAPI driver-private escape: how many bytes the host
 *                           wrote back and where. changed=0 means the host did not
 *                           answer; a plausible healthy answer is ~146 bytes and
 *                           the same signature inside the host's WSL.
 *   SIGSEGV backtrace        the crashing return address inside libcuda; the top
 *                           frame being the instruction after a `call *GOT` means
 *                           a NULL function pointer, i.e. an init step was skipped.
 *
 * Read the ORDER, not a single line: the first failing entry is the cause, every
 * later error is fallout. A run that stops before any file under
 * /usr/lib/wsl/drivers is named never reached the payload at all.
 */
#define _GNU_SOURCE
#include <stdarg.h>
#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <dlfcn.h>
#include <fcntl.h>
#include <signal.h>
#include <unistd.h>
#include <execinfo.h>
#include <sys/ioctl.h>
#include <sys/mman.h>

static int (*real_ioctl)(int, unsigned long, void *) = NULL;
static void *(*real_mmap)(void *, size_t, int, int, int, off_t) = NULL;
static int (*real_open)(const char *, int, ...) = NULL;
static int (*real_openat)(int, const char *, int, ...) = NULL;
static void *(*real_dlopen)(const char *, int) = NULL;

struct dxg_escape {
	uint32_t adapter;
	uint32_t device;
	int32_t type;
	uint32_t flags;
	uint64_t data;
	uint32_t size;
	uint32_t context;
};

static int interesting(const char *p)
{
	if (!p)
		return 0;
	return strstr(p, "nvidia") || strstr(p, "dxg") || strstr(p, "gpucomp") ||
	       strstr(p, "nvvm") || strstr(p, "proc/driver") || strstr(p, "dri");
}

static const char *fd_target(int fd, char *buf, size_t n)
{
	char path[64];
	ssize_t r;

	snprintf(path, sizeof(path), "/proc/self/fd/%d", fd);
	r = readlink(path, buf, n - 1);
	if (r < 0)
		return "?";
	buf[r] = 0;
	return buf;
}

void *dlopen(const char *name, int flag)
{
	void *h;

	if (!real_dlopen)
		real_dlopen = dlsym(RTLD_NEXT, "dlopen");
	h = real_dlopen(name, flag);
	if (name)
		fprintf(stderr, "[dlopen] %s -> %s\n", name, h ? "OK" : "FAIL");
	return h;
}

int open(const char *path, int flags, ...)
{
	mode_t mode = 0;
	va_list ap;
	int fd;

	if (!real_open)
		real_open = dlsym(RTLD_NEXT, "open");
	if (flags & O_CREAT) {
		va_start(ap, flags);
		mode = va_arg(ap, int);
		va_end(ap);
	}
	fd = real_open(path, flags, mode);
	if (interesting(path))
		fprintf(stderr, "[open] %s -> %d%s%s\n", path, fd,
			fd < 0 ? " " : "", fd < 0 ? strerror(errno) : "");
	return fd;
}

int openat(int dirfd, const char *path, int flags, ...)
{
	mode_t mode = 0;
	va_list ap;
	int fd;

	if (!real_openat)
		real_openat = dlsym(RTLD_NEXT, "openat");
	if (flags & O_CREAT) {
		va_start(ap, flags);
		mode = va_arg(ap, int);
		va_end(ap);
	}
	fd = real_openat(dirfd, path, flags, mode);
	if (interesting(path))
		fprintf(stderr, "[openat] %s -> %d%s%s\n", path, fd,
			fd < 0 ? " " : "", fd < 0 ? strerror(errno) : "");
	return fd;
}

void *mmap(void *addr, size_t len, int prot, int flags, int fd, off_t off)
{
	void *p;

	if (!real_mmap)
		real_mmap = dlsym(RTLD_NEXT, "mmap");
	p = real_mmap(addr, len, prot, flags, fd, off);
	if (fd >= 0) {
		char buf[256];
		const char *t = fd_target(fd, buf, sizeof(buf));

		if (strstr(t, "dxg"))
			fprintf(stderr,
				"[mmap] fd=%d(%s) len=%zu prot=0x%x off=%lld -> %p%s\n",
				fd, t, len, prot, (long long)off, p,
				p == MAP_FAILED ? " FAIL" : "");
	}
	return p;
}

int ioctl(int fd, unsigned long req, ...)
{
	va_list ap;
	void *arg;
	int ret, saved;
	unsigned nr = _IOC_NR(req);

	va_start(ap, req);
	arg = va_arg(ap, void *);
	va_end(ap);

	if (!real_ioctl)
		real_ioctl = dlsym(RTLD_NEXT, "ioctl");

	if (_IOC_TYPE(req) == 0x47 && nr == 0x0d && arg) {
		struct dxg_escape *e = arg;
		unsigned char *snap = NULL;
		uint32_t sz = e->size;

		if (e->data && sz) {
			snap = malloc(sz);
			if (snap)
				memcpy(snap, (void *)(uintptr_t)e->data, sz);
		}
		ret = real_ioctl(fd, req, arg);
		saved = errno;
		fprintf(stderr, "[escape] type=%d size=%u flags=0x%x ret=%d",
			e->type, sz, e->flags, ret);
		if (snap) {
			unsigned char *now = (unsigned char *)(uintptr_t)e->data;
			unsigned changed = 0, shown = 0, i;

			for (i = 0; i < sz; i++)
				if (snap[i] != now[i])
					changed++;
			fprintf(stderr, " changed=%u", changed);
			for (i = 0; i < sz && shown < 12; i++) {
				if (snap[i] != now[i]) {
					fprintf(stderr, " [%u:%02x>%02x]", i, snap[i], now[i]);
					shown++;
				}
			}
			free(snap);
		}
		fprintf(stderr, "\n");
		errno = saved;
		return ret;
	}

	ret = real_ioctl(fd, req, arg);
	saved = errno;
	if (_IOC_TYPE(req) == 0x47)
		fprintf(stderr, "[dxg] nr=0x%02x ret=%d%s%s\n", nr, ret,
			ret < 0 ? " errno=" : "",
			ret < 0 ? strerror(saved) : "");
	errno = saved;
	return ret;
}

/* ---- crash location ---------------------------------------------------- */

static void on_signal(int sig)
{
	void *bt[40];
	int n;

	(void)sig;
	write(2, "\n=== crash: backtrace (top frame = return address) ===\n", 56);
	n = backtrace(bt, 40);
	backtrace_symbols_fd(bt, n, 2);
	_exit(139);
}

__attribute__((constructor)) static void install_handlers(void)
{
	struct sigaction sa;

	memset(&sa, 0, sizeof(sa));
	sa.sa_handler = on_signal;
	sa.sa_flags = SA_NODEFER;
	sigaction(SIGSEGV, &sa, NULL);
	sigaction(SIGBUS, &sa, NULL);
	sigaction(SIGABRT, &sa, NULL);
}
