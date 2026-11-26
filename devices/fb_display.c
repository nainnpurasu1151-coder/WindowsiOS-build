#include "fb_display.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* RAMFBCfg written by EDK2 QemuRamFbDxe via fw_cfg DMA to "etc/ramfb" (28 bytes, big-endian):
   struct RAMFBCfg {
       uint64_t addr;
       uint32_t fourcc;
       uint32_t flags;
       uint32_t width;
       uint32_t height;
       uint32_t stride;
   } __attribute__((packed));
*/

/* Preferred boot resolution seeded into "etc/ramfb" for EDK2 (see
   hv_fb_display_create). Must stay within the mode sanity limits enforced by
   on_ramfb_write (64..8192 per axis). 2048x1536 is a standard 4:3 mode. */
#define HV_RAMFB_PRESET_WIDTH  2048
#define HV_RAMFB_PRESET_HEIGHT 1536

static uint32_t be32(const uint8_t *p) {
    uint32_t v;
    memcpy(&v, p, 4);
    return __builtin_bswap32(v);
}

static void put_be32(uint8_t *p, uint32_t v) {
    uint32_t be = __builtin_bswap32(v);
    memcpy(p, &be, 4);
}

static uint64_t be64(const uint8_t *p) {
    uint64_t v;
    memcpy(&v, p, 8);
    return __builtin_bswap64(v);
}

static void on_ramfb_write(void *opaque, const uint8_t *data, uint32_t len) {
    HvFbDisplay *fb = opaque;
    if (len < 28) return;

    uint64_t addr = be64(data + 0);
    uint32_t fourcc = be32(data + 8);
    uint32_t width = be32(data + 16);
    uint32_t height = be32(data + 20);
    uint32_t stride = be32(data + 24);

    if (width < 64 || width > 8192 || height < 64 || height > 8192) return;
    if (stride == 0) stride = width * 4;
    if (stride < width * 2 || stride > 65536) return;

    uint64_t total_bytes = (uint64_t)stride * (height - 1) + (uint64_t)width * 4;
    void *host_ptr = hv_phys_ptr(fb->m, addr, total_bytes);
    if (!host_ptr) {
        fprintf(stderr, "winvm: ramfb ignored invalid PA 0x%llx (%ux%u stride %u)\n",
                (unsigned long long)addr, width, height, stride);
        return;
    }

    pthread_mutex_lock(&fb->mu);
    fb->fb_pa = addr;
    fb->fb_host = (const uint8_t *)host_ptr;
    fb->width = width;
    fb->height = height;
    fb->stride = stride;
    fb->fourcc = fourcc;
    fb->active = 1;
    fb->ext_active = 0; /* ramfb (EDK2/Windows) takes the screen back */
    pthread_mutex_unlock(&fb->mu);

    fprintf(stderr, "winvm: ramfb configured %ux%u stride=%u fourcc=0x%08x at PA 0x%llx\n",
            width, height, stride, fourcc, (unsigned long long)addr);
}

HvFbDisplay *hv_fb_display_create(HvMachine *m, HvFwCfg *fw_cfg) {
    HvFbDisplay *fb = calloc(1, sizeof *fb);
    fb->m = m;
    pthread_mutex_init(&fb->mu, NULL);
    if (fw_cfg) {
        int idx = hv_fw_cfg_add_writable_file(fw_cfg, "etc/ramfb", 28, on_ramfb_write, fb);
        if (idx >= 0) {
            /* VMM-preset resolution, per the QEMU ramfb contract: the VMM may
               seed etc/ramfb with a preferred mode (addr == 0, width/height
               set, fourcc/flags/stride == 0). EDK2's QemuRamFbDxe reads the
               file when the driver starts and adopts the preset as its
               initial GOP mode; it allocates the framebuffer itself and DMA-
               writes the full RAMFBCfg back (handled by on_ramfb_write).
               Without a preset EDK2 falls back to 800x600, and the guest OS
               cannot switch modes afterwards (Windows BasicDisplay exposes
               only the boot GOP mode), so the preset is the one chance to
               pick a usable resolution. */
            uint8_t preset[28] = {0};
            put_be32(preset + 16, HV_RAMFB_PRESET_WIDTH);
            put_be32(preset + 20, HV_RAMFB_PRESET_HEIGHT);
            hv_fw_cfg_set_file_data(fw_cfg, idx, preset, sizeof preset);
        }
    }
    return fb;
}

void hv_fb_display_set_external(HvFbDisplay *fb, const uint8_t *pixels, uint32_t w, uint32_t h,
                                uint32_t stride, uint32_t fourcc) {
    if (!fb || !pixels || !w || !h) return;
    pthread_mutex_lock(&fb->mu);
    fb->ext_host = pixels;
    fb->ext_width = w;
    fb->ext_height = h;
    fb->ext_stride = stride ? stride : w * 4;
    fb->ext_fourcc = fourcc;
    fb->ext_active = 1;
    pthread_mutex_unlock(&fb->mu);
}

void hv_fb_display_clear_external(HvFbDisplay *fb) {
    if (!fb) return;
    pthread_mutex_lock(&fb->mu);
    fb->ext_active = 0;
    fb->ext_host = NULL;
    pthread_mutex_unlock(&fb->mu);
}

int hv_fb_display_get_frame(HvFbDisplay *fb, const uint8_t **pixels, uint32_t *w, uint32_t *h, uint32_t *stride) {
    if (!fb) return -1;
    pthread_mutex_lock(&fb->mu);
    if (fb->ext_active && fb->ext_host) {
        *pixels = fb->ext_host;
        *w = fb->ext_width;
        *h = fb->ext_height;
        *stride = fb->ext_stride;
        pthread_mutex_unlock(&fb->mu);
        return 0;
    }
    if (!fb->active || !fb->fb_host || !fb->width || !fb->height) {
        pthread_mutex_unlock(&fb->mu);
        return -1;
    }
    *pixels = fb->fb_host;
    *w = fb->width;
    *h = fb->height;
    *stride = fb->stride;
    pthread_mutex_unlock(&fb->mu);
    return 0;
}
