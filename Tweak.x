// AccDemoArcaea / Tweak.x
// Fork of brendonjkding/accDemo, Arcaea-only, single-binary, in-game menu.
//
// 阶段 A：保�?Substrate 调用�?hookf / %hook / %init），便于 TrollStore + ellekit
//         直接装载验证。后续阶�?B 会替换为 fishhook + Method Swizzle，去 Substrate 依赖�?

#import <substrate.h>
#import <time.h>
#import <dlfcn.h>
#import <mach/mach_time.h>
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

#import "dobby.h"
#import "fishhook.h"

extern UIApplication *UIApp;

#import "SuspendView/WQSuspendView.h"
#import "WHToast/WHToast.h"

// forward decl: 文件末尾定义，但中部诊断需要用
static void acc_flog(NSString *fmt, ...) NS_FORMAT_FUNCTION(1, 2);

#pragma mark - global

static float    *rates = NULL;
static NSInteger rate_i = 0;
static NSInteger rate_count = 0;

static BOOL     buttonEnabled = YES;
static BOOL     toast = YES;

static WQSuspendView *button = nil;
static UIView        *menuView = nil;
#pragma mark - Arcaea binary hook (Dobby)
//
// 已知偏移（来�?IDA 6.13.10 分析）：
//   sub_100846950 (vtable[7] of MultiTrackPlayer) = getPositionMs(this, channel)
//   sub_100846914 (vtable[6])                     = setPaused(this, paused, channel)
//   sub_10084699C (vtable[8])                     = seekTo(this, ms, channel)
//   sub_100C9D718                                 = getRegistry()    �?全局单例
//   *(getRegistry() + 8)                          = MultiTrackPlayer
//   sub_100EC094C                                 = Channel::getCurrentSound(ch, Sound**)
//   sub_100F2BB64                                 = Sound::getLength(snd, uint32_t*, unit=1)
//   sub_100EC069C                                 = Channel::setFrequency(ch, float)   �?备用
// 
// MTP 内部布局：通道数组 channels[i] @ player+0x38 起，步长 16，每�?+8 = Channel*�?
//   ch0 = *(*(player+0x38) + 8)
//
// 运行时地址 = arcaea_base + offset
#define ARC_OFF_GET_POSITION_MS    (0x846950ULL)
#define ARC_OFF_GET_REGISTRY       (0xC9D718ULL)
#define ARC_OFF_CC_SINGLETON_GETTER (0xCDF358ULL)
#define ARC_OFF_GET_CURRENT_SOUND  (0xEC094CULL)
#define ARC_OFF_GET_SOUND_LENGTH   (0xF2BB64ULL)
// 直接 FMOD Channel API，绕开 MTP 包装。
//   getPositionMs(MTP, ch) 内部就是 Channel::getPosition（已确认）→ 改频率 → 谱面/音频同步
#define ARC_OFF_CH_GET_POSITION    (0xEC03ACULL)
#define ARC_OFF_CH_SET_FREQUENCY   (0xEC069CULL)
#define ARC_OFF_CH_GET_FREQUENCY   (0xEC077CULL)
#define ARC_REG_PLAYER_OFFSET      (8)
#define ARC_PLAYER_CHANNELS_OFFSET (0x38)
#define ARC_CHANNEL_ENTRY_PTR_OFF  (8)
#define ARC_CHANNEL_ENTRY_STRIDE   (16)

typedef uint32_t (*get_position_ms_fn)(void *self, int channel);
typedef void *   (*get_registry_fn)(void);
typedef int      (*get_current_sound_fn)(void *channel, void **outSound);
typedef int      (*get_sound_length_fn)(void *sound, uint32_t *outLen, int unit);
typedef int      (*ch_get_position_fn)(void *channel, uint32_t *out_ms, int unit);
typedef int      (*ch_set_frequency_fn)(void *channel, float hz);
typedef int      (*ch_get_frequency_fn)(void *channel, float *out_hz);
typedef void *   (*get_cc_singleton_fn)(void);
static get_registry_fn      g_get_registry = NULL;
static get_current_sound_fn g_get_current_sound = NULL;
static get_sound_length_fn  g_get_sound_length = NULL;
static ch_get_position_fn   g_ch_get_position = NULL;
static ch_set_frequency_fn  g_ch_set_frequency = NULL;
static ch_get_frequency_fn  g_ch_get_frequency = NULL;
static get_cc_singleton_fn  g_get_cc_singleton = NULL;
// 缓存每个 channel 的「初始基准频率」，第一次 setFrequency 前用 getFrequency 抓
#define ARC_MAX_CHANNELS  (8)
static _Atomic(float) g_base_freq[ARC_MAX_CHANNELS];   // 0 = 未捕获

// �?hook 兜底捕获 + 主动通过 registry 获取
static _Atomic(void *)   g_bgmPlayer = NULL;
static _Atomic(uint32_t) g_last_pos_ms = 0;
static _Atomic(uint32_t) g_max_seen_ms = 0;
static _Atomic(uint32_t) g_song_length_ms = 0;   // FMOD 拿到的真实总时�?

// 尝试�?player 主轨�?Sound 总长
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

// 主动通过 registry 拿 MTP（不需要等 hook 触发）
static void *resolve_player_via_registry(void) {
    if (!g_get_registry) return NULL;
    void *reg = g_get_registry();
    if (!reg) return NULL;
    void *mtp = *(void **)((char *)reg + ARC_REG_PLAYER_OFFSET);
    if (mtp) atomic_store(&g_bgmPlayer, mtp);
    return mtp;
}

static inline void *get_player_or_resolve(void) {
    void *p = atomic_load(&g_bgmPlayer);
    if (p) return p;
    return resolve_player_via_registry();
}

// 防止读到野指针：先做用户态地址粗筛。
static inline bool ptr_plausible(const void *p) {
    uintptr_t v = (uintptr_t)p;
    if (v < 0x100000000ULL) return false;
    if ((v & 0x7ULL) != 0) return false;
    return true;
}

static bool addr_readable(const void *p, size_t len) {
    if (!p || len == 0) return false;
    if (!ptr_plausible(p)) return false;
    uintptr_t start_u = (uintptr_t)p;
    uintptr_t end_u = start_u + len;
    if (end_u < start_u) return false;
    // 启发式上限：拒绝超大跨度访问，避免野 end 指针导致后续越界。
    if (len > (1ULL << 20)) return false;
    // 这里不再调用 vm_region_recurse（部分 Theos/SDK 组合下该符号缺失导致链接失败）。
    return true;
}

// �?Arc-mobile 主二进制基址
static uint64_t arc_image_base(void) {
    static uint64_t cached = 0;
    if (cached) return cached;
    uint32_t n = _dyld_image_count();
    for (uint32_t i = 0; i < n; i++) {
        const char *name = _dyld_get_image_name(i);
        if (!name) continue;
        // CFBundleExecutable = "Arc-mobile"
        if (strstr(name, "Arc-mobile") != NULL) {
            cached = (uint64_t)_dyld_get_image_header(i);
            break;
        }
    }
    if (!cached && n > 0) {
        // 兜底：主可执行体一般是 image 0
        cached = (uint64_t)_dyld_get_image_header(0);
    }
    return cached;
}

static void install_arc_hooks(void) {
    uint64_t base = arc_image_base();
    if (!base) {
        NSLog(@"[AccDemoArcaea] arc_image_base() = 0, abort");
        return;
    }
    // iOS 16 sideload: 不要给主二进制 __TEXT 打 DobbyHook 补丁。
    // mprotect(rwx) 会破坏 amfi/CoreTrust 的 text page seal，
    // 其它线程跑该页时触发 EXC_BAD_ACCESS / Permission fault (Instruction Abort)。
    // 改为只读取函数指针，不修改函数实现。
    g_get_registry = (get_registry_fn)(base + ARC_OFF_GET_REGISTRY);
    g_get_cc_singleton = (get_cc_singleton_fn)(base + ARC_OFF_CC_SINGLETON_GETTER);
    g_get_current_sound = (get_current_sound_fn)(base + ARC_OFF_GET_CURRENT_SOUND);
    g_get_sound_length  = (get_sound_length_fn) (base + ARC_OFF_GET_SOUND_LENGTH);
    g_ch_get_position   = (ch_get_position_fn) (base + ARC_OFF_CH_GET_POSITION);
    g_ch_set_frequency  = (ch_set_frequency_fn)(base + ARC_OFF_CH_SET_FREQUENCY);
    g_ch_get_frequency  = (ch_get_frequency_fn)(base + ARC_OFF_CH_GET_FREQUENCY);
        NSLog(@"[AccDemoArcaea] registry=%p ccGetter=%p getCurrentSound=%p getLength=%p setFreq=%p",
            (void *)g_get_registry, (void *)g_get_cc_singleton, (void *)g_get_current_sound,
          (void *)g_get_sound_length, (void *)g_ch_set_frequency);
    void *mtp = resolve_player_via_registry();
    NSLog(@"[AccDemoArcaea] initial MTP via registry = %p", mtp);
    if (mtp) try_capture_song_length(mtp);
}

// 通过 player vtable 调用对应槽位
static inline void *_player_vt_slot(void *self, size_t byte_off) {
    if (!self) return NULL;
    void **vtable = *(void ***)self;
    if (!vtable) return NULL;
    return vtable[byte_off / sizeof(void *)];
}

// 枚举 player 的所有 channel 指针；返回写入数量（最多 outCap 个）
static int player_collect_channels(void **outChs, int outCap) {
    void *self = get_player_or_resolve();
    if (!self) return 0;
    if (!ptr_plausible(self)) return 0;
    if (!addr_readable((char *)self + ARC_PLAYER_CHANNELS_OFFSET, 16)) return 0;
    void *channels_base = *(void **)((char *)self + ARC_PLAYER_CHANNELS_OFFSET);
    void *channels_end  = *(void **)((char *)self + ARC_PLAYER_CHANNELS_OFFSET + 8);
    if (!ptr_plausible(channels_base) || !ptr_plausible(channels_end)) return 0;
    if (!channels_base || !channels_end || channels_end < channels_base) return 0;
    size_t span = (size_t)((char *)channels_end - (char *)channels_base);
    if (span > (size_t)ARC_CHANNEL_ENTRY_STRIDE * 256U) return 0;
    if (!addr_readable(channels_base, span ? span : ARC_CHANNEL_ENTRY_STRIDE)) return 0;
    size_t n = span / ARC_CHANNEL_ENTRY_STRIDE;
    if (n > (size_t)outCap) n = (size_t)outCap;
    int got = 0;
    for (size_t i = 0; i < n; i++) {
        void *entry = (char *)channels_base + ARC_CHANNEL_ENTRY_STRIDE * i + ARC_CHANNEL_ENTRY_PTR_OFF;
        if (!addr_readable(entry, sizeof(void *))) continue;
        void *ch = *(void **)entry;
        if (ch) outChs[got++] = ch;
    }
    return got;
}

// 把当前 rate 应用到所有 channel：base_freq * rate；首个调用会缓存 base_freq
static void apply_speed_to_all_channels(void) {
    if (!g_ch_set_frequency || !g_ch_get_frequency) return;
    if (rate_count <= 0 || !rates) return;
    float rate = rates[rate_i];
    if (rate <= 0.001f) return;
    void *chs[ARC_MAX_CHANNELS] = {0};
    int n = player_collect_channels(chs, ARC_MAX_CHANNELS);
    for (int i = 0; i < n; i++) {
        float base = atomic_load(&g_base_freq[i]);
        if (base <= 1.0f) {
            float cur = 0;
            if (g_ch_get_frequency(chs[i], &cur) == 0 && cur > 1.0f) {
                // 第一次：当前频率就是上次设置后的值。如果之前没改过，cur 就是 base。
                // 为了简单起见：第一次见到 channel 时，cur 视为 base（要求第一次调用前 rate 必须 = 1.0）。
                base = cur;
                atomic_store(&g_base_freq[i], base);
            } else {
                continue;
            }
        }
        float target = base * rate;
        g_ch_set_frequency(chs[i], target);
    }
}

#pragma mark - Time Warp (fishhook 谱面同步变速)

// 让游戏内部的 Clock::currentTimeMs (vtable @ 0x1013637e0) 看到的时间按 rate 加速。
// 仅 rebind Arc-mobile 主二进制 GOT 的 mach_absolute_time + gettimeofday，
// 不写任何 __TEXT 段，不影响 Firebase / 系统 framework，符合 iOS16 sideload 安全约束。
//
// 公式：t_warp(real) = t0_warp + (real - t0_real) * rate
// 切倍率瞬间：t0_real = real_now; t0_warp = warp_now（保持连续，不跳变）

typedef uint64_t (*orig_mach_abs_t)(void);
typedef int      (*orig_gettod_t)(struct timeval *tv, void *tz);
typedef int      (*orig_clock_gettime_t)(clockid_t clk, struct timespec *tp);
typedef uint64_t (*orig_clock_gettime_nsec_np_t)(clockid_t clk);
typedef int64_t  (*orig_steady_now_t)(void);
typedef uint64_t (*orig_mach_cont_t)(void);
typedef uint64_t (*orig_mach_appx_t)(void);
typedef double   (*orig_ca_cmt_t)(void);
typedef double   (*orig_cf_abs_t)(void);
typedef time_t   (*orig_time_t_fn)(time_t *);
typedef uint64_t (*orig_dispatch_time_t)(uint64_t when, int64_t delta);
typedef uint64_t (*orig_dispatch_walltime_t)(const struct timespec *when, int64_t delta);
static orig_mach_abs_t              s_orig_mach_abs = NULL;
static orig_gettod_t                s_orig_gettod   = NULL;
static orig_clock_gettime_t         s_orig_clock_gettime = NULL;
static orig_clock_gettime_nsec_np_t s_orig_clock_gettime_nsec_np = NULL;
static orig_steady_now_t            s_orig_steady_now = NULL;
static orig_mach_cont_t             s_orig_mach_cont = NULL;
static orig_mach_appx_t             s_orig_mach_appx = NULL;
static orig_mach_cont_t             s_orig_mach_cont_appx = NULL;
static orig_ca_cmt_t                s_orig_ca_cmt = NULL;
static orig_cf_abs_t                s_orig_cf_abs = NULL;
static orig_time_t_fn               s_orig_time = NULL;
static orig_dispatch_time_t         s_orig_dispatch_time = NULL;
static orig_dispatch_walltime_t     s_orig_dispatch_walltime = NULL;

static _Atomic(uint64_t) g_tw_t0_real_mach = 0;  // 切换瞬间的真实 mach
static _Atomic(uint64_t) g_tw_t0_warp_mach = 0;  // 切换瞬间的 warp mach
static _Atomic(uint64_t) g_tw_t0_real_us   = 0;  // 切换瞬间的真实 microseconds (gettimeofday)
static _Atomic(uint64_t) g_tw_t0_warp_us   = 0;  // 切换瞬间的 warp microseconds
static _Atomic(uint32_t) g_tw_rate_x1000   = 1000; // rate * 1000，整数避免原子 float 兼容性

// 冻结机制：用户暂停 + 切后台 都会增加 freeze_count，归零才解冻。
// 冻结时所有 tw_* 调用返回 frozen_*，不再随真实时间推进 → 防止 unpause/回前台时谱面飞过。
static _Atomic(int32_t)  g_tw_freeze_count = 0;
static _Atomic(uint64_t) g_tw_frozen_mach  = 0;
static _Atomic(uint64_t) g_tw_frozen_us    = 0;

// 诊断计数器：用于验证 fishhook 是否真的拦截到游戏代码路径
static _Atomic(uint64_t) g_tw_mach_calls = 0;
static _Atomic(uint64_t) g_tw_gtod_calls = 0;
static _Atomic(uint64_t) g_tw_cgt_calls  = 0;
static _Atomic(uint64_t) g_tw_cgt_nsec_calls = 0;
static _Atomic(uint64_t) g_tw_steady_now_calls = 0;
static _Atomic(uint64_t) g_tw_mach_cont_calls = 0;
static _Atomic(uint64_t) g_tw_mach_appx_calls = 0;
static _Atomic(uint64_t) g_tw_mach_cont_appx_calls = 0;
static _Atomic(uint64_t) g_tw_ca_cmt_calls = 0;
static _Atomic(uint64_t) g_tw_cf_abs_calls = 0;
static _Atomic(uint64_t) g_tw_time_calls   = 0;
static _Atomic(uint64_t) g_tw_dt_calls     = 0;
static _Atomic(uint64_t) g_tw_dwt_calls    = 0;
// vtable swizzle 调用计数（每个 wrapper 独立）
static _Atomic(uint64_t) g_tw_pu_rt_calls   = 0;  // PlatformUtils::time_realtime_ms
static _Atomic(uint64_t) g_tw_pu_mono_calls = 0;  // PlatformUtils::time_monotonic_ms
static _Atomic(uint64_t) g_tw_pi_gtod_calls = 0;  // PlatformUtilsIOS gettimeofday->ms
static _Atomic(uint64_t) g_tw_pi_mach_calls = 0;  // PlatformUtilsIOS mach_abs->ms

// 每个时钟通道独立开关：1=warp（按 rate 加速）, 0=passthrough（仅计数，返回原值）
// 默认状态：mach_abs + gettimeofday 已被验证能影响 BGM/动画 → 默认 ON
//          其余的为新增候选，默认 ON 让用户先看综合效果，找到能影响谱面的那个后再单独留它开
static _Atomic(int) g_tw_en_mach          = 1;
static _Atomic(int) g_tw_en_gtod          = 1;
static _Atomic(int) g_tw_en_cgt           = 1;
static _Atomic(int) g_tw_en_cgt_nsec      = 0; // 默认 OFF：会影响 FMOD profiler，先别碰
static _Atomic(int) g_tw_en_steady_now    = 1; // 关键：LogicChart 时基使用 steady_clock::now
static _Atomic(int) g_tw_en_mach_cont     = 1;
static _Atomic(int) g_tw_en_mach_appx     = 1;
static _Atomic(int) g_tw_en_mach_cont_appx= 1;
static _Atomic(int) g_tw_en_ca_cmt        = 1;
static _Atomic(int) g_tw_en_cf_abs        = 1;
static _Atomic(int) g_tw_en_time          = 0; // 默认 OFF：秒级 wall-time，warp 它会让 NSDate 等乱跳
static _Atomic(int) g_tw_en_dt            = 0; // 默认 OFF：dispatch_time 是相对偏移，warp 会让 GCD 延迟翻倍
static _Atomic(int) g_tw_en_dwt           = 0; // 同上
// vtable swizzle 开关：默认 OFF（arm64e PAC 风险，先要验证 binary 是 arm64 slice 才稳）
static _Atomic(int) g_tw_en_pu_rt         = 0;
static _Atomic(int) g_tw_en_pu_mono       = 0;
static _Atomic(int) g_tw_en_pi_gtod       = 0;
static _Atomic(int) g_tw_en_pi_mach       = 0;

// mach_timebase: 用于把 CACurrentMediaTime (秒) 转 mach 滴答以共享 _compute_warp_mach 锚
static mach_timebase_info_data_t s_tb_info = {0, 0};
static inline void ensure_timebase(void) {
    if (s_tb_info.denom == 0) mach_timebase_info(&s_tb_info);
}

static inline double tw_get_rate(void) {
    return (double)atomic_load(&g_tw_rate_x1000) / 1000.0;
}

// 仅根据 t0_*/rate 算 warp 时间（不考虑冻结，给 freeze 自己用）
static uint64_t _compute_warp_mach(uint64_t real_mach) {
    double rate = tw_get_rate();
    uint64_t t0r = atomic_load(&g_tw_t0_real_mach);
    uint64_t t0w = atomic_load(&g_tw_t0_warp_mach);
    if (t0r == 0 || (rate >= 0.999 && rate <= 1.001)) return real_mach;
    if (real_mach <= t0r) return t0w;
    return t0w + (uint64_t)((double)(real_mach - t0r) * rate);
}
static uint64_t _compute_warp_us(uint64_t real_us) {
    double rate = tw_get_rate();
    uint64_t t0r = atomic_load(&g_tw_t0_real_us);
    uint64_t t0w = atomic_load(&g_tw_t0_warp_us);
    if (t0r == 0 || (rate >= 0.999 && rate <= 1.001)) return real_us;
    if (real_us <= t0r) return t0w;
    return t0w + (uint64_t)((double)(real_us - t0r) * rate);
}

static uint64_t tw_mach_absolute_time(void) {
    uint64_t real = s_orig_mach_abs ? s_orig_mach_abs() : mach_absolute_time();
    atomic_fetch_add(&g_tw_mach_calls, 1);
    if (!atomic_load(&g_tw_en_mach)) return real;
    if (atomic_load(&g_tw_freeze_count) > 0) {
        uint64_t f = atomic_load(&g_tw_frozen_mach);
        return f ? f : real;
    }
    return _compute_warp_mach(real);
}

static int tw_gettimeofday(struct timeval *tv, void *tz) {
    if (!tv) return s_orig_gettod ? s_orig_gettod(tv, tz) : gettimeofday(tv, tz);
    int r = s_orig_gettod ? s_orig_gettod(tv, tz) : gettimeofday(tv, tz);
    uint32_t cnt = atomic_fetch_add(&g_tw_gtod_calls, 1);
    // 诊断: 每 256 次记录一次 caller (return address), 帮我们识别是不是 cocos2d 在调
    if ((cnt & 0xFF) == 0) {
        void *ra = __builtin_return_address(0);
        uint64_t base = arc_image_base();
        uint64_t off = (uint64_t)ra - base;
        acc_flog(@"[diag] gtod caller ra=%p (image+0x%llx) cnt=%u", ra, (unsigned long long)off, cnt);
    }
    if (r != 0) return r;
    if (!atomic_load(&g_tw_en_gtod)) return r;
    uint64_t real_us = (uint64_t)tv->tv_sec * 1000000ULL + (uint64_t)tv->tv_usec;
    uint64_t warp_us;
    if (atomic_load(&g_tw_freeze_count) > 0) {
        uint64_t f = atomic_load(&g_tw_frozen_us);
        warp_us = f ? f : real_us;
    } else {
        warp_us = _compute_warp_us(real_us);
    }
    if (warp_us == real_us) return r; // 1.0x 直通
    tv->tv_sec  = (time_t)(warp_us / 1000000ULL);
    tv->tv_usec = (suseconds_t)(warp_us % 1000000ULL);
    return r;
}

// clock_gettime(CLOCK_MONOTONIC/UPTIME) → 纳秒级 timespec，cocos2d-x 新版可能用这个
static int tw_clock_gettime(clockid_t clk, struct timespec *tp) {
    int r = s_orig_clock_gettime ? s_orig_clock_gettime(clk, tp) : clock_gettime(clk, tp);
    atomic_fetch_add(&g_tw_cgt_calls, 1);
    if (r != 0 || !tp) return r;
    if (!atomic_load(&g_tw_en_cgt)) return r;
    // 只 warp 单调时钟（CLOCK_MONOTONIC=6, CLOCK_UPTIME_RAW=8）；CLOCK_REALTIME(0) 不动
    if (clk != 6 && clk != 8 && clk != 4) return r;
    uint64_t real_ns = (uint64_t)tp->tv_sec * 1000000000ULL + (uint64_t)tp->tv_nsec;
    uint64_t real_us = real_ns / 1000ULL;
    uint64_t warp_us;
    if (atomic_load(&g_tw_freeze_count) > 0) {
        uint64_t f = atomic_load(&g_tw_frozen_us);
        warp_us = f ? f : real_us;
    } else {
        warp_us = _compute_warp_us(real_us);
    }
    if (warp_us == real_us) return r;
    uint64_t warp_ns = warp_us * 1000ULL + (real_ns % 1000ULL);
    tp->tv_sec  = (time_t)(warp_ns / 1000000000ULL);
    tp->tv_nsec = (long)(warp_ns % 1000000000ULL);
    return r;
}

// clock_gettime_nsec_np → 直接返回纳秒，FMOD profiler 用，默认不 warp
static uint64_t tw_clock_gettime_nsec_np(clockid_t clk) {
    uint64_t real_ns = s_orig_clock_gettime_nsec_np ? s_orig_clock_gettime_nsec_np(clk) : 0;
    atomic_fetch_add(&g_tw_cgt_nsec_calls, 1);
    if (real_ns == 0) return real_ns;
    if (!atomic_load(&g_tw_en_cgt_nsec)) return real_ns;
    if (clk != 8 && clk != 6 && clk != 4) return real_ns;
    uint64_t real_us = real_ns / 1000ULL;
    uint64_t warp_us;
    if (atomic_load(&g_tw_freeze_count) > 0) {
        uint64_t f = atomic_load(&g_tw_frozen_us);
        warp_us = f ? f : real_us;
    } else {
        warp_us = _compute_warp_us(real_us);
    }
    if (warp_us == real_us) return real_ns;
    return warp_us * 1000ULL + (real_ns % 1000ULL);
}

// std::chrono::steady_clock::now(): 返回 steady ns。
// Arcaea 的 LogicClock 更新链会调用该符号（A5D2D0 -> steady_clock::now / 1e6）。
static int64_t tw_steady_clock_now(void) {
    int64_t real_ns_s = s_orig_steady_now ? s_orig_steady_now() : 0;
    atomic_fetch_add(&g_tw_steady_now_calls, 1);
    if (real_ns_s <= 0) return real_ns_s;
    if (!atomic_load(&g_tw_en_steady_now)) return real_ns_s;

    uint64_t real_ns = (uint64_t)real_ns_s;
    uint64_t real_us = real_ns / 1000ULL;
    uint64_t warp_us;
    if (atomic_load(&g_tw_freeze_count) > 0) {
        uint64_t f = atomic_load(&g_tw_frozen_us);
        warp_us = f ? f : real_us;
    } else {
        warp_us = _compute_warp_us(real_us);
    }
    if (warp_us == real_us) return real_ns_s;
    return (int64_t)(warp_us * 1000ULL + (real_ns % 1000ULL));
}

// mach_continuous_time: 含睡眠的单调时钟。音游可能用它当主时钟。
static uint64_t tw_mach_continuous_time(void) {
    uint64_t real = s_orig_mach_cont ? s_orig_mach_cont() : 0;
    atomic_fetch_add(&g_tw_mach_cont_calls, 1);
    if (!atomic_load(&g_tw_en_mach_cont)) return real;
    if (atomic_load(&g_tw_freeze_count) > 0) {
        uint64_t f = atomic_load(&g_tw_frozen_mach);
        return f ? f : real;
    }
    return _compute_warp_mach(real); // 共用 mach 锚（前台时与 mach_absolute_time 几乎相等）
}

// mach_approximate_time: mach_absolute_time 的低分辨率快速版（约 1ms 精度）
static uint64_t tw_mach_approximate_time(void) {
    uint64_t real = s_orig_mach_appx ? s_orig_mach_appx() : 0;
    atomic_fetch_add(&g_tw_mach_appx_calls, 1);
    if (!atomic_load(&g_tw_en_mach_appx)) return real;
    if (atomic_load(&g_tw_freeze_count) > 0) {
        uint64_t f = atomic_load(&g_tw_frozen_mach);
        return f ? f : real;
    }
    return _compute_warp_mach(real);
}

static uint64_t tw_mach_continuous_approximate_time(void) {
    uint64_t real = s_orig_mach_cont_appx ? s_orig_mach_cont_appx() : 0;
    atomic_fetch_add(&g_tw_mach_cont_appx_calls, 1);
    if (!atomic_load(&g_tw_en_mach_cont_appx)) return real;
    if (atomic_load(&g_tw_freeze_count) > 0) {
        uint64_t f = atomic_load(&g_tw_frozen_mach);
        return f ? f : real;
    }
    return _compute_warp_mach(real);
}

// CACurrentMediaTime: QuartzCore 的 mach_absolute_time 包装，返回秒（double）
// 与 mach_absolute_time 共享 mach 锚 → toggle 切换瞬间无跳变（两者锚同步推进）
static double tw_CACurrentMediaTime(void) {
    if (!s_orig_ca_cmt) return 0.0;
    double real = s_orig_ca_cmt();
    atomic_fetch_add(&g_tw_ca_cmt_calls, 1);
    if (!atomic_load(&g_tw_en_ca_cmt)) return real;
    ensure_timebase();
    if (s_tb_info.denom == 0) return real;
    uint64_t real_ns   = (uint64_t)(real * 1e9);
    uint64_t real_mach = real_ns * (uint64_t)s_tb_info.denom / (uint64_t)s_tb_info.numer;
    uint64_t warp_mach;
    if (atomic_load(&g_tw_freeze_count) > 0) {
        uint64_t f = atomic_load(&g_tw_frozen_mach);
        warp_mach = f ? f : real_mach;
    } else {
        warp_mach = _compute_warp_mach(real_mach);
    }
    if (warp_mach == real_mach) return real;
    uint64_t warp_ns = warp_mach * (uint64_t)s_tb_info.numer / (uint64_t)s_tb_info.denom;
    return (double)warp_ns / 1e9;
}

// CFAbsoluteTimeGetCurrent: CoreFoundation 的 wall-time 秒数（自 2001-01-01）
// 与 gettimeofday 共享 us 锚
static double tw_CFAbsoluteTimeGetCurrent(void) {
    if (!s_orig_cf_abs) return 0.0;
    double real = s_orig_cf_abs();
    atomic_fetch_add(&g_tw_cf_abs_calls, 1);
    if (!atomic_load(&g_tw_en_cf_abs)) return real;
    // CFAbsoluteTime 是 double 秒，转 us 共用锚
    uint64_t real_us = (uint64_t)(real * 1e6);
    uint64_t warp_us;
    if (atomic_load(&g_tw_freeze_count) > 0) {
        uint64_t f = atomic_load(&g_tw_frozen_us);
        warp_us = f ? f : real_us;
    } else {
        warp_us = _compute_warp_us(real_us);
    }
    if (warp_us == real_us) return real;
    return (double)warp_us / 1e6;
}

// time(time_t *): 返回秒级 wall-time，用 us 锚换算
static time_t tw_time(time_t *out) {
    time_t real = s_orig_time ? s_orig_time(NULL) : time(NULL);
    atomic_fetch_add(&g_tw_time_calls, 1);
    if (!atomic_load(&g_tw_en_time)) {
        if (out) *out = real;
        return real;
    }
    uint64_t real_us = (uint64_t)real * 1000000ULL;
    uint64_t warp_us;
    if (atomic_load(&g_tw_freeze_count) > 0) {
        uint64_t f = atomic_load(&g_tw_frozen_us);
        warp_us = f ? f : real_us;
    } else {
        warp_us = _compute_warp_us(real_us);
    }
    time_t warp = (time_t)(warp_us / 1000000ULL);
    if (out) *out = warp;
    return warp;
}

// dispatch_time(when, delta): when=DISPATCH_TIME_NOW(0) 时 delta 是 ns 偏移
// warp 它会让 GCD 调度时延按 rate 缩放（dispatch_after 等会变快）
static uint64_t tw_dispatch_time(uint64_t when, int64_t delta) {
    atomic_fetch_add(&g_tw_dt_calls, 1);
    if (!atomic_load(&g_tw_en_dt) || delta == 0) {
        return s_orig_dispatch_time ? s_orig_dispatch_time(when, delta) : 0;
    }
    double rate = tw_get_rate();
    if (rate >= 0.999 && rate <= 1.001) {
        return s_orig_dispatch_time ? s_orig_dispatch_time(when, delta) : 0;
    }
    int64_t scaled = (int64_t)((double)delta / rate);
    return s_orig_dispatch_time ? s_orig_dispatch_time(when, scaled) : 0;
}

static uint64_t tw_dispatch_walltime(const struct timespec *when, int64_t delta) {
    atomic_fetch_add(&g_tw_dwt_calls, 1);
    if (!atomic_load(&g_tw_en_dwt)) {
        return s_orig_dispatch_walltime ? s_orig_dispatch_walltime(when, delta) : 0;
    }
    double rate = tw_get_rate();
    if (rate >= 0.999 && rate <= 1.001) {
        return s_orig_dispatch_walltime ? s_orig_dispatch_walltime(when, delta) : 0;
    }
    int64_t scaled = (int64_t)((double)delta / rate);
    return s_orig_dispatch_walltime ? s_orig_dispatch_walltime(when, scaled) : 0;
}

#pragma mark - vtable swizzle (PlatformUtils / PlatformUtilsIOS)
//
// IDA 6.13.10 已知:
//   PlatformUtils    vtable @ base + 0x33E000
//     slot1 = sub_1009E0FA0  realtime  -> ms (uint64_t)
//     slot2 = sub_1009E0FE8  monotonic -> ms (uint64_t)
//   PlatformUtilsIOS vtable @ base + 0x3637F0
//     slot0 = sub_100AE9A94  gettimeofday -> ms (uint64_t)
//     slot1 = sub_100AE9AE4  mach_abs     -> ms (uint64_t)
//
// Strategy: 在 vtable 周围 ±64 slots 范围内扫描,匹配原 fn 地址 (PAC strip 后)
// 找到则 mprotect RW + 写 wrapper ptr (arm64e PAC vtable 风险:写 unsigned ptr 调用
// 时会 BLRAA 失败崩溃; 默认开关 OFF, 由用户主动启用试错)。
//
// 若 PlatformUtils* 实例其实是堆对象, vtable 还是常驻 image __DATA_CONST,
// 所有实例共享 → 一次性替换全局生效。

#define ARC_OFF_PU_VTABLE   (0x133E000ULL)
#define ARC_OFF_PI_VTABLE   (0x13637F0ULL)
#define ARC_OFF_PU_RT_FN    (0x9E0FA0ULL)
#define ARC_OFF_PU_MONO_FN  (0x9E0FE8ULL)
#define ARC_OFF_PI_GTOD_FN  (0xAE9A94ULL)
#define ARC_OFF_PI_MACH_FN  (0xAE9AE4ULL)
// MultiTrackPlayer vtable @ 0x101312860 (devlog confirmed); slot 7 = getPositionMs (sub_100846950)
// 这是"chart 是否读 audio 位置"的最直接探针：每帧若被调说明 chart 跟 audio 同步
#define ARC_OFF_MTP_VTABLE  (0x1312860ULL)
#define ARC_OFF_MTP_GETPOS  (0x846950ULL)
// CCDirector singleton vtable slots called by CCDirectorCaller.doCaller
// slot +0x38 = sub_100CE197C (main tick), slot +0x40 = sub_100CE1A5C (active flag path)
#define ARC_OFF_CC_TICK_FN   (0xCE197CULL)
#define ARC_OFF_CC_ACTIVE_FN (0xCE1A5CULL)
#define ARC_OFF_GP_VTABLE    (0x136E1C0ULL)
#define ARC_OFF_GP_UPDATE_FN (0xB3AD70ULL)

typedef uint64_t (*orig_pu_ms_fn)(void *self);
// MTP::getPositionMs(this, channel) -> uint32_t (实际是 unsigned int 返回值)
typedef uint32_t (*orig_mtp_getpos_fn)(void *self, int channel);
typedef void *(*orig_cc_tick_fn)(void *self);
typedef int64_t (*orig_cc_active_fn)(void *self, uint8_t active);
typedef int64_t (*orig_gp_update_fn)(void *self, uint64_t a2, uint64_t a3, uint64_t a4, uint64_t a5);

// 前向声明 (tw_mtp_getpos 在 _warp_ms_via_us 之前用到)
static uint64_t _warp_ms_via_us(uint64_t raw_ms);

// 保存的原始 fn ptr (PAC 已 strip,可直接调用)
static orig_pu_ms_fn s_orig_pu_rt   = NULL;
static orig_pu_ms_fn s_orig_pu_mono = NULL;
static orig_pu_ms_fn s_orig_pi_gtod = NULL;
static orig_pu_ms_fn s_orig_pi_mach = NULL;
static orig_mtp_getpos_fn s_orig_mtp_getpos = NULL;
static ch_get_position_fn s_orig_ch_getpos_vt = NULL;
static orig_cc_tick_fn s_orig_cc_tick = NULL;
static orig_cc_active_fn s_orig_cc_active = NULL;
static orig_gp_update_fn s_orig_gp_update = NULL;
static _Atomic(uint64_t) g_tw_mtp_getpos_calls = 0;
static _Atomic(uint64_t) g_tw_ch_getpos_vt_calls = 0;
static _Atomic(uint64_t) g_tw_cc_tick_calls = 0;
static _Atomic(uint64_t) g_tw_cc_active_calls = 0;
static _Atomic(uint64_t) g_tw_gp_update_calls = 0;
static _Atomic(int) g_tw_en_mtp_getpos = 0;  // 默认 OFF：开了会让 chart 跟 audio 走 (但 audio 已 setFreq 同步，开这个会双倍 warp，慎用)
static _Atomic(int) g_tw_en_ch_getpos_vt = 0;
static _Atomic(int) g_tw_ch_getpos_vt_installed = 0;
static _Atomic(int) g_tw_en_cc_tick = 0;
static _Atomic(int) g_tw_en_cc_active = 0;
static _Atomic(int) g_tw_en_gp_update = 1;
static _Atomic(int) g_tw_cc_tick_installed = 0;
static _Atomic(int) g_tw_cc_active_installed = 0;
static _Atomic(int) g_tw_gp_update_installed = 0;
static void *s_gp_last_clock = NULL;
static uint64_t s_gp_last_real_us = 0;
// MTP getPos 自动捕获 player 同时记录 caller — 帮我们识别"谁在每帧读音频位置"
static uint32_t tw_mtp_getpos(void *self, int channel) {
    uint32_t raw = s_orig_mtp_getpos ? s_orig_mtp_getpos(self, channel) : 0;
    uint64_t cnt = atomic_fetch_add(&g_tw_mtp_getpos_calls, 1);
    if (channel == 0) {
        atomic_store(&g_bgmPlayer, self);
        atomic_store(&g_last_pos_ms, raw);
        if (raw > atomic_load(&g_max_seen_ms)) atomic_store(&g_max_seen_ms, raw);
    }
    if ((cnt & 0xFF) == 0) {
        void *ra = __builtin_return_address(0);
        uint64_t base = arc_image_base();
        uint64_t off = (uint64_t)ra - base;
        acc_flog(@"[diag] mtp.getPos caller ra=%p (image+0x%llx) ch=%d raw=%u cnt=%llu",
                 ra, (unsigned long long)off, channel, raw, (unsigned long long)cnt);
    }
    if (!atomic_load(&g_tw_en_mtp_getpos)) return raw;
    // 开关启用时:把 raw_ms 当 "real us / 1000" 走 warp 锚
    return (uint32_t)_warp_ms_via_us((uint64_t)raw);
}

// Channel::getPosition(channel, out_ms, unit) 的 vtable 包装。
// 这是 MTP.getPositionMs 最终落点，命中它意味着我们确实拦到了音频位置读取。
static int tw_ch_getpos_vt(void *channel, uint32_t *out_ms, int unit) {
    int ret = s_orig_ch_getpos_vt ? s_orig_ch_getpos_vt(channel, out_ms, unit) : 0;
    uint64_t cnt = atomic_fetch_add(&g_tw_ch_getpos_vt_calls, 1);
    if ((cnt & 0xFF) == 0) {
        void *ra = __builtin_return_address(0);
        uint64_t base = arc_image_base();
        uint64_t off = (uint64_t)ra - base;
        acc_flog(@"[diag] ch.getPos caller ra=%p (image+0x%llx) unit=%d ret=%d ms=%u cnt=%llu",
                 ra, (unsigned long long)off, unit, ret,
                 out_ms ? *out_ms : 0,
                 (unsigned long long)cnt);
    }
    if (ret != 0 || !out_ms || !atomic_load(&g_tw_en_ch_getpos_vt)) return ret;
    // getPositionMs 传 unit=1，out_ms 是毫秒；只对毫秒路径做 warp。
    if (unit & 1) {
        *out_ms = (uint32_t)_warp_ms_via_us((uint64_t)(*out_ms));
    }
    return ret;
}

static uint64_t _real_now_us_unwarped(void) {
    struct timeval tv = {0};
    if (s_orig_gettod) {
        if (s_orig_gettod(&tv, NULL) == 0) return (uint64_t)tv.tv_sec * 1000000ULL + (uint64_t)tv.tv_usec;
        return 0;
    }
    if (gettimeofday(&tv, NULL) == 0) return (uint64_t)tv.tv_sec * 1000000ULL + (uint64_t)tv.tv_usec;
    return 0;
}

// 逻辑链预调：通过移动 LogicClock.start_ms，让本帧逻辑时钟增量近似按 rate 缩放。
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
    if (rate >= 0.999 && rate <= 1.001) return;
    int32_t adjust = (int32_t)(((1.0 - rate) * (double)delta_ms));
    if (adjust == 0) return;

    int32_t *start_ms = (int32_t *)((char *)clk + 16);
    int64_t after = (int64_t)(*start_ms) + (int64_t)adjust;
    if (after > INT_MAX) after = INT_MAX;
    if (after < INT_MIN) after = INT_MIN;
    *start_ms = (int32_t)after;
}

// 通过调整 CCDirector 单例里的 last timeval，让 sub_100CE0518 本帧算出的 delta 变为 delta*rate。
static void _ccdirector_retime_prev_tv(void *self) {
    if (!self) return;
    struct timeval *prev = *(struct timeval **)((char *)self + 368);
    if (!prev) return;
    uint64_t now_us = _real_now_us_unwarped();
    if (!now_us) return;
    if (atomic_load(&g_tw_freeze_count) > 0) {
        prev->tv_sec = (time_t)(now_us / 1000000ULL);
        prev->tv_usec = (suseconds_t)(now_us % 1000000ULL);
        return;
    }
    double rate = tw_get_rate();
    if (rate >= 0.999 && rate <= 1.001) return;
    uint64_t prev_us = (uint64_t)prev->tv_sec * 1000000ULL + (uint64_t)prev->tv_usec;
    if (!prev_us || now_us <= prev_us) {
        prev->tv_sec = (time_t)(now_us / 1000000ULL);
        prev->tv_usec = (suseconds_t)(now_us % 1000000ULL);
        return;
    }
    uint64_t delta = now_us - prev_us;
    if (delta > 200000ULL) delta = 200000ULL;
    uint64_t scaled = (uint64_t)((double)delta * rate);
    if (scaled > 500000ULL) scaled = 500000ULL;
    uint64_t warped_prev = (now_us > scaled) ? (now_us - scaled) : 0;
    prev->tv_sec = (time_t)(warped_prev / 1000000ULL);
    prev->tv_usec = (suseconds_t)(warped_prev % 1000000ULL);
}

static void *tw_cc_tick(void *self) {
    uint64_t cnt = atomic_fetch_add(&g_tw_cc_tick_calls, 1);
    if (atomic_load(&g_tw_en_cc_tick)) {
        _ccdirector_retime_prev_tv(self);
    }
    void *ret = s_orig_cc_tick ? s_orig_cc_tick(self) : self;
    if ((cnt & 0xFF) == 0) {
        void *ra = __builtin_return_address(0);
        uint64_t base = arc_image_base();
        uint64_t off = (uint64_t)ra - base;
        float dt = self ? *(float *)((char *)self + 232) : 0.0f;
        acc_flog(@"[diag] cc.tick caller ra=%p (image+0x%llx) dt=%.6f cnt=%llu",
                 ra, (unsigned long long)off, dt, (unsigned long long)cnt);
    }
    return ret;
}

static int64_t tw_cc_active(void *self, uint8_t active) {
    uint64_t cnt = atomic_fetch_add(&g_tw_cc_active_calls, 1);
    if (atomic_load(&g_tw_en_cc_active) && active) {
        _ccdirector_retime_prev_tv(self);
    }
    if ((cnt & 0xFF) == 0) {
        void *ra = __builtin_return_address(0);
        uint64_t base = arc_image_base();
        uint64_t off = (uint64_t)ra - base;
        acc_flog(@"[diag] cc.active caller ra=%p (image+0x%llx) active=%d cnt=%llu",
                 ra, (unsigned long long)off, (int)active, (unsigned long long)cnt);
    }
    return s_orig_cc_active ? s_orig_cc_active(self, active) : 0;
}

static int64_t tw_gp_update(void *self, uint64_t a2, uint64_t a3, uint64_t a4, uint64_t a5) {
    uint64_t cnt = atomic_fetch_add(&g_tw_gp_update_calls, 1);
    if (atomic_load(&g_tw_en_gp_update) && self) {
        void *logic = NULL;
        if (addr_readable((char *)self + 936, sizeof(void *))) {
            logic = *(void **)((char *)self + 928);
        }
        if (logic && ptr_plausible(logic)) {
            _gp_retime_logic_clock(logic);
        }
    }
    if ((cnt & 0xFF) == 0) {
        void *ra = __builtin_return_address(0);
        uint64_t base = arc_image_base();
        uint64_t off = (uint64_t)ra - base;
        acc_flog(@"[diag] gp.update caller ra=%p (image+0x%llx) rate=%.3f cnt=%llu",
                 ra, (unsigned long long)off, tw_get_rate(), (unsigned long long)cnt);
    }
    return s_orig_gp_update ? s_orig_gp_update(self, a2, a3, a4, a5) : 0;
}

// 各 wrapper:先调原函数拿 raw_ms,然后按 us 锚 warp 后返回 (PlatformUtils 都返回 ms)
static uint64_t _warp_ms_via_us(uint64_t raw_ms) {
    if (atomic_load(&g_tw_freeze_count) > 0) {
        uint64_t f = atomic_load(&g_tw_frozen_us);
        return f ? (f / 1000ULL) : raw_ms;
    }
    uint64_t real_us = raw_ms * 1000ULL;
    uint64_t warp_us = _compute_warp_us(real_us);
    return warp_us / 1000ULL;
}

static uint64_t tw_pu_realtime_ms(void *self) {
    uint64_t raw = s_orig_pu_rt ? s_orig_pu_rt(self) : 0;
    atomic_fetch_add(&g_tw_pu_rt_calls, 1);
    if (!atomic_load(&g_tw_en_pu_rt)) return raw;
    return _warp_ms_via_us(raw);
}
static uint64_t tw_pu_monotonic_ms(void *self) {
    uint64_t raw = s_orig_pu_mono ? s_orig_pu_mono(self) : 0;
    atomic_fetch_add(&g_tw_pu_mono_calls, 1);
    if (!atomic_load(&g_tw_en_pu_mono)) return raw;
    return _warp_ms_via_us(raw);
}
static uint64_t tw_pi_gtod_ms(void *self) {
    uint64_t raw = s_orig_pi_gtod ? s_orig_pi_gtod(self) : 0;
    atomic_fetch_add(&g_tw_pi_gtod_calls, 1);
    if (!atomic_load(&g_tw_en_pi_gtod)) return raw;
    return _warp_ms_via_us(raw);
}
static uint64_t tw_pi_mach_ms(void *self) {
    uint64_t raw = s_orig_pi_mach ? s_orig_pi_mach(self) : 0;
    atomic_fetch_add(&g_tw_pi_mach_calls, 1);
    if (!atomic_load(&g_tw_en_pi_mach)) return raw;
    return _warp_ms_via_us(raw);
}

// 在 vtable 区域 ±64 slots 范围内扫描,找到匹配 orig_fn 的 slot 并替换为 new_fn。
// 返回找到的 slot index (相对 vtable 起始,可能负数),失败返回 INT_MIN。
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
        // PAC strip (arm64e instruction key A);arm64 上是 noop
#if __has_feature(ptrauth_calls)
        void *stripped = ptrauth_strip(cur, ptrauth_key_asia);
#else
        void *stripped = cur;
#endif
        if ((uint64_t)stripped != target) continue;
        // 找到了。mprotect 整 16K 页 RW (iOS 16 __DATA_CONST 可能 deny → 退化 vm_protect+COPY)
        uintptr_t page = (uintptr_t)&vt[i] & ~(uintptr_t)0x3FFF;
        bool wrote = false;
        if (mprotect((void *)page, 0x4000, PROT_READ | PROT_WRITE) == 0) {
            wrote = true;
        } else {
            int e1 = errno;
            // 备用:vm_protect with VM_PROT_COPY (fishhook 同款)
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
        if (out_orig) *out_orig = stripped;  // 裸地址,可直接调用
#if __has_feature(ptrauth_calls)
        // arm64e: 用相同 slot 地址作为 discriminator blend 重新签名
        // 注意:C++ vtable 真实 discriminator 在编译期 hash 决定,这里只是尽力而为
        void *signed_new = ptrauth_sign_unauthenticated(new_fn,
                              ptrauth_key_asia,
                              ptrauth_blend_discriminator(&vt[i], 0));
        vt[i] = signed_new;
#else
        vt[i] = new_fn;
#endif
        // 不能 PROT_EXEC, __DATA_CONST 不允许; 恢复 RO (尽力而为,失败也无所谓)
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
        swizzle_vtable_find_swap(base + ARC_OFF_PU_VTABLE, ARC_OFF_PU_RT_FN,
                                 (void *)tw_pu_realtime_ms,  (void **)&s_orig_pu_rt);
        swizzle_vtable_find_swap(base + ARC_OFF_PU_VTABLE, ARC_OFF_PU_MONO_FN,
                                 (void *)tw_pu_monotonic_ms, (void **)&s_orig_pu_mono);
        swizzle_vtable_find_swap(base + ARC_OFF_PI_VTABLE, ARC_OFF_PI_GTOD_FN,
                                 (void *)tw_pi_gtod_ms,      (void **)&s_orig_pi_gtod);
        swizzle_vtable_find_swap(base + ARC_OFF_PI_VTABLE, ARC_OFF_PI_MACH_FN,
                                 (void *)tw_pi_mach_ms,      (void **)&s_orig_pi_mach);
        // MTP::getPositionMs — 默认装上 hook (即使开关 OFF, 也能走计数 + caller 诊断)
        swizzle_vtable_find_swap(base + ARC_OFF_MTP_VTABLE, ARC_OFF_MTP_GETPOS,
                                 (void *)tw_mtp_getpos,      (void **)&s_orig_mtp_getpos);
        int gp_slot = swizzle_vtable_find_swap(base + ARC_OFF_GP_VTABLE, ARC_OFF_GP_UPDATE_FN,
                                               (void *)tw_gp_update,     (void **)&s_orig_gp_update);
        if (gp_slot != INT_MIN && s_orig_gp_update) {
            atomic_store(&g_tw_gp_update_installed, 1);
            acc_flog(@"gp.update vtable installed vt=%p slot=%d orig=%p",
                     (void *)(base + ARC_OFF_GP_VTABLE), gp_slot, (void *)s_orig_gp_update);
        }
    });
}

// 运行时从真实 channel 实例读取 vtable 并替换 Channel::getPosition。
// 不能用静态偏移，因为具体 vtable 地址可能受构建/链接布局影响。
static void try_install_channel_vtable_swizzle(void) {
    if (atomic_load(&g_tw_ch_getpos_vt_installed)) return;
    void *chs[ARC_MAX_CHANNELS] = {0};
    int n = player_collect_channels(chs, ARC_MAX_CHANNELS);
    if (n <= 0) return;
    for (int i = 0; i < n; i++) {
        void *ch = chs[i];
        if (!ch || !ptr_plausible(ch) || !addr_readable(ch, sizeof(void *))) continue;
        void **vt = *(void ***)ch;
        if (!vt || !ptr_plausible(vt)) continue;
        int slot = swizzle_vtable_find_swap((uint64_t)vt, ARC_OFF_CH_GET_POSITION,
                                            (void *)tw_ch_getpos_vt,
                                            (void **)&s_orig_ch_getpos_vt);
        if (slot != INT_MIN && s_orig_ch_getpos_vt) {
            atomic_store(&g_tw_ch_getpos_vt_installed, 1);
            acc_flog(@"channel vtable swizzle installed on ch[%d]=%p vt=%p slot=%d orig=%p",
                     i, ch, vt, slot, (void *)s_orig_ch_getpos_vt);
            return;
        }
    }
}

static void try_install_ccdirector_vtable_swizzle(void) {
    if (!g_get_cc_singleton) return;
    void *cc = g_get_cc_singleton();
    if (!cc) return;
    void **vt = *(void ***)cc;
    if (!vt) return;
    if (!atomic_load(&g_tw_cc_tick_installed)) {
        int slot = swizzle_vtable_find_swap((uint64_t)vt, ARC_OFF_CC_TICK_FN,
                                            (void *)tw_cc_tick, (void **)&s_orig_cc_tick);
        if (slot != INT_MIN && s_orig_cc_tick) {
            atomic_store(&g_tw_cc_tick_installed, 1);
            acc_flog(@"ccdirector vtable tick installed cc=%p vt=%p slot=%d orig=%p",
                     cc, vt, slot, (void *)s_orig_cc_tick);
        }
    }
    if (!atomic_load(&g_tw_cc_active_installed)) {
        int slot = swizzle_vtable_find_swap((uint64_t)vt, ARC_OFF_CC_ACTIVE_FN,
                                            (void *)tw_cc_active, (void **)&s_orig_cc_active);
        if (slot != INT_MIN && s_orig_cc_active) {
            atomic_store(&g_tw_cc_active_installed, 1);
            acc_flog(@"ccdirector vtable active installed cc=%p vt=%p slot=%d orig=%p",
                     cc, vt, slot, (void *)s_orig_cc_active);
        }
    }
}

// 自检:直接调原函数 (我们保存的 stripped ptr) + 调 vtable 上现在挂着的 wrapper,
// 输出对比看 vtable swizzle 是否真的让调用走到我们这边。
static void self_test_vtable(void) {
    uint64_t base = arc_image_base();
    acc_flog(@"=== self_test_vtable rate=%.3f freeze=%d ===",
             tw_get_rate(), atomic_load(&g_tw_freeze_count));
    void *pu_vt = (void *)(base + ARC_OFF_PU_VTABLE);
    void *pi_vt = (void *)(base + ARC_OFF_PI_VTABLE);
    acc_flog(@"  PU  rt:   orig_saved=%p  pu_rt_calls=%llu  en=%d",
             (void *)s_orig_pu_rt, atomic_load(&g_tw_pu_rt_calls),
             atomic_load(&g_tw_en_pu_rt));
    acc_flog(@"  PU  mono: orig_saved=%p  pu_mono_calls=%llu en=%d",
             (void *)s_orig_pu_mono, atomic_load(&g_tw_pu_mono_calls),
             atomic_load(&g_tw_en_pu_mono));
    acc_flog(@"  PI  gtod: orig_saved=%p  pi_gtod_calls=%llu en=%d",
             (void *)s_orig_pi_gtod, atomic_load(&g_tw_pi_gtod_calls),
             atomic_load(&g_tw_en_pi_gtod));
    acc_flog(@"  PI  mach: orig_saved=%p  pi_mach_calls=%llu en=%d",
             (void *)s_orig_pi_mach, atomic_load(&g_tw_pi_mach_calls),
             atomic_load(&g_tw_en_pi_mach));
    acc_flog(@"  CH  getPos(vt): orig_saved=%p  calls=%llu en=%d installed=%d",
             (void *)s_orig_ch_getpos_vt,
             atomic_load(&g_tw_ch_getpos_vt_calls),
             atomic_load(&g_tw_en_ch_getpos_vt),
             atomic_load(&g_tw_ch_getpos_vt_installed));
    acc_flog(@"  CC  tick(vt):  orig_saved=%p  calls=%llu en=%d installed=%d",
             (void *)s_orig_cc_tick,
             atomic_load(&g_tw_cc_tick_calls),
             atomic_load(&g_tw_en_cc_tick),
             atomic_load(&g_tw_cc_tick_installed));
    acc_flog(@"  CC  active(vt):orig_saved=%p  calls=%llu en=%d installed=%d",
             (void *)s_orig_cc_active,
             atomic_load(&g_tw_cc_active_calls),
             atomic_load(&g_tw_en_cc_active),
             atomic_load(&g_tw_cc_active_installed));
    // 直接读 vtable 当前内容,对比是否被替换
    void **pu = (void **)pu_vt;
    void **pi = (void **)pi_vt;
    acc_flog(@"  PU vtable[-2..3]: %p %p %p %p %p %p",
             pu[-2], pu[-1], pu[0], pu[1], pu[2], pu[3]);
    acc_flog(@"  PI vtable[-2..3]: %p %p %p %p %p %p",
             pi[-2], pi[-1], pi[0], pi[1], pi[2], pi[3]);
    // 主动调 PlatformUtils 通过原 fn 拿 raw_ms (传 self=NULL,函数应不解引用 self)
    if (s_orig_pu_mono) {
        @try {
            uint64_t raw = s_orig_pu_mono(NULL);
            acc_flog(@"  PU mono(NULL) raw_ms=%llu", raw);
        } @catch (NSException *e) {
            acc_flog(@"  PU mono(NULL) EX: %@", e);
        }
    }
}

#pragma mark - CADisplayLink ObjC swizzle (盲区补充)
//
// fishhook 拦不到 QuartzCore.framework 内部用 commpage 拿 host time。
// 但 CADisplayLink 把这个 host time 通过 -[CADisplayLink timestamp] / -targetTimestamp / -duration
// 暴露给业务代码 (NSNumber double, 单位秒)。
// → swizzle 这三个 ObjC accessor, 让 *任何* caller (包括 QuartzCore 自己 selector dispatch
//   到业务回调里) 拿到的都是 warp 时间, 等价于在调度链路最末端做注入。
//
// 注意:
// 1. 这只影响"读 displayLink.timestamp 的代码", 不影响 displayLink 自己的 firing rate。
// 2. 计数器分别为 dl_ts / dl_target / dl_dur, 默认全 OFF。
// 3. CADisplayLink.timestamp 是 CFTimeInterval (= double 秒)。我们按 _compute_warp_us 锚算。

static _Atomic(uint64_t) g_tw_dl_ts_calls     = 0;
static _Atomic(uint64_t) g_tw_dl_target_calls = 0;
static _Atomic(uint64_t) g_tw_dl_dur_calls    = 0;
static _Atomic(int) g_tw_en_dl_ts     = 0;
static _Atomic(int) g_tw_en_dl_target = 0;
static _Atomic(int) g_tw_en_dl_dur    = 0;

typedef CFTimeInterval (*dl_getter_imp)(id, SEL);
static dl_getter_imp s_orig_dl_ts     = NULL;
static dl_getter_imp s_orig_dl_target = NULL;
static dl_getter_imp s_orig_dl_dur    = NULL;

// 把"秒"按 us 锚 warp,返回新的"秒"
static CFTimeInterval _warp_seconds(CFTimeInterval real_sec) {
    if (real_sec <= 0.0) return real_sec;
    uint64_t real_us = (uint64_t)(real_sec * 1000000.0);
    if (atomic_load(&g_tw_freeze_count) > 0) {
        uint64_t f = atomic_load(&g_tw_frozen_us);
        if (f) return (CFTimeInterval)f / 1000000.0;
        return real_sec;
    }
    uint64_t warp_us = _compute_warp_us(real_us);
    return (CFTimeInterval)warp_us / 1000000.0;
}

static CFTimeInterval tw_dl_timestamp(id self, SEL _cmd) {
    CFTimeInterval raw = s_orig_dl_ts ? s_orig_dl_ts(self, _cmd) : 0.0;
    atomic_fetch_add(&g_tw_dl_ts_calls, 1);
    if (!atomic_load(&g_tw_en_dl_ts)) return raw;
    return _warp_seconds(raw);
}
static CFTimeInterval tw_dl_targetTimestamp(id self, SEL _cmd) {
    CFTimeInterval raw = s_orig_dl_target ? s_orig_dl_target(self, _cmd) : 0.0;
    atomic_fetch_add(&g_tw_dl_target_calls, 1);
    if (!atomic_load(&g_tw_en_dl_target)) return raw;
    return _warp_seconds(raw);
}
static CFTimeInterval tw_dl_duration(id self, SEL _cmd) {
    CFTimeInterval raw = s_orig_dl_dur ? s_orig_dl_dur(self, _cmd) : 0.0;
    atomic_fetch_add(&g_tw_dl_dur_calls, 1);
    if (!atomic_load(&g_tw_en_dl_dur)) return raw;
    // duration 是帧间隔, 不是绝对时间;按 rate 缩放
    double rate = tw_get_rate();
    if (rate >= 0.999 && rate <= 1.001) return raw;
    return raw * rate;
}

static void install_displaylink_swizzles(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        Class cls = objc_getClass("CADisplayLink");
        if (!cls) { acc_flog(@"displaylink swizzle: CADisplayLink class missing"); return; }
        struct { SEL sel; IMP new_imp; IMP *out_orig; const char *name; } items[] = {
            { @selector(timestamp),       (IMP)tw_dl_timestamp,        (IMP *)&s_orig_dl_ts,     "timestamp"       },
            { @selector(targetTimestamp), (IMP)tw_dl_targetTimestamp,  (IMP *)&s_orig_dl_target, "targetTimestamp" },
            { @selector(duration),        (IMP)tw_dl_duration,         (IMP *)&s_orig_dl_dur,    "duration"        },
        };
        for (int i = 0; i < (int)(sizeof(items)/sizeof(items[0])); i++) {
            Method m = class_getInstanceMethod(cls, items[i].sel);
            if (!m) { acc_flog(@"displaylink swizzle: %s method missing", items[i].name); continue; }
            IMP old = method_setImplementation(m, items[i].new_imp);
            *items[i].out_orig = old;
            acc_flog(@"displaylink swizzle OK: -[CADisplayLink %s] orig=%p -> new=%p",
                     items[i].name, (void *)old, (void *)items[i].new_imp);
        }
    });
}

// UI 开关对应的 hook 是否已真正装上（非空原函数/已安装标记）。
static int clock_hook_ready_for_idx(int idx) {
    switch (idx) {
        case 0:  return s_orig_mach_abs != NULL;
        case 1:  return s_orig_gettod != NULL;
        case 2:  return s_orig_clock_gettime != NULL;
        case 3:  return s_orig_clock_gettime_nsec_np != NULL;
        case 4:  return s_orig_steady_now != NULL;
        case 5:  return s_orig_mach_cont != NULL;
        case 6:  return s_orig_mach_appx != NULL;
        case 7:  return s_orig_mach_cont_appx != NULL;
        case 8:  return s_orig_ca_cmt != NULL;
        case 9:  return s_orig_cf_abs != NULL;
        case 10: return s_orig_time != NULL;
        case 11: return s_orig_dispatch_time != NULL;
        case 12: return s_orig_dispatch_walltime != NULL;
        case 13: return s_orig_pu_rt != NULL;
        case 14: return s_orig_pu_mono != NULL;
        case 15: return s_orig_pi_gtod != NULL;
        case 16: return s_orig_pi_mach != NULL;
        case 17: return s_orig_mtp_getpos != NULL;
        case 18: return atomic_load(&g_tw_gp_update_installed) && s_orig_gp_update != NULL;
        case 19: return atomic_load(&g_tw_cc_tick_installed) && s_orig_cc_tick != NULL;
        case 20: return atomic_load(&g_tw_cc_active_installed) && s_orig_cc_active != NULL;
        case 21: return atomic_load(&g_tw_ch_getpos_vt_installed) && s_orig_ch_getpos_vt != NULL;
        case 22: return s_orig_dl_ts != NULL;
        case 23: return s_orig_dl_target != NULL;
        case 24: return s_orig_dl_dur != NULL;
        default: return 0;
    }
}

// 增加冻结计数（用户暂停 / 切后台 / seek 期间皆可调用）
static void time_warp_freeze_inc(void) {
    int32_t prev = atomic_fetch_add(&g_tw_freeze_count, 1);
    if (prev == 0) {
        // 第一次冻结：capture 当前 warp 时间作为冻结值
        uint64_t real_mach = s_orig_mach_abs ? s_orig_mach_abs() : mach_absolute_time();
        struct timeval tv = {0};
        uint64_t real_us = 0;
        if (s_orig_gettod && s_orig_gettod(&tv, NULL) == 0) {
            real_us = (uint64_t)tv.tv_sec * 1000000ULL + (uint64_t)tv.tv_usec;
        } else if (gettimeofday(&tv, NULL) == 0) {
            real_us = (uint64_t)tv.tv_sec * 1000000ULL + (uint64_t)tv.tv_usec;
        }
        atomic_store(&g_tw_frozen_mach, _compute_warp_mach(real_mach));
        atomic_store(&g_tw_frozen_us,   _compute_warp_us(real_us));
    }
}

static void time_warp_freeze_dec(void) {
    int32_t prev = atomic_fetch_sub(&g_tw_freeze_count, 1);
    if (prev <= 0) {
        // 计数下溢，恢复 0
        atomic_store(&g_tw_freeze_count, 0);
        return;
    }
    if (prev == 1) {
        // 完全解冻：rebase t0_*，让 warp 时间从冻结值无缝继续
        uint64_t real_mach = s_orig_mach_abs ? s_orig_mach_abs() : mach_absolute_time();
        struct timeval tv = {0};
        uint64_t real_us = 0;
        if (s_orig_gettod && s_orig_gettod(&tv, NULL) == 0) {
            real_us = (uint64_t)tv.tv_sec * 1000000ULL + (uint64_t)tv.tv_usec;
        } else if (gettimeofday(&tv, NULL) == 0) {
            real_us = (uint64_t)tv.tv_sec * 1000000ULL + (uint64_t)tv.tv_usec;
        }
        atomic_store(&g_tw_t0_real_mach, real_mach);
        atomic_store(&g_tw_t0_warp_mach, atomic_load(&g_tw_frozen_mach) ? atomic_load(&g_tw_frozen_mach) : real_mach);
        atomic_store(&g_tw_t0_real_us,   real_us);
        atomic_store(&g_tw_t0_warp_us,   atomic_load(&g_tw_frozen_us)   ? atomic_load(&g_tw_frozen_us)   : real_us);
    }
}

// 设置新倍率：先用「当前 warp 时间」做新基准 t0_warp，再把 t0_real 设为「当前真实时间」。
// 这样 warp 时间在切换瞬间是连续的，不会跳变（避免谱面 note 突跳）。
// 注意：冻结期间也允许换 rate，但只更新 rate，frozen_* 保持不变（unpause 后按新 rate 推进）。
static void time_warp_set_rate(double rate) {
    if (rate <= 0.001) return;
    uint64_t real_mach_now = s_orig_mach_abs ? s_orig_mach_abs() : mach_absolute_time();
    struct timeval tv_now = {0};
    int gtr = s_orig_gettod ? s_orig_gettod(&tv_now, NULL) : gettimeofday(&tv_now, NULL);
    uint64_t real_us_now = 0;
    if (gtr == 0) real_us_now = (uint64_t)tv_now.tv_sec * 1000000ULL + (uint64_t)tv_now.tv_usec;

    // 先按旧 rate 算出当前 warp 时间作为新基准
    uint64_t warp_mach_now = _compute_warp_mach(real_mach_now);
    uint64_t warp_us_now   = _compute_warp_us(real_us_now);

    atomic_store(&g_tw_t0_real_mach, real_mach_now);
    atomic_store(&g_tw_t0_warp_mach, warp_mach_now);
    atomic_store(&g_tw_t0_real_us,   real_us_now);
    atomic_store(&g_tw_t0_warp_us,   warp_us_now);
    atomic_store(&g_tw_rate_x1000, (uint32_t)(rate * 1000.0 + 0.5));
}

static void time_warp_install(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        struct rebinding rs[13] = {
            { "mach_absolute_time",                (void *)tw_mach_absolute_time,                (void **)&s_orig_mach_abs },
            { "gettimeofday",                      (void *)tw_gettimeofday,                      (void **)&s_orig_gettod   },
            { "clock_gettime",                     (void *)tw_clock_gettime,                     (void **)&s_orig_clock_gettime },
            { "clock_gettime_nsec_np",             (void *)tw_clock_gettime_nsec_np,             (void **)&s_orig_clock_gettime_nsec_np },
            { "__ZNSt3__16chrono12steady_clock3nowEv", (void *)tw_steady_clock_now,              (void **)&s_orig_steady_now },
            { "mach_continuous_time",              (void *)tw_mach_continuous_time,              (void **)&s_orig_mach_cont },
            { "mach_approximate_time",             (void *)tw_mach_approximate_time,             (void **)&s_orig_mach_appx },
            { "mach_continuous_approximate_time",  (void *)tw_mach_continuous_approximate_time,  (void **)&s_orig_mach_cont_appx },
            { "CACurrentMediaTime",                (void *)tw_CACurrentMediaTime,                (void **)&s_orig_ca_cmt },
            { "CFAbsoluteTimeGetCurrent",          (void *)tw_CFAbsoluteTimeGetCurrent,          (void **)&s_orig_cf_abs },
            { "time",                              (void *)tw_time,                              (void **)&s_orig_time },
            { "dispatch_time",                     (void *)tw_dispatch_time,                     (void **)&s_orig_dispatch_time },
            { "dispatch_walltime",                 (void *)tw_dispatch_walltime,                 (void **)&s_orig_dispatch_walltime },
        };
        int r = rebind_symbols(rs, 13);
        ensure_timebase();
        acc_flog(@"fishhook ret=%d mach=%p gtod=%p cgt=%p cgt_ns=%p steady_now=%p mcont=%p mappx=%p mcappx=%p ca_cmt=%p cf_abs=%p time=%p dt=%p dwt=%p tb=%u/%u",
                 r,
                 (void *)s_orig_mach_abs, (void *)s_orig_gettod,
                 (void *)s_orig_clock_gettime, (void *)s_orig_clock_gettime_nsec_np,
                 (void *)s_orig_steady_now,
                 (void *)s_orig_mach_cont, (void *)s_orig_mach_appx,
                 (void *)s_orig_mach_cont_appx, (void *)s_orig_ca_cmt, (void *)s_orig_cf_abs,
                 (void *)s_orig_time, (void *)s_orig_dispatch_time, (void *)s_orig_dispatch_walltime,
                 s_tb_info.numer, s_tb_info.denom);
    });
}

static void player_seek_ms(uint32_t ms) {
    void *self = get_player_or_resolve();
    if (!self) return;
    typedef void (*seek_fn)(void *, uint32_t, int);
    seek_fn fn = (seek_fn)_player_vt_slot(self, 0x40); // slot 8 = seekTo(this, ms, channel)
    if (!fn) return;
    // seek 期间临时冻结 warp 时间，防止 game 在 vt[8] 内部读到 warp 时间产生中间态错位
    time_warp_freeze_inc();
    fn(self, ms, 0);
    time_warp_freeze_dec();
    // seek 后重新应用倍率（FMOD seek 可能重置 channel 频率）
    apply_speed_to_all_channels();
}

static void player_set_paused(BOOL paused) {
    void *self = get_player_or_resolve();
    if (!self) return;
    // 修正：vtable[6] = setPaused(this, paused, channel)
    typedef void (*set_paused_fn)(void *, int, int);
    set_paused_fn fn = (set_paused_fn)_player_vt_slot(self, 0x30); // slot 6
    if (!fn) return;
    if (paused) {
        // 先冻结 warp 时间，再暂停 audio：保证 game 看到的时钟与 audio 同步停止
        time_warp_freeze_inc();
        fn(self, 1, 0);
    } else {
        // 先恢复 audio，再解冻 warp：unpause 瞬间 currentMs 从冻结值平滑继续，不会跳过任何 note
        fn(self, 0, 0);
        time_warp_freeze_dec();
    }
}

static uint32_t player_get_position_ms_cached(void) {
    return atomic_load(&g_last_pos_ms);
}

// 调用者需要的最大进度值：优先 FMOD 拿到的真实总长，其次是运行中看到过的最大 ms
static uint32_t player_get_progress_max_ms(void) {
    uint32_t len = atomic_load(&g_song_length_ms);
    if (len > 0) return len;
    return atomic_load(&g_max_seen_ms);
}

#pragma mark - prefs

static NSMutableDictionary *loadPrefDict(void) {
    NSMutableDictionary *p = [[NSMutableDictionary alloc] initWithContentsOfFile:kPrefPath];
    if (!p) p = [NSMutableDictionary new];
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
    return p;
}

static void savePrefDict(NSDictionary *p) {
    NSString *dir = [kPrefPath stringByDeletingLastPathComponent];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    [p writeToFile:kPrefPath atomically:YES];
}

static void loadPref(void) {
    NSMutableDictionary *prefs = loadPrefDict();
    toast         = [prefs[@"toast"] boolValue];
    buttonEnabled = [prefs[@"buttonEnabled"] boolValue];

    NSArray *speedKeys = prefs[@"speedKeys"];
    rate_count = speedKeys.count;
    if (rates) { free(rates); rates = NULL; }
    rates = (float *)malloc(sizeof(float) * rate_count);
    NSInteger i = 0;
    for (NSString *k in speedKeys) rates[i++] = [prefs[k] floatValue];
    if (rate_i >= rate_count) rate_i = 0;

    if (button) [button setHidden:!buttonEnabled];
}

#pragma mark - UI overlay (NSBundle / UIWindow keep-on-top)

%group ui
%hook NSBundle
+ (NSBundle *)bundleForClass:(Class)aClass {
    if (aClass == [%c(WHToastView) class]) {
        // WHToast 资源被打包进 dylib 同目录的 bundle；TrollStore 场景下我们用�?bundle 兜底�?
        NSBundle *main = [NSBundle mainBundle];
        return main ?: %orig;
    }
    return %orig;
}
%end

%hook UIWindow
- (void)bringSubviewToFront:(UIView *)view {
    %orig;
    // 防递归：当外部把 button/menuView 自己置顶时，不要再递归置顶它们
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
@property (nonatomic, strong) UISwitch *pauseSwitch;
@property (nonatomic, assign) BOOL userDraggingSlider;
@property (nonatomic, assign) BOOL paused;
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
    acc_flog(@"show: keyWindow=%p windows.count=%lu", w, (unsigned long)UIApp.windows.count);
    if (!w) {
        // cocos2d-x 场景下 keyWindow 可能为 nil，手动拉一个
        for (UIWindow *win in UIApp.windows) {
            acc_flog(@"  win=%p key=%d level=%f hidden=%d", win, win.isKeyWindow, win.windowLevel, win.hidden);
            if (!win.hidden) { w = win; break; }
        }
    }
    if (!w) {
        acc_flog(@"show: NO USABLE WINDOW, abort");
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
    acc_flog(@"show: added menuView to %p, bounds=%@", w, NSStringFromCGRect(w.bounds));
    [self rebuild];
}

- (void)hide {
    [self.progressTimer invalidate];
    self.progressTimer = nil;
    self.progressSlider = nil;
    self.progressLabel = nil;
    self.pauseSwitch = nil;
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

    // 标题
    UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(12, y, innerW, 24)];
    title.text = @"AccDemo Arcaea 控制台";
    title.font = [UIFont boldSystemFontOfSize:18];
    title.textColor = [UIColor blackColor];
    [card addSubview:title];
    y += 28;

    // 重要说明：现在已通过 fishhook 实现谱面同步变速
    UILabel *warn = [[UILabel alloc] initWithFrame:CGRectMake(12, y, innerW, 32)];
    warn.text = @"音频 + 谱面 + 判定全部同步变速（fishhook time-warp）。建议先测低倍率验证手感。";
    warn.font = [UIFont systemFontOfSize:11];
    warn.textColor = [UIColor colorWithRed:0.0 green:0.5 blue:0.2 alpha:1.0];
    warn.numberOfLines = 0;
    [card addSubview:warn];
    y += 38;

    // ---- BGM player live controls (only meaningful while playing) ----
    BOOL playerReady = (get_player_or_resolve() != NULL);

    UILabel *playerHdr = [[UILabel alloc] initWithFrame:CGRectMake(12, y, innerW, 18)];
    playerHdr.text = playerReady ? @"BGM 实时控制" : @"BGM（等待歌曲加载中…）";
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

    UILabel *pauseLbl = [[UILabel alloc] initWithFrame:CGRectMake(12, y, innerW - 60, 28)];
    pauseLbl.text = @"暂停 BGM";
    pauseLbl.font = [UIFont systemFontOfSize:14];
    pauseLbl.textColor = [UIColor blackColor];
    [card addSubview:pauseLbl];
    UISwitch *pauseSw = [[UISwitch alloc] initWithFrame:CGRectZero];
    CGSize pSize = pauseSw.bounds.size;
    pauseSw.frame = CGRectMake(W - 12 - pSize.width, y, pSize.width, pSize.height);
    pauseSw.on = self.paused;
    pauseSw.enabled = playerReady;
    [pauseSw addTarget:self action:@selector(pauseChanged:) forControlEvents:UIControlEventValueChanged];
    [card addSubview:pauseSw];
    self.pauseSwitch = pauseSw;
    y += MAX(28, pSize.height) + 8;

    [self.progressTimer invalidate];
    self.progressTimer = [NSTimer scheduledTimerWithTimeInterval:0.1
                                                          target:self
                                                        selector:@selector(progressTick:)
                                                        userInfo:nil
                                                         repeats:YES];

    // toast switch
    UILabel *toastLbl = [[UILabel alloc] initWithFrame:CGRectMake(12, y, innerW - 60, 28)];
    toastLbl.text = @"切倍率时显示提示";
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

    // ---- 时钟通道开关（实验：找出谱面用哪个时钟）----
    UILabel *clkHdr = [[UILabel alloc] initWithFrame:CGRectMake(12, y, innerW, 32)];
    clkHdr.text = @"时钟通道（开=按 rate 加速；游戏内逐个切换可定位谱面用哪个）";
    clkHdr.font = [UIFont systemFontOfSize:11];
    clkHdr.textColor = [UIColor darkGrayColor];
    clkHdr.numberOfLines = 0;
    [card addSubview:clkHdr];
    y += 36;

    // 列表：name, enable_ptr, counter_ptr
    struct { const char *label; _Atomic(int) *en; _Atomic(uint64_t) *cnt; } clocks[] = {
        { "mach_absolute_time",                &g_tw_en_mach,           &g_tw_mach_calls          },
        { "gettimeofday",                      &g_tw_en_gtod,           &g_tw_gtod_calls          },
        { "clock_gettime",                     &g_tw_en_cgt,            &g_tw_cgt_calls           },
        { "clock_gettime_nsec_np",             &g_tw_en_cgt_nsec,       &g_tw_cgt_nsec_calls      },
        { "steady_clock::now",                 &g_tw_en_steady_now,     &g_tw_steady_now_calls    },
        { "mach_continuous_time",              &g_tw_en_mach_cont,      &g_tw_mach_cont_calls     },
        { "mach_approximate_time",             &g_tw_en_mach_appx,      &g_tw_mach_appx_calls     },
        { "mach_continuous_approximate_time",  &g_tw_en_mach_cont_appx, &g_tw_mach_cont_appx_calls},
        { "CACurrentMediaTime",                &g_tw_en_ca_cmt,         &g_tw_ca_cmt_calls        },
        { "CFAbsoluteTimeGetCurrent",          &g_tw_en_cf_abs,         &g_tw_cf_abs_calls        },
        { "time",                              &g_tw_en_time,           &g_tw_time_calls          },
        { "dispatch_time",                     &g_tw_en_dt,             &g_tw_dt_calls            },
        { "dispatch_walltime",                 &g_tw_en_dwt,            &g_tw_dwt_calls           },
        { "[vt]PlatformUtils.realtime_ms",     &g_tw_en_pu_rt,          &g_tw_pu_rt_calls         },
        { "[vt]PlatformUtils.monotonic_ms",    &g_tw_en_pu_mono,        &g_tw_pu_mono_calls       },
        { "[vt]PlatformUtilsIOS.gtod_ms",      &g_tw_en_pi_gtod,        &g_tw_pi_gtod_calls       },
        { "[vt]PlatformUtilsIOS.mach_ms",      &g_tw_en_pi_mach,        &g_tw_pi_mach_calls       },
        { "[vt]MTP.getPositionMs",             &g_tw_en_mtp_getpos,     &g_tw_mtp_getpos_calls    },
        { "[vt]Gameplay.update",               &g_tw_en_gp_update,      &g_tw_gp_update_calls     },
        { "[vt]CCDirector.tick",               &g_tw_en_cc_tick,        &g_tw_cc_tick_calls       },
        { "[vt]CCDirector.active",             &g_tw_en_cc_active,      &g_tw_cc_active_calls     },
        { "[vt]Channel.getPosition",           &g_tw_en_ch_getpos_vt,   &g_tw_ch_getpos_vt_calls  },
        { "[obj]CADisplayLink.timestamp",       &g_tw_en_dl_ts,          &g_tw_dl_ts_calls         },
        { "[obj]CADisplayLink.targetTimestamp", &g_tw_en_dl_target,      &g_tw_dl_target_calls     },
        { "[obj]CADisplayLink.duration",        &g_tw_en_dl_dur,         &g_tw_dl_dur_calls        },
    };
    int nClocks = (int)(sizeof(clocks) / sizeof(clocks[0]));
    for (int i = 0; i < nClocks; i++) {
        UILabel *nameLbl = [[UILabel alloc] initWithFrame:CGRectMake(12, y, innerW - 60, 20)];
        nameLbl.text = [NSString stringWithFormat:@"%s", clocks[i].label];
        nameLbl.font = [UIFont systemFontOfSize:12];
        nameLbl.textColor = [UIColor blackColor];
        [card addSubview:nameLbl];

        UILabel *cntLbl = [[UILabel alloc] initWithFrame:CGRectMake(12, y + 18, innerW - 60, 14)];
        cntLbl.text = [NSString stringWithFormat:@"%llu calls", (unsigned long long)atomic_load(clocks[i].cnt)];
        cntLbl.font = [UIFont systemFontOfSize:10];
        cntLbl.textColor = [UIColor grayColor];
        cntLbl.tag = 3000 + i; // 给 progressTick 用，后续可刷新
        [card addSubview:cntLbl];

        UISwitch *sw = [[UISwitch alloc] initWithFrame:CGRectZero];
        CGSize sz = sw.bounds.size;
        sw.frame = CGRectMake(W - 12 - sz.width, y + 4, sz.width, sz.height);
        sw.on = atomic_load(clocks[i].en) ? YES : NO;
        sw.tag = 3100 + i;
        [sw addTarget:self action:@selector(clockToggleChanged:) forControlEvents:UIControlEventValueChanged];
        [card addSubview:sw];

        y += MAX(36, sz.height) + 4;
    }

    // speeds list
    UILabel *speedHdr = [[UILabel alloc] initWithFrame:CGRectMake(12, y, innerW, 18)];
    speedHdr.text = @"倍率列表（点击选中，长按删除）";
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
        [row setTitle:[NSString stringWithFormat:@"  %.3f×", v] forState:UIControlStateNormal];
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
    [addBtn setTitle:@"+ 添加倍率" forState:UIControlStateNormal];
    [addBtn addTarget:self action:@selector(addSpeed) forControlEvents:UIControlEventTouchUpInside];
    [card addSubview:addBtn];
    y += 40;

    UIButton *selfTestBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    selfTestBtn.frame = CGRectMake(12, y, innerW, 32);
    [selfTestBtn setTitle:@"自检 vtable swizzle (写日志)" forState:UIControlStateNormal];
    [selfTestBtn addTarget:self action:@selector(selfTestTapped:) forControlEvents:UIControlEventTouchUpInside];
    [card addSubview:selfTestBtn];
    y += 40;

    UIButton *closeBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    closeBtn.frame = CGRectMake(12, y, innerW, 32);
    [closeBtn setTitle:@"关闭" forState:UIControlStateNormal];
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

- (void)pauseChanged:(UISwitch *)s {
    self.paused = s.on;
    player_set_paused(s.on);
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
    if (self.pauseSwitch && !self.pauseSwitch.enabled && get_player_or_resolve()) {
        self.pauseSwitch.enabled = YES;
    }
    // 刷新时钟通道计数 label
    _Atomic(uint64_t) *cnts[] = {
        &g_tw_mach_calls, &g_tw_gtod_calls, &g_tw_cgt_calls, &g_tw_cgt_nsec_calls,
        &g_tw_steady_now_calls,
        &g_tw_mach_cont_calls, &g_tw_mach_appx_calls, &g_tw_mach_cont_appx_calls,
        &g_tw_ca_cmt_calls, &g_tw_cf_abs_calls,
        &g_tw_time_calls, &g_tw_dt_calls, &g_tw_dwt_calls,
        &g_tw_pu_rt_calls, &g_tw_pu_mono_calls, &g_tw_pi_gtod_calls, &g_tw_pi_mach_calls,
        &g_tw_mtp_getpos_calls,
        &g_tw_gp_update_calls,
        &g_tw_cc_tick_calls, &g_tw_cc_active_calls,
        &g_tw_ch_getpos_vt_calls,
        &g_tw_dl_ts_calls, &g_tw_dl_target_calls, &g_tw_dl_dur_calls,
    };
    int n = (int)(sizeof(cnts) / sizeof(cnts[0]));
    for (int i = 0; i < n; i++) {
        UIView *v = [menuView viewWithTag:(3000 + i)];
        if ([v isKindOfClass:[UILabel class]]) {
            ((UILabel *)v).text = [NSString stringWithFormat:@"%llu calls",
                                   (unsigned long long)atomic_load(cnts[i])];
        }
    }
}

- (void)toastChanged:(UISwitch *)s {
    NSMutableDictionary *p = loadPrefDict();
    p[@"toast"] = @(s.on);
    savePrefDict(p);
    loadPref();
}

- (void)clockToggleChanged:(UISwitch *)sw {
    int idx = (int)(sw.tag - 3100);
    _Atomic(int) *flags[] = {
        &g_tw_en_mach, &g_tw_en_gtod, &g_tw_en_cgt, &g_tw_en_cgt_nsec,
        &g_tw_en_steady_now,
        &g_tw_en_mach_cont, &g_tw_en_mach_appx, &g_tw_en_mach_cont_appx,
        &g_tw_en_ca_cmt, &g_tw_en_cf_abs,
        &g_tw_en_time, &g_tw_en_dt, &g_tw_en_dwt,
        &g_tw_en_pu_rt, &g_tw_en_pu_mono, &g_tw_en_pi_gtod, &g_tw_en_pi_mach,
        &g_tw_en_mtp_getpos,
        &g_tw_en_gp_update,
        &g_tw_en_cc_tick, &g_tw_en_cc_active,
        &g_tw_en_ch_getpos_vt,
        &g_tw_en_dl_ts, &g_tw_en_dl_target, &g_tw_en_dl_dur,
    };
    const char *names[] = {
        "mach_abs", "gtod", "cgt", "cgt_nsec",
        "steady_now",
        "mach_cont", "mach_appx", "mach_cont_appx",
        "ca_cmt", "cf_abs",
        "time", "dispatch_time", "dispatch_walltime",
        "[vt]pu_rt", "[vt]pu_mono", "[vt]pi_gtod", "[vt]pi_mach",
        "[vt]MTP.getPos",
        "[vt]GP.update",
        "[vt]CC.tick", "[vt]CC.active",
        "[vt]CH.getPos",
        "[obj]dl.ts", "[obj]dl.target", "[obj]dl.dur",
    };
    int n = (int)(sizeof(flags) / sizeof(flags[0]));
    if (idx < 0 || idx >= n) return;
    if (sw.on && !clock_hook_ready_for_idx(idx)) {
        sw.on = NO;
        atomic_store(flags[idx], 0);
        acc_flog(@"clock toggle reject: %s ON requested but hook not ready", names[idx]);
        if (toast) {
            [WHToast showMessage:[NSString stringWithFormat:@"%s 未就绪", names[idx]]
                        duration:0.6 finishHandler:^{}];
        }
        return;
    }
    atomic_store(flags[idx], sw.on ? 1 : 0);
    acc_flog(@"clock toggle: %s = %d", names[idx], sw.on ? 1 : 0);
    if (toast) {
        [WHToast showMessage:[NSString stringWithFormat:@"%s %@", names[idx], sw.on ? @"ON" : @"OFF"]
                    duration:0.4 finishHandler:^{}];
    }
}

- (void)selfTestTapped:(UIButton *)b {
    self_test_vtable();
    if (toast) {
        [WHToast showMessage:@"自检已写入日志 Documents/AccDemoArcaea.log"
                    duration:1.0 finishHandler:^{}];
    }
}

- (void)rowTapped:(UIButton *)b {
    NSInteger i = b.tag - 1000;
    if (i < 0 || i >= rate_count) return;
    rate_i = i;
    time_warp_set_rate((double)rates[rate_i]);
    apply_speed_to_all_channels();
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
    if (keys.count <= 1) return; // 至少留一�?
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
        // 单击：切换倍率（低频动作）
        if (rate_count <= 0) return;
        rate_i = (rate_i + 1) % rate_count;
        time_warp_set_rate((double)rates[rate_i]);  // 谱面同步变速
        apply_speed_to_all_channels();              // 音频同步变速
        if (toast) {
            [WHToast showMessage:[NSString stringWithFormat:@"%.3fx (tap2x=menu)", rates[rate_i]]
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
    label.text = @"acc";
    label.textColor = [UIColor whiteColor];
    label.font = [UIFont systemFontOfSize:11];
    label.textAlignment = NSTextAlignmentCenter;
    [button addSubview:label];

    // 长按浮窗 开菜单
    UILongPressGestureRecognizer *lp = [[UILongPressGestureRecognizer alloc]
        initWithTarget:[AccMenuController shared] action:@selector(handleLongPress:)];
    lp.minimumPressDuration = 0.45;
    [button addGestureRecognizer:lp];
    // 双击浮窗 开菜单（陪绑）
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

@interface AccMenuController (LongPress) @end
@implementation AccMenuController (LongPress)
- (void)handleLongPress:(UILongPressGestureRecognizer *)g {
    if (g.state == UIGestureRecognizerStateBegan) {
        acc_flog(@"longPress fired -> show");
        [self show];
    }
}
- (void)handleDoubleTap:(UITapGestureRecognizer *)g {
    acc_flog(@"doubleTap fired -> show");
    [self show];
}
@end

#pragma mark - bootstrap

// 文件日志：sideload 下没法接 Console，写到 app Documents/AccDemoArcaea.log
// 用户可通过 iTunes 文件共享 / iMazing / 3uTools 取出
static void acc_flog(NSString *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    NSString *line = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    NSLog(@"[AccDemoArcaea] %@", line);
    @try {
        NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
        if (!docs) return;
        NSString *path = [docs stringByAppendingPathComponent:@"AccDemoArcaea.log"];
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
        acc_flog(@"doBootstrap begin");
        @try { initButton(); }       @catch (NSException *e) { acc_flog(@"initButton EX: %@", e); }
        @try { install_arc_hooks(); } @catch (NSException *e) { acc_flog(@"install_arc_hooks EX: %@", e); }
        @try { time_warp_install(); } @catch (NSException *e) { acc_flog(@"time_warp_install EX: %@", e); }
        @try { install_vtable_swizzles(); } @catch (NSException *e) { acc_flog(@"install_vtable_swizzles EX: %@", e); }
        @try { install_displaylink_swizzles(); } @catch (NSException *e) { acc_flog(@"install_displaylink_swizzles EX: %@", e); }
        // 后台轮询：不断给 channel 应用当前倍率（安全：setFrequency 是 FMOD 公开 API，不写 text）
        // 第一次进歌曲时会自动捕获 base_freq；之后每次倍率切换由 UI 触发，但 seek/重启歌曲会重置
        // FMOD 频率，所以这里也要兜底重新 apply。
        [NSTimer scheduledTimerWithTimeInterval:0.5 repeats:YES block:^(NSTimer *t) {
            apply_speed_to_all_channels();
            // CCDirector 单例就绪后安装主循环位点，命中后可直接控制本帧 deltaTime。
            try_install_ccdirector_vtable_swizzle();
            // channel 出现后再做运行时 vtable 替换，覆盖 MTP->Channel 的真实读取路径。
            try_install_channel_vtable_swizzle();
            // 兜底捕获歌曲总时长（之前依赖 getPositionMs hook，现已删除）
            void *p = get_player_or_resolve();
            // 切歌检测：player 指针没变但 channels 数组首地址变了 → 新一轮，清空缓存
            static void *s_last_player = NULL;
            static void *s_last_channels = NULL;
            static uint64_t s_diag_tick = 0;
            void *channels_base_chk = p ? *(void **)((char *)p + ARC_PLAYER_CHANNELS_OFFSET) : NULL;
            if (p != s_last_player || channels_base_chk != s_last_channels) {
                // 新歌：清 base_freq 缓存 + 清歌曲长度，重新捕获
                for (int i = 0; i < ARC_MAX_CHANNELS; i++) atomic_store(&g_base_freq[i], 0);
                atomic_store(&g_song_length_ms, 0);
                atomic_store(&g_max_seen_ms, 0);
                atomic_store(&g_last_pos_ms, 0);
                s_last_player = p;
                s_last_channels = channels_base_chk;
                acc_flog(@"new song detected: player=%p channels=%p", p, channels_base_chk);
            }
            // 每 5 秒（每 10 个 tick）打印一次诊断计数 → 可看出 fishhook 是否被实际调用
            if ((s_diag_tick++ % 10) == 0) {
                acc_flog(@"twcalls mach=%llu gtod=%llu cgt=%llu cgt_ns=%llu rate=%.3f freeze=%d",
                         (unsigned long long)atomic_load(&g_tw_mach_calls),
                         (unsigned long long)atomic_load(&g_tw_gtod_calls),
                         (unsigned long long)atomic_load(&g_tw_cgt_calls),
                         (unsigned long long)atomic_load(&g_tw_cgt_nsec_calls),
                         tw_get_rate(),
                         atomic_load(&g_tw_freeze_count));
                acc_flog(@"twcalls mtp=%llu ch_vt=%llu ch_vt_installed=%d",
                         (unsigned long long)atomic_load(&g_tw_mtp_getpos_calls),
                         (unsigned long long)atomic_load(&g_tw_ch_getpos_vt_calls),
                         atomic_load(&g_tw_ch_getpos_vt_installed));
                acc_flog(@"twcalls cc_tick=%llu cc_active=%llu cc_tick_installed=%d cc_active_installed=%d",
                         (unsigned long long)atomic_load(&g_tw_cc_tick_calls),
                         (unsigned long long)atomic_load(&g_tw_cc_active_calls),
                         atomic_load(&g_tw_cc_tick_installed),
                         atomic_load(&g_tw_cc_active_installed));
            }
            if (p) try_capture_song_length(p);
            // 兜底维护 last_pos_ms / max_seen_ms（用于进度条显示）
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
    // 切后台：冻结 warp 时间，防止回前台时 currentTimeMs 跳变 = 后台时长 * rate
    time_warp_freeze_inc();
    acc_flog(@"app -> background, warp frozen (count=%d)", atomic_load(&g_tw_freeze_count));
}

static void onAppWillEnterForeground(CFNotificationCenterRef center, void *observer,
                                     CFStringRef name, const void *object,
                                     CFDictionaryRef userInfo) {
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
    // 兜底：如果 ctor 在 UIApplicationDidFinishLaunching 之后才跑（理论上不会，但
    // 注入工具如果用 LC_LOAD_WEAK_DYLIB / 延迟加载可能错过通知），3 秒后强制走一次
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        acc_flog(@"3s fallback bootstrap");
        doBootstrap();
    });
}
