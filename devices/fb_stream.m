/* SPDX-License-Identifier: GPL-2.0-or-later */
/* fb_stream.m — LAN screen-streaming TEST server (MJPEG over HTTP).
 *
 * Purpose: let another device on the home Wi-Fi (e.g. a Chromebook) view the
 * guest screen in a plain browser while all processing stays on the iPad.
 * This is a feasibility probe for latency/quality, not a finished feature:
 * view-only, no input injection, no authentication — LAN use only.
 *
 * The server runs on detached pthreads and only ever reads the framebuffer
 * through hv_fb_display_get_frame(); each frame is copied row-by-row on the
 * server thread before conversion, so the Metal presenter is unaffected.
 * Frames are downscaled to at most 1024 px wide and JPEG-encoded (q=0.6)
 * at roughly 10 fps to keep Wi-Fi bandwidth and CPU modest.
 */
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <ImageIO/ImageIO.h>

#include <arpa/inet.h>
#include <errno.h>
#include <netinet/in.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

#include "fb_display.h"
#include "fb_stream.h"

#define FB_STREAM_MAX_WIDTH 1024u
#define FB_STREAM_FRAME_US 100000 /* ~10 fps */

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

/* ---------- HTTP handling ---------- */

static const char kIndexHTML[] =
    "<!DOCTYPE html><html><head><meta charset=\"utf-8\">"
    "<meta name=\"viewport\" content=\"width=device-width,initial-scale=1\">"
    "<title>WindowsiOS Screen</title>"
    "<style>html,body{margin:0;background:#111;height:100%}"
    "img{display:block;max-width:100%;max-height:100%;margin:0 auto}</style>"
    "</head><body><img src=\"/stream\" alt=\"guest screen\"></body></html>";

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
    fprintf(stderr, "fb_stream: MJPEG test server listening on port %u "
                    "(open http://<ipad-ip>:%u/ on the LAN)\n",
            g_port, g_port);
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
