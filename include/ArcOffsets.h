// ArcOffsets.h — Arcaea iOS 6.13.10 (Arc-mobile) 已知偏移
// Image base (IDA): 0x100000000; 运行时 = arc_image_base() + offset
#pragma once

#include <stdint.h>

// ---- 变速 / seek ----
#define ARC_OFF_GET_REGISTRY       (0xC9D718ULL)
#define ARC_OFF_GET_CURRENT_SOUND  (0xEC094CULL)
#define ARC_OFF_GET_SOUND_LENGTH   (0xF2BB64ULL)
#define ARC_OFF_CH_GET_POSITION    (0xEC03ACULL)

#define ARC_OFF_MTP_VTABLE         (0x1312860ULL)
#define ARC_OFF_MTP_GETPOS         (0x846950ULL)
#define ARC_OFF_GP_VTABLE          (0x136E1C0ULL)
#define ARC_OFF_GP_UPDATE_FN       (0xB3AD70ULL)

// ---- 判定 classifier sub_100870FD0 ----
#define ARC_OFF_JUDGE_CLASSIFY     (0x870FD0ULL)
#define ARC_OFF_JUDGE_CALLER_A     (0x871514ULL)
#define ARC_OFF_JUDGE_CALLER_B     (0x871FE0ULL)

// graft_hook.py：tramp 在 __text 末尾 padding；槽位在 __swift56_hooks 段末（__DATA 可写）
#define ARC_OFF_JUDGE_TRAMP        (0x1039500ULL)
#define ARC_OFF_HOOK_SLOT          (0x149ABF8ULL)

// 八个 CMP 站点 — 仅 RE 参考 / 静态 patch_judge_static.py；graft 方案不再 runtime patch
// 默认 imm → 有效窗口 (与 ArcCreate Values 一致):
//   Max ±25ms  | Pure ±50ms | Far ±100ms | Lost ±120ms
// 分支 A (clock+45==1): CMP #26/51/101/121 + B.CC/B.CS
// 分支 B (另一 clock 路径): CMP #25/50/100/120 + B.HI
#define ARC_OFF_JUDGE_CMP_MAXPURE_A (0x87106CULL)
#define ARC_OFF_JUDGE_CMP_PURE_A    (0x871074ULL)
#define ARC_OFF_JUDGE_CMP_FAR_A     (0x87107CULL)
#define ARC_OFF_JUDGE_CMP_LOST_A    (0x871084ULL)
#define ARC_OFF_JUDGE_CMP_MAXPURE_B (0x8710D4ULL)
#define ARC_OFF_JUDGE_CMP_PURE_B    (0x871118ULL)
#define ARC_OFF_JUDGE_CMP_FAR_B     (0x87115CULL)
#define ARC_OFF_JUDGE_CMP_LOST_B    (0x871194ULL)

#define ARC_JUDGE_CMP_SITE_COUNT 8

// 默认 imm12 (仅作安装校验 fallback)
#define ARC_JUDGE_DEF_MAXPURE_A 26
#define ARC_JUDGE_DEF_PURE_A    51
#define ARC_JUDGE_DEF_FAR_A     101
#define ARC_JUDGE_DEF_LOST_A    121
#define ARC_JUDGE_DEF_MAXPURE_B 25
#define ARC_JUDGE_DEF_PURE_B    50
#define ARC_JUDGE_DEF_FAR_B     100
#define ARC_JUDGE_DEF_LOST_B    120

#define ARC_OFF_SCORE_COMMIT_HIT   (0x9C6B38ULL)
#define ARC_OFF_SCORE_COMMIT_LOST  (0x9C697CULL)
#define ARC_OFF_LOST_AUTO_JUDGE    (0x870344ULL)
