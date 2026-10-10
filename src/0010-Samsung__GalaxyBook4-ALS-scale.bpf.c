// SPDX-License-Identifier: GPL-2.0-only
/*
 * Samsung Galaxy Book4 Ultra: the ISH ambient light sensor declares its
 * illuminance field with unit exponent -3 (milli-lux), but the values it
 * sends are about ten times too small (covered 0.8, lit room ~5, phone
 * flashlight at a few cm ~830 "lux"). KWin's automatic brightness curve
 * cannot work in such a narrow range, so declare the field as 10^-2 instead.
 *
 * Only the illuminance usage (0x04d1) is touched; colour temperature and
 * chromaticity share exponent -3 and are correct as they are.
 */

#include "vmlinux.h"
#include "hid_bpf.h"
#include "hid_bpf_helpers.h"
#include <bpf/bpf_tracing.h>

#define VID_INTEL 0x8087
#define PID_ISH_SENSOR_HUB 0x0AC2

#define RDESC_SIZE 1230
/* offset of the Unit Exponent item (0x55) of each illuminance field */
#define ALS_EXP_ITEM_1 418
#define ALS_EXP_ITEM_2 1161

#define EXP_MINUS_3 0x0d
#define EXP_MINUS_2 0x0e

HID_BPF_CONFIG(
	HID_DEVICE(BUS_INTEL_ISHTP, HID_GROUP_SENSOR_HUB, VID_INTEL, PID_ISH_SENSOR_HUB)
);

static __always_inline void fix_exponent(__u8 *data, const int item)
{
	/* Usage (0x04d1, illuminance) sits 17 bytes before its Unit Exponent */
	if (data[item - 17] == 0x0a && data[item - 16] == 0xd1 && data[item - 15] == 0x04 &&
	    data[item] == 0x55 && data[item + 1] == EXP_MINUS_3)
		data[item + 1] = EXP_MINUS_2;
}

SEC(HID_BPF_RDESC_FIXUP)
int BPF_PROG(galaxybook_als_fix_rdesc, struct hid_bpf_ctx *hctx)
{
	__u8 *data = hid_bpf_get_data(hctx, 0 /* offset */, 4096 /* size */);

	if (!data)
		return 0; /* EPERM check */

	fix_exponent(data, ALS_EXP_ITEM_1);
	fix_exponent(data, ALS_EXP_ITEM_2);

	return 0;
}

HID_BPF_OPS(galaxybook_als_scale) = {
	.hid_rdesc_fixup = (void *)galaxybook_als_fix_rdesc,
};

SEC("syscall")
int probe(struct hid_bpf_probe_args *ctx)
{
	ctx->retval = ctx->rdesc_size != RDESC_SIZE;
	if (ctx->retval)
		ctx->retval = -EINVAL;

	return 0;
}

char _license[] SEC("license") = "GPL";
