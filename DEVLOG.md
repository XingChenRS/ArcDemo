# AccDemoArcaea Devlog

实时记录这个项目的进度、坑、决策。每完成一阶段或踩一个坑就 append。

---

## 项目目标

把 [accDemo](https://github.com/brendonjkding/accDemo) 这个 iOS 越狱 Tweak（用 `gettimeofday`/`clock_gettime` 做时基注入实现游戏变速）改造为针对 Arcaea iOS 的免越狱 dylib，支持：

1. **PoC**：移植到 Arcaea 内置浮窗 UI，保留原变速行为（**只影响谱面，不影响音频** —— 已知现象，原 Tweak 模式 3 在 Arcaea 上的表现）。
2. **真·变速**：让音频和谱面同步变速（消除原 Tweak 在 Arcaea 上"谱面飞、音频不动"导致的 desync）。
3. **进度条 seek**：拖动条跳转到谱面任意位置，作为练习工具。
4. **最终形态**：framework 注入 + 重签 IPA，完全脱越狱（含巨魔）。

---

## 架构差异

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

## 进度

### 2026-05-08

#### 第 0 步：fork + 砍冗余 + 配置层重写 ✅

- `accDemo/` → `accDemo-arcaea/` 复制
- 删：`.git/`、`accdemopref/`、`ccaccdemo/`、`AccDemoLoader.plist`、`TweakLoader.x`、`log.sh`、`AccDemo.plist`
- 新建：`AccDemoArcaea.plist`（filter `moe.low.arc`）
- 重写：`Makefile`（单 target = AccDemoArcaea，注入 `Arc-mobile`）、`Prefix.pch`（kPrefPath 改 app 沙箱）、`control`（新包名 `moe.low.arc.accdemoarcaea`）

#### 第 1 步：Tweak.x 主体重写 ✅

把 `Tweak.x` 从 14 KB 重写到 ~12 KB（删 + 加 = 净增 UI 代码）。

| 删 | 加 / 改 |
|---|---|
| Unity TimeScale 内存扫描（`mach_vm_*` / `adrp` 工具 / `find_ad_*` / `%group unity`）| `AccMenuController` 类（约 200 行 UIKit）|
| `loadFrameWork()`（Unity Framework 检测）| 浮窗按钮长按 0.45s 弹出菜单 |
| `isEnabledApp()` + `kModeAuto` | 菜单内容：mode segment / Toast switch / 速率列表（点击选中、长按删除、TextField 编辑）/ + Add / Close |
| Darwin notify 注册 + 远程 prefs 路径 | prefs 默认值 `[1.00, 0.80, 0.60, 1.25, 1.50]` |
| `kBundlePath` / SpringBoard 假设 | `NSBundle hook` fallback 到 mainBundle（WHToast 资源后续再补）|

**保留核心**：`%hookf gettimeofday` / `%hookf clock_gettime` 算法逐字保留，与原 Tweak 行为一致。

**遗留问题**：
- WHToast 内置资源缺失 → toast 仅显示文字，无图标
- mode 切换需重启游戏（Substrate `%init` 一次性安装；阶段 B 用 fishhook 后才能运行期切换）
- Windows 工作站没法本地编译；**计划用 GitHub Actions macOS runner 做 CI**

#### 第 2 步：Arcaea iOS 二进制初探 ✅

工具：IDA MCP 连接 `Arc-mobile.i64`（ARM64 Mach-O，基址 `0x100000000`，大小 ~21 MB，Apple libc++）。

##### 关键发现 1：音频引擎是 **FMOD Low Level**（静态链接）
- 字符串 `FMOD error!`、`fmod_*.cpp` assertion source、`FMOD Loudness Meter`、`OpenAL.framework/OpenAL`（FMOD 在 iOS 上的 backend 元数据）
- **不是** AVAudioPlayer / cocos2d AudioEngine
- 这反而是好消息：FMOD 是公开 SDK，速率/位置控制接口固定

##### 关键发现 2：FMOD profiler wrapper 实际可用
FMOD strip 后保留了 ASCII 调试串（`Channel::setFrequency` 等），每条字符串被一个独立的 wrapper 函数引用：

| FMOD 字符串 | 字符串地址 | wrapper 函数 | 大小 |
|---|---|---|---|
| `Channel::setPriority` | `0x101133a3c` | `sub_100EC00C8` | 0xD8 |
| `Channel::setPosition` | `0x101133a66` | `sub_100EC0284` | 0x128 |
| `Channel::setChannelGroup` | `0x101133a90` | `sub_100EC04E0` | 0xD8 |
| `Channel::setFrequency` | `0x101133ac2` | `sub_100EC069C` | 0xE0 |
| `Channel::setLoopCount` | `0x101133b2c` | `sub_100EC0B14` | 0xD8 |
| `Channel::setLoopPoints` | `0x101133b58` | `sub_100EC0B90` | （未确认） |

每个 wrapper 内部结构（以 setFrequency 为例）：
```c
__int64 sub_100EC069C(__int64 channel, float freq) {
    sub_100EC64B4(channel, &v7, &v6);    // 加锁/取真实 channel ptr
    sub_100EC67BC(v7, freq);              // ★ 真正的 setFrequency 实现
    if (profiler_enabled) sub_100EEEDC8(...);
    sub_100EA9F70();                      // 解锁
}
```

→ **hook 这一层 wrapper 即可全局生效**（业务代码通过 vtable / 直接 call 都会经过）。

##### 关键发现 3：Arcaea 已有"多轨同步 seek"实现
`sub_10084699C`（vtable @ `0x101312880` 的 slot 4，size 0x14C）：

```c
void seekTo(MultiTrackPlayer* player, int64_t target_ms, int channel_idx) {
    cur_ms = (*player->vtable[7])(player, 0);   // 拿当前主轨位置
    if (channel_idx >= player->channels.size) goto error;
    Channel_setPosition(player->channels[channel_idx], target_ms, FMOD_TIMEUNIT_MS=1);
    if (channel_idx != 0) return;               // 副轨 seek 完即可
    // 主轨：把所有 tracks 数组（player->[4..5]）按 (target-cur)*rate/1000 偏移补偿同步
    for (track in player->tracks)
        Channel_setPosition(track.channel, base + (target-cur)/-1000 * rate, 0, 1);
}
```

→ **只要拿到 player 实例指针**，进度条 seek 已经"零工作量"实现：
```c
((seek_fn_t)(0x10084699C - 0x100000000 + slide))(player, target_ms, 0);
```

#### 待办（下一轮）

- [ ] 找 MultiTrackPlayer 单例的全局指针（player 实例存在哪？）
- [ ] 找 `Channel::setVolume` / `Channel::setMute` / `Channel::setPaused` profiler wrapper 地址
- [ ] 验证 vtable @ `0x101312880` 真实起点（PAC 签名导致 IDA xref 为空）
- [ ] 找 Arcaea **谱面时钟** 主变量（哪个 manager 持有 currentBeatTime？是不是从 audio current position 反推？）
- [ ] GitHub Actions workflow：macOS runner + Theos + 自动构建产出 .deb / .dylib
- [ ] 在 macOS 实机/CI 上首次编译 Stage A 验证语法

#### 第 3 步：CI workflow ✅（首版）

`.github/workflows/build-tweak.yml`：macOS runner，clone Theos，下载 iOS SDK，`make package`。

#### 第 4 步：IDA 深探 — vtable / 单例 / 业务调用方 ✅

##### vtable 真实起点 = `0x101312860`（不是 0x101312880）
`0x101312840-58` 是多继承 RTTI 区：

| addr | 内容 | 角色 |
|---|---|---|
| `0x101312840` | `0x10111c6a0` | typeinfo / RTTI ptr |
| `0x101312848-50` | `0` | offset_to_top |
| `0x101312858` | `0x101312940` | secondary vtable (multi-inherit) |
| `0x101312860` | **vtable[0]** = `sub_100844D68` | MultiTrackPlayer 主 vtable 起点 |

完整 MultiTrackPlayer vtable（slot 4 起识别）：

| slot | offset | fn | 推测语义 | 证据 |
|---|---|---|---|---|
| 3 | +0x18 | `sub_100845B88` | `loadBGM(path)` | 内含字符串 `"loadBGM - path:"` |
| 4 | +0x20 | `sub_100846660` | `unloadBGM(ch)` | 内含字符串 `"unloadBGM"` |
| 5 | +0x28 | `sub_1008467A8` | `play(loop, ch, offset_ms)` | 内含 setLoopCount + setVolume |
| 6 | +0x30 | `sub_100846914` | `setPaused(?, ch)` | 简短，调 `sub_100F6F4BC(ch, a2)` |
| 7 | +0x38 | `sub_100846950` | **`getPositionMs(ch)`** ★ | 调 `Channel::getPosition` wrapper `sub_100EC03AC` |
| 8 | +0x40 | `sub_10084699C` | **`seekTo(ms, ch)`** ★ | 多轨同步 seek，已分析 |

注：`sub_10084699C` 内部 `(*vtable[7])(this, 0)` ↔ 调 slot 7 getPositionMs，自洽。

##### Channel::getPosition wrapper = `sub_100EC03AC`
反编译末尾 `sub_100EEEDC8(v6, 2, a1, "Channel::getPosition", v13);` 确认。

##### bgmPlayer 在 GameScene 内字段偏移 = `+0x2F0`
`sub_100876710`（"playBGM" 业务函数）末尾：
```asm
LDR  X9, [SP, var_178]         ; X9 = GameScene this（早期保存）
LDRB W8, [X9, #0x336]          ; gameScene->some_flag
LDR  X0, [X9, #0x2F0]          ; ★ X0 = gameScene->bgmPlayer
CMP  W8, #1
LDR  X8, [X0]                  ; vtable
LDR  X8, [X8, #0x128]          ; vtable[37] = some method
BLR  X8                        ; call (*bgmPlayer.vtable[37])(bgmPlayer, &arg)
```

→ **GameScene 实例的 `+0x2F0` 偏移就是 bgmPlayer**。
→ 但 vtable[37] 远超 MultiTrackPlayer vtable 范围（我们目前只看到 ~16 slot），意味着 **bgmPlayer 是更大的类**：
- 假设 1：bgmPlayer 是 MultiTrackPlayer 的**子类**（更多虚函数）
- 假设 2：MultiTrackPlayer 是 bgmPlayer 的**内嵌字段**
- 待验证

##### 谱面时钟变量、GameScene 单例
**未找到**。下一轮要做：
1. 找 `sub_100876710`（GameScene 类某方法）的调用方，反推 GameScene 实例如何被持有（cocos2d Director::getRunningScene() 或某 manager 静态字段）
2. 谱面时钟通常是从 `bgmPlayer.getPositionMs(0)` 反推；hook bgmPlayer 的 vtable[37] 即可同步监听
3. setVolume / setPaused / setMute 的 FMOD wrapper 地址（把 setVolume 字符串 xref 抽出来）

##### 关键策略转向：**不必找单例，hook player 方法自动捕获 this**
既然 vtable[8] = `sub_10084699C`（seek）和 vtable[7] = `sub_100846950`（getPosition）每次 player 活动都被调用，dylib 只要：
1. 用 Dobby hook `sub_10084699C` 或 `sub_100846950`
2. 在 hook 回调里把 `this` 指针缓存到全局
3. 后续进度条 callback 用缓存的 `this` 直接调 seek

这样**完全不需要找全局单例**，只要游戏跑起来、播放任何 BGM，就能拿到 player handle。

#### 第 5 步：待办

- [ ] **Stage B 框架**：把 Dobby 加进 Makefile（`AccDemoArcaea_LIBRARIES += dobby` + 静态库放进 `tweak.libs/`），写 `Channel::setFrequency` hook 模板
- [ ] **player 自动捕获**：hook `sub_100846950`（高频 getPosition）缓存 player this 到 `static void *g_player`
- [ ] **进度条 UI**：在菜单加 UISlider，min=0, max=getDuration（通过观察 getPosition 返回值 + 谱面元数据推断）
- [ ] 第一次 GitHub Actions CI 编译验证 + 修语法

#### 第 6 步：FMOD ChannelControl wrappers 全锁定 ✅

| FMOD method | wrapper | 偏移 | 字符串 |
|---|---|---|---|
| `ChannelControl::setVolume` | `sub_100F6F67C` | 0x100F6F67C | 0x1011390a0 |
| `ChannelControl::getVolume` | `sub_100F6F848` | 0x100F6F848 | 0x1011390d4 |
| `ChannelControl::setMute` | `sub_100F6FCB0` | 0x100F6FCB0 | 0x101139160 |
| `ChannelControl::setPaused` | `sub_100F6F4BC` | 0x100F6F4BC | 0x10113906c |

**验证**：MultiTrackPlayer vtable[6] = `sub_100846914` 内部直接调 `sub_100F6F4BC` → slot 6 = setPaused 二次确认。

#### 第 7 步：getPositionMs 实现细节确认 ✅

`sub_100846950(this, channel)`:
```c
v2 = *(QWORD *)(this + 56);     // channels begin
if (channel >= ((this + 64) - v2) >> 4)  // bounds check
    sub_100847AFC(this);         // assert/abort
sub_100EC03AC(*(QWORD *)(v2 + 16*channel + 8), &out_pos, 1);
return out_pos;
```
- `this+56` = channels array begin（每元素 16 字节，offset+8 处存 FMOD::Channel*）
- `this+64` = channels array end
- 第三参 `1` = `FMOD_TIMEUNIT_MS` ✅
- 返回 `unsigned int` 毫秒

#### 第 8 步：未果项 — GameScene 单例 / 谱面时钟变量

- 字符串 `Director::getInstance` / `getRunningScene` / `bgmPlayer` / `BGMPlayer` / `chartTime` / `songTime` 等 **完全不存在** → 引擎不是 cocos2d-x，是 Arc **自研**
- vtable 反向追单例链路太长，且 PAC 阻断 xref
- **结论**：放弃静态找单例。改用「**hook player 高频虚函数自动捕获 this**」策略：
  - 启动时 Dobby hook `sub_100846950`（getPositionMs，每帧调）
  - 在 hook 回调里把 `this` ptr 缓存到 `static void *g_bgmPlayer`
  - 进度条 UI 直接用 `g_bgmPlayer` 调 vtable[7]/[8]
  - 同时 hook 回调返回值 = 当前谱面时间，免找时钟变量

#### 第 9 步：待办（更新版）

- [x] **核心**：把 Dobby 加进 Makefile，写 hook `sub_100846950` 自动捕获 `g_bgmPlayer`
- [x] **进度条 UI**：菜单加 UISlider；用 `g_bgmPlayer + vtable[7]` 实时显示位置；拖动→ vtable[8] seek
- [x] **暂停/恢复**：UISwitch → vtable[6] setPaused
- [ ] **核心**：写 hook `sub_100F6F67C`（setVolume）拦截声压 / 写新版自定义音量
- [ ] **变速测试**：`Channel::setFrequency` 已知偏移（早期 IDA 探到），写 hook 模板替换 time 注入算法
- [ ] **Stage B**：完全脱离 Substrate（fishhook 替换 `clock_gettime`/`gettimeofday`，objc swizzle 替换 `%hook`）
- [ ] 第一次 GitHub Actions CI 编译验证 + 修语法

#### 第 10 步：Dobby 接入 + 进度条 UI 代码 ✅

新增/修改文件：
- `include/dobby.h` — Dobby 最小头文件（仅声明 `DobbyHook`/`DobbyDestroy`/`DobbySymbolResolver`）
- `libs/README.md` — 占位说明，CI 自动放 `libdobby.a`
- `Makefile` — 加 `-I./include -L./libs -ldobby`
- `Tweak.x` — 加 player 自动捕获 + UI
- `.github/workflows/build-tweak.yml` — 加「Build Dobby (iOS arm64+arm64e)」step（cmake + iPhoneOS SDK，arch arm64;arm64e）

**关键设计**：

```c
#define ARC_OFF_GET_POSITION_MS 0x846950ULL    // sub_100846950 = vtable[7]

static _Atomic(void *)    g_bgmPlayer    = NULL;
static _Atomic(uint32_t)  g_last_pos_ms  = 0;
static _Atomic(uint32_t)  g_max_seen_ms  = 0;

static uint32_t hooked_get_position_ms(void *self, int channel) {
    uint32_t ret = orig_get_position_ms(self, channel);
    if (channel == 0) {                     // BGM 主轨
        atomic_store(&g_bgmPlayer, self);   // ← 自动捕获 player this
        atomic_store(&g_last_pos_ms, ret);
        if (ret > g_max_seen_ms) atomic_store(&g_max_seen_ms, ret);
    }
    return ret;
}
```

通过 `_dyld_get_image_name(i)` 找含 "Arc-mobile" 的 image base，加上偏移 0x846950 = 真实地址，DobbyHook 一次安装。

**vtable 调用 helper**：
```c
typedef void (*seek_fn)(void *, uint32_t, int);
seek_fn fn = (seek_fn)_player_vt_slot(self, 0x40); // slot 8 = seekTo
fn(self, ms, 0);
```

**菜单新增**：
- `UISlider` 进度条：min=0, max=动态追踪历史最大 ms，显示当前 ms；用户拖动结束 → `player_seek_ms()`
- `UILabel` 实时显示 "X.XXXs / Y.YYYs"
- `UISwitch` 暂停/恢复 → `player_set_paused()`
- 0.1s `NSTimer` 驱动 UI 刷新；玩家未开始播 BGM 时控件灰显，第一次播放后自动启用

**已知未解决**：
- 谱面总时长尚无法知（用「历史最大 ms」近似），后续可在 IDA 找 `getDuration` 类 wrapper
- bgmPlayer 的 vtable[37]（业务侧 setVolume 路径）未深挖；FMOD ChannelControl wrapper 已知但需要先获取 Channel* 才能调，所以暂不接



