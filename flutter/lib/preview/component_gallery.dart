/// 组件库审核画布（Batch 1：材料基元 + 基元组件）。
///
/// 用途（定）：**逐个组件审核**，而不是先看整页。
/// 本文件提供一张「大画面」预览卡，把当前批次组件按 web 原始尺寸并排
/// 铺开，供用户在预览器里逐项对照 web 审核。
///
/// 排布纪律：
/// - 每个组件区上方标出其 **web 选择器 + 数值来源文件**，便于对照；
/// - 组件一律用真实尺寸（不缩放、不留白填充），宽屏按 web CSS 像素原值
///   （Windows 125% 口径：web CSS px = Flutter 逻辑 px）；
/// - 本画布只含组件，不含页面。
///
/// 当前批次事实源（全部来自 web 源码，非旧实现）：
/// - `app.css` `.btn/.btn-primary/.btn-glow/.btn-ghost/.field/.glass-card/.avatar*`
/// - `auroraqua.css`（交互/覆写/sweep）
/// - `base.css`（spinner/skeleton/fullscreen-loader/frost-pulse/halo-breathe）
/// - `shell.css` `.tab-badge`
/// - `tokens.css` / `design.md` §2/§3/§4/§6/§7.3
library;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../theme/app_icons.dart';
import '../theme/app_theme.dart';
import '../theme/aurora_background.dart';
import '../theme/glass.dart';
import '../theme/sample_media.dart';
import '../theme/svg_path.dart' show AylaPencilGlyph;
import '../widgets/base/auth_code_row.dart' show aylaAuthCodeRowSamples;
import '../widgets/profile/profile_presence.dart' show aylaProfilePresenceSamples;
import '../theme/tokens.dart';
import '../widgets/base/avatar_halo.dart';
import '../widgets/base/avatar_status_badges.dart';
import '../widgets/shell/bottom_tabs.dart';
import '../widgets/shell/group_top_tabs.dart';
import '../widgets/base/dialogs.dart';
import '../widgets/base/directory_controls.dart';
import '../widgets/voice/elysia_voice_panel.dart';
import '../widgets/base/privacy_sheet.dart';
import '../widgets/base/profile_and_filters.dart';
import '../widgets/group/group_card.dart';
import '../widgets/base/media_interaction.dart';
import '../core/media/media_signer.dart';
import '../core/net/dio_client.dart';
import '../pages/login_page.dart' show aylaAuthOptionsSamples;
import '../widgets/base/resource_image.dart';
import '../widgets/base/loading.dart';
import '../widgets/shell/channel_sidebar.dart';
import '../widgets/posts/comments.dart';
import '../widgets/shell/create_sheet.dart';
import '../widgets/shell/fab.dart';
import '../widgets/chat/image_viewer.dart';
import '../widgets/posts/post_card.dart';
import '../widgets/posts/post_detail_chrome.dart' show aylaPostDetailChromeSamples;
import '../widgets/posts/post_page_chrome.dart' show aylaPostChromeSamples;
import '../widgets/group/home_toolbar.dart' show aylaHomeToolbarSamples;
import '../widgets/posts/post_editor.dart';
import '../widgets/posts/post_edit_fullscreen.dart'
    show aylaPostEditFullscreenSamples;
import '../widgets/base/primitives.dart';
import '../widgets/base/reveal.dart';
import '../widgets/base/switch.dart';
import '../widgets/shell/server_rail.dart';
import '../widgets/shell/session_activity.dart';
import '../widgets/base/share.dart';
import '../widgets/base/tab_badge.dart';
import '../widgets/shell/top_nav.dart';
import '../widgets/voice/voice_channel_create.dart';
import '../widgets/voice/voice_channel_panel.dart';
import '../widgets/voice/voice_channels.dart';
import '../widgets/voice/voice_member_row.dart';
import '../widgets/live/danmaku.dart';
import '../widgets/chat/elysia_entry.dart';
import '../widgets/live/live_hall.dart';
import '../widgets/live/live_rail.dart';
import '../widgets/live/live_create.dart';
import '../widgets/live/live_mini_player.dart';
import '../widgets/live/live_owner_panel.dart';
import '../widgets/live/live_player.dart';
import '../widgets/live/live_room_body.dart';
import '../widgets/live/live_studio.dart';
import '../widgets/live/live_viewers.dart';
import '../widgets/chat/conversation_list.dart';
import '../widgets/game/game_room_card.dart';
import '../widgets/game/game_room_create.dart';
import '../widgets/game/game_room_placeholder.dart';
import '../widgets/group/group_apply.dart';
import '../widgets/base/directory_page.dart';
import '../widgets/base/directory_result_cards.dart';
import '../widgets/base/page_state.dart';
import '../widgets/shell/overlay_scrollbar.dart';
import '../widgets/base/profile_content_sections.dart';
import '../widgets/group/group_create_dialog.dart';
import '../widgets/group/group_info_settings.dart';
import '../widgets/profile/profile_edit.dart';
import '../widgets/group/subgroup_dialog.dart';
import '../widgets/chat/emoji_pack_panel.dart';
import '../widgets/chat/media_content.dart';
import '../widgets/chat/message_input.dart';
import '../widgets/chat/message_list.dart';
import '../widgets/chat/messages_layout.dart';
import '../widgets/motion/panel_swap.dart';
import '../widgets/chat/messages_tabs.dart';
import '../widgets/base/nav_highlight_list.dart';
import '../widgets/base/overlays.dart' show aylaOverlayEntry;
import '../widgets/chat/mention_picker.dart';
import '../widgets/chat/message_bubble.dart';
import '../widgets/chat/private_chat_pane.dart';
import '../widgets/chat/quick_messages_sheet.dart';
import '../widgets/chat/request_rows.dart';
import '../widgets/chat/share_bubble.dart';
import '../widgets/voice/voice_room_body.dart';
import '../widgets/chat/wide_messages_sidebar.dart';
import '../widgets/base/tooltip.dart';
import '../theme/buttons.dart';
import '../widgets/motion/page_transition.dart';
import '../widgets/search/search_history_chips.dart';
import '../widgets/search/search_result_group.dart';
import '../widgets/search/search_user_row.dart';
import '../widgets/posts/masonry_grid.dart';
import '../widgets/profile/favorites_skeleton.dart';
import '../widgets/profile/profile_card.dart';
import '../widgets/game/games_grid.dart';
import '../widgets/group/group_role_chip.dart';
import '../widgets/group/transfer_owner_dialog.dart';
import '../widgets/group/group_info_profile.dart';
import '../widgets/group/group_info_manage.dart';
import '../widgets/group/group_info_lists.dart';
import '../widgets/group/group_chat_subgroup_bar.dart';
import '../widgets/group/group_posts_composer.dart';
import '../widgets/group/group_scene.dart';
import '../widgets/motion/gestures.dart';
import '../widgets/base/favorite_item.dart';

/// 审核画布宽度（导航 248 + 内容区；高度按所选分类内容收紧，不再是一张 1700 高的大画面）。
const Size kGallerySize = Size(1800, 1200);

/// 画布分类（左侧导航项）。
///
/// [prefixes] 与 `_Section.title` 做**前缀匹配**（用组件名/中文件名做前缀，互不重叠）；
/// 新增组件时把它的标题前缀加进对应类，否则会落到「未分类」（导航里会显式提示）。
class AylaGalleryCategory {
  const AylaGalleryCategory(this.id, this.label, this.prefixes);

  /// 稳定 id（状态里记录「已访问过」的分类）。
  final String id;

  /// 导航显示名。
  final String label;

  /// 归入本类的分区标题前缀。
  final List<String> prefixes;
}

/// 未匹配到任何分类时的兜底 id（导航里恒排最后 ⇒ 一眼能看出漏了映射）。
const String kGalleryFallbackCategoryId = 'other';

/// 分类导航（顺序 = 导航顺序；按 web 的域划分，与库内文件分组同构）。
const List<AylaGalleryCategory> kGalleryCategories = <AylaGalleryCategory>[
  AylaGalleryCategory('base', '基元 · 材质 · 排版', <String>[
    'AylaGlassButton',
    'AylaGlassCard',
    'AylaGlassInput',
    'AylaGlassQuality',
    'AylaAuroraBackground',
    'AylaAvatarHalo',
    'AylaTabBadge',
    'AylaRevealItem',
    'Skeleton + Spinner',
    'Icon 图标库',
    'Batch 2 基元',
    'Typography',
    'AylaTooltip',
    'AylaSwitch（通用开关',
  ]),
  AylaGalleryCategory('shell', 'Shell · 导航壳与浮层', <String>[
    'AylaBottomTabs',
    'AylaGroupTopTabs',
    'AylaTopNav',
    'AylaServerRail',
    'AylaChannelSidebar',
    'AylaCreateSheet',
    'AylaCornerFabStack',
    'AylaSessionActivityIndicator',
  ]),
  AylaGalleryCategory('chat', 'chat · 气泡 / 列表 / 输入 / 面板', <String>[
    '聊天消息气泡',
    '媒体消息族',
    '分享卡 / 爱莉入口卡',
    '会话列表',
    '@ 成员选择器',
    '群表情包面板',
    '消息输入区',
    '消息滚动区',
    '消息中心选项卡',
    '认证消息面板',
    '私聊面板',
    '宽屏消息左列',
    '快捷消息栏',
    'AylaImageViewer',
    'AylaMessagesPage / AylaWideMessages / AylaWideMessagesPane',
  ]),
  AylaGalleryCategory('live', 'live · 直播域', <String>[
    'AylaDanmakuList',
    'AylaLiveChannelCard',
    'AylaLiveChannelRail',
    'AylaLiveViewerStrip',
    'AylaLiveHostAvatar',
    'AylaLiveCreate',
    'AylaLiveOwnerPanel',
    'AylaLivePlayer',
    'AylaLiveMiniPlayer',
    'AylaLiveRoomBody',
    'AylaStudioEmpty',
  ]),
  AylaGalleryCategory('voice', 'voice · 语音域', <String>[
    'AylaVoiceChannelCard',
    'AylaVoiceMemberRow',
    'AylaVoiceChannelCreate',
    'AylaVoiceChannelPanel',
    'AylaElysiaVoicePanel',
    'AylaVoiceRoomBody',
  ]),
  AylaGalleryCategory('posts', 'posts · 帖子 / 评论', <String>[
    'AylaMasonryGrid',
    'AylaPostCard',
    'AylaPostsSkeleton',
    'AylaPostDetailChrome',
    'AylaPostEditFullscreen',
    'AylaPostEditor',
    'AylaGroupPostsComposer',
    'AylaCommentList',
  ]),
  AylaGalleryCategory('group', 'group · 群与目录', <String>[
    'GroupCard / GroupCarousel',
    'AylaHomeToolbar',
    '子群弹窗',
    '群聊申请弹窗',
    '建群对话框',
    '目录结果卡',
    'AylaDirectoryPage / AylaDirectoryContent',
    'AylaTransferOwnerDialog',
    'AylaGroupRoleChip',
    'AylaGroupInfoProfile',
    'AylaGroupInfoSettingRow / AylaGroupInfoSwitch / AylaGroupInfoSelect / AylaGroupJoinRequests',
    'AylaGroupSceneHead',
    'AylaGroupChatSubgroupBar',
    'AylaGroupInfoSectionTitle',
    'AylaGroupInfoLayout',
  ]),
  AylaGalleryCategory('game', 'boardgame · 桌游域', <String>[
    'AylaGamesGrid',
    '桌游室卡片',
    '创建桌游室表单',
    '桌游室占位整页壳',
  ]),
  AylaGalleryCategory('profile', 'profile · 个人主页域', <String>[
    'AylaFavoriteItem',
    'AylaProfileCard',
    'AylaFavoritesSkeleton',
    '个人主页内容分区', // 2026-09-25 用户指正：本件属 profile 域（早期误放在「群与目录」，当时还没有 profile 分类）
    'AylaStatusChips / AylaProfileSwitch / AylaProfileForm',
    'AylaProfilePresence', // 2026-09-28：由 user_profile_page 私有件提升
  ]),
  AylaGalleryCategory('search', 'search · 搜索域', <String>[
    'AylaSearchHistoryChips',
    'AylaSearchResultGroup',
    'AylaSearchUserRow',
  ]),
  AylaGalleryCategory('motion', 'motion · 转场与手势', <String>[
    'AylaPageTransition',
    '手势动画（空白卡片模拟）',
    'AylaPanelTransition / AylaConversationTransition / AylaFullScreenSwipeBack / AylaPrimaryNavPage',
    'AylaPanelSwap',
  ]),
  AylaGalleryCategory('common', '通用件 · 分享 / 分页 / 弹层 / 资源', <String>[
    'AylaShareSheet',
    'AylaResourceImage',
    'AylaConfirmDialog',
    'AylaAuthCodeRow', // 2026-09-28：注册页组装与 privacy_sheet 私有件合并
    'AylaAuthOptions', // 2026-10-01：登录页「记住密码 / 自动登录」（新增功能，web 无对应）
    'PullToRefresh',
    '分页族',
    'VisibilitySelector',
    '覆盖层滚动条',
  ]),
];

/// 该分区属于哪个分类 id（无匹配 ⇒ [kGalleryFallbackCategoryId]）。
String aylaGalleryCategoryOf(String title) {
  for (final AylaGalleryCategory c in kGalleryCategories) {
    for (final String prefix in c.prefixes) {
      if (title.startsWith(prefix)) return c.id;
    }
  }
  return kGalleryFallbackCategoryId;
}

/// 分类作用域：`_GalleryColumn` 据此决定每个分区「不建 / 保活但不画 / 正常画」。
class _GalleryScope extends InheritedWidget {
  const _GalleryScope({
    required this.selectedId,
    required this.visitedIds,
    required super.child,
  });

  final String selectedId;
  final Set<String> visitedIds;

  static _GalleryScope? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_GalleryScope>();

  @override
  bool updateShouldNotify(_GalleryScope oldWidget) =>
      oldWidget.selectedId != selectedId || oldWidget.visitedIds != visitedIds;
}

/// 组件库审核画布（**左侧分类导航 + 右侧内容区**）。
///
/// ## 为什么分分类（2026-09-25 用户要求）
/// 「做个分类导航，不然一下子全谱太卡、可读性太差」—— 66 个分区（大量玻璃件 + 常驻动画）
/// 同时构建/绘制确实卡。现在：
/// - **未访问过的分类连 Element 都不建**（不构建、不布局、不绘制）；
/// - **访问过的分类保活**（`Offstage` + `TickerMode(enabled: false)`：不绘制、动画停表），
///   切回来是瞬时的。
/// ⚠️ 不要改成「滚动销毁」式懒加载（`ListView.builder`）：样张里有 autofocus 组件（CreateSheet 等），
/// 滚动销毁焦点节点会触发 framework 断言
/// （`_ModalScopeState Focus Scope: Focused child does not have the same idea of its enclosing scope`），
/// 实测复现过 —— 保活就是为了避开它。
///
/// ## 语义树
/// 画布整体 `ExcludeSemantics`（2026-09-24 用户实报「启动不了了」后改）：全量构建会产生 **1685 个
/// 语义节点**，debug 下 `main.dart` 常开语义树（`ensureSemantics`），一次更新 1600+ 节点会让
/// Windows accessibility bridge 更新失败 → `Lost connection to device`。
/// 画布是开发审核面、无语义消费者 ⇒ 整体关掉。
///
/// ⚠️ **2026-10-02 订正**：本条原文把该日志的数字读成「1600+ 个节点」——**不成立**。
/// `Nodes left pending by the update: 1612` 里的 `1612` 是**单个未决语义节点的 id**，
/// 不是节点计数：引擎 `ax_tree.cc` 的 `ValidatePendingChangesComplete` 逐 id
/// `StringPrintf(" %d")` 拼接（数字有几个才是几个）⇒ 该日志是"**某一个**节点被挂空"，
/// 不是"总量超限"。它由**语义更新不自洽**导致，而不是由节点数量导致。
/// 所以整体 `ExcludeSemantics` 仍是开发面的合理选择（无语义消费者），
/// 但**不能再把它当成「节点太多触发的 bridge 限制」的证据**去指导别处取舍。
/// 详见 `Ayla/docs/report/flutter-语义树崩溃-traversalParentIdentifier-根因与修复-2026-10-02.md`。
///
/// ## ⚠️ 画布自带 Overlay（2026-10-02 用户实报「组件库打开会这样子报错」）
/// 画布在 `main.dart` 的 `MaterialApp.builder` 里与 Navigator（`child`）**同级**
/// ⇒ 拿不到 Navigator 的 `Overlay`，画布内一切 `Overlay.of` / Material `Tooltip` /
/// `OverlayPortal` 都在 build 期抛 `No Overlay widget found`（一次打开数百条）。
/// 本类的根构件因而是 [_GalleryHost]（**同帧**提供一个 `Overlay`）。
/// **默认分类（「基元 · 材质 · 排版」）就含 `AylaTooltip` 分区**（其标题前缀
/// `AylaTooltip` 在 `kGalleryCategories` 的 base 组里）⇒ 一打开画布即命中，
/// 无需切换分类。新增依赖 Overlay 的样张**不需要**各自再加包裹 —— 宿主已兜住。
///
/// ⚠️ 分区列表（`_GalleryColumn.children`）的缩进未随外层包装 +2 —— 项目不用 `dart format`，
/// 避免无关重排 diff。
class ComponentGallery extends StatefulWidget {
  const ComponentGallery({super.key});

  @override
  State<ComponentGallery> createState() => _ComponentGalleryState();
}

class _ComponentGalleryState extends State<ComponentGallery> {
  int _selected = 0;
  final Set<String> _visited = <String>{kGalleryCategories.first.id};

  String get _selectedId => _idAt(_selected);

  /// 导航最后一项目固定是兜底类（`kGalleryFallbackCategoryId`）。
  static String _idAt(int index) => index >= kGalleryCategories.length
      ? kGalleryFallbackCategoryId
      : kGalleryCategories[index].id;

  void _select(int index) {
    setState(() {
      _selected = index;
      _visited.add(_idAt(index));
    });
  }

  @override
  Widget build(BuildContext context) {
    // 画布：启用程序生成的示例图（媒体存储链路未落地；生产默认关闭）
    aylaEnableSampleMedia();
    final AylaTextStyles t = AylaTextStyles.of(context);
    return _GalleryHost(
      child: ExcludeSemantics(
      child: _GalleryScope(
        selectedId: _selectedId,
        visitedIds: _visited,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            _GalleryNav(selected: _selected, onSelect: _select),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(
                  AylaSpacing.sp6,
                  AylaSpacing.sp6,
                  AylaSpacing.sp6,
                  AylaSpacing.sp8,
                ),
                child: _GalleryColumn(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    const _GalleryHeader(),
                    const SizedBox(height: AylaSpacing.sp6),

                    // ---------- 手势动画（空白卡片模拟：淡入淡出 / 四方向滑入 / 右滑返回 / 切选项卡） ----------
                    _Section(
                      title: '手势动画（空白卡片模拟）—— 淡入淡出 · 左上右下四向滑入 · 右滑返回 · 切换选项卡',
                      source:
                          '常量取自 web：面板位移 ±20 / 300ms easeInOut（`panelVariants`）· '
                          '边缘返回 阈值 120px 或速度 ≥300px/s、退出与回弹各 200ms（`useEdgeSwipeBack`）· '
                          '横滑判定 净位移 ≥ 宽/3 优先、同向甩动 ≥300px/s 且 ≥40px 补充、方向锁让位（`resolveSwipeCommit`）· '
                          '跟手弹性 .8（`DRAG_ELASTIC`）· 纵向滚动优先由 Flutter 手势竞技场天然等价（机制差异已登记）',
                      child: const _MotionShowcaseDemo(),
                    ),
                    _Section(
                      title: 'AylaPanelSwap（hooks/useTabPanelMotion.ts 1–48 + hooks/usePanelSwapMotion.ts 1–43）',
                      source:
                          '两档**就地重播、不重挂子树**（web 原文：`No key, duplicate panel, or remount is introduced`）：'
                          'tab 档 = 消息区（`GroupChat.tsx:120–125`）300ms `opacity 0 / x +20` → `1 / 0`（easeInOut）；'
                          'swap 档 = 输入框（`:126`）600ms 双段「下移淡出 y +20 → 回位淡入」，每段 easeOut。'
                          '基线推进两条 hook **有意不同**：tab 档 not-ready 时**冻结基线**（`:28–31` 的 `if (!ready) return;` 在推进之前）'
                          '⇒ 之后补播，另有 `establishBaseline`（`:24–27`）跳过首次选中；swap 档基线**始终推进**（`:12–13`）⇒ 不补播。'
                          '定向测试 `panel_swap_test.dart` 5 条',
                      child: aylaPanelSwapSamples(), // 可交互：点键切换 identity 看两档重播
                    ),
                    _Section(
                      title: 'AylaPanelTransition / AylaConversationTransition / AylaFullScreenSwipeBack / AylaPrimaryNavPage（auroraquaMotion panel 段 + useSwipeCommit / useEdgeSwipeBack / ConversationTransition / FullScreenSwipeBack / PrimaryNavPage）',
                      source:
                          '四件的手势语义与常量见上一节样张；本节点名事实源：`panelVariants`（±20 / 300ms easeInOut）· '
                          '`AnimatePresence mode="wait"`（旧件先退再挂新件，退出期 inert + aria-hidden）· '
                          '`useEdgeSwipeBack`（120px / 300px/s / 200ms）· `resolveSwipeCommit`（size/3 优先 + 甩动补充 + 方向锁让位）· '
                          '`DRAG_ELASTIC .8`。空白卡片即上一节的七张样张。'
                          ' · **2026-09-28 收尾轮修既有 bug**：AylaPanelTransition 退场方向（原 `offset × v` 会「先瞬跳 ±20 再滑回」，'
                          'web `auroraquaMotion.ts:49` 的 exit 是 **center(0) → offset(exitEdge)(±20)**，现按 `±20 × (1 − v)`）；'
                          '并给 AylaConversationTransition 补 **panels 档**（web ConversationTransition.tsx:12/50；'
                          '`panels:false` = 空会话态 MessagesPage.tsx:190 ⇒ 宿主自己播 right→left 位移，reduced ⇒ 位移 0/时长 0）。'
                          '定向测试 `motion_gestures_test.dart` +5（共 18）',
                      child: const _MotionPiecesNote(),
                    ),
                    // ---------- 路由转场（PageTransition + AnimatePresence 等价宿主） ----------
                    _Section(
                      title: 'AylaPageTransition / AylaPageSwap（PageTransition.tsx 117 行 + AppShell.tsx:113）',
                      source:
                          '进入：opacity 0 + y ±20 + scale .95 → 500ms auroraquaEaseOut；退出：300ms auroraquaEaseInOut · '
                          '群页 / reduced-motion 只淡入 · panelOwned 整页不动 · 页面互换宿主保留旧页 300ms（sync 重叠转场）· '
                          'resolvePageKey 5 条归一规则（群页 / 宽屏群壳 / 宽屏私聊壳 / 直播间 / 开播台）',
                      child: const _PageSwapDemo(),
                    ),
                    // ---------- 瀑布流容器（帖子流 / 群内帖子 / 帖子中心 / 收藏 四处共用） ----------
                    _Section(
                      title: 'AylaMasonryGrid（useMasonryColumns.ts 146 行 + posts.css 607–694 / profile.css 458–545）',
                      source:
                          '单列（<1025）/ 双列（≥1025，页面常量 MASONRY_QUERY）· 新项插**最矮列** + 预估 320 交错 · '
                          '**分配一旦确定即锁定**（不因测量重排）· 分配记忆按 `memoryKey:columnCount` 隔离并**跨挂载恢复** · '
                          'posts 档 gap sp3；favorites 档单列 sp2 / 双列 sp3 + 上下 padding sp4 · footer 横跨两列',
                      child: const _MasonryDemo(),
                    ),
                    // ---------- 群资料卡（群信息页主卡） ----------
                    _Section(
                      title: 'AylaGroupInfoProfile（GroupInfo.tsx 461–520 + group.css 1382–1610 / 2235–2240）',
                      source:
                          '玻璃卡 · column 居中 · gap 窄 sp3 / 宽 sp2 · padding 窄 sp8 sp4 sp4 / 宽 sp6 sp4 sp4 · text-align center · '
                          '返回键 **absolute** top sp3 / left sp3（glass 底 + blur18）· 头像 窄 76 / 宽 92 + canManage 才出「更换群头像」'
                          '（12px / padding sp1 sp3 / min-h 36）· 选了新图 ⇒ hint「新头像将在保存后生效」+「保存群头像」· '
                          '展示态：群名 Display 24/600/1.25 · 群简介（label 12/700/ls .4 + 正文，**空 ⇒「暂无简介」**，max-w 420）· '
                          '「创建于 {日期}」（Utility 12；无值 ⇒「—」）· 统计三格（成员 / 已载入在线 / 子群；Utility 22/500 + 12，'
                          '**上下 1px rgba(157,191,230,.28) 分隔线**）· 动作行：分享群聊 + 「编辑群资料」· '
                          '编辑态：群名 input + 群简介 textarea(rows 3) + error + **两键等宽**（保存 / 取消）',
                      child: const _GroupInfoProfileDemo(),
                    ),
                    // ---------- 群信息**设置面**（B9 批次②：设置行 / 轨道开关 / 加入方式下拉 / 申请审批 / 成员搜索 / 子群展开） ----------
                    _Section(
                      title: 'AylaGroupInfoSettingRow / AylaGroupInfoSwitch / AylaGroupInfoSelect / AylaGroupJoinRequests / 成员搜索 / 子群展开（GroupInfo.tsx 531–624/709–718/754 + group.css 1678–1687/1796–2047/2109–2116）',
                      source:
                          '① 设置块（.group-info-settings）：column · padding **0 sp3** · radius-input · rgba(157,191,230,.1) 底；'
                          '行（.group-info-setting-row）= flex · center · space-between · gap sp3 · **min-h 44**；'
                          '**相邻行**才加 border-top 1px rgba(157,191,230,.22)（兄弟选择器 ⇒ 首行无上边线）；'
                          'label 14/w600/text-primary · value 13/secondary/nowrap'
                          '② 轨道开关（.group-info-switch）：整行（同 setting-row）· 轨道 **44×24** pill · --ice-300 底 + '
                          '**--glass-inset 顶沿内高光** · thumb 18×18 top3 left 3→23 · --surface 底 + 0 1px 3px rgba(70,91,146,.3) · '
                          '选中轨道转 --pink-500 · **禁用轨道 opacity .6** · :focus-visible = --focus-ring'
                          '③ 加入方式下拉（.group-info-select-*）：按钮 min-h 32 / padding 4 10 4 14 / pill / 1px rgba(157,191,230,.55) / '
                          '135deg 渐变（.22/.14 → hover .32/.2）/ indigo-700 13/w700 · chevron 14 rotate 180° · '
                          '**在 auroraqua 按钮组内**（200ms + hover 1.02 + active .98 + 扫光）· 禁用 opacity .6 · '
                          '菜单 = right 0 / top 100%+6 / min-w 148 / padding sp1 / radius 16 / glass-bg-strong + blur24 + --glass-shadow · '
                          '选项 min-h 36 / padding 0 sp3 / radius 8 / 13/w600 / hover rgba(157,191,230,.22) / 选中 grape-700 + check pink-500 · '
                          '非 public 一律显示「申请加入」，选中判定同 web（缺值按 application）· ⚠️ Flutter 走 root Overlay（溢出子级无命中测试）'
                          '④ 申请审批（.group-info-requests）：column · gap sp2 · 标题 13/w700「入群申请审批 · 待处理（N）」· '
                          '行 = flex · center · gap sp2 · padding sp2 sp3 · radius-input · rgba(157,191,230,.1) 底 · '
                          'name 13/w700 省略 + msg 12/secondary 省略（**message 空则不渲染**）· 两键 min-h 30 / padding 2 12 / '
                          'font-size 12 / **pill**（同意 primary / 拒绝 ghost，busy ⇒ 双双禁用）· 空态 13/secondary'
                          '⑤ 成员搜索框（GroupInfo.tsx:754）：就是 .field 档 + placeholder「搜索成员」+ aria-label「搜索群成员」，'
                          '**web 没有搜索图标**、没有额外包装'
                          '⑥ 子群展开（.group-info-expand-btn）：整宽 · min-h 36 · margin-top sp2 · 13px · ghost 档 · '
                          'aria-expanded · 文案「查看更多（N）」/「收起」（N = 总数 − 3，仅 length > 3 才渲染）',
                      child: const _GroupInfoSettingsDemo(),
                    ),
                    // ---------- 转让群主弹窗 + 角色标签（群信息域） ----------
                    _Section(
                      title: 'AylaTransferOwnerDialog（GroupInfo.tsx 904–1010 + app.css 3894–4005）',
                      source:
                          '遮罩 rgba(70,91,146,.25)（点遮罩关，busy 不关）· 卡 min(480,100%) / max-h 80vh / padding sp4 + 玻璃 · '
                          '标题 Display 18/600 + 关闭键 40 · 搜索框左内距 34px（图标 absolute left sp3）· 列表 max-h 260 / gap sp2 · '
                          '行：头像 36 + 名字 14/600 省略 + **非 member 才出角色标签**（aria-pressed / aria-label 转让给 X）· '
                          '已选提示「已选择：X」· 错误行 role=alert · 动作 ghost 取消 + primary「转让中… / 确认转让」（无选中或 busy ⇒ disabled）· '
                          '⚠️ `.group-transfer-empty` 是死声明（tsx 零使用），空态实际走 `.search-empty`',
                      child: const _TransferDialogDemo(),
                    ),
                    _Section(
                      title: 'AylaGroupRoleChip（group.css 1734–1750 + GroupInfo.tsx 52–56）',
                      source:
                          'padding 1px 8px / pill / Display 11 · owner = --sakura-300 底 + --grape-700 字 · '
                          'admin = --ice-300 底 + --indigo-700 字 · **member ⇒ 不渲染**（web 只在 role !== "member" 时出标签）',
                      child: const _RoleChipDemo(),
                    ),
                    // ---------- 群内场景统一标题栏 + 占位壳（B10：§7.5 pages 域第三批 A 类） ----------
                    _Section(
                      title:
                          'AylaGroupSceneHead / AylaGroupScenePlaceholder（group.css 358–475 + auroraqua.css 336/419/621/637）',
                      source:
                          '头部（语音/帖子/桌游共用 3 处）：sticky top 0 · z-index 10 · min-height **72** · padding sp4 · '
                          '--glass-bg + blur24 sat1.4 + 1px 亮边 + radius 16 + --glass-shadow-compact · copy flex 1 · '
                          '标题 Display 18/w500/1.25 · 描述 14/1.45/secondary **单行省略** · 尾键 flex none · '
                          '≤480 align-items flex-start · 入场 auroraqua-panel-from-top（0 −20px → 0，宽窄两段同帧）· '
                          '**sticky 用自建 paint 阶段定位**（同滚动内容里自然占位 + 按几何平移；机制差异见件头注释）· '
                          '占位壳：height 100% · column · center · gap sp3 · padding sp6 · 单键直出 / 多键 actions 行（gap sp2 + flex-wrap）· '
                          '文案逐字取自 GroupVoice/Posts/Games/Live/Info 的调用点',
                      child: aylaGroupSceneSamples(),
                    ),
                    const SizedBox(height: AylaSpacing.sp6),
                    // ---------- 群聊子群切换条（B10；19 号 §七 7.1 曾误判「已覆盖」的真缺口） ----------
                    _Section(
                      title:
                          'AylaGroupChatSubgroupBar（group.css 152–331 + GroupChat.tsx 334–407）',
                      source:
                          '折叠键 48×32（left −8 于 switcher ⇒ 4）· 收起态 = 36×18 上半圆把手（--glass-bg-strong，hover '
                          'rgba(157,191,230,.35)）· 展开态 = 32 正圆（rgba(255,250,251,.6)，hover .18）+ IconChevronUp/Down 14 · '
                          'motion y 0/−4 · aria-expanded + aria-label「展开/收起子群选项卡」· title「展开子群/收起子群」· '
                          '选项卡行 role=tablist「子群切换」· min-height 40 · gap sp2 · 横向滚动 · tab 高 32 / padding 0 sp3 / pill / '
                          'rgba(255,250,251,.6)，hover .18，选中底**交给容器级胶囊**（复用 AylaNavHighlightList，auroraqua 190–197）· '
                          '名字 max-w 120 省略 · 未读徽标 pink-500（>99 ⇒ 99+）· 禁言 chip ice-300/indigo-700 10px · '
                          'hasMore ⇒ 「加载更多子群」/「加载中…」（不参与选中）· 展开/收起 300ms disclosure（reduced ⇒ 0）',
                      child: aylaGroupChatSubgroupBarSamples(),
                    ),
                    const SizedBox(height: AylaSpacing.sp6),
                    // ---------- 桌游网格 + 加载骨架（一级 games-grid 与群内共用） ----------
                    _Section(
                      title: 'AylaGamesGrid / AylaGamesGridSkeleton（GamesHubPage.tsx 184–216 + boardgame.css 232–275）',
                      source:
                          'CSS grid repeat(2, 1fr) → ≥769 变 repeat(4, 1fr)（群内恒 2 列）· gap sp3 / padding sp3 sp4 · '
                          '骨架：2 张 120 高圆角 12 的骨架卡 + 跨列文案「正在加载桌游室…」（aria-busy）· '
                          'Flutter 无 grid ⇒ LayoutBuilder 算等宽列 + Wrap（与 1fr 等价，机制差异已登记）',
                      child: const _GamesGridDemo(),
                    ),
                    _Section(
                      title: 'AylaFavoriteItem（FavoritesPage.tsx 95 + profile.css 474–487 / 539–541）',
                      source:
                          '收藏列表项容器：flex · align-items center · gap sp3 · padding sp3（**≥769 ⇒ sp4**）· '
                          'radius-input · --glass-bg + 1px 边 + --glass-filter + **--glass-shadow-compact** · '
                          '过渡 box-shadow / border-color / translate（--auroraqua-duration）· '
                          '⚠️ `.favorite-item-title/-type/-body` 在 tsx **零使用 ⇒ 死声明**（不复刻）；'
                          '`-main` 只用于「内容不可用」按钮（由结果卡自身承担）',
                      child: const _FavoriteItemDemo(),
                    ),
                    // ---------- 目录页族（6 个目录页共用的 A 类跨页复用件：三件套 + 侧栏标题 + 装饰图标 + 返回键 + 页面状态壳） ----------
                    _Section(
                      title: 'AylaDirectoryPage / AylaDirectoryContent / AylaDirectorySidebarHeader / AylaDirectoryDecorIcon / AylaDirectoryBackButton / AylaPageState'
                          '（directory-filters.css 2–257 + home.css 620–629 + shell.css 595–629 + 六个目录页 TSX）',
                      source:
                          '① 三件套：.directory-page（height 100% / flex column / overflow hidden / padding sp3 sp3 0，≤768 ⇒ 0）· '
                          '.directory-body（flex 1 1 0 / row + gap sp3 / min-h 0，≤768 ⇒ column + gap 0）· '
                          '.directory-content（flex 1 1 0 / overflow-y auto / overscroll-y contain / scrollbar-gutter stable / padding sp2 sp2 sp6；'
                          '≥769 ⇒ margin −sp3 −sp3 0 + padding sp3 (sp2+sp3) sp6 的 12px 阴影绘制带，≤768 ⇒ padding sp2 sp4 68+safe）'
                          '② 切分类以 key={scope} 重挂载 ⇒ directory-content-in 300ms var(--auroraqua-ease)（opacity 0 + translateY 12 → 1/0；'
                          'reduced-motion ⇒ 无动画）· 内容区 role=tabpanel + aria-labelledby + tabIndex=0 · '
                          '③ 侧栏标题：kicker Display 10/w600/ls .14em/pink-500/.75 + 标题 Display 17/w700 + 统计 Utility 12（窄屏 display:none）· '
                          '④ 装饰图标：flex none / align-self center / margin 6 auto 2 / pink-500 / opacity .42 / rotate −8° / pointer-events none（窄屏 display:none）· '
                          '⑤ 返回键 = .icon-btn-40（40×40 玻璃 + IconBack 20 + aria-label 返回；宽屏 leading 槽位）· '
                          '⑥ AylaPageState = .home-state（column / align center / gap sp4 / padding sp12 sp6）+ .placeholder-title（Display 28/600）+ '
                          '.placeholder-desc（14/secondary）；收藏页覆盖 padding-top sp3。'
                          '机制差异：负 margin 用 OverflowBox + Transform.translate 表达（溢出 12px 不参与命中）· scrollbar-gutter 无等价',
                      child: const _DirectoryPageDemo(),
                    ),
                    // ---------- 个人主页域（资料卡族 + 收藏骨架） ----------
                    _Section(
                      title: 'AylaProfileCard / AylaProfileIdentity / AylaProfileAvatarActions（ProfilePage.tsx 154–180 + app.css 241–248/2657–2695 + profile.css 14–16/44–52/142–171/584–591/623–625）',
                      source:
                          '容器 = `.solid-card`（**名字叫 solid，实为玻璃卡**：--glass-bg + filter + shadow + 1px 边 + radius 16）'
                          '+ `.profile-card` padding sp8 / gap sp6（≥769 双栏档：sp4 / sp4）· identity gap sp4（返回键 40 + 头像 64 + '
                          '昵称 Display 28/600/ls −.3 + `@用户名` Utility 13/ls .3）· 分享键 `margin-left: auto` 推右 · '
                          'avatar-actions：等宽按钮（12px / padding sp1 sp2 / min-h 28）+ hint(12/secondary)/error(12/destructive)，左内距 48（与头像左缘对齐）',
                      child: const _ProfileCardDemo(),
                    ),
                    // ---------- 个人主页**编辑面**（B9 批次①：状态胶囊 / 开关行 / 表单装配） ----------
                    _Section(
                      title: 'AylaStatusChips / AylaProfileSwitch / AylaProfileForm（ProfilePage.tsx 212–305 + app.css 2696–2749 + profile.css 47–51/377–440/593–611 + auth.css 79–87）',
                      source:
                          '① 状态胶囊（.status-chips/.status-chip）：flex-wrap · gap sp2 · 胶囊 padding sp2 sp4 / pill / '
                          'Display 11 / w500 / ls .8 · 未选中 = ice-300 @16% 底 + indigo-700 字（**profile.css 598–611 覆写 app.css 的粉底**）· '
                          '选中 = sakura-300 + grape-700 + --glow-shadow（窄屏降 30%）· hover = brightness(1.04) 整颗含文字 · '
                          '**不在 auroraqua 按钮组** ⇒ 无 hover 1.02 / active .98 / 扫光 · role=radiogroup/radio ⇒ Semantics '
                          'checked + inMutuallyExclusiveGroup · focus ring = --focus-ring(glow-500) / offset 2'
                          '② 开关行（.profile-show-content-row/.profile-switch）：row · center · space-between · gap sp3 · '
                          'label 14/w700 + small 12/w400 secondary · 开关 48×28 pill + 1px --glass-border + --glass-bg-strong'
                          '（**无 backdrop-filter**）· knob 20×20 top3 left 3→23 · off = ice-300 钮 + 玻璃底 · on = grape-700 钮 + '
                          'sakura-300 底 + --glow-shadow · web 是 label 转发点击 ⇒ 整行可点 · :focus-visible = --focus-ring'
                          '③ 表单装配（.profile-form）：column · gap sp4（≥769 单栏 sp3 / 双栏侧栏 sp4）· 行 = 14/w700/ls .2 + gap sp1 · '
                          '昵称 input / 签名 textarea(rows 3, resize none) 走 .field（文字**继承行样式 14/w700**，非 .field 自声明）· '
                          '错误行 = .auth-error（13 / destructive / rgba(214,77,110,.1) 底 + .35 边 / role=alert）· '
                          '动作行 = flex-end · gap sp3：「已保存」13/--success（**仅 saved && !dirty**）+ primary'
                          '「保存修改 / 保存中…」（disabled = saving || !dirty）+ destructive「退出登录」'
                          '（min-h 36 / padding 0 sp4 / IconLogout 15）',
                      child: const _ProfileEditDemo(),
                    ),
                    _Section(
                      title: 'AylaFavoritesSkeleton（FavoritesPage.tsx 268–271 + profile.css 452–456）',
                      source: 'padding sp4 · 两条骨架条高 64（首条下方留 8）· role=status aria-label「正在加载收藏」',
                      child: const _FavoritesSkeletonDemo(),
                    ),
                    // ---------- 搜索域三件（SearchPage 自有件） ----------
                    _Section(
                      title: 'AylaSearchHistoryChips（search.css 11–30 + SearchPage.tsx 362–372）',
                      source:
                          '.search-history flex-wrap · gap sp2 · padding sp3 sp4 sp3 · .search-chip padding 4×12 / pill / '
                          '--ice-100 底 / 13px · **chip 在 auroraqua 按钮组内**（hover 1.02 / active .98）· .search-clear 13px / --slate-500（不在组内）· '
                          '**有查询词或历史为空 ⇒ 整块不渲染**',
                      child: const _SearchHistoryDemo(),
                    ),
                    _Section(
                      title: 'AylaSearchResultGroup（ResultGroup：SearchPage.tsx 494–521 + search.css 68–105）',
                      source:
                          '**count === 0 ⇒ 整组不渲染** · 标题 Display 13 / ls .8 / uppercase / secondary（单类视图隐藏）· '
                          '组内页脚紧凑化 min-height 0 / padding sp2 0 0 · 页脚三态：加载中… / 重试（带 error 文案）/ 查看更多',
                      child: const _SearchGroupDemo(),
                    ),
                    _Section(
                      title: 'AylaSearchUserRow（search.css 107–176 + SearchPage.tsx 391–408）',
                      source:
                          '.search-row flex / gap sp3 / padding sp2 sp3 / radius 12 / glass 底 + 1px 边 + blur24 · '
                          '头像 36（点头像=去主页，aria「查看 X 的个人主页」）· 标题 14/600 单行省略 · 副行 = signature（有才渲染，'
                          '`.search-row-sub` **CSS 无定义 ⇒ 照实继承**）· action 槽位 grape-700 / 13（用户行未用）',
                      child: const _SearchRowDemo(),
                    ),
                    // ---------- AylaTooltip（全库统一项：web 原生 title 提示的平台等价物） ----------
                    _Section(
                      title: 'AylaTooltip（web `title=` 28 处；提示气泡由浏览器/OS 绘制，无 CSS 可移植）',
                      source:
                          'Material `Tooltip`：迟滞 500ms（浏览器 title 量级）· 展示 1.5s · 样式取 Material 默认'
                          '（web 那份是 OS 绘制 ⇒ 不凭印象设计）· `message` 为 null/空 ⇒ 完全透传（等价 `title={undefined}`）',
                      child: _Row(
                        children: <Widget>[
                          _Slot(
                            label: '包住图标钮（悬停 0.5s 弹出）',
                            child: AylaTooltip(
                              message: '分享',
                              child: AylaIconButton(
                                icon: AylaIcon(aylaIconByName('iconShare')!),
                                semanticLabel: '分享',
                                onPressed: () {},
                              ),
                            ),
                          ),
                          _Slot(
                            label: '包住溢出长文本（提示读全文）',
                            width: 220,
                            child: AylaTooltip(
                              message: '被省略号截断的长文本，完整内容由提示给出',
                              child: Text(
                                '被省略号截断的长文本，完整内容由提示给出',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: t.body,
                              ),
                            ),
                          ),
                          _Slot(
                            label: 'message 为空 ⇒ 不提示（透传）',
                            child: AylaTooltip(
                              message: '',
                              child: AylaIconButton(
                                icon: AylaIcon(aylaIconByName('iconClose')!),
                                semanticLabel: '关闭',
                                onPressed: () {},
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),

            // ---------- AylaGlassButton ----------
            _Section(
              title: 'AylaGlassButton（app.css .btn 21–67 / auroraqua.css 54–166）',
              source:
                  '.btn：gap 8 · min-h 40 · padding 0 24 · radius 12 · 14px/700/ls .2 · 200ms',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  // 登录页主 CTA：.auth-submit（width 100% / 44 高 / btn-glow）
                  _Slot(
                    label: '登录主 CTA（.auth-submit 44 · btn-glow）',
                    width: 374,
                    child: AylaGlassButton(
                      label: '登录',
                      variant: AylaGlassButtonVariant.glow,
                      minHeight: 44,
                      expand: true,
                      onPressed: () {},
                    ),
                  ),
                  const SizedBox(height: AylaSpacing.sp6),
                  _Row(
                    children: <Widget>[
                      _Slot(
                        label: 'pending（disabled .55）',
                        width: 220,
                        child: AylaGlassButton(
                          label: '登录中…',
                          variant: AylaGlassButtonVariant.glow,
                          minHeight: 44,
                          expand: true,
                          onPressed: null,
                        ),
                      ),
                      _Slot(
                        label: 'ghost（.auth-switch-link\nmin-w 72 / 44）',
                        child: AylaGlassButton(
                          label: '注册',
                          variant: AylaGlassButtonVariant.ghost,
                          minHeight: 44,
                          minWidth: 72,
                          padding: const EdgeInsets.symmetric(horizontal: 16),
                          onPressed: () {},
                        ),
                      ),
                      _Slot(
                        label: 'primary（40 高）',
                        child: AylaGlassButton(label: '登录', onPressed: () {}),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: AylaSpacing.sp6),

            // ---------- AylaGlassCard ----------
            _Section(
              title: 'AylaGlassCard（app.css .glass-card 230–248）',
              source:
                  '.glass-bg .55 · blur 24 saturate 1.4 · 1px 白边 .65 · 16px 圆角 · 8/32 阴影 · 顶沿内高光',
              child: _Row(
                children: <Widget>[
                  _Slot(
                    label: '静态卡（padding 16）',
                    width: 300,
                    child: AylaGlassCard(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: <Widget>[
                          Text('静态玻璃卡', style: t.cardTitle),
                          const SizedBox(height: AylaSpacing.sp2),
                          Text(
                            '--glass-bg .55 / blur 24 / 16 圆角 / 8·32 阴影',
                            style: t.caption.copyWith(
                              color: AylaColors.textSecondary,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  _Slot(
                    label: '可交互（hover 上浮 2px）',
                    width: 300,
                    child: AylaGlassCard(
                      interactive: true,
                      onTap: () {},
                      child: Text('可交互玻璃卡', style: t.cardTitle),
                    ),
                  ),
                  _Slot(
                    label: 'strong 弹层底（.78）',
                    width: 300,
                    child: AylaGlassCard(
                      strong: true,
                      radius: AylaRadii.rPanel,
                      shadow: AylaShadows.modal,
                      child: Text('strong 弹层卡', style: t.cardTitle),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: AylaSpacing.sp6),

            // ---------- AylaAuroraBackground（全局五层流体极光背景） ----------
            _Section(
              title:
                  'AylaAuroraBackground（base.css 50–314 五层流体极光背景 + tokens.css 28–63）',
              source:
                  '① html 静态兜底 = --bg-aurora 九层 radial（tokens.css 28–36，半径按 farthest-corner 动态换算）· '
                  '② html::before 渐变流层 = 150vmax 正方形居中 + 96px 网格 + 九层，blur(40px)，'
                  'fluid-gradient-spin 20s ease-in-out -8s infinite（base.css 57–80）· '
                  '③ html::after 湍流层 = feTurbulence 480px 平铺 + blur(60px) + opacity .08，'
                  'fluid-turbulence-drift 15s ease-in-out -5s infinite alternate（82–95）· '
                  '④⑤ body::before/after 双光斑 = 40vw 圆 + blur(40px) + radial 70% 截止，'
                  'fluid-blob-drift-a/b 10s ease-in-out infinite alternate（99–128）· '
                  '窄屏 ≤768：光斑 80vw/70vw 上下分区（alpha .7）+ 渐变 28s / 湍流 21s（211–246）· '
                  'prefers-reduced-motion ⇒ 四层隐藏、回退静态九层（305–314）\n'
                  '★ 2026-09-27 逐像素对账（两侧同按设备像素出图）：宽屏 4 个相位平均绝对差 0.46–0.63 / '
                  '窄屏 0.68–1.06 / reduced-motion 0.67（255 制）。定位到的三处偏差（流层曾写成 165vmax · '
                  '网格常量段与 0deg 相位 · 湍流层未预乘）与对账方法见 lib/theme/aurora_background.dart 头部。\n'
                  '⚠️ 「层分解」四格是小舞台（360×216），只用来判断「哪一层在不在 / 有没有色」；'
                  '观感一律看 1440×810 的那两档（小舞台的 vmax/blur 比例与真机不同）。',
              child: aylaAuroraBackgroundSamples(),
            ),
            const SizedBox(height: AylaSpacing.sp6),

            // ---------- AylaGlassQuality（毛玻璃质量档，性能旋钮） ----------
            _Section(
              title:
                  'AylaGlassQuality（性能旋钮：真玻璃 / 预模糊 / 实底；13 号 §8.17）',
              source:
                  '默认 realBackdrop = 逐帧 backdrop-filter（与 web 逐像素等价）· '
                  'preblurred = 按屏幕位置采样背景低频快照（无滤镜）· '
                  'opaque = .92 不透明底（web 的 @supports 降级路径）· '
                  '切换只改「背后内容层」，材质层与几何一行不动（默认档逐像素未变）',
              child: const _GlassQualityStage(),
            ),
            const SizedBox(height: AylaSpacing.sp6),

            // ---------- AylaGlassInput ----------
            // 尺寸口径:登录认证卡内宽 440 − 卡内沿 32×2 = 374（.auth-submit
            // 满宽字段与它同宽,故样张统一按 374 呈现,不缩成窄列）。
            _Section(
              title: 'AylaGlassInput（app.css .field 70–88 / auroraqua.css 502–523）',
              source:
                  'padding 12×16 · radius 12 · --glass-bg + 亮边 · focus 辉光边 · placeholder slate-500',
              child: SizedBox(
                width: 374,
                child: _Rows(
                  children: <Widget>[
                    _InputSample(
                      label: '常态（认证卡内：indigo .3 描边）',
                      onGlassBorder: true,
                    ),
                    _InputSample(
                      label: 'focus（#F796FF 边 + 辉光）',
                      autofocus: true,
                      onGlassBorder: true,
                    ),
                    _InputSample(
                      label: '密码类型',
                      obscure: true,
                      text: '12345678',
                      onGlassBorder: true,
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: AylaSpacing.sp6),

            // ---------- AylaAvatarHalo ----------
            _Section(
              title:
                  'AylaAvatarHalo（app.css .avatar-halo 312–380 / base.css halo-breathe）',
              source: '2.5px 锥形渐变环 conic 210° · 离线 --ice-100 · 爱莉 3.2s 呼吸辉光',
              child: _Row(
                children: <Widget>[
                  _Slot(
                    label: '40 爱莉在线（呼吸 + 辉光）',
                    child: const AylaAvatarHalo(
                      label: '爱莉',
                      size: 40,
                      online: true,
                      core: AylaAvatarCore.elysia,
                    ),
                  ),
                  _Slot(
                    label: '40 在线',
                    child: const AylaAvatarHalo(
                      label: '在线',
                      size: 40,
                      online: true,
                    ),
                  ),
                  _Slot(
                    label: '40 离线',
                    child: const AylaAvatarHalo(label: '离线', size: 40),
                  ),
                  _Slot(
                    label: '36 在线（窄屏顶栏）',
                    child: const AylaAvatarHalo(
                      label: '在线',
                      size: 36,
                      online: true,
                    ),
                  ),
                  _Slot(
                    label: '24 在线（群卡底行）',
                    child: const AylaAvatarHalo(label: '群', size: 24, online: true),
                  ),
                ],
              ),
            ),
            const SizedBox(height: AylaSpacing.sp6),

            // ---------- AylaTabBadge（三档规格，2026-09-20 审查 R8 合并） ----------
            _Section(
              title:
                  'AylaTabBadge（shell.css .tab-badge 579–593 · home.css .group-badge 302–317 · messages.css .messages-tab-badge 43–55）',
              source:
                  'tab：min 16 / padding 0 4 / Fredoka 11 w500 / 绝对 top -4 right -12 · '
                  'groupBadge：16 / Fredoka 11 w400 / 行内 · messages：18 / Space Grotesk 11 / 行内 + glow · >99 → 99+',
              child: _Row(
                children: <Widget>[
                  _Slot(label: 'tab：1', child: _BadgeHost(count: 1)),
                  _Slot(label: 'tab：12', child: _BadgeHost(count: 12)),
                  _Slot(label: 'tab：150 → 99+', child: _BadgeHost(count: 150)),
                  _Slot(
                    label: 'groupBadge（.group-badge-unread）',
                    child: const AylaTabBadge(
                      count: 8,
                      metrics: AylaTabBadgeMetrics.groupBadge,
                      placement: AylaTabBadgePlacement.inline,
                    ),
                  ),
                  _Slot(
                    label: 'messages（.messages-tab-badge + glow）',
                    child: const AylaTabBadge(
                      count: 120,
                      metrics: AylaTabBadgeMetrics.messages,
                      placement: AylaTabBadgePlacement.inline,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: AylaSpacing.sp6),

            // ---------- 帖子卡族（B5） ----------
            _Section(
              title:
                  'AylaPostCard / AylaPostVideoCover（PostCard.tsx + posts.css 9–217 + typed-result-cards.css 5,7）',
              source:
                  'glass-bg + 16 圆角 + overflow hidden · hover（父级）translate -2px + shadow-hover + brightness 1.01 · active scale .99 · 正文 15/1.55 三行折叠 · 1 图 contain max-h 240 / 多图 3 列 gap 4 · 底排：查看帖子(12 secondary) + 统计(Space Grotesk 12) + 收藏(compact) + 分享(纯圆钮 40) · 排列：>1025 两列瀑布（轨道 1200 / 列距 12）/ <=1024 单列',
              child: aylaPostCardSamples(),
            ),
            const SizedBox(height: AylaSpacing.sp6),

            // ---------- 帖子域页面内联件（第 3 批；19 号 §7.5 range B 的 B 类） ----------
            _Section(
              title:
                  'AylaPostsSkeleton / AylaMyPostsHead（posts.css 598–605 / 628–675 + PostsHubPage.tsx 317–322 / MyPostsPage.tsx 180–186）',
              source:
                  '骨架：base padding sp3 sp4 → ≥1025 sp4 sp6 + **grid 两列 column-gap sp3**；'
                  '≥769 max-width 680 居中、≥1025 1200 居中（hub 页被 directory-filters.css 171–180 归零 ⇒ centered:false）；'
                  '内联几何：hub 三根 h120（前两根间距 12）、我的两根 h120 无间距 · '
                  '页头：flex/none + gap sp3 + padding sp2 sp4 + 1px 玻璃底边；≥769 680 居中、≥1025 1200 + 左右 sp6；'
                  '返回键 IconBack **20**（详情页是 22，勿统一）',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: aylaPostChromeSamples(),
              ),
            ),
            const SizedBox(height: AylaSpacing.sp6),

            _Section(
              title:
                  'AylaPostDetailChrome / AylaPostDetailSkeleton / AylaPostDetailEmpty（posts.css 701–780 / 1111–1136 + PostDetailPage.tsx 399–438）',
              source:
                  '壳：.post-detail 列布局（height100/overflow hidden/relative）+ 玻璃头（gap sp3 + padding sp3 sp4 + blur18 sat1.4 + 1px 底边；'
                  '≥769 覆写 auroraqua 402–409 = margin 12 + 四边亮边 + radius 16 + compact 阴影 + blur24 sat1.4）+ '
                  '滚动区 padding sp3 sp4 gap sp3 + 底部输入区（窄屏整宽页脚 / ≥769 浮动玻璃卡 margin 12 padding sp2）'
                  '· 编辑态三个 background 层 visibility:hidden 等价物（保留状态与滚动位置）· 头/输入区入场 ±20 / 300ms；'
                  '骨架：max-width 680+2×sp4 居中 + padding sp3 sp4 + gap sp3（40 圆形 / 96×16 / 64×12 · 两条正文 14 · 媒体 120 · 评论块 4 条）；'
                  '空态（2026-09-28 用户裁决「修」）：.post-detail-state = 顶栏（返回 + 帖子）+ 居中列'
                  '（padding sp12 sp6 + gap sp4 取自 .home-state home.css:622–629；整页居中同 .home-wide-empty home.css:673–682）'
                  '+ 文案（error ?? 帖子不存在）+ ghost 返回',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: aylaPostDetailChromeSamples(),
              ),
            ),
            const SizedBox(height: AylaSpacing.sp6),

            _Section(
              title:
                  'AylaPostEditFullscreen（PostDetailPage.tsx 497–599 + posts.css 806–919 / 268–414）',
              source:
                  'absolute 面板（inset 0 / z50 / 列布局 / 入场 posts.css 812 + keyframes 815–824、reduced 916–918）· '
                  '头部：取消 icon-btn-40（IconBack 22）+ 标题 Display 18/w600 + btn-primary「重新发布 / 保存中…」（min-width 72）· '
                  '正文区：padding sp4 + gap sp3 + max-width 680 居中；标题 input.field（maxLength 128）· 正文 textarea min-height 120 · '
                  '媒体块「图片/视频 n/9」+ 添加键 + 空格壳/缩略图/移除 ×（禁用档随 saving/uploading）· 可见性选择器注入 · '
                  '两条错误行 role=alert · 保存禁用 = saving || uploading || 正文空（**空标题可提交**，tsx 507）',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: aylaPostEditFullscreenSamples(),
              ),
            ),
            const SizedBox(height: AylaSpacing.sp6),

            // ---------- 发帖编辑器（B5） ----------
            _Section(
              title:
                  'AylaPostEditor（PostEditor.tsx + posts.css 219–418 + auroraqua.css 105–166）',
              source:
                  '三形态：常规 / 群内 collapsible 收起 / 展开 · padding sp3（collapsible sp2 sp3）· 展开 max-height min(90vh,1000px) · 收起钮 32 圆 · 标题 min-h 40 · 正文 展开 rows4/min-h 64、收起 单行 40 · 媒体块 128 方角（web --radius-md 未定义）、移除钮 28 圆 · 进度条 4px pill pink-500 · 图片/视频钮 glass 亮边 + hover glow（glowHover）· 可见性复用 AylaVisibilitySelector（群内 lockGroup）',
              child: aylaPostEditorSamples(),
            ),
            const SizedBox(height: AylaSpacing.sp6),

            // ---------- 主页页头（第 3 批；19 号 §7.5 range B：home-toolbar/home-title） ----------
            _Section(
              title: 'AylaHomeToolbar（home.css 18–30 + HomePage.tsx 163–166）',
              source:
                  'padding sp3 sp4 + 两端对齐 · 左标题 Fredoka 28 / w600 / --text-primary（.home-title）· '
                  '右布局开关（AylaLayoutSwitch，aria-label「主页布局」）· 两档样张：卡片 / 列表',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: aylaHomeToolbarSamples(),
              ),
            ),
            const SizedBox(height: AylaSpacing.sp6),

            // ---------- 群内帖子底部输入容器（B10：scrim + 两档材质 + 展开贴底） ----------
            _Section(
              title:
                  'AylaGroupPostsComposer（posts.css 933–951/1011–1108 + auroraqua.css 347–368）',
              source:
                  '壳件（编辑器复用 AylaPostEditor 的 compact/collapsible + composerShell 档）：'
                  '窄屏 padding sp2 sp3 sp3 / 仅上边框 / 方角 / blur18 sat1.4 / 无外阴影 · '
                  '≥769 被 auroraqua 347–359 覆写为**浮动玻璃卡**（margin 12 + margin-left 0 / padding 8 / radius 16 / '
                  '四边亮边 / --glass-shadow / blur24 sat1.4）· 入场 auroraqua-panel-from-bottom 300ms，'
                  '展开档换 group-posts-editor-rise 250ms · 遮罩 z45 rgba(70,91,146,.25) 淡入 200ms、点击收起 · '
                  '展开态 absolute 贴底 + max-height 100%（≥769 calc(100% − 2×12)）+ overflow-y auto · '
                  '字段被覆写为 padding sp2 sp3 + line-height 22（收起态正文 ⇒ 40 高）',
              child: aylaGroupPostsComposerSamples(),
            ),
            const SizedBox(height: AylaSpacing.sp6),

            // ---------- 评论族（B5） ----------
            _Section(
              title:
                  'AylaCommentList / AylaCommentComposer（CommentList.tsx + CommentComposer.tsx + posts.css 420–583）',
              source:
                  '评论项：padding sp3 sp4 + 底部 1px 亮边 · 头像 32 · 昵称 14/700 · 时间 utility 11（zh-CN）· 回复提示 12 · 正文 14 · 操作行 12/600（回复 / 作者可删除，删除色 --destructive）· 图片 2 列 gap sp1 max-w 280（单图 200）、4:3 cover、方角（web --radius-md 未定义）· 输入：padding sp3 sp4 + 上边框 · 行 gap sp3 align-end · 工具钮 40（AylaToolButton，12 圆角）· 待发图 64px + 18px × · 底部滑入 250ms',
              child: aylaCommentSamples(),
            ),
            const SizedBox(height: AylaSpacing.sp6),

            // ---------- 查看器（B5） ----------
            _Section(
              title:
                  'AylaImageViewer（ImageViewer.tsx + app.css 1459–1836 + auroraqua.css 55–94）',
              source:
                  '遮罩 --overlay-dim-strong + blur(8)（无 saturate）· 入场 opacity 180ms --ease-out · 关闭钮 40 圆 · 舞台 max min(92vw,1200) / 82vh · 图片 contain + radius-input + --surface + --card-shadow · 导航 44 圆（blur12 saturate1.4，禁用 0.35）· 操作条 pill 玻璃（blur18）+ 计数（Space Grotesk 12/ls.5）+ 保存（IconDownload 16）· 失败提示 bottom 76 · 横滑阈值 1/3 或 300px/s+40px（useSwipeCommit）· 条目 enter x=±40% 250ms · 样张走 embedded（嵌入画布不做 backdrop 模糊，避免糊宿主页面）',
              child: aylaImageViewerSamples(),
            ),
            const SizedBox(height: AylaSpacing.sp6),

            // ---------- 分享族（B5） ----------
            _Section(
              title:
                  'AylaShareSheet / AylaShareButton（ShareSheet.tsx + ShareButton.tsx + share.css 1–275）',
              source:
                  '遮罩 --overlay-dim + padding 24 居中；窄屏 60dvh 贴底（上沿 radius-panel、去左右下边框、safe-area）· 卡 min(480,100%) + max-h min(80vh,720) + glass-bg-strong + blur24 sat1.4 + modal 阴影 + 宽屏入场 opacity/scale.96/y12 250ms ease-out · head sp4 + 底边 + 关闭 40 圆钮 · 预览条 8×12 + 28 圆 135deg ice→sakura + 14/600 单行省略 · 选项卡 2 列 gap8 / 40 高 / radius 10，选中 --nav-active-bg + --glass-shadow-compact（无边框、无扫光，只有文字色 200ms 过渡）· 行 min-h 48 / radius 12 / hover rgba(157,191,230,.18) / active .98 / 禁用 .6 · 子群缩进 52 + 8px ice-500 点 +「默认」sakura 胶囊 · 未读 18/pink-500/#fff 字 99+ 封顶 · 入口钮 = icon-btn-40 pill（无扫光）',
              child: aylaShareSamples(),
            ),
            const SizedBox(height: AylaSpacing.sp6),

            // ---------- Shell 底栏（2026-09-20） ----------
            _Section(
              title:
                  'AylaBottomTabs（layout/BottomTabs.tsx 1–91 + shell.css 77–162）',
              source:
                  '玻璃 64px + safe-area · **上沿 radius-panel 20 / 下方角**（auroraqua 252）+ 顶部 1px 边 · blur18 saturate1.4 · 五等分（主页居中凸起：48 圆盘上浮 8 + 选中辉光）· 按钮 margin 4/2（auroraqua 254，胶囊随之内缩）· **容器级共享胶囊跨槽迁移 300ms**[0,0,.58,1] + hover 扫光 · 图标/文字 150ms 过渡 · 导航组 active .98、hover 不放大 · **F1 阶段不渲染红点**（badges 恒空）',
              child: aylaBottomTabsSamples(), // 可交互：点 tab 看胶囊跨槽迁移
            ),
            const SizedBox(height: AylaSpacing.sp6),

            // ---------- Shell 顶栏（2026-09-20） ----------
            _Section(
              title:
                  'AylaGroupTopTabs（components/group/GroupTopTabs.tsx 1–125 + group.css 21–91）',
              source:
                  '窄屏群场景顶栏（与底栏同构、中央换群头像）：玻璃 64 + 底部 1px 边 · blur18 saturate1.4 · **方角**（auroraqua 448 覆写 253 的 0 0 20 20）· `--glass-shadow-compact` · 五槽（语音|直播|头像|帖子|桌游）· 按钮 inline-flex 按内容宽（auroraqua 255 padding 6/12 + radius-input）· 选中共享胶囊**实测按钮矩形**跨槽迁移 300ms · hover 扫光 · 帖子 tab 8px 粉点（top 6 / 距中心右 18）· 入场「从底栏升起」由父级 translate 300ms --auroraqua-ease-out 注入',
              child: aylaGroupTopTabsSamples(), // 可交互：点 tab 看胶囊迁移
            ),
            const SizedBox(height: AylaSpacing.sp6),
            // ---------- Shell 顶栏（2026-09-20） ----------
            _Section(
              title:
                  'AylaTopNav（layout/TopNav.tsx 1–343 / layout/NarrowTopBar.tsx 1–199）',
              source:
                  '响应式（>768 宽屏 / ≤768 窄屏自动切换）· 宽屏＝圆角浮动卡（复用 AylaGlassCard：margin 12/12/0 + radius-card 16 + 四周 1px 边 + --glass-shadow + blur18）· 窄屏＝方角条（高 56 / padding 0 sp4 / 底部 1px 边 / 入场 auroraqua-panel-from-top）· 模块链 15/700 + 图标 16 上移 2px + 共享胶囊（有胶囊即不画底条，auroraqua 213）· logo 绝对居中 + 渐变字 indigo→grape + ≤1240 隐藏 · 图标钮复用 AylaIconButton（玻璃小卡 + hover 1.02 / press .98）· 搜索框＝文本字段族（radius-input + --glass-inset + focus 转辉光边）· 菜单与下拉浮层 300ms auroraqua-menu-in（opacity + −8px + .95→1）· 769–900 收窄降档（gap/padding + 搜索框 clamp(160,22vw,200)）',
              child: aylaTopNavSamples(), // 可交互：点模块 / 更多菜单 / 搜索框，切三形态
            ),
            const SizedBox(height: AylaSpacing.sp6),

            // ---------- Shell 侧栏（2026-09-21） ----------
            _Section(
              title:
                  'AylaServerRail（layout/ServerRail.tsx 1–184 + group.css 484–678 + auroraqua.css 216 / 217–229 / 270 / 311–313 / 125–138）',
              source:
                  '宽屏服务器列 72px：--glass-bg + blur24 sat1.4 + 1px 亮边 + --glass-shadow + radius-card 16 · 外距 12/0/12/12（auroraqua 270 覆写右 0）· 内 1px 占位（CSS border 占布局、Flutter 不占）· 列表 padding 20/77 + 行距 12 + clip-path 15 + 上 20/下 16 mask 渐隐 · 群头像 48 + 光环（选中 scale 52/48 · 180ms）· 选中指示条 3×32 --glow-500（group.css 的 ::before 版被 auroraqua 216 关掉，实际用 --rail 变体）· 未读 = 消息 + 帖子（左下角 -3/-3、99+ 截断、.server-item-badge 档）· 置顶 pin 左上 -6/-4 45° 粉 · 状态角标（直播/语音/桌游，右上竖列）· 悬停行 → 180ms 后展开置顶面板（行右缘 +2、垂直居中；浮层走 Overlay，否则溢出区收不到指针）· 底部 53 加号复用 AylaIconButton · 入场 panelVariants(left) 左入 20 / 300ms easeInOut · **滚动条已关**（web base.css 372–383 全局隐藏原生滚动条；自绘覆盖层条属 §B6 OverlayScrollbar）· **9 个群超出列高** → 可滚动，验收上 20 / 下 16 渐隐与「底部 77 让位悬浮加号」',
              child:
                  aylaServerRailSamples(), // 可交互：点行切群看指示条 300ms 迁移 / 悬停头像看置顶面板 / 滚轮看上下渐隐
            ),
            const SizedBox(height: AylaSpacing.sp6),

            // ---------- Shell 侧栏（2026-09-21：频道侧栏重做版） ----------
            _Section(
              title:
                  'AylaChannelSidebar（layout/ChannelSidebar.tsx 1–627 + group.css 680–1370 + auroraqua.css 54–94 / 142–197 / 236–249 / 288–291 / 310–313 / 655–676）',
              source:
                  '宽屏频道侧栏 slot 284（260 + 2×12）：--glass-bg + blur24 sat1.4 + 1px 亮边 + --glass-shadow + radius-card 16 · 内 1px 占位（CSS border 占布局、Flutter 不占；否则列表轨道 242→244、浮层钮偏 1px）· 群名头 Fredoka 500 20px + 16px chevron · 场景项 40 高 / gap 12 / padding 0 16 / radius 12 / 底 rgba(255,250,251,.4)；hover .18；选中底由**容器级单实例胶囊**画（auroraqua 194–197 取消按钮自身底）· 状态标识三型：语音在麦人数与 LIVE 是**裸文本**（web `.channel-scene-status` 零样式，继承 15px/600/secondary）、帖子未读才是粉徽标（margin-left auto 贴右）· 三个下拉各挂一个 paint-only 裁剪层（等价 useSidebarContentClip 的 inset；命中也随之裁剪，与 CSS clip-path 一致）· 自建 sticky：chat 0 / voice 44+吸底52 / live 88+吸底8，行本体画在浮层并在 **paint** 阶段按同帧几何定位（applyPaintTransform 同偏移）· 三角键属 auroraqua 按钮组（hover 1.02 + active .98），＋/笔不属于任何组（仅 180ms 底色）· 扫光只由**按钮本体** hover 触发（700ms），行级 hover 只管底色 · 语音房行 `sharedLayout={false}` → 行内独立胶囊、活跃度重排做 300ms 位置过渡 · 切群旧面板先退场再挂新面板（AnimatePresence mode="wait"）· **弹窗接线未做**（CreateSheet/VoiceChannelCreate/LiveStartSheet/SubGroupDialog 属后续批次，＋/笔点击暂无副作用）',
              child:
                  aylaChannelSidebarSamples(), // 可交互：点场景项/子群/语音房/直播间看胶囊迁移与吸顶滚动，hover 看两套 hover
            ),
            const SizedBox(height: AylaSpacing.sp6),

            // ---------- Shell 弹层（2026-09-21：A3 CreateSheet） ----------
            _Section(
              title:
                  'AylaCreateSheet（layout/CreateSheet.tsx 1–61 + private.css 185–275）',
              source:
                  '通用弹层容器 = AylaModalOverlay（--overlay-dim + 宽屏居中 / 窄屏贴底）+ AylaModalCard（--glass-bg-strong + blur24 sat1.4 + 1px 亮边 + radius-panel 20 + --glass-shadow-modal）· overlay 与卡片 padding 都是 sp4=16 · head = AylaSheetHead（Fredoka 18/600 + .icon-btn-40 关闭钮 = AylaIconButton，IconClose **20**；AylaConfirmDialog 那处是 18）· 三条关闭路径（ESC / 点遮罩 / 关闭钮；点卡内不关）· 窄屏 width 100% + radius 24 24 0 0 + 去左右下边框 + padding-bottom calc(sp4 + safe-area) + 上滑 250ms · 内容用 web CreateFab.tsx:93–103 的 post 分支（PostEditor），**可交互**：点关闭钮/遮罩即收起，点「重新打开」还原',
              child: const _CreateSheetDemo(),
            ),
            const SizedBox(height: AylaSpacing.sp6),

            // ---------- Shell 右下浮层按钮族（2026-09-21：A4） ----------
            _Section(
              title:
                  'AylaCornerFabStack / AylaRefreshFab / AylaScrollTopFab / AylaQuickMessageFab（layout/*.tsx + shell.css 423–456 / 679–787）',
              source:
                  '堆叠容器 = fixed right 38（32 + (56-44)/2）/ bottom 100（32 + 56 + sp3）/ column · gap 12 · align end · 容器不吃指针（Flutter 裸 Column 天然等价）· 44px 玻璃钮复用 AylaCornerFab（--glass-bg + blur18 sat1.4 + --card-shadow，hover → strong + 0 2px 12px .18；**过渡 200ms --auroraqua-ease**，因 auroraqua.css 54–94 把 .corner-fab 并入按钮组覆盖 shell.css 的 180ms）· 刷新：iconRetry 20，spinning = ayla-loading-spin 800ms linear infinite（reduced-motion 不转），无回调时按钮照常可点只是无动作 · 回顶：iconArrowUp 20，滚动超过一屏（pixels > 视口高）且命中**主滚动容器**（viewportDimension ≥ 40% 视口高）才浮入（opacity + translateY 8→0，200ms；隐藏态不可点 + 语义排除），点击 smooth 回顶（300ms ease-out；reduced-motion 直切）· 消息钮复用 AylaMessageFab 外观，4s 无点击 → 半贴 translateX(-44px)（200ms --ease-out），半贴点击点出来、展开点击打开快捷栏 · **样张可交互**：滚列表看回顶钮浮入、点刷新看旋转、等 4s 看消息钮半贴',
              child: aylaFabSamples(),
            ),
            const SizedBox(height: AylaSpacing.sp6),

            // ---------- Shell 会话活动悬浮球（2026-09-21：A5） ----------
            _Section(
              title:
                  'AylaSessionActivityIndicator（layout/SessionActivityIndicator.tsx 1–181 + shell.css 458–575 / 651–660）',
              source:
                  '固定层（web position:fixed；right 24 / top 80 / z 55；窄屏 right 16 / top calc(56 + safe-top + 48)）= 语音球 + 直播球 + 收起把手 · 球 44×44：1px --glass-border + **不透明** sakura-100/ice-300 底（字色 grape-700/indigo-700）+ 0 2px 12px rgba(70,91,146,.12)；hover/focus → scale(1.08) + --glow-shadow（150ms --ease-out）——球**不在** auroraqua 按钮组 ⇒ 无 1.02/.98，且**不加**背板模糊（不透明底把 blur(18) 完全盖住，视觉恒为零）· 把手 28×44 玻璃（--glass-bg-strong + blur18 sat1.4，保留）+ `›` 字符 16/w500/line-height 1 · 收起：整组右移 24（窄屏 16 ⇒ 把手贴屏幕右缘）+ 球 translateX(64px) 淡隐 + 图标 rotate(180deg)，全 200ms --ease-out；把手可上下拖（**5px** 阈值 / clamp 8 … 视口高-44-8 / 拖动后抑制合成 click）· 把手 hover 底色 = **透明**（web 的 --glass-bg-hover 全历史未定义 ⇒ 实渲染回落初始值）+ 字色转 --text-primary · **样张可交互**：点把手收起/展开、按住把手上下拖、点球看回调、开关模拟会话进出',
              child: aylaSessionActivitySamples(),
            ),
            const SizedBox(height: AylaSpacing.sp6),

            // ---------- voice 域第一批（2026-09-21：B1-1） ----------
            _Section(
              title:
                  'AylaVoiceChannelCard / AylaVoiceChannelList / AylaVoiceControls（components/voice/*.tsx 121 行 + app.css 2811–2832 · 2910–2915 · 3099–3120 + voice.css 471–485 · 505–628 · 647–659 · 690–789）',
              source:
                  '卡片三处上下文（.voice-hub / .group-voice / typed-result-card）的视觉声明**逐字相同** ⇒ 只有一个竖排形态，差异全在容器网格：.voice-hub 2→(≥769)3→(≥1440)4 列 + padding 12/16；.group-voice 恒 2 列 + padding 0 ⇒ 由 List 的 columns/padding 表达，**不设 variant**（app.css 的横排基础卡在真实渲染中从不出现，故不实现）· 卡面 = --glass-bg + 1px 亮边 + blur24 sat1.4 + --glass-shadow + radius 16 + padding 12 + gap 8 · hover 描边 → rgba(157,191,230,.65)（上浮 -2 / 按下 .99 由 AylaCardInteraction 提供）、active → --indigo-700（同特异性在后 ⇒ 压过 hover）· focus-visible 环 = **--ice-500** 2px（画在形状外、不占布局；Enter/Space 同义可进房）· head = 标签组（AylaScrollingTags；来源标签 sakura-300/grape-700、Fredoka 11/ls .8/**max-width 12ch** 实测换算、无字重） + 收藏槽（AylaFavoriteButton compact，调用方注入）· title = mic 14 + 15px/700/1.3 单行滚动 · owner/meta = 12px secondary · foot = 人数 + 加入钮（primary min-height 32 / 13px / padding 0 12），mine&!browsing → 「我在其中」占位胶囊（ice-100 底/indigo-700 字/pill，min-height 32）· joining → 卡片 .7 + 按钮禁用（.55）+「加入中…」· 文案：加入 / 加入中… / 查看语音房（browsing）· 空态 = placeholder 两行（Fredoka 28/600 + 14px secondary）· 控制条 = padding-top 8 + 顶部 1px --glass-border，离开钮走**新增档 AylaGlassButtonVariant.outlineDestructive**（透明底 + destructive 字 + 1px destructive 边、无阴影/无内高光），重新加入（livekit=failed）= primary min-height 28 / 12px · **样张可交互**：点卡或加入钮各计一次、控制条可切 failed 态',
              child: aylaVoiceChannelSamples(),
            ),
            const SizedBox(height: AylaSpacing.sp6),

            // ---------- voice 域第二批（2026-09-21：B1-2） ----------
            _Section(
              title:
                  'AylaVoiceMemberRow（components/voice/VoiceMemberRow.tsx 219 行 + app.css 2917–3095 + auroraqua.css 59/77/89/664）',
              source:
                  '行 = 头像 32（AylaAvatarHalo；爱莉走 AylaAvatarCore.elysia 光环，在线由页面层注入）+ 名称 13/w600 单行省略（「我」是名称行内的 11px indigo 子 span）+ 副行 11px（「在频道中」secondary /「已静音」destructive + IconMic 11）+ 操作区（flex:none）= 开关钮 + 音量条 · 开关钮 28 正圆：透明底 / --indigo-700，hover rgba(189,212,233,.35)、.is-off → --text-secondary + rgba(189,212,233,.25)，图标 15；在 auroraqua 按钮组内 ⇒ 200ms + hover 1.02 + active .98 · 音量条 90×20 三层（下→上）：轨道（双色 stops [0,fill,fill,1]：左 --indigo-700、右 ice-300@.55）→ 跳动条（宽 90×levelPct%、`linear-gradient(90deg, --glow-500, --ice-500)`、**80ms --ease-out**、`.is-speaking` 加 `0 0 6px rgba(247,150,255,.55)`）→ slider（轨道透明 4px + 自绘把手 14 圆 / --indigo-700 / 2px #fff 边 / `0 1px 4px rgba(70,91,146,.35)`；用 Flutter Slider 保住拖动/键盘/无障碍语义，divisions 100 = 原生 step 1）· 电平映射 `levelPct = round(min(1, level^0.4)×100)`（0.02→21 / 0.2→53 / 0.5→76）、说话阈值 **0.02** · 自己行 = 麦克风开关 + 本地麦音量（aria-pressed = micEnabled）；远端行 = 喇叭开关 + 播放音量（aria-pressed = locallyMuted，**语义与自身行不同**；locallyMuted 时跳动条归零、辉光消失）· 名称兜底 `user_id` 前 6 位 · **样张可交互**：拖滑块改音量、点开关切 is-off、拖「说话电平」看跳动条按 ^0.4 放大 + 说话辉光',
              child: aylaVoiceMemberSamples(),
            ),
            const SizedBox(height: AylaSpacing.sp6),

            // ---------- voice 域第三批（2026-09-21：B1-3 第一件） ----------
            _Section(
              title:
                  'AylaVoiceChannelCreate（components/voice/VoiceChannelCreate.tsx 80 行 + app.css 2848–2869 + auroraqua.css 502–531 + private.css 229–236）',
              source:
                  '可见性选择器（**复用 AylaVisibilitySelector**：群内创建 group 锁定 + 本群恒勾选）+ 名称输入 + 「建频道」+ 错误行 · 输入 = AylaGlassInput（min-height 36 / 13px / hint「新语音频道名称」/ 64 上限用 formatter 表达以免多出「0/64」计数器 / Enter 提交；圆角是 auroraqua 覆写的 --radius-input 12，app.css 的 pill 不生效；focus → glow-500 边 + --glow-shadow）· 两个挂载点（ChannelSidebar / CreateFab）**都在 AylaCreateSheet 内** ⇒ private.css 的 sheet 作用域恒生效：输入与按钮 width 100% + 输入 margin-bottom sp3（与容器 gap 8 叠加 = 与按钮 20）· 空名拦截「频道名称不能为空」（不发请求）· 防重入守卫 + busy 禁用 · 多选→单值 public→friends→group · 成功清空名称 + onCreated（外层关浮层）、失败显示文案并**保留表单** · 请求与列表插入由页面层 onSubmit 注入（web 是组件内直接调 API + store）· **样张可交互**：空名提交看报错、填名提交看清空与计数、第三个表单固定失败看文案',
              child: aylaVoiceChannelCreateSamples(),
            ),
            const SizedBox(height: AylaSpacing.sp6),

            // ---------- voice 域第四批（2026-09-21：B1-4） ----------
            _Section(
              title:
                  'AylaVoiceChannelPanel（components/voice/VoiceChannelPanel.tsx 158 行 + app.css 2873–2915 + voice.css 32–56/377–381 + auroraqua.css 584–610）',
              source:
                  '面板 = head（标题 **16/700**（h3 默认 bold，base.css 只重置 margin）+ 人数 12/secondary，**baseline 对齐**）+ 成员列表（`gap 8`）+ 控制条 · 材质 = radius 16 / --glass-bg / 1px 亮边 / blur24 sat1.4 / --glass-shadow / padding 16 / **max-width 560**（app.css）· **房间上下文档** `roomContext`（voice.css 32–56）：max-width→none、成员列表 `flex:1; min-height:0` 自己滚动、其余子项不收缩 · **材质归属档** `ownMaterial`（auroraqua 584–610）：宽屏房间面板透明（材质交外层卡）、窄屏外层卡透明（材质归面板）· 成员行复用 AylaVoiceMemberRow（isSelf/isElysia/展示投影注入）· 房主操作行（两个 `.btn.btn-ghost`「踢出/转让房主」，该类**无 CSS** ⇒ 4px 间距来自 JSX 空白；busy 时**两个一起** disabled + 当前行「处理中…」；失败静默）· 分页复用 AylaDirectoryLoadMore（retainCompletedSpace=false）· 控制条复用 AylaVoiceControls · 面板内只留两条纯列表规则：自己置顶兜底 / busy 管理 · **样张可交互**：普通档（拖音量条、点喇叭/麦克风）、房主档（点踢出看「处理中…」）、房间档（固定高 420 + 成员列表自带滚动 + **面板透明**：web 的 `.voice-room-voice-card` 自身无材质声明，宽屏内外两层都透明 ⇒ 整列浮在极光背景上）',
              child: aylaVoiceChannelPanelSamples(),
            ),
            const SizedBox(height: AylaSpacing.sp6),

            // ---------- voice 域第五批（2026-09-21：B1-5） ----------
            _Section(
              title:
                  'AylaElysiaVoicePanel（components/voice/ElysiaVoicePanel.tsx 108 行 + app.css 3122–3156 / 1324–1333 / 1362）',
              source:
                  '⚠️ **web 里该组件没有挂载点**（只有 hook + vitest）⇒ 本画布是唯一视觉验收面 · 收起档 = 单个 .btn-glow「爱莉语音」+ `.collapsed`（padding **sp3** + `align-items: flex-start`）· 展开档 = head（`.elysia-voice-head` **align-items: center**（B1-4 那个面板是 baseline，别抄错）+ 标题 16/700 + `.msg-action-btn`「收起」）+ 未接入态（`.voice-list-empty`：「接入中…」/「等待接入」）+ 输入行（`input.voice-create-input` 同 B1-3 档 + 2000 上限用 formatter + Enter 提交 + primary「发送」）+ 行动区（终态 → primary「重新发起」；否则 `.voice-leave-btn` = outlineDestructive「结束通话」）· busy 时三按钮一起禁用 · 空文本不受理则**不清空**输入 · 材质 = radius 16 + --glass-bg + blur24 sat1.4 + --glass-shadow + max-width 560 · **样张可交互**：点「爱莉语音」展开、输入后点发送/Enter、点结束通话看终态档切换、开关 busy',
              child: aylaElysiaVoicePanelSamples(),
            ),
            const SizedBox(height: AylaSpacing.sp6),

            // ---------- voice 域收尾（2026-09-21：B1-6，voice 域 8/8） ----------
            _Section(
              title:
                  'AylaVoiceRoomBody（components/voice/VoiceRoomBody.tsx 327 行 + voice.css 12–470 + app.css 2105–2138/3473–3477 + base.css 463–472）',
              source:
                  '**语音房整页（进房态）· voice 域最后一件** · 两形态：**≥769** body padding sp4 + gap sp4，layout = **grid** `minmax(320,1fr) minmax(320, min(380,45%))`（+ `@container voice-room (max-width:655px)` → 单列两行），三分区各自动画（head 上入 / chat 右入 / voice 下入 300ms），两张卡自带材质 + chat head/列表常驻 + 开关隐藏；**≤768** 无 padding、head 只有下边框、上下堆叠、聊天 = 底部输入卡 + **上方浮层**（h300、只有上两角 radius 16、`--glass-bg-strong` + blur18、opacity/translateY(12)/visibility 240ms）· **材质归属按断点切换**：宽屏材质在 `.voice-room-voice-card`、面板透明；窄屏外层透明、材质归 `.voice-panel`（样张里 builder 参数会显示 false/true）· head 六件：返回 · 标题（Fredoka 18）· 可见性标签（容器 16ch、标签 12ch 同 `.post-card-tag` 档）· 收藏 · 分享 · 「删除房间」（⚠️ web 的 `.btn-danger` **全 CSS 无定义** ⇒ 实渲染是无材质的裸 `.btn`，已按用户裁决照实复刻）· 房内聊天：消息行（sender 700 secondary + 「图片」占位不渲染文本 + 缩略图 120×80）+ 历史控件 + 输入条（工具钮 40 pill / `min-height 40` `max-height 140` 的输入 / primary 发送 / 窄屏开关）+ **未读徽标**（18/11/600/`--pink-500`/99+；规则：新 id + 聊天栏收起 + 非自己才 +1，展开清零，seenIds 上限 1000）+ `.live-form-error` · **样张可交互**：发文本（空文本禁用发送）、点图片钮、开关「下一次发送失败」看错误行、点右下 ▲ 展开窄屏浮层看未读红点',
              child: aylaVoiceRoomBodySamples(),
            ),
            const SizedBox(height: AylaSpacing.sp6),

            // ---------- live 域第一批（2026-09-22：B2-1，弹幕三件） ----------
            _Section(
              title:
                  'AylaDanmakuList / AylaDanmakuInput / AylaDanmakuOverlay（components/live/Danmaku{List,Input,Overlay}.tsx 139+180+213 行 + danmakuTracks.ts 55 行 + app.css 3671–3827 + live.css 756–784/860–929/1006–1018 + auroraqua.css 347–359/378–383/390/502–523）',
              source:
                  '**弹幕三件一批 · live 域第一批** · 列表 = `.danmaku-wrap`（组件根，**自身永不持材质**：app.css 3671–3676 只有布局；⚠️ live.css 756–764 给 `.live-room-swipe-item .danmaku-wrap` 的玻璃 + `radius 0 0 12 12` **没有任何渲染面** —— `.live-room-swipe-item` 只在窄屏分支出现（`LiveRoomBody.tsx` 441/468），而 live.css 818–839 的 `@media (max-width:768px)` 又把同元素的 border/background/backdrop-filter/radius 全清零 ⇒ 此前据它做过一档材质，是造轮子，**已删**；宽屏材质归 `<aside class="live-room-side">` 那张卡片（auroraqua 392–400），窄屏实渲染透明 + 仅 `min-height: 96`）+ `.danmaku-list`（padding sp3 + gap sp2）+ 行（**头像 20** + 昵称 **Space Grotesk 12** secondary + 内容 14/1.5）+ 空态 + **新弹幕提示**（`--bubble-elysia` 渐变底 + `--text-on-pink` + pill + `--glow-shadow`，bottom sp3 居中，无 hover）+ 图片钮 **96×64 / radius 8**；⚠️ **失败态照实渲染**（拍板）：骨架铺满 96×64、「图片加载失败，点击重试」芯片被 `overflow:hidden` 裁掉不可见，且 `AylaResourceImage.tsx 96–115` 的 `enclosingControl` 语义 ⇒ **点击=重试而不开查看器**（Flutter 用新增的 `AylaResourceImage.onStateChanged` 判态路由）· 输入条**三档材质**（`narrowCard` ≤768 沉浸态——live.css 768–772 的 `--glass-bg` + blur18 sat1.4 原本在包装层 `.live-room-input` 上，已并入组件／**`sideCard` ≥769 直播侧栏卡内**——auroraqua 347–359 的玻璃材质被 555–567 清零，实渲染 = `margin 12` + `padding 8` + 透明底 + **仅上边框分隔线** + 方角，即用户截图那栏／`base` studio 窄屏——侧栏卡本身透明，只剩 app.css 的 `padding sp3` + 上边框）= 状态行（上传中/两种失败 + 「重试图片」`AylaMsgActionButton`）+ 输入行（`AylaGlassButton(ghost, glowBorderOnHover)` 40×40 图片钮 / `AylaGlassInput` padding 8-12 单行「发条弹幕吧」400 上限 / primary 发送钮 **min-width 72**）+ 元行（`.live-form-error` 或 `计数器 trim/200`）；**图片三步（选/传/发）由页面注入**（`AylaMediaActions.pickImage`/`uploadImage`），组件持 attempt ⇒ 上传失败**重传同一文件**、发送失败**复用 media_id**；发送中**不禁用输入框**（保焦点）· 飘弹幕层 = 只飘**新出现**的弹幕（挂载/切台基线排除历史与重连对账）+ 轨道算法（速度 150px/s、间距 60px、行高 36、轨道 2–10）+ 关键帧 `translateX(calc(-100% - 24px))` 线性 + 上限 80 + reduced-motion 整层不渲染 + `ExcludeSemantics`（aria-hidden）· **样张可交互**：点弹幕图片开全屏查看器（root Overlay）、切「有新弹幕」、输入计数与回车发送、图片上传失败→重试、点「发一条/图片弹幕」看从右向左飘、点「换台」看基线重建',
              child: aylaDanmakuSamples(),
            ),
            const SizedBox(height: AylaSpacing.sp6),

            // ---------- live 域第二批（2026-09-22：B2-2，大厅卡片 + 网格） ----------
            _Section(
              title:
                  'AylaLiveChannelCard / AylaLiveHall（components/live/LiveChannelCard.tsx 53 行 + LiveHall.tsx 45 行 + app.css 3275–3397 + live.css 486–493/559–596/617–655/811–814/1333–1354 + shell.css 619–629 + auroraqua.css 29–52）',
              source:
                  '**直播大厅（卡片 + 网格）· live 域第二批** · 卡片 = `AylaCardInteraction`（卡片族悬停 `translate 0 -2px` + `--glass-shadow-hover`、按压 .99）+ `AylaGlassSurface`（radius 16 / blur24 sat1.4 / `--glass-shadow`）+ 封面 **16:9**（`--radius-input` / 1px 亮边 / 透明底 / 无封面用 `iconVideo 28` + `--ice-500`）+ 状态徽章三档（**`.live-badge-live` 被 live.css 811–814 后加载覆写为 `--pink-500` 底 + `--surface` 字**；idle/ended = `--ice-100` + secondary）+「爱莉」角标（`--bubble-elysia` 渐变 + `--text-on-pink`）+ **人数角标**（右下玻璃胶囊 `--glass-bg-strong` + blur8 无 saturate；**仅 status==live 且有读数**才渲染，`null` 不渲染、`0` 照常、`1.2k/53k` 紧凑写法）+ 标题（Fredoka 16 / **line-height 1.35 固定行高**）+ 主播名（13/1.4 secondary，`ownerNickname` 优先于 `ownerNames` 兜底）+ 来源标签（**共享件 `AylaSourceTag`**，容器 `max-width: 55%` 滚动）· **收藏键**：compact 32×32 落在封面右上（窄屏 12 / 宽屏 `calc(sp4+sp1)`=20 与徽标同线；点按不触发进房）——⚠️ **卡片上不放转发键**（追加裁决：首轮按「都要」加过，随后被否决；转发键只在**房头部**）· **卡片等高**：web 靠 CSS grid 的 `align-items: stretch` 拉平，Flutter 侧由 `reserveMetaSpace` **恒占位 meta 行**（固定高 `max(13×1.4, 12×body+2×2)`）保证——不能用 `IntrinsicHeight`（卡片含 `LayoutBuilder`，不支持 intrinsics）· 网格：**≤768 → 2 列（+ 上下 padding sp3、卡片 padding sp2）/ ≥769 → 3 列 / ≥1440 → 4 列**、`gap sp4`；用 `Wrap` 表达等宽列（**等高由 `reserveMetaSpace` 预留保证**，等价 web 的 `align-items: stretch`）· 空态 = `placeholder-title`（Fredoka 28/600）+ `placeholder-desc`（14 secondary）+ `padding sp12 0` · **样张可交互**：点卡进入计数、点收藏键切换、三档断点与空态各一格',
              child: aylaLiveHallSamples(),
            ),
            const SizedBox(height: AylaSpacing.sp6),

            // ---------- live 域第三批（2026-09-22：B2-3，直播侧栏 + 开播选择器） ----------
            _Section(
              title:
                  'AylaLiveChannelRail / AylaLiveStartSheet（components/live/LiveChannelRail.tsx 168 行 + LiveStartSheet.tsx 86 行 + live.css 10–29/48–139/232–239/311–423/1356–1370 + auroraqua.css 125–139/175–205/412–454）',
              source:
                  '**直播侧栏 + 开播选择器 · live 域第三批** · 侧栏 = 240 宽（≤768 → `min(240, 100vw-48)`）+ `margin 12` + `AylaGlassSurface`（radius 16 / blur24 sat1.4 / `--glass-shadow`）；⚠️ `width` 必须用 `UnconstrainedBox` 松掉父级横向紧约束才权威（`SizedBox(width:)` 的 `constraints.enforce` 会被紧父级夹回——实测 420 宿主里变 396）；竖向仍受父约束（web flex 行 `align-items: stretch`）· 操作区 `min-height 54`（与顶栏等高）+ `padding sp2 sp3` + 下边框；两个 36×36 pill 图标钮（返回 / 收起，**不在扫光组** ⇒ `sweep: false`）· 列表 `padding sp3` + `gap sp2`；行 = 封面 **72×16:9**（radius-input / 1px 亮边 / 无封面用 `iconVideo 18` + `--ice-500`；在播时 **8×8 `--pink-500` 圆点** top/right 4）+ 标题 **13/1.35 两行截断**（不是单行滚动）+ 人数角标（utility 11 / ls .3 / lh 1 / gap 2，active → text-primary）+ 删除键（**22×22** pill / `rgba(255,250,251,.72)` / destructive / opacity 0→整行 hover 或自身 focus 显形 / disabled .4）· **选中高亮 = 容器级单实例 + 跨项迁移 300ms**（web 是 `AuroraquaNavHighlight` **裸变体** + 共享 `layoutId`；选中行自身底色被 auroraqua 194–197 清零）· **自动滚到当前项 = CSS `block:"nearest"` 的显式等价**（已可见不动 / 上方顶对齐 / 下方底对齐；`Scrollable.ensureVisible` 的两种 keepVisible 策略都是单向的，不合用）· 收起态**整个组件不渲染**（返回/展开键移到顶栏；`.live-rail-float` 是死 CSS 不复刻）· 底部「新建直播间」= **1px 虚线 `--ice-500`**（复用新共享件 `AylaDashedBorder`，原为 `channel_sidebar` 私有 painter）· 目录页脚由 `directoryFooter` 槽注入 · 开播选择器 = intro（Fredoka 20 + 13 secondary）+ 五态（加载/列表失败 alert+重试/创建失败/空态/有内容）+ 列表（`max-height: min(42vh,360px)`；行 **min-height 68** / `rgba(255,250,251,.45)` 底 / 145deg `ice-300→sakura-100` 封面 + 「LIVE」/ 标题 14 + 副行 13 / `→` 20）+ 底部 `.btn-glow` 键 · **样张可交互**：点封面切台看高亮迁移、删除键 hover、收起/重开、开播选择器两态',
              child: aylaLiveRailSamples(),
            ),
            const SizedBox(height: AylaSpacing.sp6),

            // ---------- live 域第四批（2026-09-22：B2-4，观看条/名单弹层 + 主播头像 + 推流地址） ----------
            _Section(
              title:
                  'AylaLiveViewerStrip / AylaLiveViewerSheet / AylaLiveHostAvatar / AylaLiveStreamAddresses（components/live/LiveViewerStrip.tsx 85 行 + LiveViewerSheet.tsx 147 行 + LiveHostAvatar.tsx 52 行 + LiveStreamAddresses.tsx 72 行 + live.css 206–229/1095–1325/249–257 + app.css 3443–3477）',
              source:
                  '**观看条 + 名单弹层 + 主播头像 + 推流地址 · live 域第四批** · 观看条 = 整排按钮（`min-height 44` / `padding sp1 sp3` / radius-input / `--glass-bg` + blur18 sat1.4 / **compact 阴影** / hover `rgba(255,250,251,.72)`）+ 人数圆（`min-width 32` / h32 / pill / **`--ice-300` 底 + `--indigo-700` 字** / utility 12 ls .3 lh 1）+ 头像排（size **26** / gap sp1 / **overflow hidden 裁掉放不下的**）+ 排尾「更多」三圆点（26×26 / ice-100 / `IconDots 14`）· **未知人数显示 `–`**（ice-100 + secondary，尺寸与已知态**完全一致**，禁止画面跳变）、`0` 是真实读数照常显示 · **纯展示**（不自行拉数据）· 整排/名单行复用 `AylaCardInteraction(interactive: false, focusRingColor: --focus-ring 即 glow-500)`——它们**不在** auroraqua 的卡片/按钮 `:is()` 组里（无 1.02/.98、无扫光），只有 `outline 2px` 环 · 名单弹层 = **复用 A3 `AylaCreateSheet`**（`narrowHeightFactor: 0.6` = 窄屏 **60vh** 贴底上滑）+ **head 固定、只有名单自身滚**（body 最大高 = 卡上限 − padding sp4×2 − 安全区 − head 52）+ 行（min-height 48 / 头像 36 / 名字 15 w600 / hover glass-bg）+ 骨架 6 行（头像 **41×41** = 36 + 光环 2.5×2）+ 空态「还没有人在看」+ 截断「仅显示前 N 位」+ 503 `role=alert` + 重试（**不冒充空名单**）· **弹层插 root Overlay**（等价 web `createPortal(document.body)`；官方用例明确「侧栏 backdrop-filter 不裁剪弹层」）· 主播头像（label 回退链 `nickname → username → owner_nickname → 主播`；aria「查看主播 X 的个人主页」；size 默认 36；在线由页面按 presence 判（隐身恒离线））· 推流地址（`width: min(100%,960px)` 卡 + 三行：标签 **64** / 值 utility 12 省略号 **卡内覆写玻璃底 + radius-input + 内高光** / 复制键 `.msg-action-btn` →「已复制」1.5s / 失败 destructive 文案；**缺 rtmp_url 或 stream_key 时整块不渲染**；`stream_key` 是推流指纹**不打日志不持久化**）· **样张可交互**：点整排开名单（root overlay）、状态切换、复制/失败态',
              child: aylaLiveViewersSamples(),
            ),
            const SizedBox(height: AylaSpacing.sp6),
            _Section(
              title:
                  'AylaLiveHostAvatar / AylaLiveStreamAddresses（同批：主播头像 + 推流地址区）',
              source:
                  '**同批两件（B2-4）** · 主播头像 = `AylaAvatarHalo`（有头像/无头像、在线/离线、size 36/28/52 三档）· 推流地址 = 卡 `width: min(100%,960px)`（用 `Align` 松横向紧约束才权威——`ConstrainedBox(maxWidth:)` 会被紧父级 `enforce` 夹回）+ padding sp3 + 三行（标签 64 / 值 utility 12 + 卡内玻璃覆写 + `--glass-inset` 内高光 / 复制键）+ `.live-form-error` · 窄屏 `align-items: flex-start`（同档 `flex-wrap: wrap` **无渲染面**：值 `min-width: 0` 可压到 0 ⇒ 永不换行，照实只表达交叉轴对齐）· 样张可交互：复制 →「已复制」1.5s、失败态开关',
              child: aylaLiveStudioSamples(),
            ),
            const SizedBox(height: AylaSpacing.sp6),

            // ---------- live 域第五批（2026-09-22：B2-5，建播表单 + 控制台资料栏） ----------
            _Section(
              title:
                  'AylaLiveCreate（components/live/LiveCreate.tsx 189 行 + app.css 3401–3477 + live.css 32–33/164–174 + auroraqua.css 502–531）',
              source:
                  '**建直播间表单 + 推流指引 · live 域第五批** · ⚠️ **本件在 web 里零挂载点**（全仓 `<LiveCreate>` 零命中、vitest 也无用例；真实建播走 `ChannelSidebar.handleCreateNewLive` → `createLiveChannel("新直播间")`）⇒ **组件画布是唯一视觉验收面**（同 B1-4 `ElysiaVoicePanel`）· 表单 = `.live-create-form`（app.css 的 row+gap sp2 **被 live.css 32 覆写为 column/stretch**）+ 标题（placeholder「给直播间起个标题」· maxLength 128）+ 介绍（「告诉观众这场直播聊什么（可选）」· 2000 · min-height 72）+ 可见范围（**复用 `AylaVisibilitySelector`**：群内默认勾本群**不锁定**、群外默认公开）+ 封面（**96 → ≤768 88** / 16:9 / `1px dashed --ice-500` / radius-input / glass-bg；⚠️ 用户的 `<img>` **漏了 `live-cover-preview-img` 类** ⇒ live.css 174 的 object-fit 是死规则 —— **裁决按 web 本意用 `cover`**）+ `.btn-glow`「开播」→「准备中…」· 字段族 = `--glass-bg` + 1px 亮边 + radius-input + **`--glass-inset`** + blur24 sat1.4 + focus `--glow-500` 边 + `--glow-shadow`（⚠️ app.css 写的 `box-shadow: var(--focus-ring)` 是**无效声明**：`2px solid #f796ff` 里的 `solid` 在 box-shadow 里非法）+ placeholder `--slate-500` · 指引（`.live-create-guide`：`--glass-bg-strong` + radius 16 + margin-top sp3 + 标题 Fredoka 15 + notice **`--warning` 13** + 两行复制**基础档**（`--ice-100` + radius-sm 8）+「我已保存，关闭」右对齐）· 空标题「标题不能为空」**不发请求**；`stream_key` 是推流指纹**不打日志不持久化** · **样张可交互**：填标题后点「开播」看指引、点复制/关闭、失败态',
              child: aylaLiveCreateSamples(),
            ),
            const SizedBox(height: AylaSpacing.sp6),
            _Section(
              title:
                  'AylaLiveOwnerPanel（components/live/LiveOwnerPanel.tsx 217 行 + app.css 3831–3843 + live.css 168–180/190–269）',
              source:
                  '**控制台资料栏（真实挂载：`LiveRoomBody` 的 showOwnerPanel）** · 卡 = padding **sp3**（live.css 168 覆写 app.css 的 sp4）+ `--glass-bg` + blur24 sat1.4 + 1px 亮边 + radius 16 + `--glass-shadow` + column gap sp3 · 行 = 封面 96×16:9（虚线冰蓝；⚠️ 本件 tsx **确实带** `live-cover-preview-img` ⇒ cover **生效**，与 LiveCreate 的死规则不同）+ 标题 **200 固定**（`flex-shrink: 0`）+ 介绍 flex 1 + 开播（`.btn-glow`）/保存竖排（`min-width 96` / `min-height 40`）· 可见范围块 = padding sp3（≤768 sp2）+ **上边框 1px** · 三档断点：≤768 与 **769–1100**（侧栏压缩控制台余宽）都换行 ⇒ 封面+字段一行、开播/保存独占一行 · 保存 = 载荷（trim + 可见性单值 `public→friends→group`）→ **用后端回显刷新封面与可见范围**（后端可能规范化 `allowed_group_ids`）· 「标题不能为空」不发请求；开播/下播 busy 期禁用、失败「操作失败」· ⚠️ **下播键 web 是裸 `.btn`**（app.css 21–34 只有盒模型/字体，**没有任何底/边/阴影**）—— **裁决当 web 的 bug** ⇒ 改用库内 `ghost` 档给回玻璃面（登记为有意偏离）· **样张可交互**：改标题→保存看回显、开播/下播切换、切可见范围',
              child: aylaLiveOwnerPanelSamples(),
            ),
            const SizedBox(height: AylaSpacing.sp6),

            // ---------- live 域最后一批（2026-09-22：B2-6，播放器 / 浮动小窗 / 直播间装配） ----------
            _Section(
              title:
                  'AylaLivePlayer（components/live/LivePlayer.tsx 420 行 + app.css 3517–3636 + live.css 939–1005）',
              source:
                  '**播放器三态 + 悬浮控件 · live 域最后一批** · 根 = 16:9 / `rgba(70,91,146,.12)` / radius-card / 1px 亮边 / overflow hidden；视频 `object-fit: contain` + #000 底 · **三态**：`srsStatus == null` →「正在查询直播状态…」/ degraded →「直播服务状态未知，请稍后再试」（`--warning`）/ idle →「等待推流信号…」（乐观已开播）或「主播未开播」/ live + 播放失败 →「播放失败」（`--destructive`）+ `.btn-glow`「重试」· **悬浮控件**（`.live-player-controls`）：`opacity 0→1`（180ms）+ 隐藏时整层穿透；**桌面悬停/移动、触屏点击**显示，显示后 **3s 无操作自动隐藏**（`AUTO_HIDE_MS = 3000`）；左下「刷新」（32×32 · `rgba(70,91,146,.32)` + 1px `rgba(255,255,255,.28)` + 白图标 16 + blur8 sat1.2 · hover .52 · 点击转一圈 0.6s，reduced-motion 不转）+ 右下「全屏」· **画中画键不实现**（浏览器 PiP 无 Flutter 等价物；窄屏 web 本就隐藏 ⇒ 有意偏离）· **全屏改用 root Overlay 铺满 + 移动端锁横屏**（web 是 `requestFullscreen` 让容器进 top layer；Flutter 无此能力），全屏时 inline 侧不再挂视频（避免平台视图被同时 attach），屏幕下方居中显示**全屏弹幕输入框**（`min(320, 100%-120)` / min-height 50 / 内 input 透明 40 高 / 40×40 `.btn-primary` 发送键 / 失败提示玻璃片）· video 由页面注入（`HlsPlaybackController.videoView`，PoC-B 封装层）· **样张可交互**：悬停/点击显示控件、3s 自动隐藏、刷新旋转、进全屏',
              child: aylaLivePlayerSamples(),
            ),
            const SizedBox(height: AylaSpacing.sp6),
            _Section(
              title:
                  'AylaLiveMiniPlayer（components/live/LiveMiniPlayer.tsx 228 行 + live.css 1021–1095）',
              source:
                  '**手机端 App 内浮动小窗** · 仅**窄屏离开直播间且直播中**出现（调用方判断）；同一时刻至多一个 owner · **fixed 右下 16 / z 60** / **168×94（16:9）** / `touch-action:none` + 禁选中 · 内层 `.live-mini-player-video-wrap` = radius-input + `--glass-bg-strong` + blur24 sat1.4 + 1px 亮边 + compact 阴影 + overflow hidden（**外层不裁剪**，关闭键才能突出在外）· 关闭键 **top/right = -10**（24×24 · `rgba(70,91,146,.32)` · 1px `rgba(255,255,255,.28)` · 白 `IconClose 14` · hover .52）· **单指拖动**（阈值 **5px**、边缘间距 **8**、clamp 在视口内）+ **双指缩放**（宽 **120–320**、高按 16:9、**右下角锚定**）· 点主体/Enter/Space → 回直播间；关闭 → 完整销毁会话 · ⚠️ Flutter 侧**不做 web 的 `suppressClick`**（没有合成 click；拖动一开始 tap 识别器就输给 scale 识别器）· 返回 **Positioned** ⇒ 调用方放在最外层 Stack 直接子级 · **样张可交互**：拖动 / 点主体 / 点关闭',
              child: aylaLiveMiniPlayerSamples(),
            ),
            const SizedBox(height: AylaSpacing.sp6),
            _Section(
              title:
                  'AylaLiveRoomBody（components/live/LiveRoomBody.tsx 566 行 + live.css 10–29/520–760 + auroraqua.css 202–211/316–321/437–445）',
              source:
                  '**直播间核心装配（live 域收官件）** · 宽屏三栏 = `.live-rail`（240 侧栏，可收起；收起后展开键回头部）+ `.live-room-main`（头部 + 控制台资料栏 + `.live-room-stage`(播放器 16:9) + 观众条 + 推流地址）+ `.live-room-side`（弹幕列表 + 输入框）· **窄屏沉浸式** = 固定头部 + **视频与弹幕区整体上下滑切台**（dragElastic **0.8**；松手判定：净位移 > **1/3 高**优先，否则同向甩动补充）+ 固定输入框 + 右下列表键打开**覆盖层**（`.live-room-rail-overlay`：`rgba(70,91,146,.25)` 遮罩点关闭 + 右侧 240 侧栏）· **进房错误态仍保留侧栏与弹幕区**（避免卡在只有返回键的死页面）· 头部 = 返回(40×40) + 主播头像(32) + 标题滚动 + **来源标签（共享件 `AylaSourceTag`）** + 收藏(compact) + 转发 + 窄屏列表键 · 控制台（`showOwnerPanel`）头部整行不渲染、改由侧栏承载返回/标题 · **全屏期间冻结 isNarrow**（防锁横屏导致窄↔宽切换、播放器重建黑屏）· 飘弹幕层**仅 `!loading && srsStatus === "live"`** 才挂 · 数据全部由页面注入（`AylaLiveRoomData` + 回调；web 的 `useLiveRoom`/`useDanmaku`/live store 属数据层与运行时）· **样张可交互**：点侧栏切台、收起/展开、窄屏上滑切台、列表覆盖层开关'
                  ' · **2026-09-28 收尾轮补切台/头部编排动效**（LiveRoomBody.tsx:139–151/443–476/542–565）：'
                  '① 面板重播 = AylaRevealScope(replayKey: channelId) + 三块 AylaRevealItem（宽屏 stage/viewer-strip edge bottom + '
                  'side edge right；窄屏 stage/viewer-strip bottom + danmaku-wrap right），位移 ±20 / 300ms；'
                  '② 头部 = _LiveRoomHeaderSwap（AnimatePresence mode="wait" 串行退出→进入 + inert/aria-hidden/pointer-events:none '
                  '的 Flutter 等价 ExcludeFocus/ExcludeSemantics/IgnorePointer）；'
                  '⚠️ is-panel-motion / has-media-panel-motion 在 live.css 零命中，auroraqua.css 三处全是「取消 CSS 挂载入场」'
                  '⇒ Flutter 直接挂 owner（依据已登记在代码注释）；reduced-motion 与 error 两档按 web 关闭。'
                  '点侧栏切台 / 窄屏上滑切台即可看动效；⚠️ 玻璃件外整层 Opacity 在 Impeller 下会被拒 ⇒ 若只见滑入不见淡入属已知环境限制（位移腿已按像素对账）',
              child: aylaLiveRoomBodySamples(),
            ),
            const SizedBox(height: AylaSpacing.sp6),

            // ---------- 房内页批次（第 5 批；19 号 §十四）：控制台空态 ----------
            _Section(
              title:
                  'AylaStudioEmpty（live.css 148–159 + LiveStudioPage.tsx 118–135）',
              source:
                  'column 居中 + gap sp2 + height 100% + padding sp4 + text-align center · '
                  '标题 Display **20 / w400**（web 只声明 font-family + font-size ⇒ 字重继承 body）+ --text-primary · '
                  '描述 13 + --text-secondary · 按钮 = .btn.btn-glow「创建直播间」（库内 AylaGlassButton glow 档）· '
                  '**两档**：默认 / 创建中（按钮禁用）',
              child: aylaStudioEmptySamples(),
            ),
            const SizedBox(height: AylaSpacing.sp6),

            // ---------- 入场动画（2026-09-20 审查 R7：公共件） ----------
            _Section(
              title:
                  'AylaRevealItem / AylaRevealScope（base.css .reveal-item · auroraqua.css 8–26 · useListEntryMotion）',
              source:
                  'opacity 0→1 + 下 20px · 300ms --auroraqua-ease-out · stagger 50ms（cap 300）· reduced-motion 直接到位 · enabled:false 不挂动画'
                  ' · **样张可交互**：点「重播入场」= `AylaRevealScope(replayKey: nonce)` 让四档同时重播（库内既有能力，见 reveal.dart:63；'
                  '否则只能看静止终态，方向/时长/错峰/降级都无法验收）',
              child: const _RevealShowcaseDemo(),
            ),
            const SizedBox(height: AylaSpacing.sp6),

            // ---------- 加载族 ----------
            _Section(
              title: 'Skeleton + Spinner + AylaFullScreenLoader（base.css 515–574）',
              source:
                  'spinner 18px/800ms · skeleton radius 8 + frost-pulse .55↔.9 1600ms · loader 品牌 40px 渐变字',
              child: _Row(
                children: <Widget>[
                  _Slot(
                    label: '骨架行（44 头像 + 两行）',
                    width: 260,
                    child: const _SkeletonSample(),
                  ),
                  _Slot(
                    label: 'spinner md / sm',
                    child: const Row(
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        AylaLoadingSpinner(),
                        SizedBox(width: AylaSpacing.sp3),
                        AylaLoadingSpinner(size: 14),
                      ],
                    ),
                  ),
                  _Slot(
                    label: 'AylaFullScreenLoader（无卡片）',
                    width: 300,
                    child: SizedBox(
                      height: 220,
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(AylaRadii.rCard),
                        child: const AylaFullScreenLoader(),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: AylaSpacing.sp6),

            // ---------- 图标库（全量 47 个） ----------
            _Section(
              title: 'Icon 图标库（web components/icons.tsx 全量 47 个）',
              source:
                  'viewBox 24 · 2px 描边 · round cap/join · 默认 18px · 实心特例已还原',
              child: Wrap(
                spacing: AylaSpacing.sp4,
                runSpacing: AylaSpacing.sp6,
                crossAxisAlignment: WrapCrossAlignment.start,
                children: <Widget>[
                  for (final AylaIconData icon in kAylaIcons)
                    Column(
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        AylaIcon(icon, size: 18, color: AylaColors.indigo700),
                        const SizedBox(height: AylaSpacing.sp1),
                        SizedBox(
                          width: 110,
                          child: Text(
                            icon.name,
                            textAlign: TextAlign.center,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: t.timestamp.copyWith(
                              color: AylaColors.textSecondary,
                            ),
                          ),
                        ),
                      ],
                    ),
                  // 内联 glyph 公共件（**不在** icons.tsx 的 47 个里）：铅笔 ——
                  // 2026-09-28 由 channel_sidebar / group_info_lists 两处私有 painter 提升，
                  // 事实源 `ChannelSidebar.tsx:621–627` 与 `GroupInfo.tsx:1012–1018`（同 path）。
                  Column(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      const AylaPencilGlyph(size: 18, color: AylaColors.indigo700),
                      const SizedBox(height: AylaSpacing.sp1),
                      SizedBox(
                        width: 110,
                        child: Text(
                          'AylaPencilGlyph',
                          textAlign: TextAlign.center,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: t.timestamp.copyWith(
                            color: AylaColors.textSecondary,
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: AylaSpacing.sp6),

            // ---------- B2 展示型基元 ----------
            _Section(
              title:
                  'Batch 2 基元（LayoutSwitch / SegmentedTab / CapsuleTag / ScrollingText）',
              source:
                  'home.css .layout-switch 182–206 · messages.css .messages-tab 24–37 · '
                  'd:§4 胶囊 · base.css .scroll-text 724–758（marquee）',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  _Row(
                    children: <Widget>[
                      _Slot(
                        label: 'LayoutSwitch（点击切换·胶囊 300ms 迁移）',
                        child: const _LayoutSwitchDemo(),
                      ),
                    ],
                  ),
                  const SizedBox(height: AylaSpacing.sp6),
                  const SizedBox(width: 420, child: _TabsDemo()),
                  const SizedBox(height: AylaSpacing.sp4),
                  const Wrap(
                    spacing: AylaSpacing.sp2,
                    runSpacing: AylaSpacing.sp2,
                    children: <Widget>[
                      AylaCapsuleTag('数字生命'),
                      AylaCapsuleTag('持续记忆'),
                      AylaCapsuleTag('历史搜索', tone: AylaCapsuleTone.ice),
                      AylaCapsuleTag('玻璃胶囊', tone: AylaCapsuleTone.glass),
                      AylaCapsuleTag('LIVE', tone: AylaCapsuleTone.pink),
                      AylaCapsuleTag('实底', tone: AylaCapsuleTone.indigo),
                    ],
                  ),
                  const SizedBox(height: AylaSpacing.sp4),
                  const SizedBox(
                    width: 300,
                    child: AylaScrollingText(
                      text: '长文本 marquee 滚动验证：这是一段超出容器的文本，用来核对来回滚动与停顿时序',
                    ),
                  ),
                  const SizedBox(height: AylaSpacing.sp4),
                  SizedBox(
                    width: 260,
                    // web `LiveRoomBody.tsx:257 / 325`：只有直播间的可见范围标签传 `title`
                    //（悬停读完整列表）；其余 ScrollingTags 调用点在 web 上都不带 title。
                    child: AylaScrollingTags(
                      title: '公开、好友可见、指定群可见、我的收藏、更多标签',
                      children: <Widget>[
                        AylaCapsuleTag('公开'),
                        AylaCapsuleTag('好友可见', tone: AylaCapsuleTone.ice),
                        AylaCapsuleTag('指定群可见', tone: AylaCapsuleTone.glass),
                        AylaCapsuleTag('我的收藏', tone: AylaCapsuleTone.pink),
                        AylaCapsuleTag('更多标签', tone: AylaCapsuleTone.indigo),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: AylaSpacing.sp6),

            // ---------- B3 卡片族（窄屏组件） ----------
            _Section(
              title:
                  'GroupCard / GroupCarousel（home.css 224–503 + auroraqua 29–52）',
              source:
                  '玻璃卡 16 圆角 · 4:3 轮播内嵌 8 · 3s/300ms · 指示点 4px · hover -2px + shadow-hover · active .99',
              child: const _GroupCardDemo(),
            ),
            const SizedBox(height: AylaSpacing.sp6),

            // ---------- B4 通用基元 ----------
            _Section(
              title: 'AylaResourceImage（AylaResourceImage.tsx + api/media.ts）',
              source:
                  '签名链路（缓存至到期前 60s / 并发只签一次 / 原图 410 降级 thumb / thumb 410 过期）· alt="" 装饰图失败不提示',
              child: const _ResourceImageDemo(),
            ),
            const SizedBox(height: AylaSpacing.sp6),
            _Section(
              title:
                  'AylaConfirmDialog / AsyncState（AylaConfirmDialog.tsx + AsyncState.tsx）',
              source:
                  'create-sheet 弹层复用（overlay .25 + glass-bg-strong + radius-panel 20 + modal 阴影）· 窄屏贴底 · 自动聚焦取消 · busy 禁全部关闭',
              child: const _DialogsDemo(),
            ),
            const SizedBox(height: AylaSpacing.sp6),
            _Section(
              title:
                  'PullToRefresh / AylaSignedVideo（PullToRefresh.tsx + AylaSignedVideo.tsx）',
              source:
                  '阻尼 dampPull = maxPull*(1-e^-dy/90) · 阈值用原始 dy · 36 玻璃圆点三态 · thumbnail 不可作 video src',
              child: const _InteractionDemo(),
            ),
            const SizedBox(height: AylaSpacing.sp6),
            _Section(
              title:
                  '分页族 / 收藏按钮（DirectoryLoadMore + AylaStablePaginationFooter + FavoriteButton）',
              source:
                  'stable-pagination-footer min-h 80（最高高度锁定不塌缩）· 三点 6px ice-500 · favorite-toggle 36/pill/glass-bg-strong，选中转 pink+辉光',
              child: const _PaginationAndFavoriteDemo(),
            ),
            const SizedBox(height: AylaSpacing.sp6),
            _Section(
              title:
                  'AylaAuthCodeRow（auth.css 89–103 + RegisterPage.tsx 143–155 / PrivacySheet）',
              source:
                  '验证码输入 + 发码键并排（gap sp2）· 字段 flex 1 / min-width 0 / 44 高 / 认证描边 /'
                  ' 数字键盘 + maxLength 6 + 过滤非数字 · 发码键 .btn-ghost 44 高；注册页档再传'
                  ' `.auth-code-btn` 的 min-width 104 + padding-inline sp3；禁用 / aria-invalid 两档已入样张',
              child: aylaAuthCodeRowSamples(),
            ),
            const SizedBox(height: AylaSpacing.sp6),
            _Section(
              title: 'AylaAuthOptions（登录表单开关 · 新增功能，web 无对应）',
              source:
                  'web `LoginPage.tsx` 全 95 行**没有**这两个控件 ⇒ 新增件，不是复刻；视觉与交互沿用既有规范：'
                  '复选框 = AylaCheckbox（16×16 + accent-color，规格源 app.css:161–167 的 '
                  '.visibility-selector-options input[type=checkbox]；两者根同为 label 内复选框，'
                  '共用 app.css:117–133 的行规格）· 行 label = AylaTextStyles.label（14 / w700 / ls .2 / '
                  '--text-primary，等价 auth.css:64–72 的 .auth-field）· 行 min-height 40（app.css:117–133）· '
                  '行内 gap sp2（.auth-field gap）· 行间距 sp4（.auth-form gap，auth.css:63）· '
                  'focus 环 = base.css:365–370 的 :focus-visible（outline --focus-ring、offset 2）。'
                  '联动只写一处：勾「自动登录」⇒ 记住密码同时勾；取消「记住密码」⇒ 自动登录一并取消。'
                  '⚠️ 记住密码未勾时自动登录行是**禁用视觉**（灰文案 + 未勾）但**仍可点**，点了会把记住密码一并打开。'
                  '四档静态 + 一档可点联动演示（点了看两个开关是否同时开/关）。'
                  '⚠️ 本件为纯色/现有件，不含玻璃卡（画布离屏层预算）。',
              child: aylaAuthOptionsSamples(),
            ),
            const SizedBox(height: AylaSpacing.sp6),
            _Section(
              title: 'VisibilitySelector / 资料卡 / 筛选条 / 隐私设置',
              source:
                  '公开↔好友互斥、群可见独立可叠加 · user-profile-card min(320,85vw)+sp6+modal 阴影 · directory-filters 224 侧栏 · privacy-sheet 60dvh 窄屏 + 两步换绑',
              child: const _DirectoryAndProfileDemo(),
            ),
            const SizedBox(height: AylaSpacing.sp6),

            // ---------- B3 chat 域第一批（气泡 / 媒体 / 分享卡 / 爱莉入口） ----------
            _Section(
              title: '聊天消息气泡（MessageBubble.tsx）',
              source:
                  'app.css 1041–1102：.msg-row gap 8 / align-end · .msg-body max 75%（窄屏 84%）· '
                  '气泡 padding 10/14 · radius 18（自己右下 6 / 他人与爱莉左下 6）· '
                  '他人玻璃底 blur12（无 saturate）· 操作栏 hover/focus/触屏三条件 · frost-rise 180ms',
              child: SizedBox(
                width: 760,
                height: 980,
                child: aylaMessageBubbleSamples(),
              ),
            ),
            const SizedBox(height: AylaSpacing.sp6),
            _Section(
              title: '媒体消息族（MediaContent.tsx）',
              source:
                  'app.css 1383–1639 / 1839–1979：媒体帧 radius-input · 图片 max 320 且不放大 · '
                  '表情 96×96 · 播放键徽标 48 玻璃 blur8 sat1.4 · 语音卡 min-w 240 + '
                  'seek 4px 轨/12px 拇指 · 文件卡 min 240 / max 320 · 混排 180 方块 + 240×180 视频',
              child: SizedBox(
                width: 760,
                height: 1180,
                child: aylaMediaContentSamples(),
              ),
            ),
            const SizedBox(height: AylaSpacing.sp6),
            _Section(
              title: '分享卡 / 爱莉入口卡（ShareBubble.tsx + ElysiaEntry.tsx）',
              source:
                  'app.css 1138–1223：卡片 min(264,100%) · 封面 72 · 标题 15/700 两行 · hover -1px + '
                  '0 4px 16px rgba(70,91,146,.2) · :disabled opacity .7（按颜色降透明）· '
                  'app.css 435–478：入口卡 135deg 樱粉 + 1px rgba(247,150,255,.5) + hover 辉光（窄屏降 30%）',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  SizedBox(width: 640, child: aylaShareBubbleSamples()),
                  const SizedBox(height: AylaSpacing.sp6),
                  SizedBox(width: 420, child: aylaElysiaEntrySamples()),
                ],
              ),
            ),
            const SizedBox(height: AylaSpacing.sp6),

            // ---------- B3 chat 域第二批（会话列表 / @ 选择器 / 群表情包） ----------
            _Section(
              title: '会话列表（ConversationList.tsx）',
              source:
                  'app.css 490–543：行 padding 12 / padding-right 52 / 圆角**实际 12**（auroraqua 172 覆写 16）· '
                  'hover .18 / 选中 .35 · 置顶粉底 + 左 3px 辉光竖条 · 545–617 标题 15/700 + 状态胶囊 '
                  '（6px 圆点）/ 预览 13 · 693–706 未读徽标 20×20 utility 12 w500（AylaTabBadge convUnread 档）· '
                  '选中胶囊容器级 300ms 迁移（可点切换）',
              child: aylaConversationListSamples(),
            ),
            const SizedBox(height: AylaSpacing.sp6),
            _Section(
              title: '@ 成员选择器（MentionPicker.tsx）',
              source:
                  'app.css 2364–2428：glass-bg-strong + blur24 sat1.4 + 1px 边 + radius 16 + --glass-shadow · '
                  '列表 padding 4 · 行 padding 8/12 + gap 12 + radius 8（hover/focus 同款 .35）· '
                  '名称 14/600 · 空态「无匹配成员」· 定位 edge 8 / gap 8 / 高上限 280（↑↓ 循环、ESC 关闭）',
              child: aylaMentionPickerSamples(),
            ),
            const SizedBox(height: AylaSpacing.sp6),
            _Section(
              title: '群表情包面板（EmojiPackPanel.tsx）',
              source:
                  'app.css 2186–2323：面板 max-h 280 + padding sp3 + gap sp2 + glass-bg-strong/blur24 sat1.4/'
                  'radius 16 · 网格 minmax(56px,1fr) gap 8 · 格 aspect 1 / radius 8 / 1px 边 / surface 底 · '
                  'hover 边 --glow-500 + --glow-shadow · 图片 object-fit contain · 加号虚线边 · '
                  '删除键 18 圆（上右 -5，hover 显示）'
                  ' · **2026-09-28 收尾轮补分页入口**（EmojiPackPanel.tsx:227–228）：复用 AylaDirectoryLoadMore，'
                  '六传参逐条对齐（loading=!metaLoaded||pages.loading · error=metaError??pages.error · invalidated=false · '
                  'loadMore=metaError?refresh:pages.loadMore · retainCompletedSpace=false）⇒ 样张多出「有下一页（页脚加载更多）」一档；'
                  '空态按 tsx 230 逐字（删掉自加的 !_uploading）+ 补 app.css 2318 的 padding sp3 0；原「自造加载圈」按 1:1 口径删除',
              child: aylaEmojiPackPanelSamples(),
            ),
            const SizedBox(height: AylaSpacing.sp6),

            // ---------- B3 chat 域第三批（输入区 / 消息滚动区） ----------
            _Section(
              title: '消息输入区（MessageInput.tsx）',
              source:
                  'app.css 1983–2185：`.composer`（窄屏方角 + blur18 sat1.4 + 上边框）/ '
                  '宽屏 auroraqua 347–358 浮卡（padding 8 / radius 16 / glass-shadow）· 工具键 40×40 '
                  'radius 12 玻璃档（auroraqua 105–112）· 编辑器 min-h 40 / max-h 140 / padding 8 12 / lh 22 · '
                  '引用条 2484–2527 · 待发媒体 2001–2093（44/58 缩略图 + 18 圆移除键）· 录音态 2431–2483 · '
                  '@ 编辑器 = `\\uFFFC` 占位 + 胶囊渲染（web contentEditable 的等价） · '
                  '**2026-09-29**：新增 `gutter` 档 = 宽屏 `margin: var(--sidebar-gutter)`（12，auroraqua 347–359）；'
                  '左归零由**调用方按容器**给（私聊面板 `.wide-messages-pane .composer` 361–368），默认不表达',
              child: aylaMessageInputSamples(),
            ),
            const SizedBox(height: AylaSpacing.sp6),
            _Section(
              title: '消息滚动区（MessageList.tsx）',
              source:
                  'app.css 799–1037：`.message-scroll` padding sp6 + `.message-column` max-width 960 居中 · '
                  '时间分隔（> 5 分钟，utility 12）· 戳一戳居中胶囊（rgba(126,149,189,.14) + blur8）· '
                  '跳转标签 911–962（粉边玻璃胶囊，上/下两条）· 回底键 44 圆（超过一屏才显示）· '
                  '高亮 1.6s 粉框辉光 · 历史控制 min-h 40；列表用 `reverse: true` 表达前插不跳动',
              child: aylaMessageListSamples(),
            ),
            const SizedBox(height: AylaSpacing.sp6),

            // ---------- B3 chat 域第四批（选项卡 / 认证面板 / 私聊面板） ----------
            _Section(
              // 2026-09-25：用户手动删掉了本节的窄屏竖排样张 ⇒ 标题尾部的 `·` 残片一并收干净
              title: '消息中心选项卡（messages-tabs；WideMessagesSidebar 与 QuickMessagesSheet 共用）',
              source:
                  'messages.css 17–55 + auroraqua 273–285：容器 1px 边 + radius-card 16 + '
                  '**只有 --glass-inset 内高光（无外阴影、无底色）** + margin sp2 / padding sp1 · '
                  'tab 40 高 / radius 12 / 14/700，**选中底由共享胶囊提供**（auroraqua 194–197 取消自身底）· '
                  '徽标复用 `AylaTabBadgeMetrics.messages`（min 18 / padding 0 5 / utility 11 + glow-shadow）· '
                  '宽度按 `flex: 1` 等宽（LayoutBuilder 算每项宽）',
              child: aylaMessagesTabsSamples(),
            ),
            const SizedBox(height: AylaSpacing.sp6),
            _Section(
              title: '认证消息面板（WideMessagesSidebar / QuickMessagesSheet 共用）',
              source:
                  'messages.css 83–143 / 199–205：分组标题 15/700 + gap sp2 · 行材质 `--glass-bg` + 1px 边 + '
                  '--glass-filter + --glass-shadow-compact（padding sp2 sp3 / radius 12 / gap sp3）· '
                  '`.request-btn` min-h 32 · 空态「暂无待处理认证消息」· 好友行 `.friend-row` 同材质 + 解除好友键',
              child: aylaRequestsPanelSamples(),
            ),
            const SizedBox(height: AylaSpacing.sp6),
            _Section(
              title: '私聊面板（PrivateChatPane.tsx）',
              source:
                  'private.css 8–64 + auroraqua 402–410：头部恒 56 高 / padding sp2 sp4 / gap sp3 · '
                  '窄屏通栏（--glass-bg + blur18 sat1.4 + 下边框）/ 宽屏**卡片化**（1px 边 + radius 16 + '
                  'compact 阴影 + blur24）· 标题 15/700 + 状态 12（**typing → glow-500**）· '
                  '非好友禁发 `.private-chat-blocked` 替换输入区（warning-soft 底/边） · '
                  '**2026-09-29 收口（用户窄屏/宽屏验收）**：① 宽屏头部补 `margin: var(--sidebar-gutter)` = 12（左归零，'
                  'auroraqua 402–409 + 361–368）；② 新增 `panelMotion` 三区编排档（head=top / 消息区=right→left / '
                  '输入区=bottom；tsx:177–242 + auroraquaMotion 37–51）—— 宽屏样张升级为**可交互**（重播进场 / 在场⇄退场切换）',
              child: aylaPrivateChatPaneSamples(),
            ),
            const SizedBox(height: AylaSpacing.sp6),

            // ---------- B3 chat 域第四批下（宽屏左列 / 快捷消息栏） ----------
            _Section(
              title: '宽屏消息左列（WideMessagesSidebar.tsx）',
              source:
                  'messages.css 243–279：332 玻璃侧栏卡（`AylaSidebarCard`）· 三 tab（私信/好友/认证 + 徽标，'
                  '`AylaMessagesTabs`）· 各 tab 内容区 `flex:1 + min-height:0 + overflow-y:auto` + '
                  'padding sp2 sp2 sp4（**侧栏自身不滚动**，滚动归内容区 · `scrollable: false`） · '
                  '**2026-09-29 收口**：`margin: var(--sidebar-gutter)` = 四边 12（messages.css:255，此前只登记未表达）—— '
                  '由 `AylaSidebarCard.gutter` 表达（默认 0，以免动到目录页 `.directory-filters` 的 `margin: 0 0 sp3`） · '
                  '**切 tab 会播面板进场**（web `useTabPanelMotion`：新面板自右 +20 淡入 300ms，旧面板瞬时消失）',
              child: aylaWideMessagesSidebarSamples(),
            ),
            const SizedBox(height: AylaSpacing.sp6),
            _Section(
              title: '快捷消息栏（QuickMessagesSheet.tsx）',
              source:
                  'messages.css 343–425：上 30% 遮罩（rgba(70,91,146,.25) 点击关闭）+ 下 70% 面板'
                  '（glass-bg-strong + blur24 sat1.4 + 上边框 + **radius 24 24 0 0** + --glass-shadow-modal + '
                  'slide-in 250ms）· 头部 padding sp3 sp4 + 下边框（tabs padding 0）· ESC 关闭走全局键盘监听 · '
                  '私信 tab 点会话 → **内联**打开私聊面板（不跳路由） · '
                  '**切 tab / 进内联私聊都播一次面板进场**（web `QuickMessagesSheet.tsx:55`，selection = `activeChatId ?? tab`）',
              child: aylaQuickMessagesSheetSamples(),
            ),
            const SizedBox(height: AylaSpacing.sp6),

            // ---------- 页面层第 4 批（消息域页面骨架与宽屏右列） ----------
            _Section(
              title:
                  'AylaMessagesPage / AylaWideMessages / AylaWideMessagesPane（messages.css 9–15 / 207–212 / 236–241 / 281–291 / 324–339 + 83–94 / 63–68 / 199–205）',
              source:
                  '消息域**页面骨架**（19 号 §7.5 range B 的 B 类「页面内联件」）：'
                  '窄屏 `.messages-page` = column + `padding-bottom: 68px`（避让悬浮 FAB；Flutter 侧与已交付 HomePage 同口径加安全区）· '
                  '≥769 = row + `padding-bottom: 0` · `.wide-messages` = row + `overflow: hidden`（/chat/:id 外壳）· '
                  '`.wide-messages-pane` = `flex: 1` + min-w/h 0，`> .private-chat { flex: 1 }` · '
                  '`.wide-messages-empty` = 居中两行（placeholder-title 28/600 + placeholder-desc 14）· '
                  '`.messages-group-title` 15/700 + mb sp2 · `.messages-group` gap sp2 · '
                  '`.messages-section-hint` 13/1.5 + `margin-top: -sp2` · `.messages-empty` padding sp4 + 13 secondary',
              child: aylaMessagesLayoutSamples(), // 三档：窄屏页骨架 / 宽屏两列 + 右列空态 / 分组件
            ),

            // ---------- boardgame 域第一批（2026-09-24：B4-1 卡片） ----------
            _Section(
              title:
                  '桌游室卡片（GameRoomCard.tsx 53 行 + boardgame.css 9–119 + auroraqua.css 28–52 + typed-result-cards.css 44）',
              source:
                  '两列/四列网格里的房间卡（games-grid 由页面层排布）· 结构 = relative 容器 + 卡片按钮 + 右上角收藏键（绝对定位 top/right sp2=8、compact 32×32）· 卡面 = --glass-bg + 1px 亮边 + radius 16 + --glass-shadow + overflow hidden + blur24 sat1.4；hover → translate -2 + --glass-shadow-hover（300ms，卡片族专属组）、active → scale .99；focus-visible 走**全局** --focus-ring（#f796ff 2px + offset 2），桌游卡在 web 里没有域内覆写 · 封面 = 16:9 的 --ice-100 底 + --ice-500 图标（IconGame 48，margin 8 8 0、radius 12）· info = gap 2 + padding sp2 sp3 sp3 · 名称 = 单行滚动 15/700/text-primary/lh 1.35 · 状态 tag = pill、padding 1×8、Fredoka 11/ls .8/lh 1.4（playing → sakura-300+grape-700；waiting 与 **ended** → ice-300+indigo-700）· 房主 = 12px secondary（类定义在 typed-result-cards.css 的**裸选择器**里，全站生效）· meta = 人数（flex 0 0 auto + nowrap，仅 number 时渲染）+ 来源标签横向滚动（flex 1 1 auto + min-width 0）· 来源标签按用户裁决**并入统一档 AylaSourceTag**（web 的 .game-room-source 是 display 11/ls .8 的独立规格，不再复刻）· reserveSpace 档 = 网格等高（status/owner/meta 三行恒占位；缺行卡片与满行卡片等高，默认 false 供搜索结果）· reveal 由 revealDelay 非 null 时挂 AylaRevealItem · **样张可交互**：点卡进房、四档单卡（对局中/等待中/极简/action 槽位）+ 网格等高对照',
              child: aylaGameRoomCardSamples(),
            ),
            const SizedBox(height: AylaSpacing.sp6),

            // ---------- boardgame 域第一批（2026-09-24：B4-2 建房间表单） ----------
            _Section(
              title:
                  '创建桌游室表单（GameRoomCreate.tsx 78 行 + boardgame.css 123–132 + app.css 70–79 + private.css 229–236）',
              source:
                  '容器 = flex column + gap sp2 + padding sp3 · 顺序 = 可见性选择器 → 名称输入 → **错误行** → 创建键（与语音表单把错误放最后不同）· 选择器复用 AylaVisibilitySelector（群内 → group + 本群且 lockGroup；一级 → public）· 输入 = AylaGlassInput 的 .field 档（padding 12×16、radius 12、focus → glow-500 边 + --glow-shadow；hint「桌游室名称」、64 上限用 formatter 表达以免多出「0/64」计数器、Enter 提交、**随文本 setState** 以刷新按钮可用性）· 错误 = .post-editor-error（**13px** + --destructive，不是语音表单的 12px）· 提交键 = primary「创建」/「创建中…」，disabled = busy || 空名 · 空名拦截文案「房间名不能为空」**不发请求**、失败保留表单 · sheet 作用域（唯一挂载点 CreateFab 在 CreateSheet 内 ⇒ private.css 恒生效）：输入与按钮 width 100%、输入 margin-bottom sp3 · 请求由页面层 onSubmit 注入 · **样张可交互**：空名看禁用、填名提交看清空与计数、群内档看锁定、失败档看文案与表单保留',
              child: aylaGameRoomCreateSamples(),
            ),
            const SizedBox(height: AylaSpacing.sp6),

            // ---------- boardgame 域第一批（2026-09-24：B4-3 占位整页壳） ----------
            _Section(
              title:
                  '桌游室占位整页壳（GameRoomPlaceholder.tsx 189 行 + boardgame.css 136–219 + auroraqua.css 335/402–408/418）',
              source:
                  '进入房间后的整页框架（玩法后续）· head 两档：**≤768** 通栏玻璃条（--glass-bg + blur18 sat1.4 + 下边框、无圆角无外边距）、**≥769** 卡片化（margin --sidebar-gutter 12 + radius 16 + --glass-shadow-compact + blur24）；两档都有 auroraqua-panel-from-top 入场（translate 0 -20px + fade 300ms ease-out），reduced-motion 关闭 · head 内容 = 返回键 .icon-btn-40（IconBack 20）+ 名字（Fredoka 18 单行省略）+ 分享（AylaShareButton 32）+ 收藏（compact），行高恒 40 ⇒ head 高恒 64（两档恒定）· body = flex 1 + 居中 + gap sp3 + padding sp6 + **safe center**（不满一屏居中、超出可滚）· 内容 = 说明 14/secondary + 人数·房主（utility 13/text-primary）+ 错误行（13 destructive）+ 房主控制 + 加入/离开 · 房主控制 = width min(100%,680) + gap sp3 + 左对齐（web 无 align-items ⇒ 删除键全宽）+ 成员行（排除自己；名字 flex 1 1 120px；「移出」「转让房主」ghost，actionBusy 时一起禁用）+ 分页（AylaDirectoryLoadMore）+「删除房间」（destructive、全宽）· 删除确认复用 AylaConfirmDialog（标题「删除桌游房间」+「确定删除桌游房间「房名」？此操作不可撤销。」）· 加入（primary）/ 离开（ghost）两态 + busy 文案 · **web 组件内直接调 API 的 join/leave/成员操作与竞态守卫改为全注入**（与 live/voice 整页壳同范式）· **样张可交互**：点删除房间看确认弹窗、切成员/非成员看底部键、窄屏 375 档看通栏 head',
              child: aylaGameRoomPlaceholderSamples(),
            ),
            const SizedBox(height: AylaSpacing.sp6),

            // ---------- group 域第一批（2026-09-24：B5-1 子群弹窗） ----------
          _Section(
            title:
                '子群弹窗（SubGroupDialog.tsx 111 行 + group.css 2131–2231）',
            source:
                '添加/编辑子群弹窗 · overlay 遮罩 .18 + blur3（窄屏也居中）· 卡片 min(360px) + padding sp6 + radius 20 + glass-bg-strong · title display 18/w500 + icon-btn-40 · 名称 input.field（64 上限 formatter / autoFocus）· 禁言行仅 edit（整行可点，checkbox 18×18）· 错误 13 destructive · 按钮排 = 删除靠左（默认组禁用）+ 取消 + 确定（busy「保存中…」）· 二次确认归调用方 · 样张可交互',
            child: aylaSubGroupDialogSamples(),
          ),
          const SizedBox(height: AylaSpacing.sp6),

          // ---------- group 域第一批（2026-09-24：B5-2 群聊申请） ----------
          _Section(
            title:
                '群聊申请弹窗（GroupApplyDialog.tsx 25–137 行 + search.css 175–296）',
            source:
                'Form（弹窗/守卫卡共用）= desc 14/1.6（公开群/申请制两档；join_policy 未知按申请制）+ label + textarea（min-height 104 / 200 上限）+ 错误 13 + 提交键（accepted → onDone；否则成功态：圆 48 success + glow + ✓）· Dialog = 遮罩 .28、卡片 min(440px) + radius 16 + modal 阴影、head = kicker（utility 11 / ls 1.2 / pink-500）+ h2 display 22 + 文字「×」· ⚠️ web 的第三个形态 GroupApplyGate（GroupPage.tsx:398 的路由守卫卡）**按裁决不实现**（属页面层路由守卫，且 web 实渲染里 head 无左右 padding）· 提交与跳转全注入（未注入即禁用）· 样张可交互',
            child: aylaGroupApplySamples(),
          ),
          const SizedBox(height: AylaSpacing.sp6),

          // ---------- 顶层散件（2026-09-25：B6-1 建群对话框） ----------
          _Section(
            title:
                '建群对话框（GroupCreateDialog.tsx 184 行 + private.css 66–186 / 188–280）',
            source:
                '弹层与卡片**与 CreateSheet 同规格**（private.css 明写共用同一段）⇒ 直接复用 AylaModalOverlay + AylaModalCard（480 / 80vh / padding sp4 / 窄屏贴底上滑）+ AylaSheetHead（title display 18/w600 + icon-btn-40 + IconClose 18）· 群名 input.field（必填 / autoFocus）+ 成员搜索（左搜索图标 15 + 输入 padding-left 34 / margin-top sp2）+ .field-error 13 destructive + 已选 chips（复用提升后的 AylaGroupChip：pill / ice-100 / 12-600 / 叉 16×16 hover destructive）+ 结果列表（max-height 220 自滚；行 = 16×16 checkbox + 名称 14/600 省略 + 幽灵「私聊」32/12；勾选行整行可点 = web label）+ 建群键（primary 全宽 / IconPlus 16 / 「建群（N 人）」/ disabled = busy 或群名空）· 搜索 **300ms 防抖**；结果仅在 q == searchQuery 时可见 · 空态「没有匹配的用户」照实无 padding（.search-empty 用了未定义的 --sp-10 ⇒ 整条作废）· 请求与跳转全注入（未注入即禁用）· **样张可交互**：打字试防抖搜索、勾选进 chips、开关切「下一次建群失败」看错误行',
            child: aylaGroupCreateDialogSamples(),
          ),
          const SizedBox(height: AylaSpacing.sp6),

          // ---------- 顶层散件（2026-09-25：B6-2 目录结果卡） ----------
          _Section(
            title:
                '目录结果卡（DirectoryResultCards.tsx 119 行 + typed-result-cards.css）',
            source:
                '两个卡：**群结果卡**（.typed-group-card：玻璃卡 + padding sp4/窄屏 sp3 + radius-card + compact 阴影 + blur24；Avatar 44 + 标题 + meta「N 人 / 公开群聊 / 申请制群聊」12px secondary + 可选入口文案 + action 槽位）· **收藏结果卡**（按 target_type 分派到既有 post/live/voice/game 卡并传 action；**投影缺失 = 内容不可用**（.typed-unavailable-card，按钮 disabled）；message 情形自绘 .typed-message-card：IconMessage 18 + 昵称/「消息」13px + 正文三态（已撤回 / 戳一戳 / blockquote 原文，ice-100 + padding sp3 + radius-input）+ 媒体区独占一行复用 AylaMediaContent（点媒体不跳转），整卡 canOpen 时可点）· .typed-result-card 只是宽度归一 ⇒ Flutter 侧由各卡自身表达，不新造空壳容器 · 附带补档：**live 卡补 action 槽位**（web tsx 56 用它换「取消收藏」直删键）· 样张静态展示四档（群卡 meta 两档 / 消息文本 / 已撤回 / 不可用）',
            child: aylaDirectoryResultCardSamples(),
          ),
          const SizedBox(height: AylaSpacing.sp6),

          // ---------- 在线胶囊（2026-09-28：由 user_profile_page 私有件提升） ----------
          _Section(
            title:
                'AylaProfilePresence（profile.css 558–570 + UserProfilePage.tsx 142–144）',
            source:
                'padding 2×sp3 · pill · 12/w600 · 静息底 --ice-100 + 字 --text-secondary；'
                '`.is-online` ⇒ 底 --sakura-300 + 字 --grape-700 · 文案由调用方注入（后端 display_status 兜底）',
            child: aylaProfilePresenceSamples(),
          ),
          const SizedBox(height: AylaSpacing.sp6),

          // ---------- 顶层散件（2026-09-25：B6-3 个人主页内容分区） ----------
          _Section(
            title:
                '个人主页内容分区（ProfileContentSections.tsx 211 行 + profile.css 174–380）',
            source:
                '顺序完整卡片（不折叠、不叠卡：外层透明 + 每类一张玻璃卡）· 四张卡 = 正在直播（LIVE 徽标 pink-500 / 封面 88×50 或 ice-100 占位 IconVideo 20 / 副行「主播 正在直播」）· 正在语音（badge **仅 member_count > 0**「N 人在麦」utility 12 / 36×36 ice-100 图标块 IconMic 18 / 副行「主播 的语音房」）· 帖子（badge 数字 utility 12 / loading = 三条高 44 骨架 / error 与空态 13px secondary（mine「还没有发帖」/ 他人「暂无帖子」）/ 行 = 标题或正文前 40 + 副行「正文前 40 · 时间」/「更多帖子」ghost 36 高左对齐）· 桌游占位（rgba(255,250,251,.4) 圆角块 + IconGame 28 + 「桌游玩法即将上线」）· 卡片 head = 图标 16（**--ice-500**）+ 标题 14/700 + badge；内容行三处共用（静息 rgba(255,250,251,.4) → hover ice 蓝 .18 + 边，180ms）· 直播/语音宽屏并排（各 flex 1）、**≤768 单列** · formatTime 四档（刚刚 / N 分钟前 / N 小时前 / 日期 zh-CN）· 数据与跳转全注入 · **样张三档**：全内容（直播+语音并排+3 帖+桌游占位）/ loading 骨架 / error 文案',
            child: aylaProfileContentSectionsSamples(),
          ),
          const SizedBox(height: AylaSpacing.sp6),

          // ---------- 顶层散件（2026-09-25：B6-4 覆盖层滚动条，B6 收官） ----------
          _Section(
            title:
                '覆盖层滚动条（OverlayScrollbar.tsx 311 行 + base.css 385–421）',
            source:
                'web 用 document 级事件委托 + body 挂 fixed thumb；Flutter 等价 = NotificationListener 包住子树（滚动通知向上冒泡）+ 自身 Stack 槽位画条 + MouseRegion 判悬停 + GestureDetector 拖拽 ⇒ **页面层要包在应用根**· 常量逐条照 web：THICKNESS 4 / OFFSET 2 / PAD 3（视觉条 4px + 四边 3px 透明命中区）/ MIN_VERT 28 / MIN_HORZ 48 / 停滚 **600ms** 淡出（悬停与拖拽期间不淡出）/ thumb 长 = round(track²/scrollSize) / 静息 rgba(126,149,189,.38) → hover .55 / 显隐 180ms ease-out（reduced-motion 无过渡）/ **窄屏 ≤768 完全不显示** · 样张：420×320 可滚列表，滚动即出细条，停 600ms 淡出 · ⚠️ 定向测试待补',
            child: aylaOverlayScrollbarSamples(),
          ),
          const SizedBox(height: AylaSpacing.sp6),

          // ---------- 排版阶梯 ----------
            _Section(
              title: 'Typography（design.md §3 九级）',
              source:
                  'Display=Fredoka / Body=Nunito / Utility=Space Grotesk，CJK 回退链',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text('Display Hero 40/600 · Ayla 爱莉', style: t.displayHero),
                  Text('Page Title 28/600 · 语音大厅', style: t.pageTitle),
                  Text('Card Title 20/500 · 静态玻璃卡', style: t.cardTitle),
                  Text('Bubble / Body 15/400 · 聊天正文示例', style: t.body),
                  Text('Body Strong 15/700 · 昵称加粗', style: t.bodyStrong),
                  Text('Label / Button 14/700 · 登录按钮', style: t.label),
                  Text('Caption 13/400 · 次要说明文字', style: t.caption),
                  Text('Timestamp 12/400 · 21:10', style: t.timestamp),
                  Text('MICRO TAG 11/500 · 新内容', style: t.microTag),
                ],
              ),
            ),
                    // ---------- 通用开关（群档 + 个人档；2026-09-28 收尾轮提升为公共件） ----------
                    _Section(
                      title:
                          'AylaSwitch（通用开关 —— group.css 1924–1993 群档 + profile.css 400–434 个人档 + base.css 6–7）',
                      source:
                          '以群信息域 AylaGroupInfoSwitch（44×24 / thumb 18）为正确基准提升；个人档 48×28 / knob 20。'
                          'compact：--ice-300 底 + **--glass-inset 顶沿内高光** → 选中 --pink-500 · thumb --surface '
                          '+ 0 1px 3px rgba(70,91,146,.3) · 禁用整轨 **.6** · :focus-visible = --focus-ring（offset 2）；'
                          'regular：--glass-bg-strong（**无 backdrop-filter**）+ 1px --glass-border → 选中 --sakura-300 '
                          '+ --glow-shadow · knob --ice-300 → --grape-700 · 禁用 **.55**。'
                          '⚠️ **1px 边框补偿**（本轮修的 bug：个人档 knob 偏上 1px）：CSS 绝对定位子级的包含块是 '
                          'padding box（base.css 6–7 全局 box-sizing: border-box ⇒ 48×28 含边框）⇒ top/left 3px 实际距'
                          '外框 4px（中心 4+10 = 14 = 28/2）；旧实现按外框 3 ⇒ 中心 13。'
                          '点击语义：web 两处都被 <label> 包住 ⇒ 行装配传 ownTap: false（本体只保留 Focus 键盘），'
                          '行手势一次点击只切一次（样张第 ③ 行有点击计数）。'
                          '本节点名四档：compact/regular × off/on，另有禁用、focus 环与行装配档。',
                      child: aylaSwitchSamples(),
                    ),
                    // ---------- 群信息右列 / 管理卡三件（2026-09-28 收尾轮 B2） ----------
                    _Section(
                      title:
                          'AylaGroupInfoSectionTitle / AylaGroupInfoCardHead / AylaGroupInfoDangerActions（GroupInfo.tsx 523–526/628–645/651–663/748–752 + group.css 1610–1675/2050–2107）',
                      source:
                          '① 区块标题（.group-info-section-title）：flex · center · gap sp2 · margin-bottom sp3 · '
                          'font-display 17 / w500 / --text-primary · 前置 svg（web <IconMenu 18>）--text-secondary · '
                          '文案两档「管理 / 更多」。'
                          '② 卡头（.group-info-card-head）：flex · center · gap sp2 · margin-bottom sp3；图标 18 恒 '
                          '--text-secondary；标题 display 17 / w500；计数胶囊（.group-info-count）min-width 20 / height 20 / '
                          'padding 0 6 / pill / rgba(157,191,230,.32)（--ice-500 @32%）/ --indigo-700 / utility 11 / w500 / '
                          'line-height 20；在线行（.group-info-online）margin-left auto · gap 5 · 12 / --text-secondary + '
                          '::before 6×6 --success，文案逐字「已载入成员在线 {N}」；头部动作（.group-info-head-action）'
                          'margin-left auto · min-h 30 · padding 2 12 · 12px · pill · ghost（web「编辑子群」+ aria-label）。'
                          '⚠️ 在线行与头部动作都靠 margin-left auto 推右，web 两处调用互斥（子群卡出动作、成员卡出在线）。'
                          '③ 危险操作（.group-info-danger + .group-info-action-row）：column · gap sp2 · 每行 width 100% / '
                          'min-height 40 ⇒ AylaGlassButton(minHeight: 40, expand: true)；三档逐字 owner「转让群主」ghost + '
                          '「解散群聊」destructive / 非 owner「退出群聊」；'
                          '**逐键 busy/disabled 语义不同（2026-09-28 独立审计更正）**：转让无 disabled、解散只切「解散中…」不禁用、'
                          '退出切「退出中…」且 disabled = (busyAction !== null)（任意管理动作在途都禁）；回调全空 ⇒ 不渲染。'
                          '另：区块标题与卡头标题都是 web 的 <h3> ⇒ Semantics(header: true)。',
                      child: aylaGroupInfoManageSamples(),
                    ),
                    // ---------- 群信息右列两卡 + 两列布局三件（2026-09-28 收尾轮 B2） ----------
                    _Section(
                      title:
                          'AylaGroupInfoLayout / AylaGroupSubgroupList / AylaGroupMemberList（GroupInfo.tsx 401–405/670–790/1012–1018 + group.css 1421–1459/1461–1465/1690–1732/1752–1787/2062–2128）',
                      source:
                          '① 布局（.group-info-layout）：单列 minmax(0,1fr) + gap sp3（1422–1427）；≥769 两列 clamp(280px,32%,340px) '
                          'minmax(0,1fr) + gap sp4（1439–1452）；**769–1000 退回单列**（1454–1459）；side/main 各自 flex column + gap + min-width 0；'
                          '.group-info-main 的 container-type: inline-size（1437）在 Flutter 无等价物 ⇒ LayoutBuilder 算列宽 + InheritedWidget '
                          '下发「主列 inline-size」供 @container 判据；进场照 auroraqua 324–332/429–434（≥769 侧 −20x / 主 +20x；≤768 都 +20y；reduced 关）；'
                          'loading = padding sp4 + 三块 height 64 骨架（1461–1465 + tsx 401–405）。'
                          '② 子群（.group-info-subgroup*）：行 gap sp3 / padding sp2 sp3 / radius-input / transition 180ms + hover ice-500@.14（1690–1710）；'
                          '名 14-w600-textPrimary 省略；默认组 = AylaGroupRoleChip(owner,「默认组」)；'
                          '⚠️ 禁言 chip 是 **318–331 与 2062–2067 合并**（前者给 ice-300 底 + 1px 6px + Display + lh 1.4，后者只覆写 11/w700/secondary）'
                          '⇒ 真实渲染是「灰底胶囊 + 次要色 11 粗体」而非纯文本；未读（>0）复用 AylaTabBadge serverItem 档（min16/h16/pad 0 4/pink-500/#fffafb/Display 11/lh16，'
                          '与 .server-item-badge 同值 ⇒ 未扩档），>99 显「99+」而 aria-label 用原始计数；编辑键 32×32/radius-input/textSecondary + hover ice-500@.18 + '
                          '**tsx 内联铅笔 14**（GroupInfo.tsx 1012–1018，不在 icons.tsx ⇒ 私有自绘，与 channel_sidebar 私有件同 path，待裁决）；'
                          '编辑态两键 flex 1 / min-h 36 / 13px（primary「+ 添加子群」+ ghost「完成」）；空态三档逐字「加载中…/子群加载失败/暂无子群」。'
                          '③ 成员（.group-info-member*）：头像 AylaAvatarHalo 窄屏 36/宽屏 40 +「查看 X 的个人主页」；「我」chip = 1px 8px/pill/sakura-300@.28/Display 11/grape-700；'
                          '角色 chip 复用（member 不出）；操作区条件 canManage && 非自己 && 非 owner，≥769 opacity 0、行 hover / :focus-within ⇒ 1'
                          '（Flutter 用 FocusNode.descendants 判定），窄屏常显；按钮 min-h 30/pad 2 12/12px/pill，busy ⇒ 全禁用 +「移除中…」；'
                          '**@container ≤420** ⇒ 行换行 + 操作区独占一行右对齐 + opacity 1（容器是主列、卡内距 sp4 ⇒ 判据把卡内距加回 32）；'
                          '空态三档「加载中…/成员加载失败/没有匹配的成员」。'
                          '样张铺开：宽屏两列（视口 1440×内容 1120 ⇒ 左 340）/ clamp 下限（800 ⇒ 280）/ 769–1000 单列（视口 900）/ 窄屏单列 375 / '
                          'loading 档 / 子群 5 档 / 成员 4 档（含 ≤420 换行档与 busy 切换）。',
                      child: aylaGroupInfoListsSamples(),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
      ),
    );
  }
}

/// 画布**自带的 Overlay 宿主** —— 2026-10-02 修「组件库一打开就刷 No Overlay widget found」。
///
/// ## 为什么必须由画布自己提供
/// 画布在 `main.dart` 的 `MaterialApp.builder` 里与 `child`（= Navigator）**同级**：
/// ```
/// MaterialApp.builder
///  └─ Scaffold ─ Stack
///      ├─ child   →  Navigator ─ Overlay    ← 应用所有页面的 Overlay 在这里
///      └─ ComponentGallery                  ← Navigator 是它的**兄弟**，够不到
/// ```
/// Navigator 不是画布的祖先 ⇒ 画布子树里按祖先链找 `Overlay` 一律失败，
/// 框架 `widgets/debug.dart:525–553` 的 `debugCheckHasOverlay` 抛
/// `No Overlay widget found`（用户 2026-10-02 实报：一次打开数百条）。
/// 首个命中点是 `widgets/base/tooltip.dart:91` 的 `AylaTooltip` ——
/// 它包的是 Material `Tooltip`，后者 build 期**无条件**断言
/// （框架 `widgets/raw_tooltip.dart:865`）。
/// 同类依赖还有 `OverlayPortal`（菜单 / 下拉 / 选择器）与各件自己的
/// `Overlay.of(context, rootOverlay: true).insert(...)`。
///
/// 回归锁：`test/component_gallery_overlay_test.dart`（修复前 3 条全红）。
///
/// ## 为什么补在画布**内部**
/// - 画布是自成一体的预览宿主（主题 / 极光底 / Localizations 见
///   `theme/preview_theme.dart`）；由它自己兜住 Overlay 依赖，
///   就不必反向依赖 `main.dart` 的装配顺序；
/// - 画布内件插入的浮层**跟随画布裁剪**，不外溢到应用界面。
///
/// ## ⚠️ 必须**同帧**提供（2026-10-02 实测）
/// 不能用「先建子树、再 `addPostFrameCallback` 插 entry」：`Overlay.of` 在
/// **首帧 build** 就被调用（Tooltip 就是），帧后补必然已经报错。
/// `Overlay` 的 `initialEntries` 随子树一起挂载 ⇒ 同帧可见。
///
/// ## ⚠️ entry 的环境：独立子树
/// `Overlay` 的每个 entry 是独立子树，其祖先链只到 `Overlay` 为止 ——
/// 页面里的 `Material` / `DefaultTextStyle` **传不进 entry**。
/// 缺兜底时 entry 内的 `Text` 落到 `DefaultTextStyle.fallback`
/// （双下划线 + 红字 = 用户看到的「莫名其妙的黄线」）
/// ⇒ 走组件库统一入口 [aylaOverlayEntry]（`widgets/base/overlays.dart`）。
class _GalleryHost extends StatefulWidget {
  const _GalleryHost({required this.child});

  final Widget child;

  @override
  State<_GalleryHost> createState() => _GalleryHostState();
}

class _GalleryHostState extends State<_GalleryHost> {
  /// ⚠️ entry **只创建一次**，且 builder 恒读 `widget.child`（不捕获首帧实例）：
  /// [Overlay] 只在 `initState` 采纳 `initialEntries`；若每次 build 新建 entry
  /// 或把 `child` 闭包捕获进去，切换分类（`setState`）后 entry 会一直渲染**旧**子树。
  late final OverlayEntry _entry = aylaOverlayEntry(
    builder: (BuildContext context) => widget.child,
  );

  @override
  Widget build(BuildContext context) {
    return Overlay(initialEntries: <OverlayEntry>[_entry]);
  }
}

/// 布局切换演示（可点击，观察胶囊 300ms 迁移）。
class _LayoutSwitchDemo extends StatefulWidget {
  const _LayoutSwitchDemo();

  @override
  State<_LayoutSwitchDemo> createState() => _LayoutSwitchDemoState();
}

class _LayoutSwitchDemoState extends State<_LayoutSwitchDemo> {
  bool _isCard = true;

  @override
  Widget build(BuildContext context) {
    return AylaLayoutSwitch(
      isCard: _isCard,
      onChanged: (bool v) => setState(() => _isCard = v),
    );
  }
}

/// 选项卡迁移演示（可点击切换，观察共享胶囊 300ms 滑动）。
class _TabsDemo extends StatefulWidget {
  const _TabsDemo();

  @override
  State<_TabsDemo> createState() => _TabsDemoState();
}

class _TabsDemoState extends State<_TabsDemo> {
  int _i = 0;

  @override
  Widget build(BuildContext context) {
    return AylaSegmentedTabs(
      labels: const <String>['私信', '认证消息', '系统'],
      index: _i,
      badges: const <int>[0, 5, 0],
      onChanged: (int i) => setState(() => _i = i),
    );
  }
}

/// 左侧分类导航（复用库内共享胶囊列表件 `AylaNavHighlightList`：选中底迁移 / 按压 / 扫光 /
/// ↑↓ 键盘 / 滚动揭示全套现成）。
class _GalleryNav extends StatelessWidget {
  const _GalleryNav({required this.selected, required this.onSelect});

  final int selected;
  final ValueChanged<int> onSelect;

  @override
  Widget build(BuildContext context) {
    final AylaTextStyles t = AylaTextStyles.of(context);
    final int count = kGalleryCategories.length + 1; // + 未分类
    final int total = kGalleryCategories.fold<int>(
      0,
      (int a, AylaGalleryCategory c) => a + c.prefixes.length,
    );
    return SizedBox(
      width: 216,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          AylaSpacing.sp4,
          AylaSpacing.sp6,
          AylaSpacing.sp2,
          AylaSpacing.sp6,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text('组件库', style: t.pageTitle.copyWith(fontSize: 20)),
            const SizedBox(height: AylaSpacing.sp1),
            Text(
              '$total 个分区 · 按域分类',
              style: t.caption.copyWith(color: AylaColors.textSecondary),
            ),
            const SizedBox(height: AylaSpacing.sp3),
            Expanded(
              child: AylaNavHighlightList(
                itemCount: count,
                selectedIndex: selected,
                onSelect: onSelect,
                semanticLabel: '组件画布分类',
                itemBuilder: (BuildContext context, AylaNavHighlightSlot slot) {
                  final bool fallback = slot.index == kGalleryCategories.length;
                  final String label = fallback
                      ? '未分类（映射遗漏）'
                      : kGalleryCategories[slot.index].label;
                  return _GalleryNavItem(
                    slot: slot,
                    label: label,
                    count: fallback
                        ? 0
                        : kGalleryCategories[slot.index].prefixes.length,
                  );
                },
              ),
            ),
            const SizedBox(height: AylaSpacing.sp3),
            // 导航列底部：把留白换成口径提示（画布只构建当前分类）
            Text(
              '· 只构建当前分类，切回来瞬时\n· 分区标题下即 web 事实源（文件:行）\n· 映射见 kGalleryCategories',
              style: t.timestamp.copyWith(color: AylaColors.textSecondary),
            ),
          ],
        ),
      ),
    );
  }
}

/// 导航项（行高 40 / 圆角 12；选中底由容器级共享胶囊提供 ⇒ 自身不给底）。
///
/// 接线按库内范式（`_ConversationRow` / `_FilterTab`）：按压上报驱动胶囊 `.98`、
/// hover 上报驱动底色、**选中项被指到时直达扫光**、`Focus(focusNode/onKeyEvent)` 接键盘。
/// ⚠️ `slot.slotKey` **不要**再挂到自己的 widget 上：公共件已把同一个 GlobalKey 挂在槽位
/// `KeyedSubtree` 上（重复挂会 `Multiple widgets used the same GlobalKey`，实测）。
class _GalleryNavItem extends StatelessWidget {
  const _GalleryNavItem({
    required this.slot,
    required this.label,
    this.count = 0,
  });

  final AylaNavHighlightSlot slot;
  final String label;

  /// 该分类的分区数（`kGalleryCategories[].prefixes.length`；未分类桶传 0 ⇒ 不显示）。
  final int count;

  @override
  Widget build(BuildContext context) {
    final AylaTextStyles t = AylaTextStyles.of(context);
    return Listener(
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
        child: Focus(
          focusNode: slot.focusNode,
          onKeyEvent: slot.onKey,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: slot.onTap,
            child: Container(
              height: 36,
              alignment: Alignment.centerLeft,
              padding: const EdgeInsets.symmetric(horizontal: AylaSpacing.sp3),
              child: Row(
                children: <Widget>[
                  Expanded(
                    child: Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: t.label.copyWith(
                        color: slot.active
                            ? AylaColors.textPrimary
                            : AylaColors.textSecondary,
                      ),
                    ),
                  ),
                  if (count > 0)
                    Text(
                      '$count',
                      style: t.timestamp.copyWith(
                        color: AylaColors.textSecondary,
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 内容列：按分类决定每个「分区 + 其后空行」的去留。
///
/// - 未访问过的分类 ⇒ **整段不建**（连 Element 都不建）；
/// - 访问过但不是当前 ⇒ `Offstage` + `TickerMode(false)` 保活（不绘制、动画停表、不销毁）；
/// - 当前分类 ⇒ 正常渲染。
///
/// 判据来自 `_Section.title` 的前缀映射（[aylaGalleryCategoryOf]）—— 所以**新增分区必须把前缀
/// 加进 [kGalleryCategories]**，否则它会出现在「未分类（映射遗漏）」里，一眼可见。
class _GalleryColumn extends StatelessWidget {
  const _GalleryColumn({
    required this.children,
    this.crossAxisAlignment = CrossAxisAlignment.center,
  });

  final List<Widget> children;
  final CrossAxisAlignment crossAxisAlignment;

  @override
  Widget build(BuildContext context) {
    final _GalleryScope? scope = _GalleryScope.maybeOf(context);
    final List<Widget> visible = <Widget>[];
    int unmapped = 0;
    for (int i = 0; i < children.length; i++) {
      final Widget child = children[i];
      if (scope == null || child is! _Section) {
        visible.add(child);
        continue;
      }
      final String id = aylaGalleryCategoryOf(child.title);
      if (id == kGalleryFallbackCategoryId) unmapped++;
      if (!scope.visitedIds.contains(id)) {
        // 未访问：不建。若紧跟一个分区间距（sp8 的 SizedBox），一并吞掉，避免留白。
        if (i + 1 < children.length && _isSectionGap(children[i + 1])) i++;
        continue;
      }
      // ⚠️ **两种可见性必须共用同一套包装链**（2026-10-02 实测崩溃）：
      // 原实现「当前分类直接放 child / 非当前套 Offstage + TickerMode」——
      // 两者结构不同 ⇒ 切分类时 Flutter **销毁并重建**该分区的 Element。
      // 而分区里的件可能有**已插入的 Overlay entry** 引用着自己的 BuildContext
      // （例：`AylaServerRail` 的悬停置顶面板 `_popEntry`，见 server_rail.dart:826–841；
      // 画布 Shell 分区的第二个 rail 用 `hovered: 'g3'` 静态注入 ⇒ 一挂载就插 entry）
      // ⇒ 重建时 entry 的 builder 撞上「Looking up a deactivated widget's ancestor
      // is unsafe」，一次打开刷屏。
      // 现在两条路径**结构完全一致**（KeyedSubtree → Offstage → TickerMode → child），
      // 只换 Offstage / TickerMode 的参数值 ⇒ Element 原地复用、不 dispose、不重建。
      visible.add(
        KeyedSubtree(
          // ⚠️ key 用**列表索引**而不是分类 id：同一分类下有多达十几个分区，
          // 用 id 会 Duplicate keys（实测）。索引在同一份 children 上是稳定身份。
          key: ValueKey<String>('gallery-section-$i'),
          child: Offstage(
            // TickerMode 与 Offstage 同形：非当前分类停表（保活的既有语义不变）
            offstage: id != scope.selectedId,
            child: TickerMode(
              enabled: id == scope.selectedId,
              child: child,
            ),
          ),
        ),
      );
    }
    // 「未分类」桶自己报数：**映射完整时必须显示 0**（漏映射的分区会落进来，一眼可见）。
    if (scope != null && scope.selectedId == kGalleryFallbackCategoryId) {
      visible.insert(
        1, // 0 = 画布头
        Padding(
          padding: const EdgeInsets.only(bottom: AylaSpacing.sp6),
          child: Text(
            unmapped == 0
                ? '✓ 无未分类分区（标题前缀映射完整）'
                : '⚠ 有 $unmapped 个分区未分类 —— 把它们的标题前缀补进 kGalleryCategories',
            style: AylaTextStyles.of(
              context,
            ).bodyStrong.copyWith(color: AylaColors.indigo700),
          ),
        ),
      );
    }
    return Column(
      crossAxisAlignment: crossAxisAlignment,
      children: visible,
    );
  }

  /// 分区之间的空行（`SizedBox(height: sp6)`；2026-09-25 由 sp8 压紧）。
  static bool _isSectionGap(Widget w) =>
      w is SizedBox && w.height == AylaSpacing.sp6 && w.width == null;
}

/// 画布头：标题 + 当前分类 + 该分类的分区数（未分类非空时显式提示）。
class _GalleryHeader extends StatelessWidget {
  const _GalleryHeader();

  @override
  Widget build(BuildContext context) {
    final AylaTextStyles t = AylaTextStyles.of(context);
    final _GalleryScope? scope = _GalleryScope.maybeOf(context);
    final String id = scope?.selectedId ?? kGalleryCategories.first.id;
    final bool fallback = id == kGalleryFallbackCategoryId;
    final AylaGalleryCategory? category = fallback
        ? null
        : kGalleryCategories.firstWhere((AylaGalleryCategory c) => c.id == id);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          category == null ? '组件库 · 未分类（映射遗漏）' : '组件库 · ${category.label}',
          style: t.pageTitle,
        ),
        const SizedBox(height: AylaSpacing.sp2),
        Text(
          fallback
              ? '这些分区的标题前缀还没加进 kGalleryCategories ⇒ 请补映射'
              : 'web 事实源写在各分区标题下（CSS 文件:行）· 尺寸按 web CSS px（Windows 125% 口径）',
          style: t.caption.copyWith(color: AylaColors.textSecondary),
        ),
      ],
    );
  }
}

/// 分区（标题 + 来源 + 内容）。
class _Section extends StatelessWidget {
  const _Section({
    required this.title,
    required this.source,
    required this.child,
  });

  final String title;
  final String source;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final AylaTextStyles t = AylaTextStyles.of(context);
    // 每个分区一个独立重绘边界：画布是 SingleChildScrollView + 单个 Column，不隔离的话
    // **滚动一帧会把整列（含全部样张的玻璃卡与半透明层）标记重绘** —— 2026-09-25 实测
    // 4640 个 RenderObject 需要重绘；隔离后只剩进入视口的那几个分区。见 perf_audit_test。
    return RepaintBoundary(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(title, style: t.cardTitle),
          const SizedBox(height: AylaSpacing.sp1),
          Text(
            source,
            style: t.timestamp.copyWith(color: AylaColors.textSecondary),
          ),
          const SizedBox(height: AylaSpacing.sp3),
          child,
        ],
      ),
    );
  }
}

/// 横向一排（每项自带标签）。
class _Row extends StatelessWidget {
  const _Row({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: AylaSpacing.sp4,
      runSpacing: AylaSpacing.sp4,
      crossAxisAlignment: WrapCrossAlignment.end,
      children: children,
    );
  }
}

/// 纵向一列（输入样张用）。
class _Rows extends StatelessWidget {
  const _Rows({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 440),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          for (int i = 0; i < children.length; i++) ...<Widget>[
            if (i > 0) const SizedBox(height: AylaSpacing.sp4),
            children[i],
          ],
        ],
      ),
    );
  }
}

/// 毛玻璃质量档对照（13 号 §8.17）：三档切换，只换「背后内容层」。
///
/// ⚠️ `AylaGlassConfig.quality` 是**全局静态旋钮**：本样张在 [dispose] 里恢复
/// 默认档，避免污染画布其它分区与性能审计基线（perf_audit_test 的层数）。
class _GlassQualityStage extends StatefulWidget {
  const _GlassQualityStage();

  @override
  State<_GlassQualityStage> createState() => _GlassQualityStageState();
}

class _GlassQualityStageState extends State<_GlassQualityStage> {
  /// 进入样张时的全局档位 —— 离开时**恢复它**（不是硬编码默认档）。
  ///
  /// 硬编码恢复默认档会在宿主本来就跑在非默认档时把档位改回去
  /// （2026-09-27 实测：`perf_audit_test` 的预模糊档用例遍历到第二个分类就失效
  /// —— 因为切走分类时本样张被卸载、dispose 把档位重置了）。
  late final AylaGlassQuality _entryQuality = AylaGlassConfig.quality;
  late AylaGlassQuality _quality = _entryQuality;

  @override
  void dispose() {
    AylaGlassConfig.quality = _entryQuality;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final AylaTextStyles t = AylaTextStyles.of(context);
    const List<(AylaGlassQuality, String)> choices =
        <(AylaGlassQuality, String)>[
      (AylaGlassQuality.realBackdrop, '真玻璃（默认）'),
      (AylaGlassQuality.preblurred, '预模糊'),
      (AylaGlassQuality.opaque, '实底'),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        _Row(
          children: <Widget>[
            for (final (AylaGlassQuality q, String label) in choices)
              AylaGlassButton(
                label: label,
                variant: q == _quality
                    ? AylaGlassButtonVariant.primary
                    : AylaGlassButtonVariant.ghost,
                onPressed: () {
                  AylaGlassConfig.quality = q;
                  setState(() => _quality = q);
                },
              ),
          ],
        ),
        const SizedBox(height: AylaSpacing.sp3),
        // 玻璃要压在**真实背景**上才看得出差别（画布本身是浅色底），而且预模糊档
        // 的采样源正是背景登记的静态九层快照 —— 画布宿主没有全局背景，样张自带一个
        // 才看得到「预模糊」的真实效果（否则采样层无源、只剩透明）。
        SizedBox(
          height: 220,
          child: AylaAuroraBackground(
            animate: false, // 样张不跑流层（画布宿主必须能 settle）
            child: Padding(
              padding: const EdgeInsets.all(AylaSpacing.sp4),
              child: _Row(
                children: <Widget>[
                  _Slot(
                    label: '玻璃卡',
                    width: 260,
                    child: AylaGlassCard(child: Text('玻璃卡', style: t.cardTitle)),
                  ),
                  _Slot(
                    label: '玻璃按钮 + 图标钮',
                    width: 260,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        AylaGlassButton(
                          label: '主按钮',
                          variant: AylaGlassButtonVariant.glow,
                          onPressed: () {},
                        ),
                        const SizedBox(height: AylaSpacing.sp2),
                        AylaIconButton(
                          icon: AylaIcon(aylaIconByName('iconHeart')!),
                          semanticLabel: '收藏',
                          onPressed: () {},
                        ),
                      ],
                    ),
                  ),
                  _Slot(
                    label: '玻璃输入框',
                    width: 260,
                    child: const _InputSample(label: '搜索', onGlassBorder: true),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// 单个展位（下方小字标注；内容按自身内在尺寸渲染，有明确宽度才用 [width]）。
class _Slot extends StatelessWidget {
  const _Slot({required this.label, required this.child, this.width});

  final String label;
  final Widget child;
  final double? width;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.center,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        if (width != null) SizedBox(width: width, child: child) else child,
        const SizedBox(height: AylaSpacing.sp2),
        SizedBox(
          width: width ?? 180,
          child: Text(
            label,
            textAlign: TextAlign.center,
            style: AylaTextStyles.light.timestamp.copyWith(
              color: AylaColors.textSecondary,
            ),
          ),
        ),
      ],
    );
  }
}

/// 徽标宿主（40px 玻璃方，模拟图标钮）。
class _BadgeHost extends StatelessWidget {
  const _BadgeHost({required this.count});

  final int count;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 40,
      height: 40,
      child: Stack(
        clipBehavior: Clip.none,
        children: <Widget>[
          Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: AylaColors.glassBg,
                borderRadius: BorderRadius.circular(AylaRadii.rInput),
                border: Border.all(color: AylaColors.glassBorder),
              ),
            ),
          ),
          AylaTabBadge(count: count),
        ],
      ),
    );
  }
}

/// 骨架行样张。
class _SkeletonSample extends StatelessWidget {
  const _SkeletonSample();

  @override
  Widget build(BuildContext context) {
    return const Row(
      children: <Widget>[
        AylaSkeleton(
          width: 44,
          height: 44,
          radius: AylaRadii.rPill,
          shape: BoxShape.circle,
        ),
        SizedBox(width: AylaSpacing.sp3),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              AylaSkeleton(width: 120, height: 14),
              SizedBox(height: AylaSpacing.sp2),
              AylaSkeleton(width: 200, height: 12),
            ],
          ),
        ),
      ],
    );
  }
}

/// 输入样张。
class _InputSample extends StatefulWidget {
  const _InputSample({
    required this.label,
    this.autofocus = false,
    this.obscure = false,
    this.text = '',
    this.onGlassBorder = false,
  });

  final String label;
  final bool autofocus;
  final bool obscure;
  final String text;
  final bool onGlassBorder;

  @override
  State<_InputSample> createState() => _InputSampleState();
}

class _InputSampleState extends State<_InputSample> {
  late final TextEditingController _c = TextEditingController(
    text: widget.text,
  );

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(widget.label, style: AylaTextStyles.light.timestamp),
        const SizedBox(height: AylaSpacing.sp2),
        AylaGlassInput(
          controller: _c,
          hintText: '用户名',
          autofocus: widget.autofocus,
          obscureText: widget.obscure,
          onGlassBorder: widget.onGlassBorder,
          minHeight: 44,
          textStyle: AylaTextStyles.light.label.copyWith(
            fontWeight: FontWeight.w400,
            color: AylaColors.textPrimary,
          ),
        ),
      ],
    );
  }
}


/// B3 卡片族样张：窄屏 2 列网格 + 列表（卡片族**仅 ≤768 生效**——HomePage
/// 在宽屏 `if (!isNarrow) return <Navigate to={/group/:id}/>`）。
class _GroupCardDemo extends StatelessWidget {
  const _GroupCardDemo();

  @override
  Widget build(BuildContext context) {
    // 预览用外部占位图（真实链路走后端媒体签名，属媒体批次）
    const String imgA = 'https://picsum.photos/seed/ayla-live/600/450';
    const String imgB = 'https://picsum.photos/seed/ayla-post/600/450';

    final List<AylaGroupCarouselSlide> slides = <AylaGroupCarouselSlide>[
      const AylaGroupCarouselSlide.messageVoice(
        newMessageCount: 12,
        voiceRooms: <AylaGroupSlideVoiceRoom>[
          AylaGroupSlideVoiceRoom(name: '深夜电台', memberCount: 5),
          AylaGroupSlideVoiceRoom(name: '作业互助', memberCount: 3),
        ],
      ),
      const AylaGroupCarouselSlide.live(host: '小樱', title: '一起看星星', cover: imgA),
      const AylaGroupCarouselSlide.post(
        title: '周末去哪玩',
        body: '大家周末有空吗？想去海边看日落，顺便拍点照片。',
        image: imgB,
        hasUnread: true,
      ),
      const AylaGroupCarouselSlide.game(name: '你画我猜', memberCount: 4),
    ];

    const List<AylaGroupCarouselSlide> noImage = <AylaGroupCarouselSlide>[
      AylaGroupCarouselSlide.messageVoice(
        newMessageCount: 3,
        voiceRooms: <AylaGroupSlideVoiceRoom>[],
      ),
      AylaGroupCarouselSlide.live(host: '小蓝', title: '新番同步看'),
    ];

    // 用 Wrap 而非 Row：测试视口（800 宽）下两列会溢出 46px（widget test 抓到）；
    // 画布 1800 宽时仍是并排两列。
    return Wrap(
      spacing: AylaSpacing.sp8,
      runSpacing: AylaSpacing.sp6,
      crossAxisAlignment: WrapCrossAlignment.start,
      children: <Widget>[
        // 窄屏列宽 375（卡片族设计基准）
        SizedBox(
          width: 375,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              AylaGroupGrid(
                children: <Widget>[
                  AylaGroupCard(
                    groupId: 'g1',
                    title: '星海观测站',
                    slides: slides,
                    unread: 12,
                    onOpen: () {},
                    onTogglePin: (_) {},
                  ),
                  AylaGroupCard(
                    groupId: 'g2',
                    title: '置顶的长群名测试省略号',
                    slides: noImage,
                    unread: 128,
                    isPinned: true,
                    onOpen: () {},
                    onTogglePin: (_) {},
                  ),
                ],
              ),
              AylaGroupList(
                children: <Widget>[
                  AylaGroupListItem(
                    groupId: 'g1',
                    title: '星海观测站',
                    status: const AylaAvatarStatus(
                      unread: 12,
                      live: true,
                      voice: true,
                    ),
                    preview: '小樱：今晚一起吃饭吗',
                    isPinned: true,
                    onOpen: () {},
                  ),
                  AylaGroupListItem(
                    groupId: 'g2',
                    title: '作业互助',
                    status: const AylaAvatarStatus(unread: 3, voice: true),
                    memberCount: 8,
                    onOpen: () {},
                  ),
                ],
              ),
            ],
          ),
        ),
        // 空态 / 状态组合
        SizedBox(
          width: 375,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              AylaGroupGrid(
                children: <Widget>[
                  AylaGroupCard(
                    groupId: 'g3',
                    title: '空状态群',
                    slides: const <AylaGroupCarouselSlide>[],
                    onOpen: () {},
                  ),
                  AylaGroupCard(
                    groupId: 'g4',
                    title: '无图占位',
                    slides: noImage,
                    unread: 3,
                    onOpen: () {},
                  ),
                ],
              ),
              AylaGroupList(
                children: <Widget>[
                  AylaGroupListItem(
                    groupId: 'g3',
                    title: '新内容群',
                    newEventText: '阿蓝 创建了语音房 深夜电台',
                    memberCount: 5,
                    onOpen: () {},
                  ),
                  AylaGroupListItem(
                    groupId: 'g4',
                    title: '静默群',
                    memberCount: 2,
                    onOpen: () {},
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }
}

// ======================= B4 通用基元素材 =======================

/// AylaResourceImage 全状态样张。
class _ResourceImageDemo extends StatelessWidget {
  const _ResourceImageDemo();

  @override
  Widget build(BuildContext context) {
    // ⚠️「原图已过期」角标只有签名链路能产生（original 410 → 降级 thumb 并置
    // originalExpired=true，api/media.ts 50–53）；外部 URL 永远看不到。
    // 故注入受控假 client，让 `expired-original` / `fully-expired` 两个 id
    // 走真实的降级/过期分支（同一代码路径，数据源可控）。
    MediaSigner.instance.attach(PreviewMediaClient());
    const String ok = 'https://picsum.photos/seed/ayla-ri/240/180';
    const String expiredOriginal = '/api/v1/media/expired-original/content';
    const String fullyExpired = '/api/v1/media/fully-expired/content';
    Widget cell(String label, Widget child) => SizedBox(
      width: 200,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          SizedBox(width: 200, height: 140, child: child),
          const SizedBox(height: 6),
          Text(label, style: const TextStyle(fontSize: 11)),
        ],
      ),
    );
    return Wrap(
      spacing: AylaSpacing.sp4,
      runSpacing: AylaSpacing.sp4,
      children: <Widget>[
        cell('正常（外部 URL 直连）', const AylaResourceImage(src: ok, alt: '示例图')),
        cell(
          '⭐ 原图已过期 → 缩略图 + 角标',
          const AylaResourceImage(
            src: expiredOriginal,
            alt: '图',
            expiredBadge: true,
            ignoreSampleMedia: true, // 状态演示，不被示例图盖掉
          ),
        ),
        cell(
          '完全过期 → 「已过期」占位',
          const AylaResourceImage(
            src: fullyExpired,
            alt: '图',
            ignoreSampleMedia: true,
          ),
        ),
        cell(
          '装饰图（alt="" → 过期不提示）',
          const AylaResourceImage(src: fullyExpired, ignoreSampleMedia: true),
        ),
      ],
    );
  }
}

/// AylaConfirmDialog + AsyncState 样张。
class _DialogsDemo extends StatelessWidget {
  const _DialogsDemo();

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: AylaSpacing.sp4,
      runSpacing: AylaSpacing.sp4,
      crossAxisAlignment: WrapCrossAlignment.start,
      children: <Widget>[
        // AylaConfirmDialog 需要占位画框（它是 overlay 式布局）
        SizedBox(
          width: 300,
          height: 300,
          child: Stack(
            children: <Widget>[
              AylaConfirmDialog(
                title: '删除会话',
                message: '删除会话「小樱」？\n消息记录会保留。',
                onConfirm: () {},
                onClose: () {},
              ),
              const Positioned(
                left: 4,
                bottom: 4,
                child: Text(
                  'AylaConfirmDialog（默认）',
                  style: TextStyle(fontSize: 11),
                ),
              ),
            ],
          ),
        ),
        SizedBox(
          width: 300,
          height: 300,
          child: Stack(
            children: <Widget>[
              AylaConfirmDialog(
                title: '删除会话',
                message: '删除会话「小樱」？',
                busy: true,
                onConfirm: () {},
                onClose: () {},
              ),
              const Positioned(
                left: 4,
                bottom: 4,
                child: Text(
                  'AylaConfirmDialog（busy）',
                  style: TextStyle(fontSize: 11),
                ),
              ),
            ],
          ),
        ),
        // AsyncState 四态
        SizedBox(
          width: 220,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              // 高度需容纳：minHeight 96 + padding 32（loading/empty 足够）
              const SizedBox(
                height: 130,
                child: AylaAsyncState(status: AylaAsyncStatus.loading),
              ),
              const Text('loading', style: TextStyle(fontSize: 11)),
              // error 态还需「文案 + gap sp3 + 重试按钮」→ 给足 210
              SizedBox(
                height: 210,
                child: AylaAsyncState(
                  status: AylaAsyncStatus.error,
                  error: '网络连接失败',
                  onRetry: () {},
                ),
              ),
              const Text('error', style: TextStyle(fontSize: 11)),
              const SizedBox(
                height: 130,
                child: AylaAsyncState(status: AylaAsyncStatus.empty),
              ),
              const Text('empty', style: TextStyle(fontSize: 11)),
            ],
          ),
        ),
      ],
    );
  }
}

/// 画布交互样张专用：**合成一次「按下 → 分帧拖动 → 松手」的指针序列**。
///
/// 为什么需要它（2026-09-28 用户点名「动画族样张必须能一键重播」）：跟手类组件的
/// 正确性只存在于「位移随时间的形状」里 ——
/// · `AylaPullToRefresh` 的**指示器跟手档**（web `y = pull − 52`）；
/// · `AylaFullScreenSwipeBack` 的阈值判定与未过阈值回弹。
/// 静止终态看不出这两者，只靠用户手拖又无法「一键重播」。
///
/// 机制全部来自框架既有能力（`GestureBinding.handlePointerEvent`），**不动组件 API**。
/// ⚠️ `timeStamp` 必须给真实帧时间：`VelocityTracker` 按 `event.timeStamp` 求速度，
/// 默认 `Duration.zero` 会让相邻样本 dt = 0（速度 NaN ⇒ 甩动判定失效）。
Future<void> aylaSyntheticDrag({
  required Offset start,
  required Offset delta,
  int steps = 12,
  int pointer = 0x4A1A,
}) async {
  final GestureBinding binding = GestureBinding.instance;
  Duration now() => SchedulerBinding.instance.currentSystemFrameTimeStamp;
  binding.handlePointerEvent(
    PointerDownEvent(pointer: pointer, position: start, timeStamp: now()),
  );
  for (int i = 1; i <= steps; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 16));
    binding.handlePointerEvent(
      PointerMoveEvent(
        pointer: pointer,
        position: start + delta * (i / steps),
        delta: delta / steps.toDouble(),
        timeStamp: now(),
      ),
    );
  }
  await Future<void>.delayed(const Duration(milliseconds: 16));
  binding.handlePointerEvent(
    PointerUpEvent(pointer: pointer, position: start + delta, timeStamp: now()),
  );
}

/// PullToRefresh / AylaSignedVideo 样张。
class _InteractionDemo extends StatefulWidget {
  const _InteractionDemo();

  @override
  State<_InteractionDemo> createState() => _InteractionDemoState();
}

class _InteractionDemoState extends State<_InteractionDemo> {
  /// 下拉刷新宿主（合成手势的坐标基准）。
  final GlobalKey _pullKey = GlobalKey();

  /// 一键重放「按下 → 分帧下拉 110px → 松手」：越过 threshold 64 ⇒ 触发刷新。
  Future<void> _simulatePull() async {
    final RenderBox? box =
        _pullKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null) return;
    final Offset start =
        box.localToGlobal(Offset.zero) + Offset(box.size.width / 2, 24);
    await aylaSyntheticDrag(start: start, delta: const Offset(0, 110));
  }

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: AylaSpacing.sp4,
      runSpacing: AylaSpacing.sp4,
      crossAxisAlignment: WrapCrossAlignment.start,
      children: <Widget>[
        SizedBox(
          width: 375,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            spacing: AylaSpacing.sp2,
            children: <Widget>[
              SizedBox(
                height: 380,
                child: AylaPullToRefresh(
                  key: _pullKey,
                  isAtTop: () => true,
                  onRefresh: () async =>
                      Future<void>.delayed(const Duration(milliseconds: 600)),
                  child: ListView(
                    physics: const NeverScrollableScrollPhysics(),
                    padding: const EdgeInsets.all(AylaSpacing.sp3),
                    children: <Widget>[
                      for (int i = 0; i < 6; i++)
                        Container(
                          margin:
                              const EdgeInsets.only(bottom: AylaSpacing.sp2),
                          height: 48,
                          alignment: Alignment.centerLeft,
                          padding: const EdgeInsets.symmetric(
                            horizontal: AylaSpacing.sp3,
                          ),
                          decoration: BoxDecoration(
                            color: AylaColors.glassBg,
                            borderRadius:
                                BorderRadius.circular(AylaRadii.rInput),
                            border: Border.all(color: AylaColors.glassBorder),
                          ),
                          child: Text('列表项 ${i + 1}（下拉刷新）'),
                        ),
                    ],
                  ),
                ),
              ),
              // 跟手档重播（见 `aylaSyntheticDrag` 文档）：不点也能看 —— 直接用
              // 鼠标/手指在列表上往下拖同样有效；这个键只是把同一段手势**一键重放**。
              AylaGlassButton(
                label: '模拟下拉刷新（跟手）',
                variant: AylaGlassButtonVariant.ghost,
                minHeight: 28,
                fontSize: 12,
                expand: true,
                onPressed: _simulatePull,
              ),
            ],
          ),
        ),
        SizedBox(
          width: 260,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              const AylaSignedVideo(mediaId: 'demo-1'),
              const SizedBox(height: 6),
              const Text(
                'AylaSignedVideo（failed 态，可点重试）',
                style: TextStyle(fontSize: 11),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// 预览用假签名 client（公开版，画布与 画布 复用）：
/// 按 media_id 前缀模拟后端 `:sign` 的分级过期行为。
class PreviewMediaClient implements DioClient {
  @override
  Future<T> post<T>(
    String path, {
    Object? body,
    Map<String, dynamic>? query,
  }) async {
    final bool isThumb = body is Map && body['variant'] == 'thumb';
    final bool expiredOriginal = path.contains('expired-original');
    final bool fullyExpired = path.contains('fully-expired');
    if ((expiredOriginal && !isThumb) || fullyExpired) {
      throw const ApiException(410, 'media_expired');
    }
    return <String, dynamic>{
          'url':
              'https://picsum.photos/seed/ayla-${isThumb ? "thumb" : "orig"}/240/180',
          'expires_at': DateTime.now().millisecondsSinceEpoch / 1000 + 3600,
        }
        as T;
  }

  @override
  noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

// ======================= B4 剩余素材 =======================

/// 分页族 + 收藏按钮。
class _PaginationAndFavoriteDemo extends StatelessWidget {
  const _PaginationAndFavoriteDemo();

  @override
  Widget build(BuildContext context) {
    Widget cell(String label, Widget child) => SizedBox(
      width: 240,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          DecoratedBox(
            decoration: BoxDecoration(
              border: Border.all(color: const Color(0x22465B92)),
            ),
            child: child,
          ),
          const SizedBox(height: 6),
          Text(label, style: const TextStyle(fontSize: 11)),
        ],
      ),
    );

    return Wrap(
      spacing: AylaSpacing.sp4,
      runSpacing: AylaSpacing.sp4,
      crossAxisAlignment: WrapCrossAlignment.start,
      children: <Widget>[
        cell(
          'hasMore → 加载更多',
          AylaDirectoryLoadMore(
            loading: false,
            error: null,
            hasMore: true,
            invalidated: false,
            loadMore: () async {},
            refresh: () async {},
          ),
        ),
        cell(
          'loading → 三点',
          AylaDirectoryLoadMore(
            loading: true,
            error: null,
            hasMore: true,
            invalidated: false,
            loadMore: () async {},
            refresh: () async {},
          ),
        ),
        cell(
          'invalidated → 刷新中',
          AylaDirectoryLoadMore(
            loading: false,
            error: null,
            hasMore: true,
            invalidated: true,
            loadMore: () async {},
            refresh: () async {},
          ),
        ),
        cell(
          '历史控制：更早 + 返回最新',
          AylaHistoryControls(
            loading: false,
            error: null,
            hasMore: true,
            hasNewer: true,
            loadOlder: () async {},
            returnLatest: () async {},
            retry: () async {},
          ),
        ),
        SizedBox(
          width: 320,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Wrap(
                spacing: AylaSpacing.sp3,
                runSpacing: AylaSpacing.sp3,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: <Widget>[
                  AylaFavoriteButton(
                    state: AylaFavoriteState.notFavorited,
                    onToggle: (_) {},
                  ),
                  AylaFavoriteButton(
                    state: AylaFavoriteState.favorited,
                    onToggle: (_) {},
                  ),
                  AylaFavoriteButton(
                    state: AylaFavoriteState.unknown,
                    onRetryStatus: () {},
                  ),
                  AylaFavoriteButton(
                    state: AylaFavoriteState.error,
                    onRetryStatus: () {},
                  ),
                  AylaFavoriteButton(
                    state: AylaFavoriteState.favorited,
                    compact: true,
                    onToggle: (_) {},
                  ),
                ],
              ),
              const SizedBox(height: 6),
              const Text(
                'FavoriteButton 五态（含 compact 32 圆钮）',
                style: TextStyle(fontSize: 11),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// 可见性选择器 + 资料卡 + 筛选条 + 隐私设置。
///
/// **有状态**：DirectoryFilters 两种形态都可点击/键盘切换（高亮 300ms 迁移）。
class _DirectoryAndProfileDemo extends StatefulWidget {
  const _DirectoryAndProfileDemo();

  @override
  State<_DirectoryAndProfileDemo> createState() =>
      _DirectoryAndProfileDemoState();
}

class _DirectoryAndProfileDemoState extends State<_DirectoryAndProfileDemo> {
  /// 宽屏侧栏选中项（点击/↑↓ 切换）。
  String _wideValue = 'posts';

  /// 窄屏顶栏选中项（点击/←→ 切换）。
  String _narrowValue = 'groups';

  @override
  Widget build(BuildContext context) {
    const List<({String id, String title})> groups =
        <({String id, String title})>[
          (id: 'g1', title: '星海观测站'),
          (id: 'g2', title: '作业互助'),
          (id: 'g3', title: '深夜电台'),
        ];
    const List<({String key, String label})> opts =
        <({String key, String label})>[
          (key: 'all', label: '全部'),
          (key: 'users', label: '用户'),
          (key: 'groups', label: '群聊'),
          (key: 'posts', label: '帖子'),
          (key: 'live', label: '直播间'),
          (key: 'games', label: '桌游室'),
        ];

    return Wrap(
      spacing: AylaSpacing.sp4,
      runSpacing: AylaSpacing.sp4,
      crossAxisAlignment: WrapCrossAlignment.start,
      children: <Widget>[
        SizedBox(
          width: 340,
          child: AylaVisibilitySelector(
            value: const AylaVisibilitySelection(isPublic: true, group: true),
            onChange: (_) {},
            selectedGroupIds: const <String>['g1', 'g3'],
            onSelectedGroupIdsChange: (_) {},
            groups: groups,
          ),
        ),
        SizedBox(
          width: 340,
          child: AylaVisibilitySelector(
            value: const AylaVisibilitySelection(group: true),
            onChange: (_) {},
            lockGroup: true,
            initialGroupId: 'g2',
            selectedGroupIds: const <String>['g2'],
            onSelectedGroupIdsChange: (_) {},
            groups: groups,
          ),
        ),
        // ---------- DirectoryFilters 宽屏侧栏（可交互） ----------
        SizedBox(
          height: 380,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              SizedBox(
                height: 340,
                child: AylaDirectoryFilters(
                  label: '搜索结果分类',
                  options: opts,
                  value: _wideValue, // 可交互：点击 / ↑↓ / Home / End
                  onChange: (String v) => setState(() => _wideValue = v),
                  header: Column(
                    spacing: 2,
                    children: <Widget>[
                      Text(
                        'SEARCH',
                        style: TextStyle(
                          fontFamily: 'Fredoka',
                          fontSize: 10,
                          fontWeight: FontWeight.w600,
                          letterSpacing: 1.4,
                          color: AylaColors.pink500,
                        ),
                      ),
                      Text(
                        '搜索结果',
                        style: TextStyle(
                          fontFamily: 'Fredoka',
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                          color: AylaColors.textPrimary,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 6),
              Text(
                'DirectoryFilters 宽屏侧栏（点击/↑↓ 切换 · 当前 $_wideValue）',
                style: const TextStyle(fontSize: 11),
              ),
            ],
          ),
        ),
        // ---------- DirectoryFilters 窄屏顶栏（可交互） ----------
        SizedBox(
          width: 420,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              AylaDirectoryFilters(
                label: '搜索结果分类（窄屏顶栏）',
                options: opts,
                value: _narrowValue, // 可交互：点击 / ←→ 切换
                narrow: true,
                onChange: (String v) => setState(() => _narrowValue = v),
              ),
              const SizedBox(height: 8),
              Text(
                'DirectoryFilters 窄屏顶栏（无圆角·只下边框·点击/←→ 切换 · 当前 $_narrowValue）',
                style: const TextStyle(fontSize: 11),
              ),
              const SizedBox(height: 6),
              Container(
                height: 90,
                alignment: Alignment.center,
                child: const Text('内容区', style: TextStyle(fontSize: 11)),
              ),
            ],
          ),
        ),
        SizedBox(
          width: 340,
          height: 330,
          child: Stack(
            children: <Widget>[
              AylaUserProfileCard(
                nickname: '小樱',
                signature: '今天也要开开心心的',
                online: true,
                displayStatus: '在线',
              ),
              const Positioned(
                left: 0,
                bottom: 0,
                child: Text('UserProfileCard', style: TextStyle(fontSize: 11)),
              ),
            ],
          ),
        ),
        SizedBox(
          width: 340,
          height: 330,
          child: Stack(
            children: <Widget>[
              AylaPrivacySheet(onClose: () {}, boundEmail: 'ayla@example.com'),
              const Positioned(
                left: 0,
                bottom: 0,
                child: Text(
                  'AylaPrivacySheet（menu）',
                  style: TextStyle(fontSize: 11),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// AylaCreateSheet 两形态样张（**可交互**：关闭钮/遮罩收起 → 「重新打开」还原）。
///
/// ⚠️ 弹层的宽窄与尺寸**全部读 `MediaQuery` 视口**（`AylaModalCard` 的 80vh /
/// `AylaModalOverlay` 的 flex-end 判定）→ 画布里必须用
/// `MediaQuery.copyWith(size:)` **覆写局部视口**，否则两种形态都会按预览宿主的
/// 窗口尺寸走（`13-工作进度与待办.md` §6.6 同一教训）。
class _CreateSheetDemo extends StatefulWidget {
  const _CreateSheetDemo();

  @override
  State<_CreateSheetDemo> createState() => _CreateSheetDemoState();
}

class _CreateSheetDemoState extends State<_CreateSheetDemo> {
  /// 一级 tab 发帖（web `CreateFab.tsx:93–103` 的 post 分支）
  bool _wideOpen = true;
  bool _narrowOpen = true;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: AylaSpacing.sp6,
      runSpacing: AylaSpacing.sp6,
      crossAxisAlignment: WrapCrossAlignment.start,
      children: <Widget>[
        _stage(
          viewport: const Size(1024, 620),
          label: '宽屏 1024：居中 480 卡 · overlay padding sp4=16',
          open: _wideOpen,
          onToggle: (bool v) => setState(() => _wideOpen = v),
        ),
        _stage(
          viewport: const Size(375, 620),
          label: '窄屏 375：贴底 + radius 24 24 0 0 + 上滑 250ms',
          open: _narrowOpen,
          onToggle: (bool v) => setState(() => _narrowOpen = v),
        ),
      ],
    );
  }

  /// 固定视口的弹层舞台（`Stack` 需要 tight 约束，`Positioned.fill` 才成立）。
  Widget _stage({
    required Size viewport,
    required String label,
    required bool open,
    required ValueChanged<bool> onToggle,
  }) {
    return SizedBox(
      width: viewport.width,
      height: viewport.height,
      child: Builder(
        builder: (BuildContext inner) => MediaQuery(
          data: MediaQuery.of(inner).copyWith(size: viewport),
          child: Stack(
            children: <Widget>[
              if (open)
                AylaCreateSheet(
                  title: '发帖', // web `shellConfig.ts:256` 的 action.label
                  onClose: () => onToggle(false),
                  child: AylaPostEditor(
                    onSubmit: (_) async {},
                    groups: const <({String id, String title})>[
                      (id: 'g1', title: '深夜电台'),
                      (id: 'g2', title: '星海观测站'),
                    ],
                  ),
                )
              else
                Center(
                  child: AylaGlassButton(
                    label: '重新打开（$label）',
                    variant: AylaGlassButtonVariant.ghost,
                    onPressed: () => onToggle(true),
                  ),
                ),
              Positioned(
                left: 0,
                bottom: 0,
                child: Text(label, style: const TextStyle(fontSize: 11)),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 转场样张：点「进入下一页」看**新旧页重叠**（新页浮入 + 旧页 300ms 淡出），点「重播」看单页进入动画。
class _PageSwapDemo extends StatefulWidget {
  const _PageSwapDemo();

  @override
  State<_PageSwapDemo> createState() => _PageSwapDemoState();
}

class _PageSwapDemoState extends State<_PageSwapDemo> {
  int _page = 0;
  int _replay = 0;

  @override
  Widget build(BuildContext context) {
    final AylaTextStyles t = AylaTextStyles.of(context);
    return SizedBox(
      width: 560,
      height: 220,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            spacing: AylaSpacing.sp3,
            children: <Widget>[
              AylaGlassButton(
                label: '进入下一页',
                minHeight: 32,
                onPressed: () => setState(() => _page = (_page + 1) % 3),
              ),
              AylaGlassButton(
                label: '重播进入动画',
                variant: AylaGlassButtonVariant.ghost,
                minHeight: 32,
                onPressed: () => setState(() => _replay++),
              ),
            ],
          ),
          const SizedBox(height: AylaSpacing.sp3),
          Expanded(
            child: ClipRect(
              child: AylaPageSwap(
                pageKey: 'page-$_page',
                builder: (BuildContext context) => AylaPageTransition(
                  key: ValueKey<int>(_replay),
                  groupScene: _page == 2, // 第三页演示「群页只淡入」
                  child: Container(
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: AylaColors.glassBgStrong,
                      borderRadius: BorderRadius.circular(AylaRadii.rCard),
                      border: Border.all(color: AylaColors.glassBorder),
                    ),
                    child: Text(
                      '第 ${_page + 1} 页'
                      '${_page == 2 ? '（群页档：只淡入）' : ''}',
                      style: t.cardTitle,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 搜索历史样张：点词回填、点「清空」清空（演示两种状态）。
class _SearchHistoryDemo extends StatefulWidget {
  const _SearchHistoryDemo();

  @override
  State<_SearchHistoryDemo> createState() => _SearchHistoryDemoState();
}

class _SearchHistoryDemoState extends State<_SearchHistoryDemo> {
  List<String> _history = <String>['爱莉', '语音房', '桌游', '直播'];
  String _query = '';
  String _last = '（未点）';

  @override
  Widget build(BuildContext context) {
    final AylaTextStyles t = AylaTextStyles.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        SizedBox(
          width: 420,
          child: AylaSearchHistoryChips(
            history: _history,
            query: _query,
            onSelect: (String w) => setState(() {
              _query = w;
              _last = '选了「$w」';
            }),
            onClear: () => setState(() {
              _history = <String>[];
              _last = '已清空';
            }),
          ),
        ),
        Text('最近操作：$_last', style: t.timestamp),
        const SizedBox(height: AylaSpacing.sp3),
        AylaGlassButton(
          label: '重置样张',
          variant: AylaGlassButtonVariant.ghost,
          minHeight: 32,
          onPressed: () => setState(() {
            _history = <String>['爱莉', '语音房', '桌游', '直播'];
            _query = '';
            _last = '（未点）';
          }),
        ),
      ],
    );
  }
}

/// 结果分组样张：三档页脚（查看更多 / 加载中 / 失败重试）+ 空组不渲染。
class _SearchGroupDemo extends StatefulWidget {
  const _SearchGroupDemo();

  @override
  State<_SearchGroupDemo> createState() => _SearchGroupDemoState();
}

class _SearchGroupDemoState extends State<_SearchGroupDemo> {
  int _mode = 0; // 0 更多 · 1 加载中 · 2 失败

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        SizedBox(
          width: 420,
          child: AylaSearchResultGroup(
            title: '用户',
            count: 2,
            hasMore: _mode != 2,
            loading: _mode == 1,
            error: _mode == 2 ? '加载失败，请重试' : null,
            showTitle: true,
            onMore: () {},
            children: const <Widget>[
              AylaSearchUserRow(nickname: '爱莉', username: 'elysia', signature: '今天也想见你'),
              AylaSearchUserRow(nickname: '', username: 'sakura', online: true),
            ],
          ),
        ),
        const SizedBox(height: AylaSpacing.sp3),
        AylaGlassButton(
          label: _mode == 0
              ? '切到「加载中」'
              : (_mode == 1 ? '切到「失败」' : '切回「查看更多」'),
          variant: AylaGlassButtonVariant.ghost,
          minHeight: 32,
          onPressed: () => setState(() => _mode = (_mode + 1) % 3),
        ),
      ],
    );
  }
}

/// 用户结果行样张：有/无签名两态 + 尾部槽位。
class _SearchRowDemo extends StatelessWidget {
  const _SearchRowDemo();

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      spacing: AylaSpacing.sp3,
      children: <Widget>[
        SizedBox(
          width: 420,
          child: AylaSearchUserRow(
            nickname: '爱莉',
            username: 'elysia',
            signature: '今天也想见你',
            online: true,
            onOpenProfile: () {},
            onTap: () {},
          ),
        ),
        SizedBox(
          width: 420,
          child: AylaSearchUserRow(
            nickname: '',
            username: 'sakura',
            onOpenProfile: () {},
            onTap: () {},
          ),
        ),
        SizedBox(
          width: 420,
          child: AylaSearchUserRow(
            nickname: '星海观测站',
            username: 'group_xinghai',
            signature: '128 人 · 公开',
            onOpenProfile: () {},
            onTap: () {},
            trailing: Text(
              '进入',
              style: AylaTextStyles.of(context).label.copyWith(
                fontSize: 13,
                color: AylaColors.grape700,
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// 瀑布流样张：高度错落的卡片（看「最矮列优先」的交错），底部挂一个跨列 footer。
class _MasonryDemo extends StatelessWidget {
  const _MasonryDemo();

  @override
  Widget build(BuildContext context) {
    final AylaTextStyles t = AylaTextStyles.of(context);
    const List<double> heights = <double>[96, 148, 120, 176, 104, 132];
    return SizedBox(
      width: 720,
      child: AylaMasonryGrid<int>(
        items: const <int>[0, 1, 2, 3, 4, 5],
        itemKey: (int i) => i,
        memoryKey: 'gallery-masonry',
        itemBuilder: (BuildContext context, int item, int index) => Container(
          height: heights[item],
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: AylaColors.glassBgStrong,
            borderRadius: BorderRadius.circular(AylaRadii.rCard),
            border: Border.all(color: AylaColors.glassBorder),
          ),
          child: Text('卡片 $item · 高 ${heights[item].round()}', style: t.body),
        ),
        footer: Text(
          '跨列页脚（web `.home-load-more { flex-basis: 100% }`）',
          textAlign: TextAlign.center,
          style: t.timestamp,
        ),
      ),
    );
  }
}

/// 资料卡样张：返回 + 头像 + 昵称/用户名 + 分享槽位；下方等宽头像操作三键 + 提示行。
class _ProfileCardDemo extends StatelessWidget {
  const _ProfileCardDemo();

  @override
  Widget build(BuildContext context) {
    final AylaTextStyles t = AylaTextStyles.of(context);
    Widget card({required bool compact}) => SizedBox(
      width: 420,
      child: AylaProfileCard(
        compact: compact,
        children: <Widget>[
          AylaProfileIdentity(
            displayName: '爱莉',
            username: 'elysia',
            online: true,
            onBack: () {},
            share: AylaShareButton(size: 40, label: '分享我的主页', onPressed: () {}),
          ),
          AylaProfileAvatarActions(
            hint: compact ? '新头像将在保存后生效' : null,  // web：仅选了新图时显示
            error: compact ? '图片过大' : null,
            actions: <Widget>[
              AylaGlassButton(
                label: '更换头像',
                variant: AylaGlassButtonVariant.ghost,
                fontSize: 12,
                minHeight: 28,
                padding: const EdgeInsets.symmetric(
                  horizontal: AylaSpacing.sp2,
                  vertical: AylaSpacing.sp1,
                ),
                onPressed: () {},
              ),
              AylaGlassButton(
                label: '隐私设置',
                variant: AylaGlassButtonVariant.ghost,
                fontSize: 12,
                minHeight: 28,
                padding: const EdgeInsets.symmetric(
                  horizontal: AylaSpacing.sp2,
                  vertical: AylaSpacing.sp1,
                ),
                onPressed: () {},
              ),
              // web：`.profile-favorites-btn` 同盒模型 + **IconHeart 15 前置图标**（文案「我的收藏」）
              AylaGlassButton(
                label: '我的收藏',
                icon: AylaIcon(aylaIconByName('iconHeart')!, size: 15),
                variant: AylaGlassButtonVariant.ghost,
                fontSize: 12,
                minHeight: 28,
                padding: const EdgeInsets.symmetric(
                  horizontal: AylaSpacing.sp2,
                  vertical: AylaSpacing.sp1,
                ),
                onPressed: () {},
              ),
            ],
          ),
          Text('个性签名：今天也想见你', style: t.body.copyWith(color: AylaColors.textSecondary)),
        ],
      ),
    );
    return Wrap(
      spacing: AylaSpacing.sp6,
      runSpacing: AylaSpacing.sp6,
      crossAxisAlignment: WrapCrossAlignment.start,
      children: <Widget>[
        _Slot(label: '宽档（padding sp8 / gap sp6）', child: card(compact: false)),
        _Slot(
          label: '紧凑档（≥769 双栏：padding sp4 / gap sp4）+ 已选新图（hint）+ error 行',
          child: card(compact: true),
        ),
      ],
    );
  }
}

/// 收藏骨架样张。
class _FavoritesSkeletonDemo extends StatelessWidget {
  const _FavoritesSkeletonDemo();

  @override
  Widget build(BuildContext context) {
    return const SizedBox(width: 420, child: AylaFavoritesSkeleton());
  }
}

/// 桌游网格样张：2 列（窄）与 4 列（宽）并排 + 骨架态。
class _GamesGridDemo extends StatelessWidget {
  const _GamesGridDemo();

  static const List<String> _rooms = <String>['星海棋局', '深夜狼人', '作业互助', '空状态房'];

  @override
  Widget build(BuildContext context) {
    final AylaTextStyles t = AylaTextStyles.of(context);
    Widget cell(String name) => Container(
      height: 88,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: AylaColors.glassBgStrong,
        borderRadius: BorderRadius.circular(AylaRadii.rCard),
        border: Border.all(color: AylaColors.glassBorder),
      ),
      child: Text(name, style: t.body),
    );
    return Wrap(
      spacing: AylaSpacing.sp6,
      runSpacing: AylaSpacing.sp6,
      crossAxisAlignment: WrapCrossAlignment.start,
      children: <Widget>[
        _Slot(
          label: '窄档：2 列（<769）',
          child: SizedBox(
            width: 420,
            child: AylaGamesGrid(
              children: <Widget>[for (final String r in _rooms) cell(r)],
            ),
          ),
        ),
        _Slot(
          label: '宽档：4 列（≥769）',
          child: SizedBox(
            width: 900,
            child: AylaGamesGrid(
              children: <Widget>[for (final String r in _rooms) cell(r)],
            ),
          ),
        ),
        _Slot(
          label: '加载骨架（两张 120 高卡 + 跨列文案）',
          child: const SizedBox(width: 420, child: AylaGamesGridSkeleton()),
        ),
      ],
    );
  }
}

/// 转让群主弹窗样张：可搜索/可选中/可确认（确认后进入 busy 再复原）。
class _TransferDialogDemo extends StatefulWidget {
  const _TransferDialogDemo();

  @override
  State<_TransferDialogDemo> createState() => _TransferDialogDemoState();
}

class _TransferDialogDemoState extends State<_TransferDialogDemo> {
  static const List<AylaTransferMember> _all = <AylaTransferMember>[
    AylaTransferMember(id: 'u1', displayName: '爱莉', online: true),
    AylaTransferMember(id: 'u2', displayName: '小樱', avatarUrl: null),
    AylaTransferMember(id: 'u3', displayName: '管理员小可', role: AylaGroupRole.admin),
    AylaTransferMember(id: 'u4', displayName: '夜行者'),
    AylaTransferMember(id: 'u5', displayName: '星海', role: AylaGroupRole.admin),
  ];

  String _query = '';
  String? _selected;
  bool _busy = false;

  @override
  Widget build(BuildContext context) {
    final List<AylaTransferMember> shown = _all
        .where((AylaTransferMember m) => m.displayName.contains(_query))
        .toList();
    return _Slot(
      label: '弹窗（480 宽 / 列表 max-h 260 / 点遮罩关闭；「确认转让」会先进入 busy 再复原）',
      child: SizedBox(
        width: 620,
        height: 460,
        child: AylaTransferOwnerDialog(
        members: shown,
        selectedId: _selected,
        query: _query,
        busy: _busy,
        onQueryChanged: (String v) => setState(() => _query = v),
        onSelect: (AylaTransferMember m) => setState(() => _selected = m.id),
        onConfirm: (AylaTransferMember m) {
          setState(() => _busy = true);
          Future<void>.delayed(const Duration(milliseconds: 900), () {
            if (mounted) setState(() => _busy = false);
          });
        },
          onClose: () => setState(() {
            _selected = null;
            _query = '';
          }),
        ),
      ),
    );
  }
}

/// 角色标签样张：群主 / 管理员 / 成员（成员不渲染）。
class _RoleChipDemo extends StatelessWidget {
  const _RoleChipDemo();

  @override
  Widget build(BuildContext context) {
    final AylaTextStyles t = AylaTextStyles.of(context);
    return Wrap(
      spacing: AylaSpacing.sp4,
      runSpacing: AylaSpacing.sp3,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: <Widget>[
        const AylaGroupRoleChip(role: AylaGroupRole.owner),
        const AylaGroupRoleChip(role: AylaGroupRole.admin),
        Row(
          mainAxisSize: MainAxisSize.min,
          spacing: AylaSpacing.sp2,
          children: <Widget>[
            const AylaGroupRoleChip(role: AylaGroupRole.member),
            Text('← member 不渲染标签（web 同）', style: t.timestamp),
          ],
        ),
      ],
    );
  }
}

/// 群资料卡样张：展示态（窄/宽两档）+ 编辑态。
class _GroupInfoProfileDemo extends StatelessWidget {
  const _GroupInfoProfileDemo();

  @override
  Widget build(BuildContext context) {
    final DateTime created = DateTime(2026, 3, 14);
    Widget card({required bool editing, String? about, bool canManage = true}) =>
        AylaGroupInfoProfile(
          title: '星海观测站',
          about: about,
          createdAt: created,
          canManage: canManage,
          stats: const <AylaGroupInfoStat>[
            AylaGroupInfoStat(value: '128', label: '成员'),
            AylaGroupInfoStat(value: '37', label: '已载入在线'),
            AylaGroupInfoStat(value: '4', label: '子群'),
          ],
          editing: editing,
          initialTitle: '星海观测站',
          initialAbout: about,
          onBack: () {},
          onChangeAvatar: () {},
          onSaveAvatar: () {},
          onEdit: () {},
          onSaveEdit: (String a, String b) {},
          onCancelEdit: () {},
          share: AylaShareButton(label: '分享群聊', onPressed: () {}),
        );
    return Wrap(
      spacing: AylaSpacing.sp6,
      runSpacing: AylaSpacing.sp6,
      crossAxisAlignment: WrapCrossAlignment.start,
      children: <Widget>[
        _Slot(label: '展示态 · 窄档（头像 76 / gap sp3）', width: 360, child: card(editing: false, about: '一起看星星')),
        _Slot(label: '展示态 · 宽档（头像 92 / gap sp2）', width: 420, child: card(editing: false, about: '一起看星星')),
        _Slot(label: '简介为空 ⇒「暂无简介」', width: 360, child: card(editing: false, about: '')),
        _Slot(label: '编辑态（两键等宽）', width: 360, child: card(editing: true, about: '一起看星星')),
      ],
    );
  }
}

/// 手势动画样张：七张**空白卡片**，各自演示一种转场/手势（点卡片或按钮重播）。
/// reveal 族样张：**四档 + 一键重播**（2026-09-28 用户点名「动画族样张必须能重播」）。
///
/// - **重播机制**用库内既有能力（不发明）：`AylaRevealScope(replayKey: nonce)` ——
///   scope 把 `replayKey` 的变化转成 `replayTick` 下发给子项，已入场的 [AylaRevealItem]
///   整批重播一次（`reveal.dart:63 / 104 / 230`）。
/// - **四槽对齐**：每槽内容放在**同高、顶部对齐**的舞台里 ⇒ 槽内首行文字天然落在
///   同一条水平线上。此前左槽 3 行、中/右槽各 1 行，而槽内是垂直居中 + `Wrap` 底部
///   对齐 ⇒ 三槽文字不在同一水平线（用户当场点名）。
class _RevealShowcaseDemo extends StatefulWidget {
  const _RevealShowcaseDemo();

  @override
  State<_RevealShowcaseDemo> createState() => _RevealShowcaseDemoState();
}

class _RevealShowcaseDemoState extends State<_RevealShowcaseDemo> {
  /// 重播计数（`replayKey` 变化 ⇒ 四档同时重播）。
  int _nonce = 0;

  /// 槽内舞台高度：容下 stagger 档的 3 行（3×19.5 + 2×8 ≈ 74.5）。
  static const double _stageHeight = 78;

  @override
  Widget build(BuildContext context) {
    final AylaTextStyles t = AylaTextStyles.of(context);

    /// 槽内舞台：**顶部对齐**（四槽内容首行同高）。
    Widget stage(Widget child) => SizedBox(
          height: _stageHeight,
          child: Align(alignment: Alignment.topLeft, child: child),
        );

    Widget slot(String label, Widget child) => _Slot(
          label: label,
          width: 240,
          child: stage(child),
        );

    return AylaRevealScope(
      replayKey: _nonce,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          // ⚠️ 用局部 Wrap（`crossAxisAlignment: start`）而不是公共 `_Row`：`_Row`
          // 是 `WrapCrossAlignment.end`（底部对齐）——四槽的标签行数不同（最后一个
          // 标签在 240 宽下会折行）⇒ 底部对齐会把内容推到不同高度。
          Wrap(
            spacing: AylaSpacing.sp4,
            runSpacing: AylaSpacing.sp4,
            crossAxisAlignment: WrapCrossAlignment.start,
            children: <Widget>[
              // ① 下入 20px（offset 默认）
              slot(
                '① 下入 20px（offset 默认）',
                AylaRevealItem(child: Text('单条 · 下入', style: t.caption)),
              ),
              // ② 下入 + stagger 0 / 50 / 100ms
              slot(
                '② stagger 0 / 50 / 100ms',
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  spacing: AylaSpacing.sp2,
                  children: <Widget>[
                    for (int i = 0; i < 3; i++)
                      AylaRevealItem(
                        index: i,
                        child: Text(
                          '第 ${i + 1} 条（delay ${i * 50}ms）',
                          style: t.caption,
                        ),
                      ),
                  ],
                ),
              ),
              // ③ 上入 20px
              slot(
                '③ 上入 20px（offset 0,-20）',
                AylaRevealItem(
                  offset: const Offset(0, -AylaRevealMotion.distance),
                  child: Text('单条 · 上入', style: t.caption),
                ),
              ),
              // ④ enabled:false
              slot(
                '④ enabled:false（滚动恢复 / 历史节点）',
                const AylaRevealItem(
                  enabled: false,
                  child: Text(
                    '直接显示，不挂动画',
                    style: TextStyle(fontSize: 12),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: AylaSpacing.sp3),
          SizedBox(
            width: 240,
            child: AylaGlassButton(
              label: '重播入场（四档）',
              variant: AylaGlassButtonVariant.ghost,
              minHeight: 28,
              fontSize: 12,
              expand: true,
              onPressed: () => setState(() => _nonce++),
            ),
          ),
        ],
      ),
    );
  }
}

class _MotionShowcaseDemo extends StatefulWidget {
  const _MotionShowcaseDemo();

  @override
  State<_MotionShowcaseDemo> createState() => _MotionShowcaseDemoState();
}

class _MotionShowcaseDemoState extends State<_MotionShowcaseDemo> {
  int _nonce = 0; // 递增 ⇒ 重挂载 ⇒ 重播进场动画
  int _tab = 0; // 选项卡演示
  int _dir = 0; // 选项卡切换方向
  int _backCount = 0; // 右滑返回触发次数

  static const List<String> _tabs = <String>['首页', '语音', '直播'];

  int _conv = 0; // 会话转场：identity 递增（每次切换 = 退场 → 进场重播）
  bool _panels = true; // 会话转场 panels 档（true = 宿主透明，子件自己播）

  /// 右滑返回宿主（合成手势的坐标基准）。
  final GlobalKey _swipeBackKey = GlobalKey();

  void _replay() => setState(() => _nonce++);

  /// 一键重放右滑：`dx ≥ 120` ⇒ 触发 onBack；`dx` 小且慢 ⇒ 200ms 回弹。
  ///
  /// ⚠️ 回弹档必须**同时**满足「位移不过阈值」与「速度 < 300px/s」：
  /// 60px / 24 步 × 16ms = 384ms ⇒ ≈156px/s（若沿用 12 步会到 ≈312px/s，
  /// 反而被甩动判定接走 —— 这正是「只按位移猜、不看时间形状」会踩的坑）。
  Future<void> _simulateSwipeBack(double dx, {int steps = 12}) async {
    final RenderBox? box =
        _swipeBackKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null) return;
    final Offset start =
        box.localToGlobal(Offset.zero) + Offset(24, box.size.height / 2);
    await aylaSyntheticDrag(start: start, delta: Offset(dx, 0), steps: steps);
  }

  @override
  Widget build(BuildContext context) {
    final AylaTextStyles t = AylaTextStyles.of(context);
    Widget blank({required String label, String? hint, Color? tint}) => Container(
      height: 96,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: tint ?? AylaColors.glassBgStrong,
        borderRadius: BorderRadius.circular(AylaRadii.rCard),
        border: Border.all(color: AylaColors.glassBorder),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: <Widget>[
          Text(label, style: t.body),
          if (hint != null)
            Text(hint, style: t.timestamp.copyWith(fontSize: 11)),
        ],
      ),
    );

    Widget slideCard(String label, AylaPanelEdge edge) => Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: AylaSpacing.sp2,
      children: <Widget>[
        AylaPanelTransition(
          key: ValueKey<String>('$label-$_nonce'),
          edge: edge,
          child: blank(label: label, hint: '点下方重播'),
        ),
        AylaGlassButton(
          label: '重播',
          variant: AylaGlassButtonVariant.ghost,
          minHeight: 28,
          fontSize: 12,
          expand: true,
          onPressed: _replay,
        ),
      ],
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      spacing: AylaSpacing.sp4,
      children: <Widget>[
        Text('① 淡入淡出 / 四方向滑入（±20px，300ms）', style: t.cardTitle.copyWith(fontSize: 13, fontWeight: FontWeight.w600)),
        Wrap(
          spacing: AylaSpacing.sp3,
          runSpacing: AylaSpacing.sp3,
          children: <Widget>[
            SizedBox(
              width: 170,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                spacing: AylaSpacing.sp2,
                children: <Widget>[
                  AylaPageTransition(
                    key: ValueKey<String>('fade-$_nonce'),
                    groupScene: true, // 只淡入（web 群页档）
                    child: blank(label: '淡入淡出', hint: '只透明度'),
                  ),
                  AylaGlassButton(
                    label: '重播',
                    variant: AylaGlassButtonVariant.ghost,
                    minHeight: 28,
                    fontSize: 12,
                    expand: true,
                    onPressed: _replay,
                  ),
                ],
              ),
            ),
            SizedBox(width: 170, child: slideCard('右滑入', AylaPanelEdge.right)),
            SizedBox(width: 170, child: slideCard('左滑入', AylaPanelEdge.left)),
            SizedBox(width: 170, child: slideCard('下滑入', AylaPanelEdge.bottom)),
            SizedBox(width: 170, child: slideCard('上滑入', AylaPanelEdge.top)),
          ],
        ),
        const SizedBox(height: AylaSpacing.sp2),
        Text('② 右滑返回（阈值 120px 或速度 ≥300px/s；松手未过阈值回弹）', style: t.cardTitle.copyWith(fontSize: 13, fontWeight: FontWeight.w600)),
        SizedBox(
          width: 340,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            spacing: AylaSpacing.sp2,
            children: <Widget>[
              AylaFullScreenSwipeBack(
                key: _swipeBackKey,
                onBack: () => setState(() => _backCount++),
                child: blank(
                  label: '在这一行上向右滑 →',
                  hint: '已触发返回 $_backCount 次',
                ),
              ),
              // 跟手档重播：也可以直接手滑；这两个键把同一段手势一键重放，
              // 用来对照「过阈值触发」与「不过阈值回弹」两条路径。
              Row(
                spacing: AylaSpacing.sp2,
                children: <Widget>[
                  Expanded(
                    child: AylaGlassButton(
                      label: '模拟右滑 · 过阈值',
                      minHeight: 28,
                      fontSize: 12,
                      expand: true,
                      onPressed: () => _simulateSwipeBack(200),
                    ),
                  ),
                  Expanded(
                    child: AylaGlassButton(
                      label: '模拟右滑 · 回弹',
                      variant: AylaGlassButtonVariant.ghost,
                      minHeight: 28,
                      fontSize: 12,
                      expand: true,
                      onPressed: () => _simulateSwipeBack(60, steps: 24),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: AylaSpacing.sp2),
        Text('③ 切换选项卡（横滑判定：净位移 ≥ 宽/3 或甩动 ≥300px/s）', style: t.cardTitle.copyWith(fontSize: 13, fontWeight: FontWeight.w600)),
        SizedBox(
          width: 340,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            spacing: AylaSpacing.sp2,
            children: <Widget>[
              Row(
                spacing: AylaSpacing.sp2,
                children: <Widget>[
                  for (int i = 0; i < _tabs.length; i++)
                    Expanded(
                      child: AylaGlassButton(
                        label: _tabs[i],
                        variant: i == _tab
                            ? AylaGlassButtonVariant.primary
                            : AylaGlassButtonVariant.ghost,
                        minHeight: 28,
                        fontSize: 12,
                        expand: true,
                        onPressed: () => setState(() {
                          _dir = i > _tab ? 1 : -1;
                          _tab = i;
                        }),
                      ),
                    ),
                ],
              ),
              AylaPrimaryNavPage(
                key: ValueKey<int>(_tab),
                direction: _dir,
                // 与 web 一致：`onNavigate` 的 +1 = 下一项（手指左滑），落页 `(idx + step + len) % len`
                onNavigate: (int step) => setState(() {
                  _dir = step;
                  _tab = (_tab + step + _tabs.length) % _tabs.length;
                }),
                child: blank(
                  label: '第 ${_tab + 1} 页 · ${_tabs[_tab]}',
                  hint: '向左滑下一页 / 向右滑上一页', // web `forward = net < 0`：手指左滑 ⇒ 下一项
                  tint: AylaColors.glassBgStrong,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: AylaSpacing.sp2),
        Text(
          '④ 会话转场（mode="wait"：旧件先退 300ms、退完才挂新件；panels 档切换）',
          style: t.cardTitle.copyWith(fontSize: 13, fontWeight: FontWeight.w600),
        ),
        SizedBox(
          width: 340,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            spacing: AylaSpacing.sp2,
            children: <Widget>[
              Row(
                spacing: AylaSpacing.sp2,
                children: <Widget>[
                  Expanded(
                    child: AylaGlassButton(
                      label: '切换会话',
                      minHeight: 28,
                      fontSize: 12,
                      expand: true,
                      onPressed: () => setState(() => _conv++),
                    ),
                  ),
                  Expanded(
                    child: AylaGlassButton(
                      label: _panels ? 'panels: true' : 'panels: false',
                      variant: AylaGlassButtonVariant.ghost,
                      minHeight: 28,
                      fontSize: 12,
                      expand: true,
                      onPressed: () => setState(() => _panels = !_panels),
                    ),
                  ),
                ],
              ),
              AylaConversationTransition(
                identity: '会话 ${_conv + 1}',
                panels: _panels,
                builder: (BuildContext context, String id) => blank(
                  label: id,
                  hint: _panels
                      ? '宿主透明（子件自己播）'
                      : '宿主自播 right +20 → left −20',
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// 手势四件的文字说明样张（视觉演示在上一节「手势动画（空白卡片模拟）」）。
class _MotionPiecesNote extends StatelessWidget {
  const _MotionPiecesNote();

  @override
  Widget build(BuildContext context) {
    final AylaTextStyles t = AylaTextStyles.of(context);
    const List<(String, String)> rows = <(String, String)>[
      ('AylaPanelTransition', '四向滑入面板（±20px / 300ms）· enter→center→exit，exit 边可另指定'),
      ('AylaConversationTransition', '会话转场宿主：旧件先退 300ms，退完才挂最新件（mode="wait"）'),
      ('AylaFullScreenSwipeBack', '全屏右滑返回：≥120px 或 ≥300px/s ⇒ onBack，否则 200ms 回弹'),
      ('AylaPrimaryNavPage', '一级页横滑：跟手 0.8 + 松手 1/3 宽判定 + 方向相关进出（0 ⇒ 只淡入淡出）'),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      spacing: AylaSpacing.sp2,
      children: <Widget>[
        for (final (String name, String desc) in rows)
          Row(
            spacing: AylaSpacing.sp3,
            children: <Widget>[
              SizedBox(
                width: 210,
                child: Text(name, style: t.timestamp.copyWith(fontSize: 12)),
              ),
              Expanded(child: Text(desc, style: t.body.copyWith(fontSize: 13))),
            ],
          ),
      ],
    );
  }
}

/// 收藏项容器样张：窄档（padding sp3）与宽档（padding sp4）各一张。
class _FavoriteItemDemo extends StatelessWidget {
  const _FavoriteItemDemo();

  @override
  Widget build(BuildContext context) {
    final AylaTextStyles t = AylaTextStyles.of(context);
    Widget inner(String label) => Container(
      height: 64,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: AylaColors.glassBgStrong,
        borderRadius: BorderRadius.circular(AylaRadii.rInput),
        border: Border.all(color: AylaColors.glassBorder),
      ),
      child: Text(label, style: t.body),
    );
    return Wrap(
      spacing: AylaSpacing.sp6,
      runSpacing: AylaSpacing.sp6,
      crossAxisAlignment: WrapCrossAlignment.start,
      children: <Widget>[
        _Slot(
          label: '窄档（<769：padding sp3）',
          child: SizedBox(
            width: 360,
            child: AylaFavoriteItem(child: inner('收藏内容（typed 卡）')),
          ),
        ),
        _Slot(
          label: '宽档（≥769：padding sp4）',
          child: SizedBox(
            width: 420,
            child: AylaFavoriteItem(child: inner('收藏内容（typed 卡）')),
          ),
        ),
      ],
    );
  }
}

// ======================= B9 编辑面样张（2026-09-28） =======================

/// 个人主页编辑面样张：状态胶囊 / 开关行 / 表单装配（含已保存与错误行）。
class _ProfileEditDemo extends StatelessWidget {
  const _ProfileEditDemo();

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        _Row(
          children: <Widget>[
            _Slot(
              label: '在线状态胶囊（role=radiogroup；点击切换 · hover 整颗加亮 1.04）',
              width: 420,
              child: const _StatusChipsStage(),
            ),
            _Slot(
              label: '开关行（off / on / 禁用档）· 点整行或点开关都能切换',
              width: 420,
              child: const _ProfileSwitchStage(),
            ),
          ],
        ),
        const SizedBox(height: AylaSpacing.sp6),
        _Row(
          children: <Widget>[
            _Slot(
              label: '表单装配 · 默认态（dirty ⇒ 保存键可用）',
              width: 420,
              child: const _ProfileFormStage(),
            ),
            _Slot(
              label: '表单装配 · 已保存 + 错误行（saved && !dirty ⇒ 保存键禁用）',
              width: 420,
              child: const _ProfileFormStage(saved: true, error: '保存失败，请稍后重试'),
            ),
          ],
        ),
      ],
    );
  }
}

/// 状态胶囊舞台（可交互）。
class _StatusChipsStage extends StatefulWidget {
  const _StatusChipsStage();

  @override
  State<_StatusChipsStage> createState() => _StatusChipsStageState();
}

class _StatusChipsStageState extends State<_StatusChipsStage> {
  String _status = 'auto';

  @override
  Widget build(BuildContext context) {
    return AylaStatusChips(
      value: _status,
      onChanged: (String value) => setState(() => _status = value),
    );
  }
}

/// 开关行舞台（off / on / 禁用三态）。
class _ProfileSwitchStage extends StatefulWidget {
  const _ProfileSwitchStage();

  @override
  State<_ProfileSwitchStage> createState() => _ProfileSwitchStageState();
}

class _ProfileSwitchStageState extends State<_ProfileSwitchStage> {
  bool _off = false;
  bool _on = true;

  static const String _desc =
      '开启后，他人可在你的主页看到「他的内容」（发帖/直播间/桌游）';

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      spacing: AylaSpacing.sp4,
      children: <Widget>[
        AylaProfileSwitch(
          label: '向他人展示内容',
          description: _desc,
          value: _off,
          onChanged: (bool value) => setState(() => _off = value),
        ),
        AylaProfileSwitch(
          label: '向他人展示内容（on 档）',
          description: _desc,
          value: _on,
          onChanged: (bool value) => setState(() => _on = value),
        ),
        // web 无禁用档；本档留给调用方（按 button:disabled 语义 opacity .55）
        const AylaProfileSwitch(
          label: '向他人展示内容（禁用档）',
          value: false,
          onChanged: null,
        ),
      ],
    );
  }
}

/// 表单装配舞台（[saved] / [error] 决定已保存提示与错误行）。
class _ProfileFormStage extends StatefulWidget {
  const _ProfileFormStage({this.saved = false, this.error});

  final bool saved;
  final String? error;

  @override
  State<_ProfileFormStage> createState() => _ProfileFormStageState();
}

class _ProfileFormStageState extends State<_ProfileFormStage> {
  final TextEditingController _nickname = TextEditingController(text: '爱莉');
  final TextEditingController _signature = TextEditingController(
    text: '今天也想见你',
  );
  String _status = 'auto';
  bool _showContent = false;

  @override
  void dispose() {
    _nickname.dispose();
    _signature.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AylaProfileForm(
      nicknameController: _nickname,
      signatureController: _signature,
      nicknamePlaceholder: 'elysia', // web: placeholder={currentUser.username}
      status: _status,
      onStatusChanged: (String value) => setState(() => _status = value),
      showContent: _showContent,
      onShowContentChanged: (bool value) => setState(() => _showContent = value),
      saved: widget.saved,
      dirty: !widget.saved, // 已保存档 ⇒ 无改动 ⇒ 保存键禁用 +「已保存」
      error: widget.error,
      onSave: () {},
      onLogout: () {},
    );
  }
}

/// 群信息设置面样张：设置块（两档）/ 申请审批（含空态与 busy）/ 成员搜索 / 子群展开。
class _GroupInfoSettingsDemo extends StatefulWidget {
  const _GroupInfoSettingsDemo();

  @override
  State<_GroupInfoSettingsDemo> createState() => _GroupInfoSettingsDemoState();
}

class _GroupInfoSettingsDemoState extends State<_GroupInfoSettingsDemo> {
  String? _joinPolicy = 'application';
  bool _allowUpload = false;
  bool _busy = false;

  final TextEditingController _memberQuery = TextEditingController();

  static const List<AylaGroupJoinRequest> _requests = <AylaGroupJoinRequest>[
    AylaGroupJoinRequest(id: 'r1', name: '小雪', message: '想进来一起玩'),
    AylaGroupJoinRequest(id: 'r2', name: '阿澈'), // message 为空 ⇒ msg 行不渲染
    AylaGroupJoinRequest(
      id: 'r3',
      name: '名字很长的申请人甲乙丙丁戊己庚辛',
      message: '这是一条很长的申请留言，用来验证单行省略号是否生效',
    ),
  ];

  @override
  void dispose() {
    _memberQuery.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        _Row(
          children: <Widget>[
            _Slot(
              label: '设置块 · owner 档（下拉可展开 · 开关可点 · 行间 1px 分隔线）',
              width: 420,
              child: AylaGroupInfoSettingsBox(
                children: <Widget>[
                  AylaGroupInfoSettingRow(
                    label: '加入方式',
                    trailing: AylaGroupInfoSelect(
                      value: _joinPolicy,
                      onChanged: (String value) =>
                          setState(() => _joinPolicy = value),
                    ),
                  ),
                  AylaGroupInfoSwitch(
                    label: '成员可上传表情包',
                    value: _allowUpload,
                    onChanged: (bool value) =>
                        setState(() => _allowUpload = value),
                  ),
                ],
              ),
            ),
            _Slot(
              label: '设置块 · 非 owner 档（只读值 + 开关禁用 opacity .6）',
              width: 420,
              child: const AylaGroupInfoSettingsBox(
                children: <Widget>[
                  AylaGroupInfoSettingRow(label: '加入方式', value: '申请加入'),
                  AylaGroupInfoSwitch(
                    label: '成员可上传表情包',
                    value: true,
                    onChanged: null,
                  ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: AylaSpacing.sp6),
        _Row(
          children: <Widget>[
            _Slot(
              label: '入群申请审批（3 条；busy 时两键禁用）',
              width: 420,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                spacing: AylaSpacing.sp3,
                children: <Widget>[
                  AylaGroupJoinRequests(
                    total: 3,
                    requests: _requests,
                    busy: _busy,
                    onAccept: (AylaGroupJoinRequest request) {},
                    onReject: (AylaGroupJoinRequest request) {},
                  ),
                  AylaGlassButton(
                    label: _busy ? 'busy = true（点一下复位）' : 'busy = false（点一下置位）',
                    variant: AylaGlassButtonVariant.ghost,
                    fontSize: 12,
                    minHeight: 30,
                    onPressed: () => setState(() => _busy = !_busy),
                  ),
                ],
              ),
            ),
            _Slot(
              label: '空态 / 加载中 / 加载失败（无申请时的三条文案）',
              width: 420,
              child: const Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                spacing: AylaSpacing.sp6,
                children: <Widget>[
                  AylaGroupJoinRequests(
                    total: 0,
                    requests: <AylaGroupJoinRequest>[],
                  ),
                  AylaGroupJoinRequests(
                    total: 0,
                    requests: <AylaGroupJoinRequest>[],
                    loading: true,
                  ),
                  AylaGroupJoinRequests(
                    total: 0,
                    requests: <AylaGroupJoinRequest>[],
                    error: true,
                  ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: AylaSpacing.sp6),
        _Row(
          children: <Widget>[
            _Slot(
              label: '成员搜索框（.field 档 · placeholder「搜索成员」· web 无搜索图标）',
              width: 420,
              child: AylaGroupMemberSearchField(controller: _memberQuery),
            ),
            _Slot(
              label: '子群展开（收起「查看更多（2）」/ 展开「收起」；aria-expanded）',
              width: 420,
              child: const Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                spacing: AylaSpacing.sp6,
                children: <Widget>[
                  AylaGroupSubgroupExpandButton(
                    hiddenCount: 2,
                    expanded: false,
                    onPressed: null,
                  ),
                  AylaGroupSubgroupExpandButton(
                    hiddenCount: 2,
                    expanded: true,
                    onPressed: null,
                  ),
                ],
              ),
            ),
          ],
        ),
      ],
    );
  }
}

/// 目录页族样张（A 类跨页复用件 5 件）。
///
/// 宽/窄两档必须覆写 `MediaQuery`（画布宿主恒宽 ⇒ 不覆写只会渲染宽屏档）；
/// 档内文案逐字取自 web：FavoritesPage.tsx:274–275（空态）·
/// UserPostsRoute.tsx:60–65（受阻态）· VoiceHubPage.tsx:262–263（加载态）。
class _DirectoryPageDemo extends StatelessWidget {
  const _DirectoryPageDemo();

  /// `FavoritesPage.tsx:19–26` 的分类选项（逐字）。
  static const List<({String key, String label})> _options =
      <({String key, String label})>[
    (key: 'all', label: '全部'),
    (key: 'message', label: '消息'),
    (key: 'post', label: '帖子'),
    (key: 'live', label: '直播'),
    (key: 'voice', label: '语音房'),
    (key: 'game', label: '桌游房'),
  ];

  /// `.skeleton`（base.css）最简等价块（不引骨架动画，画布只审布局）。
  static Widget _skeleton({double height = 96}) => Container(
    height: height,
    decoration: BoxDecoration(
      color: AylaColors.ice100,
      borderRadius: BorderRadius.circular(AylaRadii.rSm),
    ),
  );

  static Widget _stage(
    BuildContext context, {
    required bool narrow,
    required Size size,
  }) {
    return SizedBox(
      width: size.width,
      height: size.height,
      child: MediaQuery(
        data: MediaQuery.of(context).copyWith(size: size),
        child: AylaDirectoryPage(
          filters: AylaDirectoryFilters(
            label: '收藏分类',
            options: _options,
            value: 'all',
            onChange: (String _) {},
            narrow: narrow,
            leading: narrow ? null : AylaDirectoryBackButton(onPressed: () {}),
            decor: narrow
                ? null
                : AylaDirectoryDecorIcon(icon: aylaIconByName('iconHeart')!),
            header: narrow
                ? null
                : const AylaDirectorySidebarHeader(
                    kicker: 'Favorites',
                    title: '我的收藏',
                    stats: '12 条收藏',
                  ),
          ),
          content: AylaDirectoryContent(
            fadeGlass: false,
            label: '全部',
            child: const AylaPageState(
              title: '这个分类还没有收藏',
              description: '在对应场景点收藏，内容会出现在这里',
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    Widget decor(String name, String label) => Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        AylaDirectoryDecorIcon(icon: aylaIconByName(name)!),
        const SizedBox(height: AylaSpacing.sp2),
        Text(
          label,
          style: AylaTextStyles.light.timestamp.copyWith(
            color: AylaColors.textSecondary,
          ),
        ),
      ],
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        _Row(
          children: <Widget>[
            _Slot(
              label: '宽屏（≥769）：page padding sp3 sp3 0 · 侧栏 224 + gap sp3 + 内容区剩余宽'
                  '（绘制带左/右/上各外扩 12，内容位置不变）',
              child: _stage(context, narrow: false, size: const Size(1400, 560)),
            ),
            _Slot(
              label: '窄屏（≤768）：page padding 0 · 顶栏 + 内容单列（gap 0）· 内容 padding sp2 sp4 (68+safe)',
              child: _stage(context, narrow: true, size: const Size(420, 560)),
            ),
          ],
        ),
        const SizedBox(height: AylaSpacing.sp6),
        _Row(
          children: <Widget>[
            _Slot(
              label: 'AylaDirectorySidebarHeader：Favorites / 我的收藏 / 12 条收藏'
                  '（侧栏 224 内；条数为代入值，web 是变量）',
              width: 224,
              child: const AylaDirectorySidebarHeader(
                kicker: 'Favorites',
                title: '我的收藏',
                stats: '12 条收藏',
              ),
            ),
            _Slot(
              label: 'AylaDirectoryDecorIcon：六处调用点图标'
                  '（size 64 / pink-500 / opacity .42 / rotate −8°；标签 = 各页 kicker）',
              width: 520,
              child: Wrap(
                spacing: AylaSpacing.sp4,
                runSpacing: AylaSpacing.sp4,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: <Widget>[
                  decor('iconSearch', 'Search'),
                  decor('iconHeart', 'Favorites'),
                  decor('iconMic', 'Voice'),
                  decor('iconVideo', 'Live'),
                  decor('iconPost', 'Posts'),
                  decor('iconGame', 'Games'),
                ],
              ),
            ),
            _Slot(
              label: 'AylaDirectoryBackButton（.directory-filter-back = .icon-btn-40：40×40 + IconBack 20）',
              width: 200,
              child: AylaDirectoryBackButton(onPressed: () {}),
            ),
          ],
        ),
        const SizedBox(height: AylaSpacing.sp6),
        _Row(
          children: <Widget>[
            _Slot(
              label: 'AylaPageState 空态（FavoritesPage.tsx:274–275 逐字）',
              width: 360,
              child: const AylaPageState(
                title: '这个分类还没有收藏',
                description: '在对应场景点收藏，内容会出现在这里',
              ),
            ),
            _Slot(
              label: 'AylaPageState 受阻态（UserPostsRoute.tsx:60–65 逐字 · role=alert ⇒ liveRegion）',
              width: 360,
              child: AylaPageState(
                title: '对方未开启内容展示',
                description: '对方关闭了「向他人展示内容」，暂时无法查看其帖子',
                liveRegion: true,
                children: <Widget>[
                  AylaGlassButton(
                    label: '返回主页',
                    variant: AylaGlassButtonVariant.ghost,
                    onPressed: () {},
                  ),
                ],
              ),
            ),
            _Slot(
              label: 'AylaPageState 加载态（VoiceHubPage.tsx:262–263 逐字 · role=status）',
              width: 360,
              child: AylaPageState(
                liveRegion: true,
                children: <Widget>[_skeleton(), const Text('正在加载语音房…')],
              ),
            ),
          ],
        ),
      ],
    );
  }
}
