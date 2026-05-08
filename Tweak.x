// AccDemoArcaea / Tweak.x
// Fork of brendonjkding/accDemo, Arcaea-only, single-binary, in-game menu.
//
// 阶段 A：保�?Substrate 调用�?hookf / %hook / %init），便于 TrollStore + ellekit
//         直接装载验证。后续阶�?B 会替换为 fishhook + Method Swizzle，去 Substrate 依赖�?

#import <substrate.h>
#import <time.h>
#import <dlfcn.h>
#import <mach-o/dyld.h>
#import <stdatomic.h>
#import <UIKit/UIKit.h>

#import "dobby.h"

extern UIApplication *UIApp;

#import "SuspendView/WQSuspendView.h"
#import "WHToast/WHToast.h"

// forward decl: 文件末尾定义，但中部诊断需要用
static void acc_flog(NSString *fmt, ...) NS_FORMAT_FUNCTION(1, 2);

typedef NS_ENUM(NSInteger, AccMode) {
    kModeClockGetTime = 0,   // Arcaea 默认（cocos2d-x 时基�?
    kModeGetTimeOfDay = 1,   // 备用
};

#pragma mark - global

static float    *rates = NULL;
static NSInteger rate_i = 0;
static NSInteger rate_count = 0;

static AccMode  mode = kModeClockGetTime;
static BOOL     buttonEnabled = YES;
static BOOL     toast = YES;

// 时基注入状�?
static time_t       pre_sec, true_pre_sec;
static suseconds_t  pre_usec, true_pre_usec;

static WQSuspendView *button = nil;
static UIView        *menuView = nil;

#define USec_Scale (1000000LL)
#define NSec_Scale (1000000000LL)

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
static get_position_ms_fn   orig_get_position_ms = NULL;
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

static uint32_t hooked_get_position_ms(void *self, int channel) {
    uint32_t ret = orig_get_position_ms(self, channel);
    if (channel == 0) {
        atomic_store(&g_bgmPlayer, self);
        atomic_store(&g_last_pos_ms, ret);
        uint32_t prev = atomic_load(&g_max_seen_ms);
        if (ret > prev) atomic_store(&g_max_seen_ms, ret);
        try_capture_song_length(self);
    }
    return ret;
}

// 主动通过 registry �?MTP（不需要等 hook 触发�?
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
    orig_get_position_ms = (get_position_ms_fn)(base + ARC_OFF_GET_POSITION_MS);
    NSLog(@"[AccDemoArcaea] getPositionMs (read-only) @ %p", (void *)orig_get_position_ms);

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

static void player_seek_ms(uint32_t ms) {
    void *self = get_player_or_resolve();
    if (!self) return;
    typedef void (*seek_fn)(void *, uint32_t, int);
    seek_fn fn = (seek_fn)_player_vt_slot(self, 0x40); // slot 8 = seekTo(this, ms, channel)
    if (fn) fn(self, ms, 0);
    // seek 后重新应用倍率（FMOD seek 可能重置 channel 频率）
    apply_speed_to_all_channels();
}

static void player_set_paused(BOOL paused) {
    void *self = get_player_or_resolve();
    if (!self) return;
    // 修正：vtable[6] = setPaused(this, paused, channel)
    typedef void (*set_paused_fn)(void *, int, int);
    set_paused_fn fn = (set_paused_fn)_player_vt_slot(self, 0x30); // slot 6
    if (fn) fn(self, paused ? 1 : 0, 0);
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
    if (!p[@"mode"])          p[@"mode"]          = @(kModeClockGetTime);
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
    mode          = (AccMode)[prefs[@"mode"] intValue];

    NSArray *speedKeys = prefs[@"speedKeys"];
    rate_count = speedKeys.count;
    if (rates) { free(rates); rates = NULL; }
    rates = (float *)malloc(sizeof(float) * rate_count);
    NSInteger i = 0;
    for (NSString *k in speedKeys) rates[i++] = [prefs[k] floatValue];
    if (rate_i >= rate_count) rate_i = 0;

    if (button) [button setHidden:!buttonEnabled];
}

#pragma mark - hook: gettimeofday

%group gettimeofday
%hookf(int, gettimeofday, struct timeval *tv, struct timezone *tz) {
    int ret = %orig(tv, tz);
    if (!ret) {
        if (!pre_sec) {
            pre_sec = tv->tv_sec; true_pre_sec = tv->tv_sec;
            pre_usec = tv->tv_usec; true_pre_usec = tv->tv_usec;
        } else {
            int64_t cur = tv->tv_sec * USec_Scale + tv->tv_usec;
            int64_t prv = true_pre_sec * USec_Scale + true_pre_usec;
            int64_t invl = (int64_t)((cur - prv) * rates[rate_i]);
            int64_t out = pre_sec * USec_Scale + pre_usec + invl;
            true_pre_sec = tv->tv_sec; true_pre_usec = tv->tv_usec;
            tv->tv_sec  = out / USec_Scale;
            tv->tv_usec = out % USec_Scale;
            pre_sec = tv->tv_sec; pre_usec = tv->tv_usec;
        }
    }
    return ret;
}
%end

static void hook_gettimeofday(void) {
    void *libSystem = dlopen("/usr/lib/libSystem.dylib", RTLD_NOLOAD);
    void *fn = dlsym(libSystem, "gettimeofday");
    %init(gettimeofday, gettimeofday = fn);
}

#pragma mark - hook: clock_gettime

%group clock_gettime
%hookf(int, clock_gettime, clockid_t clk_id, struct timespec *tp) {
    int ret = %orig(clk_id, tp);
    if (!ret) {
        if (!pre_sec) {
            pre_sec = tp->tv_sec; true_pre_sec = tp->tv_sec;
            pre_usec = tp->tv_nsec; true_pre_usec = tp->tv_nsec;
        } else {
            int64_t cur = tp->tv_sec * NSec_Scale + tp->tv_nsec;
            int64_t prv = true_pre_sec * NSec_Scale + true_pre_usec;
            int64_t invl = (int64_t)((cur - prv) * rates[rate_i]);
            int64_t out = pre_sec * NSec_Scale + pre_usec + invl;
            true_pre_sec = tp->tv_sec; true_pre_usec = tp->tv_nsec;
            tp->tv_sec  = out / NSec_Scale;
            tp->tv_nsec = out % NSec_Scale;
            pre_sec = tp->tv_sec; pre_usec = tp->tv_nsec;
        }
    }
    return ret;
}
%end

static void hook_clock_gettime(void) {
    void *libSystem = dlopen("/usr/lib/libSystem.dylib", RTLD_NOLOAD);
    void *fn = dlsym(libSystem, "clock_gettime");
    %init(clock_gettime, clock_gettime = fn);
}

static void initHook(void) {
    switch (mode) {
        case kModeGetTimeOfDay: hook_gettimeofday(); break;
        case kModeClockGetTime:
        default:                hook_clock_gettime(); break;
    }
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
    title.text = @"AccDemoArcaea";
    title.font = [UIFont boldSystemFontOfSize:18];
    title.textColor = [UIColor blackColor];
    [card addSubview:title];
    y += 30;

    // mode
    UILabel *modeLbl = [[UILabel alloc] initWithFrame:CGRectMake(12, y, innerW, 18)];
    modeLbl.text = @"Time Source";
    modeLbl.font = [UIFont systemFontOfSize:13];
    modeLbl.textColor = [UIColor darkGrayColor];
    [card addSubview:modeLbl];
    y += 20;

    UISegmentedControl *seg = [[UISegmentedControl alloc] initWithItems:@[@"clock_gettime", @"gettimeofday"]];
    seg.frame = CGRectMake(12, y, innerW, 28);
    seg.selectedSegmentIndex = mode;
    [seg addTarget:self action:@selector(modeChanged:) forControlEvents:UIControlEventValueChanged];
    [card addSubview:seg];
    y += 36;

    // ---- BGM player live controls (only meaningful while playing) ----
    BOOL playerReady = (get_player_or_resolve() != NULL);

    UILabel *playerHdr = [[UILabel alloc] initWithFrame:CGRectMake(12, y, innerW, 18)];
    playerHdr.text = playerReady ? @"BGM (live)" : @"BGM (waiting for playback...)";
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
    pauseLbl.text = @"Pause BGM";
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
    toastLbl.text = @"Toast on switch";
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
    speedHdr.text = @"Speeds (tap row to select; long-press to delete)";
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
    [addBtn setTitle:@"+ Add Speed" forState:UIControlStateNormal];
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
        lbl.text = [NSString stringWithFormat:@"%u.%03us / %u.%03us",
                    cur / 1000u, cur % 1000u,
                    maxMs / 1000u, maxMs % 1000u];
    }
    if (self.pauseSwitch && !self.pauseSwitch.enabled && get_player_or_resolve()) {
        self.pauseSwitch.enabled = YES;
    }
}

- (void)modeChanged:(UISegmentedControl *)s {
    NSMutableDictionary *p = loadPrefDict();
    p[@"mode"] = @(s.selectedSegmentIndex);
    savePrefDict(p);
    loadPref();
    // 注意：模�?hook 只在 ctor 安装一次，运行期切换需重启游戏
    if (toast) [WHToast showMessage:@"Restart app for mode change" duration:1.5 finishHandler:^{}];
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
        apply_speed_to_all_channels();
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
        // 后台轮询：不断给 channel 应用当前倍率（安全：setFrequency 是 FMOD 公开 API，不写 text）
        // 第一次进歌曲时会自动捕获 base_freq；之后每次倍率切换由 UI 触发，但 seek/重启歌曲会重置
        // FMOD 频率，所以这里也要兜底重新 apply。
        [NSTimer scheduledTimerWithTimeInterval:0.5 repeats:YES block:^(NSTimer *t) {
            apply_speed_to_all_channels();
        }];
        acc_flog(@"doBootstrap done");
    });
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
    // 兜底：如果 ctor 在 UIApplicationDidFinishLaunching 之后才跑（理论上不会，但
    // 注入工具如果用 LC_LOAD_WEAK_DYLIB / 延迟加载可能错过通知），3 秒后强制走一次
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        acc_flog(@"3s fallback bootstrap");
        doBootstrap();
    });
}
