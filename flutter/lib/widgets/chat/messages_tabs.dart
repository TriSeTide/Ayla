/// 消息中心选项卡（`.messages-tabs`）—— `WideMessagesSidebar` 与 `QuickMessagesSheet` 共用。
///
/// ## 事实源
///
/// | 本件 | web |
/// |---|---|
/// | 容器 | messages.css 17–22（`.messages-tabs`：flex + gap sp2 + padding `sp3 sp4`）+ **auroraqua 273–278 覆写**（1px `--glass-border` 边 + **radius-card 16** + `--glass-inset`（**只有顶沿内高光、无外阴影**）+ `margin: sp2` + `padding: sp1`） |
/// | 项 | messages.css 24–37（`.messages-tab`：`flex: 1` / 40 高 / radius-input 12 / 14 / 700 / secondary；`is-active` → `rgba(157,191,230,.35)` + textPrimary）+ **auroraqua 194–197**（`.has-auroraqua-highlight:is(.is-active,.active)` 取消其自身底 ⇒ **底归共享胶囊**） |
/// | 侧栏档 | auroraqua 279–285（`.wide-messages-sidebar .messages-tab`：`flex: 1 1 0` / padding-inline 4 / 不换行） |
/// | 徽标 | messages.css 43–55 `.messages-tab-badge` ⇒ 复用 `AylaTabBadgeMetrics.messages`（min 18 / padding 0 5 / pill + glow-shadow / utility 11） |
/// | 窄屏档 | messages.css 214–222（`flex-direction: column` + width 260）⚠️ 其 `padding: sp4` 被 auroraqua 278 的同特异性规则**覆盖为 sp1**（auroraqua 后加载）⇒ 实际 padding 恒 sp1 |
///
/// ## 与 web 的差异（有意，登记）
/// web 的 `.messages-tabs` **未声明 `background`**（容器透明，只有胶囊有底），而本库
/// `AylaGlassSurface` 恒画 `--glass-bg` ⇒ 此处按 web 用**裸容器 + 1px 边 + `AylaGlassInset.over`**
/// （内高光走公共件），不套 `AylaGlassSurface`。这与 `AylaSidebarCard` 的取舍同源：
/// **一切以 web 实际声明的声明块为准**。
///
/// ## 公开面
/// `AylaMessagesTabItem` · `AylaMessagesTabs` · 样张 `aylaMessagesTabsSamples()`

library;

import 'package:flutter/material.dart';

import '../../theme/glass.dart';
import '../../theme/sample_media.dart';
import '../../theme/tokens.dart';
import '../base/nav_highlight_list.dart';
import '../base/tab_badge.dart';

/// 一个选项卡（key + 文案 + 可选徽标计数）。
class AylaMessagesTabItem {
  const AylaMessagesTabItem({
    required this.key,
    required this.label,
    this.badge = 0,
  });

  final String key;
  final String label;

  /// 徽标计数（0 = 不渲染；`.messages-tab-badge`）。
  final int badge;
}

/// 消息中心选项卡组。
class AylaMessagesTabs extends StatelessWidget {
  const AylaMessagesTabs({
    super.key,
    required this.items,
    required this.value,
    required this.onChange,
    this.narrow = false,
    this.padding = const EdgeInsets.all(AylaSpacing.sp1),
  });

  final List<AylaMessagesTabItem> items;
  final String value;
  final ValueChanged<String> onChange;

  /// 窄屏档（`flex-direction: column` + width 260）。
  final bool narrow;

  /// 内容内边距（auroraqua 278 `padding: sp1`；`.quick-messages-tabs` 覆写为 **0**）。
  final EdgeInsetsGeometry padding;

  /// 窄屏档宽度（messages.css 217：`width: 260px`）。
  static const double narrowWidth = 260;

  /// 项高（`.messages-tab { height: 40px }`）。
  static const double tabHeight = 40;

  @override
  Widget build(BuildContext context) {
    final int selected = items.indexWhere(
      (AylaMessagesTabItem i) => i.key == value,
    );

    // ⚠️ 等宽项：web 是 `flex: 1`（宽屏）—— `AylaNavHighlightList` 自排项（Row + gap），
    // 塞不进 `Expanded` ⇒ 在 `itemBuilder` 里按算出的每项宽度包一层 `SizedBox`
    // （与 `EmojiPackPanel` 的网格同手法；槽位几何随子项宽度，胶囊测量不受影响）。
    Widget buildNav(double? each) => AylaNavHighlightList(
      itemCount: items.length,
      selectedIndex: selected,
      axis: narrow ? Axis.vertical : Axis.horizontal,
      gap: AylaSpacing.sp2, // `gap: var(--sp-2)`
      semanticLabel: '消息中心视图',
      onSelect: (int i) => onChange(items[i].key),
      itemBuilder: (BuildContext context, AylaNavHighlightSlot slot) =>
          _MessagesTab(
            item: items[slot.index],
            slot: slot,
            narrow: narrow,
            width: each,
          ),
    );

    final Widget sized = narrow
        ? buildNav(null)
        : LayoutBuilder(
            builder: (BuildContext context, BoxConstraints c) {
              final double total = c.maxWidth.isFinite ? c.maxWidth : 0;
              if (items.isEmpty || total <= 0) return buildNav(null);
              final double each =
                  (total - AylaSpacing.sp2 * (items.length - 1)) / items.length;
              return buildNav(each);
            },
          );

    final Widget box = Container(
      margin: const EdgeInsets.all(
        AylaSpacing.sp2,
      ), // auroraqua 278 `margin: sp2`
      padding: padding, // auroraqua 278 `padding: sp1`（快捷栏覆写为 0）
      decoration: BoxDecoration(
        border: Border.all(
          color: AylaColors.glassBorder,
        ), // 1px `--glass-border`
        borderRadius: BorderRadius.circular(AylaRadii.rCard), // radius-card 16
      ),
      child: sized,
    );

    final Widget inset = AylaGlassInset.over(
      // `--glass-inset`：顶沿 1px 内高光（无外阴影）
      radius: BorderRadius.circular(AylaRadii.rCard),
      child: box,
    );

    if (!narrow) return inset;
    // 窄屏档固定宽 260：⚠️ `SizedBox(width:)` 走 `constraints.enforce`，紧宿主里会被夹回
    // 宿主宽（§6.39 同款坑）⇒ 用 `UnconstrainedBox` 松横向紧约束（库内 `live_rail`/
    // `AylaSidebarCard` 同做法）。
    return UnconstrainedBox(
      constrainedAxis: Axis.vertical,
      alignment: Alignment.topLeft,
      child: SizedBox(width: narrowWidth, child: inset),
    );
  }
}

/// `.messages-tab`（app.css 覆盖关系见文件头）。
class _MessagesTab extends StatefulWidget {
  const _MessagesTab({
    required this.item,
    required this.slot,
    required this.narrow,
    this.width,
  });

  final AylaMessagesTabItem item;
  final AylaNavHighlightSlot slot;
  final bool narrow;

  /// 宽屏档的等宽值（null = 由内容决定；窄屏档竖排时不限宽）。
  final double? width;

  @override
  State<_MessagesTab> createState() => _MessagesTabState();
}

class _MessagesTabState extends State<_MessagesTab> {
  @override
  Widget build(BuildContext context) {
    final AylaNavHighlightSlot slot = widget.slot;
    final AylaMessagesTabItem item = widget.item;
    final Color color = slot.active
        ? AylaColors.textPrimary
        : AylaColors.textSecondary;
    return SizedBox(
      width: widget.width,
      child: Focus(
        focusNode: slot.focusNode,
        onKeyEvent: slot.onKey,
        child: Listener(
          onPointerDown: (_) => slot.onPressedChanged(true),
          onPointerUp: (_) => slot.onPressedChanged(false),
          onPointerCancel: (_) => slot.onPressedChanged(false),
          child: MouseRegion(
            cursor: SystemMouseCursors.click,
            onEnter: (_) {
              slot.onHoverChanged(true);
              if (slot.active) slot.onSweep(true);
            },
            onExit: (_) {
              slot.onHoverChanged(false);
              if (slot.active) slot.onSweep(false);
            },
            child: GestureDetector(
              onTap: slot.onTap,
              child: Semantics(
                button: true,
                selected: slot.active,
                label: item.label,
                child: Container(
                  height: AylaMessagesTabs.tabHeight,
                  // `.messages-tab { border-radius: var(--radius-input) }`
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(AylaRadii.rInput),
                    // 选中项自身底被 auroraqua 194–197 取消（底归胶囊）；
                    // 未选中项 web 也没有底（`:hover` 未声明）⇒ 这里只在 hover 非选中项时
                    // 保持透明（**不加自创 hover 底**，与 web 一致）。
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: <Widget>[
                      Flexible(
                        child: Text(
                          item.label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          softWrap:
                              false, // `white-space: nowrap`（auroraqua 284）
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontFamily: AylaFonts.body,
                            fontFamilyFallback: AylaFonts.cjkFallback,
                            fontSize: 14,
                            fontWeight: FontWeight.w700,
                            color: color,
                          ),
                        ),
                      ),
                      if (item.badge > 0) ...<Widget>[
                        const SizedBox(
                          width: AylaSpacing.sp1,
                        ), // `margin-left: sp1`
                        AylaTabBadge(
                          count: item.badge,
                          metrics: AylaTabBadgeMetrics.messages,
                          placement: AylaTabBadgePlacement.inline,
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ======================= 样张 =======================

/// 消息中心选项卡样张：
/// 宽屏三档（私信/好友/认证 + 徽标）/ 快捷栏两档 / 窄屏竖排。
///
/// 交互态放在**私有 StatefulWidget** 里（不能放样张函数的局部变量：每次 rebuild
/// 函数体重跑会把状态重置，这是库内已记录过的坑）。
Widget aylaMessagesTabsSamples() {
  aylaEnableSampleMedia();
  return const _MessagesTabsSample();
}

class _MessagesTabsSample extends StatefulWidget {
  const _MessagesTabsSample();

  @override
  State<_MessagesTabsSample> createState() => _MessagesTabsSampleState();
}

class _MessagesTabsSampleState extends State<_MessagesTabsSample> {
  String _wide = 'chat';
  String _quick = 'chat';

  Widget _cell(String label, Widget child) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    mainAxisSize: MainAxisSize.min,
    children: <Widget>[
      Padding(
        padding: const EdgeInsets.only(bottom: AylaSpacing.sp2),
        child: Text(
          label,
          style: const TextStyle(
            fontFamily: AylaFonts.body,
            fontFamilyFallback: AylaFonts.cjkFallback,
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: AylaColors.textSecondary,
          ),
        ),
      ),
      Align(
        alignment: Alignment.topLeft,
        widthFactor: 1,
        child: SizedBox(width: 332, child: child),
      ),
      const SizedBox(height: AylaSpacing.sp6),
    ],
  );

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        _cell(
          '宽屏三档（私信/好友/认证消息 + 徽标）：选中底由共享胶囊提供',
          AylaMessagesTabs(
            value: _wide,
            onChange: (String v) => setState(() => _wide = v),
            items: const <AylaMessagesTabItem>[
              AylaMessagesTabItem(key: 'chat', label: '私信'),
              AylaMessagesTabItem(key: 'friends', label: '好友'),
              AylaMessagesTabItem(key: 'requests', label: '认证消息', badge: 3),
            ],
          ),
        ),
        _cell(
          '快捷消息栏两档（私信/认证消息）',
          AylaMessagesTabs(
            value: _quick,
            onChange: (String v) => setState(() => _quick = v),
            items: const <AylaMessagesTabItem>[
              AylaMessagesTabItem(key: 'chat', label: '私信'),
              AylaMessagesTabItem(key: 'requests', label: '认证消息', badge: 12),
            ],
          ),
        ),
      ],
    );
  }
}
