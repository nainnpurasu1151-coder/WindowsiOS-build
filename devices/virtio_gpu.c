#include "virtio_gpu.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* Queue indices */
#define CTRLQ 0
#define CURSORQ 1

/* Command codes (virtio GPU spec / Linux uapi virtio_gpu.h) */
#define CMD_GET_DISPLAY_INFO      0x0100
#define CMD_RESOURCE_CREATE_2D    0x0101
#define CMD_RESOURCE_UNREF        0x0102
#define CMD_SET_SCANOUT           0x0103
#define CMD_RESOURCE_FLUSH        0x0104
#define CMD_TRANSFER_TO_HOST_2D   0x0105
#define CMD_RESOURCE_ATTACH_BACKING 0x0106
#define CMD_RESOURCE_DETACH_BACKING 0x0107
#define CMD_SET_SCANOUT_BLOB      0x0108
#define CMD_GET_CAPSET_INFO       0x010a
#define CMD_GET_CAPSET            0x010b
#define CMD_GET_EDID              0x010c
#define CMD_UPDATE_CURSOR         0x0300
#define CMD_MOVE_CURSOR           0x0301

/* Response codes */
#define RESP_OK_NODATA        0x1100
#define RESP_OK_DISPLAY_INFO  0x1101
#define RESP_OK_CAPSET_INFO   0x1102
#define RESP_OK_CAPSET        0x1103
#define RESP_OK_EDID          0x1104
#define RESP_ERR_UNSPEC           0x1200
#define RESP_ERR_OUT_OF_MEMORY    0x1201
#define RESP_ERR_INVALID_SCANOUT_ID 0x1202
#define RESP_ERR_INVALID_RESOURCE_ID 0x1203
#define RESP_ERR_INVALID_CONTEXT_ID  0x1204
#define RESP_ERR_INVALID_PARAMETER   0x1205

#define HDR_FLAG_FENCE (1u << 0)

/* Fixed scanout geometry for stage 1: matches the ramfb preset so the iPad
   presenter and fb_stream keep their existing assumptions. The guest learns
   it from GET_DISPLAY_INFO and sizes its dumb buffers accordingly. */
#define SCANOUT_W 2048
#define SCANOUT_H 1536

/* A 2048x1536x4 scanout is ~12MB; as shmem scatter-gather its backing list
   can run to thousands of entries (the guest coalesces, QEMU allows 1024+).
   256 resources x 2048 entries keeps the static table at ~8MB. */
#define MAX_RESOURCES 256
#define MAX_BACKING_ENTRIES 2048

/* Pixel formats (virtio_gpu_formats). All are 4 bytes per pixel. */
#define FMT_B8G8R8A8_UNORM 1
#define FMT_B8G8R8X8_UNORM 2
#define FMT_A8R8G8B8_UNORM 3
#define FMT_X8R8G8B8_UNORM 4
#define FMT_R8G8B8A8_UNORM 67
#define FMT_R8G8B8X8_UNORM 68

typedef struct {
    uint64_t addr;
    uint32_t len;
} BackingEnt;

typedef struct {
    int used;
    uint32_t format;
    uint32_t width, height;
    uint8_t *host; /* width*height*4, host byte order = memory layout of guest format */
    BackingEnt backing[MAX_BACKING_ENTRIES];
    uint32_t nbacking;
    int swizzle_rb; /* guest layout is R-first (ARGB/RGBA): swap R<->B on transfer */
} GpuResource;

typedef struct HvVirtioGpu {
    HvVirtio vio;
    HvFbDisplay *fb;
    GpuResource res[MAX_RESOURCES];
    uint32_t scanout_res; /* resource id bound to scanout 0, 0 = blank */
    uint32_t scanout_x, scanout_y, scanout_w, scanout_h;
} HvVirtioGpu;

static int logging(void) {
    static int on = -1;
    if (on < 0) on = getenv("HV_GPU_LOG") != NULL;
    return on;
}

static uint32_t rd32(const uint8_t *p) { uint32_t v; memcpy(&v, p, 4); return v; }
static uint64_t rd64(const uint8_t *p) { uint64_t v; memcpy(&v, p, 8); return v; }
static void wr32(uint8_t *p, uint32_t v) { memcpy(p, &v, 4); }

/* virtio_gpu_ctrl_hdr wire layout (32 bytes with tail padding):
   type@0 flags@4 fence_id@8 ctx_id@16 ring_idx@20 */
#define HDR_LEN 32

static GpuResource *get_res(HvVirtioGpu *g, uint32_t id) {
    if (id == 0 || id >= MAX_RESOURCES) return NULL;
    return g->res[id].used ? &g->res[id] : NULL;
}

/* Copy `len` bytes from the resource's backing iov stream (starting at stream
   offset `off`) into dst, gathering across entries via guest-physical ptrs. */
static uint32_t backing_read(HvVirtioGpu *g, GpuResource *r, uint64_t off, uint8_t *dst, uint32_t len) {
    uint32_t done = 0;
    for (uint32_t i = 0; i < r->nbacking && done < len; i++) {
        uint64_t ent_end = 0;
        /* stream offset of this entry's start */
        uint64_t ent_start = 0;
        for (uint32_t j = 0; j < i; j++) ent_start += r->backing[j].len;
        ent_end = ent_start + r->backing[i].len;
        if (off + done >= ent_end) continue;
        uint64_t within = (off + done > ent_start) ? (off + done - ent_start) : 0;
        uint32_t n = (uint32_t)(r->backing[i].len - within);
        if (n > len - done) n = len - done;
        const uint8_t *p = hv_phys_ptr(g->vio.m, r->backing[i].addr + within, n);
        if (!p) break;
        memcpy(dst + done, p, n);
        done += n;
    }
    return done;
}

static void fill_resp_hdr(const uint8_t *req, uint8_t *resp, uint32_t resp_type) {
    memset(resp, 0, HDR_LEN);
    wr32(resp + 0, resp_type);
    uint32_t flags = rd32(req + 4);
    if (flags & HDR_FLAG_FENCE) {
        wr32(resp + 4, HDR_FLAG_FENCE);
        memcpy(resp + 8, req + 8, 8); /* echo fence_id */
    }
    memcpy(resp + 16, req + 16, 4); /* ctx_id echo (harmless, QEMU does the same) */
}

/* ---- command handlers: each returns bytes written into the response ---- */

static uint32_t cmd_display_info(HvVirtioGpu *g, const uint8_t *req, HvVirtqElem *e) {
    /* resp: hdr + num_scanouts(u32) + padding(u32) + 16 * {rect(16), enabled(u32), flags(u32)} = 424 */
    uint8_t resp[HDR_LEN + 8 + 16 * 24];
    fill_resp_hdr(req, resp, RESP_OK_DISPLAY_INFO);
    wr32(resp + HDR_LEN + 0, 1); /* num_scanouts */
    wr32(resp + HDR_LEN + 4, 0);
    uint8_t *pm = resp + HDR_LEN + 8;
    memset(pm, 0, 16 * 24);
    wr32(pm + 0, 0);            /* x */
    wr32(pm + 4, 0);            /* y */
    wr32(pm + 8, SCANOUT_W);    /* width */
    wr32(pm + 12, SCANOUT_H);   /* height */
    wr32(pm + 16, 1);           /* enabled */
    return hv_virtq_write(&g->vio, e, 0, resp, sizeof resp);
}

static uint32_t err_resp(HvVirtioGpu *g, const uint8_t *req, HvVirtqElem *e, uint32_t err) {
    uint8_t resp[HDR_LEN];
    fill_resp_hdr(req, resp, err);
    return hv_virtq_write(&g->vio, e, 0, resp, sizeof resp);
}

static uint32_t ok_resp(HvVirtioGpu *g, const uint8_t *req, HvVirtqElem *e) {
    uint8_t resp[HDR_LEN];
    fill_resp_hdr(req, resp, RESP_OK_NODATA);
    return hv_virtq_write(&g->vio, e, 0, resp, sizeof resp);
}

static uint32_t readable_len(const HvVirtqElem *e) {
    uint32_t n = 0;
    for (int i = 0; i < e->nseg; i++)
        if (!e->seg[i].write) n += e->seg[i].len;
    return n;
}

static uint32_t control(HvVirtioGpu *g, HvVirtqElem *e) {
    HvVirtio *v = &g->vio;
    /* The request (ATTACH_BACKING with a long iov list) can be tens of KB:
       size the buffer from the element instead of a fixed stack array. */
    static const uint8_t zero_hdr[HDR_LEN] = {0};
    uint32_t reqlen = readable_len(e);
    if (reqlen > (1u << 20)) return err_resp(g, zero_hdr, e, RESP_ERR_INVALID_PARAMETER);
    /* Commands are handled synchronously from notify() on one thread, so a
       single grow-only scratch buffer is safe (same pattern as the static
       HvVirtqElem in virtio_snd's notify). */
    static uint8_t *reqbuf;
    static uint32_t reqcap;
    if (reqlen > reqcap) {
        free(reqbuf);
        reqbuf = malloc(reqlen);
        reqcap = reqbuf ? reqlen : 0;
    }
    if (!reqbuf) return err_resp(g, zero_hdr, e, RESP_ERR_OUT_OF_MEMORY);
    uint8_t *req = reqbuf;
    uint32_t got = hv_virtq_read(v, e, 0, req, reqlen);
    if (got < HDR_LEN) return err_resp(g, req, e, RESP_ERR_INVALID_PARAMETER);
    uint32_t type = rd32(req + 0);

    switch (type) {
    case CMD_GET_DISPLAY_INFO:
        return cmd_display_info(g, req, e);

    case CMD_RESOURCE_CREATE_2D: {
        uint32_t id = rd32(req + HDR_LEN + 0);
        uint32_t format = rd32(req + HDR_LEN + 4);
        uint32_t w = rd32(req + HDR_LEN + 8);
        uint32_t h = rd32(req + HDR_LEN + 12);
        if (id == 0 || id >= MAX_RESOURCES || w == 0 || h == 0 || w > 8192 || h > 8192 ||
            (format != FMT_B8G8R8A8_UNORM && format != FMT_B8G8R8X8_UNORM &&
             format != FMT_A8R8G8B8_UNORM && format != FMT_X8R8G8B8_UNORM &&
             format != FMT_R8G8B8A8_UNORM && format != FMT_R8G8B8X8_UNORM))
            return err_resp(g, req, e, RESP_ERR_INVALID_PARAMETER);
        GpuResource *r = &g->res[id];
        free(r->host);
        memset(r, 0, sizeof *r);
        r->host = calloc((size_t)w * h, 4);
        if (!r->host) return err_resp(g, req, e, RESP_ERR_OUT_OF_MEMORY);
        r->used = 1;
        r->format = format;
        r->width = w;
        r->height = h;
        r->swizzle_rb = (format == FMT_A8R8G8B8_UNORM || format == FMT_X8R8G8B8_UNORM ||
                         format == FMT_R8G8B8A8_UNORM || format == FMT_R8G8B8X8_UNORM);
        if (logging()) fprintf(stderr, "virtio-gpu: create2d id=%u fmt=%u %ux%u\n", id, format, w, h);
        return ok_resp(g, req, e);
    }

    case CMD_RESOURCE_UNREF: {
        uint32_t id = rd32(req + HDR_LEN + 0);
        GpuResource *r = get_res(g, id);
        if (!r) return err_resp(g, req, e, RESP_ERR_INVALID_RESOURCE_ID);
        free(r->host);
        memset(r, 0, sizeof *r);
        if (g->scanout_res == id) g->scanout_res = 0;
        return ok_resp(g, req, e);
    }

    case CMD_RESOURCE_ATTACH_BACKING: {
        uint32_t id = rd32(req + HDR_LEN + 0);
        uint32_t n = rd32(req + HDR_LEN + 4);
        GpuResource *r = get_res(g, id);
        if (!r) return err_resp(g, req, e, RESP_ERR_INVALID_RESOURCE_ID);
        if (n > MAX_BACKING_ENTRIES) return err_resp(g, req, e, RESP_ERR_INVALID_PARAMETER);
        for (uint32_t i = 0; i < n; i++) {
            const uint8_t *ent = req + HDR_LEN + 8 + (size_t)i * 16;
            if ((size_t)(HDR_LEN + 8) + (size_t)(i + 1) * 16 > got)
                return err_resp(g, req, e, RESP_ERR_INVALID_PARAMETER);
            r->backing[i].addr = rd64(ent + 0);
            r->backing[i].len = rd32(ent + 8);
        }
        r->nbacking = n;
        return ok_resp(g, req, e);
    }

    case CMD_RESOURCE_DETACH_BACKING: {
        uint32_t id = rd32(req + HDR_LEN + 0);
        GpuResource *r = get_res(g, id);
        if (!r) return err_resp(g, req, e, RESP_ERR_INVALID_RESOURCE_ID);
        r->nbacking = 0;
        return ok_resp(g, req, e);
    }

    case CMD_SET_SCANOUT: {
        uint32_t x = rd32(req + HDR_LEN + 0), y = rd32(req + HDR_LEN + 4);
        uint32_t w = rd32(req + HDR_LEN + 8), h = rd32(req + HDR_LEN + 12);
        uint32_t scanout = rd32(req + HDR_LEN + 16);
        uint32_t id = rd32(req + HDR_LEN + 20);
        if (scanout != 0) return err_resp(g, req, e, RESP_ERR_INVALID_SCANOUT_ID);
        if (id != 0 && !get_res(g, id)) return err_resp(g, req, e, RESP_ERR_INVALID_RESOURCE_ID);
        g->scanout_res = id;
        g->scanout_x = x; g->scanout_y = y; g->scanout_w = w; g->scanout_h = h;
        if (logging()) fprintf(stderr, "virtio-gpu: set_scanout res=%u rect=%u,%u %ux%u\n", id, x, y, w, h);
        return ok_resp(g, req, e);
    }

    case CMD_TRANSFER_TO_HOST_2D: {
        uint32_t x = rd32(req + HDR_LEN + 0), y = rd32(req + HDR_LEN + 4);
        uint32_t w = rd32(req + HDR_LEN + 8), h = rd32(req + HDR_LEN + 12);
        uint64_t offset = rd64(req + HDR_LEN + 16);
        uint32_t id = rd32(req + HDR_LEN + 24);
        GpuResource *r = get_res(g, id);
        if (!r) return err_resp(g, req, e, RESP_ERR_INVALID_RESOURCE_ID);
        if (x + w > r->width || y + h > r->height)
            return err_resp(g, req, e, RESP_ERR_INVALID_PARAMETER);
        uint32_t gstride = r->width * 4;
        for (uint32_t row = 0; row < h; row++) {
            uint64_t soff = offset + (uint64_t)(y + row) * gstride + (uint64_t)x * 4;
            uint8_t *dst = r->host + ((size_t)(y + row) * r->width + x) * 4;
            if (backing_read(g, r, soff, dst, w * 4) != w * 4)
                return err_resp(g, req, e, RESP_ERR_INVALID_PARAMETER);
            if (r->swizzle_rb) {
                for (uint32_t px = 0; px < w; px++) {
                    uint8_t t = dst[px * 4 + 0];
                    dst[px * 4 + 0] = dst[px * 4 + 2];
                    dst[px * 4 + 2] = t;
                }
            }
        }
        return ok_resp(g, req, e);
    }

    case CMD_RESOURCE_FLUSH: {
        uint32_t x = rd32(req + HDR_LEN + 0), y = rd32(req + HDR_LEN + 4);
        uint32_t w = rd32(req + HDR_LEN + 8), h = rd32(req + HDR_LEN + 12);
        uint32_t id = rd32(req + HDR_LEN + 16);
        GpuResource *r = get_res(g, id);
        if (!r) return err_resp(g, req, e, RESP_ERR_INVALID_RESOURCE_ID);
        (void)x; (void)y; (void)w; (void)h; /* stage 1: present the whole scanout */
        if (g->fb && g->scanout_res == id) {
            uint32_t fourcc = (r->format == FMT_B8G8R8A8_UNORM) ? 0x34325241u /* AR24 */
                                                                 : 0x34325258u /* XR24 */;
            hv_fb_display_set_external(g->fb, r->host, r->width, r->height, r->width * 4, fourcc);
        }
        return ok_resp(g, req, e);
    }

    case CMD_GET_CAPSET_INFO: {
        /* num_capsets == 0, but answer politely if asked anyway. */
        uint8_t resp[HDR_LEN + 8];
        fill_resp_hdr(req, resp, RESP_OK_CAPSET_INFO);
        wr32(resp + HDR_LEN + 0, 0); /* capset_id echoed 0 */
        wr32(resp + HDR_LEN + 4, 0); /* max_size */
        return hv_virtq_write(v, e, 0, resp, sizeof resp);
    }

    case CMD_GET_CAPSET:
    case CMD_GET_EDID:
    case CMD_SET_SCANOUT_BLOB:
        return err_resp(g, req, e, RESP_ERR_INVALID_PARAMETER);

    default:
        if (logging()) fprintf(stderr, "virtio-gpu: unknown cmd %#x\n", type);
        return err_resp(g, req, e, RESP_ERR_UNSPEC);
    }
}

static void notify(HvVirtio *v, int q) {
    HvVirtioGpu *g = v->dev;
    static HvVirtqElem e;
    if (q == CTRLQ) {
        int any = 0;
        while (hv_virtq_pop(v, q, &e) > 0) {
            hv_virtq_push(v, q, &e, control(g, &e));
            any = 1;
        }
        if (any) hv_virtio_interrupt(v);
    } else if (q == CURSORQ) {
        /* Stage 1: drain cursor commands, no response payload (spec). */
        int any = 0;
        while (hv_virtq_pop(v, q, &e) > 0) {
            hv_virtq_push(v, q, &e, 0);
            any = 1;
        }
        if (any) hv_virtio_interrupt(v);
    }
}

static void config_write(HvVirtio *v, uint32_t off, uint64_t val, unsigned size) {
    /* virtio_gpu_config: events_read@0, events_clear@4, num_scanouts@8, num_capsets@12.
       Writes to events_clear clear the matching events_read bits. */
    if (off == 4 && size >= 4) {
        uint32_t ev;
        memcpy(&ev, v->config, 4);
        ev &= ~(uint32_t)val;
        memcpy(v->config, &ev, 4);
        v->config_gen++;
    }
}

HvVirtioGpu *hv_virtio_gpu_create(HvMachine *m, HvPcie *bus, HvFbDisplay *fb) {
    HvVirtioGpu *g = calloc(1, sizeof *g);
    HvVirtio *v = &g->vio;
    g->fb = fb;
    hv_virtio_init(v, m, 16, 0x030000, 2, 0); /* GPU device, display class */
    v->dev = g;
    v->notify = notify;
    v->config_write = config_write;
    wr32(v->config + 0, 0);  /* events_read */
    wr32(v->config + 4, 0);  /* events_clear */
    wr32(v->config + 8, 1);  /* num_scanouts */
    wr32(v->config + 12, 0); /* num_capsets */
    v->config_len = 16;
    hv_pcie_attach(bus, &v->pci);
    if (logging()) fprintf(stderr, "virtio-gpu: created (2D scanout, %dx%d)\n", SCANOUT_W, SCANOUT_H);
    return g;
}
