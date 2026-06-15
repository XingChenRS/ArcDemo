# libs/

**免越狱 sideload 版 (v7.0+)** 不需要 `libdobby.a`。

计划中的 **TrollStore 分支** 将在此目录放置 Dobby 静态库，用于 inline hook 判定窗口等 `__TEXT` 函数。

CI 为 TrollStore 构建可参考:

```bash
# 示例: 拉取 release 并 lipo arm64+arm64e
curl -L -o libdobby.a https://github.com/jmpews/Dobby/releases/download/v1.x.x/libdobby_iphoneos_arm64.a
```
