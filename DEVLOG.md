# xrc-arcdemo Devlog

---

## 项目目标

将 [accDemo](https://github.com/brendonjkding/accDemo) 改造为针对 Arcaea iOS 的免越狱 dylib，支持变速、seek、练习。

---

## 当前状态 (v6.6, 2026-05-12)

### v6.6 范围收敛 — 拆掉所有 replay 实验性 hook

**最终决定**: Arcaea iOS 闭源二进制无法实现 ArcCreate 那种 `ResetJudgeTo(timing)` 的"无状态重派生"语义
(每个 Tap/Hold/Arc/ArcTap 内部都有自己的 tick 计数器、segment 索引、距离缓存等等私有 state,
RE 全部并安全清零的工作量在 sideload 限制下不现实, 强行做会触发 use-after-free / 崩溃)。

所以 v6.6 把 v5/v6 attempt 全部回滚, 只保留两件事:

1. **变速**: `gettimeofday` fishhook + `GP.update` vtable swizzle 调 `_gp_retime_logic_clock`。
2. **Seek**: 仅做两个动作 — 音频跳 (FMOD setPosition) + 谱面 clock 偏移 (logic+48 的 chart-ms 直接写)。
   跳过的 note 由游戏自身的 `sub_100870344` 路径自动判 lost; **已演奏过的 note 不会重现**,
   想重玩请用游戏内 Retry。

#### 拆除清单 (Tweak.x)
| 模块 | v6.5 状态 | v6.6 |
|------|-----------|------|
| `LogicNote::isCompleted` vtable swizzle (5 个 vtable) | 强制返回 0 (rewind grace window) | **移除** (define / 全局变量 / hook 函数 / install loop 全删) |
| `tw_gp_update` 内 judge-window settings 一次性 dump | 一次性 RE 探测 | **移除** |
| `player_seek_ms` 步骤 (a) 清空活跃音符列表 + release 引用 | 强制刷新空间查询 | **移除** (release_fn 解引用导致 UAF) |
| `player_seek_ms` 步骤 (b) 重新激活所有音轨 byte[0]=1 | 复活已死 track | **移除** (可能复活已被释放的 track) |
| `player_seek_ms` 步骤 (c) 清空事件队列 | | **移除** |
| `player_seek_ms` 步骤 (d) 清除结束标志 | | **移除** |
| `player_seek_ms` 步骤 (e) sk 重置 (combo/score/PFL/late/early) | v6.5 修好布局 | **移除** (无 replay 就没必要清, 留着旧数也是可控状态) |
| `g_seek_target_ms` / `g_rewind_until_us` 等 replay 相关全局 | | **移除** |
| 诊断面板 isComp 行 / vtcodes / seekTgt | | **移除** |

#### 已确认安全的事 (前一次 RE 留作记录)
- `sk` 重置本身路径安全 — `sub_100A7DFC4` (HUD syncer) / `sub_100A7E71C` / `sub_100A7DD20` /
  `sub_100870344` 各自反编后无 UAF, 把 sk 字段写 0 不会引发崩溃。
- 所以前向 seek 崩溃**不在 (e) 步**, 真正凶手是 (a) 步的 `release_fn(0xDB1A28)` 解 active-list 引用。
- 知道这一点之后我们仍然选择把 (e) 一起删 — 因为没有 replay 它无意义, 越少动 sk 越稳。

#### UI 汉化 (本次)
- "Arcaea Speed (XRC)" → "Arcaea 变速 (XRC)"
- "Audio: ... | Chart: ... | Visual: ..." → 中文架构说明 (保留 GP.update / FMOD 等技术术语)
- "BGM Control" / "BGM (waiting...)" → "BGM 控制" / "BGM (等待中...)"
- "Show toast on rate change" → "切换倍率时提示"
- "Hook (ON=warp at rate)" → "Hook 状态 (开 = 按倍率 warp)"
- "GP.update (chart retime)" → "GP.update (谱面 retime)"
- "Time domains (live)" → "时间域 (实时)"
- "Speed (tap=select, hold=delete)" → "倍率 (单击=选择, 长按=删除)"
- "+ Add speed" → "+ 添加倍率"
- "Close" → "关闭"
- toast `(tap2x=menu)` → `(双击打开菜单)`

#### 诊断面板瘦身
旧:
```
rate / freeze / rwnd / real-warp-drift / mach-audio-chart / Δ
isComp inst=N [OOOOO] calls=... z=... o=...
seekTgt=NNNms
```
新:
```
rate / freeze
real-warp-drift
mach-audio-chart
Δ(chart-audio)
```

#### 验证结论 (与 v6.5 共享)
- ✅ 变速 (0.6× / 0.8× / 1.0× / 1.25× / 1.5×): 音频/谱面/视觉三域同步 OK
- ✅ 前向 seek + 后向 seek: 不崩溃 (因为没在动音符状态了)
- ⚠ seek 之后**已判定的音符不会重现** — 这是有意为之的范围, 想重玩请用 Retry
- ✅ 判定窗口完整 (没动 settings)
- ✅ HP / 段位评级 / Pure-Far-Lost 计数与原版一致

#### 参考资料
- 判定窗口逆向笔记: [arcmodwiki/docs/ios-judgement-windows.md](../arcmodwiki/docs/ios-judgement-windows.md)
- ArcCreate 对比 (`ChartService.ResetJudge` / `TimingGroup.ResetJudgeTo`): 验证了 source-level 重派生在闭源二进制上的不可行性。

---

## 历史: v6.5 (2026-05-12)

### v6.5 改动 — 修复 seek-replay sk 重置 (布局已 RE 正确)

`player_seek_ms` 步骤 (e) 重新加回, 这次使用反编验证后的完整偏移集合
(参见下方 ScoreKeeper 真布局表)。关键修复点 = sk+104 (far_count) 与
sk+128..140 (late/early 全套) 之前 v6.3 全漏了, 这才是开局即结束的真因。
另外 logic+756/760/812 (UI 缓存) 也一并清零, 否则下一帧 sub_100A7DD20
触发条件 `combo != cached_combo` 会刷一次旧数。

### v6.5 RE 收获 — 判定窗口入口已锁定 (但 iOS sideload 直接 patch 不可行)

`sub_10086EE70` (LogicNoteGroup tick, 由 sub_10086E728 调用) 入口逻辑:

```c
if (sub_100868E28(*(GP+0x28))) {           // = *(BYTE)(chart+272), 默认 0
    v91 = (*(*(*(GP+0x20))[0x268])[0xE0])(...);  // late 自定义
    v90 = (*(*(*(GP+0x20))[0x268])[0xE0])(...);  // early 自定义
} else {
    v90 = 300;   // 默认 early-window
    v91 = 700;   // 默认 late-window
}
// ...
v66 = (int)((v65 - v91) / 10000.0);   // 判定窗下界 (screen-y 单位)
v67 = (int)((v65 + *(int*)(a1+24)) / 10000.0);
v68 = (int)((v85[i] - v91) / 10000.0);
v81 = (LogicArcNote ? v91 : v90);     // arc 用 late, tap 用 early
```

**默认值在 __TEXT 写死**:
- `0x10086EF04: MOV W9, #0x2BC (700)`  late-window
- `0x10086EF08: MOV W8, #0x12C (300)`  early-window

**为什么不能直接 patch**: Tweak.x:181 的注释已说明 — iOS 16 sideload 下
`mprotect(rwx)` / `vm_protect VM_PROT_COPY` 在 __TEXT 上会破坏 AMFI/CoreTrust
的 page seal, 其它线程触发该页时会被 EXC_BAD_ACCESS (Instruction Abort) 干掉。
__DATA/__DATA_CONST 写就没问题 (vtable swizzle 是这么做的)。

**v6.6 计划 — vtable 劫持方案**:
- chart 实例 +272 字节有个 `use_custom_window` flag, 设为 1 时走自定义分支
- 自定义分支调 `(*(*(GP+0x20))[0x268])[0xE0]()` 取 float late/early
- 实现路径:
  1. 在 GP.update hook 里捕获 chart 实例 (a1+0x28 deref)
  2. 设 chart+272 = 1 强制走自定义分支
  3. swizzle `*(chart+0x268)` 指向的对象的 vtable[0xE0/8],
     替换成我们的 stub 返回 `g_judge_user_*_window_x100 / 100.0f`
  4. UI 加 slider: pure 缩放 0.5..2.0x
- 需要先抓一次实例摸清楚 `*(chart+0x268)` 是什么类 (类成员 settings 指针?
  还是某个 singleton?), 然后才能确认 vtable swizzle 是否安全 (单实例还是
  多实例共享 vtable, 一改全改是否有副作用)。

### 已确认 ScoreKeeper 真布局

详见下方 "ScoreKeeper 真布局 (供 v6.5 重新加回 seek 重置使用)" 一节。

---

## 历史 v6.4 — 删除音频 hook + 回滚 ScoreKeeper 重置 (作废)

**删除的代码:**
- `apply_speed_to_all_channels` (FMOD `Channel::setFrequency` 调用)
- `player_collect_channels` (枚举 channel 表)
- `g_base_freq[ARC_MAX_CHANNELS]`, `g_ch_set_frequency`, `g_ch_get_frequency` 及对应类型定义
- `ARC_OFF_CH_SET_FREQUENCY`, `ARC_OFF_CH_GET_FREQUENCY` (offsets 不再需要)
- `g_audio_meas_*`, `s_audio_meas_*` (rate 测量全套)
- `tw_mtp_getpos` 里的 500ms 滑窗校准块
- `time_warp_set_rate` 里的 `apply_speed_to_all_channels()` 调用
- `player_seek_ms` 里的 `apply_speed_to_all_channels()` 调用
- 0.5s NSTimer 里的 `apply_speed_to_all_channels()` + base_freq 重置
- 面板 `audio.meas X.XXXx N=N` 行 (替换为 `Δ(chart-audio) Nms`)

**回滚的代码:**
- `player_seek_ms` 步骤 (e) ScoreKeeper 重置整段。原因:
  实测开始游戏后第一批音符出现时直接跳结算+0分。说明我标的 sk[+92]/[+96]/[+100]/[+104]/[+108]
  里至少有一个其实是**总谱面 note 数**之类的不变量,被零化后下一帧 `judged>=total`
  立即触发结束。需要重新反汇编 `sub_100A7DFC4` 的 score-update 入口确认每个偏移
  的真实语义。**注意: 以前 seek-replay 没崩(只是计分不重置)是因为根本没动 sk!**

**保留的:**
- 仅两个真 hook: `gettimeofday` (fishhook) + Gameplay vtable[update] (PAC vtable swizzle)
- LogicNote `isCompleted` vtable swizzle (5 子类) 用于 seek-replay 让 note 重出
- MTP `getPosition` vtable swizzle: **只读取**,作为进度条 + diag 数据源
- MTP `seekTo` vtable 调用: `player_seek_ms` 触发
- 谱面端 `_gp_retime_logic_clock` 独立 rate 推进 (不绑 audio)

**遗留问题:**
- 音画不同步 (audio 始终 1.0x, chart 按 rate)。用户决定接受/搁置。
- ScoreKeeper 真实布局未知, seek-replay 无法重置计分。

### ScoreKeeper 真布局 (供 v6.5 重新加回 seek 重置使用)

来源: 反汇编 `sub_100A7DFC4` (UI updater) + `sub_100A7E71C` (judge label updater)。
后者按 `pureLabel/farLabel/lostLabel/earlyLabel/lateLabel` 字符串 100% 锁定语义。

| 偏移 | 类型 | 字段 | 备注 |
|---|---|---|---|
| sk+20  | i32 | score_displayed | UI updater 写回 a1+760 |
| sk+28  | f32 | HP | |
| sk+76  | f32 | HP_max | |
| sk+92  | i32 | combo | UI 比对 a1+756 触发 sub_100A7DD20 |
| sk+96  | i32 | max_pure_count | sub_1009C6B38 case 0 自增; PM 起始分公式里作为 `+max_pure×1` 奖励加到投影分上 (原v6.5 误写为 score_raw，v6.6 修正) |
| sk+100 | i32 | pure_count | "pureLabel-fullnolocalize" |
| sk+104 | i32 | far_count | "farLabel" |
| sk+108 | i32 | lost_count | "lostLabel" |
| sk+128 | i32 | late_count_in_pure | "lateLabel" 默认分支 |
| sk+132 | i32 | early_count_in_pure | "earlyLabel" 默认分支 |
| sk+136 | i32 | late_count_in_max_pure | "max-pure" 模式叠加 |
| sk+140 | i32 | early_count_in_max_pure | "max-pure" 模式叠加 |

总 notes 不在 sk 内, 通过 `sub_1009C756C(sk) = *(*(sk+176)+184)` 从 chart_data 读。
sk 真实大小 ≥ 144 字节, v6.3 用 `addr_readable(sk, 128)` 范围都不够。

**v6.3 bug 复盘**: 代码漏清 sk+104(far) 与 sk+128..140(late/early 全套)。
重置后 UI updater 算 v14 = pure(0)+far(旧)+lost(0) = 旧 far, 然后
sub_100A7E71C 触发条件 `judged != cached_total` 仍然成立, 后续帧
进入异常分支 (具体怎么连到 a3+316=1 song-end 还需进一步追)。

**v6.5 正确重置序列** (待加):
```c
*(int32_t *)((char*)sk + 20)  = 0;  // score
*(int32_t *)((char*)sk + 92)  = 0;  // combo
*(int32_t *)((char*)sk + 96)  = 0;  // max_pure_count (原v6.5 误注为 score_raw, v6.6 订正)
*(int32_t *)((char*)sk + 100) = 0;  // pure
*(int32_t *)((char*)sk + 104) = 0;  // far  <-- v6.3 漏了
*(int32_t *)((char*)sk + 108) = 0;  // lost
*(int32_t *)((char*)sk + 128) = 0;  // late_pure
*(int32_t *)((char*)sk + 132) = 0;  // early_pure
*(int32_t *)((char*)sk + 136) = 0;  // late_max_pure
*(int32_t *)((char*)sk + 140) = 0;  // early_max_pure
// 同时 a1+756=0, a1+760=0, a1+812=0 (UI updater 缓存), a1+816?
```

---

## 历史 v6.3.1 (作废)

### v6.3.1 改动 — 回退 chart slave, 仅保留 score-keeper reset

用户反馈: chart slave 到 audio 任何形式都会引入延迟或抽搐 (FMOD `getPos`
ms 量化 + 帧间不均匀 + 量化往复, 即使 ≥3ms 阈值仍然会肉眼可见跳)。
**变速回到 v6.2 思路**: chart 端独立按 rate 推进 (`(1-rate)*delta`),
audio 端 `setFrequency(base*rate)`, **不做任何对齐绑定**。后续如果
要做精确对齐, 思路只有三选一: (a) 完全相同 rate; (b) 不同 rate +
固定延迟补偿; (c) 不做音画同步变速。当前默认 (a), 误差靠用户接受。

**保留:** Seek 时 ScoreKeeper 重置 (这部分用户先验证)。布局来自
`sub_100A7DFC4` 反汇编, `sk = *(LogicNote+56)`:
  sk[+20] score, sk[+92] combo, sk[+96] pure, sk[+100] far,
  sk[+104] lost, sk[+108] late/early —— 全部清零。HP 不动。

**删掉:** `g_audio_corr_x10000` (FMOD 频率反馈校准), `apply_speed_to_all_channels`
里的 corr 乘子。`g_audio_meas_rate_x1000` 测量保留作面板诊断。
面板诊断行: `audio.meas X.XXXx  N=N  Δ=Nms` (Δ = chart - audio, 仅观测)。

---

## 历史 v6.3 (作废)

**变速思路换:** 不再做 FMOD 频率自校准 (`g_audio_corr_x10000` 删除)。理由: 即使
FMOD 实际速率有 ±2% 量化误差, chart 端只要直接读 `audio_pos_ms` 反算 `clk[16]`
就能让 `chart_displayed == audio_pos`, 永不漂移, 而且不需要每帧 `(1-rate)*delta`
累积——零误差累计、零抖动来源。

- `_gp_retime_logic_clock` 重写:
  ```
  clk[16] = steady_clock_ms - audio_pos_ms - clk[40]
  ```
  当差距 ≥3ms 才写, 让 steady_clock 平滑插值。1.0x 时差 ≤50ms 不动,
  完全交给游戏自己跑。
- `apply_speed_to_all_channels` 简化为 `base * rate` (去掉 corr 乘子)。
- `tw_mtp_getpos` 滑窗保留, 仅作面板诊断用 (`g_audio_meas_rate_x1000`)。
- 面板诊断行换为 `audio.meas X.XXXx  N=N  Δ=Nms` (Δ = chart - audio)。

**Seek 重放:** 之前只 hook isCompleted 让音符重出, 但**计分器 (ScoreKeeper)
独立累计 combo / score / pure / far / lost**, 没重置。类比 ArcCreate 的
`ChartService.ResetJudge() + ScoreService.ResetScoreTo() + JudgementService.ResetJudge()`,
本版本反汇编 `sub_100A7DFC4` (per-frame UI updater) 摸出 ScoreKeeper 布局
(`sk = *(LogicNote+56)`):
  - sk[+20] score, sk[+92] combo, sk[+96] pure, sk[+100] far, sk[+104] lost, sk[+108] late/early
  
`player_seek_ms` 步骤 (e) 把这些字段全部归零, HP 暂时不动。下一帧 isCompleted
hook 让音符重出 → 玩家重新打 → ScoreKeeper 自然重新累加。

---

## 历史 v6.2

### v6.2 改动

- **音/谱解耦** (修复变速抽搐): `_gp_retime_logic_clock` 删除 `chart→audio` 的 5%/帧低通拉回。两路时钟独立按 `target_rate` 推进。
- **音频自校准**: `tw_mtp_getpos` 滑窗 (~500ms) 实测 `audio_dms / real_dms = measured_rate`, 乘性逼近 `corr ← corr × (target/measured)` (单步±5%, 总幅±20%), `apply_speed_to_all_channels` 用 `base × rate × corr` 抵消 FMOD 频率量化误差。
- **删除 Pause BGM**: `player_set_paused` + 菜单开关 + `pauseChanged:` 全部移除 (实测与 freeze 双重暂停冲突)。
- **面板新增** `audio.meas X.XXXx  corr X.XXXx  N=N` 一行用于诊断。
- **修复 isCompleted 全部失败 (inst=0/MMMMM)**: `kArcLogicNoteVtables[]` 偏移之前少写了一位 (`0x303FD0` 应为 `0x1303FD0`), 导致每个 vtable 指向的是 `__DATA` 段之外的随机内存, slot[5] 读到 PAC 加签的堆指针 (`0x1714a0801ef` 之类), 与 target `image+0x7E27B8` 不匹配, 5 个全部 `M`。修正为 `0x1303FD0 / 0x130BC40 / 0x130DBB0 / 0x13171F0 / 0x13388F0` 后 IDA 验证 slot[5] 字节正好是 `b8 27 7e 00 01 ...` = `0x1007E27B8`。

## 历史 v6.1

### 已实现

- **音频变速**: FMOD `Channel::setFrequency(base × rate)`
- **谱面变速**: `Gameplay.update` vtable hook → `_gp_retime_logic_clock` 修改 `clock[16]`
- **视觉变速**: `gettimeofday` fishhook → CCDirector deltaTime 自动变速
- **Seek**: MTP::seekTo(音频) + clock[40] 偏移(谱面) 双系统对齐
- **Seek-replay (v6 timing-aware)**: vtable-swizzle `LogicNote::isCompleted` (5 个子类 vtable+40)
  + 1.5s grace window 期间，hook 读取 `note.timing (LogicNote+20)` 与 seek 目标比较：
  - `note.timing >= target - 120ms` → 返回 0（未来音符重新出现）
  - `note.timing < target - 120ms`  → 返回原实现（过去音符保持完成，杜绝闪现）
  - timing 字段读失败 → fallback 到 v5 模式（窗口内统一返回 0）
  - 窗口关闭 → 完全透明 passthrough，零干扰常规播放
- **进度条**: 实时显示位置和总时长
- **暂停/恢复**: freeze 机制 + retime 基准重置
- **代码量**: ~1400行, 1 fishhook + 7 vtable hook (MTP::getPos / GP::update / 5×LogicNote::isCompleted)
- **B-1 诊断面板** (2026-05-11): UI 实时显示 4 个时钟域 (real/warp/mach/audio/chart) + freeze 深度 + isCompleted 命中分布, 用于现场观察时钟漂移和暂停异常。
- **v6.1 (2026-05-11) 三项修复**:
  1. **isComp inst=0 诊断升级**: install 路径从 ±64 slot 扫描改为直接读 vtable[5]，每个 vtable 单独记 OK / Unreadable / Mismatch / mProtect-fail 状态码，面板显示 `inst=N [OOOOO]` + 失败时打 `vt[i] seen=0x... (target=0x...)` 帮助一眼看出根因。
  2. **延迟漂移修法 (drift correction)**: `_gp_retime_logic_clock` 增加低通校正：每帧把 `clock[16]` 拉向 `chart_clock - audio_pos = 0`，幅度 `drift/20` 上限 ±20ms/帧。彻底消除非 1× 倍率长时间累积的 chart vs audio 漂移 (实测达 5+ 秒)。
  3. **暂停时调速失效修法**: `apply_speed_to_all_channels` 在 `freeze_count > 0` 时 early-return — 部分 FMOD 实现会因 setFrequency 把 paused channel 解暂停，导致用户感知 "暂停时调速无响应"。

### 待验证 (v6)

- LogicNote.timing @ +20 的偏移从 IDA 推理（`sub_10086EE70` 中 `*(_DWORD*)(*v11+20) > v15-120` 模式）— 需真机加日志确认。
- 5 个 vtable swizzle 实际命中率：UI 计数器 `g_iscompleted_calls / force_zero / force_one` 验证。
- 子类 (LogicArcNote 有 +164/+288/+296 字段) 是否需要按 typeinfo 分支。

### 已废弃

- **v4**: 遍历 `LogicChart+32/+40` 重置 byte[12]/[13]：运行时 +40 是 chart_data 指针，不是音符向量末尾。
- **v5 byte 清零**: 在 isCompleted hook 内 `*(uint8_t*)+12 = 0` `+13 = 0` 完全是 no-op —
  反编译 vtable[3] (`sub_1007E2788`) 显示 byte +48..+55（自我们想象的 +12/+13 不同）是
  每帧由 vtable[3] 重写的距离缓存（`chart_time + base_offset`），不是状态。v6 已删除这两行。
- `_gp_drift_correct` 音画纠偏：谱面持续抽搐。

---

## 架构

### 变速系统


| 组件  | 机制                                                       | 说明    |
| --- | -------------------------------------------------------- | ----- |
| 音频  | `Channel::setFrequency(base × rate)`                     | 需主动调用 |
| 谱面  | `tw_gp_update` → `_gp_retime_logic_clock` 修改 `clock[16]` | 每帧调整  |
| 视觉  | `gettimeofday` fishhook → CCDirector delta               | 完全自动  |


### Seek 机制

```
Gameplay(+928) → LogicChart(+48) → Clock
display_ms = clock[32] - clock[40]

seek to X ms:
  1. freeze warp
  2. MTP::seekTo(ms, 0) → 音频跳转
  3. apply_speed → 重设频率
  4. clock[40] += (cur_display - X) → 谱面跳转
  5. unfreeze warp
```

### 时钟结构 (LogicChart+48)

```
+16: int32  start_reference (steady_clock ms)
+32: int32  accumulated_time
+40: int32  base_offset (display = [32] - [40])
+45: byte   internal_drive_flag
+52: int32  external_position
```

---

## 关键偏移 (Arcaea 6.13.10)


| 符号                               | 偏移                                |
| -------------------------------- | --------------------------------- |
| Gameplay.update vtable           | `0x136E1C0`                       |
| Gameplay.update fn               | `0xB3AD70`                        |
| MTP vtable                       | `0x1312860`                       |
| MTP::seekTo                      | `0x84699C`                        |
| LogicChart 时钟更新                  | `0x8C2FEC`                        |
| LogicChart 时间读取                  | `0x86E69C`                        |
| LogicChart::update               | `0x86E728`                        |
| 音符空间查询/活跃管理                      | `0x86EE70`                        |
| LogicNote::isCompleted (全子类共用) | vtable+40 → `0x7E27B8`            |
| TapNote 判定标志                     | vtable+48 → `0x14172C` (byte[13]) |
| TapNote 命中标志                     | vtable+64 → `0x118A80` (byte[12]) |
| LogicChart 构造工厂                  | `0xB1EA08`                        |
| LogicChart::init                 | `0x865B28`                        |
| Gameplay 结束/retry                | `0xB3CC7C`                        |
| refcount addref                  | `0xDB1A18`                        |
| refcount release                 | `0xDB1A28`                        |

### LogicNote 子类 vtable 起始地址 (5 个, 均含 isCompleted@slot+40 指向 0x7E27B8)

| 偏移        | 备注                                       |
| --------- | ---------------------------------------- |
| `0x303FD0` |                                          |
| `0x30BC40` |                                          |
| `0x30DBB0` | LogicTapNote (typeinfo @`0x10130DC00`)   |
| `0x3171F0` |                                          |
| `0x3388F0` |                                          |


---

## LogicChart 内存布局 (IDA 逆向)

```
LogicChart (0x118 = 280 bytes):
  +0:   vtable
  +8:   refcount base
  +16:  song_id (ptr)
  +24:  difficulty_data (ptr)
  +32:  notes_vector begin (init 时; 运行时语义待确认)
  +40:  notes_vector end / chart_data ptr (运行时)
  +48:  Clock ptr
  +56:  timing_groups vector begin
  +64:  timing_groups vector end
  +80:  tracks vector begin
  +88:  tracks vector end
  +104: tree structure (inline)
  +128: character_ability / spatial root ptr
  +136: spatial_index vector begin
  +144: spatial_index vector end
  +160: active_notes vector begin
  +168: active_notes vector end
  +188: int32 last_note_time
  +192: int32 max_note_end_time
  +288: events vector begin
  +296: events vector end
  +312: active flag
  +313: finished flag
  +314-316: end-game flags
  +324: state enum
```

---

## LogicNote 结构 (IDA 逆向, v6 修正)

```
LogicNote (base class):
  +0..7:    vtable
  +8..11:   refcount (int32)
  +12..13:  bytes - 含义不明; v4/v5 误以为是 hit/judged 标志, v6 反编译 vtable[3] 后
            确认 isCompleted 真正读的不在这里 (见 +28). 不要 touch.
  +20:      int32  ★note.timing (chart-ms judge time) — 空间查询 early-prune 用
            (sub_10086EE70 第 23 行: `*(_DWORD *)(*v11 + 20) > v15 - 120`)
  +28:      int32  end_time (active-list 移除条件: chart_time > end_time AND completed)
  +48..55:  int32x2 ★per-frame render distance cache (vtable[3] sub_1007E2788
            每帧重写: result = (int32)(chart_time + (float)base_offset))
            空间查询 add-back 用 `min(this) < 700` 判断. 不是状态, 别清零.
  +56..63:  int32x2 base render offset (init 时设, 影响 vtable[3] 输出)
  +164:     int32  (LogicArcNote only) arc/trace flag (=0 时 highlight 路径)
  +288/+296: ptr*2 (LogicArcNote only) 子段 vector (begin/end)
```

**重要**: 我们 v5 hook 内的 `*(uint8_t*)+12 = 0; +13 = 0;` 是历史包袱 no-op,
v6 已删除. 真正影响 add-back 的唯一变量是 `vtable[5](note)` 的返回值.

---

## 探索历程

1. **v1**: 12 fishhook → 精简至 2 (gettimeofday + mach_absolute_time)，删 ~500 行死代码
2. **v2**: 移除 `_gp_retime_logic_clock`（误判 mach_absolute_time 能驱动谱面），移除 CCDirector vtable hook
3. **v3**: 实测确认 mach_absolute_time 无法影响谱面，恢复 `_gp_retime_logic_clock`；修复 UI 乱码(ASCII化)；移除 mach_absolute_time hook (无实际作用)
4. **v4**: 尝试实现 seek 后音符重现，深入逆向 LogicNote 生命周期、isCompleted 机制、空间索引查询逻辑、retry 场景重建流程；确认根因但未能找到有效的运行时重置方案
5. **v5 (2026-05-11)**: 采用 vtable swizzle `isCompleted` + rewind grace window 方案。可靠逆向路径：`sub_10086EE70` 谱面空间查询 → 识别 vtable[5] 调用 → IDA xref 查找 0x7E27B8 的 5 个 vtable 宿主 → 统一 swizzle。
6. **v6 (2026-05-11)**: 反编译 LogicTapNote vtable[3] (`sub_1007E2788`) 发现 v5 内的
   byte[12]/[13] 清零是 no-op (vtable[3] 每帧重写 +48..+55 距离缓存). 引入
   timing-aware 决策: hook 读 `LogicNote+20 = note.timing`, 与 seek 目标比较;
   过去音符直接 delegate 原实现 (杜绝错误闪现). 取消 1.5s 全局强制返回 0,
   仅在 timing 字段读失败时 fallback 到 v5 模式. 灵感来自 ArcCreate `ResetJudgeTo(int timing)`.

### 被验证无效的方案


| 方案                                            | 结果               |
| --------------------------------------------- | ---------------- |
| mach_absolute_time fishhook 驱动谱面变速            | 几乎不被调用，无效        |
| CCDirector vtable hook + gettimeofday 双重 warp | 动画卡死             |
| 清空活跃音符列表 + 重激活音轨                              | 音符不重现            |
| 遍历 LogicChart+32/+40 重置 byte[12]/[13]         | +40 运行时语义不确定，未生效 |
| 清零 LogicNote+12/+13 byte (v5 内嵌)              | no-op: 真正字段在 +48/+52, 且每帧被 vtable[3] 覆盖 |
| `_gp_drift_correct` 音画纠偏                      | 谱面持续抽搐           |


---

## 安全约束

- ✗ DobbyHook on `__TEXT` — iOS 16+ sideload 不允许 RWX
- ✗ fishhook `clock_gettime_nsec_np` 全局 warp — 会断 FMOD mixer
- ✓ fishhook on 主二进制 GOT — 安全 (`__DATA` 段)
- ✓ vtable 槽位替换 (`__DATA_CONST`) — mprotect RW 可行



---

## v6.5.2 (2026-05-12) hotfix

### 现象
v6.5.1 上线后, seek (向前/向后拖时间) 直接闪退. 用户日志显示 sk reset 步骤打印成功
(combo 0->0 score 1148369->0 P/F/L 254/2/30 -> 0/0/0), 之后下一帧崩.

### 诊断
v6.5.1 在 `player_seek_ms` 步 (e) 末尾追加了:

```c
*(int32_t *)((char *)logic + 756) = 0;
*(int32_t *)((char *)logic + 760) = 0;
*(int32_t *)((char *)logic + 812) = 0;
```

意图是清空 UI 缓存让下一帧 `sub_100A7DD20` / `sub_100A7E71C` 强制刷新.
但这三个偏移**实际位于 `*(GP+896)` (ScorePresenter)**, 不在 LogicNoteGroup 上.
重读 `sub_100A7DFC4` 签名 `(__int64 a1 = ScorePresenter, int a2, __int64 a3 = LogicNoteGroup)`,
`a1+756/760/812` 才是 UI 缓存; 我把 a1 / a3 写混了, 在 LogicNoteGroup 后面的堆区域
随机覆写, 触发下一帧的 OOB 解引用 -> `EXC_BAD_ACCESS`.

### 修复
直接删掉这三行写入. 不需要替换为 ScorePresenter 写入: 下一帧 HUD 同步器
(`sub_100A7DFC4`) 自身就会做 `cached != current` 比较, combo / score 不一致
会自动刷新. 省略后 UI 最多比 sk 真值晚一帧, 完全可接受.

### 教训
`sub_XXXX(a1, a2, a3)` 反编时 a1 / a3 是不同对象 -- 不要靠"反正都从 GP 上挂着"的
直觉混用. 写偏移之前先把 `sub_100B3AD70` 调用点的实参对齐确认.

提交: `bf1a689`.

---

## v6.6 判定窗口控制 -- 暂缓 (RE 已完成, 实施被签名约束挡住)

完整 RE 路径与 5 阈值定位详见: [arcmodwiki / iOS judgement windows](../arcmodwiki/docs/ios-judgement-windows.md).

### RE 结论速记

- 真正的 per-tap classifier = `sub_100870FD0`.
- 5 阈值: `|dt| < 26ms = MAX_PURE`, `< 51 = PURE`, `< 101 = FAR`, `< 121 = LOST`, `>= 121 = no judge`.
- `sub_10086EE70` 里那对 300 / 700 是 **active-list entry/exit window**, 不是判定阈值
  (我们之前 v6.5 RE 误判了语义).
- ScoreKeeper 字段表已修正: `sk+96 = max_pure`, `+100 = pure`, `+104 = far`,
  `+108 = lost`, `+128 = late_far`, `+132 = early_far`, `+136 = late_pure`,
  `+140 = early_pure`. (early/late 之前在 summary 里写反了, 以这次为准.)

### 为什么暂缓

- `sub_100870FD0` 仅由 `sub_100871514` / `sub_100871FE0` 通过直接 `BL imm26` 调用
  (字节确认: `0x100871a34 = 97 FF FD 67` = BL). 没有 vtable 没有 GOT.
- 直接 BL 重定向 = 必须改 `__TEXT` 指令字节. iOS 16+ 普通自签 (Sideloadly /
  AltStore) 上 `__TEXT` 有 AMFI / CoreTrust page-hash seal, `vm_protect(WRITE)`
  失败或者更糟 (其它线程 fetch instruction 时 `EXC_BAD_ACCESS`).
- **不是 PAC 的问题** -- 直接 BL 完全不走 PAC.
- TrollStore 装的 (有 `dynamic-codesigning`) 可以 Dobby inline hook, 这个 tweak 仓的
  约束目标是"自签也要能跑", 所以暂不实现.

### 后续选项 (留给以后)

1. TrollStore 专属构建: build flag `ARC_TROLLSTORE_INLINE_HOOK=1`, 启用后用 Dobby
   inline hook `sub_100870FD0`, UI slider 实时调全 5 阈值.
2. 自签场景: 静态 IPA patch 8 处 `imm12` 字节, 出几个预设 IPA (easier / harder).
3. Android: 同套 RE 思路适用, 而且 Android 没有 `__TEXT` seal -> `mprotect` 直接
   能成, 一条路线就够 (Dobby / xHook 都行). 详见 wiki 跨平台 note.

### 接下来

回到 seek + 变速主线. 不再追判定窗口.
