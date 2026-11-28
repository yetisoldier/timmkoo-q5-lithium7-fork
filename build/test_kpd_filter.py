#!/usr/bin/env python3
"""Host test for the D43 kpd glitch filter (G1-G6, spec §5.5).

Same technique as build/test_touch_key_protocol.py: extract the REAL patched
functions out of the kernel tree and compile them against host mocks —
mock input_report_key (with the real input-core change-suppression
semantics), mock kpd_get_keymap_state backed by a host-controlled matrix,
and mock schedule_delayed_work/cancel_delayed_work_sync on a host fake
clock. Everything else is extracted verbatim from the tree.

Extracted, verbatim, from the post-D43 tree:
  drivers/misc/mediatek/keypad/kpd.c: kpd_glitch_work_func (the only key
  reporter), kpd_keymap_handler (sample-only tasklet), kpd_pdrv_suspend
  (first statement cancels the glitch work), kpd_pdrv_resume (re-syncs
  baselines without reporting), kpd_aee_handler + kpd_update_aee_state and
  the D43 state block.
  Data: hal_kpd.c kpd_keymap_state initial map, cust_kpd.h KPD_INIT_KEYMAP
  macro, the hal_pub_kpd.h sizes (KPD_NUM_MEMS/KPD_NUM_KEYS).

Glitch presentation for G2/G3: a storm pulse is a press-edge IRQ whose
release edge settles the matrix back WITHOUT a further IRQ delivery (a
pulse shorter than the key-IRQ re-arm window only ever presents the press
edge; the press bit therefore sits in the S1 sample). With that
presentation the drop counter counts exactly one bit per drowned pulse,
which is what G2/G3 and the §6 storm-attribution metric expect.

Run gates (build runs this from the 75/82 chain before the zImage build):
  G1  250 ms press of hw slot 0     -> exactly one KEY_VOLUMEUP down then up
  G2  80 ms pulse on hw slot 0      -> zero events; drop counter increments
  G3  60 s of 2.9 Hz slot-01 pulses -> zero events; drops == observed glitches
  G4  press held across one suspend -> work cancelled + resume re-sync, no
      stuck key, no phantom release
  G5  two quick distinct presses    -> both delivered, correct order
  G6  filtered stream into the real kpd_aee_handler; the both-key
      5-15 s AEE dump path stays armed and fires
"""
import argparse
import re
import subprocess
import tempfile
from pathlib import Path

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('kernel', type=Path)
args = parser.parse_args()

kpd_c = (args.kernel / 'drivers/misc/mediatek/keypad/kpd.c').read_text()
hal_kpd_c = (args.kernel / 'drivers/misc/mediatek/keypad/mt6582/hal_kpd.c').read_text()
cust_kpd_h = (args.kernel / 'arch/arm/mach-mt6582/q5/dct/dct/inc/cust_kpd.h').read_text()
hal_pub_kpd_h = (args.kernel / 'arch/arm/mach-mt6582/include/mach/hal_pub_kpd.h').read_text()

# The tree MUST already carry the D43 patch — fail loudly on an unpatched tree.
assert 'kpd_glitch_work_func' in kpd_c, 'D43 not applied: kpd_glitch_work_func missing'
assert 'kpd_show_scan' in hal_kpd_c, 'D43 not applied: scan-log gate missing'
assert '(HZ/50)' in (args.kernel / 'drivers/misc/mediatek/connectivity/'
                     'conn_soc/drv_wlan/mt_wifi/wlan/os/linux/gl_kal.c').read_text(), \
    'D44 not applied: HZ/50 missing'


def function(text, head):
    """Extract a whole C function: signature head up to its flush-left brace."""
    match = re.compile(r'^' + re.escape(head) + r'[^\n]*\n\{(.*?)\n\}', re.M | re.S).search(text)
    assert match, head
    return head + '\n{' + match[1] + '\n}'


f_work = function(kpd_c, 'static void kpd_glitch_work_func(struct work_struct *work)')
f_handler = function(kpd_c, 'static void kpd_keymap_handler(unsigned long data)')
f_suspend = function(kpd_c, 'static int kpd_pdrv_suspend(struct platform_device *pdev, pm_message_t state)')
f_resume = function(kpd_c, 'static int kpd_pdrv_resume(struct platform_device *pdev)')
f_aee_handler = function(kpd_c, 'static void kpd_aee_handler(u32 keycode, u16 pressed)')
f_aee_state = function(kpd_c, 'static inline void kpd_update_aee_state(void)')

state_block = re.search(r'^static int kpd_glitch_ms = 150;\n.*?^static unsigned long kpd_glitch_drops;\n',
                        kpd_c, re.M | re.S)[0]
aee_defines = '\n'.join(re.findall(r'^#define AEE_[A-Z0-9_]+\t+[0-9]+$', kpd_c, re.M))
assert 'AEE_ENABLE_5_15' in aee_defines and 'AEE_DELAY_TIME_5S' in aee_defines, aee_defines
num_defs = '\n'.join(re.findall(r'^#define KPD_NUM_(?:MEMS|KEYS)[^\n]*', hal_pub_kpd_h, re.M))
keymap_state_init = re.search(r'^static u16 kpd_keymap_state\[KPD_NUM_MEMS\] = \{.*?^\};',
                              hal_kpd_c, re.M | re.S)[0]
init_keymap_macro = re.search(r'^#define KPD_INIT_KEYMAP\(\)[^\n]*\\\n.*?^\} *$',
                              cust_kpd_h, re.M | re.S)[0]

# The extracted functions must be the D43 shapes (sample-only tasklet; the
# resume re-sync without reporting; suspend cancels before anything else).
assert 'input_report_key' not in f_handler, 'kpd_keymap_handler must report nothing'
assert 'schedule_delayed_work(&kpd_glitch_work, msecs_to_jiffies(kpd_glitch_ms))' in f_handler
assert 'cancel_delayed_work_sync(&kpd_glitch_work);' in f_suspend
assert 'memcpy(kpd_reported_state,' in f_resume and 'memcpy(kpd_pending_state,' in f_resume

source = r'''
#include <assert.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* ---- kernel shims (the §5.5 mock set plus the minimal type layer) ---- */
typedef unsigned short u16;
typedef unsigned int u32;
typedef unsigned long ktime_t;
#define printk(...) printf(__VA_ARGS__)
#define KERN_INFO ""
#define KPD_SAY "kpd: "
#define kpd_print(...) ((void)0)
#define printk_ratelimited(...) printf(__VA_ARGS__)
#define unlikely(x) (x)
#define BUG_ON(x) do { if (x) { printf("FAIL: BUG_ON\n"); exit(2); } } while (0)
#define hweight16(x) (__builtin_popcount((unsigned int)(x) & 0xffffu))
#define __set_bit(b, p)   (*(p) |= (1UL << (b)))
#define __clear_bit(b, p) (*(p) &= ~(1UL << (b)))
#define KEY_VOLUMEUP 115
#define KEY_VOLUMEDOWN 114
#define HRTIMER_MODE_REL 0

#define CONFIG_OF 1
struct input_dev { int dummy; };
static struct input_dev kpd_dev;
struct input_dev *kpd_input_dev = &kpd_dev;

struct work_struct { unsigned long stamp; };
struct delayed_work { void (*func)(struct work_struct *); int pending; unsigned long deadline; struct work_struct work; };
#define INIT_DELAYED_WORK(dw, fn) do { (dw)->func = (fn); (dw)->pending = 0; } while (0)

static unsigned long jiffies_now;          /* fake clock: 1 jiffy = 1 ms */
#define msecs_to_jiffies(x) ((unsigned long)(x))
#define HZ 1000

struct platform_device { int dummy; };
struct pm_message { int event; };
#define pm_message_t struct pm_message
static unsigned int kp_irqnr = 77;
static void enable_irq(unsigned int irq) { (void)irq; }   /* host matrix always armed */
#define MTK_KP_WAKESOURCE 1

static bool kpd_suspend;
static volatile int call_status;
static void kpd_wakeup_src_setting(int en) { (void)en; }
static void kpd_disable_backlight(void) {}
static void kpd_backlight_handler(int onoff, int code) { (void)onoff; (void)code; }
static ktime_t ktime_set(long s, long ns) { return (ktime_t)s * 1000000000UL + (ktime_t)ns; }

/* Event stream: every input_report_key call, plus the change-only view the
 * real input core would emit (Linux suppresses no-op EV_KEY reports). */
struct kevent { int key, value; };
static struct kevent driver_calls[128];
static int driver_count;
static int evdev_prev[512];
static struct kevent userspace[128];
static int userspace_count;
static void input_report_key(struct input_dev *dev, int key, int value)
{
    (void)dev;
    assert(driver_count < 128);
    driver_calls[driver_count].key = key;
    driver_calls[driver_count].value = value;
    driver_count++;
    if (evdev_prev[key] != value) {
        evdev_prev[key] = value;
        assert(userspace_count < 128);
        userspace[userspace_count].key = key;
        userspace[userspace_count].value = value;
        userspace_count++;
    }
}
static void input_sync(struct input_dev *dev) { (void)dev; }

/* workqueue on the fake clock. 3.10 schedule_delayed_work does NOT restart
 * a pending timer — the first deadline wins; later IRQs only resample. */
static void schedule_delayed_work(struct delayed_work *dw, unsigned long delay)
{
    if (!dw->pending) {
        dw->pending = 1;
        dw->deadline = jiffies_now + delay;
    }
}
static void cancel_delayed_work_sync(struct delayed_work *dw) { dw->pending = 0; }

/* host-controlled key matrix: bit 1 = released (idle), bit 0 = pressed.
 * Idle pattern mirrors the real hal kpd_keymap_state initializer. */
static u16 matrix[5] = {0xffff, 0xffff, 0xffff, 0xffff, 0x00ff};

void kpd_get_keymap_state(u16 state[])
{
    memcpy(state, matrix, sizeof(matrix));
}

/* ---- real extracted data, verbatim ---- */
__NUM_DEFS__

__KEYMAP_STATE_INIT__

static u16 kpd_keymap[KPD_NUM_KEYS];
__KPD_INIT_KEYMAP_MACRO__
static u16 hal_keymap[KPD_NUM_KEYS] = KPD_INIT_KEYMAP();
void kpd_init_keymap(u16 keymap[]) { memcpy(keymap, hal_keymap, sizeof(hal_keymap)); }
void kpd_init_keymap_state(u16 keymap_state[]) { memcpy(keymap_state, kpd_keymap_state, sizeof(kpd_keymap_state)); }

/* ---- real extracted D43 state + functions, verbatim ---- */
__STATE_BLOCK__

/* ---- AEE statics (the real ones live in kpd.c beside the hrtimers;
 *      shapes and semantics asserted through the extracted pair below).
 *      The AEE_* defines are extracted verbatim from kpd.c. ---- */
struct hrtimer { int started; };
static struct hrtimer aee_timer, aee_timer_5s;
static unsigned long aee_pressed_keys;
static bool aee_timer_started;
static bool aee_timer_5s_started;
static bool flags_5s;
static int aee_timer_starts;
static int aee_reminding_calls;
__AEE_DEFINES__
static int hrtimer_start(struct hrtimer *t, ktime_t d, int mode)
{
    (void)d; (void)mode;
    t->started = 1;
    aee_timer_starts++;
    return 0;
}
static int hrtimer_cancel(struct hrtimer *t)
{
    int was = t->started;
    t->started = 0;
    return was;
}
static void aee_kernel_reminding(const char *reason, const char *detail)
{
    (void)reason; (void)detail;
    aee_reminding_calls++;
}

__F_AEE_STATE__

__F_AEE_HANDLER__

__F_WORK__

__F_HANDLER__

__F_SUSPEND__

__F_RESUME__

/* ---- test drivers (they only RUN the real functions) ---- */
static void press_edge(int mem, int bit)
{
    matrix[mem] = matrix[mem] & ~(1U << bit);
    kpd_keymap_handler(0);              /* IRQ -> tasklet: S1 sample */
}

static void release_edge(int mem, int bit)
{
    matrix[mem] = matrix[mem] | (1U << bit);
    kpd_keymap_handler(0);              /* IRQ -> tasklet resample */
}

static void run_due_work(void)
{
    if (kpd_glitch_work.pending && jiffies_now >= kpd_glitch_work.deadline) {
        kpd_glitch_work.pending = 0;
        kpd_glitch_work.func(&kpd_glitch_work.work);
    }
}

static void advance(unsigned long t)
{
    while (jiffies_now < t) {
        jiffies_now++;
        run_due_work();
    }
}

static void reset_stream(void)
{
    driver_count = 0;
    userspace_count = 0;
}

static int stream_equals(int expected[][2], int n)
{
    if (userspace_count != n)
        return 0;
    for (int i = 0; i < n; i++) {
        if (userspace[i].key != expected[i][0] || userspace[i].value != expected[i][1])
            return 0;
    }
    return 1;
}

static void probe_mirror(void)
{
    /* mirrors kpd_pdrv_probe after the hrtimer blocks (the D43 hunk) */
    kpd_init_keymap(kpd_keymap);
    kpd_init_keymap_state(kpd_pending_state);
    kpd_init_keymap_state(kpd_reported_state);
    INIT_DELAYED_WORK(&kpd_glitch_work, kpd_glitch_work_func);
}

int main(void)
{
    probe_mirror();

    /* sanity: the REAL keymap/map/params reached the harness */
    assert(kpd_keymap[0] == KEY_VOLUMEUP);
    assert(kpd_keymap[1] == KEY_VOLUMEDOWN);
    assert(kpd_glitch_ms == 150);
    assert(kpd_keymap_state[0] == 0xffff && kpd_keymap_state[4] == 0x00ff);

    /* ---------------- G1: one 250 ms press of hw slot 0 ---------------- */
    press_edge(0, 0);                   /* IRQ at 0: S1 sample, work at 150 */
    advance(250);                       /* work fires at 150: press reported */
    release_edge(0, 0);                 /* IRQ at 250: resample; work at 400 */
    advance(500);                       /* work fires at 400: release reported */
    {
        int g1[2][2] = {{KEY_VOLUMEUP, 1}, {KEY_VOLUMEUP, 0}};
        assert(stream_equals(g1, 2));
        assert(driver_count == 2);
        assert(kpd_glitch_drops == 0);
        printf("PASS G1: one 250ms press -> exactly one VOLUMEUP down/up, no duplicates\n");
    }

    /* ---------------- G2: an 80 ms pulse on hw slot 0 ------------------ */
    reset_stream();
    {
        unsigned long t0 = jiffies_now;
        unsigned long drops_before = kpd_glitch_drops;
        press_edge(0, 0);               /* press-edge IRQ at t0 (S1 keeps it) */
        matrix[0] |= 1U;                /* pulse ends at t0+80: no release IRQ */
        advance(t0 + 170);              /* work at t0+150 */
        assert(userspace_count == 0);   /* ZERO events */
        assert(driver_count == 0);
        assert(kpd_glitch_drops == drops_before + 1);   /* counter increments */
        printf("PASS G2: 80ms pulse -> zero events, drop counter +1\n");
    }

    /* ---------------- G3: 60 s of 2.9 Hz slot-01 toggling -------------- */
    {
        unsigned long drops_before = kpd_glitch_drops;
        int userspace_before = userspace_count;
        unsigned long window = jiffies_now;
        unsigned long period = 345;
        /* 2.9 Hz over 60 s = 174 pulses; the 174th press (k=173) lands at
         * 59,685 ms, inside the window. */
        assert(2.9 * 60 == 174);
        assert((173UL * period) < 60000);
        for (int k = 0; k < 174; k++) {
            unsigned long press = window + (unsigned long)k * period;
            press_edge(0, 1);           /* VOLDOWN glitch press-edge IRQ */
            matrix[0] |= (1U << 1);     /* glitch gone 10 ms later, no IRQ */
            advance(press + 150);       /* the single work run per pulse */
            if (jiffies_now < press + period)
                advance(press + period);
        }
        assert(userspace_count == userspace_before);    /* ZERO events over 60 s */
        assert(driver_count == 0);
        assert(kpd_glitch_drops == drops_before + 174); /* == observed glitches */
        printf("PASS G3: 60s of 2.9Hz slot-01 toggling -> zero events, drops==174\n");
    }

    /* ---------------- G4: press held across one suspend ---------------- */
    reset_stream();
    evdev_prev[KEY_VOLUMEUP] = 0;
    {
        unsigned long drops_before = kpd_glitch_drops;
        press_edge(0, 0);               /* press; S1 sample; work queued */
        advance(jiffies_now + 50);      /* still held; work not yet due */
        reset_stream();
        kpd_pdrv_suspend(NULL, (pm_message_t){.event = 0});
        assert(kpd_glitch_work.pending == 0);        /* cancelled FIRST */
        matrix[0] = 0xffffU & ~(1U << 0);            /* key still held */
        kpd_pdrv_resume(NULL);          /* re-sync baselines, NO report */
        assert(kpd_pending_state[0] == matrix[0]);
        assert(kpd_reported_state[0] == matrix[0]);
        assert(driver_count == 0);
        advance(jiffies_now + 200);
        release_edge(0, 0);             /* release after resume */
        advance(jiffies_now + 250);
        assert(userspace_count == 0);   /* evdev: no phantom release */
        assert(driver_count == 1 && driver_calls[0].key == KEY_VOLUMEUP
               && driver_calls[0].value == 0);
        assert(aee_pressed_keys == 0);
        assert(kpd_glitch_drops == drops_before);   /* this flow drops nothing */
        printf("PASS G4: press across suspend -> no stuck key, no phantom release\n");
    }

    /* ---------------- G5: two quick distinct presses -------------------- */
    reset_stream();
    evdev_prev[KEY_VOLUMEUP] = 0;
    evdev_prev[KEY_VOLUMEDOWN] = 0;
    {
        unsigned long drops_before = kpd_glitch_drops;
        /* both holds and both gaps exceed the window (§7.3 documents that a
         * press under 150 ms is dropped by design). */
        press_edge(0, 0);
        advance(jiffies_now + 250);
        release_edge(0, 0);
        advance(jiffies_now + 300);
        press_edge(0, 1);
        advance(jiffies_now + 250);
        release_edge(0, 1);
        advance(jiffies_now + 300);
        int g5[4][2] = {{KEY_VOLUMEUP, 1}, {KEY_VOLUMEUP, 0},
                        {KEY_VOLUMEDOWN, 1}, {KEY_VOLUMEDOWN, 0}};
        assert(stream_equals(g5, 4));
        assert(driver_count == 4);
        assert(kpd_glitch_drops == drops_before);
        printf("PASS G5: two quick distinct presses -> both delivered, correct order\n");
    }

    /* ---------------- G6: filtered stream into the AEE logic ----------- */
    reset_stream();
    evdev_prev[KEY_VOLUMEUP] = 0;
    evdev_prev[KEY_VOLUMEDOWN] = 0;
    {
        press_edge(0, 0);               /* VOLUMEUP press */
        advance(jiffies_now + 50);
        press_edge(0, 1);               /* VOLUMEDOWN joins inside the window */
        advance(jiffies_now + 120);     /* work at press1+150: both report */
        assert(aee_pressed_keys == ((1u << 0) | (1u << 1)));
        assert(aee_timer_started);
        assert(aee_timer_5s_started);
        assert(aee_timer_starts == 2);  /* 15 s dump timer + 5 s both-keys timer */
        flags_5s = true;                /* the hold crosses 5 s (within 15) */
        release_edge(0, 0);             /* VOLUMEUP released first */
        advance(jiffies_now + 300);
        int g6a[3][2] = {{KEY_VOLUMEUP, 1}, {KEY_VOLUMEDOWN, 1}, {KEY_VOLUMEUP, 0}};
        assert(stream_equals(g6a, 3));
        assert(aee_reminding_calls == 1);   /* 5-15 s both-keys path fired */
        release_edge(0, 1);             /* VOLUMEDOWN released */
        advance(jiffies_now + 300);
        int g6b[4][2] = {{KEY_VOLUMEUP, 1}, {KEY_VOLUMEDOWN, 1},
                         {KEY_VOLUMEUP, 0}, {KEY_VOLUMEDOWN, 0}};
        assert(stream_equals(g6b, 4));
        assert(aee_pressed_keys == 0);
        printf("PASS G6: aee follows the filtered stream; both-key 5-15s path intact\n");
    }

    puts("PASS: D43 kpd glitch filter G1-G6");
    return 0;
}
'''

source = (source
          .replace('__NUM_DEFS__', num_defs)
          .replace('__AEE_DEFINES__', aee_defines)
          .replace('__KEYMAP_STATE_INIT__', keymap_state_init)
          .replace('__KPD_INIT_KEYMAP_MACRO__', init_keymap_macro)
          .replace('__STATE_BLOCK__', state_block)
          .replace('__F_AEE_STATE__', f_aee_state)
          .replace('__F_AEE_HANDLER__', f_aee_handler)
          .replace('__F_WORK__', f_work)
          .replace('__F_HANDLER__', f_handler)
          .replace('__F_SUSPEND__', f_suspend)
          .replace('__F_RESUME__', f_resume))

with tempfile.NamedTemporaryFile('w', suffix='.c', delete=False, encoding='utf-8') as f:
    f.write(source)
    c_path = f.name
build_dir = Path(tempfile.mkdtemp())
out_path = build_dir / 'kpd_filter_harness'
try:
    subprocess.run(['gcc', '-std=gnu99', '-Wall', '-Wextra', '-Wno-unused-parameter',
                    c_path, '-o', str(out_path)], check=True)
    subprocess.run([str(out_path)], check=True)
finally:
    Path(c_path).unlink()
