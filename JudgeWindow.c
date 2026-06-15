// JudgeWindow.c — graft slot（__data 扩展区）+ 从 tramp 解析槽位地址
#include "JudgeWindow.h"
#include "ArcOffsets.h"

#include <stdint.h>
#include <limits.h>
#include <string.h>
#include <stdio.h>
#include <stdarg.h>

typedef int64_t (*classify_fn)(void *gp, void *note, void *ctx);
typedef int64_t (*score_hit_fn)(void *sk, void *note, int judge_type, int sub_type,
                                int32_t current_time, void *ctx);
typedef int64_t (*score_lost_fn)(void *sk, void *note, int32_t current_time);

static classify_fn g_classify_resume = NULL;
static score_hit_fn g_score_hit = NULL;
static score_lost_fn g_score_lost = NULL;
static void **g_hook_slot = NULL;

static int s_max_ms = 25;
static int s_pure_ms = 50;
static int s_far_ms = 100;
static int s_lost_ms = 120;
static bool s_ready = false;
static char s_install_log[512];

static const char kSlotMagic[4] = {'X', 'R', 'C', 'H'};

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

static bool insn_is_adrp(uint32_t insn) {
    return (insn & 0x9F000000u) == 0x90000000u;
}

static bool insn_is_add_imm(uint32_t insn) {
    return (insn & 0xFF000000u) == 0x91000000u;
}

static bool insn_is_ldr_x64(uint32_t insn) {
    return (insn & 0xFFC00000u) == 0xF9400000u;
}

static uint64_t decode_adrp_target(uint32_t insn, uint64_t pc) {
    uint32_t immlo = (insn >> 29) & 3u;
    uint32_t immhi = (insn >> 5) & 0x7ffffu;
    int64_t imm = (int64_t)((immhi << 2) | immlo);
    if (imm & 0x100000) imm |= ~(int64_t)0x1fffff;
    return (pc & ~0xfffull) + (uint64_t)(imm << 12);
}

static void **resolve_slot_from_tramp(uint64_t image_base) {
    uint64_t pc = image_base + ARC_OFF_JUDGE_TRAMP;
    uint32_t w0 = *(uint32_t *)pc;
    if (!insn_is_adrp(w0)) return NULL;

    uint64_t addr = decode_adrp_target(w0, pc);
    pc += 4;

    uint32_t w1 = *(uint32_t *)pc;
    if (insn_is_add_imm(w1)) {
        addr += (uint64_t)((w1 >> 10) & 0xfffu);
        pc += 4;
    }

    uint32_t w2 = *(uint32_t *)pc;
    if (!insn_is_ldr_x64(w2)) return NULL;

    return (void **)addr;
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

static int64_t xrc_classify(void *gp, void *note, void *ctx) {
    if (!gp || !note) return 0;

    if (g_hook_slot && *g_hook_slot != (void *)xrc_classify)
        *g_hook_slot = (void *)xrc_classify;

    if (!g_score_hit || !g_score_lost) {
        if (g_classify_resume) return g_classify_resume(gp, note, ctx);
        return 0;
    }

    void *sk = *(void **)((char *)gp + 56);
    if (!sk) return 0;

    int32_t n24 = *(int32_t *)((char *)note + 24);
    int32_t n32 = *(int32_t *)((char *)note + 32);
    int32_t n40 = *(int32_t *)((char *)note + 40);
    int32_t signed_dt = n24 - n32;
    int32_t abs_dt = abs_i32(signed_dt);
    int sub_type = signed_dt < 0 ? 1 : 2;
    int32_t commit_time = n32 - n40;

    if (abs_dt <= s_max_ms)
        return g_score_hit(sk, note, 0, 0, commit_time, ctx);
    if (abs_dt <= s_pure_ms)
        return g_score_hit(sk, note, 1, sub_type, commit_time, ctx);
    if (abs_dt <= s_far_ms)
        return g_score_hit(sk, note, 2, sub_type, commit_time, ctx);
    if (abs_dt <= s_lost_ms)
        return g_score_lost(sk, note, commit_time);
    return 0;
}

bool judge_window_install(uint64_t image_base) {
    if (!image_base) return false;

    s_install_log[0] = '\0';
    s_ready = false;
    g_hook_slot = NULL;
    g_classify_resume = NULL;
    g_score_hit = NULL;
    g_score_lost = NULL;

    uint32_t entry = *(uint32_t *)(image_base + ARC_OFF_JUDGE_CLASSIFY);
    if (!insn_is_b(entry)) {
        log_append("no_graft(entry=0x%08x); ", entry);
        return false;
    }

    uint32_t tramp0 = *(uint32_t *)(image_base + ARC_OFF_JUDGE_TRAMP);
    if (!insn_is_adrp(tramp0)) {
        log_append("bad_tramp(0x%08x); ", tramp0);
        return false;
    }

    g_hook_slot = resolve_slot_from_tramp(image_base);
    if (!g_hook_slot) {
        log_append("tramp_slot_resolve_fail; ");
        return false;
    }

    g_classify_resume = (classify_fn)(image_base + ARC_OFF_JUDGE_CLASSIFY + 16);
    g_score_hit = (score_hit_fn)(image_base + ARC_OFF_SCORE_COMMIT_HIT);
    g_score_lost = (score_lost_fn)(image_base + ARC_OFF_SCORE_COMMIT_LOST);

    void *before = *g_hook_slot;
    const char *magic = (const char *)g_hook_slot - 8;
    if (memcmp(magic, kSlotMagic, 4) != 0)
        memcpy((void *)magic, kSlotMagic, 4);

    *g_hook_slot = (void *)xrc_classify;

    if (*g_hook_slot != (void *)xrc_classify) {
        log_append("slot_write_fail; ");
        return false;
    }

    s_ready = true;
    log_append("graft_ok slot=%p hook=%p prev=%p tramp=0x%08x magic=%.4s",
               (void *)g_hook_slot, (void *)xrc_classify, before, tramp0, magic);
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
