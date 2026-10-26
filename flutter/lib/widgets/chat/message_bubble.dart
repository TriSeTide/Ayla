/// 单条消息气泡（`components/chat/MessageBubble.tsx` 的 Flutter 等价）。
///
/// ## 事实源
///
/// | 本文件 | web |
/// |---|---|
/// | [AylaMessageBubble] | `MessageBubble.tsx:324–376`（单行布局 + 内容分支） |
/// | [aylaCanRecall] | tsx 34–44 `canRecall`（自己 + 未撤回 + **120s** 内） |
/// | [aylaMessageTimeAgo] | tsx 24–32 `timeAgo` |
/// | 行/主体布局 | app.css 1041–1102（`.msg-row` / `.msg-body` / `.msg-bubble-wrap`） |
/// | 气泡三态 | app.css 1104–1136（`.bubble-self` / `-elysia` / `-other`）+ 1514–1518（`.bubble-media`） |
/// | 撤回态 | app.css 1225–1228（opacity .6 + italic；**同时 class 退化为 `bubble-other`**，tsx 210–216） |
/// | 引用条 | app.css 1261–1285（`.quote-strip`） |
/// | 操作栏 | app.css 1287–1322（`.msg-actions` 三种显示条件）+ 1324–1333 / 1362–1365 |
/// | 操作键 | auroraqua.css 55–94（transition 200ms / hover 1.02 / active .98）+ 124–166（材质 + 扫光） |
/// | 发送态 | app.css 1335–1360 + tsx 276–322 |
/// | 到达动画 | base.css 426–434 `frost-rise`（+8px 淡入 180ms）+ app.css 1089–1093（reduced-motion 关） |
///
/// ## 与 web 的差异（有意，登记）
/// 1. **工具栏触发 = 两档**（**2026-10-13 用户定稿；Flutter 有意偏离 web**）：
///    - **宽屏且有 hover 能力** ⇒ 悬停显示、移开消失（纯悬停，不接点击）；
///    - **否则**（窄屏 **或** 无 hover 能力的宽屏触屏）⇒ 点气泡行切换。
///
///    ⚠️ **本条是单端偏离，不是「对齐 web」。** web 侧**保持原样**（用户 2026-10-13
///    明确裁决「回退 web，我说对的就是对的」）：web 的判据仍为**纯 hover 能力查询**
///    —— `MessageBubble.tsx:135` `isTouch = useMediaQuery(HOVER_NONE_QUERY)`、
///    `app.css:1307–1322` 只有 `@media (hover: hover)` / `@media (hover: none)`，
///    **无任何宽度条件** ⇒ web 窄屏桌面窗口仍走悬停档。
///    Flutter 端按用户要求对窄屏走点击档：Windows 端窄窗口是用户的手机形态代理，
///    而该环境**无法用真实触屏模拟**（用户原话），故判据落到宽度。
///    发生冲突时**以用户裁决为准**，不回改 web；但不得伪称两端一致。
///
///    Flutter 侧对应 `_tapOnly`（见 State 内注释）：
///    窄屏 = `AylaBreakpoints.isNarrow`（`width <= 768`，与 web `NARROW_QUERY`
///    的 `(max-width: 768px)` 数值同界，仅**本端**用于工具栏判据）；
///    「无 hover 能力」无媒体查询可查 ⇒ 两级近似：
///    ⓐ 平台名（Android / iOS / fuchsia = 触屏，与 `live_player` 的平台分派同一先例）；
///    ⓑ **当次指针设备**（`PointerDeviceKind.touch/stylus/invertedStylus` ⇒ 判为无 hover
///       能力）—— 补住 ⓐ 在**触屏 Windows / 平板模式**上的失准（平台名是 `windows`，
///       但 web 会报 `hover: none`）。判定发生在 `onTap` 内（事件级），与 web 的
///       `handleRowClick` 首行 `if (!isTouch) return;` 同构；
///    另留 [AylaMessageBubble.touchMode] 供页面层**强制覆盖**（优先级最高）；
/// 2. **发送态定位**：web 用 `position:absolute; right:calc(100% + 8px)`；Flutter 用
///    `FractionalTranslation(-1, 0)` + 8px 位移表达同一条 CSS（相对**自身**宽度的 100%），
///    因此不占布局位、不会压缩气泡；
/// 3. **收藏键状态**：web `MessageBubble.tsx:246` **恒渲染**
///    `<FavoriteButton targetType="message" targetId={message.id} compact />`
///    —— 状态由收藏键自己持有（`FavoriteButton.tsx:22` 调 `useFavoriteStatuses`，
///    `hooks/useFavoriteStatuses.ts:12–16` 挂载即 retain+load、卸载 release），
///    **调用方不传任何收藏参数**。2026-10-09 前 Flutter 侧走「页面注入档」，
///    而 `message_list.dart` 从未传 `favoriteState` ⇒ 每个气泡都停在 `unknown`
///    （禁用 +「正在加载收藏状态」，用户实报）⇒ 本次改为**默认自给自足**：
///    不传 [AylaMessageBubble.favoriteState] / [AylaMessageBubble.onToggleFavorite]
///    时收藏键自己按 `message:<msg.id>` 起状态；画布样张显式传 `favoriteState`
///    仍走注入档（零改动）。
///
/// ## 与本轮实测的偏差（2026-10-22 对账后登记，勿当成未完成项）
///
/// 对账方法：`tool/web_bubble_measure.html` 用 `file://` 加载 web 四份 CSS +
/// 与 `MessageBubble.tsx` 同构的 DOM，字体换成与 Flutter 侧**同一批 TTF**，
/// Playwright 读 `getBoundingClientRect()`；Flutter 侧量同构 widget 树。
/// 期望值存 `tool/web_bubble_expected.json`。四档实测结论：
///
/// | 项 | 结果 |
/// |---|---|
/// | 短消息气泡宽（peer/elysia，带边框） | **Δ = −0.02px**（44.91 vs 44.89） |
/// | 无边框档（self） | **Δ = −0.01px**（48.89 vs 48.88） |
/// | 长消息气泡宽（900/1440 档） | **Δ = 0.00px**（633 / 714） |
/// | 图片帧比例 | 4:3 与 3:4 均精确保持（见 `bubble_layout_parity_test.dart`）|
///
///
/// ## 3. `.msg-actions` 参与主轴收缩 —— **2026-10-22 已实现**（本段取代旧的
/// 「有意保留不收缩」登记，勿再当成未完成项）
///
/// 上一轮这里登记为唯一残留差异：web 的 `.msg-actions` 及其按钮都带
/// `flex-shrink: 1`（app.css:1290–1298 / 1324–1333 **没有任何 flex-shrink:0
/// 或 white-space:nowrap**），窄屏挤不下时会压窄按钮并让标签折行，气泡因此
/// 能占到 84%；而 Flutter 的 `Row` 子项**不收缩** ⇒ 工具栏恒占自然宽，
/// 375 档气泡比 web 少约 24px。
///
/// 两条老修法都踩过坑（`Flexible` 是「分配空间」不是「溢出才收缩」，900 档
/// 气泡 633→395 腰斩）⇒ 本轮改为 **[AylaCssFlexRow]（`widgets/base/css_flex_row.dart`）**：
/// 按 CSS 规范 §9.7 的收缩分支逐条实现，只在真正溢出时才压。
///
/// 实现口径（各件 CSS 参数）：
/// - 头像 `flex-shrink: 0`（app.css:1053）；
/// - 气泡 `max-width:75%/84%` + `min-width:0`（app.css:1073–1083 / 3217–3219）；
/// - 工具栏默认 shrink 1，min-content = 各键 min-content 之和 +
///   `.msg-actions` 的 gap（键间 4px）：`.favorite-toggle.is-compact` 32
///   （app.css:3334–3338）+ `.msg-action-btn` 33.6（图标 16 + padding 16 +
///   border 1.6，浏览器实测）。
///
/// 实测对账（与浏览器同值，见 `test/css_flex_row_test.dart`）：
///
/// | 档 | peer-long 气泡 | 工具栏 | self-long 气泡 | 工具栏 |
/// |---|---|---|---|---|
/// | 375 | 220.6 | 69.6 | **182.8**（web 183） | **107.2**（web 107.2） |
/// | 480 | 325.4 | 69.6 | 287.8 | 107.2 |
/// | 900 | 633.0 | 93.6 | 633.0 | 155.2 |
/// | 1440 | 714.0 | 93.6 | 714.0 | 155.2 |
///
/// 唯一残留：按钮标签是中文，测试引擎无 CJK 字体 ⇒ **测试里**的自然宽是 132
/// 而非 web 的 155.2；这是字体度量差，不影响布局口径（真机有系统 CJK 字体）。
///
/// ⚠️ 已知局限（登记）：[AylaCssFlexRow] 不实现 intrinsic 尺寸（子树含
/// `LayoutBuilder`，Flutter 不支持对其求 intrinsic）⇒ 不得把它塞进
/// `IntrinsicWidth/Height`。
///
/// ## 4. 媒体族气泡的 fit-content —— **2026-10-22 二轮**（本段记录一次真实回归）
///
/// 上面 [AylaCssFlexRow] 用**无界主轴测量**实现 CSS 的 `flex-basis:auto`
/// （= max-content）。但媒体子树里有 `Expanded`（CSS `flex:1`），而
/// `Expanded` 在无界主轴下**无定义**：
/// - 语音卡主行 `.voice-card-main` 的 `.voice-wave{flex:1}`；
/// - 语音卡进度行 `.voice-seek{flex:1}`；
/// - 文件卡 `.file-info{flex:1}`。
///
/// 于是「自然宽」被量成 `.msg-body` 的 75%/84% 上限 ⇒ **语音/文件气泡撑满整行**
/// （用户真机截图实锤：1440 档语音气泡占满整行约 84%）。
///
/// **CSS 的机制是两趟**：intrinsic 趟里 `flex:1` 项贡献**自身 max-content**
/// （波形 = 36 × 480/120 = 144），布局趟才被祖先 `max-width` 夹住。
/// Flutter 只有一趟（`Align(widthFactor:1)` 拿到的是**已被夹过的**约束）。
///
/// **修法**：`widgets/base/fit_content.dart` 三个原语把两趟补上 ——
/// [AylaFitContent]（= CSS `width: fit-content`，先无界测 max-content 再夹）、
/// [AylaInlineSize]（`flex:1` 有界占满 / 无界取声明值）、
/// [AylaInlineNaturalSize]（同上，无界取子级自然宽）。没用 `IntrinsicWidth`
/// 是因为媒体子树含 `LayoutBuilder`（Flutter 不支持求 intrinsic）。
///
/// 实测对账（`tool/web_media_measure.html` + Playwright，四档 + max-content 档，
/// 期望值存 `tool/web_media_expected.json`）：
///
/// | 气泡 | web @1440 | Flutter 修复前 | Flutter 修复后 |
/// |---|---|---|---|
/// | 语音（有波形） | 266.19 | **714**（75% 上限） | 264.19 |
/// | 语音（无波形） | 250.00 | **714** | 248.00 |
/// | 图片 640×480 | 330 | 328 | 328 |
/// | 图片 480×640 | 250 | 248 | 248 |
/// | 图片 100×100 | 110 | 108 | 108 |
/// | 表情 | 106 | 104 | 104 |
/// | 视频 1280×720 | 330 | 328 | 328 |
/// | 文件 | 276.73 | **328** | 248–277（CJK 度量差见下） |
/// | 分享 | 227.69 | 294 | 294（见「残留差异」） |
/// | 混排 | 378 | 220.1 | 220.1（见「残留差异」） |
/// | 引用条 | 714 | 714 | 714（web 同样撑到上限，无差异） |
///
/// 回归锁：`test/bubble_media_width_test.dart`（16 例，含「1440 档语音气泡
/// 不得等于 84%/75% 上限」这条直接判据）+ `test/fit_content_test.dart`（9 例，原语语义）。
///
/// ### 残留差异（如实登记，未修）
/// 1. **文件卡**：web 276.73 vs Flutter 248 —— 文件名是中文，测试引擎无 CJK
///    字体 ⇒ 自然宽偏窄；真机有系统 CJK 字体，差值会收敛（与
///    `css_flex_row_test.dart` 文件头登记的工具栏 132 vs 155.2 同源）。
/// 2. **分享卡**：web 227.69 vs Flutter 294 —— web 的
///    `.share-bubble-card{width:min(264px,100%)}` 在 `.bubble` 的 fit-content
///    计算里构成**百分比循环依赖**，Chrome 按「先按 100% 求解、再收缩」得 227.69；
///    Flutter 侧按字面 `min(264, 可用)` 得 294（264 + padding/border）。两者都是
///    「窄卡」，不撑满整行，**本轮不动**（要精确复刻需要模拟 Chrome 的循环求解，
///    风险大于收益；已登记待用户决定）。
/// 3. **混排**：web 378 vs Flutter 220.1 —— web 的 `.mixed-flow{flex-wrap:wrap}`
///    在 max-content 档把 text 段与 180 方块**排在同一行**（368 + gap），Flutter
///    的 `Wrap` 在测量档得到 220.1（排成两行）。同样是「不撑满整行」的窄卡，
///    差异属于 `Wrap` 与 CSS `flex-wrap` 的 max-content 求值差，本轮不动并登记。
///
/// ## 公开面
/// `AylaMessageBubble` · 样张 `aylaMessageBubbleSamples()`

library;

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show KeyDownEvent, LogicalKeyboardKey;

import '../../core/media/audio_playback.dart';
import '../../core/models/chat_message.dart';
import '../../core/models/media_kind.dart';
import '../../core/models/user_public.dart' show AylaUserPublic;
import '../../core/models/post.dart' show AylaMediaDescriptor;
import '../../core/models/share_payload.dart';
import '../../player/vod_player.dart';
import '../../theme/app_icons.dart';
import '../../theme/buttons.dart';
import '../../theme/glass.dart';
import '../../theme/sample_media.dart';
import '../../theme/tokens.dart';
import '../base/avatar_halo.dart';
import '../base/css_flex_row.dart';
import '../base/directory_controls.dart' show AylaFavoriteButton, AylaFavoriteState;
import '../base/loading.dart';
import '../../state/favorite_status.dart' show AylaFavoriteStatusController;
import 'media_content.dart';
import 'share_bubble.dart';
import '../base/tooltip.dart';

/// `.msg-action-btn` 的 **min-content 宽**（CSS px，浏览器实测 33.6）。
///
/// 来源：`app.css:1324–1333` 的 `padding: 4px 8px`（8×2 = 16）+ `border: 1px`（×2
/// = 1.6，浏览器 DPR 1.25 下是 0.8px 边框，但布局按 CSS px 计 1px → 本件按 1×2 = 2
/// 与浏览器实测 33.6 对齐）+ 图标行盒 16（`auroraqua.css` / `MessageBubble.tsx` 里
/// 图标 12px + `margin-right: 4px`）。
/// 即 16 + 16 + 1.6 = 33.6 —— 与 Chrome `getBoundingClientRect` 实测的 min-content
/// 完全一致（`tool/web_bubble_measure.html` + Playwright 实测）。
const double kAylaMsgActionBtnMinContent = 33.6;

/// `.favorite-toggle.is-compact` 的 `min-width`（`app.css:3334–3338`）。
const double kAylaFavoriteCompactMinWidth = 32;

/// 撤回时限（秒）—— `hooks/useChat.ts:26` `RECALL_SECONDS = 120`，
/// 与后端 `MESSAGE_RECALL_SECONDS` 对齐。
const int kAylaMessageRecallSeconds = 120;

/// 双击头像判定窗口（ms）—— `MessageBubble.tsx:49` `DOUBLE_CLICK_MS`。
const int kAylaMessageDoubleClickMs = 250;

/// 撤回窗口判断（tsx 34–44）：仅自己、未撤回、`created_at` 在 [kAylaMessageRecallSeconds] 内。
bool aylaCanRecall(
  AylaChatMessage message,
  String? currentUserId, {
  DateTime? now,
}) {
  if (currentUserId == null || message.senderId != currentUserId) return false;
  if (message.recalled) return false;
  final DateTime? created = DateTime.tryParse(message.createdAt);
  if (created == null) return false;
  final DateTime reference = now ?? DateTime.now();
  return reference.difference(created).inSeconds <= kAylaMessageRecallSeconds;
}

/// 相对时间文案（tsx 24–32）：<60s「刚刚」/ <3600s「N 分钟前」/ 否则 `HH:mm`（本地时区）。
String aylaMessageTimeAgo(String iso, {DateTime? now}) {
  final DateTime? parsed = DateTime.tryParse(iso);
  if (parsed == null) return '';
  final DateTime local = parsed.toLocal();
  final DateTime reference = (now ?? DateTime.now()).toLocal();
  final int diff = reference.difference(local).inSeconds;
  if (diff < 60) return '刚刚';
  if (diff < 3600) return '${diff ~/ 60} 分钟前';
  String pad(int n) => n.toString().padLeft(2, '0');
  return '${pad(local.hour)}:${pad(local.minute)}';
}

/// 单条消息气泡。
class AylaMessageBubble extends StatefulWidget {
  const AylaMessageBubble({
    super.key,
    required this.msg,
    required this.isSelf,
    this.isElysia = false,
    this.justArrived = false,
    this.senderName,
    this.senderAvatarUrl,
    this.senderAvatarLabel,
    this.senderOnline = false,
    this.senderUser,
    this.senderUserId,
    this.onSenderClick,
    this.onMentionSender,
    this.onPokeSender,
    this.actionsOpen = false,
    this.onToggleActions,
    this.quoteText,
    this.onQuote,
    this.onQuoteJump,
    this.jumpedRecalled = false,
    this.onRecall,
    this.onRetry,
    this.onRemove,
    this.onCancel,
    this.shareGroupId,
    this.currentUserId,
    this.touchMode,
    this.favoriteState,
    this.favoriteBusy = false,
    this.favoriteError,
    this.onToggleFavorite,
    this.onRetryFavoriteStatus,
    this.favoriteTargetType,
    this.favoriteTargetId,
    this.favoriteController,
    this.descriptorFetcher,
    this.onDescriptorFetched,
    this.audioEngineFactory,
    this.vodPlayerFactory,
    this.onMentionTap,
    this.onDownloaded,
    this.onSaveError,
    this.onNavigate,
    this.isGroupJoined,
    this.onRequestJoin,
    this.onResolveShareTarget,
  });

  final AylaChatMessage msg;

  /// 是否自己发送（行方向与气泡样式的判定；爱莉消息由父级判 [isElysia]）。
  final bool isSelf;

  /// 爱莉消息（**爱莉专属气泡，不可复用于其他用户**，design.md §4）。
  final bool isElysia;

  /// 新到达消息（乐观发送 / WS 实时）挂到达动画；初始历史加载为 false。
  final bool justArrived;

  /// 群聊显示发送者名。
  final String? senderName;

  final String? senderAvatarUrl;
  final String? senderAvatarLabel;

  /// 发送者实时在线（光环）。
  final bool senderOnline;

  /// 发送者完整用户对象 ⇒ 头像自订阅 presence（web MessageBubble.tsx:130–132,235）。
  final AylaUserPublic? senderUser;

  /// 发送者 id（最轻量入口；群聊里发送者常无完整用户对象）。
  final String? senderUserId;

  /// 头像单击（延迟双击窗口后触发）→ 个人主页。
  final VoidCallback? onSenderClick;

  /// 长按头像 500ms → 在输入框内插入 @该用户（仅群聊非自己、非撤回、非 system）。
  final void Function(String userId, String name)? onMentionSender;

  /// 双击头像 → 戳一戳。
  final void Function(String senderUserId)? onPokeSender;

  /// 触屏下该行工具栏是否展开（由父级单选管理）。
  final bool actionsOpen;

  /// 触屏下点击行切换工具栏展开。
  final VoidCallback? onToggleActions;

  /// 被引用消息的预览文本（父级解析）。
  final String? quoteText;

  final void Function(AylaChatMessage msg)? onQuote;

  /// 点击引用块 → 定位被引用的原消息。
  final void Function(AylaChatMessage msg)? onQuoteJump;

  /// 定位到已撤回原消息时的明确文案。
  final bool jumpedRecalled;

  final void Function(AylaChatMessage msg)? onRecall;

  /// 乐观发送失败：重试（重新上传 + 发送，幂等键复用）。
  final void Function(AylaChatMessage msg)? onRetry;

  /// 乐观消息删除（本地丢弃）。
  final void Function(AylaChatMessage msg)? onRemove;

  /// 乐观发送中：取消上传（abort + 删除气泡）。
  final void Function(AylaChatMessage msg)? onCancel;

  /// 当前会话为群聊时的群 id（分享卡片分流跳转用）。
  final String? shareGroupId;

  /// 当前登录用户 id（撤回窗口与混排「@我」判定）。
  final String? currentUserId;

  /// **强制覆盖**工具栏触发档（优先级最高；null = 按形态自动判定）。
  ///
  /// - `true` ⇒ 点击档：悬停不展开、点气泡行切换、行给手型；
  /// - `false` ⇒ 桌面档：悬停展开、点行不切换（**即使窄屏**也如此）；
  /// - `null` ⇒ 自动：窄屏 ∨ 触屏平台 ⇒ 点击档（见 `_tapMode`）。
  ///
  /// 判据本体在 State 的 `_tapMode`/`_tapOnly`/`_narrow`。⚠️ 自动档比 web 多一条
  /// **窄屏**判据（web 只查 hover 能力）—— 见文件头「与 web 的差异」第 1 条。
  final bool? touchMode;

  /// 收藏状态（**注入档**：非 null ⇒ 由调用方驱动，与 2026-10-09 前逐像素一致）。
  ///
  /// null 且 [onToggleFavorite] 也为 null ⇒ **自给自足档**（web 语义，
  /// `MessageBubble.tsx:246`）：收藏键按 `message:<msg.id>` 自己 retain + load + toggle。
  final AylaFavoriteState? favoriteState;

  final bool favoriteBusy;
  final String? favoriteError;
  final void Function(bool favorited)? onToggleFavorite;
  final VoidCallback? onRetryFavoriteStatus;

  /// 收藏目标类型/id（web `MessageBubble.tsx:246` 恒为 `"message"` + `message.id`）。
  ///
  /// 留出覆写口：消息卡在别的上下文（如收藏页的消息卡）可能有自己的目标身份。
  final String? favoriteTargetType;
  final String? favoriteTargetId;

  /// 自给自足档的控制器（不传 ⇒ 用库内共享单例）。
  final AylaFavoriteStatusController? favoriteController;

  // ---- 媒体内容注入点（透传给 [AylaMediaContent]，语义见该组件文档）----
  final AylaMediaDescriptorFetcher? descriptorFetcher;
  final void Function(AylaMediaDescriptor media)? onDescriptorFetched;
  final AylaAudioEngine Function()? audioEngineFactory;
  final VodPlayerFactory? vodPlayerFactory;
  final void Function(String userId)? onMentionTap;
  final void Function(String savedPath)? onDownloaded;
  final void Function(String detail)? onSaveError;

  // ---- 分享卡注入点（透传给 [AylaShareBubble]）----
  final void Function(String route)? onNavigate;
  final bool Function(String groupId)? isGroupJoined;
  final void Function(AylaSharePayload payload)? onRequestJoin;
  final Future<String?> Function(AylaSharePayload? payload, String? groupId)?
      onResolveShareTarget;

  @override
  State<AylaMessageBubble> createState() => _AylaMessageBubbleState();
}

class _AylaMessageBubbleState extends State<AylaMessageBubble>
    with SingleTickerProviderStateMixin {
  late final AnimationController _arrive = AnimationController(
    vsync: this,
    duration: AylaDurations.fast, // frost-rise 180ms（base.css 426–434）
  );

  bool _hovered = false;
  bool _focused = false;

  /// 长按已触发（抑制紧随的 click，避免又跳个人主页 —— tsx 147–149）。
  bool _longPressTriggered = false;
  Timer? _singleClickTimer;
  Timer? _longPressTimer;

  /// 点击档：**点气泡行切工具栏**（而非悬停展开）。判据 = 窄屏 **或** 触屏平台。
  ///
  /// ⚠️ **本件有意偏离 web**（用户 2026-10-13 裁决「回退 web，我说对的就是对的」）：
  /// - web 判据 = **纯 hover 能力查询**（`MessageBubble.tsx:135` `HOVER_NONE_QUERY`、
  ///   `app.css:1307–1322` 只有 `(hover: hover)` / `(hover: none)`，**无宽度条件**）
  ///   ⇒ web 窄屏桌面窗口**仍走悬停档**；
  /// - 本件在 [_platformIsTouch] 之外**另外**采信 [_narrow]（`width <= 768`）⇒
  ///   窄屏一律走点击档。原因：Windows 端窄窗口是用户的手机形态代理，而该环境
  ///   **无法用真实触屏模拟**（用户原话），窄屏悬停在其体验里等于「不显示」。
  /// 该偏离已登记于文件头「与 web 的差异」第 1 条；**冲突时以用户裁决为准**。
  ///
  /// ✅ **两档互补是结构性保证**：本件只有一个 `_tapMode` 布尔，悬停档取
  /// `_hovered && !_tapMode` ⇒ 不存在「两条独立媒体查询拼接」可能留下的死区
  /// （参考教训：CSS 里 `max-width:768px` 与 `min-width:769px` 并非互补 ——
  /// 小数视口宽 768.5 上两条同时为假。本件用布尔取反天然免疫）。
  bool get _tapOnly => _narrow || _platformIsTouch(context);

  /// 当前形态是否窄屏（≤768 **含等号**）。
  bool get _narrow => AylaBreakpoints.isNarrow(MediaQuery.sizeOf(context).width);

  /// 最近一次指针按下的**设备类型**（`PointerDownEvent.kind`）。
  ///
  /// 为什么要它：web 的判定**每次点击重新求值**（`MessageBubble.tsx:139–144` 的
  /// `handleRowClick` 首行 `if (!isTouch) return;`），
  /// 同一台设备上「手指点」与「鼠标点」走的本就是不同分支。
  ///
  /// Flutter 无 `hover` 媒体查询 ⇒ 平台名 + 本字段两级近似（见 [_tapOnly]）：
  /// 平台名在**触屏 Windows / 平板模式**上失准（平台名是 windows ⇒ 判为「有 hover」），
  /// 而 web 在那种设备上报 `hover: none` ⇒ 应当走点击路径。
  /// 桌面平台收到触摸/触控笔指针时也判为无 hover 输入。
  PointerDeviceKind? _lastPointerKind;

  /// **本行**是否走点击档（点行切工具栏、悬停不展开、行给手型）。
  ///
  /// 显式 [AylaMessageBubble.touchMode] **最高优先** —— `false` = 调用方明确要求
  /// 桌面档（窄屏也悬停展开、点行不切换）；未给 ⇒ 按 [_tapOnly]（窄屏 ∨ 触屏平台）。
  bool get _tapMode => widget.touchMode ?? _tapOnly;

  /// 本次点击是否走「点行切换工具栏」（对应 web 的 `if (!isTouch) return;`）。
  ///
  /// 优先级：显式 [AylaMessageBubble.touchMode] > **点击档**（窄屏 ∨ 触屏平台，
  /// 见 [_tapOnly]）> **当次指针设备能力**。
  /// 显式档位优先是为了保住既有契约（`touchMode: false` 的调用方明确要求
  /// 关闭点行路径，见 `test/message_bubble_test.dart` 的对应用例）。
  bool get _tapTogglesToolbar {
    if (_tapMode) return true;
    // 显式桌面档（`touchMode: false`）不接指针设备维度：调用方已明确要求关闭点行路径。
    if (widget.touchMode != null) return false;
    return switch (_lastPointerKind) {
      // `PointerDeviceKind.touch` = 手指；stylus / invertedStylus = 触控笔
      //（都没有 hover 能力，与 web `@media (hover: none)` 同义）。
      PointerDeviceKind.touch ||
      PointerDeviceKind.stylus ||
      PointerDeviceKind.invertedStylus =>
        true,
      _ => false,
    };
  }

  static bool _platformIsTouch(BuildContext context) {
    // web `@media (hover: none)`（`hooks/useMediaQuery.ts:16` HOVER_NONE_QUERY）：
    // 判「无 hover 能力的设备」。Flutter 无该媒体查询 ⇒ 按平台判定
    // （Touch 平台 = 触摸为主；桌面平台的鼠标/触控板都有 hover），
    // 再由 [_tapTogglesToolbar] 用**当次指针设备**兜住触屏桌面这一档。
    return switch (Theme.of(context).platform) {
      TargetPlatform.android || TargetPlatform.iOS || TargetPlatform.fuchsia => true,
      _ => false,
    };
  }

  /// 到达动画是否已启动（`didChangeDependencies` 只处理一次；**不能在 initState 读
  /// MediaQuery**，见 13 号 §五）。
  bool _arriveStarted = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_arriveStarted) return;
    _arriveStarted = true;
    final bool reduceMotion =
        MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    // web `@media (prefers-reduced-motion: reduce) { .msg-row.msg-arrive { animation: none } }`
    if (widget.justArrived && !reduceMotion) {
      _arrive.forward();
    } else {
      _arrive.value = 1;
    }
  }

  @override
  void dispose() {
    _singleClickTimer?.cancel();
    _longPressTimer?.cancel();
    _arrive.dispose();
    super.dispose();
  }

  // ---- 头像手势（tsx 146–208）----

  bool get _canMention =>
      !widget.isSelf &&
      !widget.msg.recalled &&
      !widget.msg.isSystem &&
      widget.senderName != null &&
      widget.onMentionSender != null;

  bool get _canPoke =>
      !widget.msg.recalled && !widget.msg.isSystem && widget.onPokeSender != null;

  void _clearLongPress() {
    _longPressTimer?.cancel();
    _longPressTimer = null;
  }

  void _onSenderTap() {
    if (_longPressTriggered) {
      _longPressTriggered = false;
      return;
    }
    final Timer? pending = _singleClickTimer;
    if (_canPoke && pending != null) {
      // 双击窗口内第二次：取消挂起的单击，触发戳一戳
      pending.cancel();
      _singleClickTimer = null;
      widget.onPokeSender?.call(widget.msg.senderId);
      return;
    }
    _singleClickTimer = Timer(
      const Duration(milliseconds: kAylaMessageDoubleClickMs),
      () {
        _singleClickTimer = null;
        widget.onSenderClick?.call();
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final AylaChatMessage msg = widget.msg;
    final bool recalled = msg.recalled;
    // ⚠️ **2026-10-26 修复（用户实报「群聊页面头像光环显示错误状态」的真正根因）**：
    // 此前判据是 `senderAvatarLabel != null || senderAvatarUrl != null`，
    // 而这两个值都来自 `message_list.dart` 的 `_memberAvatars`
    // （= `conversation.members`，一份 **REST 快照**）。两种常见情形下它们都是 null：
    //   ① 成员表**尚未加载**（冷启动直链进群 / 手机慢网）；
    //   ② 发送者**不在成员表**里（历史消息的已退群用户）。
    // ⇒ **整个头像不渲染**（不是颜色错，是根本没头像）——用户看到的就是「光环状态错误」。
    //
    // 现在：**只要知道发送者是谁（senderUserId / senderUser）就画头像**，
    // 文字回退链 `senderAvatarLabel → senderName → '发送者'`（与 halo 内部一致），
    // 图片 URL 由 resourceUrl + presence 的 `user.updated` 覆盖层共同决定。
    final String? senderId = widget.senderUserId ?? widget.senderUser?.id;
    final bool showSenderHalo = !recalled &&
        !msg.isSystem &&
        (senderId != null ||
            widget.senderAvatarLabel != null ||
            widget.senderAvatarUrl != null);

    final Widget? halo = showSenderHalo
        ? MouseRegion(
            // 指针（2026-10-09 核查，**刻意不给 click**）：
            // - web 的头像指针事件层 `.msg-sender-halo`（`MessageBubble.tsx:224–231` +
            //   `app.css:1048–1053`）是 `<span>`，**无 cursor 声明** ⇒ 默认箭头；
            // - 真正可点的是它内部的 `<Avatar onClick>`（tsx 232–239），web 在该分支渲染
            //   `<button class="avatar-halo avatar-halo-btn">`（`Avatar.tsx:62–73`），
            //   `app.css:330` 才给 `cursor: pointer` —— Flutter 侧的
            //   `AylaAvatarHalo(onTap:)`（`avatar_halo.dart:339–340`）已按此挂 click。
            // 本层只承担长按 @（`_canMention`）这一**触屏**语义，web 对应元素是 span
            // ⇒ 显式 `basic`，避免长按层把 32×32 头像外的空白也染成手型
            //（头像本体仍是 click，因为内层 MouseRegion 会遮蔽本层）。
            cursor: SystemMouseCursors.basic,
            child: GestureDetector(
            // 长按 500ms（Flutter onLongPress 默认即 kLongPressTimeout = 500ms）
            onLongPress: _canMention
                ? () {
                    _longPressTriggered = true;
                    widget.onMentionSender!(
                      msg.senderId,
                      widget.senderName!,
                    );
                  }
                : null,
            onLongPressCancel: _clearLongPress,
            onLongPressUp: _clearLongPress,
            child: AylaAvatarHalo(
              // ⚠️ **2026-10-26 修复（用户实报「群成员退出后头像变成『发』字」）**：
              // 旧回退链是 `senderAvatarLabel ?? senderName ?? '发送者'`。群成员退出后
              // 他不在 `conversation.members` 里 ⇒ label/name **双双为 null** ⇒ 落到
              // 字面量「发送者」⇒ 头像取首字 → **「发」**。
              //
              // web 口径（`Avatar.tsx:37`）：`label?.trim() || "?"` —— 没有名字就显示
              // **问号**，而不是拿一个语义占位词去取首字。这里对齐 web（空串触发同一档）。
              label: widget.senderAvatarLabel ?? widget.senderName ?? '',
              size: 32,
              online: widget.senderOnline,
              user: widget.senderUser,
              userId: widget.senderUserId,
              resourceUrl: widget.senderAvatarUrl,
              onTap: _onSenderTap,
              // 语义标签同样不能编造「发送者个人主页」——没有名字时只表达「打开该用户主页」。
              semanticLabel: widget.senderName == null
                  ? '打开该用户主页'
                  : '${widget.senderName} 的个人主页',
            ),
          ),
          )
        : null;

    // 撤回键的显示条件（明确：**只有自己 2 分钟内的消息**才显示）。
    // web 由父级过滤（`MessageList.tsx:1084`：`onRecall={onRecall && canRecall(m, currentUserId)
    // ? onRecall : undefined}`）⇒ 组件内**再判一次**，父级漏传时对方消息也不会冒出撤回键。
    final bool showRecall =
        widget.onRecall != null && aylaCanRecall(msg, widget.currentUserId);

    final Widget? actions = (!recalled && !msg.isSystem)
        ? _MsgActions(
            msg: msg,
            // 悬停档只在 **`@media (hover:hover) and (not (max-width:768px))`** 的形态生效
            // （app.css:1317–1322）：窄屏 与 触屏档一律不因悬停展开，只走点行切换。
            // `_focused` 两档都留 —— 对应 web `.msg-row:focus-within`
            // （app.css:1304–1308，**无媒体查询**，键盘聚焦可达性）。
            visible: (_hovered && !_tapMode) ||
                _focused ||
                widget.actionsOpen,
            showRecall: showRecall,
            favoriteState: widget.favoriteState,
            favoriteBusy: widget.favoriteBusy,
            favoriteError: widget.favoriteError,
            onToggleFavorite: widget.onToggleFavorite,
            onRetryFavoriteStatus: widget.onRetryFavoriteStatus,
            favoriteTargetType: widget.favoriteTargetType,
            favoriteTargetId: widget.favoriteTargetId,
            favoriteController: widget.favoriteController,
            onQuote: widget.onQuote,
            onRecall: widget.onRecall,
          )
        : null;

    // ⚠️ **气泡宽度 = 内容宽**（2026-10-21 用户实报「气泡太长了」）。
    //
    // `Column` 的交叉轴默认按约束**撑满**（crossAxisAlignment.start/end 只是对齐，
    // 不改变自身宽）⇒ 外层 `ConstrainedBox(maxWidth: 75%)` 下它会取满 75%，
    // 于是撤回态/分享卡等窄内容消息的气泡背景横贯整行。
    //
    // 修法：用 `Row(mainAxisSize: MainAxisSize.min)` 包一层 —— Row 的主轴尺寸 min
    // 表示「按子级宽收缩」，而 Column 在 Row 里拿到的是 loose 约束，会按内容取宽。
    // （`IntrinsicWidth` 曾试过，会在语义树重建时触发 `parentDataDirty` 断言，不可用。）
    final Widget innerColumn = Column(
      crossAxisAlignment:
          widget.isSelf ? CrossAxisAlignment.end : CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        if (!widget.isSelf && widget.senderName != null)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: AylaSpacing.sp1),
            child: Text(
              widget.senderName!,
              style: const TextStyle(
                fontFamily: AylaFonts.body,
                fontFamilyFallback: AylaFonts.cjkFallback,
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: AylaColors.textSecondary,
              ),
            ),
          ),
        _BubbleWrap(
          msg: msg,
          isSelf: widget.isSelf,
          isElysia: widget.isElysia,
          onCancel: widget.onCancel,
          onRetry: widget.onRetry,
          onRemove: widget.onRemove,
          quoteText: widget.quoteText,
          onQuoteJump: widget.onQuoteJump,
          jumpedRecalled: widget.jumpedRecalled,
          shareGroupId: widget.shareGroupId,
          currentUserId: widget.currentUserId,
          descriptorFetcher: widget.descriptorFetcher,
          onDescriptorFetched: widget.onDescriptorFetched,
          audioEngineFactory: widget.audioEngineFactory,
          vodPlayerFactory: widget.vodPlayerFactory,
          onMentionTap: widget.onMentionTap,
          onDownloaded: widget.onDownloaded,
          onSaveError: widget.onSaveError,
          onNavigate: widget.onNavigate,
          isGroupJoined: widget.isGroupJoined,
          onRequestJoin: widget.onRequestJoin,
          onResolveShareTarget: widget.onResolveShareTarget,
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: AylaSpacing.sp1),
          child: Text(
            aylaMessageTimeAgo(msg.createdAt),
            style: const TextStyle(
              fontFamily: AylaFonts.utility,
              fontFamilyFallback: AylaFonts.cjkFallback,
              fontSize: 12,
              letterSpacing: 0.3,
              color: AylaColors.textSecondary,
            ),
          ),
        ),
      ],
    );

    final Widget body = innerColumn;

    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints c) {
        final bool narrow = AylaBreakpoints.isNarrow(MediaQuery.sizeOf(context).width);
        // `.msg-body { max-width: 75% }`（app.css:1074）/ 窄屏 84%（app.css:3217–3219）
        // 的百分比基数是 **`.msg-row` 的 content box** —— `.msg-row` 自身有
        // `padding: 0 var(--sp-1)`（app.css:1045，= 8px）⇒ 可分配宽 = 行宽 − 8。
        // 本件 `c` 是 LayoutBuilder 拿到的**整行**约束、`Padding(horizontal: sp1)`
        // 在它内层 ⇒ 不减这 8px 会让气泡最大宽多出 0.84×8 ≈ 6.7px。
        final double rowInnerWidth = math.max(
          0,
          c.maxWidth - 2 * AylaSpacing.sp1,
        );
        final double bodyMaxWidth = rowInnerWidth * (narrow ? 0.84 : 0.75);
        // `.msg-actions` 的 min-content = 各键 min-content 之和 + 键间 gap（app.css:1293）。
        // 实测（Chrome）：他人行 32 + 4 + 33.6 = 69.6；自己行再加 4 + 33.6 = 107.2。
        final int actionCount = 1 +
            (widget.onQuote != null ? 1 : 0) +
            (showRecall ? 1 : 0);
        final double actionsMinContent = kAylaFavoriteCompactMinWidth +
            (actionCount - 1) * AylaSpacing.sp1 +
            (actionCount - 1) * kAylaMsgActionBtnMinContent;
        // ⚠️ 主轴 = **CSS flex-shrink**（2026-10-22 补，见文件头「与 web 的偏差」3 已更新）。
        //
        // 上一轮这里是 Flutter 的 `Row`（子项**不收缩**），宽屏 900/1440 恰好对齐
        // （空间够，CSS 也不收缩），但窄屏 375 工具栏把气泡挤窄 —— web 的
        // `.msg-actions`/其按钮都是 `flex-shrink: 1`（app.css:1290–1298 / 1324–1333
        // **没有任何 flex-shrink:0 或 nowrap**），挤不下时按钮压窄 + 标签折行。
        //
        // Flutter 的 `Flexible` **不是**它的等价物（那是「分配空间」，空间够也会改宽，
        // 实测 900 档气泡 633→395 腰斩），故用自写的 [AylaCssFlexRow] 表达规范 §9.7
        // 的收缩分支：**只在真正溢出时**按 flex-basis 加权压缩，且各自不低于 min-width。
        //
        // 各件的 CSS 参数（逐条对账，实测值见 test/css_flex_row_test.dart）：
        // - 头像 `.msg-sender-halo { flex-shrink: 0 }`（app.css:1053）⇒ base 固定 37；
        // - 气泡 `.msg-body { max-width:75%(窄屏 84%); min-width:0 }`（app.css:1073–1083 /
        //   3217–3219）⇒ base 由自身 maxWidth 夹住，min-width 0；
        // - 工具栏 `.msg-actions` 无 shrink 声明 ⇒ 默认 1，最小 = 子项 min 之和
        //   （`.favorite-toggle.is-compact { min-width: 32px }`（app.css:3334–3338）；
        //    `.msg-action-btn` 因 `overflow:hidden`（auroraqua.css:142–146）min-width:auto
        //    解析为 0 ⇒ 能压到文本逐字折行，实测 375 档压到 33.6）。
        final List<Widget> children = <Widget>[
          if (halo != null)
            AylaCssFlexItem(flexShrink: 0, child: halo),
          AylaCssFlexItem(
            child: ConstrainedBox(
              constraints: BoxConstraints(maxWidth: bodyMaxWidth),
              // ⚠️ **气泡按内容收缩**（2026-10-21 用户实报「气泡太长了」）：
              //
              // web `.msg-bubble-wrap { max-width:100% }` 里的 `.bubble` 是收缩容器
              // ⇒ 宽度 = 内容 + padding。Flutter 侧 `ConstrainedBox` 只给**上限**，
              // 其内 `Column` 在 Row 的 loose 约束下会取「最大子宽」——而 `Text` /
              // 分享卡在 loose 约束里也会拉到 maxWidth ⇒ 撤回态、分享卡等窄内容消息
              // 的气泡横贯整行（截图实证）。
              //
              // `Align(widthFactor: 1.0)` 让本节点宽度 = 子级宽度（shrink-to-fit），
              // 等价 CSS 的收缩行为；且它只是**布局选择**，不参与 intrinsic 计算，
              // 不会触发 `IntrinsicWidth` 那类 `parentDataDirty` 断言。
              child: Align(
                alignment: widget.isSelf
                    ? Alignment.centerRight
                    : Alignment.centerLeft,
                widthFactor: 1.0,
                heightFactor: 1.0,
                child: body,
              ),
            ),
          ),
          if (actions != null)
            // 工具栏的 **min-content**（规范 §4.5 automatic minimum size）：
            // 每个按钮压到极限时的宽之和 + 按钮间 gap。
            //   · `.favorite-toggle.is-compact` → 32（app.css:3334–3338 明写 min-width）
            //   · `.msg-action-btn` → 16（图标盒）+ 16（padding 8×2）+ 2（border）= 34？
            //     不是：web 实测该按钮的 min-content = **33.6**（css 像素），
            //     与「图标 12 + margin-right 4 = 16」+ padding 16 + border 1.6 同源；
            //     本件按同一算式给 [kAylaMsgActionBtnMinContent]（见常量注释）。
            // 目标：375 档工具栏被压到 107.2（自己行 3 键）/ 69.6（他人行 2 键），
            // 与浏览器实测逐像素一致（见 test/css_flex_row_test.dart）。
            AylaCssFlexItem(
              minContentWidth: actionsMinContent,
              child: actions,
            ),
        ];
        // web `.msg-row { display:flex; align-items:flex-end; gap:var(--sp-2) }`
        // （app.css:1041–1046）+ `.msg-row.self { flex-direction: row-reverse }`
        // （app.css:1069–1071）—— `row-reverse` **同时把主轴起点移到右侧**
        // ⇒ 只反转子级顺序不够，self 行必须 `MainAxisAlignment.end` 才真的靠右
        // （实测「好呀我这就来这条没有置右」）。
        //
        // gap 用容器的 `gap`（不是 `SizedBox` 子项）：CSS 的 gap **不参与收缩**，
        // 若写成子项会被当成 flex item 一起压（宽度被分摊掉 ⇒ 气泡多算 8px）。
        final Widget row = AylaCssFlexRow(
          crossAxisAlignment: CrossAxisAlignment.end,
          gap: AylaSpacing.sp2,
          mainAxisAlignment: widget.isSelf
              ? MainAxisAlignment.end
              : MainAxisAlignment.start,
          children: widget.isSelf ? children.reversed.toList() : children,
        );

        // ⚠️ `GestureDetector` **恒在**（只要父级接了 `onToggleActions`）——
        // 与 web 同构：`MessageBubble.tsx:324–328` 的 `onClick={handleRowClick}`
        // **无条件挂在行上**，是否生效由回调**首行**在**事件发生时**判定。
        // 不能在 build 期按 `_tapOnly` 决定挂不挂：手势识别器是**指针按下时**
        // 注册进竞技场的，若那一次按下是手指、而本帧还没挂识别器，这一次点击就永远
        // 收不到回调（实测：先判后挂 → `onToggleActions` 调用 0 次）。
        //
        // 可点区域必须 = **整行**：web 的 `onClick` 挂在 `.msg-row` 这个 block-level
        // `display:flex` div 上 ⇒ 它**整个盒子**（全宽 × 内容高，含 `padding: 0 var(--sp-1)`，
        // app.css:1041–1046）都是点击目标。本件早先两条都漏了（用户 2026-10-13 实报
        // 「点击区域不对，要有 web 那一整行点击」）：
        //  ① 手势层必须**包住** `Padding(horizontal: sp1)` —— 旧实现把 Padding 留在手势层
        //     **外层** ⇒ 行左右各 4px 的 padding 条不可点；
        //  ② 点击档的 `HitTestBehavior` 必须取 **`opaque`** —— 默认 `deferToChild` 只让
        //     **被子级覆盖**的位置可命中 ⇒ 气泡上方的空白、头像上方空白、操作栏左侧空白
        //     全点不动（实测：375 宽行只有 y≈90–118 的窄条能点中）。
        //  `opaque` 只改「空白处是否命中本层」：气泡内的按钮/引用条仍在命中链更内层、
        //  在竞技场里照旧胜出 ⇒ 点按钮不会误触发本回调。
        final Widget paddedRow = Padding(
          padding: const EdgeInsets.symmetric(horizontal: AylaSpacing.sp1),
          child: row,
        );
        final Widget content = widget.onToggleActions != null
            ? GestureDetector(
                behavior: _tapMode
                    ? HitTestBehavior.opaque
                    : HitTestBehavior.deferToChild,
                // 点击档：点行（非交互区）切换工具栏展开（tsx 139–144）。
                // 子级按钮各自的手势识别器在竞技场中胜出 ⇒ 点按钮不会误触发本回调。
                onTap: () {
                  if (!_tapTogglesToolbar) return;
                  widget.onToggleActions!();
                },
                child: paddedRow,
              )
            : paddedRow;

        // `:focus-within`（app.css:1304–1308 `.msg-row:focus-within .msg-actions`）
        // 命中**行内任何**可聚焦元素 —— 含气泡内 `.quote-strip` 的 button 分支
        // （`MessageBubble.tsx:339–347`）。`Focus.onFocusChange` 只在该节点自身
        // 获得/失去焦点时触发；子节点取得焦点而父节点仍在链上不触发 —— 对布尔
        // 语义**恰好等价**：子树里任何可聚焦件拿到焦点 ⇒ `_focused = true`，
        // 焦点离开整行 ⇒ false（`FocusNode.hasFocus` 的「链上任意位置」语义）。
        // 此前 Focus 只包住操作栏自身 ⇒ 聚焦气泡里的引用键时工具栏不显示。
        return Focus(
          onFocusChange: (bool v) => setState(() => _focused = v),
          child: MouseRegion(
            // 无 hover 档（**窄屏** ∨ 触屏）整行可点（点行展开工具栏，见上方
            // `onToggleActions` 分支）⇒ 手型；
            // 有 hover 档行本体不可点，鼠标落在气泡上仍是 arrow（web 同：行无 pointer 声明）。
            cursor: _tapMode
                ? SystemMouseCursors.click
                : MouseCursor.defer,
            // 无 hover 档（窄屏 / 触屏）不记悬停：既不改判据，也省掉
            // 每次划过整行的一次重建（本行子树含玻璃层，重建不便宜）。
            onEnter: (_) {
              if (_tapMode || _hovered) return;
              setState(() => _hovered = true);
            },
            onExit: (_) {
              if (!_hovered) return;
              setState(() => _hovered = false);
            },
            child: Listener(
              // 记录**当次指针的设备类型** —— 供 [_tapTogglesToolbar] 在 `onTap`
              // 里按 web 的 `isTouch`（= `@media (hover: none)` 能力查询）判定。
              // `onPointerDown` 早于 `onTap`（后者在抬起时判定）⇒ 取样必然先于判定。
              // 只 `setState` 于**变化时**：否则每次按下都重建整行。
              onPointerDown: (PointerDownEvent e) {
                if (_lastPointerKind == e.kind) return;
                setState(() => _lastPointerKind = e.kind);
              },
              child: AnimatedBuilder(
                animation: _arrive,
                builder: (BuildContext context, Widget? child) {
                  if (_arrive.value >= 1.0) return child!;
                  final double t = AylaCurves.easeOut.transform(_arrive.value);
                  // `frost-rise`：opacity 0→1 + translateY 8→0（180ms）
                  // 依据（2026-09-27 收口；13 号 §8.19）：web `@keyframes frost-rise`
                  // （base.css:426–435）作用在**整行** `.msg-row` 上 ⇒ 整层 opacity，
                  // 含气泡自身的 `.bubble-other` blur(12px) 层 ⇒ 保持整层 Opacity。
                  return Opacity(
                    opacity: t,
                    child: Transform.translate(
                      offset: Offset(0, 8 * (1 - t)),
                      child: child,
                    ),
                  );
                },
                // 行内距已在 `paddedRow` 里加过（**必须叠在手势层之内**，见上）；
                // 此处不得再包一层，否则水平内距翻倍（8px）。
                child: content,
              ),
            ),
          ),
        );
      },
    );
  }
}

/// 气泡外层（`.msg-bubble-wrap`）：承载发送态与气泡本体（tsx 334–368）。
class _BubbleWrap extends StatelessWidget {
  const _BubbleWrap({
    required this.msg,
    required this.isSelf,
    required this.isElysia,
    this.onCancel,
    this.onRetry,
    this.onRemove,
    this.quoteText,
    this.onQuoteJump,
    this.jumpedRecalled = false,
    this.shareGroupId,
    this.currentUserId,
    this.descriptorFetcher,
    this.onDescriptorFetched,
    this.audioEngineFactory,
    this.vodPlayerFactory,
    this.onMentionTap,
    this.onDownloaded,
    this.onSaveError,
    this.onNavigate,
    this.isGroupJoined,
    this.onRequestJoin,
    this.onResolveShareTarget,
  });

  final AylaChatMessage msg;
  final bool isSelf;
  final bool isElysia;
  final void Function(AylaChatMessage msg)? onCancel;
  final void Function(AylaChatMessage msg)? onRetry;
  final void Function(AylaChatMessage msg)? onRemove;
  final String? quoteText;
  final void Function(AylaChatMessage msg)? onQuoteJump;
  final bool jumpedRecalled;
  final String? shareGroupId;
  final String? currentUserId;
  final AylaMediaDescriptorFetcher? descriptorFetcher;
  final void Function(AylaMediaDescriptor media)? onDescriptorFetched;
  final AylaAudioEngine Function()? audioEngineFactory;
  final VodPlayerFactory? vodPlayerFactory;
  final void Function(String userId)? onMentionTap;
  final void Function(String savedPath)? onDownloaded;
  final void Function(String detail)? onSaveError;
  final void Function(String route)? onNavigate;
  final bool Function(String groupId)? isGroupJoined;
  final void Function(AylaSharePayload payload)? onRequestJoin;
  final Future<String?> Function(AylaSharePayload? payload, String? groupId)?
      onResolveShareTarget;

  @override
  Widget build(BuildContext context) {
    final AylaChatMessage message = msg;
    final bool recalled = message.recalled;

    Widget? sendState;
    if (isSelf && !recalled && (message.pending || message.sendFailed)) {
      sendState = _SendState(
        msg: message,
        onCancel: onCancel,
        onRetry: onRetry,
        onRemove: onRemove,
      );
    }

    final Widget bubble = _BubbleFace(
      msg: message,
      isSelf: isSelf,
      isElysia: isElysia,
      quoteText: quoteText,
      onQuoteJump: onQuoteJump,
      jumpedRecalled: jumpedRecalled,
      shareGroupId: shareGroupId,
      currentUserId: currentUserId,
      descriptorFetcher: descriptorFetcher,
      onDescriptorFetched: onDescriptorFetched,
      audioEngineFactory: audioEngineFactory,
      vodPlayerFactory: vodPlayerFactory,
      onMentionTap: onMentionTap,
      onDownloaded: onDownloaded,
      onSaveError: onSaveError,
      onNavigate: onNavigate,
      isGroupJoined: isGroupJoined,
      onRequestJoin: onRequestJoin,
      onResolveShareTarget: onResolveShareTarget,
    );

    if (sendState == null) return bubble;

    // 发送态：web `.msg-send-state { position:absolute; right:calc(100% + 8px); top:50% }`
    // （app.css 1336–1345）——即**贴在气泡左缘外 8px、垂直居中**。
    //
    // ⚠️ Flutter 侧**不能**用「`Stack` + `Positioned.fill` + `FractionalTranslation(-1)`」
    // 表达这条 CSS：溢出父边界的部分会被祖先的命中测试丢弃（`RenderBox.hitTest` 只在
    // 自身 size 内接受）⇒ 取消/重试/删除三个键**点不到**（13 号 §6.4 同类现象）。
    // 改为在气泡左侧**占位**：self 行的 `msg-body` 交叉轴是 `end`（app.css 1085–1087），
    // body 变宽只向左扩展 ⇒ 右对齐的气泡**位置不变**，而状态整体落在 body 尺寸内、可点。
    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.center, // = CSS 的 top:50% + translateY(-50%)
      children: <Widget>[
        sendState,
        const SizedBox(width: AylaSpacing.sp2), // CSS `calc(100% + 8px)` 的 8px
        Flexible(child: bubble),
      ],
    );
  }
}

/// 气泡本体（三态材质 + 内容分支）。
class _BubbleFace extends StatelessWidget {
  const _BubbleFace({
    required this.msg,
    required this.isSelf,
    required this.isElysia,
    this.quoteText,
    this.onQuoteJump,
    this.jumpedRecalled = false,
    this.shareGroupId,
    this.currentUserId,
    this.descriptorFetcher,
    this.onDescriptorFetched,
    this.audioEngineFactory,
    this.vodPlayerFactory,
    this.onMentionTap,
    this.onDownloaded,
    this.onSaveError,
    this.onNavigate,
    this.isGroupJoined,
    this.onRequestJoin,
    this.onResolveShareTarget,
  });

  final AylaChatMessage msg;
  final bool isSelf;
  final bool isElysia;
  final String? quoteText;
  final void Function(AylaChatMessage msg)? onQuoteJump;
  final bool jumpedRecalled;
  final String? shareGroupId;
  final String? currentUserId;
  final AylaMediaDescriptorFetcher? descriptorFetcher;
  final void Function(AylaMediaDescriptor media)? onDescriptorFetched;
  final AylaAudioEngine Function()? audioEngineFactory;
  final VodPlayerFactory? vodPlayerFactory;
  final void Function(String userId)? onMentionTap;
  final void Function(String savedPath)? onDownloaded;
  final void Function(String detail)? onSaveError;
  final void Function(String route)? onNavigate;
  final bool Function(String groupId)? isGroupJoined;
  final void Function(AylaSharePayload payload)? onRequestJoin;
  final Future<String?> Function(AylaSharePayload? payload, String? groupId)?
      onResolveShareTarget;

  @override
  Widget build(BuildContext context) {
    final AylaChatMessage message = msg;
    final bool recalled = message.recalled;
    // 撤回态 class 退化为 `bubble-other`（tsx 210–216）
    final bool self = isSelf && !recalled;
    final bool elysia = isElysia && !recalled && !isSelf;
    final bool isMedia = message.isMedia && !recalled;

    // 圆角：self → `18 18 6 18`（右下小角）；elysia/other → `18 18 18 6`（左下小角）
    final BorderRadius radius = BorderRadius.only(
      topLeft: const Radius.circular(AylaRadii.rBubble),
      topRight: const Radius.circular(AylaRadii.rBubble),
      bottomRight: Radius.circular(self ? 6 : AylaRadii.rBubble),
      bottomLeft: Radius.circular(self ? AylaRadii.rBubble : 6),
    );

    // ⚠️ **气泡必须按内容收缩，不能撑满可用宽**（2026-10-21 用户实报「气泡太长了」）。
    //
    // web `.bubble` 是**行内块**（`display:block` 但父级 `.msg-bubble-wrap` 为
    // `max-width:100%` 的收缩容器）⇒ 宽度 = 内容 + padding。Flutter 侧此前只有
    // `ConstrainedBox(maxWidth: 75%)` 这层**上限**，而外层 `Row` 给的 loose 约束下
    // `Column` 会取「最大子宽」—— 但 `Text`/分享卡在 loose 约束里也会拉到 maxWidth，
    // 导致撤回态、分享卡等**内容很窄的消息气泡横贯整行**（截图实证）。
    //
    // 修法：用 `IntrinsicWidth` 让 Column 按**内容固有宽**收缩（等价 CSS 行内块的
    // shrink-to-fit）。注意它只影响「宽度方向的选择」，媒体气泡仍由自身尺寸决定
    // （AylaMediaContent 内部是固定尺寸，固有宽即其尺寸）；文本仍受外层 maxWidth 约束
    // 而正常换行。
    final Widget content = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        if (quoteText != null && !recalled)
          _QuoteStrip(
            text: quoteText!,
            onJump: onQuoteJump == null ? null : () => onQuoteJump!(message),
          ),
        _content(message, recalled, isMedia),
      ],
    );

    return Opacity(
      // `.bubble.recalled { opacity: .6; font-style: italic }`（app.css:1225–1228）
      // ⇒ web 是**整层 opacity**：它连同 `.bubble-other { background: var(--bubble-other);
      //   backdrop-filter: blur(12px) }`（app.css:1129–1136）一起被压暗
      //   ⇒ 保持整层（不以颜色 alpha 替代，否则模糊层不再被压暗；13 号 §8.19）。
      opacity: recalled ? 0.6 : 1.0,
      child: ClipRRect(
        borderRadius: radius,
        child: Stack(
          children: <Widget>[
            // ① 模糊层（仅 `.bubble-other` 有 `backdrop-filter: blur(12px)`，
            //    注意：**无 saturate**（app.css 1131）⇒ 用 blurOnly）
            if (!self && !elysia)
              Positioned.fill(
                // 背后内容层统一走 AylaGlassBackdrop（质量档 owner，§8.17）。
                child: AylaGlassBackdrop(
                  radius: radius,
                  filter: AylaGlassConfig.blurOnly(sigma: 12),
                ),
              ),
            // ② 底色层（渐变必须在**独立层**：同层 BoxDecoration 的渐变会盖住 1px 边框）
            Positioned.fill(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  // 别人气泡的降级值 = `rgba(255,250,251,.92)`：web 的
                  // `.bubble-other { background: var(--bubble-other); backdrop-filter:
                  // blur(12px) }`（app.css:1129–1136）**只命中** app.css:252–270 的
                  // `@supports` 降级段（不在 auroraqua.css:527–551 的清单里）
                  // ⇒ 实底档换软值 `.92` 而不是 `--surface`。
                  color: self || elysia
                      ? null
                      : (AylaGlassConfig.useOpaqueFallback
                            ? AylaColors.glassOpaqueFallbackSoft
                            : AylaColors.bubbleOther),
                  gradient: self
                      ? const LinearGradient(
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                          colors: AylaGradients.bubbleSelf,
                        )
                      : (elysia
                          ? const LinearGradient(
                              begin: Alignment.topLeft,
                              end: Alignment.bottomRight,
                              colors: AylaGradients.bubbleElysia,
                            )
                          : null),
                ),
              ),
            ),
            // ③ 边框层（elysia：1px `rgba(247,150,255,.5)`；other：1px `--glass-border`）
            if (elysia || (!self && !elysia))
              Positioned.fill(
                child: IgnorePointer(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      borderRadius: radius,
                      border: Border.all(
                        color: elysia
                            ? AylaColors.elysiaBubbleBorder
                            : AylaColors.glassBorder,
                      ),
                    ),
                  ),
                ),
              ),
            // ④ 内容（`.bubble { padding: 10px 14px }`；媒体气泡 `padding: sp1`）
            //
            // 🔴 **带边框的两档必须把 1px 边框计入内距**（2026-10-22 对账实测）。
            // web 是 `box-sizing: border-box`（base.css:7）⇒ `.bubble-other` /
            // `.bubble-elysia` 的 `border: 1px`（app.css:1124 / 1133）加在 **padding 之外**，
            // 外框宽 = 文本 + padding(14×2) + border(1×2)。
            // Flutter 的 `BoxDecoration.border` 画在**尺寸内**（本层 Stack 的
            // `Positioned.fill` 边框层与内容层同尺寸）⇒ 边框压在内距边缘、不撑大外框
            // ⇒ 每个带边框气泡比 web 窄 2px、文本比 web 靠外 1px。
            // 实测（900 档，字体已对齐）：peer-short web 44.91 / Flutter 42.89（−2.02）、
            // elysia-short web 71.66 / Flutter 69.65（−2.01）；**无边框**的 self 档
            // web 48.89 / Flutter 48.88（−0.01，仅文本测量差）⇒ 差值来源就是这 1px 边框。
            // 故带边框档内距取 padding + 1（水平 15 / 垂直 11），与 border-box 同解。
            Padding(
              padding: isMedia
                  ? const EdgeInsets.all(AylaSpacing.sp1)
                  : (self
                      // `.bubble-self` 无 border（app.css:1114–1118）⇒ 保持 10/14
                      ? const EdgeInsets.symmetric(horizontal: 14, vertical: 10)
                      : const EdgeInsets.symmetric(horizontal: 15, vertical: 11)),
              child: DefaultTextStyle.merge(
                style: TextStyle(
                  fontFamily: AylaFonts.body,
                  fontFamilyFallback: AylaFonts.cjkFallback,
                  fontSize: 15,
                  height: 1.55,
                  // ⚠️ **有意偏离 web**（实测「对方撤回了一条消息字体过于斜了」）：
                  // web 是 `.bubble.recalled { opacity: .6; font-style: italic }`（app.css 1225–1228），
                  // 但中文没有真斜体变体 ⇒ 浏览器/Flutter 都在合成斜体，而 Flutter（Skia）在
                  // 预览宿主的中文回退字体上倾角明显更大。撤回态保留 `opacity: .6` 弱化，
                  // **不再叠斜体**。改回 italic 前请先与用户确认。
                  fontStyle: FontStyle.normal,
                  color: elysia ? AylaColors.grape700 : AylaColors.indigo700,
                ),
                child: content,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _content(AylaChatMessage message, bool recalled, bool isMedia) {
    if (recalled) {
      return Text(
        jumpedRecalled
            ? '该消息已撤回'
            : (isSelf ? '你撤回了一条消息' : '对方撤回了一条消息'),
      );
    }
    if (message.isSystem) return Text(message.content);
    if (message.isShare) {
      return AylaShareBubble(
        msg: message,
        groupId: shareGroupId,
        isGroupJoined: isGroupJoined,
        onRequestJoin: onRequestJoin,
        onNavigate: onNavigate,
        onResolveTarget: onResolveShareTarget,
      );
    }
    if (isMedia) {
      return AylaMediaContent(
        msg: message,
        descriptorFetcher: descriptorFetcher,
        onDescriptorFetched: onDescriptorFetched,
        audioEngineFactory: audioEngineFactory,
        vodPlayerFactory: vodPlayerFactory,
        onMentionTap: onMentionTap,
        onDownloaded: onDownloaded,
        onSaveError: onSaveError,
        currentUserId: currentUserId,
      );
    }
    // 媒体消息气泡只渲染媒体本体（tsx 365–366）；其余显示正文（空则空格占位）
    return Text(message.content.isEmpty ? ' ' : message.content);
  }
}

/// 引用竖条（`.quote-strip`，app.css 1261–1285）。
class _QuoteStrip extends StatefulWidget {
  const _QuoteStrip({required this.text, this.onJump});

  final String text;
  final VoidCallback? onJump;

  @override
  State<_QuoteStrip> createState() => _QuoteStripState();
}

class _QuoteStripState extends State<_QuoteStrip> {
  bool _hovered = false;
  bool _focused = false;

  bool get _clickable => widget.onJump != null;

  @override
  Widget build(BuildContext context) {
    // web `MessageBubble.tsx:339–347` 的可点分支是**原生 `<button>`** ⇒ 天然进
    // tab 序列、可聚焦；不可点分支是 `<div>`（`tsx:349–351`）⇒ 不可聚焦。
    // Flutter 的 `GestureDetector` 不可聚焦 ⇒ 补一层 `Focus`（Enter/Space 触发同
    // `onJump`），并让 `:hover, :focus-visible → background .65`
    // （`app.css:1282–1285`）的焦点档也生效。
    // 焦点也因此被**行级** Focus 捕获（`app.css:1304` 的 `:focus-within`）。
    final Widget body = Focus(
      canRequestFocus: _clickable,
      onFocusChange: (bool has) => setState(() => _focused = has),
      onKeyEvent: (FocusNode node, KeyEvent event) {
        if (event is! KeyDownEvent) return KeyEventResult.ignored;
        final bool activate = event.logicalKey == LogicalKeyboardKey.enter ||
            event.logicalKey == LogicalKeyboardKey.space;
        if (!activate || !_clickable) return KeyEventResult.ignored;
        widget.onJump!();
        return KeyEventResult.handled;
      },
      child: MouseRegion(
      cursor: widget.onJump == null
          ? SystemMouseCursors.basic
          : SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: Semantics(
        label: '跳转到被引用消息：${widget.text}',
        button: widget.onJump != null,
        child: GestureDetector(
          onTap: widget.onJump,
          child: Opacity(
            opacity: 0.85,
            child: AnimatedContainer(
              duration: AylaDurations.fast,
              curve: AylaCurves.easeOut,
              margin: const EdgeInsets.only(bottom: AylaSpacing.sp1),
              decoration: BoxDecoration(
                // `background: rgba(255,250,251,.45)`；hover/focus → `.65`（app.css:1261–1285）
                color: (_hovered || _focused)
                    ? const Color(0xA6FFFAFB)
                    : const Color(0x73FFFAFB),
                borderRadius: BorderRadius.circular(AylaRadii.rSm),
              ),
              child: ClipRRect(
                // `border-left: 3px solid --ice-500` + 圆角：Flutter 的 BoxDecoration
                // 不允许「非均匀 border + borderRadius」⇒ 用 Stack + Positioned 色条。
                // ⚠️ **不能用 `Row(crossAxisAlignment: stretch)`** —— Row 在 Column 的
                // 竖直无界约束下会抛 `BoxConstraints forces an infinite height`
                // （13 号 §五「StackFit.expand / Center 在无界高度下的陷阱」）。
                borderRadius: BorderRadius.circular(AylaRadii.rSm),
                child: Stack(
                  children: <Widget>[
                    Positioned(
                      left: 0,
                      top: 0,
                      bottom: 0,
                      width: 3,
                      child: ColoredBox(color: AylaColors.ice500),
                    ),
                    Padding(
                      // 左 padding = sp2 + 3px 色条（等价 CSS 的 border-box padding）
                      padding: const EdgeInsets.only(
                        left: AylaSpacing.sp2 + 3,
                        right: AylaSpacing.sp2,
                        top: AylaSpacing.sp1,
                        bottom: AylaSpacing.sp1,
                      ),
                      child: Text(
                        widget.text,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        softWrap: false,
                        style: const TextStyle(
                          fontFamily: AylaFonts.body,
                          fontFamilyFallback: AylaFonts.cjkFallback,
                          fontSize: 13,
                          color: AylaColors.indigo700,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
      ),
    );
    // web «MessageBubble.tsx:341–352»：可点分支 «title="跳转到被引用消息"»、
    // 不可点分支 «title={quoteText}» —— 两分支同用 .quote-strip 类名。
    return AylaTooltip(
      message: widget.onJump != null ? '跳转到被引用消息' : widget.text,
      child: body,
    );
  }
}

/// 乐观发送状态（`.msg-send-state`，app.css 1336–1360 + tsx 276–322）。
class _SendState extends StatelessWidget {
  const _SendState({
    required this.msg,
    this.onCancel,
    this.onRetry,
    this.onRemove,
  });

  final AylaChatMessage msg;
  final void Function(AylaChatMessage msg)? onCancel;
  final void Function(AylaChatMessage msg)? onRetry;
  final void Function(AylaChatMessage msg)? onRemove;

  @override
  Widget build(BuildContext context) {
    final double? progress = msg.pending ? msg.uploadProgress : null;
    if (msg.pending) {
      if (progress != null) {
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Semantics(
              label: '上传中 ${progress.round()}%',
              child: Text(
                '上传中 ${progress.round()}%',
                style: const TextStyle(
                  fontFamily: AylaFonts.body,
                  fontFamilyFallback: AylaFonts.cjkFallback,
                  fontSize: 12,
                  color: AylaColors.textSecondary,
                ),
              ),
            ),
            if (onCancel != null) ...<Widget>[
              const SizedBox(width: AylaSpacing.sp1),
              AylaMsgActionButton(
                label: '取消',
                semanticLabel: '取消发送',
                onPressed: () => onCancel!(msg),
              ),
            ],
          ],
        );
      }
      // 纯文本发送中：spinner sm 14 + 轨道 rgba(70,91,146,.25)（app.css 1353–1355）
      return Semantics(
        label: '发送中',
        child: AylaLoadingSpinner(
          size: 14,
          track: const Color(0x40465B92),
        ),
      );
    }
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        const Text(
          '发送失败',
          style: TextStyle(
            fontFamily: AylaFonts.body,
            fontFamilyFallback: AylaFonts.cjkFallback,
            fontSize: 12,
            color: AylaColors.destructive,
          ),
        ),
        if (onRetry != null) ...<Widget>[
          const SizedBox(width: AylaSpacing.sp1),
          AylaMsgActionButton(
            label: '重试',
            semanticLabel: '重试发送',
            onPressed: () => onRetry!(msg),
          ),
        ],
        if (onRemove != null) ...<Widget>[
          const SizedBox(width: AylaSpacing.sp1),
          AylaMsgActionButton(
            label: '删除',
            semanticLabel: '删除消息',
            onPressed: () => onRemove!(msg),
          ),
        ],
      ],
    );
  }
}

/// 气泡操作栏（`.msg-actions`，app.css 1287–1331）。
class _MsgActions extends StatelessWidget {
  const _MsgActions({
    required this.msg,
    required this.visible,
    required this.showRecall,
    this.favoriteState,
    required this.favoriteBusy,
    this.favoriteError,
    this.onToggleFavorite,
    this.onRetryFavoriteStatus,
    this.favoriteTargetType,
    this.favoriteTargetId,
    this.favoriteController,
    this.onQuote,
    this.onRecall,
  });

  final AylaChatMessage msg;
  final bool visible;

  /// 是否显示「撤回」键（= 自己的消息且在 120s 窗口内，见 [AylaMessageBubble.build]）。
  final bool showRecall;

  /// 注入档收藏状态；null 且 [onToggleFavorite] 也为 null ⇒ 自给自足档（web 语义）。
  final AylaFavoriteState? favoriteState;
  final bool favoriteBusy;
  final String? favoriteError;
  final void Function(bool favorited)? onToggleFavorite;
  final VoidCallback? onRetryFavoriteStatus;
  final String? favoriteTargetType;
  final String? favoriteTargetId;
  final AylaFavoriteStatusController? favoriteController;
  final void Function(AylaChatMessage msg)? onQuote;
  final void Function(AylaChatMessage msg)? onRecall;

  /// 收藏键（web `MessageBubble.tsx:246` 的**条件恒真**分支）。
  ///
  /// - 调用方给了状态/回调 ⇒ 注入档（画布样张与既有测试逐像素不变）；
  /// - 都没给 ⇒ **自给自足档**：`targetType="message"`、`targetId=msg.id`
  ///   （web 写死的两个值），收藏键挂载即 retain + load ⇒ `message_list.dart`
  ///   **无需任何改动**就得到 web 的行为。
  Widget get _favorite {
    final bool injected =
        favoriteState != null || onToggleFavorite != null;
    if (injected) {
      return AylaFavoriteButton(
        state: favoriteState ?? AylaFavoriteState.unknown,
        compact: true,
        busy: favoriteBusy,
        actionError: favoriteError,
        onToggle: onToggleFavorite,
        onRetryStatus: onRetryFavoriteStatus,
      );
    }
    return AylaFavoriteButton(
      targetType: favoriteTargetType ?? 'message',
      targetId: favoriteTargetId ?? msg.id,
      controller: favoriteController,
      compact: true,
    );
  }

  @override
  Widget build(BuildContext context) {
    // 包装器**恒在**（只翻转可见标志位），否则 Element 重建会让隐式动画直接跳到终值
    // （13 号 §五：A5 会话球「瞬间消失」事故同一根因）。
    // ⚠️ 焦点不在本件：`:focus-within` 的判定已提到**整行**层级
    // （见 `AylaMessageBubble.build` 的 `Focus`）—— `app.css:1304` 覆盖行内任何可聚焦元素。
    return IgnorePointer(
        ignoring: !visible,
        child: AnimatedOpacity(
          // `.msg-actions { opacity: 0; pointer-events: none; transition: opacity var(--dur-fast)
          //   var(--ease-out) }`（app.css:1294–1302）；显示态 → `opacity: 1`：
          //   `.msg-row:focus-within`（app.css:1304–1308，**无媒体查询**）/
          //   `@media (hover:hover) and (not (max-width:768px)) .msg-row:hover`（app.css:1317–1322）/
          //   `@media (hover:none), (max-width:768px) .msg-row.is-actions-open`（app.css:1330–1335）
          //   ⇒ 后两条**互斥**：窄屏 ∨ 触屏走点击档，只有「宽屏且有 hover」才悬停展开。
          // ⇒ web 是**整层 opacity** ⇒ 保持 AnimatedOpacity。子树里的 AylaMsgActionButton 带
          //   blur(8px)（web 同款：auroraqua.css:122–129 的按钮材质组含 `.msg-action-btn`）
          //   ⇒ 不以颜色 alpha 替代（13 号 §8.19）。
          opacity: visible ? 1.0 : 0.0,
          duration: AylaDurations.fast,
          curve: AylaCurves.easeOut,
          child: Padding(
            // `.msg-actions { padding-bottom: 2px }`
            padding: const EdgeInsets.only(bottom: 2),
            // `.msg-actions { display:flex; align-items:center; gap:var(--sp-1) }`
            // （app.css:1290–1298）；**没有 flex-wrap** ⇒ 单行。
            //
            // 工具栏自身在消息行里是**可收缩项**（见 build 里的 [AylaCssFlexRow]），
            // 被压窄后它的按钮也按 `flex-shrink: 1` 继续收缩、标签折行
            // （375 档实测：`.msg-action-btn` 57.6×27.2 → 33.6×60.8，标签折两行）。
            // 下界按 CSS 的 automatic minimum size 取（见文件头事实源）：
            // - 收藏键 `.favorite-toggle.is-compact { min-width: 32px }`（app.css:3334–3338）；
            // - `.msg-action-btn` 有 `overflow:hidden`（auroraqua.css:142–146）⇒ min 0。
            child: AylaCssFlexRow(
              crossAxisAlignment: CrossAxisAlignment.center,
              gap: AylaSpacing.sp1,
              // 内层 flex 容器 ⇒ 宽度 = 子键之和（等价 CSS 里 `.msg-actions` 作为
              // 行内 flex item 的收缩宽，而不是撑满整行）。
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                AylaCssFlexItem(minWidth: 32, child: _favorite),
                // 引用键：web `MessageBubble.tsx:247` `{onQuote && (…)}` ——
                // **未接线时根本不渲染**（不是渲染一个无副作用的假按钮），
                // 与 `tsx:258` 的 `{onRecall && (…)}` 同一写法；
                // 同时 gap 也不出现（`.msg-actions { gap: var(--sp-1) }` 只在有子项时生效
                // ⇒ 交给容器 `gap`，左右各算一次会变成 8px）。
                if (onQuote != null)
                  AylaCssFlexItem(
                    child: AylaMsgActionButton(
                      label: '引用',
                      semanticLabel: '引用回复',
                      icon: _actionIcon('iconQuote', 12),
                      onPressed: () => onQuote!.call(msg),
                    ),
                  ),
                if (showRecall)
                  AylaCssFlexItem(
                    child: AylaMsgActionButton(
                      label: '撤回',
                      semanticLabel: '撤回消息',
                      icon: _actionIcon('iconUndo', 12),
                      onPressed: () => onRecall?.call(msg),
                    ),
                  ),
              ],
            ),
          ),
        ),
    );
  }

  static Widget? _actionIcon(String name, double size) {
    final AylaIconData? data = aylaIconByName(name);
    return data == null ? null : AylaIcon(data, size: size);
  }
}

// ======================= 样张 =======================

AylaChatMessage _previewBubbleMessage({
  required String id,
  required AylaMessageType type,
  String content = '',
  bool self = false,
  AylaMessageStatus status = AylaMessageStatus.sent,
  bool pending = false,
  bool sendFailed = false,
  double? uploadProgress,
  AylaMediaDescriptor? media,
  AylaSharePayload? share,
  /// 距当前时间多久（默认 3 分钟；撤回窗口 120s 内的用例传 30 秒）。
  Duration ago = const Duration(minutes: 3),
}) =>
    AylaChatMessage(
      id: id,
      conversationId: 'conv-1',
      senderId: self ? 'me' : 'user-2',
      type: type,
      content: content,
      mediaId: media?.mediaId,
      media: media,
      sharePayload: share,
      status: status,
      seq: 1,
      createdAt: DateTime.now().subtract(ago).toUtc().toIso8601String(),
      pending: pending,
      sendFailed: sendFailed,
      uploadProgress: uploadProgress,
    );

/// 气泡族样张。
///
/// 覆盖：他人（含发送者名 + 引用 + 操作栏）/ 自己 / 爱莉 / 撤回 / 系统 / 上传中 /
/// 发送失败 / 分享 / 媒体（图片）。操作栏在画布上以 `actionsOpen: true` 呈现
/// （等价触屏 `.is-actions-open` 展开态；桌面 hover 态由用户实测）。
Widget aylaMessageBubbleSamples() {
  aylaEnableSampleMedia();
  final AylaChatMessage other = _previewBubbleMessage(
    id: 'b1',
    type: AylaMessageType.text,
    content: '晚上一起看直播吗？我这边刚开播。',
  );
  return SingleChildScrollView(
    padding: const EdgeInsets.all(AylaSpacing.sp4),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        AylaMessageBubble(
          msg: other,
          isSelf: false,
          senderName: '小樱',
          senderAvatarLabel: '樱',
          senderOnline: true,
          quoteText: '那我先去占个位置',
          onQuoteJump: (_) {},
          onQuote: (_) {},
          // 对方消息：即使父级传了 onRecall，组件内 `canRecall` 判定也不会渲染撤回键
          onRecall: (_) {},
          actionsOpen: true,
          onToggleFavorite: (_) {},
          favoriteState: AylaFavoriteState.notFavorited,
        ),
        const SizedBox(height: AylaSpacing.sp4),
        AylaMessageBubble(
          msg: _previewBubbleMessage(
            id: 'b2',
            type: AylaMessageType.text,
            content: '好呀，我这就来 ✨',
            self: true,
            ago: const Duration(seconds: 30), // 撤回窗口（120s）内 ⇒ 显示撤回键
          ),
          isSelf: true,
          currentUserId: 'me',
          senderAvatarLabel: '汐',
          senderOnline: true,
          actionsOpen: true,
          onRecall: (_) {},
          favoriteState: AylaFavoriteState.favorited,
          onToggleFavorite: (_) {},
        ),
        const SizedBox(height: AylaSpacing.sp4),
        AylaMessageBubble(
          msg: _previewBubbleMessage(
            id: 'b3',
            type: AylaMessageType.text,
            content: '我在的～需要我帮你准备点什么吗？',
          ),
          isSelf: false,
          isElysia: true,
          senderName: '爱莉',
          senderAvatarLabel: '爱莉',
          senderOnline: true,
          onToggleFavorite: (_) {},
        ),
        const SizedBox(height: AylaSpacing.sp4),
        AylaMessageBubble(
          msg: _previewBubbleMessage(
            id: 'b4',
            type: AylaMessageType.text,
            content: '这条已经被撤回了',
            status: AylaMessageStatus.recalled,
          ),
          isSelf: false,
          senderName: '小樱',
          senderAvatarLabel: '樱',
          onToggleFavorite: (_) {},
        ),
        const SizedBox(height: AylaSpacing.sp4),
        AylaMessageBubble(
          msg: _previewBubbleMessage(
            id: 'b5',
            type: AylaMessageType.system,
            content: '小樱 加入了群聊',
          ),
          isSelf: false,
        ),
        const SizedBox(height: AylaSpacing.sp4),
        AylaMessageBubble(
          msg: _previewBubbleMessage(
            id: 'b6',
            type: AylaMessageType.text,
            content: '大图上传中，稍等…',
            self: true,
            pending: true,
            uploadProgress: 42,
          ),
          isSelf: true,
          currentUserId: 'me',
          senderAvatarLabel: '汐',
          senderOnline: true,
          onCancel: (_) {},
          onToggleFavorite: (_) {},
        ),
        const SizedBox(height: AylaSpacing.sp4),
        AylaMessageBubble(
          msg: _previewBubbleMessage(
            id: 'b7',
            type: AylaMessageType.text,
            content: '这条发送失败了',
            self: true,
            sendFailed: true,
          ),
          isSelf: true,
          currentUserId: 'me',
          senderAvatarLabel: '汐',
          senderOnline: true,
          onRetry: (_) {},
          onRemove: (_) {},
          onToggleFavorite: (_) {},
        ),
        const SizedBox(height: AylaSpacing.sp4),
        AylaMessageBubble(
          msg: _previewBubbleMessage(
            id: 'b8',
            type: AylaMessageType.share,
            share: AylaSharePayload.live(
              id: '9',
              title: '今晚一起看星星',
              ownerName: '爱莉',
            ),
          ),
          isSelf: false,
          senderName: '小樱',
          senderAvatarLabel: '樱',
          onToggleFavorite: (_) {},
        ),
        const SizedBox(height: AylaSpacing.sp4),
        AylaMessageBubble(
          msg: _previewBubbleMessage(
            id: 'b9',
            type: AylaMessageType.image,
            media: AylaMediaDescriptor(
              mediaId: 'm-image',
              kind: AylaMediaKind.image,
              mimeType: 'image/png',
              size: 240000,
              width: 640,
              height: 480,
              thumbnail: '/api/v1/media/m-image/thumbnail',
              status: 'ready',
            ),
          ),
          isSelf: false,
          senderName: '小樱',
          senderAvatarLabel: '樱',
          onToggleFavorite: (_) {},
        ),
      ],
    ),
  );
}
