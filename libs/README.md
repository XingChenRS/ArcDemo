# libs/

Drop `libdobby.a` (arm64 + arm64e fat archive) here before building.

CI fetches it from <https://github.com/jmpews/Dobby/releases> automatically.

For local builds:

```bash
# example: download a release artifact
curl -L -o libdobby.a https://github.com/jmpews/Dobby/releases/download/v1.x.x/libdobby_iphoneos_arm64.a
```
