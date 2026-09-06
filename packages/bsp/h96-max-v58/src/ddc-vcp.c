// ddc-vcp — read/write DDC/CI VCP features (e.g. brightness 0x10) over a
// bit-banged i2c bus on the HDMI DDC pins, for the H96 Max V58 (RK3588) whose
// HDMI DDC i2c *controller* never completes a transaction on this kernel.
//
// The wires work (stock Android reads EDID over them; ddc-edid-read proves the
// bit-bang bus). DDC/CI is just more i2c traffic on the same two pins, to the
// display's MCCS slave address 0x37 (write 0x6E, read 0x6F) instead of the EDID
// slave 0x50.
//
// The GPIO/i2c layer below is copied verbatim from ddc-edid-read.c (proven on
// hardware). Only the transaction layer differs.  Character-device GPIO uAPI
// only — NEVER /dev/mem near the HDMI blocks (it hard-hangs this SoC).
//
//   ddc-vcp <gpiochip> <scl> <sda> get <vcp>            [--hz N] [--label NAME]
//   ddc-vcp <gpiochip> <scl> <sda> set <vcp> <value>    [--hz N] [--label NAME]
//   e.g.  ddc-vcp /dev/gpiochip4 15 16 get 0x10   (brightness)
//
// Exit codes: 0 ok, 1 usage/system/label/EBUSY, 2 no ACK from 0x37 (the display
// does not speak DDC/CI on this input), 3 malformed/again reply, 4 bad checksum.

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <errno.h>
#include <fcntl.h>
#include <unistd.h>
#include <time.h>
#include <sys/ioctl.h>

/* ---- GPIO uAPI v2 (subset; identical to ddc-edid-read.c) --------- */
#define GPIO_MAX_NAME_SIZE        32
#define GPIO_V2_LINES_MAX         64
#define GPIO_V2_LINE_NUM_ATTRS_MAX 10
#define GPIO_V2_LINE_FLAG_INPUT        (1ULL << 2)
#define GPIO_V2_LINE_FLAG_OUTPUT       (1ULL << 3)
#define GPIO_V2_LINE_FLAG_OPEN_DRAIN   (1ULL << 6)
#define GPIO_V2_LINE_FLAG_BIAS_PULL_UP (1ULL << 8)
#define GPIO_V2_LINE_ATTR_ID_OUTPUT_VALUES 2

struct gpiochip_info { char name[GPIO_MAX_NAME_SIZE]; char label[GPIO_MAX_NAME_SIZE]; uint32_t lines; };
struct gpio_v2_line_attribute { uint32_t id; uint32_t padding; union { uint64_t flags; uint64_t values; uint32_t debounce_period_us; }; };
struct gpio_v2_line_config_attribute { struct gpio_v2_line_attribute attr; uint64_t mask; };
struct gpio_v2_line_config { uint64_t flags; uint32_t num_attrs; uint32_t padding[5]; struct gpio_v2_line_config_attribute attrs[GPIO_V2_LINE_NUM_ATTRS_MAX]; };
struct gpio_v2_line_request { uint32_t offsets[GPIO_V2_LINES_MAX]; char consumer[GPIO_MAX_NAME_SIZE]; struct gpio_v2_line_config config; uint32_t num_lines; uint32_t event_buffer_size; uint32_t padding[5]; int32_t fd; };
struct gpio_v2_line_values { uint64_t bits; uint64_t mask; };
#define GPIO_GET_CHIPINFO_IOCTL       _IOR(0xB4, 0x01, struct gpiochip_info)
#define GPIO_V2_GET_LINE_IOCTL        _IOWR(0xB4, 0x07, struct gpio_v2_line_request)
#define GPIO_V2_LINE_GET_VALUES_IOCTL _IOWR(0xB4, 0x0E, struct gpio_v2_line_values)
#define GPIO_V2_LINE_SET_VALUES_IOCTL _IOWR(0xB4, 0x0F, struct gpio_v2_line_values)

#define IDX_SCL 0
#define IDX_SDA 1
#define STRETCH_TIMEOUT_NS 100000000L

#define RC_OK    0
#define RC_BUS  -1
#define RC_NOACK -2

/* DDC/CI addressing */
#define DDC_ADDR_W 0x6E     /* 0x37 << 1 | 0  (write) */
#define DDC_ADDR_R 0x6F     /* 0x37 << 1 | 1  (read)  */
#define DDC_SRC    0x51     /* host "virtual" source address in requests */
#define DDC_HOSTD  0x50     /* host virtual dest addr — seeds reply checksum */

static int  g_line_fd = -1;
static long g_half_ns = 250000;

static void die(const char *what) { fprintf(stderr, "ddc-vcp: %s: %s\n", what, strerror(errno)); exit(1); }
static void delay_half(void) { struct timespec ts = { 0, g_half_ns }; nanosleep(&ts, NULL); }
static void delay_ms(long ms) { struct timespec ts = { ms / 1000, (ms % 1000) * 1000000L }; nanosleep(&ts, NULL); }

static void set_line(int idx, int val) {
    struct gpio_v2_line_values lv; memset(&lv, 0, sizeof(lv));
    lv.mask = 1ULL << idx; lv.bits = (uint64_t)(val ? 1 : 0) << idx;
    if (ioctl(g_line_fd, GPIO_V2_LINE_SET_VALUES_IOCTL, &lv) < 0) die("SET_VALUES ioctl");
}
static int get_line(int idx) {
    struct gpio_v2_line_values lv; memset(&lv, 0, sizeof(lv));
    lv.mask = 1ULL << idx;
    if (ioctl(g_line_fd, GPIO_V2_LINE_GET_VALUES_IOCTL, &lv) < 0) die("GET_VALUES ioctl");
    return (lv.bits >> idx) & 1;
}
static int scl_release_wait(void) {
    set_line(IDX_SCL, 1); long waited = 0;
    for (;;) { if (get_line(IDX_SCL)) return RC_OK; if (waited >= STRETCH_TIMEOUT_NS) return RC_BUS; delay_half(); waited += g_half_ns; }
}
static int i2c_start(void) {
    set_line(IDX_SDA, 1); delay_half();
    if (scl_release_wait()) return RC_BUS; delay_half();
    set_line(IDX_SDA, 0); delay_half(); set_line(IDX_SCL, 0); delay_half(); return RC_OK;
}
static int i2c_stop(void) {
    set_line(IDX_SDA, 0); delay_half();
    if (scl_release_wait()) return RC_BUS; delay_half();
    set_line(IDX_SDA, 1); delay_half(); return RC_OK;
}
static int i2c_write_byte(uint8_t b) {
    for (int i = 7; i >= 0; i--) { set_line(IDX_SDA, (b >> i) & 1); delay_half();
        if (scl_release_wait()) return RC_BUS; delay_half(); set_line(IDX_SCL, 0); }
    set_line(IDX_SDA, 1); delay_half();
    if (scl_release_wait()) return RC_BUS;
    int nack = get_line(IDX_SDA); delay_half(); set_line(IDX_SCL, 0);
    return nack ? RC_NOACK : RC_OK;
}
static int i2c_read_byte(int ack) {
    int b = 0; set_line(IDX_SDA, 1);
    for (int i = 0; i < 8; i++) { delay_half();
        if (scl_release_wait()) return RC_BUS; b = (b << 1) | get_line(IDX_SDA); delay_half(); set_line(IDX_SCL, 0); }
    set_line(IDX_SDA, ack ? 0 : 1); delay_half();
    if (scl_release_wait()) return RC_BUS; delay_half(); set_line(IDX_SCL, 0); set_line(IDX_SDA, 1);
    return b;
}
static void i2c_bus_clear(void) {
    if (get_line(IDX_SDA)) return;
    fprintf(stderr, "ddc-vcp: SDA stuck low, attempting bus clear\n");
    for (int i = 0; i < 16 && !get_line(IDX_SDA); i++) { set_line(IDX_SCL, 0); delay_half();
        if (scl_release_wait()) break; delay_half(); }
    i2c_stop();
}

/* ------------------------------------------------------------------ */
/* DDC/CI transaction layer                                           */
/* ------------------------------------------------------------------ */

/* Send an MCCS message. `data` is the payload counted by the length byte,
 * e.g. {0x01,0x10} for "Get VCP brightness".  On the wire:
 *   [S] 0x6E  0x51  (0x80|dlen)  data...  chk  [P]
 * checksum = XOR of the destination write-address 0x6E, the source 0x51,
 * the length byte and every payload byte. */
static int ddc_send(const uint8_t *data, int dlen) {
    uint8_t lenb = (uint8_t)(0x80 | dlen);
    uint8_t chk = DDC_ADDR_W ^ DDC_SRC ^ lenb;
    for (int i = 0; i < dlen; i++) chk ^= data[i];
    int rc;
    if ((rc = i2c_start()) != RC_OK) goto out;
    if ((rc = i2c_write_byte(DDC_ADDR_W)) != RC_OK) goto out;   /* no ACK here => 0x37 absent */
    if ((rc = i2c_write_byte(DDC_SRC))    != RC_OK) goto out;
    if ((rc = i2c_write_byte(lenb))       != RC_OK) goto out;
    for (int i = 0; i < dlen; i++)
        if ((rc = i2c_write_byte(data[i])) != RC_OK) goto out;
    rc = i2c_write_byte(chk);
out:
    i2c_stop();
    return rc;
}

/* Read a reply frame from 0x6F into buf (up to cap bytes).  Frame:
 *   0x6E  (0x80|N)  data[N]  chk       (total N+3 bytes)
 * Returns total bytes read, or negative RC_* on a bus/ack failure.
 * A "null message" (len 0x80, 0 data bytes) is a valid frame the caller
 * interprets as unsupported/not-ready. */
static int ddc_recv(uint8_t *buf, int cap) {
    int rc, n = 0;
    if ((rc = i2c_start()) != RC_OK) { i2c_stop(); return rc; }
    if ((rc = i2c_write_byte(DDC_ADDR_R)) != RC_OK) { i2c_stop(); return rc; } /* NOACK => 0x37 absent */

    int src = i2c_read_byte(1); if (src < 0) { i2c_stop(); return RC_BUS; }
    int len = i2c_read_byte(1); if (len < 0) { i2c_stop(); return RC_BUS; }
    if (cap >= 1) buf[n++] = (uint8_t)src;
    if (cap >= 2) buf[n++] = (uint8_t)len;
    int ndata = len & 0x7F;                       /* strip the 0x80 protocol flag */
    int remaining = ndata + 1;                    /* data bytes + checksum */
    for (int i = 0; i < remaining; i++) {
        int last = (i == remaining - 1);
        int v = i2c_read_byte(last ? 0 : 1);      /* NACK only the final byte */
        if (v < 0) { i2c_stop(); return RC_BUS; }
        if (n < cap) buf[n++] = (uint8_t)v;
    }
    i2c_stop();
    return n;
}

/* Reply checksum: XOR of the host virtual dest 0x50 and every received byte
 * (including the trailing checksum) must be zero. */
static int reply_checksum_ok(const uint8_t *buf, int n) {
    uint8_t x = DDC_HOSTD;
    for (int i = 0; i < n; i++) x ^= buf[i];
    return x == 0;
}

/* ------------------------------------------------------------------ */
/* GPIO setup (identical policy to ddc-edid-read.c)                   */
/* ------------------------------------------------------------------ */
static int setup_lines(const char *chip_path, long scl, long sda, const char *want_label) {
    int chip_fd = open(chip_path, O_RDWR | O_CLOEXEC);
    if (chip_fd < 0) die(chip_path);
    struct gpiochip_info ci; memset(&ci, 0, sizeof(ci));
    if (ioctl(chip_fd, GPIO_GET_CHIPINFO_IOCTL, &ci) < 0) die("CHIPINFO ioctl (not a gpiochip?)");
    fprintf(stderr, "ddc-vcp: %s label=%s lines=%u, scl=%ld sda=%ld @ %ld Hz\n",
            chip_path, ci.label, ci.lines, scl, sda, 1000000000L / (2 * g_half_ns));
    if (want_label && strncmp(ci.label, want_label, GPIO_MAX_NAME_SIZE) != 0) {
        fprintf(stderr, "ddc-vcp: %s label is '%s', expected '%s' — refusing\n", chip_path, ci.label, want_label);
        exit(1);
    }
    if ((uint32_t)scl >= ci.lines || (uint32_t)sda >= ci.lines) { fprintf(stderr, "ddc-vcp: offset beyond chip lines\n"); exit(1); }
    struct gpio_v2_line_request req; memset(&req, 0, sizeof(req));
    req.offsets[IDX_SCL] = (uint32_t)scl; req.offsets[IDX_SDA] = (uint32_t)sda; req.num_lines = 2;
    snprintf(req.consumer, sizeof(req.consumer), "ddc-vcp");
    req.config.flags = GPIO_V2_LINE_FLAG_OUTPUT | GPIO_V2_LINE_FLAG_OPEN_DRAIN | GPIO_V2_LINE_FLAG_BIAS_PULL_UP;
    req.config.num_attrs = 1;
    req.config.attrs[0].attr.id = GPIO_V2_LINE_ATTR_ID_OUTPUT_VALUES;
    req.config.attrs[0].attr.values = 0x3; req.config.attrs[0].mask = 0x3;
    if (ioctl(chip_fd, GPIO_V2_GET_LINE_IOCTL, &req) < 0) die("GET_LINE ioctl (EBUSY = a kernel driver holds the line)");
    g_line_fd = req.fd;
    delay_half(); i2c_bus_clear();
    if (scl_release_wait() != RC_OK) { fprintf(stderr, "ddc-vcp: SCL stuck low, bus unusable\n"); exit(2); }
    return chip_fd;
}

/* Get VCP with up to 3 attempts (spec allows retries with 40 ms waits). */
static int do_get(int vcp) {
    uint8_t req[2] = { 0x01, (uint8_t)vcp };
    uint8_t buf[16];
    for (int attempt = 1; attempt <= 3; attempt++) {
        int rc = ddc_send(req, 2);
        if (rc == RC_NOACK) { fprintf(stderr, "ddc-vcp: no ACK from 0x37 (display does not speak DDC/CI on this input)\n"); return 2; }
        if (rc == RC_BUS)   { fprintf(stderr, "ddc-vcp: bus hung on request (attempt %d)\n", attempt); i2c_bus_clear(); delay_ms(50); continue; }
        delay_ms(50);                                   /* spec: >=40 ms before reading the reply */
        int n = ddc_recv(buf, sizeof(buf));
        if (n == RC_NOACK) { fprintf(stderr, "ddc-vcp: no ACK reading reply (attempt %d)\n", attempt); delay_ms(50); continue; }
        if (n < 0)         { fprintf(stderr, "ddc-vcp: bus hung reading reply (attempt %d)\n", attempt); i2c_bus_clear(); delay_ms(50); continue; }

        fprintf(stderr, "ddc-vcp: reply %d bytes:", n);
        for (int i = 0; i < n; i++) fprintf(stderr, " %02X", buf[i]);
        fprintf(stderr, "\n");

        if (n >= 2 && (buf[1] & 0x7F) == 0) { fprintf(stderr, "ddc-vcp: null reply (feature unsupported / not ready), retrying\n"); delay_ms(50); continue; }
        int cks = reply_checksum_ok(buf, n);
        if (n < 11 || buf[0] != DDC_ADDR_W || buf[2] != 0x02) {
            fprintf(stderr, "ddc-vcp: malformed reply (attempt %d)\n", attempt); delay_ms(50); continue;
        }
        int result = buf[3], rvcp = buf[4], type = buf[5];
        int maxv = (buf[6] << 8) | buf[7];
        int cur  = (buf[8] << 8) | buf[9];
        if (result != 0)   { fprintf(stderr, "ddc-vcp: display result code 0x%02X (1=unsupported VCP)\n", result); return 3; }
        if (rvcp != vcp)   { fprintf(stderr, "ddc-vcp: reply is for VCP 0x%02X, asked 0x%02X\n", rvcp, vcp); delay_ms(50); continue; }
        printf("vcp 0x%02X  current %d  max %d  type %s  checksum %s\n",
               vcp, cur, maxv, type == 1 ? "momentary" : "set-parameter", cks ? "ok" : "MISMATCH");
        if (!cks) { fprintf(stderr, "ddc-vcp: warning: reply checksum mismatch (value still shown; probe accepts it)\n"); return 4; }
        return 0;
    }
    fprintf(stderr, "ddc-vcp: get failed after 3 attempts\n");
    return 3;
}

static int do_set(int vcp, int value) {
    uint8_t req[4] = { 0x03, (uint8_t)vcp, (uint8_t)(value >> 8), (uint8_t)(value & 0xFF) };
    int rc = ddc_send(req, 4);
    if (rc == RC_NOACK) { fprintf(stderr, "ddc-vcp: no ACK from 0x37 (display does not speak DDC/CI on this input)\n"); return 2; }
    if (rc == RC_BUS)   { fprintf(stderr, "ddc-vcp: bus hung on set request\n"); return 3; }
    delay_ms(50);                                       /* spec: >=50 ms after a Set before more traffic */
    printf("vcp 0x%02X  set to %d  (sent; no reply expected)\n", vcp, value);
    return 0;
}

static void usage(void) {
    fprintf(stderr,
        "usage: ddc-vcp <gpiochip> <scl> <sda> get <vcp> [--hz N] [--label NAME]\n"
        "       ddc-vcp <gpiochip> <scl> <sda> set <vcp> <value> [--hz N] [--label NAME]\n"
        "  e.g. ddc-vcp /dev/gpiochip4 15 16 get 0x10   (brightness)\n");
    exit(1);
}

int main(int argc, char **argv) {
    if (argc < 6) usage();
    const char *chip = argv[1]; char *end = NULL;
    long scl = strtol(argv[2], &end, 0); if (!end || *end) usage();
    long sda = strtol(argv[3], &end, 0); if (!end || *end) usage();
    if (scl == sda) { fprintf(stderr, "scl and sda must differ\n"); return 1; }
    const char *op = argv[4];
    int vcp = (int)strtol(argv[5], &end, 0); if (!end || *end || vcp < 0 || vcp > 255) usage();

    int value = 0, have_value = 0, argi = 6;
    if (!strcmp(op, "set")) {
        if (argc < 7) usage();
        value = (int)strtol(argv[6], &end, 0); if (!end || *end || value < 0 || value > 65535) usage();
        have_value = 1; argi = 7;
    } else if (strcmp(op, "get")) usage();

    long hz = 2000; const char *want_label = NULL;
    for (int i = argi; i < argc; i++) {
        if (!strcmp(argv[i], "--hz") && i + 1 < argc) { hz = strtol(argv[++i], &end, 0); if (!end || *end) usage(); }
        else if (!strcmp(argv[i], "--label") && i + 1 < argc) want_label = argv[++i];
        else usage();
    }
    if (hz < 100) hz = 100; if (hz > 100000) hz = 100000;
    g_half_ns = 1000000000L / (2 * hz);
    (void)have_value;

    int chip_fd = setup_lines(chip, scl, sda, want_label);
    int rc = !strcmp(op, "get") ? do_get(vcp) : do_set(vcp, value);
    if (g_line_fd >= 0) close(g_line_fd);
    close(chip_fd);
    return rc;
}
