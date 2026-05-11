# xrc-arcdemo Devlog

---

## 椤圭洰鐩爣

灏?[accDemo](https://github.com/brendonjkding/accDemo) 鏀归€犱负閽堝 Arcaea iOS 鐨勫厤瓒婄嫳 dylib锛屾敮鎸佸彉閫熴€乻eek銆佺粌涔犮€?
---

## 褰撳墠鐘舵€?(v6.6, 2026-05-12)

### v6.6 鑼冨洿鏀舵暃 鈥?鎷嗘帀鎵€鏈?replay 瀹為獙鎬?hook

**鏈€缁堝喅瀹?*: Arcaea iOS 闂簮浜岃繘鍒舵棤娉曞疄鐜?ArcCreate 閭ｇ `ResetJudgeTo(timing)` 鐨?鏃犵姸鎬侀噸娲剧敓"璇箟
(姣忎釜 Tap/Hold/Arc/ArcTap 鍐呴儴閮芥湁鑷繁鐨?tick 璁℃暟鍣ㄣ€乻egment 绱㈠紩銆佽窛绂荤紦瀛樼瓑绛夌鏈?state,
RE 鍏ㄩ儴骞跺畨鍏ㄦ竻闆剁殑宸ヤ綔閲忓湪 sideload 闄愬埗涓嬩笉鐜板疄, 寮鸿鍋氫細瑙﹀彂 use-after-free / 宕╂簝)銆?
鎵€浠?v6.6 鎶?v5/v6 attempt 鍏ㄩ儴鍥炴粴, 鍙繚鐣欎袱浠朵簨:

1. **鍙橀€?*: `gettimeofday` fishhook + `GP.update` vtable swizzle 璋?`_gp_retime_logic_clock`銆?2. **Seek**: 浠呭仛涓や釜鍔ㄤ綔 鈥?闊抽璺?(FMOD setPosition) + 璋遍潰 clock 鍋忕Щ (logic+48 鐨?chart-ms 鐩存帴鍐?銆?   璺宠繃鐨?note 鐢辨父鎴忚嚜韬殑 `sub_100870344` 璺緞鑷姩鍒?lost; **宸叉紨濂忚繃鐨?note 涓嶄細閲嶇幇**,
   鎯抽噸鐜╄鐢ㄦ父鎴忓唴 Retry銆?
#### 鎷嗛櫎娓呭崟 (Tweak.x)
| 妯″潡 | v6.5 鐘舵€?| v6.6 |
|------|-----------|------|
| `LogicNote::isCompleted` vtable swizzle (5 涓?vtable) | 寮哄埗杩斿洖 0 (rewind grace window) | **绉婚櫎** (define / 鍏ㄥ眬鍙橀噺 / hook 鍑芥暟 / install loop 鍏ㄥ垹) |
| `tw_gp_update` 鍐?judge-window settings 涓€娆℃€?dump | 涓€娆℃€?RE 鎺㈡祴 | **绉婚櫎** |
| `player_seek_ms` 姝ラ (a) 娓呯┖娲昏穬闊崇鍒楄〃 + release 寮曠敤 | 寮哄埗鍒锋柊绌洪棿鏌ヨ | **绉婚櫎** (release_fn 瑙ｅ紩鐢ㄥ鑷?UAF) |
| `player_seek_ms` 姝ラ (b) 閲嶆柊婵€娲绘墍鏈夐煶杞?byte[0]=1 | 澶嶆椿宸叉 track | **绉婚櫎** (鍙兘澶嶆椿宸茶閲婃斁鐨?track) |
| `player_seek_ms` 姝ラ (c) 娓呯┖浜嬩欢闃熷垪 | | **绉婚櫎** |
| `player_seek_ms` 姝ラ (d) 娓呴櫎缁撴潫鏍囧織 | | **绉婚櫎** |
| `player_seek_ms` 姝ラ (e) sk 閲嶇疆 (combo/score/PFL/late/early) | v6.5 淇ソ甯冨眬 | **绉婚櫎** (鏃?replay 灏辨病蹇呰娓? 鐣欑潃鏃ф暟涔熸槸鍙帶鐘舵€? |
| `g_seek_target_ms` / `g_rewind_until_us` 绛?replay 鐩稿叧鍏ㄥ眬 | | **绉婚櫎** |
| 璇婃柇闈㈡澘 isComp 琛?/ vtcodes / seekTgt | | **绉婚櫎** |

#### 宸茬‘璁ゅ畨鍏ㄧ殑浜?(鍓嶄竴娆?RE 鐣欎綔璁板綍)
- `sk` 閲嶇疆鏈韩璺緞瀹夊叏 鈥?`sub_100A7DFC4` (HUD syncer) / `sub_100A7E71C` / `sub_100A7DD20` /
  `sub_100870344` 鍚勮嚜鍙嶇紪鍚庢棤 UAF, 鎶?sk 瀛楁鍐?0 涓嶄細寮曞彂宕╂簝銆?- 鎵€浠ュ墠鍚?seek 宕╂簝**涓嶅湪 (e) 姝?*, 鐪熸鍑舵墜鏄?(a) 姝ョ殑 `release_fn(0xDB1A28)` 瑙?active-list 寮曠敤銆?- 鐭ラ亾杩欎竴鐐逛箣鍚庢垜浠粛鐒堕€夋嫨鎶?(e) 涓€璧峰垹 鈥?鍥犱负娌℃湁 replay 瀹冩棤鎰忎箟, 瓒婂皯鍔?sk 瓒婄ǔ銆?
#### UI 姹夊寲 (鏈)
- "Arcaea Speed (XRC)" 鈫?"Arcaea 鍙橀€?(XRC)"
- "Audio: ... | Chart: ... | Visual: ..." 鈫?涓枃鏋舵瀯璇存槑 (淇濈暀 GP.update / FMOD 绛夋妧鏈湳璇?
- "BGM Control" / "BGM (waiting...)" 鈫?"BGM 鎺у埗" / "BGM (绛夊緟涓?..)"
- "Show toast on rate change" 鈫?"鍒囨崲鍊嶇巼鏃舵彁绀?
- "Hook (ON=warp at rate)" 鈫?"Hook 鐘舵€?(寮€ = 鎸夊€嶇巼 warp)"
- "GP.update (chart retime)" 鈫?"GP.update (璋遍潰 retime)"
- "Time domains (live)" 鈫?"鏃堕棿鍩?(瀹炴椂)"
- "Speed (tap=select, hold=delete)" 鈫?"鍊嶇巼 (鍗曞嚮=閫夋嫨, 闀挎寜=鍒犻櫎)"
- "+ Add speed" 鈫?"+ 娣诲姞鍊嶇巼"
- "Close" 鈫?"鍏抽棴"
- toast `(tap2x=menu)` 鈫?`(鍙屽嚮鎵撳紑鑿滃崟)`

#### 璇婃柇闈㈡澘鐦﹁韩
鏃?
```
rate / freeze / rwnd / real-warp-drift / mach-audio-chart / 螖
isComp inst=N [OOOOO] calls=... z=... o=...
seekTgt=NNNms
```
鏂?
```
rate / freeze
real-warp-drift
mach-audio-chart
螖(chart-audio)
```

#### 楠岃瘉缁撹 (涓?v6.5 鍏变韩)
- 鉁?鍙橀€?(0.6脳 / 0.8脳 / 1.0脳 / 1.25脳 / 1.5脳): 闊抽/璋遍潰/瑙嗚涓夊煙鍚屾 OK
- 鉁?鍓嶅悜 seek + 鍚庡悜 seek: 涓嶅穿婧?(鍥犱负娌″湪鍔ㄩ煶绗︾姸鎬佷簡)
- 鈿?seek 涔嬪悗**宸插垽瀹氱殑闊崇涓嶄細閲嶇幇** 鈥?杩欐槸鏈夋剰涓轰箣鐨勮寖鍥? 鎯抽噸鐜╄鐢?Retry
- 鉁?鍒ゅ畾绐楀彛瀹屾暣 (娌″姩 settings)
- 鉁?HP / 娈典綅璇勭骇 / Pure-Far-Lost 璁℃暟涓庡師鐗堜竴鑷?
#### 鍙傝€冭祫鏂?- 鍒ゅ畾绐楀彛閫嗗悜绗旇: [arcmodwiki/docs/ios-judgement-windows.md](../arcmodwiki/docs/ios-judgement-windows.md)
- ArcCreate 瀵规瘮 (`ChartService.ResetJudge` / `TimingGroup.ResetJudgeTo`): 楠岃瘉浜?source-level 閲嶆淳鐢熷湪闂簮浜岃繘鍒朵笂鐨勪笉鍙鎬с€?
---

## 鍘嗗彶: v6.5 (2026-05-12)

### v6.5 鏀瑰姩 鈥?淇 seek-replay sk 閲嶇疆 (甯冨眬宸?RE 姝ｇ‘)

`player_seek_ms` 姝ラ (e) 閲嶆柊鍔犲洖, 杩欐浣跨敤鍙嶇紪楠岃瘉鍚庣殑瀹屾暣鍋忕Щ闆嗗悎
(鍙傝涓嬫柟 ScoreKeeper 鐪熷竷灞€琛?銆傚叧閿慨澶嶇偣 = sk+104 (far_count) 涓?sk+128..140 (late/early 鍏ㄥ) 涔嬪墠 v6.3 鍏ㄦ紡浜? 杩欐墠鏄紑灞€鍗崇粨鏉熺殑鐪熷洜銆?鍙﹀ logic+756/760/812 (UI 缂撳瓨) 涔熶竴骞舵竻闆? 鍚﹀垯涓嬩竴甯?sub_100A7DD20
瑙﹀彂鏉′欢 `combo != cached_combo` 浼氬埛涓€娆℃棫鏁般€?
### v6.5 RE 鏀惰幏 鈥?鍒ゅ畾绐楀彛鍏ュ彛宸查攣瀹?(浣?iOS sideload 鐩存帴 patch 涓嶅彲琛?

`sub_10086EE70` (LogicNoteGroup tick, 鐢?sub_10086E728 璋冪敤) 鍏ュ彛閫昏緫:

```c
if (sub_100868E28(*(GP+0x28))) {           // = *(BYTE)(chart+272), 榛樿 0
    v91 = (*(*(*(GP+0x20))[0x268])[0xE0])(...);  // late 鑷畾涔?    v90 = (*(*(*(GP+0x20))[0x268])[0xE0])(...);  // early 鑷畾涔?} else {
    v90 = 300;   // 榛樿 early-window
    v91 = 700;   // 榛樿 late-window
}
// ...
v66 = (int)((v65 - v91) / 10000.0);   // 鍒ゅ畾绐椾笅鐣?(screen-y 鍗曚綅)
v67 = (int)((v65 + *(int*)(a1+24)) / 10000.0);
v68 = (int)((v85[i] - v91) / 10000.0);
v81 = (LogicArcNote ? v91 : v90);     // arc 鐢?late, tap 鐢?early
```

**榛樿鍊煎湪 __TEXT 鍐欐**:
- `0x10086EF04: MOV W9, #0x2BC (700)`  late-window
- `0x10086EF08: MOV W8, #0x12C (300)`  early-window

**涓轰粈涔堜笉鑳界洿鎺?patch**: Tweak.x:181 鐨勬敞閲婂凡璇存槑 鈥?iOS 16 sideload 涓?`mprotect(rwx)` / `vm_protect VM_PROT_COPY` 鍦?__TEXT 涓婁細鐮村潖 AMFI/CoreTrust
鐨?page seal, 鍏跺畠绾跨▼瑙﹀彂璇ラ〉鏃朵細琚?EXC_BAD_ACCESS (Instruction Abort) 骞叉帀銆?__DATA/__DATA_CONST 鍐欏氨娌￠棶棰?(vtable swizzle 鏄繖涔堝仛鐨?銆?
**v6.6 璁″垝 鈥?vtable 鍔寔鏂规**:
- chart 瀹炰緥 +272 瀛楄妭鏈変釜 `use_custom_window` flag, 璁句负 1 鏃惰蛋鑷畾涔夊垎鏀?- 鑷畾涔夊垎鏀皟 `(*(*(GP+0x20))[0x268])[0xE0]()` 鍙?float late/early
- 瀹炵幇璺緞:
  1. 鍦?GP.update hook 閲屾崟鑾?chart 瀹炰緥 (a1+0x28 deref)
  2. 璁?chart+272 = 1 寮哄埗璧拌嚜瀹氫箟鍒嗘敮
  3. swizzle `*(chart+0x268)` 鎸囧悜鐨勫璞＄殑 vtable[0xE0/8],
     鏇挎崲鎴愭垜浠殑 stub 杩斿洖 `g_judge_user_*_window_x100 / 100.0f`
  4. UI 鍔?slider: pure 缂╂斁 0.5..2.0x
- 闇€瑕佸厛鎶撲竴娆″疄渚嬫懜娓呮 `*(chart+0x268)` 鏄粈涔堢被 (绫绘垚鍛?settings 鎸囬拡?
  杩樻槸鏌愪釜 singleton?), 鐒跺悗鎵嶈兘纭 vtable swizzle 鏄惁瀹夊叏 (鍗曞疄渚嬭繕鏄?  澶氬疄渚嬪叡浜?vtable, 涓€鏀瑰叏鏀规槸鍚︽湁鍓綔鐢?銆?
### 宸茬‘璁?ScoreKeeper 鐪熷竷灞€

璇﹁涓嬫柟 "ScoreKeeper 鐪熷竷灞€ (渚?v6.5 閲嶆柊鍔犲洖 seek 閲嶇疆浣跨敤)" 涓€鑺傘€?
---

## 鍘嗗彶 v6.4 鈥?鍒犻櫎闊抽 hook + 鍥炴粴 ScoreKeeper 閲嶇疆 (浣滃簾)

**鍒犻櫎鐨勪唬鐮?**
- `apply_speed_to_all_channels` (FMOD `Channel::setFrequency` 璋冪敤)
- `player_collect_channels` (鏋氫妇 channel 琛?
- `g_base_freq[ARC_MAX_CHANNELS]`, `g_ch_set_frequency`, `g_ch_get_frequency` 鍙婂搴旂被鍨嬪畾涔?- `ARC_OFF_CH_SET_FREQUENCY`, `ARC_OFF_CH_GET_FREQUENCY` (offsets 涓嶅啀闇€瑕?
- `g_audio_meas_*`, `s_audio_meas_*` (rate 娴嬮噺鍏ㄥ)
- `tw_mtp_getpos` 閲岀殑 500ms 婊戠獥鏍″噯鍧?- `time_warp_set_rate` 閲岀殑 `apply_speed_to_all_channels()` 璋冪敤
- `player_seek_ms` 閲岀殑 `apply_speed_to_all_channels()` 璋冪敤
- 0.5s NSTimer 閲岀殑 `apply_speed_to_all_channels()` + base_freq 閲嶇疆
- 闈㈡澘 `audio.meas X.XXXx N=N` 琛?(鏇挎崲涓?`螖(chart-audio) Nms`)

**鍥炴粴鐨勪唬鐮?**
- `player_seek_ms` 姝ラ (e) ScoreKeeper 閲嶇疆鏁存銆傚師鍥?
  瀹炴祴寮€濮嬫父鎴忓悗绗竴鎵归煶绗﹀嚭鐜版椂鐩存帴璺崇粨绠?0鍒嗐€傝鏄庢垜鏍囩殑 sk[+92]/[+96]/[+100]/[+104]/[+108]
  閲岃嚦灏戞湁涓€涓叾瀹炴槸**鎬昏氨闈?note 鏁?*涔嬬被鐨勪笉鍙橀噺,琚浂鍖栧悗涓嬩竴甯?`judged>=total`
  绔嬪嵆瑙﹀彂缁撴潫銆傞渶瑕侀噸鏂板弽姹囩紪 `sub_100A7DFC4` 鐨?score-update 鍏ュ彛纭姣忎釜鍋忕Щ
  鐨勭湡瀹炶涔夈€?*娉ㄦ剰: 浠ュ墠 seek-replay 娌″穿(鍙槸璁″垎涓嶉噸缃?鏄洜涓烘牴鏈病鍔?sk!**

**淇濈暀鐨?**
- 浠呬袱涓湡 hook: `gettimeofday` (fishhook) + Gameplay vtable[update] (PAC vtable swizzle)
- LogicNote `isCompleted` vtable swizzle (5 瀛愮被) 鐢ㄤ簬 seek-replay 璁?note 閲嶅嚭
- MTP `getPosition` vtable swizzle: **鍙鍙?*,浣滀负杩涘害鏉?+ diag 鏁版嵁婧?- MTP `seekTo` vtable 璋冪敤: `player_seek_ms` 瑙﹀彂
- 璋遍潰绔?`_gp_retime_logic_clock` 鐙珛 rate 鎺ㄨ繘 (涓嶇粦 audio)

**閬楃暀闂:**
- 闊崇敾涓嶅悓姝?(audio 濮嬬粓 1.0x, chart 鎸?rate)銆傜敤鎴峰喅瀹氭帴鍙?鎼佺疆銆?- ScoreKeeper 鐪熷疄甯冨眬鏈煡, seek-replay 鏃犳硶閲嶇疆璁″垎銆?
### ScoreKeeper 鐪熷竷灞€ (渚?v6.5 閲嶆柊鍔犲洖 seek 閲嶇疆浣跨敤)

鏉ユ簮: 鍙嶆眹缂?`sub_100A7DFC4` (UI updater) + `sub_100A7E71C` (judge label updater)銆?鍚庤€呮寜 `pureLabel/farLabel/lostLabel/earlyLabel/lateLabel` 瀛楃涓?100% 閿佸畾璇箟銆?
| 鍋忕Щ | 绫诲瀷 | 瀛楁 | 澶囨敞 |
|---|---|---|---|
| sk+20  | i32 | score_displayed | UI updater 鍐欏洖 a1+760 |
| sk+28  | f32 | HP | |
| sk+76  | f32 | HP_max | |
| sk+92  | i32 | combo | UI 姣斿 a1+756 瑙﹀彂 sub_100A7DD20 |
| sk+96  | i32 | score_raw | PM 鎶曞奖绱姞鍣? **涓嶆槸** pure_count |
| sk+100 | i32 | pure_count | "pureLabel-fullnolocalize" |
| sk+104 | i32 | far_count | "farLabel" |
| sk+108 | i32 | lost_count | "lostLabel" |
| sk+128 | i32 | late_count_in_pure | "lateLabel" 榛樿鍒嗘敮 |
| sk+132 | i32 | early_count_in_pure | "earlyLabel" 榛樿鍒嗘敮 |
| sk+136 | i32 | late_count_in_max_pure | "max-pure" 妯″紡鍙犲姞 |
| sk+140 | i32 | early_count_in_max_pure | "max-pure" 妯″紡鍙犲姞 |

鎬?notes 涓嶅湪 sk 鍐? 閫氳繃 `sub_1009C756C(sk) = *(*(sk+176)+184)` 浠?chart_data 璇汇€?sk 鐪熷疄澶у皬 鈮?144 瀛楄妭, v6.3 鐢?`addr_readable(sk, 128)` 鑼冨洿閮戒笉澶熴€?
**v6.3 bug 澶嶇洏**: 浠ｇ爜婕忔竻 sk+104(far) 涓?sk+128..140(late/early 鍏ㄥ)銆?閲嶇疆鍚?UI updater 绠?v14 = pure(0)+far(鏃?+lost(0) = 鏃?far, 鐒跺悗
sub_100A7E71C 瑙﹀彂鏉′欢 `judged != cached_total` 浠嶇劧鎴愮珛, 鍚庣画甯?杩涘叆寮傚父鍒嗘敮 (鍏蜂綋鎬庝箞杩炲埌 a3+316=1 song-end 杩橀渶杩涗竴姝ヨ拷)銆?
**v6.5 姝ｇ‘閲嶇疆搴忓垪** (寰呭姞):
```c
*(int32_t *)((char*)sk + 20)  = 0;  // score
*(int32_t *)((char*)sk + 92)  = 0;  // combo
*(int32_t *)((char*)sk + 96)  = 0;  // score_raw
*(int32_t *)((char*)sk + 100) = 0;  // pure
*(int32_t *)((char*)sk + 104) = 0;  // far  <-- v6.3 婕忎簡
*(int32_t *)((char*)sk + 108) = 0;  // lost
*(int32_t *)((char*)sk + 128) = 0;  // late_pure
*(int32_t *)((char*)sk + 132) = 0;  // early_pure
*(int32_t *)((char*)sk + 136) = 0;  // late_max_pure
*(int32_t *)((char*)sk + 140) = 0;  // early_max_pure
// 鍚屾椂 a1+756=0, a1+760=0, a1+812=0 (UI updater 缂撳瓨), a1+816?
```

---

## 鍘嗗彶 v6.3.1 (浣滃簾)

### v6.3.1 鏀瑰姩 鈥?鍥為€€ chart slave, 浠呬繚鐣?score-keeper reset

鐢ㄦ埛鍙嶉: chart slave 鍒?audio 浠讳綍褰㈠紡閮戒細寮曞叆寤惰繜鎴栨娊鎼?(FMOD `getPos`
ms 閲忓寲 + 甯ч棿涓嶅潎鍖€ + 閲忓寲寰€澶? 鍗充娇 鈮?ms 闃堝€间粛鐒朵細鑲夌溂鍙璺?銆?**鍙橀€熷洖鍒?v6.2 鎬濊矾**: chart 绔嫭绔嬫寜 rate 鎺ㄨ繘 (`(1-rate)*delta`),
audio 绔?`setFrequency(base*rate)`, **涓嶅仛浠讳綍瀵归綈缁戝畾**銆傚悗缁鏋?瑕佸仛绮剧‘瀵归綈, 鎬濊矾鍙湁涓夐€変竴: (a) 瀹屽叏鐩稿悓 rate; (b) 涓嶅悓 rate +
鍥哄畾寤惰繜琛ュ伩; (c) 涓嶅仛闊崇敾鍚屾鍙橀€熴€傚綋鍓嶉粯璁?(a), 璇樊闈犵敤鎴锋帴鍙椼€?
**淇濈暀:** Seek 鏃?ScoreKeeper 閲嶇疆 (杩欓儴鍒嗙敤鎴峰厛楠岃瘉)銆傚竷灞€鏉ヨ嚜
`sub_100A7DFC4` 鍙嶆眹缂? `sk = *(LogicNote+56)`:
  sk[+20] score, sk[+92] combo, sk[+96] pure, sk[+100] far,
  sk[+104] lost, sk[+108] late/early 鈥斺€?鍏ㄩ儴娓呴浂銆侶P 涓嶅姩銆?
**鍒犳帀:** `g_audio_corr_x10000` (FMOD 棰戠巼鍙嶉鏍″噯), `apply_speed_to_all_channels`
閲岀殑 corr 涔樺瓙銆俙g_audio_meas_rate_x1000` 娴嬮噺淇濈暀浣滈潰鏉胯瘖鏂€?闈㈡澘璇婃柇琛? `audio.meas X.XXXx  N=N  螖=Nms` (螖 = chart - audio, 浠呰娴?銆?
---

## 鍘嗗彶 v6.3 (浣滃簾)

**鍙橀€熸€濊矾鎹?** 涓嶅啀鍋?FMOD 棰戠巼鑷牎鍑?(`g_audio_corr_x10000` 鍒犻櫎)銆傜悊鐢? 鍗充娇
FMOD 瀹為檯閫熺巼鏈?卤2% 閲忓寲璇樊, chart 绔彧瑕佺洿鎺ヨ `audio_pos_ms` 鍙嶇畻 `clk[16]`
灏辫兘璁?`chart_displayed == audio_pos`, 姘镐笉婕傜Щ, 鑰屼笖涓嶉渶瑕佹瘡甯?`(1-rate)*delta`
绱Н鈥斺€旈浂璇樊绱銆侀浂鎶栧姩鏉ユ簮銆?
- `_gp_retime_logic_clock` 閲嶅啓:
  ```
  clk[16] = steady_clock_ms - audio_pos_ms - clk[40]
  ```
  褰撳樊璺?鈮?ms 鎵嶅啓, 璁?steady_clock 骞虫粦鎻掑€笺€?.0x 鏃跺樊 鈮?0ms 涓嶅姩,
  瀹屽叏浜ょ粰娓告垙鑷繁璺戙€?- `apply_speed_to_all_channels` 绠€鍖栦负 `base * rate` (鍘绘帀 corr 涔樺瓙)銆?- `tw_mtp_getpos` 婊戠獥淇濈暀, 浠呬綔闈㈡澘璇婃柇鐢?(`g_audio_meas_rate_x1000`)銆?- 闈㈡澘璇婃柇琛屾崲涓?`audio.meas X.XXXx  N=N  螖=Nms` (螖 = chart - audio)銆?
**Seek 閲嶆斁:** 涔嬪墠鍙?hook isCompleted 璁╅煶绗﹂噸鍑? 浣?*璁″垎鍣?(ScoreKeeper)
鐙珛绱 combo / score / pure / far / lost**, 娌￠噸缃€傜被姣?ArcCreate 鐨?`ChartService.ResetJudge() + ScoreService.ResetScoreTo() + JudgementService.ResetJudge()`,
鏈増鏈弽姹囩紪 `sub_100A7DFC4` (per-frame UI updater) 鎽稿嚭 ScoreKeeper 甯冨眬
(`sk = *(LogicNote+56)`):
  - sk[+20] score, sk[+92] combo, sk[+96] pure, sk[+100] far, sk[+104] lost, sk[+108] late/early
  
`player_seek_ms` 姝ラ (e) 鎶婅繖浜涘瓧娈靛叏閮ㄥ綊闆? HP 鏆傛椂涓嶅姩銆備笅涓€甯?isCompleted
hook 璁╅煶绗﹂噸鍑?鈫?鐜╁閲嶆柊鎵?鈫?ScoreKeeper 鑷劧閲嶆柊绱姞銆?
---

## 鍘嗗彶 v6.2

### v6.2 鏀瑰姩

- **闊?璋辫В鑰?* (淇鍙橀€熸娊鎼?: `_gp_retime_logic_clock` 鍒犻櫎 `chart鈫抋udio` 鐨?5%/甯т綆閫氭媺鍥炪€備袱璺椂閽熺嫭绔嬫寜 `target_rate` 鎺ㄨ繘銆?- **闊抽鑷牎鍑?*: `tw_mtp_getpos` 婊戠獥 (~500ms) 瀹炴祴 `audio_dms / real_dms = measured_rate`, 涔樻€ч€艰繎 `corr 鈫?corr 脳 (target/measured)` (鍗曟卤5%, 鎬诲箙卤20%), `apply_speed_to_all_channels` 鐢?`base 脳 rate 脳 corr` 鎶垫秷 FMOD 棰戠巼閲忓寲璇樊銆?- **鍒犻櫎 Pause BGM**: `player_set_paused` + 鑿滃崟寮€鍏?+ `pauseChanged:` 鍏ㄩ儴绉婚櫎 (瀹炴祴涓?freeze 鍙岄噸鏆傚仠鍐茬獊)銆?- **闈㈡澘鏂板** `audio.meas X.XXXx  corr X.XXXx  N=N` 涓€琛岀敤浜庤瘖鏂€?- **淇 isCompleted 鍏ㄩ儴澶辫触 (inst=0/MMMMM)**: `kArcLogicNoteVtables[]` 鍋忕Щ涔嬪墠灏戝啓浜嗕竴浣?(`0x303FD0` 搴斾负 `0x1303FD0`), 瀵艰嚧姣忎釜 vtable 鎸囧悜鐨勬槸 `__DATA` 娈典箣澶栫殑闅忔満鍐呭瓨, slot[5] 璇诲埌 PAC 鍔犵鐨勫爢鎸囬拡 (`0x1714a0801ef` 涔嬬被), 涓?target `image+0x7E27B8` 涓嶅尮閰? 5 涓叏閮?`M`銆備慨姝ｄ负 `0x1303FD0 / 0x130BC40 / 0x130DBB0 / 0x13171F0 / 0x13388F0` 鍚?IDA 楠岃瘉 slot[5] 瀛楄妭姝ｅソ鏄?`b8 27 7e 00 01 ...` = `0x1007E27B8`銆?
## 鍘嗗彶 v6.1

### 宸插疄鐜?
- **闊抽鍙橀€?*: FMOD `Channel::setFrequency(base 脳 rate)`
- **璋遍潰鍙橀€?*: `Gameplay.update` vtable hook 鈫?`_gp_retime_logic_clock` 淇敼 `clock[16]`
- **瑙嗚鍙橀€?*: `gettimeofday` fishhook 鈫?CCDirector deltaTime 鑷姩鍙橀€?- **Seek**: MTP::seekTo(闊抽) + clock[40] 鍋忕Щ(璋遍潰) 鍙岀郴缁熷榻?- **Seek-replay (v6 timing-aware)**: vtable-swizzle `LogicNote::isCompleted` (5 涓瓙绫?vtable+40)
  + 1.5s grace window 鏈熼棿锛宧ook 璇诲彇 `note.timing (LogicNote+20)` 涓?seek 鐩爣姣旇緝锛?  - `note.timing >= target - 120ms` 鈫?杩斿洖 0锛堟湭鏉ラ煶绗﹂噸鏂板嚭鐜帮級
  - `note.timing < target - 120ms`  鈫?杩斿洖鍘熷疄鐜帮紙杩囧幓闊崇淇濇寔瀹屾垚锛屾潨缁濋棯鐜帮級
  - timing 瀛楁璇诲け璐?鈫?fallback 鍒?v5 妯″紡锛堢獥鍙ｅ唴缁熶竴杩斿洖 0锛?  - 绐楀彛鍏抽棴 鈫?瀹屽叏閫忔槑 passthrough锛岄浂骞叉壈甯歌鎾斁
- **杩涘害鏉?*: 瀹炴椂鏄剧ず浣嶇疆鍜屾€绘椂闀?- **鏆傚仠/鎭㈠**: freeze 鏈哄埗 + retime 鍩哄噯閲嶇疆
- **浠ｇ爜閲?*: ~1400琛? 1 fishhook + 7 vtable hook (MTP::getPos / GP::update / 5脳LogicNote::isCompleted)
- **B-1 璇婃柇闈㈡澘** (2026-05-11): UI 瀹炴椂鏄剧ず 4 涓椂閽熷煙 (real/warp/mach/audio/chart) + freeze 娣卞害 + isCompleted 鍛戒腑鍒嗗竷, 鐢ㄤ簬鐜板満瑙傚療鏃堕挓婕傜Щ鍜屾殏鍋滃紓甯搞€?- **v6.1 (2026-05-11) 涓夐」淇**:
  1. **isComp inst=0 璇婃柇鍗囩骇**: install 璺緞浠?卤64 slot 鎵弿鏀逛负鐩存帴璇?vtable[5]锛屾瘡涓?vtable 鍗曠嫭璁?OK / Unreadable / Mismatch / mProtect-fail 鐘舵€佺爜锛岄潰鏉挎樉绀?`inst=N [OOOOO]` + 澶辫触鏃舵墦 `vt[i] seen=0x... (target=0x...)` 甯姪涓€鐪肩湅鍑烘牴鍥犮€?  2. **寤惰繜婕傜Щ淇硶 (drift correction)**: `_gp_retime_logic_clock` 澧炲姞浣庨€氭牎姝ｏ細姣忓抚鎶?`clock[16]` 鎷夊悜 `chart_clock - audio_pos = 0`锛屽箙搴?`drift/20` 涓婇檺 卤20ms/甯с€傚交搴曟秷闄ら潪 1脳 鍊嶇巼闀挎椂闂寸疮绉殑 chart vs audio 婕傜Щ (瀹炴祴杈?5+ 绉?銆?  3. **鏆傚仠鏃惰皟閫熷け鏁堜慨娉?*: `apply_speed_to_all_channels` 鍦?`freeze_count > 0` 鏃?early-return 鈥?閮ㄥ垎 FMOD 瀹炵幇浼氬洜 setFrequency 鎶?paused channel 瑙ｆ殏鍋滐紝瀵艰嚧鐢ㄦ埛鎰熺煡 "鏆傚仠鏃惰皟閫熸棤鍝嶅簲"銆?
### 寰呴獙璇?(v6)

- LogicNote.timing @ +20 鐨勫亸绉讳粠 IDA 鎺ㄧ悊锛坄sub_10086EE70` 涓?`*(_DWORD*)(*v11+20) > v15-120` 妯″紡锛夆€?闇€鐪熸満鍔犳棩蹇楃‘璁ゃ€?- 5 涓?vtable swizzle 瀹為檯鍛戒腑鐜囷細UI 璁℃暟鍣?`g_iscompleted_calls / force_zero / force_one` 楠岃瘉銆?- 瀛愮被 (LogicArcNote 鏈?+164/+288/+296 瀛楁) 鏄惁闇€瑕佹寜 typeinfo 鍒嗘敮銆?
### 宸插簾寮?
- **v4**: 閬嶅巻 `LogicChart+32/+40` 閲嶇疆 byte[12]/[13]锛氳繍琛屾椂 +40 鏄?chart_data 鎸囬拡锛屼笉鏄煶绗﹀悜閲忔湯灏俱€?- **v5 byte 娓呴浂**: 鍦?isCompleted hook 鍐?`*(uint8_t*)+12 = 0` `+13 = 0` 瀹屽叏鏄?no-op 鈥?  鍙嶇紪璇?vtable[3] (`sub_1007E2788`) 鏄剧ず byte +48..+55锛堣嚜鎴戜滑鎯宠薄鐨?+12/+13 涓嶅悓锛夋槸
  姣忓抚鐢?vtable[3] 閲嶅啓鐨勮窛绂荤紦瀛橈紙`chart_time + base_offset`锛夛紝涓嶆槸鐘舵€併€倂6 宸插垹闄よ繖涓よ銆?- `_gp_drift_correct` 闊崇敾绾犲亸锛氳氨闈㈡寔缁娊鎼愩€?
---

## 鏋舵瀯

### 鍙橀€熺郴缁?

| 缁勪欢  | 鏈哄埗                                                       | 璇存槑    |
| --- | -------------------------------------------------------- | ----- |
| 闊抽  | `Channel::setFrequency(base 脳 rate)`                     | 闇€涓诲姩璋冪敤 |
| 璋遍潰  | `tw_gp_update` 鈫?`_gp_retime_logic_clock` 淇敼 `clock[16]` | 姣忓抚璋冩暣  |
| 瑙嗚  | `gettimeofday` fishhook 鈫?CCDirector delta               | 瀹屽叏鑷姩  |


### Seek 鏈哄埗

```
Gameplay(+928) 鈫?LogicChart(+48) 鈫?Clock
display_ms = clock[32] - clock[40]

seek to X ms:
  1. freeze warp
  2. MTP::seekTo(ms, 0) 鈫?闊抽璺宠浆
  3. apply_speed 鈫?閲嶈棰戠巼
  4. clock[40] += (cur_display - X) 鈫?璋遍潰璺宠浆
  5. unfreeze warp
```

### 鏃堕挓缁撴瀯 (LogicChart+48)

```
+16: int32  start_reference (steady_clock ms)
+32: int32  accumulated_time
+40: int32  base_offset (display = [32] - [40])
+45: byte   internal_drive_flag
+52: int32  external_position
```

---

## 鍏抽敭鍋忕Щ (Arcaea 6.13.10)


| 绗﹀彿                               | 鍋忕Щ                                |
| -------------------------------- | --------------------------------- |
| Gameplay.update vtable           | `0x136E1C0`                       |
| Gameplay.update fn               | `0xB3AD70`                        |
| MTP vtable                       | `0x1312860`                       |
| MTP::seekTo                      | `0x84699C`                        |
| LogicChart 鏃堕挓鏇存柊                  | `0x8C2FEC`                        |
| LogicChart 鏃堕棿璇诲彇                  | `0x86E69C`                        |
| LogicChart::update               | `0x86E728`                        |
| 闊崇绌洪棿鏌ヨ/娲昏穬绠＄悊                      | `0x86EE70`                        |
| LogicNote::isCompleted (鍏ㄥ瓙绫诲叡鐢? | vtable+40 鈫?`0x7E27B8`            |
| TapNote 鍒ゅ畾鏍囧織                     | vtable+48 鈫?`0x14172C` (byte[13]) |
| TapNote 鍛戒腑鏍囧織                     | vtable+64 鈫?`0x118A80` (byte[12]) |
| LogicChart 鏋勯€犲伐鍘?                 | `0xB1EA08`                        |
| LogicChart::init                 | `0x865B28`                        |
| Gameplay 缁撴潫/retry                | `0xB3CC7C`                        |
| refcount addref                  | `0xDB1A18`                        |
| refcount release                 | `0xDB1A28`                        |

### LogicNote 瀛愮被 vtable 璧峰鍦板潃 (5 涓? 鍧囧惈 isCompleted@slot+40 鎸囧悜 0x7E27B8)

| 鍋忕Щ        | 澶囨敞                                       |
| --------- | ---------------------------------------- |
| `0x303FD0` |                                          |
| `0x30BC40` |                                          |
| `0x30DBB0` | LogicTapNote (typeinfo @`0x10130DC00`)   |
| `0x3171F0` |                                          |
| `0x3388F0` |                                          |


---

## LogicChart 鍐呭瓨甯冨眬 (IDA 閫嗗悜)

```
LogicChart (0x118 = 280 bytes):
  +0:   vtable
  +8:   refcount base
  +16:  song_id (ptr)
  +24:  difficulty_data (ptr)
  +32:  notes_vector begin (init 鏃? 杩愯鏃惰涔夊緟纭)
  +40:  notes_vector end / chart_data ptr (杩愯鏃?
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

## LogicNote 缁撴瀯 (IDA 閫嗗悜, v6 淇)

```
LogicNote (base class):
  +0..7:    vtable
  +8..11:   refcount (int32)
  +12..13:  bytes - 鍚箟涓嶆槑; v4/v5 璇互涓烘槸 hit/judged 鏍囧織, v6 鍙嶇紪璇?vtable[3] 鍚?            纭 isCompleted 鐪熸璇荤殑涓嶅湪杩欓噷 (瑙?+28). 涓嶈 touch.
  +20:      int32  鈽卬ote.timing (chart-ms judge time) 鈥?绌洪棿鏌ヨ early-prune 鐢?            (sub_10086EE70 绗?23 琛? `*(_DWORD *)(*v11 + 20) > v15 - 120`)
  +28:      int32  end_time (active-list 绉婚櫎鏉′欢: chart_time > end_time AND completed)
  +48..55:  int32x2 鈽卲er-frame render distance cache (vtable[3] sub_1007E2788
            姣忓抚閲嶅啓: result = (int32)(chart_time + (float)base_offset))
            绌洪棿鏌ヨ add-back 鐢?`min(this) < 700` 鍒ゆ柇. 涓嶆槸鐘舵€? 鍒竻闆?
  +56..63:  int32x2 base render offset (init 鏃惰, 褰卞搷 vtable[3] 杈撳嚭)
  +164:     int32  (LogicArcNote only) arc/trace flag (=0 鏃?highlight 璺緞)
  +288/+296: ptr*2 (LogicArcNote only) 瀛愭 vector (begin/end)
```

**閲嶈**: 鎴戜滑 v5 hook 鍐呯殑 `*(uint8_t*)+12 = 0; +13 = 0;` 鏄巻鍙插寘琚?no-op,
v6 宸插垹闄? 鐪熸褰卞搷 add-back 鐨勫敮涓€鍙橀噺鏄?`vtable[5](note)` 鐨勮繑鍥炲€?

---

## 鎺㈢储鍘嗙▼

1. **v1**: 12 fishhook 鈫?绮剧畝鑷?2 (gettimeofday + mach_absolute_time)锛屽垹 ~500 琛屾浠ｇ爜
2. **v2**: 绉婚櫎 `_gp_retime_logic_clock`锛堣鍒?mach_absolute_time 鑳介┍鍔ㄨ氨闈級锛岀Щ闄?CCDirector vtable hook
3. **v3**: 瀹炴祴纭 mach_absolute_time 鏃犳硶褰卞搷璋遍潰锛屾仮澶?`_gp_retime_logic_clock`锛涗慨澶?UI 涔辩爜(ASCII鍖?锛涚Щ闄?mach_absolute_time hook (鏃犲疄闄呬綔鐢?
4. **v4**: 灏濊瘯瀹炵幇 seek 鍚庨煶绗﹂噸鐜帮紝娣卞叆閫嗗悜 LogicNote 鐢熷懡鍛ㄦ湡銆乮sCompleted 鏈哄埗銆佺┖闂寸储寮曟煡璇㈤€昏緫銆乺etry 鍦烘櫙閲嶅缓娴佺▼锛涚‘璁ゆ牴鍥犱絾鏈兘鎵惧埌鏈夋晥鐨勮繍琛屾椂閲嶇疆鏂规
5. **v5 (2026-05-11)**: 閲囩敤 vtable swizzle `isCompleted` + rewind grace window 鏂规銆傚彲闈犻€嗗悜璺緞锛歚sub_10086EE70` 璋遍潰绌洪棿鏌ヨ 鈫?璇嗗埆 vtable[5] 璋冪敤 鈫?IDA xref 鏌ユ壘 0x7E27B8 鐨?5 涓?vtable 瀹夸富 鈫?缁熶竴 swizzle銆?6. **v6 (2026-05-11)**: 鍙嶇紪璇?LogicTapNote vtable[3] (`sub_1007E2788`) 鍙戠幇 v5 鍐呯殑
   byte[12]/[13] 娓呴浂鏄?no-op (vtable[3] 姣忓抚閲嶅啓 +48..+55 璺濈缂撳瓨). 寮曞叆
   timing-aware 鍐崇瓥: hook 璇?`LogicNote+20 = note.timing`, 涓?seek 鐩爣姣旇緝;
   杩囧幓闊崇鐩存帴 delegate 鍘熷疄鐜?(鏉滅粷閿欒闂幇). 鍙栨秷 1.5s 鍏ㄥ眬寮哄埗杩斿洖 0,
   浠呭湪 timing 瀛楁璇诲け璐ユ椂 fallback 鍒?v5 妯″紡. 鐏垫劅鏉ヨ嚜 ArcCreate `ResetJudgeTo(int timing)`.

### 琚獙璇佹棤鏁堢殑鏂规


| 鏂规                                            | 缁撴灉               |
| --------------------------------------------- | ---------------- |
| mach_absolute_time fishhook 椹卞姩璋遍潰鍙橀€?           | 鍑犱箮涓嶈璋冪敤锛屾棤鏁?       |
| CCDirector vtable hook + gettimeofday 鍙岄噸 warp | 鍔ㄧ敾鍗℃             |
| 娓呯┖娲昏穬闊崇鍒楄〃 + 閲嶆縺娲婚煶杞?                             | 闊崇涓嶉噸鐜?           |
| 閬嶅巻 LogicChart+32/+40 閲嶇疆 byte[12]/[13]         | +40 杩愯鏃惰涔変笉纭畾锛屾湭鐢熸晥 |
| 娓呴浂 LogicNote+12/+13 byte (v5 鍐呭祵)              | no-op: 鐪熸瀛楁鍦?+48/+52, 涓旀瘡甯ц vtable[3] 瑕嗙洊 |
| `_gp_drift_correct` 闊崇敾绾犲亸                      | 璋遍潰鎸佺画鎶芥悙           |


---

## 瀹夊叏绾︽潫

- 鉁?DobbyHook on `__TEXT` 鈥?iOS 16+ sideload 涓嶅厑璁?RWX
- 鉁?fishhook `clock_gettime_nsec_np` 鍏ㄥ眬 warp 鈥?浼氭柇 FMOD mixer
- 鉁?fishhook on 涓讳簩杩涘埗 GOT 鈥?瀹夊叏 (`__DATA` 娈?
- 鉁?vtable 妲戒綅鏇挎崲 (`__DATA_CONST`) 鈥?mprotect RW 鍙



---

## v6.5.2 (2026-05-12) hotfix

### 鐜拌薄
v6.5.1 涓婄嚎鍚? seek (鍚戝墠/鍚戝悗鎷栨椂闂? 鐩存帴闂€€. 鐢ㄦ埛鏃ュ織鏄剧ず sk reset 姝ラ鎵撳嵃鎴愬姛
(combo 0->0 score 1148369->0 P/F/L 254/2/30 -> 0/0/0), 涔嬪悗涓嬩竴甯у穿.

### 璇婃柇
v6.5.1 鍦?`player_seek_ms` 姝?(e) 鏈熬杩藉姞浜?

```c
*(int32_t *)((char *)logic + 756) = 0;
*(int32_t *)((char *)logic + 760) = 0;
*(int32_t *)((char *)logic + 812) = 0;
```

鎰忓浘鏄竻绌?UI 缂撳瓨璁╀笅涓€甯?`sub_100A7DD20` / `sub_100A7E71C` 寮哄埗鍒锋柊.
浣嗚繖涓変釜鍋忕Щ**瀹為檯浣嶄簬 `*(GP+896)` (ScorePresenter)**, 涓嶅湪 LogicNoteGroup 涓?
閲嶈 `sub_100A7DFC4` 绛惧悕 `(__int64 a1 = ScorePresenter, int a2, __int64 a3 = LogicNoteGroup)`,
`a1+756/760/812` 鎵嶆槸 UI 缂撳瓨; 鎴戞妸 a1 / a3 鍐欐贩浜? 鍦?LogicNoteGroup 鍚庨潰鐨勫爢鍖哄煙
闅忔満瑕嗗啓, 瑙﹀彂涓嬩竴甯х殑 OOB 瑙ｅ紩鐢?-> `EXC_BAD_ACCESS`.

### 淇
鐩存帴鍒犳帀杩欎笁琛屽啓鍏? 涓嶉渶瑕佹浛鎹负 ScorePresenter 鍐欏叆: 涓嬩竴甯?HUD 鍚屾鍣?(`sub_100A7DFC4`) 鑷韩灏变細鍋?`cached != current` 姣旇緝, combo / score 涓嶄竴鑷?浼氳嚜鍔ㄥ埛鏂? 鐪佺暐鍚?UI 鏈€澶氭瘮 sk 鐪熷€兼櫄涓€甯? 瀹屽叏鍙帴鍙?

### 鏁欒
`sub_XXXX(a1, a2, a3)` 鍙嶇紪鏃?a1 / a3 鏄笉鍚屽璞?-- 涓嶈闈?鍙嶆閮戒粠 GP 涓婃寕鐫€"鐨?鐩磋娣风敤. 鍐欏亸绉讳箣鍓嶅厛鎶?`sub_100B3AD70` 璋冪敤鐐圭殑瀹炲弬瀵归綈纭.

鎻愪氦: `bf1a689`.

---

## v6.6 鍒ゅ畾绐楀彛鎺у埗 -- 鏆傜紦 (RE 宸插畬鎴? 瀹炴柦琚鍚嶇害鏉熸尅浣?

瀹屾暣 RE 璺緞涓?5 闃堝€煎畾浣嶈瑙? [arcmodwiki / iOS judgement windows](../arcmodwiki/docs/ios-judgement-windows.md).

### RE 缁撹閫熻

- 鐪熸鐨?per-tap classifier = `sub_100870FD0`.
- 5 闃堝€? `|dt| < 26ms = MAX_PURE`, `< 51 = PURE`, `< 101 = FAR`, `< 121 = LOST`, `>= 121 = no judge`.
- `sub_10086EE70` 閲岄偅瀵?300 / 700 鏄?**active-list entry/exit window**, 涓嶆槸鍒ゅ畾闃堝€?  (鎴戜滑涔嬪墠 v6.5 RE 璇垽浜嗚涔?.
- ScoreKeeper 瀛楁琛ㄥ凡淇: `sk+96 = max_pure`, `+100 = pure`, `+104 = far`,
  `+108 = lost`, `+128 = late_far`, `+132 = early_far`, `+136 = late_pure`,
  `+140 = early_pure`. (early/late 涔嬪墠鍦?summary 閲屽啓鍙嶄簡, 浠ヨ繖娆′负鍑?)

### 涓轰粈涔堟殏缂?
- `sub_100870FD0` 浠呯敱 `sub_100871514` / `sub_100871FE0` 閫氳繃鐩存帴 `BL imm26` 璋冪敤
  (瀛楄妭纭: `0x100871a34 = 97 FF FD 67` = BL). 娌℃湁 vtable 娌℃湁 GOT.
- 鐩存帴 BL 閲嶅畾鍚?= 蹇呴』鏀?`__TEXT` 鎸囦护瀛楄妭. iOS 16+ 鏅€氳嚜绛?(Sideloadly /
  AltStore) 涓?`__TEXT` 鏈?AMFI / CoreTrust page-hash seal, `vm_protect(WRITE)`
  澶辫触鎴栬€呮洿绯?(鍏跺畠绾跨▼ fetch instruction 鏃?`EXC_BAD_ACCESS`).
- **涓嶆槸 PAC 鐨勯棶棰?* -- 鐩存帴 BL 瀹屽叏涓嶈蛋 PAC.
- TrollStore 瑁呯殑 (鏈?`dynamic-codesigning`) 鍙互 Dobby inline hook, 杩欎釜 tweak 浠撶殑
  绾︽潫鐩爣鏄?鑷涔熻鑳借窇", 鎵€浠ユ殏涓嶅疄鐜?

### 鍚庣画閫夐」 (鐣欑粰浠ュ悗)

1. TrollStore 涓撳睘鏋勫缓: build flag `ARC_TROLLSTORE_INLINE_HOOK=1`, 鍚敤鍚庣敤 Dobby
   inline hook `sub_100870FD0`, UI slider 瀹炴椂璋冨叏 5 闃堝€?
2. 鑷鍦烘櫙: 闈欐€?IPA patch 8 澶?`imm12` 瀛楄妭, 鍑哄嚑涓璁?IPA (easier / harder).
3. Android: 鍚屽 RE 鎬濊矾閫傜敤, 鑰屼笖 Android 娌℃湁 `__TEXT` seal -> `mprotect` 鐩存帴
   鑳芥垚, 涓€鏉¤矾绾垮氨澶?(Dobby / xHook 閮借). 璇﹁ wiki 璺ㄥ钩鍙?note.

### 鎺ヤ笅鏉?
鍥炲埌 seek + 鍙橀€熶富绾? 涓嶅啀杩藉垽瀹氱獥鍙?
