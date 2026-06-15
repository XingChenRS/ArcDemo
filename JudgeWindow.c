// JudgeWindow.c — TrollStore: patch sub_100870FD0 CMP imm12
// 策略: 整页解锁 → 批量写 CMP → 恢复 RX + icache（避免 4B remap 失败）

#include "JudgeWindow.h"
#include "ArcOffsets.h"

#include <mach/mach.h>
#include <sys/mman.h>
#include <stdint.h>
#include <limits.h>
#include <string.h>
#include <math.h>
#include <stdio.h>
#include <stdarg.h>
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

typedef enum {
    PATCH_NONE = 0,
    PATCH_MIRROR_PAGE,  // vm_remap 整页镜像写
    PATCH_COPY_PAGE,    // vm_protect COPY 原地写 (fdiv.net / geode)
    PATCH_RWX_PAGE,     // mprotect/vm_protect RWX 原地写
} PatchMode;

typedef struct {
    uintptr_t page;
    vm_address_t mirror; // PATCH_MIRROR_PAGE 时有效
} PageSlot;

static JudgeCmpSite s_sites[ARC_JUDGE_CMP_SITE_COUNT];
static PageSlot s_pages[4];
static int s_page_count = 0;
static PatchMode s_mode = PATCH_NONE;
static int s_max_ms = 25;
static int s_pure_ms = 50;
static int s_far_ms = 100;
static int s_lost_ms = 120;
static bool s_ready = false;
static char s_install_log[512];

#define JUDGE_PAGE_SIZE 0x4000u
#define JUDGE_PAGE_MASK (JUDGE_PAGE_SIZE - 1u)

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

static uintptr_t page_align(uintptr_t addr) {
    return addr & JUDGE_PAGE_MASK;
}

static uint32_t insn_set_imm12(uint32_t insn, uint32_t imm12) {
    return (insn & ~0x003FFC00u) | ((imm12 & 0xFFFu) << 10);
}

static bool insn_is_cmp_w_imm(uint32_t insn) {
    return (insn & 0xFF800000u) == 0x71000000u;
}

static int collect_pages(void) {
    s_page_count = 0;
    for (int i = 0; i < ARC_JUDGE_CMP_SITE_COUNT; i++) {
        if (!s_sites[i].insn) continue;
        uintptr_t page = page_align((uintptr_t)s_sites[i].insn);
        bool seen = false;
        for (int j = 0; j < s_page_count; j++) {
            if (s_pages[j].page == page) { seen = true; break; }
        }
        if (!seen && s_page_count < 4) {
            s_pages[s_page_count].page = page;
            s_pages[s_page_count].mirror = 0;
            s_page_count++;
        }
    }
    return s_page_count;
}

static bool page_unlock(PatchMode mode, PageSlot *ps) {
    uintptr_t page = ps->page;
    kern_return_t kr;
    switch (mode) {
    case PATCH_MIRROR_PAGE:
        ps->mirror = 0;
        vm_prot_t cur, max;
        kr = vm_remap(mach_task_self(), &ps->mirror, JUDGE_PAGE_SIZE, 0, VM_FLAGS_ANYWHERE,
                      mach_task_self(), (vm_address_t)page, FALSE, &cur, &max, VM_INHERIT_SHARE);
        if (kr != KERN_SUCCESS) {
            log_append("remap=0x%x ", kr);
            return false;
        }
        vm_address_t writable = ps->mirror;
        kr = vm_protect(mach_task_self(), writable, JUDGE_PAGE_SIZE, 0,
                        VM_PROT_READ | VM_PROT_WRITE);
        if (kr != KERN_SUCCESS) {
            log_append("mirror_prot=0x%x ", kr);
            vm_deallocate(mach_task_self(), ps->mirror, JUDGE_PAGE_SIZE);
            ps->mirror = 0;
            return false;
        }
        return true;
    case PATCH_COPY_PAGE:
        kr = vm_protect(mach_task_self(), (vm_address_t)page, JUDGE_PAGE_SIZE, 0,
                        VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY);
        if (kr != KERN_SUCCESS) log_append("copy=0x%x ", kr);
        return kr == KERN_SUCCESS;
    case PATCH_RWX_PAGE:
        if (mprotect((void *)page, JUDGE_PAGE_SIZE, PROT_READ | PROT_WRITE | PROT_EXEC) == 0)
            return true;
        kr = vm_protect(mach_task_self(), (vm_address_t)page, JUDGE_PAGE_SIZE, 0,
                        VM_PROT_READ | VM_PROT_WRITE | VM_PROT_EXECUTE);
        if (kr != KERN_SUCCESS) log_append("rwx=0x%x ", kr);
        return kr == KERN_SUCCESS;
    default:
        return false;
    }
}

static void page_lock(PatchMode mode, PageSlot *ps) {
    uintptr_t page = ps->page;
    sys_icache_invalidate((void *)page, JUDGE_PAGE_SIZE);
    switch (mode) {
    case PATCH_MIRROR_PAGE:
        if (ps->mirror) {
            vm_deallocate(mach_task_self(), ps->mirror, JUDGE_PAGE_SIZE);
            ps->mirror = 0;
        }
        break;
    case PATCH_COPY_PAGE:
        vm_protect(mach_task_self(), (vm_address_t)page, JUDGE_PAGE_SIZE, 0,
                   VM_PROT_READ | VM_PROT_EXECUTE);
        break;
    case PATCH_RWX_PAGE:
        mprotect((void *)page, JUDGE_PAGE_SIZE, PROT_READ | PROT_EXEC);
        vm_protect(mach_task_self(), (vm_address_t)page, JUDGE_PAGE_SIZE, 0,
                   VM_PROT_READ | VM_PROT_EXECUTE);
        break;
    default:
        break;
    }
}

static uint32_t *write_ptr(PatchMode mode, PageSlot *ps, uint32_t *target) {
    if (mode == PATCH_MIRROR_PAGE && ps->mirror)
        return (uint32_t *)(ps->mirror + ((uintptr_t)target - ps->page));
    return target;
}

static PageSlot *page_slot_for(uint32_t *insn) {
    uintptr_t page = page_align((uintptr_t)insn);
    for (int i = 0; i < s_page_count; i++) {
        if (s_pages[i].page == page) return &s_pages[i];
    }
    return NULL;
}

static bool probe_mode(PatchMode mode) {
    if (!s_sites[0].insn) return false;
    collect_pages();
    if (s_page_count == 0) return false;
    PageSlot *ps = &s_pages[0];
    if (!page_unlock(mode, ps)) return false;

    uint32_t *wp = write_ptr(mode, ps, s_sites[0].insn);
    uint32_t saved = *wp;
    *wp = saved;
    bool ok = insn_is_cmp_w_imm(*s_sites[0].insn);
    page_lock(mode, ps);
    return ok;
}

static const char *mode_name(PatchMode m) {
    switch (m) {
    case PATCH_MIRROR_PAGE: return "mirror_page";
    case PATCH_COPY_PAGE:   return "copy_page";
    case PATCH_RWX_PAGE:    return "rwx_page";
    default:                return "none";
    }
}

static bool patch_site_imm(int idx, uint32_t imm) {
    if (idx < 0 || idx >= ARC_JUDGE_CMP_SITE_COUNT || s_mode == PATCH_NONE) return false;
    JudgeCmpSite *site = &s_sites[idx];
    if (!site->insn || !insn_is_cmp_w_imm(site->orig)) return false;
    if (imm < 2) imm = 2;
    if (imm > 0xFFFu) imm = 0xFFFu;
    PageSlot *ps = page_slot_for(site->insn);
    if (!ps) return false;
    uint32_t patched = insn_set_imm12(site->orig, imm);
    uint32_t *wp = write_ptr(s_mode, ps, site->insn);
    *wp = patched;
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
    memset(s_pages, 0, sizeof(s_pages));
    s_page_count = 0;
    s_mode = PATCH_NONE;
    s_install_log[0] = '\0';
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
            log_append("%s bad_insn; ", meta->name);
    }

    if (ok >= 6) {
        static const PatchMode kTry[] = { PATCH_MIRROR_PAGE, PATCH_COPY_PAGE, PATCH_RWX_PAGE };
        for (int t = 0; t < 3; t++) {
            s_install_log[strlen(s_install_log)] = '\0';
            size_t mark = strlen(s_install_log);
            if (probe_mode(kTry[t])) {
                s_mode = kTry[t];
                break;
            }
            // 回滚本轮错误码，避免日志过长
            s_install_log[mark] = '\0';
        }
        if (s_mode == PATCH_NONE)
            log_append("patch_probe_fail; ");
    }

    log_append("cmp_ok=%d/%d patch=%s", ok, ARC_JUDGE_CMP_SITE_COUNT, mode_name(s_mode));
    s_ready = (ok >= 6) && (s_mode != PATCH_NONE);
    return s_ready;
}

bool judge_window_set_thresholds_ms(int max_ms, int pure_ms, int far_ms, int lost_ms) {
    if (!s_ready || s_mode == PATCH_NONE) return false;

    normalize_thresholds(&max_ms, &pure_ms, &far_ms, &lost_ms);
    s_max_ms = max_ms;
    s_pure_ms = pure_ms;
    s_far_ms = far_ms;
    s_lost_ms = lost_ms;

    collect_pages();
    for (int i = 0; i < s_page_count; i++) {
        if (!page_unlock(s_mode, &s_pages[i]))
            return false;
    }

    uint32_t a_imms[4] = {
        (uint32_t)max_ms + 1, (uint32_t)pure_ms + 1,
        (uint32_t)far_ms + 1, (uint32_t)lost_ms + 1,
    };
    uint32_t b_imms[4] = {
        (uint32_t)max_ms, (uint32_t)pure_ms,
        (uint32_t)far_ms, (uint32_t)lost_ms,
    };

    bool ok = true;
    for (int i = 0; i < 4; i++) {
        if (!patch_site_imm(i, a_imms[i])) ok = false;
        if (!patch_site_imm(i + 4, b_imms[i])) ok = false;
    }

    for (int i = 0; i < s_page_count; i++)
        page_lock(s_mode, &s_pages[i]);

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
