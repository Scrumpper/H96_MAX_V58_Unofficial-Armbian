// ddc-edid-read.c — bit-banged E-DDC EDID read over the Linux GPIO chardev uAPI v2.
//
// Why this exists: the vendor 6.1.115 kernel's HDMI DDC i2c controller never
// completes a transaction on the H96 Max V58 (root-caused, closed, not fixable
// at our layer), but Android on the same board reads EDID fine — so the wires,
// pull-ups and the TV are all good. We therefore steal the two DDC pins as
// plain GPIOs and speak i2c ourselves, slowly and defensively.
//
// SAFETY: /dev/gpiochipN character-device uAPI ONLY (same rule as the VFD
// bit-bang precedent). No /dev/mem (VO1/HDMI register space hard-hangs the
// SoC), no sysfs gpio, no external libraries — the uAPI v2 structs are
// declared inline below, byte-for-byte matching include/uapi/linux/gpio.h.
// Requesting the lines makes rockchip pinctrl re-mux them from the (dead)
// hdmim0 DDC function to GPIO; a reboot restores the original mux.
//
// Usage:
//   ddc-edid-read <gpiochip> <scl-offset> <sda-offset>
//                 [--hz N] [--blocks auto|N] [--label NAME]
//   e.g.  ddc-edid-read /dev/gpiochip4 15 16 --label gpio4
//         (GPIO4_B7 = SCL = line 15, GPIO4_C0 = SDA = line 16)
//
// --label NAME refuses to touch the chip unless its GPIO_GET_CHIPINFO label
// matches NAME exactly — guards against gpiochip renumbering putting some
// other bank at /dev/gpiochip4.
//
// Output: raw EDID bytes on stdout (binary), human-readable summary on stderr.
// Exit codes: 0 ok, 1 usage/system error (incl. label mismatch, EBUSY),
//             2 no-ack/no-device/bus-hung, 3 bad EDID header, 4 bad checksum.
//
// Build (dev box, npuload precedent — target image has no compiler):
//   aarch64-linux-gnu-gcc -O2 -Wall -Wextra -static -o ddc-edid-read ddc-edid-read.c

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <errno.h>
#include <fcntl.h>
#include <unistd.h>
#include <time.h>
#include <sys/ioctl.h>

/* ------------------------------------------------------------------ */
/* GPIO uAPI v2 — verbatim layouts from include/uapi/linux/gpio.h.    */
/* Declared locally so this builds anywhere with no kernel headers.   */
/* ------------------------------------------------------------------ */

#define GPIO_MAX_NAME_SIZE        32
#define GPIO_V2_LINES_MAX         64
#define GPIO_V2_LINE_NUM_ATTRS_MAX 10

#define GPIO_V2_LINE_FLAG_INPUT        (1ULL << 2)
#define GPIO_V2_LINE_FLAG_OUTPUT       (1ULL << 3)
#define GPIO_V2_LINE_FLAG_OPEN_DRAIN   (1ULL << 6)
#define GPIO_V2_LINE_FLAG_BIAS_PULL_UP (1ULL << 8)

#define GPIO_V2_LINE_ATTR_ID_OUTPUT_VALUES 2

struct gpiochip_info {
    char name[GPIO_MAX_NAME_SIZE];
    char label[GPIO_MAX_NAME_SIZE];
    uint32_t lines;
};

struct gpio_v2_line_attribute {
    uint32_t id;
    uint32_t padding;
    union {
        uint64_t flags;
        uint64_t values;
        uint32_t debounce_period_us;
    };
};

struct gpio_v2_line_config_attribute {
    struct gpio_v2_line_attribute attr;
    uint64_t mask;
};

struct gpio_v2_line_config {
    uint64_t flags;
    uint32_t num_attrs;
    uint32_t padding[5];
    struct gpio_v2_line_config_attribute attrs[GPIO_V2_LINE_NUM_ATTRS_MAX];
};

struct gpio_v2_line_request {
    uint32_t offsets[GPIO_V2_LINES_MAX];
    char consumer[GPIO_MAX_NAME_SIZE];
    struct gpio_v2_line_config config;
    uint32_t num_lines;
    uint32_t event_buffer_size;
    uint32_t padding[5];
    int32_t fd;
};

struct gpio_v2_line_values {
    uint64_t bits;
    uint64_t mask;
};

#define GPIO_GET_CHIPINFO_IOCTL       _IOR(0xB4, 0x01, struct gpiochip_info)
#define GPIO_V2_GET_LINE_IOCTL        _IOWR(0xB4, 0x07, struct gpio_v2_line_request)
#define GPIO_V2_LINE_GET_VALUES_IOCTL _IOWR(0xB4, 0x0E, struct gpio_v2_line_values)
#define GPIO_V2_LINE_SET_VALUES_IOCTL _IOWR(0xB4, 0x0F, struct gpio_v2_line_values)

/* ------------------------------------------------------------------ */
/* Constants and globals                                              */
/* ------------------------------------------------------------------ */

#define IDX_SCL 0                     /* bit index within our 2-line request */
#define IDX_SDA 1

#define EDID_BLOCK_SIZE   128
#define MAX_BLOCKS        8           /* sane cap; real TVs ship 1-4 blocks  */
#define BLOCK_RETRIES     3
#define STRETCH_TIMEOUT_NS 100000000L /* 100 ms of clock stretching allowed  */

#define RC_OK      0
#define RC_BUS    -1                  /* SCL never released — bus hung       */
#define RC_NOACK  -2                  /* device NACKed an address/data byte  */

static int  g_line_fd  = -1;
static long g_half_ns  = 250000;      /* half-bit at the default 2 kHz       */

static const uint8_t EDID_HEADER[8] =
    { 0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x00 };

/* ------------------------------------------------------------------ */
/* Line-level helpers                                                 */
/* ------------------------------------------------------------------ */

static void die(const char *what) {
    fprintf(stderr, "ddc-edid-read: %s: %s\n", what, strerror(errno));
    exit(1);
}

static void delay_half(void) {
    struct timespec ts = { 0, g_half_ns };
    nanosleep(&ts, NULL);
}

/* Open-drain semantics: writing 1 RELEASES the line (pull-ups take it high),
 * writing 0 actively drives it low. The kernel emulates this for us because
 * the lines were requested OUTPUT|OPEN_DRAIN. */
static void set_line(int idx, int val) {
    struct gpio_v2_line_values lv;
    memset(&lv, 0, sizeof(lv));
    lv.mask = 1ULL << idx;
    lv.bits = (uint64_t)(val ? 1 : 0) << idx;
    if (ioctl(g_line_fd, GPIO_V2_LINE_SET_VALUES_IOCTL, &lv) < 0)
        die("SET_VALUES ioctl");
}

/* Reads the ACTUAL wire state (rockchip reads the external-port register even
 * for output lines), which is what lets us see ACKs and clock stretching. */
static int get_line(int idx) {
    struct gpio_v2_line_values lv;
    memset(&lv, 0, sizeof(lv));
    lv.mask = 1ULL << idx;
    if (ioctl(g_line_fd, GPIO_V2_LINE_GET_VALUES_IOCTL, &lv) < 0)
        die("GET_VALUES ioctl");
    return (lv.bits >> idx) & 1;
}

/* Release SCL and wait for it to actually rise. A sink is allowed to hold
 * SCL low (clock stretching) for as long as it likes; we allow 100 ms. */
static int scl_release_wait(void) {
    set_line(IDX_SCL, 1);
    long waited = 0;
    for (;;) {
        if (get_line(IDX_SCL))
            return RC_OK;
        if (waited >= STRETCH_TIMEOUT_NS)
            return RC_BUS;
        delay_half();
        waited += g_half_ns;
    }
}

/* ------------------------------------------------------------------ */
/* i2c bit-bang primitives (SDA only ever changes while SCL is low,   */
/* except inside START/STOP where the change IS the condition)        */
/* ------------------------------------------------------------------ */

/* Works both as initial START (bus idle, both high) and repeated START
 * (SCL currently held low): release SDA, raise SCL, then drop SDA. */
static int i2c_start(void) {
    set_line(IDX_SDA, 1);
    delay_half();
    if (scl_release_wait()) return RC_BUS;
    delay_half();
    set_line(IDX_SDA, 0);
    delay_half();
    set_line(IDX_SCL, 0);
    delay_half();
    return RC_OK;
}

static int i2c_stop(void) {
    set_line(IDX_SDA, 0);
    delay_half();
    if (scl_release_wait()) return RC_BUS;
    delay_half();
    set_line(IDX_SDA, 1);      /* SDA rises while SCL high = STOP */
    delay_half();
    return RC_OK;
}

/* Returns RC_OK on ACK, RC_NOACK on NACK, RC_BUS on a hung clock. */
static int i2c_write_byte(uint8_t b) {
    for (int i = 7; i >= 0; i--) {
        set_line(IDX_SDA, (b >> i) & 1);
        delay_half();
        if (scl_release_wait()) return RC_BUS;
        delay_half();
        set_line(IDX_SCL, 0);
    }
    /* 9th clock: release SDA and sample the sink's ACK (low = acked) */
    set_line(IDX_SDA, 1);
    delay_half();
    if (scl_release_wait()) return RC_BUS;
    int nack = get_line(IDX_SDA);
    delay_half();
    set_line(IDX_SCL, 0);
    return nack ? RC_NOACK : RC_OK;
}

/* Returns the byte (0..255), or RC_BUS on a hung clock.
 * ack != 0 -> we ACK (more bytes wanted); ack == 0 -> NACK (final byte). */
static int i2c_read_byte(int ack) {
    int b = 0;
    set_line(IDX_SDA, 1);              /* released so the sink can drive it */
    for (int i = 0; i < 8; i++) {
        delay_half();
        if (scl_release_wait()) return RC_BUS;
        b = (b << 1) | get_line(IDX_SDA);
        delay_half();
        set_line(IDX_SCL, 0);
    }
    set_line(IDX_SDA, ack ? 0 : 1);    /* drive low to ACK, release to NACK */
    delay_half();
    if (scl_release_wait()) return RC_BUS;
    delay_half();
    set_line(IDX_SCL, 0);
    set_line(IDX_SDA, 1);
    return b;
}

/* Standard i2c bus-clear: if a sink was left mid-byte holding SDA low,
 * clocking SCL up to ~9 extra times lets it finish and release the bus. */
static void i2c_bus_clear(void) {
    if (get_line(IDX_SDA))
        return;                        /* bus already free */
    fprintf(stderr, "ddc-edid-read: SDA stuck low, attempting bus clear\n");
    for (int i = 0; i < 16 && !get_line(IDX_SDA); i++) {
        set_line(IDX_SCL, 0);
        delay_half();
        if (scl_release_wait()) break;
        delay_half();
    }
    i2c_stop();
}

/* ------------------------------------------------------------------ */
/* E-DDC block read                                                   */
/* ------------------------------------------------------------------ */

/* One whole E-DDC transaction, no intermediate STOPs (the VESA segment
 * pointer is volatile — a STOP may reset it, so segment write, offset
 * write and the 128-byte read must be chained with repeated STARTs):
 *
 *   [S] 0x60 seg  [Sr] 0xA0 off  [Sr] 0xA1 d0..d127(NACK last) [P]
 *
 * The 0x60 segment stage is skipped for blocks 0/1 (segment 0) so plain
 * DDC2B monitors that don't implement E-DDC are never bothered by it. */
static int read_block(int seg, uint8_t off, uint8_t *buf) {
    int rc;

    if ((rc = i2c_start()) != RC_OK) goto out;

    if (seg > 0) {
        if ((rc = i2c_write_byte(0x60)) != RC_OK) goto out; /* segment ptr addr */
        rc = i2c_write_byte((uint8_t)seg);
        if (rc == RC_BUS) goto out;
        if (rc == RC_NOACK)                 /* some sinks NACK the segment    */
            fprintf(stderr, "ddc-edid-read: warn: segment byte NACKed, "
                            "continuing (permitted by E-DDC)\n");
        if ((rc = i2c_start()) != RC_OK) goto out;          /* repeated START */
    }

    if ((rc = i2c_write_byte(0xA0)) != RC_OK) goto out;     /* 0x50 write     */
    if ((rc = i2c_write_byte(off)) != RC_OK) goto out;      /* word offset    */
    if ((rc = i2c_start()) != RC_OK) goto out;              /* repeated START */
    if ((rc = i2c_write_byte(0xA1)) != RC_OK) goto out;     /* 0x50 read      */

    for (int i = 0; i < EDID_BLOCK_SIZE; i++) {
        int v = i2c_read_byte(i < EDID_BLOCK_SIZE - 1);     /* NACK the last  */
        if (v < 0) { rc = v; goto out; }
        buf[i] = (uint8_t)v;
    }
    rc = RC_OK;
out:
    i2c_stop();                       /* always leave the bus released */
    return rc;
}

static int checksum_ok(const uint8_t *blk) {
    uint8_t sum = 0;
    for (int i = 0; i < EDID_BLOCK_SIZE; i++)
        sum = (uint8_t)(sum + blk[i]);
    return sum == 0;                  /* all 128 bytes must sum to 0 mod 256 */
}

/* ------------------------------------------------------------------ */
/* Human summary (stderr only — stdout carries the raw bytes)         */
/* ------------------------------------------------------------------ */

static void summarize(const uint8_t *edid, int nblocks) {
    /* Manufacturer PNP id: bytes 8-9, big-endian, three 5-bit letters */
    uint16_t m = (uint16_t)((edid[8] << 8) | edid[9]);
    char mfg[4] = {
        (char)('A' - 1 + ((m >> 10) & 0x1F)),
        (char)('A' - 1 + ((m >> 5) & 0x1F)),
        (char)('A' - 1 + (m & 0x1F)), 0
    };
    fprintf(stderr, "EDID: mfg=%s product=0x%04X blocks=%d\n",
            mfg, edid[10] | (edid[11] << 8), nblocks);

    /* Preferred mode = first detailed timing descriptor, bytes 54-71 */
    const uint8_t *d = edid + 54;
    long clk10k = d[0] | (d[1] << 8);            /* pixel clock, 10 kHz units */
    if (clk10k) {
        long ha = d[2] | ((d[4] >> 4) << 8),  hb = d[3] | ((d[4] & 0xF) << 8);
        long va = d[5] | ((d[7] >> 4) << 8),  vb = d[6] | ((d[7] & 0xF) << 8);
        long ht = ha + hb, vt = va + vb;
        if (ht > ha && vt > va)
            fprintf(stderr, "EDID: preferred %ldx%ld @ %.2f Hz (%.2f MHz)\n",
                    ha, va, clk10k * 10000.0 / (ht * vt), clk10k / 100.0);
        else
            fprintf(stderr, "EDID: preferred DTD has non-positive blanking "
                            "(suspect)\n");
    } else {
        fprintf(stderr, "EDID: no preferred detailed timing descriptor\n");
    }

    /* CEA/CTA-861 extension = HDMI audio capability (the v3.4 hard rule:
     * no CEA block -> HDMI audio cannot work on this image) */
    int cea = 0;
    for (int b = 1; b < nblocks; b++)
        if (edid[b * EDID_BLOCK_SIZE] == 0x02) cea = 1;
    fprintf(stderr, "EDID: CEA-861 extension %s\n",
            cea ? "present (HDMI audio possible)"
                : "ABSENT (HDMI audio will not work)");
}

/* ------------------------------------------------------------------ */
/* main                                                               */
/* ------------------------------------------------------------------ */

static void usage(void) {
    fprintf(stderr,
        "usage: ddc-edid-read <gpiochip> <scl-offset> <sda-offset>"
        " [--hz N] [--blocks auto|N] [--label NAME]\n"
        "  e.g. ddc-edid-read /dev/gpiochip4 15 16 --label gpio4\n");
    exit(1);
}

int main(int argc, char **argv) {
    if (argc < 4) usage();

    const char *chip_path = argv[1];
    char *end = NULL;
    long scl = strtol(argv[2], &end, 0);
    if (!end || *end || scl < 0 || scl > 63) usage();
    long sda = strtol(argv[3], &end, 0);
    if (!end || *end || sda < 0 || sda > 63) usage();
    if (scl == sda) { fprintf(stderr, "scl and sda must differ\n"); return 1; }

    long hz = 2000;
    int  forced_blocks = 0;           /* 0 = auto (follow byte 126) */
    const char *want_label = NULL;    /* --label: refuse a mislabelled chip */
    for (int i = 4; i < argc; i++) {
        if (!strcmp(argv[i], "--hz") && i + 1 < argc) {
            hz = strtol(argv[++i], &end, 0);
            if (!end || *end) usage();
        } else if (!strcmp(argv[i], "--blocks") && i + 1 < argc) {
            i++;
            if (strcmp(argv[i], "auto")) {
                forced_blocks = (int)strtol(argv[i], &end, 0);
                if (!end || *end || forced_blocks < 1 ||
                    forced_blocks > MAX_BLOCKS) usage();
            }
        } else if (!strcmp(argv[i], "--label") && i + 1 < argc) {
            want_label = argv[++i];
        } else usage();
    }
    if (hz < 100 || hz > 100000) {    /* DDC certification caps at 100 kHz */
        fprintf(stderr, "ddc-edid-read: clamping --hz %ld into 100..100000\n", hz);
        hz = hz < 100 ? 100 : 100000;
    }
    g_half_ns = 1000000000L / (2 * hz);

    /* --- open chip, sanity-check its label ------------------------- */
    int chip_fd = open(chip_path, O_RDWR | O_CLOEXEC);
    if (chip_fd < 0) die(chip_path);

    struct gpiochip_info ci;
    memset(&ci, 0, sizeof(ci));
    if (ioctl(chip_fd, GPIO_GET_CHIPINFO_IOCTL, &ci) < 0)
        die("CHIPINFO ioctl (not a gpiochip?)");
    fprintf(stderr, "ddc-edid-read: %s label=%s lines=%u, scl=%ld sda=%ld @ %ld Hz\n",
            chip_path, ci.label, ci.lines, scl, sda, hz);
    if (want_label && strncmp(ci.label, want_label, GPIO_MAX_NAME_SIZE) != 0) {
        fprintf(stderr, "ddc-edid-read: %s label is '%s', expected '%s' — "
                "refusing (gpiochip numbering changed?)\n",
                chip_path, ci.label, want_label);
        return 1;
    }
    if ((uint32_t)scl >= ci.lines || (uint32_t)sda >= ci.lines) {
        fprintf(stderr, "ddc-edid-read: offset beyond chip's %u lines\n", ci.lines);
        return 1;
    }

    /* --- request both lines: OUTPUT + OPEN_DRAIN, released high.    */
    /* Kernel rejects OPEN_DRAIN|INPUT, so both stay OUTPUT and we    */
    /* "read" via the external-port register. Internal pull-up is a   */
    /* belt-and-braces extra on top of the board's own DDC pull-ups.  */
    struct gpio_v2_line_request req;
    memset(&req, 0, sizeof(req));
    req.offsets[IDX_SCL] = (uint32_t)scl;
    req.offsets[IDX_SDA] = (uint32_t)sda;
    req.num_lines = 2;
    snprintf(req.consumer, sizeof(req.consumer), "ddc-edid-read");
    req.config.flags = GPIO_V2_LINE_FLAG_OUTPUT | GPIO_V2_LINE_FLAG_OPEN_DRAIN |
                       GPIO_V2_LINE_FLAG_BIAS_PULL_UP;
    req.config.num_attrs = 1;         /* initial values: both released (1) */
    req.config.attrs[0].attr.id = GPIO_V2_LINE_ATTR_ID_OUTPUT_VALUES;
    req.config.attrs[0].attr.values = 0x3;
    req.config.attrs[0].mask = 0x3;
    if (ioctl(chip_fd, GPIO_V2_GET_LINE_IOCTL, &req) < 0)
        die("GET_LINE ioctl (EBUSY = a kernel driver holds the line)");
    g_line_fd = req.fd;

    /* --- bring the bus to a known-idle state ----------------------- */
    delay_half();
    i2c_bus_clear();
    if (scl_release_wait() != RC_OK) {
        fprintf(stderr, "ddc-edid-read: SCL stuck low, bus unusable\n");
        return 2;
    }

    /* --- read blocks, each with retries ---------------------------- */
    static uint8_t edid[MAX_BLOCKS * EDID_BLOCK_SIZE];
    int total = 1;                    /* learned from byte 126 after block 0 */

    for (int b = 0; b < total; b++) {
        uint8_t *blk = edid + b * EDID_BLOCK_SIZE;
        int seg = b / 2;
        uint8_t off = (b & 1) ? 0x80 : 0x00;
        int fail_code = 2;            /* worst failure of the final attempt */

        for (int attempt = 1; attempt <= BLOCK_RETRIES; attempt++) {
            int rc = read_block(seg, off, blk);
            if (rc != RC_OK) {
                fail_code = 2;
                fprintf(stderr, "ddc-edid-read: block %d attempt %d: %s\n",
                        b, attempt,
                        rc == RC_NOACK ? "no ack (no device?)" : "bus hung");
            } else if (b == 0 && memcmp(blk, EDID_HEADER, 8) != 0) {
                fail_code = 3;
                fprintf(stderr, "ddc-edid-read: block 0 attempt %d: bad header "
                        "%02X %02X %02X %02X %02X %02X %02X %02X\n", attempt,
                        blk[0], blk[1], blk[2], blk[3],
                        blk[4], blk[5], blk[6], blk[7]);
            } else if (!checksum_ok(blk)) {
                fail_code = 4;
                fprintf(stderr, "ddc-edid-read: block %d attempt %d: bad "
                        "checksum\n", b, attempt);
            } else {
                fail_code = 0;        /* clean read */
                break;
            }
            /* settle + recover before the retry */
            i2c_bus_clear();
            struct timespec pause = { 0, 20000000 };  /* 20 ms */
            nanosleep(&pause, NULL);
        }
        if (fail_code) return fail_code;

        if (b == 0) {
            if (forced_blocks) {
                total = forced_blocks;
            } else {
                total = 1 + blk[126];
                if (total > MAX_BLOCKS) {
                    fprintf(stderr, "ddc-edid-read: byte 126 claims %d "
                            "extensions, capping at %d total blocks\n",
                            blk[126], MAX_BLOCKS);
                    total = MAX_BLOCKS;
                }
            }
        }
    }

    /* --- report + emit --------------------------------------------- */
    summarize(edid, total);
    if (isatty(STDOUT_FILENO))
        fprintf(stderr, "ddc-edid-read: warn: writing binary EDID to a tty "
                "(redirect stdout to a file)\n");
    if (fwrite(edid, 1, (size_t)total * EDID_BLOCK_SIZE, stdout) !=
        (size_t)total * EDID_BLOCK_SIZE || fflush(stdout) != 0)
        die("writing EDID to stdout");

    close(g_line_fd);
    close(chip_fd);
    return 0;
}
