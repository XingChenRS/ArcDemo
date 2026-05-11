# accDemo-arcaea

Arcaea iOS 6.13.10 免越狱 (sideload) 变速 + Seek 工具的 Theos tweak。
基于 [accDemo](https://github.com/brendonjkding/accDemo) (越狱版) 重写, 适配 iOS 16+ sideload 限制。

> **当前版本: v6.6** —— 范围已收敛到「变速 + 音频/谱面 seek」, 不再尝试 replay 已判定音符。
> 详见 [DEVLOG.md](DEVLOG.md)。

## 功能范围

| 功能 | 状态 | 实现 |
|------|------|------|
| 变速 (0.6× / 0.8× / 1.0× / 1.25× / 1.5×, 可自定义) | ✅ | `gettimeofday` fishhook + `GP.update` vtable swizzle |
| 音频 seek (前/后任意位置) | ✅ | FMOD `setPosition` |
| 谱面 clock seek | ✅ | 直写 LogicNoteGroup 的 chart-ms clock |
| 已判定音符回放 | ❌ (有意为之) | 闭源二进制无法实现 ArcCreate 的 `ResetJudgeTo` 语义, 强行做会 UAF。需要重玩请用游戏内 **Retry** |
| 浮动控制按钮 / 菜单 | ✅ | WHToast + WQSuspendView |
| 进度条 / BGM 拖动 | ✅ | 复用音频 seek |

## 架构 (一句话)

- **音频域**: FMOD `Channel::setFrequency` 按倍率播放
- **谱面域**: vtable swizzle `Gameplay::update` → 每帧调 `_gp_retime_logic_clock` 调整 `LogicNoteGroup+48` 的 chart-ms clock
- **视觉域**: fishhook `gettimeofday` → CCDirector 的 deltaTime warp 同步动画

iOS 16+ sideload 上 `__TEXT` 被 AMFI/CoreTrust 封闭, 不能 `mprotect+W`, 所以**不能** Dobby inline hook
主二进制函数。只能动 GOT (fishhook) 与 `__DATA*` 里的 vtable (PAC swizzle)。

## 编译

依赖 [theos](https://github.com/theos/theos)。

```bash
git clone --recursive https://github.com/XingChenRS/arcdemo.git
cd arcdemo

# 准备 libdobby.a (虽然 v6.6 没实际调用 Dobby, Makefile 仍链接)
# 详见 libs/README.md

make package
```

CI: `.github/workflows/build-tweak.yml` 自动拉 Dobby release 并出 `.deb`。

## 注入

把生成的 `dylib` (从 `.deb` 解出) 注入到 Arcaea 6.13.10 IPA, 重签名后安装。

## 使用

1. 启动 Arcaea, 屏幕左侧出现「xrc」浮动按钮
2. 单击 = 切到下一档倍率, 双击 = 打开菜单
3. 菜单内可: 拖动进度条 seek、调节倍率列表、看实时时间域诊断面板

## Credits

- [accDemo](https://github.com/brendonjkding/accDemo) — 原始 jailbreak 框架
- [WHToast](https://github.com/remember17/WHToast)
- [WQSuspendView](https://github.com/liwq87112/WQSuspendView)
- [fishhook](https://github.com/facebook/fishhook)
- [Dobby](https://github.com/jmpews/Dobby) (CI 拉)
- [ArcCreate](https://github.com/Arcthesia/ArcCreate) — 行为参考 (变速/seek 模型)

## License

GPL-2.0 (沿用上游 accDemo)
