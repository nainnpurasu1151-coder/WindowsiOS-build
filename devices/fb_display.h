#ifndef WINVM_FB_DISPLAY_H
#define WINVM_FB_DISPLAY_H

#include <pthread.h>
#include <stdint.h>

#include "fw_cfg.h"
#include "machine.h"
#include "pcie.h"

/* Linear framebuffer display supporting QEMU `ramfb` (etc/ramfb in fw_cfg, used by
   EDK2 ArmVirtQemu GOP -> winload.efi -> Windows 11 BasicDisplay.sys + DWM)
   as well as optional VBE/bochs scanout. Zero MMIO exits per pixel write! */

typedef struct HvFbDisplay {
    HvMachine *m;
    pthread_mutex_t mu;

    /* Active scanout geometry (protected by mu) */
    uint64_t fb_pa;
    const uint8_t *fb_host;
    uint32_t width;
    uint32_t height;
    uint32_t stride;
    uint32_t fourcc; /* DRM fourcc, e.g. XR24 / AR24 (32-bit BGRX) */
    int active;

    /* Metal presenter handle (created lazily by fb_metal.m) */
    void *metal;

    /* External scanout (virtio-gpu): host-owned pixel buffer presented instead
       of the ramfb scanout while ext_active. Last writer wins: a ramfb write
       (EDK2/Windows) clears ext_active, a gpu flush sets it. */
    const uint8_t *ext_host;
    uint32_t ext_width;
    uint32_t ext_height;
    uint32_t ext_stride;
    uint32_t ext_fourcc;
    int ext_active;
} HvFbDisplay;

HvFbDisplay *hv_fb_display_create(HvMachine *m, HvFwCfg *fw_cfg);
/* Present an externally owned BGRA/XRGB buffer (must outlive the call; the
   virtio-gpu device owns it until RESOURCE_UNREF). Thread-safe. */
void hv_fb_display_set_external(HvFbDisplay *fb, const uint8_t *pixels, uint32_t w, uint32_t h,
                                uint32_t stride, uint32_t fourcc);
void hv_fb_display_clear_external(HvFbDisplay *fb);
/* Thread-safe snapshot of current scanout pointer and dimensions; returns 0 if active, -1 if not yet set. */
int hv_fb_display_get_frame(HvFbDisplay *fb, const uint8_t **pixels, uint32_t *w, uint32_t *h, uint32_t *stride);

/* Metal layer presentation & PNG screenshot helpers (implemented in devices/fb_metal.m) */
void hv_fb_metal_set_layer(HvFbDisplay *fb, void *ca_metal_layer);
uint64_t hv_fb_metal_frames(HvFbDisplay *fb);
int hv_fb_save_png(HvFbDisplay *fb, const char *path);

#endif
