#ifndef HENGEVM_VIRTIO_GPU_H
#define HENGEVM_VIRTIO_GPU_H

#include "fb_display.h"
#include "machine.h"
#include "pcie.h"
#include "virtio.h"

/* 2D-scanout-only virtio-gpu (device id 16, PCI 1af4:1050), Phase 3 stage 1.
   No virgl/blob/context features: the guest (Linux virtio_gpu DRM driver +
   Android drm_hwcomposer) uses the classic dumb-buffer path
   (CREATE_2D / ATTACH_BACKING / SET_SCANOUT / TRANSFER_TO_HOST_2D / FLUSH),
   rendering on its CPU and asking us only to present the result through the
   existing HvFbDisplay presenter (shared with ramfb, last writer wins). */

typedef struct HvVirtioGpu HvVirtioGpu;

/* fb may be NULL (headless): commands still complete, frames are dropped. */
HvVirtioGpu *hv_virtio_gpu_create(HvMachine *m, HvPcie *bus, HvFbDisplay *fb);

#endif
