/// 红点快捷消息栏（`components/chat/QuickMessagesSheet.tsx` 的 Flutter 等价）。
///
/// ## 事实源
///
/// | 本件 | web |
/// |---|---|
/// | 覆盖层 | messages.css 343–347（`.quick-messages-overlay`：`position: fixed` + `inset: 0` + `z-index: 70`） |
/// | 遮罩 | messages.css 349–356（`.quick-messages-scrim`：**上 30%** + `rgba(70,91,146,.25)`；点击关闭） |
/// | 面板 | messages.css 358–378（`.quick-messages-panel`：**下 70%** + `--glass-bg-strong` + `--glass-filter` + 上边框 + **radius `24 24 0 0`** + `overflow: hidden` + `--glass-shadow-modal` + **slide-in 250ms ease-out**） |
/// | 头部 | messages.css 392–404（`.quick-messages-head`：padding `sp3 sp4` + 下边框；`.quick-messages-tabs { flex: 1; padding: 0 }`） |
/// | 内容区 | messages.css 406–425（`.quick-messages-private/-requests`：`flex: 1` + `min-height: 0` + `overflow-y: auto`；`.quick-messages-chat`：`flex: 1` + `display: flex`，内层 `.private-chat flex: 1`） |
/// | ESC 关闭 | tsx 64–71（`document.addEventListener("keydown")`）⇒ Flutter 侧用 `HardwareKeyboard.instance.addHandler`（同 `AylaMentionPickerHost`：web 监听 document，不能用 `Shortcuts`） |
/// | 两个 tab | tsx 178–202（私信 / 认证消息 + 徽标）⇒ 复用 `AylaMessagesTabs` |
///
/// ## 与 web 的差异（有意，登记）
/// 1. **本件返回全屏覆盖层内容**（`Stack` + 遮罩 + 底部面板），由调用方放进 **root Overlay**
///    （`aylaOverlayEntry`）或页面级 `Stack`——web 是 `position: fixed`，Flutter 侧没有等价物；
/// 2. **遮罩/面板高度用 `LayoutBuilder` 的 30% / 70%**（web 是百分比定位）；
/// 3. **slide-in 用 `AnimatedSlide`**：其位移基准正是**直接 child 的尺寸**（面板高）
///    ⇒ `offset: (0, 1)` = `translateY(100%)`，与 web 关键帧等价（skill「百分比基准」条的正例）；
/// 4. 栏内所有操作**不跳路由**：私信 tab 点会话 → 内联打开私聊面板（`activeChatId`），
///    头像一律不可点（`disableAvatarNav`）——判定与装配由调用方给。
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart'
    show HardwareKeyboard, KeyDownEvent, KeyEvent, LogicalKeyboardKey;
import 'package:flutter/widget_previews.dart';

import '../theme/app_icons.dart';
import '../theme/glass.dart';
import '../theme/preview_theme.dart';
import '../theme/sample_media.dart';
import '../theme/tokens.dart';
import 'messages_tabs.dart';

/// 快捷消息栏（窄屏非导航页左下角红点按钮触发）。
class AylaQuickMessagesSheet extends StatefulWidget {
  const AylaQuickMessagesSheet({
    super.key,
    required this.onClose,
    this.activeChatId,
    this.onBackToList,
    this.backLabel = '返回私信列表',
    this.privatePanel,
    this.requestsPanel,
    this.privateChatPane,
    this.requestBadge = 0,
    this.initialTab = 'chat',
    this.onTabChanged,
  });

  /// 关闭（遮罩点击 / 关闭键 / ESC）。
  final VoidCallback onClose;

  /// 私信 tab 内**内联**打开的会话 id（null = 列表态）。
  final String? activeChatId;

  /// 从内联私聊返回列表（web `onBack={() => setActiveChatId(null)}`）。
  final VoidCallback? onBackToList;
  final String backLabel;

  /// 私信 tab 列表态内容（调用方构造：爱莉入口 + 会话列表 + 分页）。
  final Widget? privatePanel;

  /// 认证 tab 内容（调用方构造 `AylaRequestsPanel`）。
  final Widget? requestsPanel;

  /// 内联私聊面板（调用方构造 `AylaPrivateChatPane`；与 `activeChatId` 配合）。
  final Widget? privateChatPane;

  /// 认证徽标计数。
  final int requestBadge;

  final String initialTab;
  final void Function(String tab)? onTabChanged;

  /// 遮罩高度占比（`.quick-messages-scrim { height: 30% }`）。
  static const double scrimFraction = 0.3;

  /// 面板高度占比（`.quick-messages-panel { height: 70% }`）。
  static const double panelFraction = 0.7;

  /// 面板顶部圆角（`.quick-messages-panel { border-radius: 24px 24px 0 0 }` —— **不是** radius-card 16）。
  static const double panelRadius = 24;

  @override
  State<AylaQuickMessagesSheet> createState() => _AylaQuickMessagesSheetState();
}

class _AylaQuickMessagesSheetState extends State<AylaQuickMessagesSheet> {
  late String _tab = widget.initialTab;
  bool _entered = false;

  @override
  void initState() {
    super.initState();
    // ESC 关闭：web 监听 document（tsx 64–71）⇒ 全局键盘监听（不是 `Shortcuts`）
    HardwareKeyboard.instance.addHandler(_onKey);
    // slide-in：挂载后下一帧把 offset 从 1 归零（250ms ease-out）
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) setState(() => _entered = true);
    });
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_onKey);
    super.dispose();
  }

  bool _onKey(KeyEvent event) {
    if (event is! KeyDownEvent) return false;
    if (event.logicalKey == LogicalKeyboardKey.escape) {
      widget.onClose();
      return true;
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    final bool hasChat = widget.activeChatId != null;
    final List<AylaMessagesTabItem> tabs = <AylaMessagesTabItem>[
      const AylaMessagesTabItem(key: 'chat', label: '私信'),
      AylaMessagesTabItem(
        key: 'requests',
        label: '认证消息',
        badge: widget.requestBadge,
      ),
    ];

    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints c) {
        final double height = c.maxHeight.isFinite ? c.maxHeight : 0;
        final double panelHeight = height * AylaQuickMessagesSheet.panelFraction;
        return Stack(
          fit: StackFit.expand,
          children: <Widget>[
            // 上 30% 遮罩（点击关闭）
            Positioned(
              left: 0,
              right: 0,
              top: 0,
              height: height * AylaQuickMessagesSheet.scrimFraction,
              child: GestureDetector(
                onTap: widget.onClose,
                child: const ColoredBox(color: Color(0x40465B92)), // rgba(70,91,146,.25)
              ),
            ),
            // 下 70% 面板
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              height: panelHeight,
              child: AnimatedSlide(
                // ⚠️ `AnimatedSlide` 的基准是**直接 child 尺寸**（= 面板高）
                // ⇒ offset 1 = translateY(100%)，与 web 的 slide-in 关键帧等价。
                offset: _entered ? Offset.zero : const Offset(0, 1),
                duration: const Duration(milliseconds: 250),
                curve: AylaCurves.easeOut,
                child: ClipRRect(
                  borderRadius: const BorderRadius.vertical(
                    top: Radius.circular(AylaQuickMessagesSheet.panelRadius),
                  ),
                  child: GlassSurface(
                    strong: true, // --glass-bg-strong
                    blur: AylaGlass.blurCard, // --glass-filter（blur24 sat1.4）
                    radiusOverride: const BorderRadius.vertical(
                      top: Radius.circular(AylaQuickMessagesSheet.panelRadius),
                    ),
                    borderOverride: const Border(
                      top: BorderSide(color: AylaColors.glassBorder),
                    ),
                    shadow: AylaShadows.modal, // --glass-shadow-modal
                    padding: EdgeInsets.zero,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: <Widget>[
                        _head(tabs),
                        Expanded(child: _body(hasChat)),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  /// `.quick-messages-head`（padding `sp3 sp4` + 下边框）。
  Widget _head(List<AylaMessagesTabItem> tabs) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AylaSpacing.sp4,
        vertical: AylaSpacing.sp3,
      ),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: AylaColors.glassBorder)),
      ),
      child: Row(
        children: <Widget>[
          Expanded(
            child: AylaMessagesTabs(
              items: tabs,
              value: _tab,
              // `.quick-messages-tabs { padding: 0 }`（覆写 auroraqua 278 的 sp1）
              padding: EdgeInsets.zero,
              onChange: (String v) {
                setState(() => _tab = v);
                widget.onTabChanged?.call(v);
              },
            ),
          ),
          const SizedBox(width: AylaSpacing.sp2),
          // `.icon-btn-40` 关闭键
          Semantics(
            button: true,
            label: '关闭快捷消息',
            child: GestureDetector(
              key: const ValueKey<String>('quick-messages-close'),
              onTap: widget.onClose,
              child: Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: AylaColors.glassBg,
                  border: Border.all(color: AylaColors.glassBorder),
                  borderRadius: BorderRadius.circular(AylaRadii.rInput),
                ),
                child: Center(
                  child: AylaIcon(aylaIconByName('iconClose')!, size: 20),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 内容区（`.quick-messages-chat` / `-private` / `-requests`）。
  Widget _body(bool hasChat) {
    if (hasChat) {
      final Widget? pane = widget.privateChatPane;
      return SizedBox.expand(
        child: pane ?? const SizedBox.shrink(),
      );
    }
    final Widget? panel =
        _tab == 'requests' ? widget.requestsPanel : widget.privatePanel;
    return SingleChildScrollView(
      padding: EdgeInsets.zero,
      child: panel ?? const SizedBox.shrink(),
    );
  }
}

// ======================= 预览 =======================

/// 快捷消息栏样张（**组件画布与 `@Preview` 共用**）：
/// 私信 tab（列表态）/ 认证 tab / 内联私聊态（含返回键）。
Widget aylaQuickMessagesSheetSamples() {
  aylaEnableSampleMedia();
  Widget stage(String label, Widget child, {double width = 420, double height = 560}) =>
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.only(bottom: AylaSpacing.sp2),
            child: Text(
              label,
              style: const TextStyle(
                fontFamily: AylaFonts.body,
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: AylaColors.textSecondary,
              ),
            ),
          ),
          Align(
            alignment: Alignment.topLeft,
            widthFactor: 1,
            child: SizedBox(
              width: width,
              height: height,
              child: child,
            ),
          ),
          const SizedBox(height: AylaSpacing.sp6),
        ],
      );

  Widget placeholder(String text) => Container(
        padding: const EdgeInsets.all(AylaSpacing.sp4),
        child: Text(
          text,
          textAlign: TextAlign.center,
          style: const TextStyle(
            fontFamily: AylaFonts.body,
            fontSize: 13,
            color: AylaColors.textSecondary,
          ),
        ),
      );

  return Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    mainAxisSize: MainAxisSize.min,
    children: <Widget>[
      stage(
        '私信 tab（上 30% 遮罩 + 下 70% 面板 + 两档选项卡）',
        AylaQuickMessagesSheet(
          onClose: () {},
          requestBadge: 3,
          privatePanel: placeholder('私信 tab 内容由调用方装配\n（爱莉入口 + 会话列表 + 分页）'),
        ),
      ),
      stage(
        '认证 tab（徽标 3）',
        AylaQuickMessagesSheet(
          onClose: () {},
          initialTab: 'requests',
          requestBadge: 3,
          requestsPanel: placeholder('认证 tab 内容由调用方装配\n（AylaRequestsPanel）'),
        ),
        height: 420,
      ),
      stage(
        '内联私聊态（不跳路由；返回列表键在私聊面板头部）',
        AylaQuickMessagesSheet(
          onClose: () {},
          activeChatId: 'c1',
          onBackToList: () {},
          privateChatPane: placeholder('内联私聊面板由调用方装配\n（AylaPrivateChatPane，onBack → onBackToList）'),
        ),
        height: 420,
      ),
    ],
  );
}

/// 快捷消息栏（私信 tab / 认证 tab / 内联私聊态）。
@Preview(
  group: 'Chat',
  name: '快捷消息栏（私信 · 认证 · 内联私聊）',
  size: Size(460, 1200),
  wrapper: previewTheme,
)
Widget quickMessagesSheetPreview() => aylaQuickMessagesSheetSamples();
