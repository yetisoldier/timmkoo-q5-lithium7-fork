/* Execute the kernel's actual selection code; no network identifiers or I/O. */
#include <assert.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/types.h>
#include <stddef.h>
#define IN
#define OUT
#define TRUE 1
#define FALSE 0
#define ASSERT assert
#define MAC_ADDR_LEN 6
#define NULL_MAC_ADDR {0,0,0,0,0,0}
#define IS_BMCAST_MAC_ADDR(p) (((const unsigned char *)(p))[0] & 1)
#define EQUAL_MAC_ADDR(a,b) (!memcmp((a),(b),6))
#define COPY_MAC_ADDR(a,b) memcpy((a),(b),6)
#define kalMemCopy memcpy
#define OFFSET_OF offsetof
#define IS_ERR(p) ((intptr_t)(p) < 0)
typedef int BOOLEAN;
typedef unsigned char UINT_8;
typedef unsigned int UINT_32;
typedef unsigned short UINT_16;
typedef UINT_16 *PUINT_16;
typedef UINT_8 *PUINT_8;
typedef UINT_8 PARAM_MAC_ADDRESS[6];
typedef struct { UINT_16 version, peer; UINT_8 aucMacAddress[6]; } WIFI_CFG_PARAM_STRUCT;
struct adapter { int fgIsEmbbededMacAddrValid; };
typedef struct {
    int fgIsMacAddrOverride;
    UINT_8 rMacAddrOverride[6];
    struct adapter *prAdapter;
} GLUE_INFO_T, *P_GLUE_INFO_T;
struct file { int unused; };
typedef int mm_segment_t;
static int fs, missing, read_error, opens, closes, nvram_error;
static UINT_8 nvram[6], stored[7];
static ssize_t stored_length;
static struct file mock_file;
static struct adapter adapter;
static GLUE_INFO_T glue;
static int get_fs(void) { return fs; }
static int get_ds(void) { return 99; }
static void set_fs(int value) { fs=value; }
static struct file *filp_open(const char *path, int flags, int rights) {
    assert(fs==99 && rights==0 && flags==(O_RDONLY|O_NOFOLLOW));
    assert(!strcmp(path,"/data/misc/wifi/q5-stable-mac"));
    opens++;
    return missing ? (struct file *)(intptr_t)-1 : &mock_file;
}
static ssize_t vfs_read(struct file *file, char *data, size_t size, loff_t *offset) {
    assert(file==&mock_file && fs==99 && *offset==0 && size==7);
    if(read_error) return -5;
    memcpy(data,stored,(size_t)stored_length);
    return stored_length;
}
static int filp_close(struct file *file, void *unused) {
    assert(file==&mock_file && !unused && fs==99);
    closes++;
    return 0;
}
static int kalCfgDataRead16(P_GLUE_INFO_T unused, UINT_32 offset, PUINT_16 data) {
    (void)unused;
    assert(offset>=4 && offset<=8);
    if(nvram_error) return FALSE;
    memcpy(data,nvram+offset-4,2);
    return TRUE;
}
/* KERNEL FUNCTIONS */
static void reset(void) {
    const UINT_8 local[6]={2,1,2,3,4,5};
    memset(nvram,0,sizeof(nvram));
    memcpy(stored,local,6);
    stored[6]=0;
    stored_length=6;
    fs=42;missing=read_error=opens=closes=nvram_error=0;
    memset(&glue,0,sizeof(glue));
    memset(&adapter,0,sizeof(adapter));
    glue.prAdapter=&adapter;
}
static int select_address(PARAM_MAC_ADDRESS *out) {
    int result=kalRetrieveNetworkAddress(&glue,out);
    assert(fs==42);
    assert(closes==opens-(missing ? 1 : 0));
    return result;
}
int main(void) {
    PARAM_MAC_ADDRESS out;
    const UINT_8 factory[6]={0,0x11,0x22,0x33,0x44,0x55};
    int i;
    reset(); memcpy(nvram,factory,6);
    assert(select_address(&out) && !memcmp(out,factory,6) && !opens);
    reset(); adapter.fgIsEmbbededMacAddrValid=TRUE;
    assert(!select_address(&out) && !opens); /* caller retains valid eFUSE */
    reset(); assert(select_address(&out) && !memcmp(out,stored,6));
    reset(); nvram[0]=1;
    assert(select_address(&out) && !memcmp(out,stored,6)); /* multicast NVRAM */
    reset(); nvram_error=1;
    assert(select_address(&out) && !memcmp(out,stored,6));
    reset(); missing=1; assert(!select_address(&out));
    reset(); read_error=1; assert(!select_address(&out));
    reset(); stored_length=5; assert(!select_address(&out));
    reset(); stored_length=7; assert(!select_address(&out));
    for(i=0;i<4;i++) {
        reset(); stored[0]=(UINT_8)i;
        assert(select_address(&out)==(i==2));
    }
    reset(); glue.fgIsMacAddrOverride=TRUE;
    memcpy(glue.rMacAddrOverride,factory,6);
    assert(select_address(&out) && !memcmp(out,factory,6) && !opens);
    puts("PASS: factory/eFUSE priority, stable fallback, invalid/short/long/missing/error paths; fs restored");
    return 0;
}
