# xrc-arcdemo Devlog

---

## 项目目标

将 [accDemo](https://github.com/brendonjkding/accDemo) 改造为针对 Arcaea iOS 的免越狱 dylib，支持变速、seek、练习。

---

## 当前状态 (v6.2, 2026-05-11)

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

