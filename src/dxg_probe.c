/*
 * dxg_probe.c - prove the GPU-PV kernel path without root and without nvidia-smi.
 *
 * Build: gcc -O0 -o /tmp/dxg_probe dxg_probe.c -I<dxgkrnl source tree>/include/uapi/misc
 *        (the tree path is  /usr/src/dxgkrnl-<hash>  - see gpupv.sh probe)
 * Run:   /tmp/dxg_probe            (any user: /dev/dxg is mode 0666)
 *
 * Why: once dxgkrnl loads, nvidia-smi cannot tell you whether the failure is
 * the kernel/host link, the DXCore layer, or the userland payload under
 * /usr/lib/wsl/drivers.
 *
 * Reads, in order of what they prove:
 *   enum2/enum3 count >= 1, open_adapter ret=0
 *       module -> VMBus channel -> host GPU partition are all live. From here
 *       a CUDA/NVML failure can only be userland-side; stop touching the kernel.
 *   QUERYADAPTERINFO type 15 / 57  (ADAPTERTYPE / ADAPTERTYPE_RENDER)
 *       value 0x81 = render + paravirtual, i.e. a real paravirtual render device.
 *   QUERYADAPTERINFO type 0  (_KMTQAITYPE_UMDRIVERPRIVATE)
 *       How libdxcore asks for the adapter's private description (driver-store
 *       path and friends). It is SIZE-SENSITIVE: the host only answers the
 *       exact structure size the caller uses (libcuda sends ~9308 and ~49559
 *       bytes and gets a buffer starting with the ASCII magic "NVDA" =
 *       0x4e564441). Any other size returns EINVAL, so EINVAL in the two probes
 *       below is expected and proves nothing about DXCore or the host — do not
 *       read it as "the branch is wrong".
 *
 * Uses the module's own uapi header on purpose (struct layouts and LX_DX* ioctl
 * numbers come from dxgkrnl itself), so the probe stays in sync with whatever
 * module the guest happens to be running.
 */
#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <fcntl.h>
#include <errno.h>
#include <unistd.h>
#include <sys/ioctl.h>
#include <linux/types.h>

#include "d3dkmthk.h"

static void dump_type(const char *tag, const struct d3dkmt_adaptertype *t)
{
	printf("%s value=0x%08x render=%u display=%u software=%u paravirt=%u "
	       "compute_only=%u prototype=%u\n", tag, t->value,
	       t->render_supported, t->display_supported, t->software_device,
	       t->paravirtualized, t->compute_only, t->prototype);
}

int main(void)
{
	int fd = open("/dev/dxg", O_RDWR);
	if (fd < 0) {
		printf("open /dev/dxg failed: %s\n", strerror(errno));
		printf("RESULT: module not loaded or no adapter - see skill sections 2/3/5\n");
		return 1;
	}

	struct d3dkmt_adapterinfo info[D3DKMT_ADAPTERS_MAX];
	struct d3dkmt_enumadapters2 ea;
	memset(info, 0, sizeof(info));
	memset(&ea, 0, sizeof(ea));
	ea.num_adapters = D3DKMT_ADAPTERS_MAX;
	ea.adapters = (__u64 *)info;

	int ret = ioctl(fd, LX_DXENUMADAPTERS2, &ea);
	printf("enum_adapters ret=%d errno=%s num_adapters=%u\n",
	       ret, ret ? strerror(errno) : "-", ea.num_adapters);
	if (ret || !ea.num_adapters) {
		printf("RESULT: no adapter started (kernel/host side)\n");
		close(fd);
		return 2;
	}

	for (unsigned i = 0; i < ea.num_adapters && i < D3DKMT_ADAPTERS_MAX; i++)
		printf("  adapter[%u] handle=%08x luid=%08x-%08x num_sources=%u\n",
		       i, info[i].adapter_handle.v,
		       info[i].adapter_luid.a, info[i].adapter_luid.b,
		       info[i].num_sources);

	/* Newer DXCore / libcuda enumerate through the filtered variant too. */
	struct d3dkmt_adapterinfo i3[D3DKMT_ADAPTERS_MAX];
	struct d3dkmt_enumadapters3 e3;
	memset(i3, 0, sizeof(i3));
	memset(&e3, 0, sizeof(e3));
	e3.adapter_count = D3DKMT_ADAPTERS_MAX;
	e3.adapters = (__u64)i3;
	e3.filter.value = 0;
	int r3 = ioctl(fd, LX_DXENUMADAPTERS3, &e3);
	printf("enum_adapters3 ret=%d errno=%s count=%u\n",
	       r3, r3 ? strerror(errno) : "-", e3.adapter_count);

	struct d3dkmt_openadapterfromluid oa;
	memset(&oa, 0, sizeof(oa));
	oa.adapter_luid = info[0].adapter_luid;

	ret = ioctl(fd, LX_DXOPENADAPTERFROMLUID, &oa);
	printf("open_adapter ret=%d errno=%s handle=%08x\n",
	       ret, ret ? strerror(errno) : "-", oa.adapter_handle.v);
	if (ret) {
		close(fd);
		return 3;
	}

	const enum kmtqueryadapterinfotype types[] = {
		_KMTQAITYPE_ADAPTERTYPE,
		_KMTQAITYPE_ADAPTERTYPE_RENDER,
	};
	for (unsigned i = 0; i < sizeof(types) / sizeof(types[0]); i++) {
		struct d3dkmt_adaptertype at;
		struct d3dkmt_queryadapterinfo q;
		memset(&at, 0, sizeof(at));
		memset(&q, 0, sizeof(q));
		q.adapter = oa.adapter_handle;
		q.type = types[i];
		q.private_data = (__u64)&at;
		q.private_data_size = sizeof(at);
		errno = 0;
		int r = ioctl(fd, LX_DXQUERYADAPTERINFO, &q);
		if (r) {
			printf("query type=%d ret=%d errno=%s\n", types[i], r,
			       strerror(errno));
			continue;
		}
		char tag[32];
		snprintf(tag, sizeof(tag), "query type=%d:", types[i]);
		dump_type(tag, &at);
	}

	size_t sizes[] = { 4096, 65536 };
	for (unsigned i = 0; i < sizeof(sizes) / sizeof(sizes[0]); i++) {
		void *buf = calloc(1, sizes[i]);
		struct d3dkmt_queryadapterinfo q;
		memset(&q, 0, sizeof(q));
		q.adapter = oa.adapter_handle;
		q.type = _KMTQAITYPE_UMDRIVERPRIVATE;
		q.private_data = (__u64)buf;
		q.private_data_size = sizes[i];
		errno = 0;
		int r = ioctl(fd, LX_DXQUERYADAPTERINFO, &q);
		printf("query UMDRIVERPRIVATE size=%-6zu ret=%d errno=%s"
		       "%s",
		       sizes[i], r, r ? strerror(errno) : "-",
		       r ? "  (EINVAL = wrong size; not a fault)" : "");
		if (!r)
			printf(" used=%u first4=%02x%02x%02x%02x", q.private_data_size,
			       ((unsigned char *)buf)[0], ((unsigned char *)buf)[1],
			       ((unsigned char *)buf)[2], ((unsigned char *)buf)[3]);
		printf("\n");
		free(buf);
	}

	struct d3dkmt_closeadapter ca;
	memset(&ca, 0, sizeof(ca));
	ca.adapter_handle = oa.adapter_handle;
	int rc = ioctl(fd, LX_DXCLOSEADAPTER, &ca);
	printf("close_adapter ret=%d errno=%s\n", rc, rc ? strerror(errno) : "-");
	printf("RESULT: kernel path OK. If nvidia-smi still fails, check whether a "
	       "payload under /usr/lib/wsl/drivers is loaded at all "
	       "(LD_DEBUG=files) before replacing libs.\n");
	close(fd);
	return 0;
}
