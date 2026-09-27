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
/// | ESC 关闭 | tsx 64–71（`document.addEventListener("keydown")`）⇒ **由复用的通用弹层提供**（`AylaCreateSheet` 的 `Shortcuts` + `Actions(DismissIntent)`）；本件**不再**自己加全局监听 |
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
///
/// ## 公开面
/// `AylaQuickMessagesSheet` · 样张 `aylaQuickMessagesSheetSamples()`

library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart'
    show HardwareKeyboard, KeyDownEvent, KeyEvent, LogicalKeyboardKey;

import '../base/dialogs.dart' show AylaModalCard, AylaModalOverlay;
import '../../theme/app_icons.dart';
import '../../theme/sample_media.dart';
import '../../theme/tokens.dart';
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

  @override
  void initState() {
    super.initState();
    // ESC 关闭：web 监听 document（`QuickMessagesSheet.tsx 64–71`）⇒ 全局键盘监听
    // （这里**必须**自己实现：本件用的是裸的 `AylaModalOverlay + AylaModalCard` 容器，
    //  它们不带 ESC；`AylaCreateSheet` 才带，但它会多渲染一行 web 没有的标题 head ✗）
    HardwareKeyboard.instance.addHandler(_onKey);
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

    // 复用库内**现成的弹层容器**（与名单弹层同一套）：遮罩铺满 + 下方弹出的半屏卡
    // （`narrowHeightFactor` 表达 web 的 70% 高、`narrowRadius: 24` 表达 `24 24 0 0`、
    // 窄屏贴底上滑 250ms、卡片材质 `--glass-bg-strong` + blur24 sat1.4 + `--glass-shadow-modal`）。
    //
    // head 用**本件自己的**（web 原样）：`QuickMessagesSheet.tsx 177–204` ——
    // `.quick-messages-head` = **选项卡（flex:1）+ `.icon-btn-40` 关闭键**，**没有标题**
    // （标题只是 `role="dialog" aria-label="快捷消息"`）；CSS `padding: sp3 sp4` + 下边框
    // （messages.css 392–404）。
    // ⚠️ 别改用 `AylaCreateSheet`：它会渲染 `AylaSheetHead(title + 关闭键)` ⇒ 多出一行 web 没有的标题，
    // 且 ESC/关闭键会重复（实测 onClose 触发两次）。
    //
    // ⚠️ 本栏**窄屏专属**（web「R-QM，窄屏非导航页」；宽屏根本没有快捷消息栏）——由**调用方**保证；
    // 组件画布/`画布` 那类宽宿主由**样张舞台覆写 MediaQuery**（见 `aylaQuickMessagesSheetSamples`）。
    return AylaModalOverlay(
      onDismiss: widget.onClose, // 点遮罩关闭（`.quick-messages-scrim` 的 onClick）
      padding: 0, // 贴底铺满（无四周内沿）
      child: AylaModalCard(
        narrowHeightFactor:
            AylaQuickMessagesSheet.panelFraction, // `.quick-messages-panel { height: 70% }`
        narrowRadius: AylaQuickMessagesSheet.panelRadius, // `border-radius: 24px 24px 0 0`
        scrollable: false, // 各 tab 内容区自滚（`overflow-y: auto`）
        padding: EdgeInsets.zero,
        // 卡片给子级的是**无界高度** ⇒ 自己定死面板高（各 tab 内部滚动视图因此有界；
        // 与名单弹层同法）。head 是本件自己的，所以只扣面板高本身，不再扣 head。
        child: SizedBox(
          height: _contentHeight(context),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              _head(tabs),
              Expanded(child: _body(hasChat)),
            ],
          ),
        ),
      ),
    );
  }

  /// 面板内容高 = `.quick-messages-panel { height: 70% }`（**只按屏高算**，卡内自己不再留内沿
  /// —— 卡片的 `padding` 传 `EdgeInsets.zero`；head 是本件自己的，不额外扣高）。
  ///
  /// ⚠️ 不依赖任何行高估算：探针踩过「估 tabs 行高 60 ⇒ 溢出 23px、改成实测 82 又差 1px」，
  /// 现在改成**只定面板高、内部用 `Expanded` 分配**，任何行高变化都不会溢出。
  double _contentHeight(BuildContext context) =>
      MediaQuery.sizeOf(context).height * AylaQuickMessagesSheet.panelFraction;

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
          // `.icon-btn-40` 关闭键（`QuickMessagesSheet.tsx 202–204`：`aria-label="关闭快捷消息"`）
          const SizedBox(width: AylaSpacing.sp2),
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

// ======================= 样张 =======================

/// 快捷消息栏样张：
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
              // ⚠️ **必须覆写 MediaQuery**：本栏是窄屏专属（web「R-QM，窄屏非导航页」），
              // 而组件画布/预览宿主的 MediaQuery 是 1800 宽 ⇒ 弹层会按宽屏档渲染成
              // 「居中 + 四角圆角」✗（实测）。覆写成窄屏舞台尺寸后，
              // 弹层才走「下方弹出的半屏弹层」档（贴底 + 仅上圆角 24 + 70% 高）。
              child: Builder(
                builder: (BuildContext inner) => MediaQuery(
                  data: MediaQuery.of(inner).copyWith(
                    size: Size(width, height),
                  ),
                  child: child,
                ),
              ),
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
