/// 页面状态壳 —— `.home-state` + placeholder 标题族（跨页复用）。
///
/// ## 事实源（逐条对应 web 源码，无自由发挥）
///
/// | web | 行 | 本件 |
/// |---|---|---|
/// | `.home-state` | `home.css:622–629`（620–621 是分节注释） | [AylaPageState]（flex column / align-items center / `gap: sp4` / `padding: sp12 sp6` / text-align center） |
/// | `.placeholder-title` | `shell.css:619–624` | [AylaPlaceholderTitle]（Display **28** / **w600** / `--text-primary`） |
/// | `.placeholder-desc` | `shell.css:626–629` | [AylaPlaceholderDesc]（**14** / `--text-secondary`；未声明 font-family ⇒ 继承 body） |
/// | `.favorites-content .home-state { padding-top: sp3 }` | `directory-filters.css:185–187` | [AylaPageState.padding]（收藏页覆盖档） |
/// | 目录页内容区组规则（`width: 100%` / **左右 padding 归零**） | `directory-filters.css:171–180` | ⚠️ **无人自动承担**：[AylaDirectoryContent] 只设滚动视图自身的 padding，覆盖不到子件 ⇒ 目录页调用点必须显式传 [kAylaPageStateDirectoryPadding]（2026-09-28 独立审计更正了原「已由滚动内容承担」的误判） |
///
/// ⚠️ 只做 `.home-state` + placeholder 标题族。**不要**与下面两件混为一谈：
/// - [AylaDirectoryLoadMore]（`DirectoryLoadMore.tsx`：错误态重试 / 加载更多 / 到底了，
///   `home.css:631–636` 的 `.home-load-more` 是其容器）；
/// - [AylaAsyncState]（`dialogs.dart`：加载/错误/空三态面板，另一件）。
///
/// ⚠️ `.search-empty` 是**另一个容器类**（`search.css:46–57`，含
/// `.search-empty .placeholder-title { font-size: 20px }` 的 20px 变体），归
/// `AylaSearchResults` 那件；本件只提供 [AylaPlaceholderTitle.fontSize] 以支持该变体。
///
/// ## web 调用点（12 处，逐处读过结构与文案 —— 本件**不自造档位**）
///
/// | 结构 | 调用点 |
/// |---|---|
/// | 空态 `title + desc` | `FavoritesPage.tsx:273–275` · `PostsHubPage.tsx:324–326 / 331–333` · `GamesHubPage.tsx:195–197 / 202–204` · `LiveHubPage.tsx:151–153` · `VoiceHubPage.tsx:296–298` · `MyPostsPage.tsx:188` |
/// | 空态 `title + desc + 动作` | `HomePage.tsx:171–179`（`btn-glow`「创建群聊」+ `btn-ghost`「搜索发现群」） |
/// | 受阻态 `role="alert"`：title + desc + 动作 | `UserPostsRoute.tsx:60–65`（「对方未开启内容展示」+「返回主页」） |
/// | 错态 `role="alert"`：desc + 动作 | `MyPostsPage.tsx:187`（`{error}` + 「重试」） |
/// | 加载态 `role="status"`：骨架 + 文本 | `VoiceHubPage.tsx:262–263`（`.skeleton` 96 + 「正在加载语音房…」） |
/// | 空态（**非** home-state，见上） | `home-wide-empty` `HomePage.tsx:142–144` · `voice-list-empty` `VoiceChannelList.tsx:28–34` · `live-hall-empty` `LiveHall.tsx:29–35` |
///
/// ⇒ 容器参数化：`title?` / `description?` / `children`（动作、骨架、任意附加件）+
/// `liveRegion`（`role="alert"/"status"` 的 Flutter 等价）+ `padding`（收藏页覆盖）。
/// 文案一律由调用方逐字传入（如 `这个分类还没有收藏` / `在对应场景点收藏，内容会出现在这里`）。
///
/// ## 公开面
/// `AylaPageState` · `AylaPlaceholderTitle` · `AylaPlaceholderDesc` ·
/// `kAylaPageStateDirectoryPadding`
library;

import 'package:flutter/material.dart';

import '../../theme/tokens.dart';

/// 目录页内容区档的内距（`directory-filters.css:171–180` 给 `.directory-content` 内的
/// `.home-state` 追加 `padding-left/right: 0`；上下仍是 sp12）——
/// **六个目录页的调用点必须传它**，否则可用宽度少 48px、长文案换行点与 web 不同。
const EdgeInsets kAylaPageStateDirectoryPadding = EdgeInsets.symmetric(
  vertical: AylaSpacing.sp12,
);

/// `.placeholder-title` —— Display 28 / w600 / `--text-primary`（`shell.css:619–624`）。
class AylaPlaceholderTitle extends StatelessWidget {
  const AylaPlaceholderTitle(
    this.text, {
    super.key,
    this.fontSize = 28,
    this.textAlign = TextAlign.center,
  });

  /// 文案（web 各调用点逐字传入，本件不内置任何默认文案）。
  final String text;

  /// 字号（默认 28；`search.css:55–57` 的 `.search-empty` 变体传 20）。
  final double fontSize;

  /// 对齐（容器 `text-align: center`）。
  final TextAlign textAlign;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      // web 六个目录页的 title 是 h2/h3，个人主页是 h1 ⇒ 均为标题语义。
      header: true,
      child: Text(
        text,
        textAlign: textAlign,
        style: TextStyle(
          fontFamily: AylaFonts.display,
          // ⚠️ 中文标题（「这个分类还没有语音房」等）必须走 CJK 回退链 —— Fredoka 无中文字形，
          // 缺 fallback 时中文落到引擎默认字体（2026-09-28 用户实报）。
          fontFamilyFallback: AylaFonts.cjkFallback,
          fontSize: fontSize,
          fontWeight: FontWeight.w600,
          color: AylaColors.textPrimary,
        ),
      ),
    );
  }
}

/// `.placeholder-desc` —— 14 / `--text-secondary`（`shell.css:626–629`）。
///
/// 全仓命中 4 处（已逐处读过）：本件两个定义 + 两处**域内覆盖** ——
/// `search.css:55–57`（`.search-empty .placeholder-title { font-size: 20px }`，由
/// [AylaPlaceholderTitle.fontSize] 表达）与 `app.css:225–227`
/// （`.visibility-selector-groups .placeholder-desc { padding: var(--sp-1) 0 }`，
/// 属选择器族自身的行内距，由调用方在该族容器上表达，本件不加 ——
/// `visibility_selector.dart` 自 2026-09-28 起已用
/// `EdgeInsets.symmetric(vertical: AylaSpacing.sp1)` + `textAlign: TextAlign.start`
/// 落地该族空态）。
class AylaPlaceholderDesc extends StatelessWidget {
  const AylaPlaceholderDesc(
    this.text, {
    super.key,
    this.textAlign = TextAlign.center,
  });

  /// 文案（web 各调用点逐字传入，本件不内置任何默认文案）。
  final String text;

  /// 对齐（容器 `text-align: center`）。
  final TextAlign textAlign;

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      textAlign: textAlign,
      style: const TextStyle(
        // 本件显式声明 body（Nunito）+ CJK 回退链：web 侧 `.placeholder-desc` 未声明
        // font-family ⇒ 继承 body；两侧最终落到同一组字体。
        fontFamily: AylaFonts.body,
        fontFamilyFallback: AylaFonts.cjkFallback,
        fontSize: 14,
        color: AylaColors.textSecondary,
      ),
    );
  }
}

/// `.home-state` —— 空 / 错 / 加载态的公共容器（`home.css:622–629`）。
///
/// `display: flex` / `flex-direction: column` / `align-items: center` /
/// `gap: var(--sp-4)` / `padding: var(--sp-12) var(--sp-6)` / `text-align: center`。
/// 宽度不设（web 块级撑满父级；目录页内容区里的 `width: 100%` 由组规则 171–180 给出、
/// 由 [AylaDirectoryContent] 的滚动内容承担）。
///
/// 用法（与 web 调用点同构，文案由调用方逐字给）：
/// `
/// // 空态：title + desc
/// AylaPageState(title: '这个分类还没有收藏', description: '在对应场景点收藏，内容会出现在这里')
/// // 空态 + 动作（HomePage.tsx:171–179）
/// AylaPageState(title: '创建你的第一个群', description: '和朋友们聚在一起，从这里开始',
///   children: [AylaGlassButton(label: '创建群聊', variant: AylaGlassButtonVariant.glow, ...)])
/// // 错态（MyPostsPage.tsx:187，role="alert"）
/// AylaPageState(liveRegion: true, description: error,
///   children: [AylaGlassButton(label: '重试', variant: AylaGlassButtonVariant.ghost, ...)])
/// // 加载态（VoiceHubPage.tsx:262–263，role="status"）
/// AylaPageState(liveRegion: true, children: [skeleton, const Text('正在加载语音房…')])
/// `
class AylaPageState extends StatelessWidget {
  const AylaPageState({
    super.key,
    this.title,
    this.description,
    this.children = const <Widget>[],
    this.padding,
    this.liveRegion = false,
    this.semanticLabel,
  });

  /// 标题（[AylaPlaceholderTitle]；null = 不渲染 —— 错态/加载态没有标题）。
  final String? title;

  /// 描述（[AylaPlaceholderDesc]；null = 不渲染）。
  final String? description;

  /// 附加内容（动作按钮 / 骨架 / 任意文本），排在 title、description 之后，
  /// 与二者共用 `gap: sp4`。
  final List<Widget> children;

  /// 容器内距；null = `padding: sp12 sp6`（`home.css:627`）。
  ///
  /// 收藏页空态覆盖顶部（`directory-filters.css:185–187`：`padding-top: sp3`）⇒ 传
  /// `EdgeInsets.fromLTRB(sp6, sp3, sp6, sp12)`。
  ///
  /// 目录页（六个 `.directory-content` 内的调用点）传 [kAylaPageStateDirectoryPadding]。
  final EdgeInsetsGeometry? padding;

  /// 是否为实时区域（`role="alert"` / `role="status"` 的 Flutter 等价：
  /// `Semantics(liveRegion: true)`）。web 用法见文件头调用点表。
  final bool liveRegion;

  /// 可访问名（web 无 `aria-label`，仅 `role`；需要时由调用方传）。
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    Widget box = Padding(
      padding:
          padding ??
          const EdgeInsets.symmetric(
            vertical: AylaSpacing.sp12, // padding: var(--sp-12)
            horizontal: AylaSpacing.sp6, // var(--sp-6)
          ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.center, // align-items: center
        spacing: AylaSpacing.sp4, // gap: var(--sp-4)
        children: <Widget>[
          if (title != null) AylaPlaceholderTitle(title!),
          if (description != null) AylaPlaceholderDesc(description!),
          ...children,
        ],
      ),
    );

    if (liveRegion || semanticLabel != null) {
      box = Semantics(
        container: true,
        liveRegion: liveRegion,
        label: semanticLabel,
        child: box,
      );
    }
    return box;
  }
}
