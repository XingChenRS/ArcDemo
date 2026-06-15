// JudgeWindow.c — TrollStore: in-place patch sub_100870FD0 CMP imm12 (no COW)

#include "JudgeWindow.h"
#include "ArcOffsets.h"

#include <mach/mach.h>
#include <stdint.h>
#include <limits.h>
#include <string.h>
#include <math.h>
#include <stdio.h>
#include <libkern/OSCacheControl.h>

typedef struct {
    uint64_t off;
    uint32_t def_imm;
    const char *name;
} JudgeCmpMeta;

static const JudgeCmpMeta kJudgeCmpMeta[ARC_JUDGE_CMP_SITE_COUNT] = {
    { ARC_OFF_JUDGE_CMP_MAXPURE_A, ARC_JUDGE_DEF_MAXPURE_A, "maxpure_A" },
    { ARC_OFF_JUDGE_CMP_PURE_A,    ARC_JUDGE_DEF_PURE_A,    "pure_A"    },
    { ARC_OFF_JUDGE_CMP_FAR_A,     ARC_JUDGE_DEF_FAR_A,     "far_A"     },
    { ARC_OFF_JUDGE_CMP_LOST_A,    ARC_JUDGE_DEF_LOST_A,    "lost_A"    },
    { ARC_OFF_JUDGE_CMP_MAXPURE_B, ARC_JUDGE_DEF_MAXPURE_B, "maxpure_B" },
    { ARC_OFF_JUDGE_CMP_PURE_B,    ARC_JUDGE_DEF_PURE_B,    "pure_B"    },
    { ARC_OFF_JUDGE_CMP_FAR_B,     ARC_JUDGE_DEF_FAR_B,     "far_B"     },
    { ARC_OFF_JUDGE_CMP_LOST_B,    ARC_JUDGE_DEF_LOST_B,    "lost_B"    },
};

typedef struct {
    uint32_t *insn;
    uint32_t orig;
} JudgeCmpSite;

static JudgeCmpSite s_sites[ARC_JUDGE_CMP_SITE_COUNT];
static int s_max_ms = 25;
static int s_pure_ms = 50;
static int s_far_ms = 100;
static int s_lost_ms = 120;
static bool s_ready = false;
static bool s_inplace_ok = false;
static char s_install_log[512];

#define JUDGE_PAGE_SIZE 0x4000u
#define JUDGE_PAGE_MASK (~(uintptr_t)(JUDGE_PAGE_SIZE - 1))

const char *judge_window_install_log(void) {
    return s_install_log;
}

static uintptr_t page_align(uintptr_t addr) {
    return addr & JUDGE_PAGE_MASK;
}

// TrollStore: 原地 RWX，禁止 VM_PROT_COPY（COW 页在 iOS16 上取指会 SIGBUS）
static bool page_unlock_inplace(uintptr_t page) {
    if (mprotect((void *)page, JUDGE_PAGE_SIZE, PROT_READ | PROT_WRITE | PROT_EXEC) == 0)
        return true;
    kern_return_t kr = vm_protect(mach_task_self(), (vm_address_t)page, JUDGE_PAGE_SIZE, 0,
                                 VM_PROT_READ | VM_PROT_WRITE | VM_PROT_EXECUTE);
    return kr == KERN_SUCCESS;
}

static void page_lock_exec(uintptr_t page) {
    if (mprotect((void *)page, JUDGE_PAGE_SIZE, PROT_READ | PROT_EXEC) == 0)
        return;
    vm_protect(mach_task_self(), (vm_address_t)page, JUDGE_PAGE_SIZE, 0,
               VM_PROT_READ | VM_PROT_EXECUTE);
}

static int collect_unique_pages(uintptr_t *pages, int max_pages) {
    int n = 0;
    for (int i = 0; i < ARC_JUDGE_CMP_SITE_COUNT; i++) {
        if (!s_sites[i].insn) continue;
        uintptr_t page = page_align((uintptr_t)s_sites[i].insn);
        bool seen = false;
        for (int j = 0; j < n; j++) {
            if (pages[j] == page) { seen = true; break; }
        }
        if (!seen && n < max_pages)
            pages[n++] = page;
    }
    return n;
}

static void flush_insn_range(uintptr_t lo, uintptr_t hi) {
    if (lo < hi)
        sys_icache_invalidate((void *)lo, hi - lo);
}

static uint32_t insn_set_imm12(uint32_t insn, uint32_t imm12) {
    return (insn & ~0x003FFC00u) | ((imm12 & 0xFFFu) << 10);
}

static bool insn_is_cmp_w_imm(uint32_t insn) {
    return (insn & 0xFF800000u) == 0x71000000u;
}

static bool probe_inplace_write(void) {
    if (!s_sites[0].insn) return false;
    uintptr_t page = page_align((uintptr_t)s_sites[0].insn);
    if (!page_unlock_inplace(page)) return false;
    uint32_t *p = s_sites[0].insn;
    uint32_t saved = *p;
    *p = saved;
    flush_insn_range((uintptr_t)p, (uintptr_t)p + sizeof(uint32_t));
    page_lock_exec(page);
    return insn_is_cmp_w_imm(*p);
}

static bool patch_site_imm(int idx, uint32_t imm) {
    if (idx < 0 || idx >= ARC_JUDGE_CMP_SITE_COUNT) return false;
    JudgeCmpSite *site = &s_sites[idx];
    if (!site->insn || !insn_is_cmp_w_imm(site->orig)) return false;
    if (imm < 2) imm = 2;
    if (imm > 0xFFFu) imm = 0xFFFu;
    uint32_t patched = insn_set_imm12(site->orig, imm);
    *site->insn = patched;
    site->orig = patched;
    return true;
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

bool judge_window_install(uint64_t image_base) {
    if (!image_base) return false;
    memset(s_sites, 0, sizeof(s_sites));
    s_install_log[0] = '\0';
    s_inplace_ok = false;
    int ok = 0;

    for (int i = 0; i < ARC_JUDGE_CMP_SITE_COUNT; i++) {
        const JudgeCmpMeta *meta = &kJudgeCmpMeta[i];
        uint32_t *p = (uint32_t *)(image_base + meta->off);
        uint32_t orig = *p;
        s_sites[i].insn = p;
        s_sites[i].orig = orig;
        if (insn_is_cmp_w_imm(orig))
            ok++;
        else
            snprintf(s_install_log + strlen(s_install_log),
                     sizeof(s_install_log) - strlen(s_install_log),
                     "%s bad_insn; ", meta->name);
    }

    if (ok >= 6) {
        s_inplace_ok = probe_inplace_write();
        if (!s_inplace_ok)
            snprintf(s_install_log + strlen(s_install_log),
                     sizeof(s_install_log) - strlen(s_install_log),
                     " inplace_fail; ");
    }

    snprintf(s_install_log + strlen(s_install_log),
             sizeof(s_install_log) - strlen(s_install_log),
             "cmp_ok=%d/%d inplace=%s", ok, ARC_JUDGE_CMP_SITE_COUNT,
             s_inplace_ok ? "yes" : "no");

    s_ready = (ok >= 6) && s_inplace_ok;
    return s_ready;
}

bool judge_window_set_thresholds_ms(int max_ms, int pure_ms, int far_ms, int lost_ms) {
    if (!s_ready || !s_inplace_ok) return false;

    normalize_thresholds(&max_ms, &pure_ms, &far_ms, &lost_ms);
    s_max_ms = max_ms;
    s_pure_ms = pure_ms;
    s_far_ms = far_ms;
    s_lost_ms = lost_ms;

    uintptr_t pages[4];
    int page_count = collect_unique_pages(pages, 4);
    for (int i = 0; i < page_count; i++) {
        if (!page_unlock_inplace(pages[i]))
            return false;
    }

    uintptr_t lo = UINTPTR_MAX, hi = 0;
    for (int i = 0; i < ARC_JUDGE_CMP_SITE_COUNT; i++) {
        if (!s_sites[i].insn) continue;
        uintptr_t a = (uintptr_t)s_sites[i].insn;
        if (a < lo) lo = a;
        if (a + sizeof(uint32_t) > hi) hi = a + sizeof(uint32_t);
    }

    uint32_t a_imms[4] = {
        (uint32_t)max_ms + 1,
        (uint32_t)pure_ms + 1,
        (uint32_t)far_ms + 1,
        (uint32_t)lost_ms + 1,
    };
    uint32_t b_imms[4] = {
        (uint32_t)max_ms,
        (uint32_t)pure_ms,
        (uint32_t)far_ms,
        (uint32_t)lost_ms,
    };

    bool ok = true;
    for (int i = 0; i < 4; i++) {
        if (!patch_site_imm(i, a_imms[i])) ok = false;
        if (!patch_site_imm(i + 4, b_imms[i])) ok = false;
    }

    flush_insn_range(lo, hi);
    for (int i = 0; i < page_count; i++)
        page_lock_exec(pages[i]);

    return ok;
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
