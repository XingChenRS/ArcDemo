# accDemo-arcaea

Arcaea iOS 6.13.10 鍏嶈秺鐙?(sideload) 鍙橀€?+ Seek 宸ュ叿鐨?Theos tweak銆?
鍩轰簬 [accDemo](https://github.com/brendonjkding/accDemo) (瓒婄嫳鐗? 閲嶅啓, 閫傞厤 iOS 16+ sideload 闄愬埗銆?

> **褰撳墠鐗堟湰: v6.6** 鈥斺€?鑼冨洿宸叉敹鏁涘埌銆屽彉閫?+ 闊抽/璋遍潰 seek銆? 涓嶅啀灏濊瘯 replay 宸插垽瀹氶煶绗︺€?
> 璇﹁ [DEVLOG.md](DEVLOG.md)銆?

## 鍔熻兘鑼冨洿

| 鍔熻兘 | 鐘舵€?| 瀹炵幇 |
|------|------|------|
| 鍙橀€?(0.6脳 / 0.8脳 / 1.0脳 / 1.25脳 / 1.5脳, 鍙嚜瀹氫箟) | 鉁?| `gettimeofday` fishhook + `GP.update` vtable swizzle |
| 闊抽 seek (鍓?鍚庝换鎰忎綅缃? | 鉁?| FMOD `setPosition` |
| 璋遍潰 clock seek | 鉁?| 鐩村啓 LogicNoteGroup 鐨?chart-ms clock |
| 宸插垽瀹氶煶绗﹀洖鏀?| 鉂?(鏈夋剰涓轰箣) | 闂簮浜岃繘鍒舵棤娉曞疄鐜?ArcCreate 鐨?`ResetJudgeTo` 璇箟, 寮鸿鍋氫細 UAF銆傞渶瑕侀噸鐜╄鐢ㄦ父鎴忓唴 **Retry** |
| 娴姩鎺у埗鎸夐挳 / 鑿滃崟 | 鉁?| WHToast + WQSuspendView |
| 杩涘害鏉?/ BGM 鎷栧姩 | 鉁?| 澶嶇敤闊抽 seek |

## 鏋舵瀯 (涓€鍙ヨ瘽)

- **闊抽鍩?*: FMOD `Channel::setFrequency` 鎸夊€嶇巼鎾斁
- **璋遍潰鍩?*: vtable swizzle `Gameplay::update` 鈫?姣忓抚璋?`_gp_retime_logic_clock` 璋冩暣 `LogicNoteGroup+48` 鐨?chart-ms clock
- **瑙嗚鍩?*: fishhook `gettimeofday` 鈫?CCDirector 鐨?deltaTime warp 鍚屾鍔ㄧ敾

iOS 16+ sideload 涓?`__TEXT` 琚?AMFI/CoreTrust 灏侀棴, 涓嶈兘 `mprotect+W`, 鎵€浠?*涓嶈兘** Dobby inline hook
涓讳簩杩涘埗鍑芥暟銆傚彧鑳藉姩 GOT (fishhook) 涓?`__DATA*` 閲岀殑 vtable (PAC swizzle)銆?

## 缂栬瘧

渚濊禆 [theos](https://github.com/theos/theos)銆?

```bash
git clone --recursive https://github.com/XingChenRS/arcdemo.git
cd arcdemo

# 鍑嗗 libdobby.a (铏界劧 v6.6 娌″疄闄呰皟鐢?Dobby, Makefile 浠嶉摼鎺?
# 璇﹁ libs/README.md

make package
```

CI: `.github/workflows/build-tweak.yml` 鑷姩鎷?Dobby release 骞跺嚭 `.deb`銆?

## 娉ㄥ叆

鎶婄敓鎴愮殑 `dylib` (浠?`.deb` 瑙ｅ嚭) 娉ㄥ叆鍒?Arcaea 6.13.10 IPA, 閲嶇鍚嶅悗瀹夎銆?

## 浣跨敤

1. 鍚姩 Arcaea, 灞忓箷宸︿晶鍑虹幇銆寈rc銆嶆诞鍔ㄦ寜閽?
2. 鍗曞嚮 = 鍒囧埌涓嬩竴妗ｅ€嶇巼, 鍙屽嚮 = 鎵撳紑鑿滃崟
3. 鑿滃崟鍐呭彲: 鎷栧姩杩涘害鏉?seek銆佽皟鑺傚€嶇巼鍒楄〃銆佺湅瀹炴椂鏃堕棿鍩熻瘖鏂潰鏉?

## Credits

- [accDemo](https://github.com/brendonjkding/accDemo) 鈥?鍘熷 jailbreak 妗嗘灦
- [WHToast](https://github.com/remember17/WHToast)
- [WQSuspendView](https://github.com/liwq87112/WQSuspendView)
- [fishhook](https://github.com/facebook/fishhook)
- [Dobby](https://github.com/jmpews/Dobby) (CI 鎷?
- [ArcCreate](https://github.com/Arcthesia/ArcCreate) 鈥?琛屼负鍙傝€?(鍙橀€?seek 妯″瀷)

## License

GPL-2.0 (娌跨敤涓婃父 accDemo)
