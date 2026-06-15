// JudgeWindow.c — TrollStore: graft slot + classifier 替换（不写 __TEXT）
#include "JudgeWindow.h"
#include "ArcOffsets.h"

#include <stdint.h>
#include <limits.h>
#include <string.h>
#include <stdio.h>
#include <stdarg.h>

typedef int64_t (*score_hit_fn)(void *sk, void *note, int judge_type, int sub_type,
                                int32_t current_time, void *ctx);
typedef int64_t (*score_lost_fn)(void *sk, void *note, int32_t current_time);

static score_hit_fn g_score_hit = NULL;
static score_lost_fn g_score_lost = NULL;
static void **g_hook_slot = NULL;

static int s_max_ms = 25;
static int s_pure_ms = 50;
static int s_far_ms = 100;
static int s_lost_ms = 120;
static bool s_ready = false;
static char s_install_log[512];

const char *judge_window_install_log(void) {
    return s_install_log;
}

static void log_append(const char *fmt, ...) {
    size_t n = strlen(s_install_log);
    if (n >= sizeof(s_install_log) - 1) return;
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(s_install_log + n, sizeof(s_install_log) - n, fmt, ap);
    va_end(ap);
}

static bool insn_is_b(uint32_t insn) {
    return (insn >> 26) == 0x05u;
}

static void normalize_thresholds(int *max_ms, int *pure_ms, int *far_ms, int *lost_ms) {
    if (*max_ms < 1) *max_ms = 1;
    if (*max_ms > 2000) *max_ms = 2000;
    if (*pure_ms <= *max_ms) *pure_ms = *max_ms + 1;
    if (*pure_ms > 2000) *pure_ms = 2000;
    if (*far_ms <= *pure_ms) *far_ms = *pure_ms + 1;
    if (*far_ms > 2000) *far_ms = 2000;
    if (*lost_ms <= *far_ms) *lost_ms = *far_ms + 1;
    if (*lost_ms > 2000) *lost_ms = 2000;
}

static int32_t abs_i32(int32_t v) {
    return v < 0 ? -v : v;
}

// sub_100870FD0 主路径：dt = note+24 - note+32，|dt| 分档后调 score commit
static int64_t xrc_classify(void *gp, void *note, void *ctx) {
    if (!gp || !note || !g_score_hit || !g_score_lost) return 0;

    void *sk = *(void **)((char *)gp + 56);
    if (!sk) return 0;

    int32_t n24 = *(int32_t *)((char *)note + 24);
    int32_t n32 = *(int32_t *)((char *)note + 32);
    int32_t n40 = *(int32_t *)((char *)note + 40);
    int32_t signed_dt = n24 - n32;
    int32_t abs_dt = abs_i32(signed_dt);
    int sub_type = signed_dt < 0 ? 1 : 2;
    int32_t hit_time = n32;
    int32_t lost_time = n32 - n40;

    if (abs_dt <= s_max_ms)
        return g_score_hit(sk, note, 0, 0, hit_time, ctx);
    if (abs_dt <= s_pure_ms)
        return g_score_hit(sk, note, 1, sub_type, hit_time, ctx);
    if (abs_dt <= s_far_ms)
        return g_score_hit(sk, note, 2, sub_type, hit_time, ctx);
    if (abs_dt <= s_lost_ms)
        return g_score_lost(sk, note, lost_time);
    return 0;
}

bool judge_window_install(uint64_t image_base) {
    if (!image_base) return false;

    s_install_log[0] = '\0';
    s_ready = false;
    g_hook_slot = NULL;
    g_score_hit = NULL;
    g_score_lost = NULL;

    uint32_t entry = *(uint32_t *)(image_base + ARC_OFF_JUDGE_CLASSIFY);
    if (!insn_is_b(entry)) {
        log_append("no_graft(entry=0x%08x); ", entry);
        return false;
    }

    uint32_t tramp0 = *(uint32_t *)(image_base + ARC_OFF_JUDGE_TRAMP);
    if ((tramp0 & 0xFF000000u) != 0x90000000u) {
        log_append("bad_tramp(0x%08x); ", tramp0);
        return false;
    }

    g_hook_slot = (void **)(image_base + ARC_OFF_HOOK_SLOT);
    g_score_hit = (score_hit_fn)(image_base + ARC_OFF_SCORE_COMMIT_HIT);
    g_score_lost = (score_lost_fn)(image_base + ARC_OFF_SCORE_COMMIT_LOST);

    *g_hook_slot = (void *)xrc_classify;
    s_ready = true;
    log_append("graft_hook slot=0x%llx", (unsigned long long)ARC_OFF_HOOK_SLOT);
    return true;
}

bool judge_window_set_thresholds_ms(int max_ms, int pure_ms, int far_ms, int lost_ms) {
    if (!s_ready) return false;
    normalize_thresholds(&max_ms, &pure_ms, &far_ms, &lost_ms);
    s_max_ms = max_ms;
    s_pure_ms = pure_ms;
    s_far_ms = far_ms;
    s_lost_ms = lost_ms;
    return true;
}

bool judge_window_is_active(void) {
    return s_ready;
}

void judge_window_get_thresholds_ms(int *max_ms, int *pure_ms, int *far_ms, int *lost_ms) {
    if (max_ms) *max_ms = s_max_ms;
    if (pure_ms) *pure_ms = s_pure_ms;
    if (far_ms) *far_ms = s_far_ms;
    if (lost_ms) *lost_ms = s_lost_ms;
}

void judge_window_uninstall(void) {
    if (g_hook_slot) *g_hook_slot = NULL;
    s_ready = false;
}
