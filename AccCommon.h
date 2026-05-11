// AccCommon.h
// Shared declarations between Tweak.x and AccMenuController.x.
// All symbols defined here must be defined exactly once (in Tweak.x).
//
// Convention: globals keep their original names (g_/s_/etc); functions keep theirs.
// `static` qualifier is dropped on the definitions in Tweak.x; declarations here
// are `extern` (or none for functions).
#pragma once

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <stdatomic.h>
#import <stdint.h>
#import <sys/time.h>

// ====== constants known to AccMenuController ======
#define ARC_OFF_VT_LOGICNOTE_COUNT 5
#define ARC_OFF_LOGICNOTE_ISCOMPLETED (0x7E27B8ULL)

// ====== globals (defined in Tweak.x) ======
extern UIView *menuView;
extern BOOL toast;
extern BOOL buttonEnabled;
extern NSInteger rate_i;
extern NSInteger rate_count;
extern float *rates;            // heap-allocated array of rate_count floats

// time-warp / hook counters
extern _Atomic(int) g_tw_en_gtod;
extern _Atomic(uint64_t) g_tw_gtod_calls;
extern _Atomic(uint64_t) g_tw_gp_update_calls;
extern int (*s_orig_gettod)(struct timeval *, void *);
extern _Atomic(int32_t) g_tw_freeze_count;

// audio / chart state
extern _Atomic(uint32_t) g_last_pos_ms;
extern _Atomic(void *)   g_gameplay_instance;

// isCompleted hook diag
extern _Atomic(uint64_t) g_iscompleted_calls;
extern _Atomic(uint64_t) g_iscompleted_force_zero;
extern _Atomic(uint64_t) g_iscompleted_force_one;
extern _Atomic(int)      g_iscompleted_installed_count;
extern _Atomic(int)      g_iscompleted_vt_code[ARC_OFF_VT_LOGICNOTE_COUNT];
extern _Atomic(uint64_t) g_iscompleted_vt_seen[ARC_OFF_VT_LOGICNOTE_COUNT];
extern _Atomic(int32_t)  g_seek_target_ms;
extern _Atomic(uint64_t) g_rewind_until_us;

// ====== functions (defined in Tweak.x) ======
void acc_flog(NSString *fmt, ...);
void *get_player_or_resolve(void);
uint32_t player_get_progress_max_ms(void);
uint32_t player_get_position_ms_cached(void);
NSMutableDictionary *loadPrefDict(void);
void savePrefDict(NSDictionary *p);
void loadPref(void);
void player_seek_ms(uint32_t ms);
bool ptr_plausible(const void *p);
bool addr_readable(const void *p, size_t len);
double tw_get_rate(void);
uint64_t arc_image_base(void);
int clock_hook_ready_for_idx(int idx);
void time_warp_set_rate(double rate);

// External UI helpers from Tweak.x bootstrap (button reference is needed by menu show/hide)
@class WQSuspendView;
extern WQSuspendView *button;

// AccMenuController @interface lives inline in Tweak.x for now; this header
// only exposes globals/functions needed by it. Future split: move @interface
// here and define impl in AccMenuController.x.
@class AccMenuController;

