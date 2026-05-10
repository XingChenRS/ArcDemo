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

### 当前版本（6.13.10）- 已完全功能化 ✅

所有核心功能已实现并验证：
- **✅ 音频变速**：通过FMOD频率调节 
- **✅ 谱面变速**：通过LogicChart时钟调整
- **✅ 视觉变速**：通过CCDirector帧时间缩放
- **✅ 全局变速**：通过gettimeofday时间注入
- **✅ Seek功能**：三系统对齐跳转
- **✅ 进度条**：实时显示位置和总时长
- **✅ 暂停/恢复**：无时间不连续
- **✅ 项目瘦身**：4个核心hooks，代码清晰

**关键技术决策已验证**：通过运行时vtable自动捕获player实例（而非查找全局单例）、采用时间加速公式而非简单缩放、冻结机制保证暂停/seek原子性。

---

## 前期探索过程说明

2026-05-08 ~ 2026-05-10：经过系统的IDA反编译分析和迭代testing，从盲目fishhook尝试逐步收敛到三个确定有效的Hook路径。过程中踩过的坑包括：
- steady_clock::now无法通过GOT拦截（编译器内联）→ 改用Gameplay.update vtable
- Channel虚表swizzle导致crash（尚未找到PAC签名正确的方法）→ 改用高级别的Gameplay/CCDirector
- GameScene单例难以定位 → 采用hook自动捕获策略彻底解决

**被抛弃的方案**：PlatformUtils虚表hooks、MTP.getPositionMs诊断hook、CADisplayLink ObjC swizzles等，因为后来发现三个核心hook已可覆盖所有需求。

---

## 三个核心 Hook 详解

经过详尽的IDA反编译和运行时验证，**三个Hook路径已确认功能完整且稳定**。本章详细记录这三个Hook的生效机制、IDA定位方法、以及Arcaea游戏时钟架构，为版本升级后的快速迁移奠定基础。

### Hook 1: Gameplay.update (vtable) — 掌控谱面事件与判定

**IDA偏移**：vtable @ `base + 0x136E1C0`，函数 @ `base + 0xB3AD70`

#### 工作原理
Gameplay是Arcaea内置的谱面逻辑管理类，持有LogicChart实例。每帧Gameplay.update被调用时：
1. 通过LogicChart内部的时钟读取当前游戏逻辑时间
2. 与谱面事件起始时间对比，决定哪些Note/Hold/Arc应该出现
3. 更新judgment window（判定窗口）

#### Hook生效机制
wrapper函数 `tw_gp_update()` 在原函数前执行 `_gp_retime_logic_clock()`：

```c
static void _gp_retime_logic_clock(void *logic) {
    void *clk = *(void **)((char *)logic + 48);  // LogicChart.clock
    int32_t *start_ms = (int32_t *)((char *)clk + 16);
    
    uint64_t delta_us = now_us - s_gp_last_real_us;
    int32_t adjust = (int32_t)(((1.0 - rate) * (double)(delta_us / 1000)));
    *start_ms += adjust;  // ★ 通过调整起始时间实现率变
}
```

LogicChart是单次初始化后复用的对象，每帧微调start_ms字段，游戏逻辑层感知到的时间流速就按rate缩放。

#### 版本迁移指南
1. IDA搜索字符串 "Gameplay" 或 "LogicChart" → 定位类定义
2. 找到调用 Channel::getPosition 的代码片段 → 往上回溯到Gameplay类的虚函数表
3. 验证该虚函数是否被 CCDirector 在主循环中每帧调用
4. 确认虚函数内存在 LogicChart 初始化或字段访问操作
5. 记录新版本的虚函数表偏移和LogicChart时钟字段的相对偏移

**当前版本（6.13.10）关键偏移**：
- Gameplay.update vtable entry = `base + 0x136E1C0`
- Gameplay.update function = `base + 0xB3AD70`
- LogicChart.start_ms offset = `clk + 16`

---

### Hook 2: CCDirector.tick (vtable) — 掌控视觉渲染与帧时间

**IDA偏移**：函数 @ `base + 0xCE197C`

#### 工作原理
CCDirector.tick是Arcaea渲染循环的心脏。每帧读当前时间，计算deltaTime，更新所有Sprite位置/透明度/旋转。

#### Hook生效机制 — dt预调（dt pre-adjustment）
我们无法修改tick()本身（__TEXT段不可写），但可以在tick()执行前修改prev_timeval：

```c
static void _ccdirector_retime_prev_tv(void *self) {
    struct timeval *prev = *(struct timeval **)((char *)self + 368);
    uint64_t delta = now_us - prev_us;
    uint64_t scaled = (uint64_t)((double)delta * rate);
    uint64_t warped_prev = now_us - scaled;
    prev->tv_sec = warped_prev / 1000000ULL;
    prev->tv_usec = warped_prev % 1000000ULL;
    // tick()读prev时：delta = now - warped_prev = scaled ✓
}
```

有两个Hook点：tick前调用（主路径）和active=true时调用（防edge case跳帧）。

#### 版本迁移指南
1. 找 CCDirector 的虚函数表
2. 搜索 `mach_absolute_time` 或 `gettimeofday` 的xref → 指向clock wrapper
3. 汇编找 struct timeval 成员访问（`LDR X?, [self, #368]`）
4. 记录prev_timeval的偏移

**当前版本关键偏移**：
- CCDirector.tick function = `base + 0xCE197C`
- CCDirector.active function = `base + 0xCE1A5C`
- prev_timeval field = `CCDirector + 368`

---

### Hook 3: gettimeofday (fishhook GOT rebinding) — 掌控全局动画效果

#### 工作原理
Arcaea的UIKit动画、渲染特效、暂停面板等依赖系统时钟。通过fishhook修改GOT表项，拦截所有gettimeofday调用。

#### 时间加速公式
```c
// t_warp = t0_warp + (real - t0_real) * rate
static uint64_t _compute_warp_us(uint64_t real_us) {
    if (atomic_load(&g_tw_freeze_count) > 0)
        return atomic_load(&g_tw_frozen_us);  // 冻结
    uint64_t delta_real = real_us - t0_real;
    return t0_warp + (uint64_t)((double)delta_real * rate);
}
```

变速切换时通过 `time_warp_set_rate()` 重新计算锚点，保证时间连续不跳变。

同时rebind `mach_absolute_time`，使用类似的 `_compute_warp_mach()` 公式。

**当前固定实现**：
- fishhook rebinding 于 doBootstrap 时执行
- 只rebind 2个符号：`mach_absolute_time`, `gettimeofday`
- GOT修改在__DATA段，不破坏iOS 16 sideload代码签名

---

### 三Hook协同关系

| Hook | 时间源 | 影响范围 | 修改部位 |
|------|--------|---------|---------|
| Gameplay.update | LogicChart.start_ms | 谱面事件判定时间 | vtable直接修改 |
| CCDirector.tick | prev_timeval | 视觉渲染（track/effects/panel）| 内存现场修改 |
| gettimeofday | 系统API | 全局动画、计时器 | GOT表重定向 |

**协同时序**（用户拖动速度条从1.0改为0.5）：
1. `time_warp_set_rate(0.5)` 更新全局锚点 + 音频频率 + 重置逻辑时钟参考
2. 下一帧：
   - gettimeofday → 返回缩放时间 → 所有动画速度↓
   - CCDirector.tick → prev_timeval已预调 → deltaTime = real * 0.5
   - Gameplay.update → LogicChart.start_ms被调整 → 谱面判定延后

---

## Step 15: 音画完全同步 + 项目瘦身 (2026-05-10)

### 关键问题发现：变速后音画错位

**现象**：音频和谱面都被变速了，但时间基准不同步，导致随时间推进出现明显错位。

**根本原因**：
- 音频变速 = 改FMOD频率（相对时间系数）
- 谱面变速 = 改warp时间基准（绝对时间映射）
- 改变rate时，两者的参考点没有重新对齐 → 时间偏移累积

### 修复方案

#### 修复1: time_warp_set_rate() 内部同步
rate改变时同时调用 `apply_speed_to_all_channels()` 更新音频频率，并重置 `s_gp_last_real_us = 0` 让逻辑时钟重新建立基准。

#### 修复2: player_seek_ms() 三系统对齐
seek时：冻结时间 → FMOD跳转 → 重应用倍率 → 重置逻辑时钟 → 更新warp基准到seek位置 → 解冻。确保谱面、音频、warp三系统都对齐到同一时刻。

### 项目瘦身

菜单从24项精简到4项核心hooks：

| 保留 | 作用 |
|------|------|
| gettimeofday | 全局动画效果 |
| [vt]Gameplay.update | 谱面事件与判定 |
| [vt]CCDirector.tick | 视觉渲染 |
| [vt]CCDirector.active | 视觉副路径（避免rate<1卡顿） |

删除：clock_gettime等无法通过GOT拦截的fishhook符号、PlatformUtils虚表hooks、CADisplayLink swizzles、self_test诊断等。

---

## 深层重构 (2026-05-10)

### 已完成
- **代码清理**：从12个fishhook符号减到2个，删除~500行死代码
- **编译修复**：`mach_timebase` → `s_tb_info`，删除未声明变量引用
- **UI逻辑修复**：clockToggleChanged flags数组与4项菜单对齐（修复了开关映射错误的bug）
- **命名规范**：日志前缀统一为 `xrc-arcdemo`，浮窗标签 `xrc`，菜单标题 `Arcaea 变速 (XRC)`
- **诊断精简**：去除高频caller诊断日志，保留5秒一次的计数汇总

### 已知限制
1. **偏移硬编码**：所有vtable/字段偏移基于Arcaea 6.13.10，版本更新后需要用IDA重新定位
2. **arm64e PAC**：vtable swizzle时PAC discriminator采用尽力而为策略，arm64e设备可能需要额外验证
3. **Seek精度**：seek后warp时间基准会重置到seek位置对应的us值，极快连续seek可能有微小偏差
4. **依赖Substrate ABI**：当前使用Logos语法+ElleKit/Substrate，完全脱Substrate需额外迁移工作

### 代码结构（重构后）

```
Tweak.x (~1500行)
  ├─ [全局] rates/rate_i/button/menuView
  ├─ [Arcaea偏移] ARC_OFF_* defines + 函数指针类型
  ├─ [玩家交互] resolve_player, apply_speed_to_all_channels
  ├─ [Time Warp核心]
  │   ├─ _compute_warp_mach / _compute_warp_us (锚点公式)
  │   ├─ tw_mach_absolute_time / tw_gettimeofday (fishhook wrappers)
  │   ├─ time_warp_set_rate / freeze_inc / freeze_dec
  │   └─ time_warp_install (rebind 2个GOT符号)
  ├─ [vtable Hooks]
  │   ├─ tw_gp_update → _gp_retime_logic_clock (谱面)
  │   ├─ tw_cc_tick / tw_cc_active → _ccdirector_retime_prev_tv (视觉)
  │   ├─ tw_mtp_getpos (player自动捕获)
  │   └─ swizzle_vtable_find_swap (通用vtable替换引擎)
  ├─ [Seek/Pause] player_seek_ms, player_set_paused
  ├─ [UI] AccMenuController (菜单) + initButton (浮窗)
  ├─ [Prefs] loadPref/savePrefDict (沙箱plist)
  └─ [Bootstrap] ctor → onAppLaunched → doBootstrap
```

---

## Arcaea时钟架构总结

```
          真实世界时间轴 (real_time)
          ↓ gettimeofday() / mach_absolute_time()
          ↓ fishhook 拦截 → _compute_warp_us(real_us)
   
   加速时间轴 (warp_time)
   ├─ [系统级] UIAnimation, dispatch_walltime
   │
   ├─ [引擎级] CCDirector 渲染循环
   │   ├─ tick() → 读 prev_timeval（已预调）→ deltaTime = real_delta * rate
   │   ├─ active() → 二级retime
   │   ↓ 所有Sprite按加速deltaTime更新
   │
   └─ [游戏逻辑] Gameplay.update
       ├─ LogicChart.start_ms （每帧微调）
       ├─ 谱面事件判定：currentTime - eventTime vs judgment_window
       ↓ Note hit/miss 判定
```

**稳定性保证**：
1. 三个Hook作用于不同的时间注入点，互不冲突
2. 时间加速公式采用锚点偏移而非简单乘法，保证连续性
3. 每个Hook都有计数器和使能开关，允许精细调试
4. Freeze机制保证暂停/seek时不会时间乱跳

---

## 已验明的安全约束

- ✗ DobbyHook on libsystem __TEXT — iOS 16 sideload 不允许 RWX
- ✗ 直接 fishhook clock_gettime_nsec_np 全局 warp — 会断 FMOD mixer 时钟
- ✓ fishhook on 主二进制 GOT — 安全，只修改 __DATA 段
- ✓ vtable 槽位替换（含 C++ vtable in __DATA_CONST）— 安全，mprotect RW 可行
