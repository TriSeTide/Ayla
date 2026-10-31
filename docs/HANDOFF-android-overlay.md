# Android 悬浮球 + 直播小窗 · 完整交接

> 交接时间：本轮。代码基线 = Ayla `5c6acda`（中间态，含已知缺陷）。
> 你接手全部代码工作。下面每一条都是**已验证的事实或用户明确要求**，不要重新调研。

## 0. 环境

- 仓库：`E:/Elysium-AyerElysia/Elysium/Ayla`，Flutter 在 `flutter/`
- Flutter：`E:/flutter-3.47.4/bin/flutter.bat`，Dart：`.../dart.bat`
- 手机：`adb -s 10AD542KZ100277`（vivo V2243A / Android 16 / 1080x2400 / 480dpi）
- 模拟器：`emulator-5554`（**不可用于验证悬浮球**：第二个 FlutterView 会 raster SIGSEGV）
- 构建：`flutter build apk --debug --android-skip-build-dependency-validation --build-number 999 --dart-define=AYLA_API_BASE=https://s.ayla.trise.top:26211`
  （必须 `--build-number 999` 才能覆盖手机上 build 45 的正式版；用户不允许卸载正式版）
- 测试账号：`test / 12345678`（远程后端）
- 模拟器系统手写输入法会吞输入：`adb shell settings put secure stylus_handwriting_enabled 0`

## 1. 用户报的未解决问题（必须全部修好）

| # | 问题 | 状态 |
|---|---|---|
| 1 | 上下拖动时球在新位置与默认位置之间**来回跳变闪烁** | 未解决，本轮引入 |
| 2 | 点把手**不收起**，拖动时才触发收起动画 | 未解决 |
| 3 | 收起后**窗口矩形没变小**，收起失去意义 | 未解决 |
| 4 | 窗口矩形**不精确**，空白区域过多 | 未解决 |
| 5 | 悬浮球**显示时机被改坏**：原先进 App 自动出现，现在要打开开播界面才刷出，进语音房也不出现 | 未解决 |
| 6 | 手机端**直播小窗完全不显示**；退出直播间能听到声音但看不到小窗；Ayla 切后台后声音也没了 | 未解决 |

## 2. 已确认的根因（不要再猜）

### 2.1 跳变闪烁（问题 1）—— 两处同时在移动窗口
`OverlayFlutterHost.kt` 里有两个 `updateViewLayout`：
- `installDragHandle()` 第 ~355 行：原生按手指位移移动窗口
- `applyBallGroupTop()` 第 ~468 行：Dart 侧上报 `setBallGroupTop` 后移动窗口

**两者同时生效 ⇒ 窗口在两个位置之间来回跳。**
**决策：二选一。保留原生拖动（`installDragHandle`），删掉 `applyBallGroupTop` 的窗口移动逻辑**（Dart 的 `onTopChanged` 仍可用于保存位置，但不得再移动窗口）。

### 2.2 收起不生效（问题 2）—— setOnTouchListener 打断了点击
之前实现里在 `ACTION_MOVE` 超阈值时给 Flutter 发 `ACTION_CANCEL`，导致把手的普通点击被打断（用户实报「点把手不收起，拖拽时才收起」）。
**决策：只旁听、绝不干预 Flutter 事件流。** `ACTION_DOWN/MOVE/UP` 全部返回 `false`，不发 CANCEL。

### 2.3 收起后矩形没变小（问题 3）
`resizeWindowForState(isCollapsed, ballCount)` 已写好（第 388 行），但**收起的实际触发链路断了**——因为问题 2，收起从未真正发生。
修好问题 2 后，此函数会在 `pushPayload` 里按状态重建窗口：
- 双球展开 = 132dp，单球 = 80dp，收起 = 28dp，高度恒 44dp
- 用 `removeView` + `addView` 重建（**不是** `updateViewLayout` 改尺寸 —— 改尺寸会触发合成器重分配 surface buffer，产生斜向位置伪影，见 DE23）

### 2.4 矩形不精确（问题 4）
当前 `WINDOW_WIDTH_DP=176 / WINDOW_HEIGHT_DP=132` 是旧值，与球组真实尺寸（132x44）不符。
**决策：窗口尺寸严格等于当前状态的球组尺寸**（见 2.3 的三个值），不留多余空白。

### 2.5 显示时机（问题 5）—— 关键语义
**web 唯一事实源**：`web/src/layout/SessionActivityIndicator.tsx:81-82`
```tsx
const showVoice = currentUser?.is_in_voice && voice && !onVoiceRoom;
const showLive  = currentUser?.is_live && live && !onLiveConsole;
if (!showVoice && !showLive) return null;
```
- `is_in_voice` / `is_live` = **当前登录用户自己**的状态（我在语音房里 / 我在直播），**不是**「我在看谁的直播」
- `onVoiceRoom` / `onLiveConsole` = 当前页面是否就是那个房间（在房间里就不显示球）

**web 如何更新这两个字段**：`web/src/stores/auth.ts:80` 的 `setMediaActivity({kind, active, roomId})`，由
`web/src/hooks/useVoiceChannel.ts:96/231/254/352` 和 `web/src/components/live/LiveOwnerPanel.tsx:47` 主动调用。

**Flutter 侧现状**：`lib/state/auth_state.dart:157` 已有 `setMediaActivity`，调用方在
`lib/pages/group_live_page.dart:302`、`live_room_page.dart:100`、`live_studio_page.dart:124/289`、
`voice_support.dart`（三处）。
**需要你查**：为什么这条链路没生效。加日志确认 `user.isInVoice / isLive` 在
进入自己开的直播间 / 语音房后是否变 true。注意 `lib/pages/live_support.dart` 里
`tracksOwnerActivity = channel.owner_id === currentUserId` —— 只有**自己开的房间**才写这两个位。

**注意**：`lib/layout/app_shell.dart` 里我加了一条 `print('[AYLA-BALL] ...')` 诊断日志，交接后请删掉。

### 2.6 直播小窗不显示（问题 6）
- Android 端**从未**实现 Flutter 自绘的窗口外直播小窗。历史上：
  1.0.37 及之前：应用内 `AylaLiveMiniPlayer` 浮层
  1.0.40：移除系统 PiP
  1.0.41：新增 `LiveOverlayFlutterHost.kt`（533 行，Flutter 自绘独立小窗）—— **用户评价「各种交互都做烂了」，不要抄**
  我回退 1.0.38 时把这个文件删了
- 当前 `MainActivity` 只有 `showBall`/`updateBall`/`hideBall`，**没有**直播小窗的通道
- `lib/core/platform/detached_live.dart` 的 Android 分支还在调已废弃的 `enterPip`（恒返回 false）
- **需要你实现**：Android 端 Flutter 自绘的窗口外直播小窗，语义见第 3 节

## 3. 直播小窗 · 预期行为（用户已确认）

### 显示时机
| 场景 | 电脑端 | 手机端 |
|---|---|---|
| 在直播间内 | 不显示（画面在主窗口） | 不显示（画面在页面里） |
| 点播放器「小窗」键 | ✅ 出现 | 不渲染此键 |
| 退出直播间（直播仍在进行） | ❌ 不自动出现 | ✅ **自动出现** |
| 切到 App 其他页面 | ❌ | ✅ 保持 |
| 切到别的 App / 回桌面 | 保持 | 保持 |
| 直播结束 | 自动关闭 | 自动关闭 |
| 再次进入直播间 | 关闭，画面回主窗口 | 关闭，画面回页面 |
| 点小窗画面 | 跳回直播间 | 跳回直播间 |
| 点关闭键 | 关闭 | 关闭 |

### 交互
- 外观与 App 内 `AylaLiveMiniPlayer` **100% 一致**（同一份 widget）
- 默认 400x225 逻辑像素，16:9
- 可拖到屏幕任意位置
- 双指捏合缩放，等比 16:9，范围 168x94 ~ 900x506
- 关闭键在右上角外侧，整个圆可点
- 点画面跳回直播间
- **不许改长宽比，不许把按钮移进卡片内部**

## 4. 悬浮球 · 预期行为（用户已确认）

### 显示时机
- 有进行中的**自己的**语音/直播会话 + 脱离应用 ⇒ 显示对应球
- 无会话 ⇒ 球消失
- 会话结束 ⇒ 对应球消失
- 同时有语音+直播 ⇒ 两球并排

### 交互
- 外观与 App 内 `AylaSessionActivityIndicator` **100% 一致**
- **上下拖动**：按住球或把手上下拖，可到屏幕任意高度
- **左右**：固定右侧，不左右拖
- **收起**：点把手 → 球滑出，只留 28dp 宽把手贴右边缘，**窗口也要缩到 28dp**
- **展开**：再点把手 → 球滑回，窗口恢复到 132dp（或单球 80dp）
- **收起态拖动**：仍可按住把手上下拖
- **点击球**：跳对应会话；Ayla 在后台则先拉前台
- **多球**：语音+直播并排，各自可点

### 窗口尺寸（三态，必须精确）
| 状态 | 宽 | 高 |
|---|---|---|
| 双球展开 | 132dp | 44dp |
| 单球展开 | 80dp | 44dp |
| 收起 | 28dp | 44dp |

球组几何（`lib/widgets/shell/session_activity.dart`）：`ballSize=44`、`gap=8`、`toggleWidth=28`。

## 5. 平台约束（已验证，不要重新调研）

1. **overlay 窗口尺寸 = 触摸热区**。窗口内任何位置都吃触摸，`onTouch` 返回 false 也**不会**还给下层（WM input channel 在 DOWN 时已捕获，DE26）。
2. **没有公开 API 做非矩形热区**。`InputWindowHandle.touchableRegion` 和 `OnComputeInternalInsetsListener.TOUCHABLE_INSETS_REGION` 都是 `@hide`（DE25）。
3. **用户已拍板：接受矩形近似**，把窗口做到刚好包住球组。
4. **改窗口尺寸会产生斜向位置伪影**（DE23），必须用 `removeView`+`addView` 重建，不能用 `updateViewLayout` 改宽高。
5. **模拟器上第二个 FlutterView 必崩**（`libEGL: no current context` + raster SIGSEGV）。真机（vivo）不崩。**只在真机验证**。
6. 参考实现：`flutter_overlay_window` 插件（源码可从 `https://pub.dev/api/archives/flutter_overlay_window-1.0.2.tar.gz` 下载）。它的拖动逻辑（DOWN 返回 false、超 slop 后接管、用 `getRawX/getRawY` 算位移）是正确的，**但它没有解决「球外穿透」**。

## 6. 本轮已完成的改动（保留）

- **彻底移除系统 PiP**：`AndroidManifest.xml` 删 `supportsPictureInPicture`；`MainActivity.kt` 删 13 个 PiP 函数；通道 `isSupported/isInPip/enterPip` 改成恒 false 桩。验证通过：`mWindowingMode=fullscreen`（原 pinned）、主窗口 1080x2400（原 598x336）。
- `OverlayFlutterHost.kt`：单窗口紧贴球组 + `resizeWindowForState` 三态重建 + `bringAppToFront`。
- `media_kit_impl.dart`：`Video` 加 `ObjectKey(vc)`（修主窗口直播黑屏：重建后复用旧 Element 渲染已释放纹理）。
- Windows 端直播小窗：铺满工作区 + 滚轮/边缘缩放 + `SetWindowRgn` 穿透（已发布 1.0.44）。

## 7. 建议的实施顺序

1. 先删 `applyBallGroupTop` 的窗口移动逻辑（修跳变），只保留 `installDragHandle`
2. 修 `installDragHandle`：所有分支返回 false，不发 CANCEL（修收起点击）
3. 窗口尺寸严格按三态（修矩形不精确 + 收起不缩小）
4. 查 `isInVoice/isLive` 链路（修显示时机），删掉我加的诊断 print
5. 实现 Android 窗口外直播小窗（复用 `AylaLiveMiniPlayer` + 第二引擎 `aylaLiveWindowMain`）
6. 每步都在真机验证，不要用模拟器

## 8. 验收标准

- 悬浮球：进 App 自动出现（有自己会话时）、上下拖动跟手不跳、点把手能收起且窗口缩到 28dp、收起态能拖、点球能唤起 Ayla
- 直播小窗：退出直播间自动出现、能拖能缩放、点画面回房间、点关闭键关闭
- 全程不吞触摸（球/窗之外能正常点桌面）

---

## 9. 补充发现（写文档后新增，重要）

### 9.1 `app_shell.dart` 本轮**没有**改显示逻辑
`git diff 5f1a5b4..5c6acda -- flutter/lib/layout/app_shell.dart` 只有一条我加的诊断 `print`。
⇒ **问题 5（显示时机）不是本轮引入的**，是历史行为。排查方向：`isInVoice/isLive` 的实际赋值链路，
而不是 app_shell 的渲染逻辑。

### 9.2 问题 6 的直接根因：`_retireDetachedWindow`
`lib/pages/live_support.dart` 的 `start()` 里本轮新增了：
```dart
await _retireDetachedWindow();   // 进入直播间时关闭窗口外小窗
```
这会导致：**退出直播间 → 小窗刚出现 → 再次进入直播间 → 小窗被强制关掉**。

同时 `_attachPlayer()` 里新增了 `_playerSuspendedForDetached = false;`。

**这两处是为了修「Windows 端直播黑屏」加的**（当时确实修好了 Windows 黑屏）。
但它们是 Windows 专用语义，Android 上不该照搬：
- Windows：小窗是第二引擎 + 第二个 HLS 播放器，会抢流 ⇒ 进直播间必须让小窗让位
- Android：当前**根本没有**窗口外小窗实现 ⇒ 这段代码只会误伤

**决策**：把 `_retireDetachedWindow()` 的调用限定为 `defaultTargetPlatform == TargetPlatform.windows`。
`_playerSuspendedForDetached` 的清零保留（它是幂等的，Android 上本来就是 false）。

### 9.3 「切后台后声音没了」的排查方向
Android 上直播音频依赖主引擎的 media_kit player。切后台后：
- 若 `clearDetachedPresentation` 走了 `_resumeMainPlayerAfterDetached()` 而 player 已 destroy ⇒ 无音频
- 检查 `MainActivity` 是否有前台服务 / `onPause` 里是否停了音频焦点
- 参考 web：web 切后台不会停播放器
- Android 需要 `FOREGROUND_SERVICE_MEDIA_PLAYBACK` 前台服务保活，否则系统会冻结进程
