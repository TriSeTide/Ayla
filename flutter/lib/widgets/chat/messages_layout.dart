/// 消息域页面骨架与宽屏右列 —— `messages.css` 的**页面级**声明块（19 号 §7.5 range B 的 B 类）。
///
/// ## 事实源（逐条）
///
/// | 本件 | web |
/// |---|---|
/// | [AylaMessagesPage] | `messages.css 9–15`（`.messages-page`：`height: 100%` / `overflow-y: auto` / column / **padding-bottom 68**）· `207–212`（≥769：`padding-bottom: 0` + `flex-direction: row`） |
/// | [AylaWideMessages] | `messages.css 236–241`（`.wide-messages`：`height: 100%` + row + `overflow: hidden`；`/chat/:id` 宽屏外壳） |
/// | [AylaWideMessagesPane] | `messages.css 281–291`（`.wide-messages-pane`：`flex: 1` + min-w/h 0 + flex）· `288–291`（`> .private-chat { flex: 1; min-width: 0 }`）· `324–329`（≥769 `.wide-messages-pane .private-chat { overflow: visible }`）· `331–339`（`.wide-messages-empty`：flex 1 / column / center / gap sp2 / padding sp4） |
/// | [AylaMessagesGroup] / [AylaMessagesGroupTitle] | `messages.css 83–94`（`.messages-group-title` 15/700 + margin-bottom sp2；`.messages-group` column + gap sp2） |
/// | [AylaMessagesSectionHint] | `messages.css 63–68`（`margin: calc(var(--sp-2) * -1) 0 0` + 13 / 1.5 / secondary） |
/// | [AylaMessagesEmpty] | `messages.css 199–205`（padding sp4 + 13 secondary + 居中） |
///
/// ## 为什么这些件在**页面层**才建
/// 它们是「页面装配骨架」（19 号 §7.5 range B 的 D 类原登记为「页面层未开工，不建件」）；
/// 本批（消息域）真的用到了 ⇒ 按用户指示「库内确无对应件时**先补件进画布再装配**」立件。
/// 与 [AylaPageState] 同口径：**文案一律调用方逐字传入**（本件不内置默认文案）。
///
/// ## 机制差异（登记）
/// - **FAB 避让**：web `.messages-page { padding-bottom: 68px }` **不含** `env(safe-area-inset-bottom)`；
///   Flutter 侧与已交付的 `HomePage`（`home.css:10–15` 同款 68）保持同一口径 —— **68 + safe**，
///   否则内容会落在系统手势条下（有意偏离，见 19 号 §十二）。
/// - `.messages-page-wide`（`MessagesPage.tsx:183` 的第二个类）= **死声明**（全仓 CSS 零命中）⇒ 不复刻。
///
/// ## 公开面
/// `AylaMessagesPage` · `AylaWideMessages` · `AylaWideMessagesPane` · `AylaWideMessagesEmpty` ·
/// `AylaMessagesGroupTitle` ·
/// `AylaMessagesGroup` · `AylaMessagesSectionHint` · `AylaMessagesEmpty` · 样张 `aylaMessagesLayoutSamples()`
library;

import 'package:flutter/material.dart';

import '../../theme/tokens.dart';
import '../base/page_state.dart' show AylaPlaceholderDesc, AylaPlaceholderTitle;

/// `.messages-page` —— 消息中心（`/messages`）页根容器。
///
/// 窄屏档（≤768）：column（`flex: none` 的选项卡行 + `flex: 1` 的内容区各自滚动）
/// + `padding-bottom: 68px`（底部避让悬浮 FAB）；
/// 宽屏档（≥769）：row + `padding-bottom: 0`（两列：左会话侧栏 + 右内容区）。
///
/// 调用方负责把「占满剩余高度」的子项包进 [Expanded]（与 web 的 `flex: 1` 同义）。
class AylaMessagesPage extends StatelessWidget {
  const AylaMessagesPage({
    super.key,
    required this.children,
    this.wide = false,
  });

  /// 子项（窄屏一般为 `[选项卡行, Expanded(内容区)]`；宽屏为 `[侧栏, Expanded(右列)]`）。
  final List<Widget> children;

  /// ≥769 档（`messages.css:207–212`）。
  final bool wide;

  /// `.messages-page { padding-bottom: 68px }` —— 底部 FAB 避让。
  static const double fabClearance = 68;

  @override
  Widget build(BuildContext context) {
    if (wide) {
      // ≥769：padding-bottom 归零（否则侧栏/输入框不铺满、底部露背景，messages.css:208–212）。
      return Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: children,
      );
    }
    // ≤768：底部避让 = 68 + 安全区（与 HomePage 同口径；见文件头「机制差异」）。
    final double safeBottom = MediaQuery.viewPaddingOf(context).bottom;
    return Padding(
      padding: EdgeInsets.only(bottom: fabClearance + safeBottom),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: children,
      ),
    );
  }
}

/// `.wide-messages` —— `/chat/:id` 宽屏两列外壳（`height: 100%` + row + `overflow: hidden`）。
class AylaWideMessages extends StatelessWidget {
  const AylaWideMessages({super.key, required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    // `overflow: hidden` ⇒ ClipRect（子项超出时不画到壳外）。
    return ClipRect(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: children,
      ),
    );
  }
}

/// `.wide-messages-pane` —— 宽屏右列（`/messages` 与 `/chat/:id` 共用）。
///
/// [child] 为 null 时渲染 `.wide-messages-empty` 空态（web `MessagesPage.tsx:194–197` 的两行文案）。
/// 本件返回 [Expanded] —— 与 web 的 `flex: 1` 同义，**必须**作为 Row 的直接子项使用。
class AylaWideMessagesPane extends StatelessWidget {
  const AylaWideMessagesPane({
    super.key,
    this.child,
    this.emptyTitle = '选择一个会话开始聊天',
    this.emptyDescription = '左侧会话列表，点击进入私聊',
  });

  /// 右列内容（一般是 `AylaPrivateChatPane`）；null = 空态。
  final Widget? child;

  /// 空态标题（`.placeholder-title`，`shell.css:619–624`；web 调用点逐字）。
  final String emptyTitle;

  /// 空态描述（`.placeholder-desc`，`shell.css:626–629`；web 调用点逐字）。
  final String emptyDescription;

  @override
  Widget build(BuildContext context) {
    final Widget? paneChild = child;
    return Expanded(
      child: paneChild == null
          ? AylaWideMessagesEmpty(
              title: emptyTitle,
              description: emptyDescription,
            )
          // `.wide-messages-pane > .private-chat { flex: 1; min-width: 0 }`
          : SizedBox.expand(child: paneChild),
    );
  }
}

/// `.wide-messages-empty`（`messages.css:331–339`）—— 宽屏右列空态。
///
/// 文案由调用方逐字传入（web `MessagesPage.tsx:194–197` 的两行；默认值即该处原文）。
class AylaWideMessagesEmpty extends StatelessWidget {
  const AylaWideMessagesEmpty({
    super.key,
    this.title = '选择一个会话开始聊天',
    this.description = '左侧会话列表，点击进入私聊',
  });

  final String title;
  final String description;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(AylaSpacing.sp4),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: <Widget>[
          AylaPlaceholderTitle(title),
          const SizedBox(height: AylaSpacing.sp2),
          AylaPlaceholderDesc(description),
        ],
      ),
    );
  }
}

/// `.messages-group-title` —— 分组标题（15 / w700 / textPrimary / margin-bottom sp2）。
class AylaMessagesGroupTitle extends StatelessWidget {
  const AylaMessagesGroupTitle(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: AylaSpacing.sp2),
      child: Text(
        text,
        style: const TextStyle(
          fontFamily: AylaFonts.body,
          fontFamilyFallback: AylaFonts.cjkFallback,
          fontSize: 15,
          fontWeight: FontWeight.w700,
          color: AylaColors.textPrimary,
        ),
      ),
    );
  }
}

/// `.messages-group` —— 分组容器（column + gap sp2）。
class AylaMessagesGroup extends StatelessWidget {
  const AylaMessagesGroup({super.key, required this.children, this.title});

  final List<Widget> children;

  /// 分组标题（null = 不渲染）。
  final String? title;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        if (title != null) AylaMessagesGroupTitle(title!),
        Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          spacing: AylaSpacing.sp2,
          children: children,
        ),
      ],
    );
  }
}

/// `.messages-section-hint` —— 分组说明（13 / 1.5 / secondary；`margin-top: -sp2`）。
class AylaMessagesSectionHint extends StatelessWidget {
  const AylaMessagesSectionHint(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Transform.translate(
      offset: const Offset(0, -AylaSpacing.sp2),
      child: Text(
        text,
        style: const TextStyle(
          fontFamily: AylaFonts.body,
          fontFamilyFallback: AylaFonts.cjkFallback,
          fontSize: 13,
          height: 1.5,
          color: AylaColors.textSecondary,
        ),
      ),
    );
  }
}

/// `.messages-empty` —— 行内空态文案（padding sp4 / 13 / secondary / 居中）。
class AylaMessagesEmpty extends StatelessWidget {
  const AylaMessagesEmpty(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(AylaSpacing.sp4),
      child: Text(
        text,
        textAlign: TextAlign.center,
        style: const TextStyle(
          fontFamily: AylaFonts.body,
          fontFamilyFallback: AylaFonts.cjkFallback,
          fontSize: 13,
          color: AylaColors.textSecondary,
        ),
      ),
    );
  }
}

// ======================= 样张 =======================

/// 消息域页面骨架样张：窄屏页骨架 / 宽屏两列 + 右列空态 / `/chat/:id` 外壳 + 分组件。
Widget aylaMessagesLayoutSamples() {
  Widget stage(String label, Widget child, {double width = 720, double height = 420}) =>
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
            child: SizedBox(
              width: width,
              height: height,
              child: ClipRect(child: child),
            ),
          ),
          const SizedBox(height: AylaSpacing.sp6),
        ],
      );

  Widget bar(double height) => Container(
        height: height,
        color: AylaColors.glassBg,
        alignment: Alignment.center,
        child: const Text(
          '选项卡行（AylaMessagesTabs）',
          style: TextStyle(
            fontFamily: AylaFonts.body,
            fontFamilyFallback: AylaFonts.cjkFallback,
            fontSize: 13,
            color: AylaColors.textSecondary,
          ),
        ),
      );

  Widget placeholder(String label) => Container(
        width: 332,
        color: AylaColors.glassBg,
        alignment: Alignment.center,
        child: Text(
          label,
          style: const TextStyle(
            fontFamily: AylaFonts.body,
            fontFamilyFallback: AylaFonts.cjkFallback,
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
        'AylaMessagesPage（窄屏：column + 底部 68 避让 FAB；内容区 Expanded 自滚）',
        AylaMessagesPage(
          children: <Widget>[
            bar(56),
            const Expanded(child: AylaMessagesEmpty('还没有好友，去搜索添加吧')),
          ],
        ),
        width: 420,
      ),
      stage(
        'AylaMessagesPage（宽屏：row + padding-bottom 0）+ AylaWideMessagesPane 空态',
        AylaMessagesPage(
          wide: true,
          children: <Widget>[
            placeholder('AylaWideMessagesSidebar'),
            const AylaWideMessagesPane(),
          ],
        ),
      ),
      stage(
        'AylaWideMessages（/chat/:id 外壳）+ 分组件（说明 / 组标题 / 空态）',
        AylaWideMessages(
          children: <Widget>[
            placeholder('AylaWideMessagesSidebar'),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(AylaSpacing.sp4),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    const AylaMessagesSectionHint('好友申请、群邀请和入群申请都会集中显示在这里。'),
                    AylaMessagesGroup(
                      title: '我的好友（2）',
                      children: const <Widget>[
                        AylaMessagesEmpty('好友行（AylaFriendRow）'),
                        AylaMessagesEmpty('好友行（AylaFriendRow）'),
                      ],
                    ),
                    const SizedBox(height: AylaSpacing.sp3),
                    AylaMessagesGroup(
                      title: '入群申请（群主/管理员）',
                      children: const <Widget>[AylaMessagesEmpty('申请行（AylaRequestRow）')],
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    ],
  );
}
