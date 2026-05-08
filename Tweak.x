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
#import <stdatomic.h>
#import <UIKit/UIKit.h>

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
static get_registry_fn      g_get_registry = NULL;
static get_current_sound_fn g_get_current_sound = NULL;
static get_sound_length_fn  g_get_sound_length = NULL;
static ch_get_position_fn   g_ch_get_position = NULL;
static ch_set_frequency_fn  g_ch_set_frequency = NULL;
static ch_get_frequency_fn  g_ch_get_frequency = NULL;
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
    g_get_current_sound = (get_current_sound_fn)(base + ARC_OFF_GET_CURRENT_SOUND);
    g_get_sound_length  = (get_sound_length_fn) (base + ARC_OFF_GET_SOUND_LENGTH);
    g_ch_get_position   = (ch_get_position_fn) (base + ARC_OFF_CH_GET_POSITION);
    g_ch_set_frequency  = (ch_set_frequency_fn)(base + ARC_OFF_CH_SET_FREQUENCY);
    g_ch_get_frequency  = (ch_get_frequency_fn)(base + ARC_OFF_CH_GET_FREQUENCY);
    NSLog(@"[AccDemoArcaea] registry=%p getCurrentSound=%p getLength=%p setFreq=%p",
          (void *)g_get_registry, (void *)g_get_current_sound,
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
    void *channels_base = *(void **)((char *)self + ARC_PLAYER_CHANNELS_OFFSET);
    void *channels_end  = *(void **)((char *)self + ARC_PLAYER_CHANNELS_OFFSET + 8);
    if (!channels_base || !channels_end || channels_end < channels_base) return 0;
    size_t n = ((size_t)((char *)channels_end - (char *)channels_base)) / ARC_CHANNEL_ENTRY_STRIDE;
    if (n > (size_t)outCap) n = (size_t)outCap;
    int got = 0;
    for (size_t i = 0; i < n; i++) {
        void *ch = *(void **)((char *)channels_base + ARC_CHANNEL_ENTRY_STRIDE * i + ARC_CHANNEL_ENTRY_PTR_OFF);
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
static orig_mach_abs_t          s_orig_mach_abs = NULL;
static orig_gettod_t            s_orig_gettod   = NULL;
static orig_clock_gettime_t     s_orig_clock_gettime = NULL;
static orig_clock_gettime_nsec_np_t s_orig_clock_gettime_nsec_np = NULL;

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
    if (atomic_load(&g_tw_freeze_count) > 0) {
        uint64_t f = atomic_load(&g_tw_frozen_mach);
        return f ? f : real;
    }
    return _compute_warp_mach(real);
}

static int tw_gettimeofday(struct timeval *tv, void *tz) {
    if (!tv) return s_orig_gettod ? s_orig_gettod(tv, tz) : gettimeofday(tv, tz);
    int r = s_orig_gettod ? s_orig_gettod(tv, tz) : gettimeofday(tv, tz);
    atomic_fetch_add(&g_tw_gtod_calls, 1);
    if (r != 0) return r;
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

// clock_gettime_nsec_np → 直接返回纳秒，FMOD profiler / 部分 cocos 用这个
static uint64_t tw_clock_gettime_nsec_np(clockid_t clk) {
    uint64_t real_ns = s_orig_clock_gettime_nsec_np ? s_orig_clock_gettime_nsec_np(clk) : 0;
    atomic_fetch_add(&g_tw_cgt_nsec_calls, 1);
    if (real_ns == 0) return real_ns;
    if (clk != 8 && clk != 6 && clk != 4) return real_ns; // 同上，只 warp 单调
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
        struct rebinding rs[4] = {
            { "mach_absolute_time",     (void *)tw_mach_absolute_time,     (void **)&s_orig_mach_abs },
            { "gettimeofday",           (void *)tw_gettimeofday,           (void **)&s_orig_gettod   },
            { "clock_gettime",          (void *)tw_clock_gettime,          (void **)&s_orig_clock_gettime },
            { "clock_gettime_nsec_np",  (void *)tw_clock_gettime_nsec_np,  (void **)&s_orig_clock_gettime_nsec_np },
        };
        int r = rebind_symbols(rs, 4);
        acc_flog(@"fishhook rebind_symbols ret=%d mach=%p gtod=%p cgt=%p cgt_nsec=%p",
                 r, (void *)s_orig_mach_abs, (void *)s_orig_gettod,
                 (void *)s_orig_clock_gettime, (void *)s_orig_clock_gettime_nsec_np);
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
}

- (void)toastChanged:(UISwitch *)s {
    NSMutableDictionary *p = loadPrefDict();
    p[@"toast"] = @(s.on);
    savePrefDict(p);
    loadPref();
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
        // 后台轮询：不断给 channel 应用当前倍率（安全：setFrequency 是 FMOD 公开 API，不写 text）
        // 第一次进歌曲时会自动捕获 base_freq；之后每次倍率切换由 UI 触发，但 seek/重启歌曲会重置
        // FMOD 频率，所以这里也要兜底重新 apply。
        [NSTimer scheduledTimerWithTimeInterval:0.5 repeats:YES block:^(NSTimer *t) {
            apply_speed_to_all_channels();
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
