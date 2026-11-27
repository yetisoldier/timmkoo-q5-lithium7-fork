#!/usr/bin/env python3
"""Exercise the actual port report path with the actual MTK virtual-key helper."""
import argparse
from pathlib import Path
import re
import subprocess
import tempfile

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('kernel', type=Path)
parser.add_argument('--legacy-reporting', action='store_true',
                    help='Reproduce D36-D38 while allowing their known duplicate touchscreen reporting')
args = parser.parse_args()
driver = (args.kernel / 'drivers/input/touchscreen/mediatek/gslX680/mtk_gslX680.c').read_text()
buttons = (args.kernel / 'drivers/input/touchscreen/mediatek/tpd_button.c').read_text()

def function(text, name):
    match = re.search(r'^(?:static )?void ' + name + r'\([^\n]*\)\n\{.*?^\}', text, re.M | re.S)
    assert match, name
    return match[0]

keys = re.search(r'^static const int gsl_tp_keys\[2\].*?;', driver, re.M | re.S)[0]
dims = re.search(r'^static const int gsl_tp_keys_dim\[2\]\[4\].*?^\};', driver, re.M | re.S)[0]
source = r'''
#include <assert.h>
#include <stdio.h>
#include <string.h>
#define unlikely(x) (x)
#define BTN_TOUCH 330
#define ABS_MT_TOUCH_MAJOR 48
#define ABS_MT_POSITION_X 53
#define ABS_MT_POSITION_Y 54
#define ABS_MT_TRACKING_ID 57
#define TPD_DEBUG(...) ((void)0)
#define printk(...) ((void)0)
#define ARRAY_SIZE(a) (sizeof(a)/sizeof((a)[0]))
#define MAX_CONTACTS 10
#define TPD_RES_X 480
#define TPD_RES_Y 800
struct input_dev {int value;};
struct tpd_device {struct input_dev *dev, *kpd; unsigned int btn_state;};
static struct input_dev screen, keypad;
static struct tpd_device device = {&screen, &keypad, 0};
static struct tpd_device *tpd = &device;
struct gsl_touch_info {int x[10], y[10], id[10], finger_num;};
static int events[32][2], event_count, screen_downs, offscreen_coordinates;
static void input_report_key(struct input_dev *dev, int key, int value) {
    if(dev == &keypad) {assert(event_count < 32); events[event_count][0]=key; events[event_count++][1]=value;}
    if(dev == &screen && key == BTN_TOUCH && value == 1) screen_downs++;
}
static void input_report_abs(struct input_dev *dev, int code, int value) {
    if(code == ABS_MT_POSITION_Y && value >= TPD_RES_Y) offscreen_coordinates++;
}
static void input_sync(struct input_dev *dev) {}
static void input_mt_sync(struct input_dev *dev) {}
'''
source += keys + '\n' + dims + '\n'
source += f'static const int require_separate_keys = {int(not args.legacy_reporting)};\n'
source += '#define tpd_keys gsl_tp_keys\n#define tpd_keys_dim gsl_tp_keys_dim\nstatic int tpd_keycnt=2;\n'
source += function(buttons, 'tpd_button') + '\n'
source += '\n'.join(function(driver, name) for name in ['tpd_down', 'tpd_up', 'gsl_report_point'])
source += r'''
static void tap(int x,int y) {
    struct gsl_touch_info ti = {.x={x}, .y={y}, .id={1}, .finger_num=1};
    gsl_report_point(&ti); ti.finger_num=0; gsl_report_point(&ti); gsl_report_point(&ti);
}
int main(void) {
    tap(100,900); tap(100,900); tap(240,400); tap(300,900);
    int expected[6][2]={{172,1},{172,0},{172,1},{172,0},{158,1},{158,0}};
    assert(event_count==6);
    assert(memcmp(events,expected,sizeof(expected))==0);
    assert(tpd->btn_state==0);
    if(require_separate_keys) {
        assert(screen_downs==1); /* Only the normal screen tap, never virtual keys. */
        assert(offscreen_coordinates==0);
    }
    puts(require_separate_keys
        ? "PASS: paired Home/Back press/release, no off-display touchscreen contacts"
        : "PASS: legacy paired key release (duplicate touchscreen reporting allowed for historical reproduction)");
}
'''
with tempfile.TemporaryDirectory(prefix='q5-key-test-') as temp:
    path = Path(temp)
    (path / 'test.c').write_text(source)
    subprocess.run(['gcc', '-g', '-O1', '-fsanitize=address,undefined', '-fno-omit-frame-pointer',
                    str(path / 'test.c'), '-o', str(path / 'test')], check=True)
    subprocess.run([str(path / 'test')], check=True)
