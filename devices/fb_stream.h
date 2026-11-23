/* SPDX-License-Identifier: GPL-2.0-or-later */
#ifndef WINVM_FB_STREAM_H
#define WINVM_FB_STREAM_H

#include <stdint.h>

#include "fb_display.h"

/* LAN screen-streaming test server (MJPEG over HTTP), implemented in
   devices/fb_stream.m. Starts a detached background server thread:
     GET /          -> tiny HTML page embedding the stream
     GET /stream    -> multipart/x-mixed-replace MJPEG (~10 fps, <=1024 px wide)
     GET /frame.jpg -> single JPEG snapshot
   Read-only: frames are snapshot via hv_fb_display_get_frame() and copied on
   the server thread, so the Metal presentation path is never disturbed.
   Idempotent: starting twice is a no-op. Returns 0 on success (or if already
   running), -1 on bad arguments. */
int hv_fb_stream_start(HvFbDisplay *fb, uint16_t port);

#endif
