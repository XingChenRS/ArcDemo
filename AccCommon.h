// AccCommon.h
#pragma once

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <stdatomic.h>
#import <stdint.h>
#import <sys/time.h>

extern UIView *menuView;
extern BOOL toast;
extern BOOL buttonEnabled;
extern NSInteger rate_i;
extern NSInteger rate_count;
extern float *rates;
extern int judgeMaxMs;
extern int judgePureMs;
extern int judgeFarMs;
extern int judgeLostMs;

extern _Atomic(int32_t) g_tw_freeze_count;
extern int (*s_orig_gettod)(struct timeval *, void *);
extern _Atomic(uint32_t) g_last_pos_ms;
extern _Atomic(void *)   g_gameplay_instance;

NSString *arcConfigPath(void);
NSMutableDictionary *loadPrefDict(void);
void savePrefDict(NSDictionary *p);
void loadPref(void);

void acc_flog(NSString *fmt, ...);
void *get_player_or_resolve(void);
uint32_t player_get_progress_max_ms(void);
uint32_t player_get_position_ms_cached(void);
void player_seek_ms(uint32_t ms);
bool ptr_plausible(const void *p);
bool addr_readable(const void *p, size_t len);
double tw_get_rate(void);
uint64_t arc_image_base(void);
void time_warp_set_rate(double rate);

void normalizeJudgeThresholds(void);

@class WQSuspendView;
extern WQSuspendView *button;
@class AccMenuController;
