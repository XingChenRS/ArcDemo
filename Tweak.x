// xrc-arcdemo / Tweak.x
// Sideload dylib: chart/visual speed control + basic seek.
#define XRC_TWEAK_VERSION  @"v7.3.2"
#define XRC_BUILD_LABEL    @"Sideload"

#import <substrate.h>
#import <time.h>
#import <dlfcn.h>
#import <mach-o/dyld.h>
#import <sys/time.h>
#import <sys/mman.h>
#import <stdatomic.h>
#import <errno.h>
#import <limits.h>
#import <mach/vm_map.h>
#import <mach/mach_init.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#if __has_include(<ptrauth.h>)
#  import <ptrauth.h>
#endif

#import "fishhook.h"

extern UIApplication *UIApp;

#import "SuspendView/WQSuspendView.h"
#import "WHToast/WHToast.h"
#include "ArcOffsets.h"

void acc_flog(NSString *fmt, ...) NS_FORMAT_FUNCTION(1, 2);

#pragma mark - global

float    *rates = NULL;
NSInteger rate_i = 0;
NSInteger rate_count = 0;

BOOL     buttonEnabled = YES;
BOOL     toast = YES;
int judgeMaxMs = 25;
int judgePureMs = 50;
int judgeFarMs = 100;
int judgeLostMs = 120;

WQSuspendView *button = nil;
UIView        *menuView = nil;
#pragma mark - Arcaea binary (offsets in include/ArcOffsets.h)

#define ARC_REG_PLAYER_OFFSET      (8)
#define ARC_PLAYER_CHANNELS_OFFSET (0x38)
#define ARC_CHANNEL_ENTRY_PTR_OFF  (8)

typedef void *   (*get_registry_fn)(void);
typedef int      (*get_current_sound_fn)(void *channel, void **outSound);
typedef int      (*get_sound_length_fn)(void *sound, uint32_t *outLen, int unit);
typedef int      (*ch_get_position_fn)(void *channel, uint32_t *out_ms, int unit);
static get_registry_fn      g_get_registry = NULL;
static get_current_sound_fn g_get_current_sound = NULL;
static get_sound_length_fn  g_get_sound_length = NULL;
static ch_get_position_fn   g_ch_get_position = NULL;

// hook 鍏滃簳鎹曡幏 + 涓诲姩閫氳繃 registry 鑾峰彇
static _Atomic(void *)   g_bgmPlayer = NULL;
_Atomic(uint32_t) g_last_pos_ms = 0;
static _Atomic(uint32_t) g_max_seen_ms = 0;
static _Atomic(uint32_t) g_song_length_ms = 0;   // FMOD 鎷垮埌鐨勭湡瀹炴€绘椂闀?

// 闊抽鍙橀€熷凡绉婚櫎 (v6.4+): BGM 濮嬬粓 1.0脳; 浠呰氨闈?clock + 鐢婚潰 warp 鎸夊€嶇巼鍙樺寲銆?
// MTP getPos vtable swizzle 浠呯敤浜庢崟鑾?player 涓庤繘搴﹁鍙栥€?

// 灏濊瘯浠?player 涓昏建鎷?Sound 鎬婚暱
static void try_capture_song_length(void *player) {
    if (!player || !g_get_current_sound || !g_get_sound_length) return;
    if (atomic_load(&g_song_length_ms) != 0) return;
    void *channels_base = *(void **)((char *)player + ARC_PLAYER_CHANNELS_OFFSET);
    if (!channels_base) return;
    void *ch0 = *(void **)((char *)channels_base + ARC_CHANNEL_ENTRY_PTR_OFF);
    if (!ch0) return;
    void *snd = NULL;
    if (g_get_current_sound(ch0, &snd) != 0 || !snd) return;
    uint32_t len = 0;
    if (g_get_sound_length(snd, &len, 1) == 0 && len > 0 && len < 0x7FFFFFFFu) {
        atomic_store(&g_song_length_ms, len);
    }
}

// 涓诲姩閫氳繃 registry 鎷?MTP锛堜笉闇€瑕佺瓑 hook 瑙﹀彂锛?
static void *resolve_player_via_registry(void) {
    if (!g_get_registry) return NULL;
    void *reg = g_get_registry();
    if (!reg) return NULL;
    void *mtp = *(void **)((char *)reg + ARC_REG_PLAYER_OFFSET);
    if (mtp) atomic_store(&g_bgmPlayer, mtp);
    return mtp;
}

void *get_player_or_resolve(void) {
    void *p = atomic_load(&g_bgmPlayer);
    if (p) return p;
    return resolve_player_via_registry();
}

// 闃叉璇诲埌閲庢寚閽堬細鍏堝仛鐢ㄦ埛鎬佸湴鍧€绮楃瓫銆?
bool ptr_plausible(const void *p) {
    uintptr_t v = (uintptr_t)p;
    if (v < 0x100000000ULL) return false;
    if ((v & 0x7ULL) != 0) return false;
    return true;
}

bool addr_readable(const void *p, size_t len) {
    if (!p || len == 0) return false;
    if (!ptr_plausible(p)) return false;
    uintptr_t start_u = (uintptr_t)p;
    uintptr_t end_u = start_u + len;
    if (end_u < start_u) return false;
    // 鍚彂寮忎笂闄愶細鎷掔粷瓒呭ぇ璺ㄥ害璁块棶锛岄伩鍏嶉噹 end 鎸囬拡瀵艰嚧鍚庣画瓒婄晫銆?
    if (len > (1ULL << 20)) return false;
    // 杩欓噷涓嶅啀璋冪敤 vm_region_recurse锛堥儴鍒?Theos/SDK 缁勫悎涓嬭绗﹀彿缂哄け瀵艰嚧閾炬帴澶辫触锛夈€?
    return true;
}

// 鍙?Arc-mobile 涓诲彲鎵ц浣撳熀鍧€锛堟帓闄?Frameworks 鍐?dylib锛?
uint64_t arc_image_base(void) {
    static uint64_t cached = 0;
    if (cached) return cached;
    uint32_t n = _dyld_image_count();
    for (uint32_t i = 0; i < n; i++) {
        const char *name = _dyld_get_image_name(i);
        if (!name) continue;
        if (strstr(name, ".dylib") != NULL) continue;
        const char *slash = strrchr(name, '/');
        if (slash && strcmp(slash + 1, "Arc-mobile") == 0) {
            cached = (uint64_t)_dyld_get_image_header(i);
            break;
        }
    }
    if (!cached && n > 0)
        cached = (uint64_t)_dyld_get_image_header(0);
    return cached;
}

static void install_arc_hooks(void) {
    uint64_t base = arc_image_base();
    NSLog(@"[xrc-arcdemo] tweak %@ loading; arc base = 0x%llx", XRC_TWEAK_VERSION, base);
    if (!base) {
        NSLog(@"[xrc-arcdemo] arc_image_base() = 0, abort");
        return;
    }
    // Keep main-binary __TEXT read-only. This branch only reads known function
    // addresses and swaps writable vtable slots.
    g_get_registry = (get_registry_fn)(base + ARC_OFF_GET_REGISTRY);
    g_get_current_sound = (get_current_sound_fn)(base + ARC_OFF_GET_CURRENT_SOUND);
    g_get_sound_length  = (get_sound_length_fn) (base + ARC_OFF_GET_SOUND_LENGTH);
    g_ch_get_position   = (ch_get_position_fn) (base + ARC_OFF_CH_GET_POSITION);
    NSLog(@"[xrc-arcdemo] registry=%p getCurrentSound=%p getLength=%p",
          (void *)g_get_registry, (void *)g_get_current_sound,
          (void *)g_get_sound_length);
    void *mtp = resolve_player_via_registry();
    NSLog(@"[xrc-arcdemo] initial MTP via registry = %p", mtp);
    if (mtp) try_capture_song_length(mtp);

}

// 閫氳繃 player vtable 璋冪敤瀵瑰簲妲戒綅
static inline void *_player_vt_slot(void *self, size_t byte_off) {
    if (!self) return NULL;
    void **vtable = *(void ***)self;
    if (!vtable) return NULL;
    return vtable[byte_off / sizeof(void *)];
}

#pragma mark - Time Warp (gettimeofday fishhook for CCDirector visual speed)

// gettimeofday fishhook: CCDirector 鐢ㄥ畠璁＄畻甯ч棿 delta, warp 鍚庤瑙夊姩鐢绘寜 rate 鎾斁
// 鍏紡: t_warp(real) = t0_warp + (real - t0_real) * rate
// 鍒囧€嶇巼鐬棿: t0_real = real_now; t0_warp = warp_now (淇濇寔杩炵画, 涓嶈烦鍙?

typedef int (*orig_gettod_t)(struct timeval *tv, void *tz);
orig_gettod_t s_orig_gettod = NULL;

static _Atomic(uint64_t) g_tw_t0_real_us   = 0;
static _Atomic(uint64_t) g_tw_t0_warp_us   = 0;
static _Atomic(uint32_t) g_tw_rate_x1000   = 1000;

// 鍐荤粨鏈哄埗: 鏆傚仠 / 鍒囧悗鍙?/ seek 鏃跺喕缁?warp 鏃堕棿
_Atomic(int32_t)  g_tw_freeze_count = 0;
static _Atomic(uint64_t) g_tw_frozen_us    = 0;

double tw_get_rate(void) {
    return (double)atomic_load(&g_tw_rate_x1000) / 1000.0;
}

static uint64_t _compute_warp_us(uint64_t real_us) {
    double rate = tw_get_rate();
    uint64_t t0r = atomic_load(&g_tw_t0_real_us);
    uint64_t t0w = atomic_load(&g_tw_t0_warp_us);
    if (t0r == 0 || (rate >= 0.999 && rate <= 1.001)) return real_us;
    if (real_us <= t0r) return t0w;
    return t0w + (uint64_t)((double)(real_us - t0r) * rate);
}

static int tw_gettimeofday(struct timeval *tv, void *tz) {
    if (!tv) return s_orig_gettod ? s_orig_gettod(tv, tz) : gettimeofday(tv, tz);
    int r = s_orig_gettod ? s_orig_gettod(tv, tz) : gettimeofday(tv, tz);
    if (r != 0) return r;
    uint64_t real_us = (uint64_t)tv->tv_sec * 1000000ULL + (uint64_t)tv->tv_usec;
    uint64_t warp_us;
    if (atomic_load(&g_tw_freeze_count) > 0) {
        uint64_t f = atomic_load(&g_tw_frozen_us);
        warp_us = f ? f : real_us;
    } else {
        warp_us = _compute_warp_us(real_us);
    }
    if (warp_us == real_us) return r;
    tv->tv_sec  = (time_t)(warp_us / 1000000ULL);
    tv->tv_usec = (suseconds_t)(warp_us % 1000000ULL);
    return r;
}





#pragma mark - vtable swizzle (鏍稿績 Hook)

typedef uint32_t (*orig_mtp_getpos_fn)(void *self, int channel);
typedef int64_t (*orig_gp_update_fn)(void *self, uint64_t a2, uint64_t a3, uint64_t a4, uint64_t a5);

static orig_mtp_getpos_fn s_orig_mtp_getpos = NULL;
static orig_gp_update_fn s_orig_gp_update = NULL;

_Atomic(void *) g_gameplay_instance = NULL;

// retime 鐘舵€? 璁板綍涓婁竴甯х殑鐪熷疄鏃堕棿鍜?clock 鎸囬拡, 鐢ㄤ簬璁＄畻甯ч棿 delta
static void *s_gp_last_clock = NULL;
static uint64_t s_gp_last_real_us = 0;
static uint32_t tw_mtp_getpos(void *self, int channel) {
    uint32_t raw = s_orig_mtp_getpos ? s_orig_mtp_getpos(self, channel) : 0;
    if (channel == 0) {
        atomic_store(&g_bgmPlayer, self);
        atomic_store(&g_last_pos_ms, raw);
        uint32_t prev_pos = atomic_exchange(&g_max_seen_ms, raw);
        if (prev_pos > 100 && raw < 100) {
            atomic_store(&g_song_length_ms, 0);
        } else if (raw > atomic_load(&g_max_seen_ms)) {
            atomic_store(&g_max_seen_ms, raw);
        }
    }
    return raw;
}

// 鍙栨湭琚?warp 鐨勭湡瀹?microsecond 鏃堕棿 (鐢ㄤ簬 retime delta 璁＄畻)
static uint64_t _real_now_us_unwarped(void) {
    struct timeval tv = {0};
    if (s_orig_gettod) {
        if (s_orig_gettod(&tv, NULL) == 0)
            return (uint64_t)tv.tv_sec * 1000000ULL + (uint64_t)tv.tv_usec;
        return 0;
    }
    if (gettimeofday(&tv, NULL) == 0)
        return (uint64_t)tv.tv_sec * 1000000ULL + (uint64_t)tv.tv_usec;
    return 0;
}

// forward decl (defined later in file)
static int32_t _read_chart_clock_ms(void *clk);

static void _gp_retime_logic_clock(void *logic) {
    if (!logic) return;
    if (atomic_load(&g_tw_freeze_count) > 0) return;
    if (!addr_readable((char *)logic + 56, sizeof(void *))) return;
    void *clk = *(void **)((char *)logic + 48);
    if (!clk || !ptr_plausible(clk) || !addr_readable(clk, 64)) return;

    uint64_t now_us = _real_now_us_unwarped();
    if (!now_us) return;
    if (clk != s_gp_last_clock || s_gp_last_real_us == 0 || now_us <= s_gp_last_real_us) {
        s_gp_last_clock = clk;
        s_gp_last_real_us = now_us;
        return;
    }

    uint64_t delta_us = now_us - s_gp_last_real_us;
    if (delta_us > 200000ULL) delta_us = 200000ULL;
    s_gp_last_real_us = now_us;
    int32_t delta_ms = (int32_t)(delta_us / 1000ULL);
    if (delta_ms <= 0) return;

    double rate = tw_get_rate();
    int32_t adjust = 0;
    if (rate < 0.999 || rate > 1.001)
        adjust = (int32_t)((1.0 - rate) * (double)delta_ms);

    if (adjust == 0) return;
    int32_t *start_ms = (int32_t *)((char *)clk + 16);
    int64_t after = (int64_t)(*start_ms) + (int64_t)adjust;
    if (after > INT_MAX) after = INT_MAX;
    if (after < INT_MIN) after = INT_MIN;
    *start_ms = (int32_t)after;
}

// Gameplay.update: 缂撳瓨 GP 瀹炰緥 + 璋遍潰 clock retime
static int64_t tw_gp_update(void *self, uint64_t a2, uint64_t a3, uint64_t a4, uint64_t a5) {
    if (self) {
        // 缂撳瓨 Gameplay 瀹炰緥鎸囬拡 (player_seek_ms 闇€瑕佽闂?logic clock)
        atomic_store(&g_gameplay_instance, self);
        void *logic = NULL;
        if (addr_readable((char *)self + 936, sizeof(void *)))
            logic = *(void **)((char *)self + 928);
        if (logic && ptr_plausible(logic))
            _gp_retime_logic_clock(logic);
    }
    return s_orig_gp_update ? s_orig_gp_update(self, a2, a3, a4, a5) : 0;
}


// 鍦?vtable 鍖哄煙 卤64 slots 鑼冨洿鍐呮壂鎻?鎵惧埌鍖归厤 orig_fn 鐨?slot 骞舵浛鎹负 new_fn銆?
// 杩斿洖鎵惧埌鐨?slot index (鐩稿 vtable 璧峰,鍙兘璐熸暟),澶辫触杩斿洖 INT_MIN銆?
static int swizzle_vtable_find_swap(uint64_t vtable_addr, uint64_t orig_fn_off,
                                     void *new_fn, void **out_orig)
{
    uint64_t base = arc_image_base();
    if (!base) return INT_MIN;
    uint64_t target = base + orig_fn_off;
    void **vt = (void **)vtable_addr;
    if (!ptr_plausible(vt)) return INT_MIN;
    if ((uintptr_t)vt < (uintptr_t)(4 * sizeof(void *))) return INT_MIN;
    if (!addr_readable((void *)((uintptr_t)vt - 4 * sizeof(void *)), 68 * sizeof(void *))) {
        acc_flog(@"swizzle: vtable unreadable @ %p", vt);
        return INT_MIN;
    }
    for (int i = -4; i < 64; i++) {
        void *cur = vt[i];
        if (!cur) continue;
        // PAC strip (arm64e instruction key A);arm64 涓婃槸 noop
#if __has_feature(ptrauth_calls)
        void *stripped = ptrauth_strip(cur, ptrauth_key_asia);
#else
        void *stripped = cur;
#endif
        if ((uint64_t)stripped != target) continue;
        // 鎵惧埌浜嗐€俶protect 鏁?16K 椤?RW (iOS 16 __DATA_CONST 鍙兘 deny 鈫?閫€鍖?vm_protect+COPY)
        uintptr_t page = (uintptr_t)&vt[i] & ~(uintptr_t)0x3FFF;
        bool wrote = false;
        if (mprotect((void *)page, 0x4000, PROT_READ | PROT_WRITE) == 0) {
            wrote = true;
        } else {
            int e1 = errno;
            // 澶囩敤:vm_protect with VM_PROT_COPY (fishhook 鍚屾)
            kern_return_t kr = vm_protect(mach_task_self(), (vm_address_t)page, 0x4000,
                                          0, VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY);
            if (kr == KERN_SUCCESS) {
                wrote = true;
            } else {
                acc_flog(@"swizzle: mprotect RW fail errno=%d, vm_protect kr=%d @ %p",
                         e1, kr, (void *)page);
            }
        }
        if (!wrote) return INT_MIN;
        if (out_orig) *out_orig = stripped;  // 瑁稿湴鍧€,鍙洿鎺ヨ皟鐢?
#if __has_feature(ptrauth_calls)
        // arm64e: 鐢ㄧ浉鍚?slot 鍦板潃浣滀负 discriminator blend 閲嶆柊绛惧悕
        // 娉ㄦ剰:C++ vtable 鐪熷疄 discriminator 鍦ㄧ紪璇戞湡 hash 鍐冲畾,杩欓噷鍙槸灏藉姏鑰屼负
        void *signed_new = ptrauth_sign_unauthenticated(new_fn,
                              ptrauth_key_asia,
                              ptrauth_blend_discriminator(&vt[i], 0));
        vt[i] = signed_new;
#else
        vt[i] = new_fn;
#endif
        // 涓嶈兘 PROT_EXEC, __DATA_CONST 涓嶅厑璁? 鎭㈠ RO (灏藉姏鑰屼负,澶辫触涔熸棤鎵€璋?
        mprotect((void *)page, 0x4000, PROT_READ);
        acc_flog(@"swizzle OK: vtable=%p slot[%d] orig=%p -> new=%p",
                 (void *)vtable_addr, i, stripped, new_fn);
        return i;
    }
    acc_flog(@"swizzle: NOT FOUND in vtable=%p target=%p (image+0x%llx)",
             (void *)vtable_addr, (void *)target, orig_fn_off);
    return INT_MIN;
}

static void install_vtable_swizzles(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        uint64_t base = arc_image_base();
        if (!base) { acc_flog(@"swizzle: no image base"); return; }
        // 1) MTP::getPositionMs vtable swap: 浠呯敤浜庤褰撳墠鎾斁浣嶇疆 (杩涘害鏉?
        //    + seek 鍙嶉), 涓嶅彉閫熴€?
        swizzle_vtable_find_swap(base + ARC_OFF_MTP_VTABLE, ARC_OFF_MTP_GETPOS,
                                 (void *)tw_mtp_getpos, (void **)&s_orig_mtp_getpos);
        // 2) Gameplay::update vtable swap: 姣忓抚鎷︽埅浠?
        //    a) 缂撳瓨 Gameplay 瀹炰緥 (渚?player_seek_ms 璁块棶 logic clock)
        //    b) 璋冪敤 _gp_retime_logic_clock(logic) 瀹炵幇璋遍潰鍙橀€?
        int gp_slot = swizzle_vtable_find_swap(base + ARC_OFF_GP_VTABLE, ARC_OFF_GP_UPDATE_FN,
                                               (void *)tw_gp_update, (void **)&s_orig_gp_update);
        if (gp_slot != INT_MIN && s_orig_gp_update)
            acc_flog(@"gp.update vtable installed slot=%d", gp_slot);
    });
}

static void time_warp_freeze_inc(void) {
    int32_t prev = atomic_fetch_add(&g_tw_freeze_count, 1);
    if (prev == 0) {
        struct timeval tv = {0};
        uint64_t real_us = 0;
        if (s_orig_gettod && s_orig_gettod(&tv, NULL) == 0)
            real_us = (uint64_t)tv.tv_sec * 1000000ULL + (uint64_t)tv.tv_usec;
        else if (gettimeofday(&tv, NULL) == 0)
            real_us = (uint64_t)tv.tv_sec * 1000000ULL + (uint64_t)tv.tv_usec;
        atomic_store(&g_tw_frozen_us, _compute_warp_us(real_us));
    }
}

static void time_warp_freeze_dec(void) {
    int32_t prev = atomic_fetch_sub(&g_tw_freeze_count, 1);
    if (prev <= 0) {
        atomic_store(&g_tw_freeze_count, 0);
        return;
    }
    if (prev == 1) {
        struct timeval tv = {0};
        uint64_t real_us = 0;
        if (s_orig_gettod && s_orig_gettod(&tv, NULL) == 0)
            real_us = (uint64_t)tv.tv_sec * 1000000ULL + (uint64_t)tv.tv_usec;
        else if (gettimeofday(&tv, NULL) == 0)
            real_us = (uint64_t)tv.tv_sec * 1000000ULL + (uint64_t)tv.tv_usec;
        atomic_store(&g_tw_t0_real_us, real_us);
        atomic_store(&g_tw_t0_warp_us, atomic_load(&g_tw_frozen_us) ? atomic_load(&g_tw_frozen_us) : real_us);
    }
}

void time_warp_set_rate(double rate) {
    if (rate <= 0.001) return;
    struct timeval tv_now = {0};
    int gtr = s_orig_gettod ? s_orig_gettod(&tv_now, NULL) : gettimeofday(&tv_now, NULL);
    uint64_t real_us_now = 0;
    if (gtr == 0) real_us_now = (uint64_t)tv_now.tv_sec * 1000000ULL + (uint64_t)tv_now.tv_usec;

    uint64_t warp_us_now = _compute_warp_us(real_us_now);
    atomic_store(&g_tw_t0_real_us, real_us_now);
    atomic_store(&g_tw_t0_warp_us, warp_us_now);
    atomic_store(&g_tw_rate_x1000, (uint32_t)(rate * 1000.0 + 0.5));
    s_gp_last_real_us = 0;
}

static void time_warp_install(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        struct rebinding rs[1] = {
            { "gettimeofday", (void *)tw_gettimeofday, (void **)&s_orig_gettod },
        };
        int r = rebind_symbols(rs, 1);
        acc_flog(@"fishhook ret=%d: gtod=%p", r, (void *)s_orig_gettod);
    });
}

// 璇诲彇璋遍潰鏃堕挓鐨勫綋鍓嶆樉绀?ms锛堝鍒?sub_10086E69C 閫昏緫锛?
// 鏃堕挓缁撴瀯: clock[32]=绱鏃堕棿, clock[40]=鍩哄噯鍋忕Щ, clock[45]=鍐呴儴椹卞姩鏍囧織, clock[52]=澶栭儴浣嶇疆
static int32_t _read_chart_clock_ms(void *clk) {
    if (!clk || !ptr_plausible(clk) || !addr_readable(clk, 64)) return -1;
    if (*(uint8_t *)((char *)clk + 45) & 1)
        return *(int32_t *)((char *)clk + 32) - *(int32_t *)((char *)clk + 40);
    int32_t v = *(int32_t *)((char *)clk + 52);
    int32_t off = (v <= 0) ? -3000 : 0;
    return v - *(int32_t *)((char *)clk + 40) + off;
}

void player_seek_ms(uint32_t ms) {
    void *self = get_player_or_resolve();
    if (!self) return;

    time_warp_freeze_inc();

    // 1. 闊抽璺宠浆锛歁TP::seekTo(this, ms, channel=0)
    typedef void (*seek_fn)(void *, uint32_t, int);
    seek_fn fn = (seek_fn)_player_vt_slot(self, 0x40);
    if (fn) {
        fn(self, ms, 0);
        acc_flog(@"[seek] audio seek to %u ms", ms);
    }

    // 2. 璋遍潰鏃堕挓璺宠浆锛氫慨鏀?clock[40] 浣垮緱 display_time = target_ms
    //    Gameplay(+928) 鈫?LogicChart(+48) 鈫?Clock
    //    display = clock[32] - clock[40]  (褰?clock[45] 缃綅鏃? steady_clock 椹卞姩)
    //    璋冩暣: clock[40] += (current_display - target_ms)
    void *gp = atomic_load(&g_gameplay_instance);
    if (gp && ptr_plausible(gp) && addr_readable((char *)gp + 936, 8)) {
        void *logic = *(void **)((char *)gp + 928);
        if (logic && ptr_plausible(logic) && addr_readable((char *)logic + 56, 8)) {
            void *clk = *(void **)((char *)logic + 48);
            int32_t cur_ms = _read_chart_clock_ms(clk);
            if (cur_ms >= -3000) {
                int32_t delta = cur_ms - (int32_t)ms;
                int32_t *base_off = (int32_t *)((char *)clk + 40);
                *base_off += delta;
                acc_flog(@"[seek] chart clock adjusted: cur=%d target=%u delta=%d new_base=%d",
                         cur_ms, ms, delta, *base_off);
            }
        }
    }

    s_gp_last_real_us = 0;

    time_warp_freeze_dec();
}

// (player_set_paused 宸茬Щ闄?

uint32_t player_get_position_ms_cached(void) {
    return atomic_load(&g_last_pos_ms);
}

// 璋冪敤鑰呴渶瑕佺殑鏈€澶ц繘搴﹀€硷細浼樺厛 FMOD 鎷垮埌鐨勭湡瀹炴€婚暱锛屽叾娆℃槸杩愯涓湅鍒拌繃鐨勬渶澶?ms
uint32_t player_get_progress_max_ms(void) {
    uint32_t len = atomic_load(&g_song_length_ms);
    if (len > 0) return len;
    return atomic_load(&g_max_seen_ms);
}

#pragma mark - config (Documents/xrc-arcdemo.plist)

NSString *arcConfigPath(void) {
    NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    if (!docs) return nil;
    return [docs stringByAppendingPathComponent:@"xrc-arcdemo.plist"];
}

static void migrateLegacyPrefsIfNeeded(void) {
    NSString *cfg = arcConfigPath();
    if (!cfg || [[NSFileManager defaultManager] fileExistsAtPath:cfg]) return;
    NSMutableDictionary *old = [[NSMutableDictionary alloc] initWithContentsOfFile:kPrefPath];
    if (!old || old.count == 0) return;
    [old writeToFile:cfg atomically:YES];
    acc_flog(@"migrated legacy prefs -> %@", cfg);
}

static void ensurePrefDefaults(NSMutableDictionary *p) {
    if (!p[@"speedKeys"] || ![p[@"speedKeys"] count]) {
        p[@"speedKeys"] = [@[@"speed-1", @"speed-2", @"speed-3", @"speed-4", @"speed-5"] mutableCopy];
        p[@"speed-1"] = @1.00;
        p[@"speed-2"] = @0.80;
        p[@"speed-3"] = @0.60;
        p[@"speed-4"] = @1.25;
        p[@"speed-5"] = @1.50;
    }
    if (!p[@"buttonEnabled"]) p[@"buttonEnabled"] = @YES;
    if (!p[@"toast"])         p[@"toast"]         = @YES;
    if (!p[@"rateIndex"])     p[@"rateIndex"]     = @0;
    if (!p[@"judgeMaxMs"] && p[@"judgeWindowScale"]) {
        float sc = [p[@"judgeWindowScale"] floatValue];
        if (sc < 0.25f) sc = 0.25f;
        if (sc > 4.0f) sc = 4.0f;
        p[@"judgeMaxMs"]  = @((int)lround(25.0f * sc));
        p[@"judgePureMs"] = @((int)lround(50.0f * sc));
        p[@"judgeFarMs"]  = @((int)lround(100.0f * sc));
        p[@"judgeLostMs"] = @((int)lround(120.0f * sc));
    }
    if (!p[@"judgeMaxMs"])  p[@"judgeMaxMs"]  = @25;
    if (!p[@"judgePureMs"]) p[@"judgePureMs"] = @50;
    if (!p[@"judgeFarMs"])  p[@"judgeFarMs"]  = @100;
    if (!p[@"judgeLostMs"]) p[@"judgeLostMs"] = @120;
}

NSMutableDictionary *loadPrefDict(void) {
    migrateLegacyPrefsIfNeeded();
    NSString *path = arcConfigPath();
    NSMutableDictionary *p = path ? [[NSMutableDictionary alloc] initWithContentsOfFile:path] : nil;
    if (!p) p = [NSMutableDictionary new];
    ensurePrefDefaults(p);
    return p;
}

void savePrefDict(NSDictionary *p) {
    NSString *path = arcConfigPath();
    if (!path) return;
    NSString *dir = [path stringByDeletingLastPathComponent];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    [p writeToFile:path atomically:YES];
}

void normalizeJudgeThresholds(void) {
    if (judgeMaxMs < 1) judgeMaxMs = 1;
    if (judgeMaxMs > 2000) judgeMaxMs = 2000;
    if (judgePureMs <= judgeMaxMs) judgePureMs = judgeMaxMs + 1;
    if (judgePureMs > 2000) judgePureMs = 2000;
    if (judgeFarMs <= judgePureMs) judgeFarMs = judgePureMs + 1;
    if (judgeFarMs > 2000) judgeFarMs = 2000;
    if (judgeLostMs <= judgeFarMs) judgeLostMs = judgeFarMs + 1;
    if (judgeLostMs > 2000) judgeLostMs = 2000;
}

void loadPref(void) {
    NSMutableDictionary *prefs = loadPrefDict();
    toast         = [prefs[@"toast"] boolValue];
    buttonEnabled = [prefs[@"buttonEnabled"] boolValue];

    NSArray *speedKeys = prefs[@"speedKeys"];
    rate_count = speedKeys.count;
    if (rates) { free(rates); rates = NULL; }
    rates = (float *)malloc(sizeof(float) * rate_count);
    NSInteger i = 0;
    for (NSString *k in speedKeys) rates[i++] = [prefs[k] floatValue];
    rate_i = [prefs[@"rateIndex"] integerValue];
    if (rate_i >= rate_count) rate_i = 0;

    judgeMaxMs  = [prefs[@"judgeMaxMs"] intValue];
    judgePureMs = [prefs[@"judgePureMs"] intValue];
    judgeFarMs  = [prefs[@"judgeFarMs"] intValue];
    judgeLostMs = [prefs[@"judgeLostMs"] intValue];
    normalizeJudgeThresholds();

    if (button) [button setHidden:!buttonEnabled];
}

#pragma mark - UI overlay (NSBundle / UIWindow keep-on-top)

%group ui
%hook NSBundle
+ (NSBundle *)bundleForClass:(Class)aClass {
    if (aClass == [%c(WHToastView) class]) {
        // WHToast resources are packaged next to the dylib; mainBundle is a fallback.
        NSBundle *main = [NSBundle mainBundle];
        return main ?: %orig;
    }
    return %orig;
}
%end

%hook UIWindow
- (void)bringSubviewToFront:(UIView *)view {
    %orig;
    // 闃查€掑綊锛氬綋澶栭儴鎶?button/menuView 鑷繁缃《鏃讹紝涓嶈鍐嶉€掑綊缃《瀹冧滑
    if (view == button || view == menuView) return;
    if (button) %orig(button);
    if (menuView) %orig(menuView);
}
- (void)addSubview:(UIView *)view {
    %orig;
    if (view == button || view == menuView) return;
    if (button) [self bringSubviewToFront:button];
    if (menuView) [self bringSubviewToFront:menuView];
}
%end

%hook WQSuspendView
- (instancetype)initWithFrame:(CGRect)frame showType:(WQSuspendViewType)type tapBlock:(void (^)(void))tapBlock {
    id ret = %orig;
    button = ret;
    return ret;
}
%end
%end

#pragma mark - in-game menu

@interface AccMenuController : NSObject
+ (instancetype)shared;
- (void)show;
- (void)hide;
- (void)rebuild;
@property (nonatomic, strong) NSTimer *progressTimer;
@property (nonatomic, strong) UISlider *progressSlider;
@property (nonatomic, strong) UILabel *progressLabel;
@property (nonatomic, assign) BOOL userDraggingSlider;
@end

@implementation AccMenuController

+ (instancetype)shared {
    static AccMenuController *s = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [AccMenuController new]; });
    return s;
}

- (UIWindow *)keyWindow {
    if ([UIApp.delegate respondsToSelector:@selector(window)]) {
        UIWindow *w = [UIApp.delegate performSelector:@selector(window)];
        if (w) return w;
    }
    for (UIWindow *w in UIApp.windows) if (w.isKeyWindow) return w;
    return UIApp.windows.firstObject;
}

- (void)show {
    UIWindow *w = [self keyWindow];
    if (!w) {
        for (UIWindow *win in UIApp.windows) {
            if (!win.hidden) { w = win; break; }
        }
    }
    if (!w) {
        acc_flog(@"show: no window");
        return;
    }
    if (menuView) [menuView removeFromSuperview];
    menuView = [[UIView alloc] initWithFrame:w.bounds];
    menuView.backgroundColor = [UIColor colorWithWhite:0 alpha:0.55];
    menuView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc]
        initWithTarget:self action:@selector(backgroundTap:)];
    [menuView addGestureRecognizer:tap];
    [w addSubview:menuView];
    [w bringSubviewToFront:menuView];
    [self rebuild];
}

- (void)hide {
    [self.progressTimer invalidate];
    self.progressTimer = nil;
    self.progressSlider = nil;
    self.progressLabel = nil;
    [menuView removeFromSuperview];
    menuView = nil;
}

- (void)backgroundTap:(UITapGestureRecognizer *)g {
    CGPoint p = [g locationInView:menuView];
    UIView *card = [menuView viewWithTag:9001];
    if (!card || CGRectContainsPoint(card.frame, p)) return;
    [self hide];
}

- (void)rebuild {
    if (!menuView) return;
    for (UIView *sub in [menuView.subviews copy]) [sub removeFromSuperview];

    CGFloat W = MIN(menuView.bounds.size.width - 40, 320);
    CGFloat X = (menuView.bounds.size.width - W) / 2;

    UIScrollView *card = [[UIScrollView alloc] initWithFrame:CGRectMake(X, 80, W, menuView.bounds.size.height - 160)];
    card.tag = 9001;
    card.backgroundColor = [UIColor colorWithWhite:1 alpha:0.95];
    card.layer.cornerRadius = 12;
    card.layer.masksToBounds = YES;
    [menuView addSubview:card];

    CGFloat y = 12;
    CGFloat innerW = W - 24;

    // 鏍囬
    UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(12, y, innerW, 24)];
    title.text = [NSString stringWithFormat:@"Arcaea 鍙橀€?(XRC) %@ [%@]",
                  XRC_TWEAK_VERSION, XRC_BUILD_LABEL];
    title.font = [UIFont boldSystemFontOfSize:18];
    title.textColor = [UIColor blackColor];
    [card addSubview:title];
    y += 28;

    UILabel *scope = [[UILabel alloc] initWithFrame:CGRectMake(12, y, innerW, 44)];
    scope.text = @"璋遍潰+鐢婚潰鍙橀€燂紱BGM 1.0脳銆傞厤缃? Documents/xrc-arcdemo.plist";
    scope.font = [UIFont systemFontOfSize:11];
    scope.textColor = [UIColor darkGrayColor];
    scope.numberOfLines = 0;
    [card addSubview:scope];
    y += 48;

    BOOL playerReady = (get_player_or_resolve() != NULL);

    UILabel *playerHdr = [[UILabel alloc] initWithFrame:CGRectMake(12, y, innerW, 18)];
    playerHdr.text = playerReady ? @"杩涘害 seek" : @"杩涘害 (绛夊緟瀵瑰眬...)";
    playerHdr.font = [UIFont systemFontOfSize:13];
    playerHdr.textColor = [UIColor darkGrayColor];
    [card addSubview:playerHdr];
    y += 22;

    UISlider *sl = [[UISlider alloc] initWithFrame:CGRectMake(12, y, innerW, 28)];
    sl.minimumValue = 0;
    uint32_t maxMs = MAX(player_get_progress_max_ms(), (uint32_t)1000);
    sl.maximumValue = (float)maxMs;
    sl.value = (float)player_get_position_ms_cached();
    sl.continuous = YES;
    sl.enabled = playerReady;
    [sl addTarget:self action:@selector(sliderTouchDown:) forControlEvents:UIControlEventTouchDown];
    [sl addTarget:self action:@selector(sliderTouchUp:)   forControlEvents:UIControlEventTouchUpInside | UIControlEventTouchUpOutside | UIControlEventTouchCancel];
    [card addSubview:sl];
    self.progressSlider = sl;
    y += 32;

    UILabel *posLbl = [[UILabel alloc] initWithFrame:CGRectMake(12, y, innerW, 16)];
    posLbl.font = [UIFont systemFontOfSize:11];
    posLbl.textColor = [UIColor darkGrayColor];
    posLbl.textAlignment = NSTextAlignmentCenter;
    posLbl.text = @"--:-- / --:--";
    [card addSubview:posLbl];
    self.progressLabel = posLbl;
    y += 22;

    [self.progressTimer invalidate];
    self.progressTimer = [NSTimer scheduledTimerWithTimeInterval:0.1
                                                          target:self
                                                        selector:@selector(progressTick:)
                                                        userInfo:nil
                                                         repeats:YES];

    // toast switch
    UILabel *toastLbl = [[UILabel alloc] initWithFrame:CGRectMake(12, y, innerW - 60, 28)];
    toastLbl.text = @"Show speed toast";
    toastLbl.font = [UIFont systemFontOfSize:14];
    toastLbl.textColor = [UIColor blackColor];
    [card addSubview:toastLbl];
    UISwitch *toastSw = [[UISwitch alloc] initWithFrame:CGRectZero];
    CGSize swSize = toastSw.bounds.size;
    toastSw.frame = CGRectMake(W - 12 - swSize.width, y, swSize.width, swSize.height);
    toastSw.on = toast;
    [toastSw addTarget:self action:@selector(toastChanged:) forControlEvents:UIControlEventValueChanged];
    [card addSubview:toastSw];
    y += MAX(28, swSize.height) + 8;

    UILabel *judgeHdr = [[UILabel alloc] initWithFrame:CGRectMake(12, y, innerW, 32)];
    judgeHdr.text = @"鍒ゅ畾绐楀彛 卤ms (Max / Pure / Far / Lost)";
    judgeHdr.font = [UIFont systemFontOfSize:12];
    judgeHdr.textColor = [UIColor darkGrayColor];
    judgeHdr.numberOfLines = 2;
    [card addSubview:judgeHdr];
    y += 34;

    const char *judgeTags[] = { "Max", "Pure", "Far", "Lost" };
    int judgeVals[] = { judgeMaxMs, judgePureMs, judgeFarMs, judgeLostMs };
    CGFloat colW = (innerW - 8) / 4.0f;
    for (int j = 0; j < 4; j++) {
        CGFloat cx = 12 + colW * j;
        UILabel *lbl = [[UILabel alloc] initWithFrame:CGRectMake(cx, y, colW - 4, 14)];
        lbl.text = @(judgeTags[j]);
        lbl.font = [UIFont systemFontOfSize:10];
        lbl.textAlignment = NSTextAlignmentCenter;
        lbl.textColor = [UIColor grayColor];
        [card addSubview:lbl];

        UITextField *tf = [[UITextField alloc] initWithFrame:CGRectMake(cx, y + 16, colW - 4, 32)];
        tf.borderStyle = UITextBorderStyleRoundedRect;
        tf.font = [UIFont monospacedDigitSystemFontOfSize:13 weight:UIFontWeightRegular];
        tf.textAlignment = NSTextAlignmentCenter;
        tf.keyboardType = UIKeyboardTypeNumberPad;
        tf.text = [NSString stringWithFormat:@"%d", judgeVals[j]];
        tf.tag = 4100 + j;
        tf.delegate = (id<UITextFieldDelegate>)self;
        [card addSubview:tf];
    }
    y += 52;

    UILabel *speedHdr = [[UILabel alloc] initWithFrame:CGRectMake(12, y, innerW, 18)];
    speedHdr.text = @"鍊嶇巼 (鍗曞嚮=閫変腑, 闀挎寜=鍒犻櫎)";
    speedHdr.font = [UIFont systemFontOfSize:12];
    speedHdr.textColor = [UIColor darkGrayColor];
    speedHdr.numberOfLines = 0;
    [card addSubview:speedHdr];
    y += 32;

    NSMutableDictionary *prefs = loadPrefDict();
    NSArray *keys = prefs[@"speedKeys"];
    for (NSInteger i = 0; i < (NSInteger)keys.count; i++) {
        NSString *k = keys[i];
        float v = [prefs[k] floatValue];

        UIButton *row = [UIButton buttonWithType:UIButtonTypeSystem];
        row.frame = CGRectMake(12, y, innerW - 60, 32);
        row.tag = 1000 + i;
        [row setTitle:[NSString stringWithFormat:@"  %.3f脳", v] forState:UIControlStateNormal];
        row.titleLabel.font = [UIFont systemFontOfSize:15];
        row.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeft;
        row.backgroundColor = (i == rate_i) ? [UIColor colorWithRed:0.9 green:0.95 blue:1 alpha:1] : [UIColor clearColor];
        row.layer.cornerRadius = 6;
        [row addTarget:self action:@selector(rowTapped:) forControlEvents:UIControlEventTouchUpInside];
        UILongPressGestureRecognizer *lp = [[UILongPressGestureRecognizer alloc]
            initWithTarget:self action:@selector(rowLongPress:)];
        [row addGestureRecognizer:lp];
        [card addSubview:row];

        UITextField *tf = [[UITextField alloc] initWithFrame:CGRectMake(W - 12 - 56, y, 56, 32)];
        tf.borderStyle = UITextBorderStyleRoundedRect;
        tf.font = [UIFont systemFontOfSize:13];
        tf.text = [NSString stringWithFormat:@"%.2f", v];
        tf.keyboardType = UIKeyboardTypeDecimalPad;
        tf.textAlignment = NSTextAlignmentCenter;
        tf.tag = 2000 + i;
        tf.delegate = (id<UITextFieldDelegate>)self;
        [card addSubview:tf];

        y += 38;
    }

    UIButton *addBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    addBtn.frame = CGRectMake(12, y, innerW, 32);
    [addBtn setTitle:@"+ 娣诲姞鍊嶇巼" forState:UIControlStateNormal];
    [addBtn addTarget:self action:@selector(addSpeed) forControlEvents:UIControlEventTouchUpInside];
    [card addSubview:addBtn];
    y += 40;

    UIButton *closeBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    closeBtn.frame = CGRectMake(12, y, innerW, 32);
    [closeBtn setTitle:@"鍏抽棴" forState:UIControlStateNormal];
    [closeBtn setTitleColor:[UIColor systemRedColor] forState:UIControlStateNormal];
    [closeBtn addTarget:self action:@selector(hide) forControlEvents:UIControlEventTouchUpInside];
    [card addSubview:closeBtn];
    y += 40;

    card.contentSize = CGSizeMake(W, y + 12);
}

- (void)sliderTouchDown:(UISlider *)s { self.userDraggingSlider = YES; }
- (void)sliderTouchUp:(UISlider *)s {
    self.userDraggingSlider = NO;
    player_seek_ms((uint32_t)s.value);
}

- (void)progressTick:(NSTimer *)t {
    if (!menuView) { [t invalidate]; self.progressTimer = nil; return; }
    uint32_t cur = player_get_position_ms_cached();
    uint32_t maxMs = MAX(player_get_progress_max_ms(), (uint32_t)1000);
    UISlider *sl = self.progressSlider;
    UILabel *lbl = self.progressLabel;
    if (sl) {
        if (sl.maximumValue < (float)maxMs) sl.maximumValue = (float)maxMs;
        if (!self.userDraggingSlider) sl.value = (float)cur;
        if (!sl.enabled && get_player_or_resolve()) sl.enabled = YES;
    }
    if (lbl) {
        uint32_t cs = cur / 1000u, ms = cur % 1000u;
        uint32_t ts = maxMs / 1000u;
        lbl.text = [NSString stringWithFormat:@"%02u:%02u.%03u / %02u:%02u",
                    cs / 60u, cs % 60u, ms,
                    ts / 60u, ts % 60u];
    }
}

- (void)toastChanged:(UISwitch *)s {
    NSMutableDictionary *p = loadPrefDict();
    p[@"toast"] = @(s.on);
    savePrefDict(p);
    loadPref();
}

- (void)commitJudgeField:(UITextField *)tf {
    int v = MAX(0, [tf.text intValue]);
    switch (tf.tag - 4100) {
        case 0: judgeMaxMs = v; break;
        case 1: judgePureMs = v; break;
        case 2: judgeFarMs = v; break;
        case 3: judgeLostMs = v; break;
        default: return;
    }
    normalizeJudgeThresholds();
    tf.text = [NSString stringWithFormat:@"%d",
               (tf.tag == 4100) ? judgeMaxMs :
               (tf.tag == 4101) ? judgePureMs :
               (tf.tag == 4102) ? judgeFarMs : judgeLostMs];
    NSMutableDictionary *p = loadPrefDict();
    p[@"judgeMaxMs"]  = @(judgeMaxMs);
    p[@"judgePureMs"] = @(judgePureMs);
    p[@"judgeFarMs"]  = @(judgeFarMs);
    p[@"judgeLostMs"] = @(judgeLostMs);
    savePrefDict(p);
    if (toast) {
        [WHToast showMessage:[NSString stringWithFormat:@"鍒ゅ畾鍙傛暟宸蹭繚瀛?卤%d/%d/%d/%d",
                              judgeMaxMs, judgePureMs, judgeFarMs, judgeLostMs]
                    duration:0.8 finishHandler:^{}];
    }
}

- (void)rowTapped:(UIButton *)b {
    NSInteger i = b.tag - 1000;
    if (i < 0 || i >= rate_count) return;
    rate_i = i;
    time_warp_set_rate((double)rates[rate_i]);
    NSMutableDictionary *p = loadPrefDict();
    p[@"rateIndex"] = @(rate_i);
    savePrefDict(p);
    if (toast) {
        [WHToast showMessage:[NSString stringWithFormat:@"%.3fx", rates[rate_i]]
                               duration:0.5 finishHandler:^{}];
    }
    [self rebuild];
}

- (void)rowLongPress:(UILongPressGestureRecognizer *)g {
    if (g.state != UIGestureRecognizerStateBegan) return;
    NSInteger i = g.view.tag - 1000;
    if (i < 0) return;
    NSMutableDictionary *p = loadPrefDict();
    NSMutableArray *keys = [p[@"speedKeys"] mutableCopy];
    if (i >= (NSInteger)keys.count) return;
    if (keys.count <= 1) return; // 鑷冲皯鐣欎竴涓?
    NSString *k = keys[i];
    [keys removeObjectAtIndex:i];
    [p removeObjectForKey:k];
    p[@"speedKeys"] = keys;
    savePrefDict(p);
    loadPref();
    [self rebuild];
}

- (void)addSpeed {
    NSMutableDictionary *p = loadPrefDict();
    NSMutableArray *keys = [p[@"speedKeys"] mutableCopy];
    NSInteger n = 1;
    NSString *nk;
    do { nk = [NSString stringWithFormat:@"speed-%ld", (long)n++]; } while ([keys containsObject:nk]);
    [keys addObject:nk];
    p[nk] = @1.0;
    p[@"speedKeys"] = keys;
    savePrefDict(p);
    loadPref();
    [self rebuild];
}

// UITextFieldDelegate
- (void)textFieldDidEndEditing:(UITextField *)tf {
    if (tf.tag >= 4100 && tf.tag <= 4103) {
        [self commitJudgeField:tf];
        return;
    }
    NSInteger i = tf.tag - 2000;
    if (i < 0 || i >= rate_count) return;
    float v = MAX(0.0f, MIN(100.0f, [tf.text floatValue]));
    NSMutableDictionary *p = loadPrefDict();
    NSArray *keys = p[@"speedKeys"];
    if (i >= (NSInteger)keys.count) return;
    p[keys[i]] = @(v);
    savePrefDict(p);
    loadPref();
}
- (BOOL)textFieldShouldReturn:(UITextField *)tf {
    [tf resignFirstResponder];
    return YES;
}

@end

#pragma mark - floating button bootstrap

static void initButton(void) {
    [WHToast setShowMask:NO];
    [WQSuspendView showWithType:WQSuspendViewTypeNone tapBlock:^{
        // 鍗曞嚮锛氬垏鎹㈠€嶇巼锛堜綆棰戝姩浣滐級
        if (rate_count <= 0) return;
        rate_i = (rate_i + 1) % rate_count;
        time_warp_set_rate((double)rates[rate_i]);
        NSMutableDictionary *p = loadPrefDict();
        p[@"rateIndex"] = @(rate_i);
        savePrefDict(p);
        if (toast) {
            [WHToast showMessage:[NSString stringWithFormat:@"%.3fx (鍙屽嚮鎵撳紑鑿滃崟)", rates[rate_i]]
                                       duration:0.5 finishHandler:^{}];
        }
    }];
    button.frame = CGRectMake(0, 200, 40, 40);
    button.backgroundColor = [UIColor blackColor];
    button.layer.cornerRadius = 20;
    button.layer.masksToBounds = YES;
    button.layer.borderWidth = 3.0;
    button.layer.borderColor = [UIColor whiteColor].CGColor;

    UILabel *label = [[UILabel alloc] initWithFrame:CGRectMake(3, 13, 34, 14)];
    label.text = @"xrc";
    label.textColor = [UIColor whiteColor];
    label.font = [UIFont systemFontOfSize:11];
    label.textAlignment = NSTextAlignmentCenter;
    [button addSubview:label];

    UITapGestureRecognizer *dt = [[UITapGestureRecognizer alloc]
        initWithTarget:[AccMenuController shared] action:@selector(handleDoubleTap:)];
    dt.numberOfTapsRequired = 2;
    [button addGestureRecognizer:dt];

    UIWindow *w = [[AccMenuController shared] keyWindow];
    if (w && !button.superview) {
        [w addSubview:button];
        [w bringSubviewToFront:button];
    }
    if (!buttonEnabled) [button setHidden:YES];
}

@interface AccMenuController (MenuGesture) @end
@implementation AccMenuController (MenuGesture)
- (void)handleDoubleTap:(UITapGestureRecognizer *)g {
    [self show];
}
@end

#pragma mark - bootstrap

// 鏂囦欢鏃ュ織锛歴ideload 涓嬫病娉曟帴 Console锛屽啓鍒?app Documents/xrc-arcdemo.log
void acc_flog(NSString *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    NSString *line = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    NSLog(@"[xrc-arcdemo] %@", line);
    @try {
        NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
        if (!docs) return;
        NSString *path = [docs stringByAppendingPathComponent:@"xrc-arcdemo.log"];
        NSDateFormatter *df = [[NSDateFormatter alloc] init];
        df.dateFormat = @"yyyy-MM-dd HH:mm:ss.SSS";
        NSString *out = [NSString stringWithFormat:@"[%@] %@\n", [df stringFromDate:[NSDate date]], line];
        NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:path];
        if (!fh) {
            [out writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
        } else {
            [fh seekToEndOfFile];
            [fh writeData:[out dataUsingEncoding:NSUTF8StringEncoding]];
            [fh closeFile];
        }
    } @catch (NSException *e) {}
}

static void doBootstrap(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        acc_flog(@"==== xrc-arcdemo tweak %@ doBootstrap begin ====", XRC_TWEAK_VERSION);
        @try { initButton(); }       @catch (NSException *e) { acc_flog(@"initButton EX: %@", e); }
        @try { install_arc_hooks(); } @catch (NSException *e) { acc_flog(@"install_arc_hooks EX: %@", e); }
        @try { time_warp_install(); } @catch (NSException *e) { acc_flog(@"time_warp_install EX: %@", e); }
        @try { install_vtable_swizzles(); } @catch (NSException *e) { acc_flog(@"install_vtable_swizzles EX: %@", e); }
        if (rate_count > 0)
            time_warp_set_rate((double)rates[rate_i]);
        acc_flog(@"config path: %@", arcConfigPath());
        // 0.5s 杞: 鎹㈡洸妫€娴?+ 浠?FMOD 琛ヨ冻杩涘害鏉℃暟鎹?
        [NSTimer scheduledTimerWithTimeInterval:0.5 repeats:YES block:^(NSTimer *t) {
            void *p = get_player_or_resolve();
            static void *s_last_player = NULL;
            static void *s_last_channels = NULL;
            void *channels_base_chk = p ? *(void **)((char *)p + ARC_PLAYER_CHANNELS_OFFSET) : NULL;
            if (p != s_last_player || channels_base_chk != s_last_channels) {
                atomic_store(&g_song_length_ms, 0);
                atomic_store(&g_max_seen_ms, 0);
                atomic_store(&g_last_pos_ms, 0);
                s_last_player = p;
                s_last_channels = channels_base_chk;
                acc_flog(@"new song: player=%p", p);
            }
            if (p) try_capture_song_length(p);
            // 鍏滃簳缁存姢 last_pos_ms / max_seen_ms锛堢敤浜庤繘搴︽潯鏄剧ず锛?
            if (p && g_ch_get_position) {
                void *channels_base = channels_base_chk;
                if (channels_base) {
                    void *ch0 = *(void **)((char *)channels_base + ARC_CHANNEL_ENTRY_PTR_OFF);
                    uint32_t pos = 0;
                    if (ch0 && g_ch_get_position(ch0, &pos, 1) == 0) {
                        atomic_store(&g_last_pos_ms, pos);
                        uint32_t prev = atomic_load(&g_max_seen_ms);
                        if (pos > prev) atomic_store(&g_max_seen_ms, pos);
                    }
                }
            }
        }];
        acc_flog(@"doBootstrap done");
    });
}

static void onAppDidEnterBackground(CFNotificationCenterRef center, void *observer,
                                    CFStringRef name, const void *object,
                                    CFDictionaryRef userInfo) {
    // 鍒囧悗鍙帮細鍐荤粨 warp 鏃堕棿锛岄槻姝㈠洖鍓嶅彴鏃?currentTimeMs 璺冲彉 = 鍚庡彴鏃堕暱 * rate
    time_warp_freeze_inc();
    acc_flog(@"app -> background, warp frozen (count=%d)", atomic_load(&g_tw_freeze_count));
}

static void onAppWillEnterForeground(CFNotificationCenterRef center, void *observer,
                                     CFStringRef name, const void *object,
                                     CFDictionaryRef userInfo) {
    s_gp_last_real_us = 0;  // 鍥炲墠鍙板悗閲嶅缓 retime 鍩哄噯
    time_warp_freeze_dec();
    acc_flog(@"app -> foreground, warp unfrozen (count=%d)", atomic_load(&g_tw_freeze_count));
}

static void onAppLaunched(CFNotificationCenterRef center, void *observer,
                          CFStringRef name, const void *object,
                          CFDictionaryRef userInfo) {
    acc_flog(@"onAppLaunched notification fired");
    doBootstrap();
}

%ctor {
    acc_flog(@"ctor entered (dylib loaded ok)");
    @try { %init(ui); }   @catch (NSException *e) { acc_flog(@"%%init(ui) EX: %@", e); }
    @try { loadPref(); }  @catch (NSException *e) { acc_flog(@"loadPref EX: %@", e); }
    CFNotificationCenterAddObserver(CFNotificationCenterGetLocalCenter(), NULL,
        onAppLaunched,
        (CFStringRef)UIApplicationDidFinishLaunchingNotification,
        NULL, CFNotificationSuspensionBehaviorCoalesce);
    CFNotificationCenterAddObserver(CFNotificationCenterGetLocalCenter(), NULL,
        onAppDidEnterBackground,
        (CFStringRef)UIApplicationDidEnterBackgroundNotification,
        NULL, CFNotificationSuspensionBehaviorCoalesce);
    CFNotificationCenterAddObserver(CFNotificationCenterGetLocalCenter(), NULL,
        onAppWillEnterForeground,
        (CFStringRef)UIApplicationWillEnterForegroundNotification,
        NULL, CFNotificationSuspensionBehaviorCoalesce);
    // 鍏滃簳锛氬鏋?ctor 鍦?UIApplicationDidFinishLaunching 涔嬪悗鎵嶈窇锛堢悊璁轰笂涓嶄細锛屼絾
    // 娉ㄥ叆宸ュ叿濡傛灉鐢?LC_LOAD_WEAK_DYLIB / 寤惰繜鍔犺浇鍙兘閿欒繃閫氱煡锛夛紝3 绉掑悗寮哄埗璧颁竴娆?
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        acc_flog(@"3s fallback bootstrap");
        doBootstrap();
    });
}
