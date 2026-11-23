/* SPDX-License-Identifier: GPL-2.0-or-later */
/* fb_stream.m — LAN screen-streaming TEST server (H.264 + MJPEG over HTTP).
 *
 * Purpose: let another device on the home Wi-Fi (e.g. a Chromebook) view the
 * guest screen in a plain browser while all processing stays on the iPad.
 * This is a feasibility probe for latency/quality, not a finished feature:
 * view-only, no input injection, no authentication — LAN use only.
 *
 * Two streaming paths share one tiny HTTP server (single port):
 *   GET /          -> WebCodecs player page (H.264 over WebSocket, below);
 *                     auto-falls back to the MJPEG <img> when WebCodecs is
 *                     unavailable or the H.264 path stalls.
 *   GET /ws        -> WebSocket endpoint carrying hardware-encoded H.264
 *                     (VideoToolbox, 1280 px wide max, ~30 fps, ~5 Mbps,
 *                     realtime/no-B-frame settings). Wire format per binary
 *                     message: [0x01][avcC] once per config, then
 *                     [0x02][flags][8-byte BE timestamp us][AVCC sample].
 *                     Senders never queue deep: a client that falls behind
 *                     is resynced at the next keyframe instead of being fed
 *                     stale frames.
 *   GET /stream    -> multipart/x-mixed-replace MJPEG (~10 fps, <=1024 px
 *                     wide, JPEG q=0.6). Kept as fallback/debug path.
 *   GET /frame.jpg -> single JPEG snapshot.
 *
 * The server runs on detached pthreads and only ever reads the framebuffer
 * through hv_fb_display_get_frame(); each frame is copied row-by-row on the
 * streaming thread before conversion, so the Metal presenter is unaffected.
 */
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <ImageIO/ImageIO.h>
#import <CoreVideo/CoreVideo.h>
#import <CoreMedia/CoreMedia.h>
#import <VideoToolbox/VideoToolbox.h>
#import <CommonCrypto/CommonDigest.h>

#include <arpa/inet.h>
#include <errno.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <poll.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>

#include "fb_display.h"
#include "fb_stream.h"

#define FB_STREAM_MAX_WIDTH 1024u
#define FB_STREAM_FRAME_US 100000 /* ~10 fps */

/* H.264 path tuning: one step up in picture size from the MJPEG test
   (1024 -> 1280 px wide) and hardware-encoded at 30 fps / ~5 Mbps. */
#define FB_H264_MAX_WIDTH 1280u
#define FB_H264_FPS 30
#define FB_H264_BITRATE 5000000
#define FB_H264_QUEUE_MAX (512u * 1024u) /* per-client backlog cap (bytes) */

static HvFbDisplay *g_fb;
static uint16_t g_port = 8080;
static int g_started;
static pthread_mutex_t g_start_mu = PTHREAD_MUTEX_INITIALIZER;

/* ---------- helpers ---------- */

static int write_all(int fd, const void *buf, size_t len) {
    const uint8_t *p = (const uint8_t *)buf;
    while (len > 0) {
        ssize_t n = write(fd, p, len);
        if (n < 0) {
            if (errno == EINTR) continue;
            return -1;
        }
        p += (size_t)n;
        len -= (size_t)n;
    }
    return 0;
}

static int send_str(int fd, const char *s) {
    return write_all(fd, s, strlen(s));
}

/* ---------- MJPEG path (unchanged from the first test build) ---------- */

/* Snapshot the current guest frame, downscale, and JPEG-encode it.
   Returns nil while the guest has not set a framebuffer yet. */
static NSData *fb_stream_encode_jpeg(void) {
    const uint8_t *px = NULL;
    uint32_t w = 0, h = 0, stride = 0;
    if (!g_fb) return nil;
    if (hv_fb_display_get_frame(g_fb, &px, &w, &h, &stride) != 0) return nil;

    @autoreleasepool {
        /* Copy row-by-row on this thread; the guest may keep writing the
           original while we convert (same approach as hv_fb_save_png). */
        size_t total = (size_t)stride * h;
        uint8_t *copy = (uint8_t *)malloc(total);
        if (!copy) return nil;
        for (uint32_t y = 0; y < h; y++)
            memcpy(copy + (size_t)y * stride, px + (size_t)y * stride, stride);
        /* Ensure alpha byte is 0xff (XRGB8888 leaves X=0x00) */
        for (uint32_t y = 0; y < h; y++) {
            uint8_t *row = copy + (size_t)y * stride;
            for (uint32_t x = 0; x < w; x++) row[x * 4 + 3] = 0xff;
        }

        NSData *result = nil;
        CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
        CGDataProviderRef prov = CGDataProviderCreateWithData(NULL, copy, total, NULL);
        CGBitmapInfo bmi = kCGBitmapByteOrder32Little | (CGBitmapInfo)kCGImageAlphaNoneSkipFirst;
        CGImageRef img = CGImageCreate(w, h, 8, 32, stride, cs, bmi, prov, NULL, false,
                                       kCGRenderingIntentDefault);
        CGDataProviderRelease(prov);
        CGColorSpaceRelease(cs);
        if (img) {
            CGImageRef out = img;
            CGImageRef scaled = NULL;
            if (w > FB_STREAM_MAX_WIDTH) {
                size_t sw = FB_STREAM_MAX_WIDTH;
                size_t sh = (size_t)(((uint64_t)h * FB_STREAM_MAX_WIDTH) / w);
                if (sh < 2) sh = 2;
                CGColorSpaceRef cs2 = CGColorSpaceCreateDeviceRGB();
                CGContextRef ctx = CGBitmapContextCreate(NULL, sw, sh, 8, sw * 4, cs2, bmi);
                if (ctx) {
                    CGContextSetInterpolationQuality(ctx, kCGInterpolationMedium);
                    CGContextDrawImage(ctx, CGRectMake(0, 0, (CGFloat)sw, (CGFloat)sh), img);
                    scaled = CGBitmapContextCreateImage(ctx);
                    CGContextRelease(ctx);
                    if (scaled) out = scaled;
                }
                CGColorSpaceRelease(cs2);
            }

            NSMutableData *data = [NSMutableData data];
            CGImageDestinationRef dst = CGImageDestinationCreateWithData(
                (__bridge CFMutableDataRef)data, CFSTR("public.jpeg"), 1, NULL);
            if (dst) {
                NSDictionary *opts = @{
                    (__bridge NSString *)kCGImageDestinationLossyCompressionQuality : @0.6
                };
                CGImageDestinationAddImage(dst, out, (__bridge CFDictionaryRef)opts);
                if (CGImageDestinationFinalize(dst)) result = data;
                CFRelease(dst);
            }
            if (scaled) CGImageRelease(scaled);
            CGImageRelease(img);
        }
        /* `copy` must outlive the CGImage above (the data provider borrows
           it), so it is freed only here, after encoding is done. */
        free(copy);
        return result;
    }
}

/* ---------- H.264 path: encoder + per-client distribution ---------- */

typedef struct H264Sample {
    uint8_t *data; /* AVCC sample (4-byte length-prefixed NAL units) */
    size_t len;
    uint64_t ts_us;
    int key;
    struct H264Sample *next;
} H264Sample;

typedef struct WsClient {
    int fd;
    int need_key; /* guarded by g_h264.mu: drop deltas until a keyframe */
    H264Sample *qhead, *qtail; /* guarded by mu (below) */
    size_t qbytes;
    int qcount;
    pthread_mutex_t mu;
    struct WsClient *next; /* guarded by g_h264.mu */
} WsClient;

/* Lock order is always g_h264.mu -> WsClient.mu, never the reverse. */
static struct {
    pthread_mutex_t mu;
    WsClient *clients;
    int client_count;
    int encoder_run;    /* encoder thread should keep looping */
    int encoder_active; /* encoder thread exists */
    int force_key;      /* force a keyframe on the next encode */
    uint8_t *avcc;      /* current decoder config (avcC record) */
    size_t avcc_len;
    uint32_t avcc_gen;  /* bumps whenever avcc is replaced/cleared */
    VTCompressionSessionRef session; /* encoder thread only */
    uint32_t sess_w, sess_h;         /* encoder thread only */
    CVPixelBufferRef pixbuf;         /* encoder thread only */
    uint64_t frame_no;               /* encoder thread only */
} g_h264 = { PTHREAD_MUTEX_INITIALIZER };

/* Caller holds g_h264.mu. */
static void h264_client_clear_queue_locked(WsClient *c) {
    pthread_mutex_lock(&c->mu);
    H264Sample *q = c->qhead;
    while (q) {
        H264Sample *nx = q->next;
        free(q->data);
        free(q);
        q = nx;
    }
    c->qhead = c->qtail = NULL;
    c->qbytes = 0;
    c->qcount = 0;
    pthread_mutex_unlock(&c->mu);
}

/* Extract SPS/PPS from an encoded sample's format description and rebuild
   the avcC record; on change, all clients must resync at a keyframe with
   the new config. */
static void h264_update_config(CMFormatDescriptionRef fmt) {
    const uint8_t *sps = NULL, *pps = NULL;
    size_t sps_len = 0, pps_len = 0, pset_count = 0;
    int nalu_len = 0;
    if (CMVideoFormatDescriptionGetH264ParameterSetAtIndex(fmt, 0, &sps, &sps_len,
                                                           &pset_count, &nalu_len) != noErr)
        return;
    if (CMVideoFormatDescriptionGetH264ParameterSetAtIndex(fmt, 1, &pps, &pps_len,
                                                           &pset_count, &nalu_len) != noErr)
        return;
    if (!sps || !pps || sps_len < 4) return;

    size_t total = 7 + 2 + sps_len + 1 + 2 + pps_len;
    uint8_t *avcc = (uint8_t *)malloc(total);
    if (!avcc) return;
    size_t o = 0;
    avcc[o++] = 1;          /* configurationVersion */
    avcc[o++] = sps[1];     /* AVCProfileIndication */
    avcc[o++] = sps[2];     /* profile_compatibility */
    avcc[o++] = sps[3];     /* AVCLevelIndication */
    avcc[o++] = 0xFF;       /* reserved + lengthSizeMinusOne(3): 4-byte lengths */
    avcc[o++] = 0xE1;       /* reserved + numOfSPS(1) */
    avcc[o++] = (uint8_t)(sps_len >> 8);
    avcc[o++] = (uint8_t)sps_len;
    memcpy(avcc + o, sps, sps_len);
    o += sps_len;
    avcc[o++] = 1;          /* numOfPPS */
    avcc[o++] = (uint8_t)(pps_len >> 8);
    avcc[o++] = (uint8_t)pps_len;
    memcpy(avcc + o, pps, pps_len);
    o += pps_len;

    pthread_mutex_lock(&g_h264.mu);
    if (!g_h264.avcc || g_h264.avcc_len != total || memcmp(g_h264.avcc, avcc, total) != 0) {
        free(g_h264.avcc);
        g_h264.avcc = avcc;
        g_h264.avcc_len = total;
        g_h264.avcc_gen++;
        for (WsClient *c = g_h264.clients; c; c = c->next) {
            h264_client_clear_queue_locked(c);
            c->need_key = 1;
        }
    } else {
        free(avcc);
    }
    pthread_mutex_unlock(&g_h264.mu);
}

/* Hand one encoded sample to every connected client (per-client copies).
   Takes ownership of `buf`. Clients that are behind or out of sync only
   ever resume at a keyframe — stale video is dropped, never queued deep. */
static void h264_distribute(uint8_t *buf, size_t len, int key, uint64_t ts_us) {
    pthread_mutex_lock(&g_h264.mu);
    for (WsClient *c = g_h264.clients; c; c = c->next) {
        if (c->need_key && !key) continue;
        H264Sample *s = (H264Sample *)malloc(sizeof(H264Sample));
        if (!s) continue;
        s->data = (uint8_t *)malloc(len ? len : 1);
        if (!s->data) {
            free(s);
            continue;
        }
        memcpy(s->data, buf, len);
        s->len = len;
        s->key = key;
        s->ts_us = ts_us;
        s->next = NULL;
        pthread_mutex_lock(&c->mu);
        if (c->qbytes + len > FB_H264_QUEUE_MAX) {
            /* Client is too slow: drop everything queued and resync it at
               the next keyframe (this sample too, unless it is one). */
            H264Sample *q = c->qhead;
            while (q) {
                H264Sample *nx = q->next;
                free(q->data);
                free(q);
                q = nx;
            }
            c->qhead = c->qtail = NULL;
            c->qbytes = 0;
            c->qcount = 0;
            if (!key) c->need_key = 1;
        }
        if (!(c->need_key && !key)) {
            if (c->qtail) c->qtail->next = s;
            else c->qhead = s;
            c->qtail = s;
            c->qbytes += len;
            c->qcount++;
            if (key) c->need_key = 0;
            s = NULL; /* ownership moved to the queue */
        }
        pthread_mutex_unlock(&c->mu);
        if (s) {
            free(s->data);
            free(s);
        }
    }
    pthread_mutex_unlock(&g_h264.mu);
    free(buf);
}

static void h264_output_cb(void *ref_con, void *source_frame_ref_con, OSStatus status,
                           VTEncodeInfoFlags info_flags, CMSampleBufferRef sample) {
    (void)ref_con;
    (void)source_frame_ref_con;
    (void)info_flags;
    if (status != noErr || !sample) return;
    if (!CMSampleBufferDataIsReady(sample)) return;

    CMFormatDescriptionRef fmt = CMSampleBufferGetFormatDescription(sample);
    if (fmt) h264_update_config(fmt);

    int key = 1;
    CFArrayRef atts = CMSampleBufferGetSampleAttachmentsArray(sample, false);
    if (atts && CFArrayGetCount(atts) > 0) {
        CFDictionaryRef d = (CFDictionaryRef)CFArrayGetValueAtIndex(atts, 0);
        if (d) {
            CFBooleanRef not_sync =
                (CFBooleanRef)CFDictionaryGetValue(d, kCMSampleAttachmentKey_NotSync);
            if (not_sync == kCFBooleanTrue) key = 0;
        }
    }

    CMBlockBufferRef bb = CMSampleBufferGetDataBuffer(sample);
    if (!bb) return;
    size_t len = CMBlockBufferGetDataLength(bb);
    if (len == 0) return;
    uint8_t *buf = (uint8_t *)malloc(len);
    if (!buf) return;
    if (CMBlockBufferCopyDataBytes(bb, 0, len, buf) != kCMBlockBufferNoErr) {
        free(buf);
        return;
    }

    uint64_t ts_us = 0;
    CMTime pts = CMSampleBufferGetPresentationTimeStamp(sample);
    if (CMTIME_IS_VALID(pts)) ts_us = (uint64_t)(CMTimeGetSeconds(pts) * 1000000.0);
    h264_distribute(buf, len, key, ts_us);
}

/* Encoder-thread only: flush + invalidate the session and drop the config
   so clients resync against the next session. */
static void h264_teardown_session(void) {
    if (g_h264.session) {
        VTCompressionSessionCompleteFrames(g_h264.session, kCMTimeInvalid);
        VTCompressionSessionInvalidate(g_h264.session);
        CFRelease(g_h264.session);
        g_h264.session = NULL;
    }
    if (g_h264.pixbuf) {
        CFRelease(g_h264.pixbuf);
        g_h264.pixbuf = NULL;
    }
    g_h264.sess_w = g_h264.sess_h = 0;
    pthread_mutex_lock(&g_h264.mu);
    free(g_h264.avcc);
    g_h264.avcc = NULL;
    g_h264.avcc_len = 0;
    g_h264.avcc_gen++;
    pthread_mutex_unlock(&g_h264.mu);
}

static int h264_create_session(uint32_t tw, uint32_t th) {
    VTCompressionSessionRef s = NULL;
    OSStatus st = VTCompressionSessionCreate(kCFAllocatorDefault, (int32_t)tw, (int32_t)th,
                                             kCMVideoCodecType_H264, NULL, NULL, NULL,
                                             h264_output_cb, NULL, &s);
    if (st != noErr || !s) {
        fprintf(stderr, "fb_stream: VTCompressionSessionCreate failed: %d\n", (int)st);
        fflush(stderr);
        return -1;
    }
    int fps = FB_H264_FPS, bitrate = FB_H264_BITRATE, keyint = FB_H264_FPS;
    double keyint_dur = 1.0;
    CFNumberRef n_fps = CFNumberCreate(NULL, kCFNumberIntType, &fps);
    CFNumberRef n_br = CFNumberCreate(NULL, kCFNumberIntType, &bitrate);
    CFNumberRef n_kfi = CFNumberCreate(NULL, kCFNumberIntType, &keyint);
    CFNumberRef n_kfid = CFNumberCreate(NULL, kCFNumberDoubleType, &keyint_dur);
    VTSessionSetProperty(s, kVTCompressionPropertyKey_RealTime, kCFBooleanTrue);
    VTSessionSetProperty(s, kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse);
    if (n_fps) {
        VTSessionSetProperty(s, kVTCompressionPropertyKey_ExpectedFrameRate, n_fps);
        CFRelease(n_fps);
    }
    if (n_br) {
        VTSessionSetProperty(s, kVTCompressionPropertyKey_AverageBitRate, n_br);
        CFRelease(n_br);
    }
    if (n_kfi) {
        VTSessionSetProperty(s, kVTCompressionPropertyKey_MaxKeyFrameInterval, n_kfi);
        CFRelease(n_kfi);
    }
    if (n_kfid) {
        VTSessionSetProperty(s, kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, n_kfid);
        CFRelease(n_kfid);
    }
    VTSessionSetProperty(s, kVTCompressionPropertyKey_ProfileLevel,
                         kVTProfileLevel_H264_High_AutoLevel);
    st = VTCompressionSessionPrepareToEncodeFrames(s);
    if (st != noErr) {
        fprintf(stderr, "fb_stream: VTCompressionSessionPrepare failed: %d\n", (int)st);
        fflush(stderr);
        VTCompressionSessionInvalidate(s);
        CFRelease(s);
        return -1;
    }
    g_h264.session = s;
    g_h264.sess_w = tw;
    g_h264.sess_h = th;
    fprintf(stderr, "fb_stream: H.264 encoder started (%ux%u @ %d fps, %d bps)\n",
            tw, th, FB_H264_FPS, FB_H264_BITRATE);
    fflush(stderr);
    return 0;
}

static int h264_ensure_pixbuf(uint32_t tw, uint32_t th) {
    if (g_h264.pixbuf) {
        if ((uint32_t)CVPixelBufferGetWidth(g_h264.pixbuf) == tw &&
            (uint32_t)CVPixelBufferGetHeight(g_h264.pixbuf) == th)
            return 0;
        CFRelease(g_h264.pixbuf);
        g_h264.pixbuf = NULL;
    }
    CVPixelBufferRef pb = NULL;
    CVReturn r = CVPixelBufferCreate(kCFAllocatorDefault, tw, th,
                                     kCVPixelFormatType_32BGRA, NULL, &pb);
    if (r != kCVReturnSuccess || !pb) return -1;
    g_h264.pixbuf = pb;
    return 0;
}

/* Bilinear-downscale the top-down BGRA framebuffer copy into the pixel
   buffer (also top-down memory, so no orientation juggling is needed). */
static void h264_scale_into_pixbuf(const uint8_t *src, uint32_t sw, uint32_t sh,
                                   uint32_t sstride, CVPixelBufferRef pb) {
    uint32_t dw = (uint32_t)CVPixelBufferGetWidth(pb);
    uint32_t dh = (uint32_t)CVPixelBufferGetHeight(pb);
    uint32_t *x0 = (uint32_t *)malloc(sizeof(uint32_t) * dw);
    uint32_t *x1 = (uint32_t *)malloc(sizeof(uint32_t) * dw);
    float *xw = (float *)malloc(sizeof(float) * dw);
    if (!x0 || !x1 || !xw) {
        free(x0);
        free(x1);
        free(xw);
        return;
    }
    for (uint32_t x = 0; x < dw; x++) {
        double fx = (x + 0.5) * (double)sw / (double)dw - 0.5;
        if (fx < 0) fx = 0;
        if (fx > (double)(sw - 1)) fx = (double)(sw - 1);
        uint32_t xi = (uint32_t)fx;
        uint32_t xj = xi + 1;
        if (xj > sw - 1) xj = sw - 1;
        x0[x] = xi;
        x1[x] = xj;
        xw[x] = (float)(fx - (double)xi);
    }
    CVPixelBufferLockBaseAddress(pb, 0);
    uint8_t *dst = (uint8_t *)CVPixelBufferGetBaseAddress(pb);
    size_t dstride = CVPixelBufferGetBytesPerRow(pb);
    if (dst) {
        for (uint32_t y = 0; y < dh; y++) {
            double fy = (y + 0.5) * (double)sh / (double)dh - 0.5;
            if (fy < 0) fy = 0;
            if (fy > (double)(sh - 1)) fy = (double)(sh - 1);
            uint32_t yi = (uint32_t)fy;
            uint32_t yj = yi + 1;
            if (yj > sh - 1) yj = sh - 1;
            float wy = (float)(fy - (double)yi);
            const uint8_t *r0 = src + (size_t)yi * sstride;
            const uint8_t *r1 = src + (size_t)yj * sstride;
            uint8_t *drow = dst + (size_t)y * dstride;
            for (uint32_t x = 0; x < dw; x++) {
                const uint8_t *p00 = r0 + (size_t)x0[x] * 4;
                const uint8_t *p01 = r0 + (size_t)x1[x] * 4;
                const uint8_t *p10 = r1 + (size_t)x0[x] * 4;
                const uint8_t *p11 = r1 + (size_t)x1[x] * 4;
                float wx = xw[x];
                for (int ci = 0; ci < 3; ci++) {
                    float top = (float)p00[ci] + ((float)p01[ci] - (float)p00[ci]) * wx;
                    float bot = (float)p10[ci] + ((float)p11[ci] - (float)p10[ci]) * wx;
                    drow[x * 4 + ci] = (uint8_t)(top + (bot - top) * wy + 0.5f);
                }
                drow[x * 4 + 3] = 0xff;
            }
        }
    }
    CVPixelBufferUnlockBaseAddress(pb, 0);
    free(x0);
    free(x1);
    free(xw);
}

/* Encoder thread only. */
static void h264_encode_one_frame(void) {
    const uint8_t *px = NULL;
    uint32_t w = 0, h = 0, stride = 0;
    if (!g_fb) return;
    if (hv_fb_display_get_frame(g_fb, &px, &w, &h, &stride) != 0) return;

    uint32_t tw = w, th = h;
    if (tw > FB_H264_MAX_WIDTH) {
        th = (uint32_t)(((uint64_t)h * FB_H264_MAX_WIDTH) / w);
        tw = FB_H264_MAX_WIDTH;
    }
    tw &= ~1u; /* H.264 wants even dimensions */
    th &= ~1u;
    if (tw < 2) tw = 2;
    if (th < 2) th = 2;

    if (!g_h264.session || g_h264.sess_w != tw || g_h264.sess_h != th) {
        h264_teardown_session();
        if (h264_create_session(tw, th) != 0) return;
    }
    if (h264_ensure_pixbuf(tw, th) != 0) return;

    /* Copy row-by-row on this thread; the guest may keep writing the
       original while we scale (same approach as the JPEG path). */
    size_t total = (size_t)stride * h;
    uint8_t *copy = (uint8_t *)malloc(total);
    if (!copy) return;
    for (uint32_t y = 0; y < h; y++)
        memcpy(copy + (size_t)y * stride, px + (size_t)y * stride, stride);
    h264_scale_into_pixbuf(copy, w, h, stride, g_h264.pixbuf);
    free(copy);

    pthread_mutex_lock(&g_h264.mu);
    int force_key = g_h264.force_key;
    g_h264.force_key = 0;
    pthread_mutex_unlock(&g_h264.mu);

    CFDictionaryRef opts = NULL;
    if (force_key) {
        const void *keys[] = { kVTEncodeFrameOptionKey_ForceKeyFrame };
        const void *vals[] = { kCFBooleanTrue };
        opts = CFDictionaryCreate(NULL, keys, vals, 1, &kCFTypeDictionaryKeyCallBacks,
                                  &kCFTypeDictionaryValueCallBacks);
    }
    CMTime pts = CMTimeMake((int64_t)g_h264.frame_no * 1000, 30000);
    CMTime dur = CMTimeMake(1000, 30000);
    OSStatus st = VTCompressionSessionEncodeFrame(g_h264.session, g_h264.pixbuf, pts, dur,
                                                  opts, NULL, NULL);
    if (opts) CFRelease(opts);
    if (st == noErr) g_h264.frame_no++;
}

static void *h264_encoder_main(void *unused) {
    (void)unused;
    for (;;) {
        for (;;) {
            pthread_mutex_lock(&g_h264.mu);
            int run = g_h264.encoder_run;
            pthread_mutex_unlock(&g_h264.mu);
            if (!run) break;
            struct timespec t0, t1;
            clock_gettime(CLOCK_MONOTONIC, &t0);
            @autoreleasepool {
                h264_encode_one_frame();
            }
            clock_gettime(CLOCK_MONOTONIC, &t1);
            long elapsed_us = (long)(t1.tv_sec - t0.tv_sec) * 1000000L +
                              (t1.tv_nsec - t0.tv_nsec) / 1000;
            long remain = 1000000L / FB_H264_FPS - elapsed_us;
            if (remain > 0) usleep((useconds_t)remain);
        }
        h264_teardown_session();
        pthread_mutex_lock(&g_h264.mu);
        if (g_h264.encoder_run) {
            /* A new client arrived while we were tearing down: keep going. */
            pthread_mutex_unlock(&g_h264.mu);
            continue;
        }
        g_h264.encoder_active = 0;
        pthread_mutex_unlock(&g_h264.mu);
        return NULL;
    }
}

static void h264_client_register(WsClient *c) {
    pthread_mutex_lock(&g_h264.mu);
    c->next = g_h264.clients;
    g_h264.clients = c;
    g_h264.client_count++;
    g_h264.force_key = 1; /* let the newcomer start at a keyframe ASAP */
    g_h264.encoder_run = 1;
    if (!g_h264.encoder_active) {
        g_h264.encoder_active = 1;
        pthread_t t;
        if (pthread_create(&t, NULL, h264_encoder_main, NULL) == 0) {
            pthread_detach(t);
        } else {
            g_h264.encoder_active = 0;
            fprintf(stderr, "fb_stream: failed to spawn H.264 encoder thread\n");
            fflush(stderr);
        }
    }
    pthread_mutex_unlock(&g_h264.mu);
}

static void h264_client_unregister(WsClient *c) {
    pthread_mutex_lock(&g_h264.mu);
    WsClient **pp = &g_h264.clients;
    while (*pp && *pp != c) pp = &(*pp)->next;
    if (*pp) *pp = c->next;
    if (g_h264.client_count > 0) g_h264.client_count--;
    if (g_h264.client_count == 0) g_h264.encoder_run = 0;
    pthread_mutex_unlock(&g_h264.mu);
}

/* ---------- WebSocket transport (minimal, server side) ---------- */

static void base64_encode(const uint8_t *in, size_t len, char *out) {
    static const char tbl[] =
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    size_t o = 0;
    for (size_t i = 0; i < len; i += 3) {
        uint32_t v = (uint32_t)in[i] << 16;
        size_t rem = len - i;
        if (rem > 1) v |= (uint32_t)in[i + 1] << 8;
        if (rem > 2) v |= (uint32_t)in[i + 2];
        out[o++] = tbl[(v >> 18) & 63];
        out[o++] = tbl[(v >> 12) & 63];
        out[o++] = rem > 1 ? tbl[(v >> 6) & 63] : '=';
        out[o++] = rem > 2 ? tbl[v & 63] : '=';
    }
    out[o] = '\0';
}

/* Send one unmasked server->client frame, payload in two parts. */
static int ws_send2(int fd, uint8_t opcode, const uint8_t *p1, size_t n1,
                    const uint8_t *p2, size_t n2) {
    size_t len = n1 + n2;
    uint8_t hdr[10];
    size_t hn = 0;
    hdr[hn++] = (uint8_t)(0x80 | opcode);
    if (len < 126) {
        hdr[hn++] = (uint8_t)len;
    } else if (len <= 0xffff) {
        hdr[hn++] = 126;
        hdr[hn++] = (uint8_t)(len >> 8);
        hdr[hn++] = (uint8_t)len;
    } else {
        hdr[hn++] = 127;
        for (int i = 7; i >= 0; i--) hdr[hn++] = (uint8_t)((uint64_t)len >> (i * 8));
    }
    if (write_all(fd, hdr, hn) != 0) return -1;
    if (n1 && write_all(fd, p1, n1) != 0) return -1;
    if (n2 && write_all(fd, p2, n2) != 0) return -1;
    return 0;
}

static int ws_send(int fd, uint8_t opcode, const uint8_t *payload, size_t len) {
    return ws_send2(fd, opcode, payload, len, NULL, 0);
}

static int ws_handshake(int fd, const char *req) {
    const char *k = strcasestr(req, "Sec-WebSocket-Key:");
    if (!k) return -1;
    k += strlen("Sec-WebSocket-Key:");
    while (*k == ' ' || *k == '\t') k++;
    char key[128];
    size_t n = 0;
    while (k[n] && k[n] != '\r' && k[n] != '\n' && n < sizeof(key) - 1) {
        key[n] = k[n];
        n++;
    }
    while (n > 0 && (key[n - 1] == ' ' || key[n - 1] == '\t')) n--;
    key[n] = '\0';
    if (n == 0) return -1;

    char combo[256];
    snprintf(combo, sizeof(combo), "%s%s", key,
             "258EAFA5-E914-47DA-95CA-C5AB0DC85B11");
    uint8_t digest[CC_SHA1_DIGEST_LENGTH];
    CC_SHA1(combo, (CC_LONG)strlen(combo), digest);
    char accept[64];
    base64_encode(digest, sizeof(digest), accept);

    char resp[512];
    snprintf(resp, sizeof(resp),
             "HTTP/1.1 101 Switching Protocols\r\n"
             "Upgrade: websocket\r\n"
             "Connection: Upgrade\r\n"
             "Sec-WebSocket-Accept: %s\r\n\r\n",
             accept);
    return send_str(fd, resp);
}

typedef struct {
    int fd;
    uint8_t buf[8192];
    size_t len; /* valid bytes in buf */
} WsReader;

/* Read whatever is available and consume complete client frames: close
   ends the connection, ping is answered with pong, everything else from
   the player page is ignored. Returns -1 when the connection is over. */
static int ws_handle_input(WsClient *c, WsReader *r) {
    if (r->len == sizeof(r->buf)) return -1; /* frame larger than buffer: give up */
    ssize_t n = read(r->fd, r->buf + r->len, sizeof(r->buf) - r->len);
    if (n < 0) {
        if (errno == EINTR || errno == EAGAIN) return 0;
        return -1;
    }
    if (n == 0) return -1;
    r->len += (size_t)n;

    size_t off = 0;
    for (;;) {
        size_t avail = r->len - off;
        if (avail < 2) break;
        uint8_t b0 = r->buf[off], b1 = r->buf[off + 1];
        int opcode = b0 & 0x0f;
        int masked = (b1 & 0x80) != 0;
        uint64_t plen = b1 & 0x7f;
        size_t hdr = 2;
        if (plen == 126) {
            if (avail < 4) break;
            plen = ((uint64_t)r->buf[off + 2] << 8) | r->buf[off + 3];
            hdr += 2;
        } else if (plen == 127) {
            if (avail < 10) break;
            plen = 0;
            for (int i = 0; i < 8; i++) plen = (plen << 8) | r->buf[off + 2 + i];
            hdr += 8;
        }
        if (masked) hdr += 4;
        if (avail < hdr + (size_t)plen) break; /* incomplete: wait for more */
        uint8_t *payload = r->buf + off + hdr;
        if (masked) {
            const uint8_t *mk = r->buf + off + hdr - 4;
            for (uint64_t i = 0; i < plen; i++) payload[i] ^= mk[i & 3];
        }
        if (opcode == 0x8) return -1; /* close */
        if (opcode == 0x9) {          /* ping -> pong */
            if (ws_send(c->fd, 0xA, payload, (size_t)plen) != 0) return -1;
        }
        off += hdr + (size_t)plen;
    }
    if (off > 0) {
        memmove(r->buf, r->buf + off, r->len - off);
        r->len -= off;
    }
    return 0;
}

/* Runs the WebSocket session on the calling (per-client) thread and takes
   ownership of `fd` (always closes it). Message order guarantee: a config
   message is always sent before the first sample of its generation. */
static void handle_ws_client(int fd, const char *req) {
    if (ws_handshake(fd, req) != 0) {
        close(fd);
        return;
    }
    int one = 1;
    setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof(one));
    struct timeval snd_to;
    snd_to.tv_sec = 0;
    snd_to.tv_usec = 200000; /* a client stalled >200 ms is dropped, not queued */
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &snd_to, sizeof(snd_to));

    WsClient *c = (WsClient *)calloc(1, sizeof(WsClient));
    if (!c) {
        close(fd);
        return;
    }
    c->fd = fd;
    c->need_key = 1;
    pthread_mutex_init(&c->mu, NULL);
    h264_client_register(c);
    fprintf(stderr, "fb_stream: H.264 WebSocket client connected\n");
    fflush(stderr);

    WsReader r;
    memset(&r, 0, sizeof(r));
    r.fd = fd;
    uint32_t sent_gen = 0;
    int dead = 0;
    while (!dead) {
        /* 1) config first whenever it changed */
        uint8_t *cfg = NULL;
        size_t cfg_len = 0;
        uint32_t gen = 0;
        pthread_mutex_lock(&g_h264.mu);
        gen = g_h264.avcc_gen;
        if (g_h264.avcc && gen != sent_gen) {
            cfg_len = g_h264.avcc_len;
            cfg = (uint8_t *)malloc(cfg_len);
            if (cfg) memcpy(cfg, g_h264.avcc, cfg_len);
        }
        pthread_mutex_unlock(&g_h264.mu);
        if (cfg) {
            uint8_t type = 0x01;
            if (ws_send2(fd, 0x2, &type, 1, cfg, cfg_len) != 0) dead = 1;
            free(cfg);
            if (dead) break;
            sent_gen = gen;
        }

        /* 2) one queued sample */
        pthread_mutex_lock(&c->mu);
        H264Sample *s = c->qhead;
        if (s) {
            c->qhead = s->next;
            if (!c->qhead) c->qtail = NULL;
            c->qbytes -= s->len;
            c->qcount--;
        }
        pthread_mutex_unlock(&c->mu);
        if (s) {
            uint8_t prefix[10];
            prefix[0] = 0x02;
            prefix[1] = s->key ? 1 : 0;
            for (int i = 0; i < 8; i++)
                prefix[2 + i] = (uint8_t)(s->ts_us >> (56 - 8 * i));
            if (ws_send2(fd, 0x2, prefix, sizeof(prefix), s->data, s->len) != 0)
                dead = 1;
            free(s->data);
            free(s);
            if (dead) break;
            continue;
        }

        /* 3) idle: watch for control frames briefly */
        struct pollfd pfd;
        pfd.fd = fd;
        pfd.events = POLLIN;
        pfd.revents = 0;
        int pr = poll(&pfd, 1, 5);
        if (pr > 0) {
            if ((pfd.revents & POLLIN) && ws_handle_input(c, &r) != 0) break;
            if (pfd.revents & (POLLERR | POLLHUP)) break;
        } else if (pr < 0 && errno != EINTR) {
            break;
        }
    }

    h264_client_unregister(c);
    /* Unregistered: no distributor can reference c anymore. */
    pthread_mutex_lock(&c->mu);
    H264Sample *q = c->qhead;
    while (q) {
        H264Sample *nx = q->next;
        free(q->data);
        free(q);
        q = nx;
    }
    c->qhead = c->qtail = NULL;
    pthread_mutex_unlock(&c->mu);
    pthread_mutex_destroy(&c->mu);
    free(c);
    close(fd);
    fprintf(stderr, "fb_stream: H.264 WebSocket client disconnected\n");
    fflush(stderr);
}

/* ---------- HTTP handling ---------- */

static const char kIndexHTML[] =
    "<!DOCTYPE html><html><head><meta charset=\"utf-8\">"
    "<meta name=\"viewport\" content=\"width=device-width,initial-scale=1\">"
    "<title>WindowsiOS Screen</title>"
    "<style>html,body{margin:0;background:#111;height:100%;color:#ccc;"
    "font-family:sans-serif}"
    "#st{height:24px;line-height:24px;font-size:13px;padding:0 8px;"
    "white-space:nowrap;overflow:hidden}"
    "canvas{display:block;max-width:100%;max-height:calc(100% - 24px);"
    "margin:0 auto}"
    "img{display:block;max-width:100%;max-height:100%;margin:0 auto}</style>"
    "</head><body><div id=\"st\">connecting...</div>"
    "<canvas id=\"cv\" width=\"1280\" height=\"960\"></canvas>"
    "<script>(function(){"
    "var st=document.getElementById('st'),cv=document.getElementById('cv'),"
    "ctx=cv.getContext('2d');"
    "var decoder=null,ws=null,gotFirst=false,gaveUp=false,retries=0,frames=0,"
    "lastT=performance.now();"
    "function status(s){st.textContent=s;}"
    "function fallback(){if(gaveUp)return;gaveUp=true;"
    "try{if(ws)ws.close();}catch(e){}"
    "status('H.264 unavailable - MJPEG fallback');"
    "var img=document.createElement('img');img.src='/stream';"
    "img.alt='guest screen';cv.replaceWith(img);}"
    "setTimeout(function(){if(!gotFirst)fallback();},10000);"
    "function connect(){"
    "decoder=null;"
    "ws=new WebSocket('ws://'+location.host+'/ws');"
    "ws.binaryType='arraybuffer';"
    "ws.onmessage=function(ev){"
    "var u=new Uint8Array(ev.data);if(u.length<1)return;"
    "if(u[0]===1){"
    "var avcc=u.slice(1);"
    "var hx=function(b){return ('0'+b.toString(16)).slice(-2);};"
    "var codec='avc1.'+hx(avcc[1])+hx(avcc[2])+hx(avcc[3]);"
    "if(decoder&&decoder.state!=='closed'){try{decoder.close();}catch(e){}}"
    "decoder=new VideoDecoder({"
    "output:function(f){"
    "if(cv.width!==f.displayWidth||cv.height!==f.displayHeight){"
    "cv.width=f.displayWidth;cv.height=f.displayHeight;}"
    "ctx.drawImage(f,0,0);f.close();"
    "gotFirst=true;retries=0;frames++;"
    "var now=performance.now();"
    "if(now-lastT>=1000){status('H.264 live - '+frames+' fps, '+cv.width+'x'+cv.height);"
    "frames=0;lastT=now;}"
    "},"
    "error:function(e){status('decoder error - reconnecting');"
    "try{ws.close();}catch(_){}}"
    "});"
    "try{decoder.configure({codec:codec,description:avcc.buffer,"
    "optimizeForLatency:true});}"
    "catch(e){status('configure failed');fallback();}"
    "}else if(u[0]===2){"
    "if(!decoder||decoder.state!=='configured')return;"
    "var key=(u[1]&1)!==0;"
    "if(decoder.decodeQueueSize>6){try{ws.close();}catch(e){}return;}"
    "var ts=0;for(var i=0;i<8;i++){ts=ts*256+u[2+i];}"
    "try{decoder.decode(new EncodedVideoChunk({type:key?'key':'delta',"
    "timestamp:ts,data:u.subarray(10)}));}catch(e){}"
    "}"
    "};"
    "ws.onclose=function(){"
    "if(gaveUp)return;"
    "if(retries<5){retries++;status('reconnecting...');"
    "setTimeout(function(){if(!gaveUp)connect();},500);}"
    "else fallback();"
    "};"
    "ws.onerror=function(){};"
    "}"
    "if(!('VideoDecoder' in window)||!('EncodedVideoChunk' in window)){"
    "fallback();}else{status('connecting...');connect();}"
    "})();</script></body></html>";

static void handle_client(int fd) {
    int one = 1;
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof(one));

    char buf[4096];
    size_t used = 0;
    while (used < sizeof(buf) - 1) {
        ssize_t n = read(fd, buf + used, sizeof(buf) - 1 - used);
        if (n < 0) {
            if (errno == EINTR) continue;
            close(fd);
            return;
        }
        if (n == 0) break;
        used += (size_t)n;
        buf[used] = '\0';
        if (strstr(buf, "\r\n\r\n") || strstr(buf, "\n\n")) break;
    }
    if (used == 0) {
        close(fd);
        return;
    }

    char method[16] = {0};
    char path[256] = {0};
    if (sscanf(buf, "%15s %255s", method, path) != 2) {
        close(fd);
        return;
    }
    /* Strip any query string. */
    char *q = strchr(path, '?');
    if (q) *q = '\0';

    if (strcmp(path, "/") == 0 || strcmp(path, "/index.html") == 0) {
        char hdr[256];
        snprintf(hdr, sizeof(hdr),
                 "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\n"
                 "Content-Length: %zu\r\nCache-Control: no-cache\r\nConnection: close\r\n\r\n",
                 strlen(kIndexHTML));
        if (send_str(fd, hdr) == 0) (void)send_str(fd, kIndexHTML);
    } else if (strcmp(path, "/ws") == 0) {
        handle_ws_client(fd, buf); /* takes ownership of fd */
        return;
    } else if (strcmp(path, "/frame.jpg") == 0) {
        NSData *jpg = fb_stream_encode_jpeg();
        if (jpg) {
            char hdr[256];
            snprintf(hdr, sizeof(hdr),
                     "HTTP/1.1 200 OK\r\nContent-Type: image/jpeg\r\n"
                     "Content-Length: %lu\r\nCache-Control: no-cache\r\nConnection: close\r\n\r\n",
                     (unsigned long)[jpg length]);
            if (send_str(fd, hdr) == 0) (void)write_all(fd, [jpg bytes], [jpg length]);
        } else {
            (void)send_str(fd, "HTTP/1.1 503 Service Unavailable\r\nContent-Length: 0\r\n"
                               "Connection: close\r\n\r\n");
        }
    } else if (strcmp(path, "/stream") == 0) {
        fprintf(stderr, "fb_stream: MJPEG client connected\n");
        fflush(stderr);
        if (send_str(fd, "HTTP/1.1 200 OK\r\n"
                         "Content-Type: multipart/x-mixed-replace; boundary=frame\r\n"
                         "Cache-Control: no-cache\r\nConnection: close\r\n\r\n") == 0) {
            for (;;) {
                NSData *jpg = fb_stream_encode_jpeg();
                if (jpg) {
                    char part[160];
                    int plen = snprintf(part, sizeof(part),
                                        "--frame\r\nContent-Type: image/jpeg\r\n"
                                        "Content-Length: %lu\r\n\r\n",
                                        (unsigned long)[jpg length]);
                    if (write_all(fd, part, (size_t)plen) != 0) break;
                    if (write_all(fd, [jpg bytes], [jpg length]) != 0) break;
                    if (write_all(fd, "\r\n", 2) != 0) break;
                }
                usleep(FB_STREAM_FRAME_US);
            }
        }
        fprintf(stderr, "fb_stream: MJPEG client disconnected\n");
        fflush(stderr);
    } else {
        (void)send_str(fd, "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n"
                           "Connection: close\r\n\r\n");
    }
    close(fd);
}

static void *client_main(void *arg) {
    int fd = (int)(intptr_t)arg;
    handle_client(fd);
    return NULL;
}

static void *server_main(void *unused) {
    (void)unused;
    int ls = socket(AF_INET, SOCK_STREAM, 0);
    if (ls < 0) {
        fprintf(stderr, "fb_stream: socket() failed: %s\n", strerror(errno));
        fflush(stderr);
        return NULL;
    }
    int one = 1;
    setsockopt(ls, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));

    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = htonl(INADDR_ANY);
    addr.sin_port = htons(g_port);
    if (bind(ls, (struct sockaddr *)&addr, sizeof(addr)) != 0) {
        fprintf(stderr, "fb_stream: bind(port %u) failed: %s\n", g_port, strerror(errno));
        fflush(stderr);
        close(ls);
        return NULL;
    }
    if (listen(ls, 8) != 0) {
        fprintf(stderr, "fb_stream: listen() failed: %s\n", strerror(errno));
        fflush(stderr);
        close(ls);
        return NULL;
    }
    fprintf(stderr, "fb_stream: screen server listening on port %u "
                    "(H.264/WebCodecs at /, MJPEG fallback at /stream)\n",
            g_port);
    fflush(stderr);

    for (;;) {
        int fd = accept(ls, NULL, NULL);
        if (fd < 0) {
            if (errno == EINTR) continue;
            usleep(50 * 1000);
            continue;
        }
        pthread_t t;
        if (pthread_create(&t, NULL, client_main, (void *)(intptr_t)fd) == 0) {
            pthread_detach(t);
        } else {
            handle_client(fd);
        }
    }
    return NULL;
}

/* ---------- public entry point ---------- */

int hv_fb_stream_start(HvFbDisplay *fb, uint16_t port) {
    if (!fb) return -1;
    pthread_mutex_lock(&g_start_mu);
    if (g_started) {
        pthread_mutex_unlock(&g_start_mu);
        return 0;
    }
    g_fb = fb;
    g_port = port;
    pthread_t t;
    if (pthread_create(&t, NULL, server_main, NULL) != 0) {
        fprintf(stderr, "fb_stream: failed to spawn server thread\n");
        fflush(stderr);
        pthread_mutex_unlock(&g_start_mu);
        return -1;
    }
    pthread_detach(t);
    g_started = 1;
    pthread_mutex_unlock(&g_start_mu);
    return 0;
}
