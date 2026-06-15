# accDemo-arcaea (arcdemo)

Arcaea iOS **6.13.10** 练习辅助 dylib。

> **当前版本: v7.3.2**（TrollStore 判定需主程序 graft + 本 dylib 配套安装）

## TrollStore 判定安装（主程序 + dylib 必须同一套 graft）

1. 从**未 graft** 的 `Arc-mobile` 主程序开始
2. `python graft_hook.py --binary <Arc-mobile>`（在 `__DATA` 文件尾插入 `XRCH`+槽位，刷新 tramp）
3. 注入 `libAccDemoArcaea.dylib` + `libellekit.dylib` 到 `Frameworks/`
4. TrollStore 签名安装

成功日志示例：`graft_ok slot=... hook=... magic=XRCH tramp=0xf0002310`

**不能只换 dylib 不换主程序**（tramp 槽位地址必须一致）。

## 配置文件

所有设置写入 **`Documents/xrc-arcdemo.plist`**（与 `xrc-arcdemo.log` 同目录，可导出编辑）。

首次启动会从旧路径 `Library/Preferences/moe.low.arc.accdemoarcaea.plist` 自动迁移。

| 键 | 说明 | 默认 |
|----|------|------|
| `speedKeys` / `speed-N` | 变速档位列表 | 1.0 / 0.8 / 0.6 / 1.25 / 1.5 |
| `rateIndex` | 当前选中倍率索引 | 0 |
| `toast` | 切倍率 toast | YES |
| `buttonEnabled` | 浮动按钮 | YES |
| `judgeMaxMs` | Max 判定 ±ms (TrollStore) | 25 |
| `judgePureMs` | Pure ±ms | 50 |
| `judgeFarMs` | Far ±ms | 100 |
| `judgeLostMs` | Lost ±ms | 120 |

## 构建

```bash
make              # Sideload
make trollstore   # + 判定窗口自定义
```

## 功能

| 功能 | Sideload | TrollStore |
|------|----------|------------|
| 谱面/画面变速 + seek | ✅ | ✅ |
| 判定四档自定义 (输入框 / plist) | ❌ | ✅ |

BGM 始终 1.0×。Seek 不重置已判定音符。

## 注入（Sideload / TrollStore 均需）

设备上**没有** `CydiaSubstrate.framework`。必须把 **两个** dylib 放进 `Arc-mobile.app/Frameworks/`：

| 文件 | 说明 |
|------|------|
| `libAccDemoArcaea.dylib` | 本 tweak（CI 已把依赖改为 `@rpath/libellekit.dylib`） |
| `libellekit.dylib` | Substrate 替代，提供 MSHook 符号 |

主二进制需已有 `LC_LOAD_DYLIB @rpath/libAccDemoArcaea.dylib` 与 `LC_RPATH @executable_path/Frameworks`。可用仓库根目录 `inject.py` 一键注入。

CI artifact（sideload / trollstore）内均包含上述两个文件。

## License

GPL-2.0
