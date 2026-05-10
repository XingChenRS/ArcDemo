# xrc-arcdemo Devlog

---

## 项目目标

将 [accDemo](https://github.com/brendonjkding/accDemo) 改造为针对 Arcaea iOS 的免越狱 dylib，支持变速、seek、练习。

---

## 当前状态 (v4, 2026-05-10)

### 已实现

- **音频变速**: FMOD `Channel::setFrequency(base × rate)`
- **谱面变速**: `Gameplay.update` vtable hook → `_gp_retime_logic_clock` 修改 `clock[16]`
- **视觉变速**: `gettimeofday` fishhook → CCDirector deltaTime 自动变速
- **Seek**: MTP::seekTo(音频) + clock[40] 偏移(谱面) 双系统对齐
- **进度条**: 实时显示位置和总时长
- **暂停/恢复**: freeze 机制 + retime 基准重置
- **代码量**: ~1400行, 2 fishhook + 2 vtable hook

### 未解决

- **Seek 后已播放音符不重现**: 向前 seek 后，已经判定过的音符不会重新出现在谱面上。
  - **根因**: `LogicNote::isCompleted()` 检查 `byte[12]`/`byte[13]` 判定标志，空间查询 (`sub_10086EE70`) 中 `((isCompleted^1)|isBar)&1 == 0` 导致已判定音符不被重新加入活跃列表。
  - **已尝试**: 遍历 `LogicChart+32/+40` 主列表重置 byte[12]/byte[13]，但 +32/+40 在运行时可能被复用（init 时为音符向量，运行时 +40 似乎变为 chart_data 指针），导致遍历无效。
  - **已尝试**: 清空活跃列表 (+160/+168) + release 引用、重激活音轨、清空事件队列、重置结束标志 — 均未能使音符重现。
  - **游戏原生 retry 机制**: 不存在"重置"函数，retry 是直接创建全新 Gameplay 场景（`sub_100B3CC7C`）。
  - **临时方案**: 先 retry 再 seek 到目标片段。
  - **TODO**: 换思路——考虑 hook `isCompleted()` vtable 方法在 seek 后临时返回 0；或在 Gameplay.update hook 中后处理活跃列表；或找到运行时音符主列表的正确地址。

---

## 架构

### 变速系统

| 组件 | 机制 | 说明 |
|------|------|------|
| 音频 | `Channel::setFrequency(base × rate)` | 需主动调用 |
| 谱面 | `tw_gp_update` → `_gp_retime_logic_clock` 修改 `clock[16]` | 每帧调整 |
| 视觉 | `gettimeofday` fishhook → CCDirector delta | 完全自动 |

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

| 符号 | 偏移 |
|------|------|
| Gameplay.update vtable | `0x136E1C0` |
| Gameplay.update fn | `0xB3AD70` |
| MTP vtable | `0x1312860` |
| MTP::seekTo | `0x84699C` |
| LogicChart 时钟更新 | `0x8C2FEC` |
| LogicChart 时间读取 | `0x86E69C` |
| 音符空间查询/活跃管理 | `0x86EE70` |
| LogicNote::isCompleted (TapNote) | vtable+40 → `0x7E27B8` |
| TapNote 判定标志 | vtable+48 → `0x14172C` (byte[13]) |
| TapNote 命中标志 | vtable+64 → `0x118A80` (byte[12]) |
| LogicChart 构造工厂 | `0xB1EA08` |
| LogicChart::init | `0x865B28` |
| Gameplay 结束/retry | `0xB3CC7C` |
| refcount addref | `0xDB1A18` |
| refcount release | `0xDB1A28` |

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

## LogicNote 结构 (IDA 逆向)

```
LogicNote (base class):
  +0:   vtable
  +8:   refcount (int32)
  +12:  byte  hit_flag (isCompleted check 2)
  +13:  byte  judged_flag (isCompleted check 1)
  +24:  int32 start_time_ms
  +28:  int32 end_time_ms
  +48:  int32x2 current_render_offset (updated by update())
  +56:  int32x2 base_render_offset (set during init, immutable)
  +64:  ptr   render_object
  +80:  int32 track_index
  +84:  byte  note_type_flag
```

---

## 探索历程

1. **v1**: 12 fishhook → 精简至 2 (gettimeofday + mach_absolute_time)，删 ~500 行死代码
2. **v2**: 移除 `_gp_retime_logic_clock`（误判 mach_absolute_time 能驱动谱面），移除 CCDirector vtable hook
3. **v3**: 实测确认 mach_absolute_time 无法影响谱面，恢复 `_gp_retime_logic_clock`；修复 UI 乱码(ASCII化)；移除 mach_absolute_time hook (无实际作用)
4. **v4**: 尝试实现 seek 后音符重现，深入逆向 LogicNote 生命周期、isCompleted 机制、空间索引查询逻辑、retry 场景重建流程；确认根因但未能找到有效的运行时重置方案

### 被验证无效的方案

| 方案 | 结果 |
|------|------|
| mach_absolute_time fishhook 驱动谱面变速 | 几乎不被调用，无效 |
| CCDirector vtable hook + gettimeofday 双重 warp | 动画卡死 |
| 清空活跃音符列表 + 重激活音轨 | 音符不重现 |
| 遍历 LogicChart+32/+40 重置 byte[12]/[13] | +40 运行时语义不确定，未生效 |
| `_gp_drift_correct` 音画纠偏 | 谱面持续抽搐 |

---

## 安全约束

- ✗ DobbyHook on `__TEXT` — iOS 16+ sideload 不允许 RWX
- ✗ fishhook `clock_gettime_nsec_np` 全局 warp — 会断 FMOD mixer
- ✓ fishhook on 主二进制 GOT — 安全 (`__DATA` 段)
- ✓ vtable 槽位替换 (`__DATA_CONST`) — mprotect RW 可行
