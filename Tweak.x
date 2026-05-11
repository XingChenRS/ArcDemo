// xrc-arcdemo / Tweak.x
// Arcaea iOS 变速/Seek 练习工具 (fork of brendonjkding/accDemo)
// 单 dylib 注入，游戏内浮窗 UI
//
// 变速架构 (v4):
//   谱面: GP.update vtable -> _gp_retime_logic_clock(clock[16]) + _gp_drift_correct(clock[40])
//   视觉: gettimeofday fishhook -> CCDirector delta 自动变速
//   音频: FMOD Channel::setFrequency(base * rate)
// seek 架构: MTP::seekTo + clock[40] + track reactivation + finished flags reset

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
#import "AccCommon.h"

// forward decl: 文件末尾定义，但中部诊断需要用
void acc_flog(NSString *fmt, ...) NS_FORMAT_FUNCTION(1, 2);

#pragma mark - global

float    *rates = NULL;
NSInteger rate_i = 0;
NSInteger rate_count = 0;

BOOL     buttonEnabled = YES;
BOOL     toast = YES;

WQSuspendView *button = nil;
UIView        *menuView = nil;
#pragma mark - Arcaea binary hook (Dobby)
//
// 已知偏移 (IDA 6.13.10 分析):
//   sub_100846950 (vtable[7] of MultiTrackPlayer) = getPositionMs(this, channel)
//   sub_100846914 (vtable[6])                     = setPaused(this, paused, channel)
//   sub_10084699C (vtable[8])                     = seekTo(this, ms, channel)
//   sub_100C9D718                                 = getRegistry() - 全局单例
//   *(getRegistry() + 8)                          = MultiTrackPlayer
//   sub_100EC094C                                 = Channel::getCurrentSound(ch, Sound**)
//   sub_100F2BB64                                 = Sound::getLength(snd, uint32_t*, unit=1)
//   sub_100EC069C                                 = Channel::setFrequency(ch, float)
// 
// MTP 内部布局: 通道数组 channels[i] @ player+0x38, stride=16, 每项+8 = Channel*
//   ch0 = *(*(player+0x38) + 8)
//
// 运行时地址 = arcaea_base + offset
#define ARC_OFF_GET_POSITION_MS    (0x846950ULL)
#define ARC_OFF_GET_REGISTRY       (0xC9D718ULL)
// 以下偏移仅用于数据/函数指针读取，不做 vtable 写入
#define ARC_OFF_GET_CURRENT_SOUND  (0xEC094CULL)
#define ARC_OFF_GET_SOUND_LENGTH   (0xF2BB64ULL)
// 直接 FMOD Channel API，绕开 MTP 包装。
//   getPositionMs(MTP, ch) 内部就是 Channel::getPosition（已确认）→ 改频率 → 谱面/音频同步
#define ARC_OFF_CH_GET_POSITION    (0xEC03ACULL)
#define ARC_REG_PLAYER_OFFSET      (8)
#define ARC_PLAYER_CHANNELS_OFFSET (0x38)
#define ARC_CHANNEL_ENTRY_PTR_OFF  (8)
#define ARC_CHANNEL_ENTRY_STRIDE   (16)

typedef uint32_t (*get_position_ms_fn)(void *self, int channel);
typedef void *   (*get_registry_fn)(void);
typedef int      (*get_current_sound_fn)(void *channel, void **outSound);
typedef int      (*get_sound_length_fn)(void *sound, uint32_t *outLen, int unit);
typedef int      (*ch_get_position_fn)(void *channel, uint32_t *out_ms, int unit);
static get_registry_fn      g_get_registry = NULL;
static get_current_sound_fn g_get_current_sound = NULL;
static get_sound_length_fn  g_get_sound_length = NULL;
static ch_get_position_fn   g_ch_get_position = NULL;

// hook 兜底捕获 + 主动通过 registry 获取
static _Atomic(void *)   g_bgmPlayer = NULL;
_Atomic(uint32_t) g_last_pos_ms = 0;
static _Atomic(uint32_t) g_max_seen_ms = 0;
static _Atomic(uint32_t) g_song_length_ms = 0;   // FMOD 拿到的真实总时长

// 音频 hook 已废除 (用户决定: 仅留 gettimeofday + Gameplay vtable 两个 hook)。
// MTP getPos vtable swizzle 仍保留, 仅用作位置读出 (进度条 + seek 反馈),
// 不再做任何 setFrequency / corr / 滑窗测量。

// 尝试从 player 主轨拿 Sound 总长
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

void *get_player_or_resolve(void) {
    void *p = atomic_load(&g_bgmPlayer);
    if (p) return p;
    return resolve_player_via_registry();
}

// 防止读到野指针：先做用户态地址粗筛。
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
    // 启发式上限：拒绝超大跨度访问，避免野 end 指针导致后续越界。
    if (len > (1ULL << 20)) return false;
    // 这里不再调用 vm_region_recurse（部分 Theos/SDK 组合下该符号缺失导致链接失败）。
    return true;
}

// 取 Arc-mobile 主二进制基址
uint64_t arc_image_base(void) {
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
        NSLog(@"[xrc-arcdemo] arc_image_base() = 0, abort");
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
    NSLog(@"[xrc-arcdemo] registry=%p getCurrentSound=%p getLength=%p",
          (void *)g_get_registry, (void *)g_get_current_sound,
          (void *)g_get_sound_length);
    void *mtp = resolve_player_via_registry();
    NSLog(@"[xrc-arcdemo] initial MTP via registry = %p", mtp);
    if (mtp) try_capture_song_length(mtp);
}

// 通过 player vtable 调用对应槽位
static inline void *_player_vt_slot(void *self, size_t byte_off) {
    if (!self) return NULL;
    void **vtable = *(void ***)self;
    if (!vtable) return NULL;
    return vtable[byte_off / sizeof(void *)];
}

#pragma mark - Time Warp (gettimeofday fishhook for CCDirector visual speed)

// gettimeofday fishhook: CCDirector 用它计算帧间 delta, warp 后视觉动画按 rate 播放
// 公式: t_warp(real) = t0_warp + (real - t0_real) * rate
// 切倍率瞬间: t0_real = real_now; t0_warp = warp_now (保持连续, 不跳变)

typedef int (*orig_gettod_t)(struct timeval *tv, void *tz);
orig_gettod_t s_orig_gettod = NULL;

static _Atomic(uint64_t) g_tw_t0_real_us   = 0;
static _Atomic(uint64_t) g_tw_t0_warp_us   = 0;
static _Atomic(uint32_t) g_tw_rate_x1000   = 1000;

// 冻结机制: 暂停 / 切后台 / seek 时冻结 warp 时间
_Atomic(int32_t)  g_tw_freeze_count = 0;
static _Atomic(uint64_t) g_tw_frozen_us    = 0;

_Atomic(uint64_t) g_tw_gtod_calls = 0;
_Atomic(int) g_tw_en_gtod = 1;

// forward decl: defined later; needed by tw_mtp_getpos audio rate measurement
static uint64_t _real_now_us_unwarped(void);

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
    atomic_fetch_add(&g_tw_gtod_calls, 1);
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
    if (warp_us == real_us) return r;
    tv->tv_sec  = (time_t)(warp_us / 1000000ULL);
    tv->tv_usec = (suseconds_t)(warp_us % 1000000ULL);
    return r;
}





#pragma mark - vtable swizzle (核心 Hook)

#define ARC_OFF_MTP_VTABLE  (0x1312860ULL)
#define ARC_OFF_MTP_GETPOS  (0x846950ULL)
#define ARC_OFF_GP_VTABLE    (0x136E1C0ULL)
#define ARC_OFF_GP_UPDATE_FN (0xB3AD70ULL)

// LogicNote::isCompleted (vtable+40, slot 5).
// Same impl 0x7E27B8 lives in 5 subclass vtables (Tap/ArcTap/Hold/Arc/Bar variants).
// Vtable starts identified via IDA xrefs to 0x1007E27B8 (xref data addrs are
// vtable_start + 0x28 = slot[5], so vtable_start = xref - 0x28):
//   xref 0x101303ff8 -> vtable 0x101303fd0 -> off 0x1303FD0
//   xref 0x10130bc68 -> vtable 0x10130bc40 -> off 0x130BC40
//   xref 0x10130dbd8 -> vtable 0x10130dbb0 -> off 0x130DBB0
//   xref 0x101317218 -> vtable 0x1013171f0 -> off 0x13171F0
//   xref 0x101338918 -> vtable 0x1013388f0 -> off 0x13388F0
// (Earlier comment had typo 0x303FD0; the correct offsets are 0x1303FD0...)
#define ARC_OFF_LOGICNOTE_ISCOMPLETED (0x7E27B8ULL)
#define ARC_OFF_VT_LOGICNOTE_COUNT 5
static const uint64_t kArcLogicNoteVtables[ARC_OFF_VT_LOGICNOTE_COUNT] = {
    0x1303FD0ULL, 0x130BC40ULL, 0x130DBB0ULL, 0x13171F0ULL, 0x13388F0ULL
};

typedef uint32_t (*orig_mtp_getpos_fn)(void *self, int channel);
typedef int64_t (*orig_gp_update_fn)(void *self, uint64_t a2, uint64_t a3, uint64_t a4, uint64_t a5);

static orig_mtp_getpos_fn s_orig_mtp_getpos = NULL;
static orig_gp_update_fn s_orig_gp_update = NULL;
static _Atomic(uint64_t) g_tw_mtp_getpos_calls = 0;
_Atomic(uint64_t) g_tw_gp_update_calls = 0;
static _Atomic(int) g_tw_gp_update_installed = 0;

// isCompleted hook state (v6: timing-aware seek-replay).
//
// v5 did:  during 1.5s grace window, force return 0 + clear byte[12]/[13].
// v6 does: maintain g_seek_target_ms; for ANY note whose timing >= target-120,
//          force return 0 (note re-appears via spatial query); for past notes
//          delegate to original (stays completed). Window is kept as a SAFETY
//          BACKSTOP only -- if g_seek_target_ms is unset but window is open,
//          fall back to "force 0" (legacy v5 behaviour).
//
// IDA-derived layout (LogicNote, common base):
//   +0..7   vtable
//   +20 (DWORD, int32)  note.timing in chart-ms          ← used here
//   +28 (DWORD, int32)  note.end_timing
//   +48..55 (int32x2)   per-frame distance cache (vtable[3] writes; do NOT touch)
//   +56..63 (int32x2)   distance base offset (init-time const)
typedef int (*orig_iscompleted_fn)(void *self);
static orig_iscompleted_fn s_orig_iscompleted = NULL;
_Atomic(uint64_t) g_rewind_until_us  = 0;       // legacy v5 backstop window deadline (real us)
_Atomic(int32_t)  g_seek_target_ms   = INT_MIN; // v6: chart-ms target of last seek; INT_MIN = inactive
_Atomic(uint64_t) g_iscompleted_calls = 0;
_Atomic(uint64_t) g_iscompleted_force_zero = 0;
_Atomic(uint64_t) g_iscompleted_force_one  = 0;
_Atomic(int)      g_iscompleted_installed_count = 0;
// Per-vtable install diag (visible in panel). 0..4 = code:
//   0='?' not tried, 'O'=ok, 'B'=bad-base, 'U'=unreadable, 'M'=mismatch slot5,
//   'P'=mprotect fail, 'S'=signed-write
_Atomic(int) g_iscompleted_vt_code[ARC_OFF_VT_LOGICNOTE_COUNT] = {0};
// Last raw value seen at slot 5 (post-PAC-strip), for panel hex dump on failure
_Atomic(uint64_t) g_iscompleted_vt_seen[ARC_OFF_VT_LOGICNOTE_COUNT] = {0};
// Tunable: future-window slop (ms). Notes within this past-radius of seek
// target are also treated as "future" so just-passed notes get re-shown.
#define ARC_SEEK_FUTURE_SLOP_MS  120
// Heuristic plausibility for note.timing (chart-ms). Reject obviously bogus reads.
#define ARC_NOTE_TIMING_MIN  (-10000)
#define ARC_NOTE_TIMING_MAX  ( 1200000)   /* 20 min */

// 缓存 Gameplay 实例指针 (seek 需要访问谱面时钟)
_Atomic(void *) g_gameplay_instance = NULL;

// retime 状态: 记录上一帧的真实时间和 clock 指针, 用于计算帧间 delta
static void *s_gp_last_clock = NULL;
static uint64_t s_gp_last_real_us = 0;
// MTP getPos vtable wrapper：自动捕获 player 实例 + 位置追踪 (仅读取,不变速)
static uint32_t tw_mtp_getpos(void *self, int channel) {
    uint32_t raw = s_orig_mtp_getpos ? s_orig_mtp_getpos(self, channel) : 0;
    atomic_fetch_add(&g_tw_mtp_getpos_calls, 1);
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

// 取未被 warp 的真实 microsecond 时间 (用于 retime delta 计算)
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

// forward decl (defined later in file): chart clock reader used by retime drift fix
static int32_t _read_chart_clock_ms(void *clk);

// 谱面 retime: 每帧按 rate 推进 clk[16], 与音频独立。
// 不做 audio<->chart 任何绑定 (绑定无论怎么做都会抽搐或加延迟)。
// 公式: chart_displayed = steady_now - clk[16] - clk[40]
// 想让 chart 走 rate 倍速 -> 每帧让 clk[16] 反向走 (rate-1)*delta_ms
// 即  clk[16] += (1 - rate) * delta_ms
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

// forward decl (defined after time_warp_install)
static int32_t _read_chart_clock_ms(void *clk);

// LogicNote::isCompleted vtable hook (v6 timing-aware seek-replay).
//
// Decision matrix (only active while seek grace window open):
//   if window_open and g_seek_target_ms set:
//     if note.timing >= target - SLOP   -> return 0  (treat as future, re-show)
//     else                                -> return original (likely 1, stay completed)
//   elif window_open (timing read failed): -> return 0 (legacy v5 fallback)
//   else:                                  -> delegate to original
//
// We DELIBERATELY do NOT touch byte[12]/[13] anymore -- vtable[3] writes
// bytes +48..+55 every frame as cached distances, so any state-clearing
// at those offsets is a no-op (cache gets overwritten next spatial query).
// IMPORTANT: g_seek_target_ms must be SCOPED to the grace window. If left
// armed forever, every newly judged note during normal play would get
// re-shown (target stale). Window expiry disarms both.
static int tw_logicnote_isCompleted(void *self) {
    atomic_fetch_add(&g_iscompleted_calls, 1);
    uint64_t until = atomic_load(&g_rewind_until_us);
    if (until == 0) {
        // Window closed -> normal play, transparent passthrough
        return s_orig_iscompleted ? s_orig_iscompleted(self) : 0;
    }
    uint64_t now_us = _real_now_us_unwarped();
    if (now_us != 0 && now_us >= until) {
        // Window expired -> disarm both (avoid stale target affecting normal play)
        atomic_store(&g_rewind_until_us, 0);
        atomic_store(&g_seek_target_ms, INT_MIN);
        return s_orig_iscompleted ? s_orig_iscompleted(self) : 0;
    }

    // Window active.
    int32_t target = atomic_load(&g_seek_target_ms);
    if (target != INT_MIN && self && ptr_plausible(self) && addr_readable((char *)self + 24, 4)) {
        int32_t note_timing = *(int32_t *)((char *)self + 20);
        if (note_timing > ARC_NOTE_TIMING_MIN && note_timing < ARC_NOTE_TIMING_MAX) {
            if (note_timing >= target - ARC_SEEK_FUTURE_SLOP_MS) {
                atomic_fetch_add(&g_iscompleted_force_zero, 1);
                return 0;
            }
            atomic_fetch_add(&g_iscompleted_force_one, 1);
            return s_orig_iscompleted ? s_orig_iscompleted(self) : 1;
        }
    }
    // timing read failed or target unset -> legacy v5: force 0 within window
    atomic_fetch_add(&g_iscompleted_force_zero, 1);
    return 0;
}

// Gameplay.update vtable hook:
//   1. 缓存 Gameplay 实例 (seek/reset 需要)
//   2. _gp_retime_logic_clock 变速谱面
static int64_t tw_gp_update(void *self, uint64_t a2, uint64_t a3, uint64_t a4, uint64_t a5) {
    atomic_fetch_add(&g_tw_gp_update_calls, 1);
    if (self) {
        atomic_store(&g_gameplay_instance, self);
        void *logic = NULL;
        if (addr_readable((char *)self + 936, sizeof(void *)))
            logic = *(void **)((char *)self + 928);
        if (logic && ptr_plausible(logic))
            _gp_retime_logic_clock(logic);
    }
    return s_orig_gp_update ? s_orig_gp_update(self, a2, a3, a4, a5) : 0;
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
        swizzle_vtable_find_swap(base + ARC_OFF_MTP_VTABLE, ARC_OFF_MTP_GETPOS,
                                 (void *)tw_mtp_getpos, (void **)&s_orig_mtp_getpos);
        int gp_slot = swizzle_vtable_find_swap(base + ARC_OFF_GP_VTABLE, ARC_OFF_GP_UPDATE_FN,
                                               (void *)tw_gp_update, (void **)&s_orig_gp_update);
        if (gp_slot != INT_MIN && s_orig_gp_update) {
            atomic_store(&g_tw_gp_update_installed, 1);
            acc_flog(@"gp.update vtable installed slot=%d", gp_slot);
        }
        // Hook isCompleted on every known LogicNote subclass vtable.
        // The first successful swizzle captures the original; later vtables share it
        // (all 5 vtables hold the same impl 0x7E27B8 at slot+40).
        // IDA-confirmed layout: vtable[5] = isCompleted on every subclass.
        // We bypass the ±64-slot scan and write slot 5 directly, capturing
        // per-vtable diag codes so the panel can show why any failed.
        int n_iscomp = 0;
        uint64_t iscomp_target = base + ARC_OFF_LOGICNOTE_ISCOMPLETED;
        for (int i = 0; i < ARC_OFF_VT_LOGICNOTE_COUNT; i++) {
            uint64_t vt_addr = base + kArcLogicNoteVtables[i];
            void **vt = (void **)vt_addr;
            if (!ptr_plausible(vt) || !addr_readable(vt, 8 * 8)) {
                atomic_store(&g_iscompleted_vt_code[i], 'U');
                acc_flog(@"isComp[%d] vtable %p UNREADABLE", i, vt);
                continue;
            }
            void *cur = vt[5];
#if __has_feature(ptrauth_calls)
            void *stripped = ptrauth_strip(cur, ptrauth_key_asia);
#else
            void *stripped = cur;
#endif
            atomic_store(&g_iscompleted_vt_seen[i], (uint64_t)stripped);
            if ((uint64_t)stripped != iscomp_target) {
                atomic_store(&g_iscompleted_vt_code[i], 'M');
                acc_flog(@"isComp[%d] vtable %p slot5=%p (stripped=%p) != target %p",
                         i, vt, cur, stripped, (void *)iscomp_target);
                continue;
            }
            // mprotect 16K page RW
            uintptr_t page = (uintptr_t)&vt[5] & ~(uintptr_t)0x3FFF;
            bool wrote = false;
            if (mprotect((void *)page, 0x4000, PROT_READ | PROT_WRITE) == 0) {
                wrote = true;
            } else {
                kern_return_t kr = vm_protect(mach_task_self(), (vm_address_t)page, 0x4000,
                                              0, VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY);
                if (kr == KERN_SUCCESS) wrote = true;
            }
            if (!wrote) {
                atomic_store(&g_iscompleted_vt_code[i], 'P');
                acc_flog(@"isComp[%d] vtable %p mprotect+vmprotect FAIL page=%p",
                         i, vt, (void *)page);
                continue;
            }
            if (!s_orig_iscompleted)
                s_orig_iscompleted = (orig_iscompleted_fn)stripped;
#if __has_feature(ptrauth_calls)
            void *signed_new = ptrauth_sign_unauthenticated((void *)tw_logicnote_isCompleted,
                                  ptrauth_key_asia,
                                  ptrauth_blend_discriminator(&vt[5], 0));
            vt[5] = signed_new;
#else
            vt[5] = (void *)tw_logicnote_isCompleted;
#endif
            mprotect((void *)page, 0x4000, PROT_READ);
            atomic_store(&g_iscompleted_vt_code[i], 'O');
            n_iscomp++;
            acc_flog(@"isComp[%d] vtable %p slot5 OK orig=%p", i, vt, stripped);
        }
        atomic_store(&g_iscompleted_installed_count, n_iscomp);
        acc_flog(@"isCompleted vtable installed on %d/%d vtables, orig=%p",
                 n_iscomp, ARC_OFF_VT_LOGICNOTE_COUNT, (void *)s_orig_iscompleted);
    });
}

int clock_hook_ready_for_idx(int idx) {
    if (idx == 0) return s_orig_gettod != NULL;
    return 0;
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

    // (\u97f3\u9891 hook \u5df2\u5e9f\u9664: \u4ec5\u8c03\u8c31\u9762\u53d8\u901f, \u97f3\u9891\u4e0d\u52a8\u3002)
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

// 读取谱面时钟的当前显示 ms（复刻 sub_10086E69C 逻辑）
// 时钟结构: clock[32]=累计时间, clock[40]=基准偏移, clock[45]=内部驱动标志, clock[52]=外部位置
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

    // 1. 音频跳转：MTP::seekTo(this, ms, channel=0)
    typedef void (*seek_fn)(void *, uint32_t, int);
    seek_fn fn = (seek_fn)_player_vt_slot(self, 0x40);
    if (fn) {
        fn(self, ms, 0);
        acc_flog(@"[seek] audio seek to %u ms", ms);
    }

    // 2. 谱面时钟跳转：修改 clock[40] 使得 display_time = target_ms
    //    Gameplay(+928) → LogicChart(+48) → Clock
    //    display = clock[32] - clock[40]  (当 clock[45] 置位时, steady_clock 驱动)
    //    调整: clock[40] += (current_display - target_ms)
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

            // 3. 谱面状态重置 (Plan A, v6 timing-aware):
            //    - IDA 逆向 sub_10086EE70 (空间查询) 确认: 加回活跃列表的关键
            //      条件是 vtable[5](note) == 0 (isCompleted)。byte[12]/[13] 是
            //      sub_1007E2788 (vtable[3]) 每帧重写的距离缓存,清零无意义。
            //    - v6 改为 timing-aware: 设置 g_seek_target_ms 后,hook 按
            //      note.timing(LogicNote+20) 与 target 比较精确决定返回值,
            //      模拟 ArcCreate 的 ResetJudgeTo(timing) 语义。
            //      - note.timing >= target-120  -> 返回 0 (重新出现)
            //      - note.timing <  target-120  -> 返回 1 (保持已完成)
            //    - 旧的 1.5s rewind window 仍开启,作为 timing 字段读失败时的
            //      安全兜底 (legacy v5 path)。
            //    保留辅助清理:
            //      a) 清空活跃音符列表 (+160/+168) 强制下一帧重查询
            //      b) 重新激活所有音轨 (chart_data+80 tracks byte[0])
            //      c) 清空事件队列 (+288/+296)
            //      d) 清除结束标志 (+313..+316)

            // v6: 设置精确 seek 目标 (chart-ms)
            if (atomic_load(&g_iscompleted_installed_count) > 0) {
                atomic_store(&g_seek_target_ms, (int32_t)ms);
                acc_flog(@"[seek] g_seek_target_ms = %d (timing-aware re-show armed)", (int32_t)ms);
            } else {
                acc_flog(@"[seek] WARN: isCompleted hook not installed, replay may fail");
            }

            // Legacy v5 backstop: ~1.5s rewind grace window (兼容 timing 读失败)
            uint64_t now_us = _real_now_us_unwarped();
            if (now_us != 0 && atomic_load(&g_iscompleted_installed_count) > 0) {
                atomic_store(&g_rewind_until_us, now_us + 1500000ULL);
                acc_flog(@"[seek] backstop rewind window opened until +1500ms (real)");
            }

            typedef void (*release_fn)(void *);
            uint64_t base = arc_image_base();

            // a) 清空活跃音符列表: release 每个引用, 然后截断
            if (base && addr_readable((char *)logic + 168, 8)) {
                void **notes_begin = *(void ***)((char *)logic + 160);
                void **notes_end   = *(void ***)((char *)logic + 168);
                if (notes_begin && notes_end && notes_end > notes_begin) {
                    release_fn rel = (release_fn)(base + 0xDB1A28ULL);
                    int n_notes = (int)(notes_end - notes_begin);
                    for (int ni = 0; ni < n_notes; ni++) {
                        if (notes_begin[ni]) rel(notes_begin[ni]);
                    }
                    *(void ***)((char *)logic + 168) = notes_begin;
                    acc_flog(@"[seek] cleared %d active notes", n_notes);
                }
            }

            // b) 重新激活所有音轨
            if (addr_readable((char *)logic + 40, 8)) {
                void *cd = *(void **)((char *)logic + 40);
                if (cd && ptr_plausible(cd) && addr_readable((char *)cd + 96, 8)) {
                    void **tracks_begin = *(void ***)((char *)cd + 80);
                    void **tracks_end   = *(void ***)((char *)cd + 88);
                    if (tracks_begin && tracks_end && tracks_end > tracks_begin) {
                        int n_reactivated = 0;
                        for (void **t = tracks_begin; t < tracks_end; t++) {
                            if (*t && ptr_plausible(*t) && addr_readable(*t, 8)) {
                                *(uint8_t *)(*t) = 1;
                                n_reactivated++;
                            }
                        }
                        acc_flog(@"[seek] reactivated %d tracks", n_reactivated);
                    }
                }
            }

            // c) 清空事件队列
            if (addr_readable((char *)logic + 296, 8)) {
                void *ev_begin = *(void **)((char *)logic + 288);
                if (ev_begin)
                    *(void **)((char *)logic + 296) = ev_begin;
            }

            // d) 清除结束标志
            if (addr_readable((char *)logic + 321, 1)) {
                *(uint8_t *)((char *)logic + 313) = 0;
                *(uint8_t *)((char *)logic + 314) = 0;
                *(uint8_t *)((char *)logic + 315) = 0;
                *(uint8_t *)((char *)logic + 316) = 0;
                acc_flog(@"[seek] chart flags reset");
            }

            // (e) ScoreKeeper \u91cd\u7f6e: \u6682\u65f6\u53bb\u9664\u3002sub_100A7DFC4 \u91cc \u6307\u5b9a\u7684 sk \u504f\u79fb\n            //    (sk[+92]/[+96]/[+100]/[+104]/[+108]) \u4f7f\u7528\u5728 v14=sk[26]+sk[25]+sk[27]\n            //    \u8fd9\u4e2a\u300c\u5df2\u5224\u5b9a\u8ba1\u6570\u300d\u516c\u5f0f\u91cc, \u4f46\u6f14\u7ec3\u8868\u660e\u96f6\u5316\u4f1a\u89e6\u53d1\u300c\u5f00\u5c40\u5373\u7ed3\u675f\u300d\n            //    \u2014\u2014\u8bf4\u660e\u90a3\u4e9b\u504f\u79fb\u91cc\u67d0\u4e00\u4e2a\u5176\u5b9e\u662f\u300c\u603b\u8c31\u9762 note \u6570\u300d\u4e4b\u7c7b\u7684\u4e0d\u53d8\u91cf\uff0c\n            //    \u88ab\u6e05 0 \u540e\u201c\u5df2\u5b8c\u6210 == \u603b\u91cf\u201d\u4e0b\u4e00\u5e27\u5224\u5b9a\u4e3a\u7ed3\u5c40\u3002\u9700\u8981\u91cd\u65b0 RE \u786e\u8ba4\u4e3a\u54ea\u4e2a\n            //    \u504f\u79fb\u540e\u518d\u52a0\u56de\u3002
        }
    }

    s_gp_last_real_us = 0;

    time_warp_freeze_dec();
}

// (player_set_paused 已移除: 用户反馈暂停 BGM 没意义且与 freeze 冲突)

uint32_t player_get_position_ms_cached(void) {
    return atomic_load(&g_last_pos_ms);
}

// 调用者需要的最大进度值：优先 FMOD 拿到的真实总长，其次是运行中看到过的最大 ms
uint32_t player_get_progress_max_ms(void) {
    uint32_t len = atomic_load(&g_song_length_ms);
    if (len > 0) return len;
    return atomic_load(&g_max_seen_ms);
}

#pragma mark - prefs

NSMutableDictionary *loadPrefDict(void) {
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

void savePrefDict(NSDictionary *p) {
    NSString *dir = [kPrefPath stringByDeletingLastPathComponent];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    [p writeToFile:kPrefPath atomically:YES];
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
    if (rate_i >= rate_count) rate_i = 0;

    if (button) [button setHidden:!buttonEnabled];
}

#pragma mark - UI overlay (NSBundle / UIWindow keep-on-top)

%group ui
%hook NSBundle
+ (NSBundle *)bundleForClass:(Class)aClass {
    if (aClass == [%c(WHToastView) class]) {
        // WHToast 资源被打包进 dylib 同目录的 bundle; TrollStore 场景下用 mainBundle 兜底
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
    title.text = @"Arcaea Speed (XRC)";
    title.font = [UIFont boldSystemFontOfSize:18];
    title.textColor = [UIColor blackColor];
    [card addSubview:title];
    y += 28;

    // architecture summary line
    UILabel *warn = [[UILabel alloc] initWithFrame:CGRectMake(12, y, innerW, 48)];
    warn.text = @"Audio: FMOD freq | Chart: GP.update retime | Visual: gettimeofday warp";
    warn.font = [UIFont systemFontOfSize:10];
    warn.textColor = [UIColor colorWithRed:0.0 green:0.5 blue:0.2 alpha:1.0];
    warn.numberOfLines = 0;
    [card addSubview:warn];
    y += 52;

    // ---- BGM player live controls (only meaningful while playing) ----
    BOOL playerReady = (get_player_or_resolve() != NULL);

    UILabel *playerHdr = [[UILabel alloc] initWithFrame:CGRectMake(12, y, innerW, 18)];
    playerHdr.text = playerReady ? @"BGM Control" : @"BGM (waiting...)";
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

    // (Pause BGM 控件已移除: setPaused 与 freeze 双重暂停冲突, 实测不可用)

    [self.progressTimer invalidate];
    self.progressTimer = [NSTimer scheduledTimerWithTimeInterval:0.1
                                                          target:self
                                                        selector:@selector(progressTick:)
                                                        userInfo:nil
                                                         repeats:YES];

    // toast switch
    UILabel *toastLbl = [[UILabel alloc] initWithFrame:CGRectMake(12, y, innerW - 60, 28)];
    toastLbl.text = @"Show toast on rate change";
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

    // ---- hook toggles ----
    UILabel *clkHdr = [[UILabel alloc] initWithFrame:CGRectMake(12, y, innerW, 32)];
    clkHdr.text = @"Hook (ON=warp at rate)";
    clkHdr.font = [UIFont systemFontOfSize:11];
    clkHdr.textColor = [UIColor darkGrayColor];
    clkHdr.numberOfLines = 0;
    [card addSubview:clkHdr];
    y += 36;

    struct { const char *label; _Atomic(int) *en; _Atomic(uint64_t) *cnt; } clocks[] = {
        { "gettimeofday (visual)",             &g_tw_en_gtod,           &g_tw_gtod_calls          },
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

    // GP.update (chart retime) - 只读显示, 始终启用
    UILabel *gpLbl = [[UILabel alloc] initWithFrame:CGRectMake(12, y, innerW - 60, 20)];
    gpLbl.text = @"GP.update (chart retime)";
    gpLbl.font = [UIFont systemFontOfSize:12];
    gpLbl.textColor = [UIColor blackColor];
    [card addSubview:gpLbl];
    UILabel *gpCnt = [[UILabel alloc] initWithFrame:CGRectMake(12, y + 18, innerW - 60, 14)];
    gpCnt.text = [NSString stringWithFormat:@"%llu calls", (unsigned long long)atomic_load(&g_tw_gp_update_calls)];
    gpCnt.font = [UIFont systemFontOfSize:10];
    gpCnt.textColor = [UIColor grayColor];
    gpCnt.tag = 3010;
    [card addSubview:gpCnt];
    UILabel *gpOn = [[UILabel alloc] initWithFrame:CGRectMake(W - 12 - 40, y + 4, 40, 20)];
    gpOn.text = @"ON";
    gpOn.font = [UIFont boldSystemFontOfSize:12];
    gpOn.textColor = [UIColor colorWithRed:0.2 green:0.7 blue:0.2 alpha:1.0];
    gpOn.textAlignment = NSTextAlignmentCenter;
    [card addSubview:gpOn];
    y += 40;

    // ---- B-1: clock-domain diagnostic panel ----
    UILabel *diagHdr = [[UILabel alloc] initWithFrame:CGRectMake(12, y, innerW, 18)];
    diagHdr.text = @"Time domains (live)";
    diagHdr.font = [UIFont systemFontOfSize:11];
    diagHdr.textColor = [UIColor darkGrayColor];
    [card addSubview:diagHdr];
    y += 22;

    // 5~6 行：real / warp / mach / audio / iscomp [+ optional vt-fail line]
    UILabel *diagBody = [[UILabel alloc] initWithFrame:CGRectMake(12, y, innerW, 108)];
    diagBody.numberOfLines = 7;
    diagBody.font = [UIFont fontWithName:@"Menlo" size:10] ?: [UIFont systemFontOfSize:10];
    diagBody.textColor = [UIColor blackColor];
    diagBody.text = @"(initialising...)";
    diagBody.tag = 3020;
    [card addSubview:diagBody];
    y += 114;

    // speeds list
    UILabel *speedHdr = [[UILabel alloc] initWithFrame:CGRectMake(12, y, innerW, 18)];
    speedHdr.text = @"Speed (tap=select, hold=delete)";
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
    [addBtn setTitle:@"+ Add speed" forState:UIControlStateNormal];
    [addBtn addTarget:self action:@selector(addSpeed) forControlEvents:UIControlEventTouchUpInside];
    [card addSubview:addBtn];
    y += 40;

    UIButton *closeBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    closeBtn.frame = CGRectMake(12, y, innerW, 32);
    [closeBtn setTitle:@"Close" forState:UIControlStateNormal];
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
    _Atomic(uint64_t) *cnts[] = {
        &g_tw_gtod_calls,
    };
    int n = (int)(sizeof(cnts) / sizeof(cnts[0]));
    UIView *card = [menuView viewWithTag:9001];
    for (int i = 0; i < n; i++) {
        UIView *v = [card viewWithTag:(3000 + i)];
        if ([v isKindOfClass:[UILabel class]]) {
            ((UILabel *)v).text = [NSString stringWithFormat:@"%llu calls",
                                   (unsigned long long)atomic_load(cnts[i])];
        }
    }
    // GP.update 计数器
    UIView *gpv = [card viewWithTag:3010];
    if ([gpv isKindOfClass:[UILabel class]]) {
        ((UILabel *)gpv).text = [NSString stringWithFormat:@"%llu calls",
                                 (unsigned long long)atomic_load(&g_tw_gp_update_calls)];
    }
    // B-1: clock-domain diagnostic
    UIView *diagv = [card viewWithTag:3020];
    if ([diagv isKindOfClass:[UILabel class]]) {
        struct timeval tv = {0};
        uint64_t real_us = 0, warp_us = 0;
        if (s_orig_gettod && s_orig_gettod(&tv, NULL) == 0)
            real_us = (uint64_t)tv.tv_sec * 1000000ULL + (uint64_t)tv.tv_usec;
        struct timeval tv2 = {0};
        if (gettimeofday(&tv2, NULL) == 0)
            warp_us = (uint64_t)tv2.tv_sec * 1000000ULL + (uint64_t)tv2.tv_usec;
        uint64_t mach_ms = 0;
        // mach_absolute_time -> ns -> ms
        static mach_timebase_info_data_t s_tb = {0};
        if (s_tb.denom == 0) mach_timebase_info(&s_tb);
        if (s_tb.denom != 0) {
            mach_ms = (mach_absolute_time() * (uint64_t)s_tb.numer / (uint64_t)s_tb.denom) / 1000000ULL;
        }
        uint32_t audio_ms = atomic_load(&g_last_pos_ms);
        // chart clock display ms (best-effort)
        int32_t chart_ms = INT_MIN;
        void *gp = atomic_load(&g_gameplay_instance);
        if (gp && ptr_plausible(gp) && addr_readable((char *)gp + 936, 8)) {
            void *logic = *(void **)((char *)gp + 928);
            if (logic && ptr_plausible(logic) && addr_readable((char *)logic + 56, 8)) {
                void *clk = *(void **)((char *)logic + 48);
                if (clk && ptr_plausible(clk) && addr_readable(clk, 64)) {
                    chart_ms = _read_chart_clock_ms(clk);
                }
            }
        }
        uint64_t isc_calls = atomic_load(&g_iscompleted_calls);
        uint64_t isc_z     = atomic_load(&g_iscompleted_force_zero);
        uint64_t isc_o     = atomic_load(&g_iscompleted_force_one);
        int isc_inst       = atomic_load(&g_iscompleted_installed_count);
        // build per-vtable status string e.g. "OOOMM" + first failure hex
        char vtcodes[ARC_OFF_VT_LOGICNOTE_COUNT + 1] = {0};
        uint64_t first_bad_seen = 0; int first_bad_idx = -1;
        for (int vi = 0; vi < ARC_OFF_VT_LOGICNOTE_COUNT; vi++) {
            int code = atomic_load(&g_iscompleted_vt_code[vi]);
            vtcodes[vi] = code ? (char)code : '?';
            if (vtcodes[vi] != 'O' && first_bad_idx < 0) {
                first_bad_idx = vi;
                first_bad_seen = atomic_load(&g_iscompleted_vt_seen[vi]);
            }
        }
        int32_t seek_tgt   = atomic_load(&g_seek_target_ms);
        uint64_t rwnd_us   = atomic_load(&g_rewind_until_us);
        int32_t freeze_n   = atomic_load(&g_tw_freeze_count);
        double rate        = tw_get_rate();
        // wall-warp drift since rate switch (positive: warp ahead of real)
        int64_t drift_ms = 0;
        if (real_us && warp_us) drift_ms = ((int64_t)warp_us - (int64_t)real_us) / 1000;
        ((UILabel *)diagv).text = [NSString stringWithFormat:
            @"rate %.3fx  freeze=%d  rwnd=%llums\n"
             "real %llums  warp %llums  drift %lldms\n"
             "mach %llums  audio %ums  chart %dms\n"
             "Δ(chart-audio) %dms\n"
             "isComp inst=%d [%s] calls=%llu z=%llu o=%llu\n"
             "%@seekTgt=%@",
            rate, freeze_n,
            (unsigned long long)(rwnd_us ? (rwnd_us / 1000) : 0),
            (unsigned long long)(real_us / 1000),
            (unsigned long long)(warp_us / 1000),
            (long long)drift_ms,
            (unsigned long long)mach_ms,
            audio_ms,
            chart_ms,
            (int)((int32_t)chart_ms - (int32_t)audio_ms),
            isc_inst, vtcodes, (unsigned long long)isc_calls,
            (unsigned long long)isc_z, (unsigned long long)isc_o,
            (first_bad_idx >= 0
                ? [NSString stringWithFormat:@"vt[%d] seen=0x%llx (target=0x%llx)\n",
                       first_bad_idx, (unsigned long long)first_bad_seen,
                       (unsigned long long)(arc_image_base() + ARC_OFF_LOGICNOTE_ISCOMPLETED)]
                : @""),
            (seek_tgt == INT_MIN ? @"--" : [NSString stringWithFormat:@"%dms", seek_tgt])];
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
        &g_tw_en_gtod,
    };
    const char *names[] = {
        "gettimeofday",
    };
    int n = (int)(sizeof(flags) / sizeof(flags[0]));
    if (idx < 0 || idx >= n) return;
    if (sw.on && !clock_hook_ready_for_idx(idx)) {
        sw.on = NO;
        atomic_store(flags[idx], 0);
        if (toast) {
        [WHToast showMessage:[NSString stringWithFormat:@"%s not ready", names[idx]]
                    duration:0.6 finishHandler:^{}];
        }
        return;
    }
    atomic_store(flags[idx], sw.on ? 1 : 0);
    if (toast) {
        [WHToast showMessage:[NSString stringWithFormat:@"%s %@", names[idx], sw.on ? @"ON" : @"OFF"]
                    duration:0.4 finishHandler:^{}];
    }
}

- (void)rowTapped:(UIButton *)b {
    NSInteger i = b.tag - 1000;
    if (i < 0 || i >= rate_count) return;
    rate_i = i;
    time_warp_set_rate((double)rates[rate_i]);
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
    if (keys.count <= 1) return; // 至少留一个
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
        // 【修复】time_warp_set_rate现在内部已调用apply_speed_to_all_channels和重置逻辑时钟
        time_warp_set_rate((double)rates[rate_i]);
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
    label.text = @"xrc";
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

// 文件日志：sideload 下没法接 Console，写到 app Documents/xrc-arcdemo.log
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
        acc_flog(@"doBootstrap begin");
        @try { initButton(); }       @catch (NSException *e) { acc_flog(@"initButton EX: %@", e); }
        @try { install_arc_hooks(); } @catch (NSException *e) { acc_flog(@"install_arc_hooks EX: %@", e); }
        @try { time_warp_install(); } @catch (NSException *e) { acc_flog(@"time_warp_install EX: %@", e); }
        @try { install_vtable_swizzles(); } @catch (NSException *e) { acc_flog(@"install_vtable_swizzles EX: %@", e); }
        // 0.5s \u8f6e\u8be2: \u68c0\u6d4b\u6362\u6b4c + \u8f93\u51fa\u8bca\u65ad + \u4ece FMOD \u8865\u8db3\u8fdb\u5ea6\u3002\n        // (\u97f3\u9891 hook \u5df2\u53bb\u9664, \u4e0d\u518d\u8c03\u7528 apply_speed_to_all_channels\u3002)
        [NSTimer scheduledTimerWithTimeInterval:0.5 repeats:YES block:^(NSTimer *t) {
            void *p = get_player_or_resolve();
            static void *s_last_player = NULL;
            static void *s_last_channels = NULL;
            static uint64_t s_diag_tick = 0;
            void *channels_base_chk = p ? *(void **)((char *)p + ARC_PLAYER_CHANNELS_OFFSET) : NULL;
            if (p != s_last_player || channels_base_chk != s_last_channels) {
                atomic_store(&g_song_length_ms, 0);
                atomic_store(&g_max_seen_ms, 0);
                atomic_store(&g_last_pos_ms, 0);
                s_last_player = p;
                s_last_channels = channels_base_chk;
                acc_flog(@"new song detected: player=%p channels=%p", p, channels_base_chk);
            }
            if ((s_diag_tick++ % 10) == 0) {
                acc_flog(@"twcalls gtod=%llu mtp=%llu gp=%llu rate=%.3f freeze=%d",
                         (unsigned long long)atomic_load(&g_tw_gtod_calls),
                         (unsigned long long)atomic_load(&g_tw_mtp_getpos_calls),
                         (unsigned long long)atomic_load(&g_tw_gp_update_calls),
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
    s_gp_last_real_us = 0;  // 回前台后重建 retime 基准
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
