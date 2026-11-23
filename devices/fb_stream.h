/* SPDX-License-Identifier: GPL-2.0-or-later */
#ifndef WINVM_FB_STREAM_H
#define WINVM_FB_STREAM_H

#include <stdint.h>

#include "fb_display.h"

/* LAN screen-streaming test server, implemented in devices/fb_stream.m.
   Starts a detached background server thread:
     GET /          -> player page (H.264 over WebSocket; decode order is
                       WebCodecs, then the bundled TinyH264 WASM decoder,
                       then MJPEG; the page also sends mouse/keyboard
                       input back over the same WebSocket)
     GET /ws        -> WebSocket H.264 stream (VideoToolbox hardware
                       encode, Constrained Baseline + CAVLC, <=1280 px
                       wide, ~30 fps, ~5 Mbps, AVCC + avcC config) and
                       the JSON input channel (only the most recently
                       connected client injects input, through the
                       existing hv_winvm_tablet / hv_winvm_key_hid hooks)
     GET /decoder.js-> TinyH264 WASM decoder bundle (embedded base64,
                       see fb_stream_decoder.h)
     GET /stream    -> multipart/x-mixed-replace MJPEG (~10 fps,
                       <=1024 px wide)
     GET /frame.jpg -> single JPEG snapshot
   Read-only: frames are snapshot via hv_fb_display_get_frame() and copied on
   the streaming threads, so the Metal presentation path is never disturbed.
   Idempotent: starting twice is a no-op. Returns 0 on success (or if already
   running), -1 on bad arguments. */
int hv_fb_stream_start(HvFbDisplay *fb, uint16_t port);

#endif
