# xrc-arcdemo Devlog

实时记录这个项目的进度、坑、决策。每完成一阶段或踩一个坑就 append。

---

## 项目目标

把 [accDemo](https://github.com/brendonjkding/accDemo) 这个 iOS 越狱 Tweak（用 `gettimeofday`/`clock_gettime` 做时基注入实现游戏变速）改造为针对 Arcaea iOS 的免越狱 dylib，支持：

1. **PoC**：移植到 Arcaea 内置浮窗 UI，保留原变速行为（**只影响谱面，不影响音频** —— 已知现象，原 Tweak 模式 3 在 Arcaea 上的表现）。
2. **真·变速**：让音频和谱面同步变速（消除原 Tweak 在 Arcaea 上"谱面飞、音频不动"导致的 desync）。
3. **进度条 seek**：拖动条跳转到谱面任意位置，作为练习工具。
4. **最终形态**：framework 注入 + 重签 IPA，完全脱越狱（含巨魔）。

---

## 架构

### 原 accDemo（3 二进制）

```
[com.apple.Preferences]  ← accdemopref.bundle    (PreferenceLoader 配置面板)
[SpringBoard]            ← ccaccdemo.bundle      (控制中心模块)
[SpringBoard]            ← AccDemoLoader.dylib   (检测目标 App，按需 dlopen 主体)
[target game]            ← AccDemo.dylib         (主 hook：mode 1/2/3)
        共享 ~/Library/Preferences/com.brend0n.accdemo.plist
        Darwin notify "com.brend0n.accdemo/loadPref" 热重载
```

### 目标架构（单 dylib，注入 Arcaea）

```
Arcaea.app/Frameworks/AccDemoArcaea.framework/AccDemoArcaea
  (主二进制 LC_LOAD_DYLIB 注入 → app 启动时自动加载)

  ├─ ctor: 注册 UIApplicationDidFinishLaunching 通知
  ├─ Hooks
  │   ├─ Stage A: Substrate (%hookf / %hook / %init)  — 越狱/TrollStore 验证
  │   └─ Stage B: fishhook + Method Swizzle + Dobby   — 完全脱 Substrate
  ├─ Prefs: app 沙箱 NSHomeDirectory()/Library/Preferences/...plist
  └─ 游戏内浮窗 UI（吞掉原 PreferenceLoader + 控制中心 + 浮窗按钮）
```

---

## 项目完成状态

### 当前版本（6.13.10）- v2 架构 ✅

核心功能已实现：

- **✅ 音频变速**：FMOD Channel::setFrequency(base × rate)
- **✅ 谱面变速**：mach_absolute_time fishhook → steady_clock::now() 自动变速
- **✅ 视觉变速**：gettimeofday fishhook → CCDirector.tick deltaTime 自动变速
- **✅ Seek功能**：MTP::seekTo(音频) + clock[40] 偏移(谱面) 双系统对齐
- **✅ 进度条**：实时显示位置和总时长
- **✅ 暂停/恢复**：freeze 机制保证时间连续
- **✅ 代码精简**：~1200行，2 个 fishhook + 2 个 vtable hook

---

## 探索过程与教训

2026-05-08 ~ 2026-05-10：从盲目fishhook尝试逐步收敛。

**被抛弃的方案**：PlatformUtils虚表hooks、MTP.getPositionMs诊断hook、CADisplayLink ObjC swizzles、`_gp_retime_logic_clock`（手动修改 LogicChart.start_ms）、CCDirector vtable hooks（`_ccdirector_retime_prev_tv`）。

**v1 架构的致命缺陷**：mach_absolute_time fishhook + `_gp_retime_logic_clock` 对谱面时钟产生了 **rate² 双重 warp**（steady_clock 已被 fishhook 加速，再手动调 start_ms 又加速一次）。同理 gettimeofday fishhook + `_ccdirector_retime_prev_tv` 也对视觉帧时间双重 warp。实测 rate=0.5x 时谱面完全停止（0²=0），rate=2x 时谱面 3x 速度。

---

## v2 架构详解 (2026-05-10)

### 核心发现：双重 warp 问题

通过 IDA 反编译分析，确认了 Arcaea 时钟链条：

1. **谱面时钟** (`sub_10086E69C`): `display_ms = clock[32] - clock[40]`
   - `clock[32]` 由 `sub_1008C2FEC` 每帧通过 `steady_clock::now()` 计算
   - `steady_clock::now()` 底层调用 `mach_absolute_time()`
   - 因此 fishhook `mach_absolute_time` **已经自动让谱面变速**
   - v1 的 `_gp_retime_logic_clock` 修改 `clock[16]` 额外加速 → 双重 warp!

2. **视觉时钟** (`sub_100CE0518`): `delta = gettimeofday() - prev_timeval`
   - CCDirector 每帧调用 gettimeofday 计算 deltaTime
   - fishhook `gettimeofday` **已经自动让 CCDirector 看到 warped delta**
   - v1 的 `_ccdirector_retime_prev_tv` 又修改 prev_timeval → 双重 warp!

### v2 变速架构（正确方案）

| 组件 | 机制 | 自动程度 |
| --- | --- | --- |
| 音频 | `Channel::setFrequency(base × rate)` | 需主动调用 |
| 谱面 | `mach_absolute_time` fishhook → `steady_clock::now()` → `clock[32]` | 完全自动 |
| 视觉 | `gettimeofday` fishhook → CCDirector delta | 完全自动 |

**无需任何 vtable retime hook**。只需 2 个 fishhook + FMOD 频率调节。

### Gameplay.update vtable hook（仅缓存实例）

vtable @ `base + 0x136E1C0`，函数 @ `base + 0xB3AD70`

v2 中 `tw_gp_update()` 只做一件事：`atomic_store(&g_gameplay_instance, self)`。缓存 Gameplay 实例指针供 seek 使用。不做任何时间修改。

### Seek 机制

MTP::seekTo 只影响 FMOD 音频位置，不影响谱面时钟。v2 的 seek 通过直接修改时钟结构实现谱面跳转：

```
Gameplay(+928) → LogicChart(+48) → Clock
display_ms = clock[32] - clock[40]

seek to X ms:
  clock[40] += (current_display - X)
  → display_ms = X ✓
```

具体步骤：
1. 冻结 warp 时间
2. MTP::seekTo(ms, channel=0) → 音频跳转
3. 重新应用频率（FMOD seek 可能重置频率）
4. 读取当前 `_read_chart_clock_ms()` → `cur_ms`
5. `clock[40] += (cur_ms - target_ms)` → 谱面跳转
6. 解冻 warp 时间

### 谱面时钟结构（IDA 反编译确认）

```
Clock struct (at LogicChart + 48):
  +16: int32  start_reference (steady_clock ms at init)
  +32: int32  accumulated_time (updated each frame from steady_clock)
  +36: int32  (internal reference)
  +40: int32  base_offset (display_time = clock[32] - clock[40])
  +44: byte   (flag)
  +45: byte   internal_drive_flag (1 = use steady_clock)
  +48: int32  duration/countdown
  +52: int32  external_position
```

### 当前版本（6.13.10）关键偏移

- Gameplay.update: vtable = `0x136E1C0`, fn = `0xB3AD70`
- MTP vtable: `0x1312860`, getPositionMs = `0x846950`, seekTo = `0x84699C`
- CCDirector.tick: `0xCE197C` (不再 hook)
- `sub_100CE0518`: CCDirector 时间计算函数，调用 `gettimeofday`
- `sub_1008C2FEC`: LogicChart 时钟更新函数，调用 `steady_clock::now()`
- `sub_10086E69C`: LogicChart 当前时间读取函数
- `sub_100A5D2D0`: `steady_clock::now() / 1e6` → ms

---

## 深层重构 (2026-05-10)

### v1 重构（Phase 1-7）

- 从12个fishhook符号减到2个，删除~500行死代码
- 编译修复：`mach_timebase` → `s_tb_info`
- UI逻辑修复：clockToggleChanged flags数组与菜单对齐
- 命名规范：日志前缀统一为 `xrc-arcdemo`

### v2 重构（双重 warp 修复）

- **移除 `_gp_retime_logic_clock`**：谱面变速改由 mach_absolute_time fishhook 自动驱动
- **移除 `_ccdirector_retime_prev_tv`**：视觉变速改由 gettimeofday fishhook 自动驱动
- **移除全部 CCDirector vtable hooks**（tw_cc_tick, tw_cc_active, try_install_ccdirector_vtable_swizzle）
- **修复 seek**：添加 clock[40] 偏移调整，实现谱面+音频同步跳转
- **UI 精简**：菜单从4项减至2项（gettimeofday + mach_absolute_time 开关）
- 代码从 ~1500行 精简到 ~1200行

### 已知限制

1. **偏移硬编码**：所有vtable/字段偏移基于Arcaea 6.13.10，版本更新后需IDA重新定位
2. **arm64e PAC**：vtable swizzle采用尽力而为策略，arm64e可能需额外验证
3. **依赖Substrate ABI**：当前使用Logos语法+ElleKit/Substrate

### 代码结构

```
Tweak.x (~1200行)
  ├─ [全局] rates/rate_i/button/menuView
  ├─ [Arcaea偏移] ARC_OFF_* defines + 函数指针类型
  ├─ [玩家交互] resolve_player, apply_speed_to_all_channels
  ├─ [Time Warp核心]
  │   ├─ _compute_warp_mach / _compute_warp_us (锚点公式)
  │   ├─ tw_mach_absolute_time / tw_gettimeofday (fishhook wrappers)
  │   ├─ time_warp_set_rate / freeze_inc / freeze_dec
  │   └─ time_warp_install (rebind 2个GOT符号)
  ├─ [vtable Hooks]
  │   ├─ tw_gp_update (仅缓存Gameplay实例)
  │   ├─ tw_mtp_getpos (player自动捕获)
  │   └─ swizzle_vtable_find_swap (通用vtable替换引擎)
  ├─ [Seek/Pause] player_seek_ms (_read_chart_clock_ms + clock[40]), player_set_paused
  ├─ [UI] AccMenuController (菜单) + initButton (浮窗)
  ├─ [Prefs] loadPref/savePrefDict (沙箱plist)
  └─ [Bootstrap] ctor → onAppLaunched → doBootstrap
```

---

## Arcaea时钟架构总结

```
  真实时间 (real_time)
  │
  ├─ mach_absolute_time() ──[fishhook]──→ tw_mach_absolute_time()
  │   └─ steady_clock::now() / 1e6 = warped_ms
  │       └─ sub_1008C2FEC: clock[32] = warped_ms - clock[16] + ...
  │           └─ sub_10086E69C: display = clock[32] - clock[40]
  │               └─ 谱面事件判定 ✓
  │
  ├─ gettimeofday() ──[fishhook]──→ tw_gettimeofday()
  │   └─ sub_100CE0518: delta = warped_now - prev
  │       └─ CCDirector.tick: deltaTime = rate × real_delta
  │           └─ Sprite/Effect 更新 ✓
  │
  └─ FMOD Channel
      └─ setFrequency(base × rate) → 音频播放速度 ✓
```

**稳定性保证**：

1. fishhook 拦截在 GOT 层面，所有引用同一符号的代码都看到相同的 warped 时间
2. 不再有任何手动 retime，杜绝双重 warp
3. 时间连续性由锚点公式保证（切 rate 时 t0_warp = warp(now, old_rate)）
4. Freeze 机制保证暂停/seek/切后台时时间不跳变

---

## 已验明的安全约束

- ✗ DobbyHook on libsystem __TEXT — iOS 16 sideload 不允许 RWX
- ✗ 直接 fishhook clock_gettime_nsec_np 全局 warp — 会断 FMOD mixer 时钟
- ✓ fishhook on 主二进制 GOT — 安全，只修改 __DATA 段
- ✓ vtable 槽位替换（含 C++ vtable in __DATA_CONST）— 安全，mprotect RW 可行

