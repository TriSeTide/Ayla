/// 组件画布冒烟测试：渲染画布、**按分类导航逐类遍历**，捕获任何运行期类型/布局错误。
///
/// 画布 2026-09-25 起是「左侧分类导航 + 右侧内容区」（`ComponentGallery`）：
/// 未访问过的分类**连 Element 都不建**，所以「一次断言全部分区标题」已不成立 ⇒
/// 本测试改为**逐类点选后断言该类分区标题**（这份清单同时是分组回归锁）。
///
/// 另一条自检：**「未分类（映射遗漏）」必须为空** —— 分区靠标题前缀映射到分类
/// （`kGalleryCategories`），漏映射的分区会落到兜底类，这里断言兜底类里一个分区都没有。
///
/// 跑法（Windows 侧）：
///   E:\flutter-3.47.4\bin\flutter.bat test test/smoke_gallery_test.dart
library;

import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../lib/preview/component_gallery.dart';
import '../lib/theme/preview_theme.dart';

/// 期望的「分类 → 该类的分区标题」（与 `kGalleryCategories` 的前缀映射一致）。
const Map<String, List<String>> kExpectedSections = <String, List<String>>{
  '基元 · 材质 · 排版': <String>[
    'AylaGlassButton（app.css .btn 21–67 / auroraqua.css 54–166）',
    'AylaGlassCard（app.css .glass-card 230–248）',
    'AylaAuroraBackground（base.css 50–314 五层流体极光背景 + tokens.css 28–63）',
    'AylaGlassInput（app.css .field 70–88 / auroraqua.css 502–523）',
    'AylaGlassQuality（性能旋钮：真玻璃 / 预模糊 / 实底；13 号 §8.17）',
    'AylaAvatarHalo（app.css .avatar-halo 312–380 / base.css halo-breathe）',
    'AylaTabBadge（shell.css .tab-badge 579–593 · home.css .group-badge 302–317 · messages.css .messages-tab-badge 43–55）',
    'AylaRevealItem / AylaRevealScope（base.css .reveal-item · auroraqua.css 8–26 · useListEntryMotion）',
    'Skeleton + Spinner + AylaFullScreenLoader（base.css 515–574）',
    'Icon 图标库（web components/icons.tsx 全量 47 个）',
    'Batch 2 基元（LayoutSwitch / SegmentedTab / CapsuleTag / ScrollingText）',
    'Typography（design.md §3 九级）',
    'AylaTooltip（web `title=` 28 处；提示气泡由浏览器/OS 绘制，无 CSS 可移植）',
    'AylaSwitch（通用开关 —— group.css 1924–1993 群档 + profile.css 400–434 个人档 + base.css 6–7）',
  ],
  'Shell · 导航壳与浮层': <String>[
    'AylaBottomTabs（layout/BottomTabs.tsx 1–91 + shell.css 77–162）',
    'AylaGroupTopTabs（components/group/GroupTopTabs.tsx 1–125 + group.css 21–91）',
    'AylaTopNav（layout/TopNav.tsx 1–343 / layout/NarrowTopBar.tsx 1–199）',
    'AylaServerRail（layout/ServerRail.tsx 1–184 + group.css 484–678 + auroraqua.css 216 / 217–229 / 270 / 311–313 / 125–138）',
    'AylaChannelSidebar（layout/ChannelSidebar.tsx 1–627 + group.css 680–1370 + auroraqua.css 54–94 / 142–197 / 236–249 / 288–291 / 310–313 / 655–676）',
    'AylaCreateSheet（layout/CreateSheet.tsx 1–61 + private.css 185–275）',
    'AylaCornerFabStack / AylaRefreshFab / AylaScrollTopFab / AylaQuickMessageFab（layout/*.tsx + shell.css 423–456 / 679–787）',
    'AylaSessionActivityIndicator（layout/SessionActivityIndicator.tsx 1–181 + shell.css 458–575 / 651–660）',
  ],
  'chat · 气泡 / 列表 / 输入 / 面板': <String>[
    '聊天消息气泡（MessageBubble.tsx）',
    '媒体消息族（MediaContent.tsx）',
    '分享卡 / 爱莉入口卡（ShareBubble.tsx + ElysiaEntry.tsx）',
    '会话列表（ConversationList.tsx）',
    '@ 成员选择器（MentionPicker.tsx）',
    '群表情包面板（EmojiPackPanel.tsx）',
    '消息输入区（MessageInput.tsx）',
    '消息滚动区（MessageList.tsx）',
    '消息中心选项卡（messages-tabs；WideMessagesSidebar 与 QuickMessagesSheet 共用）',
    '认证消息面板（WideMessagesSidebar / QuickMessagesSheet 共用）',
    '私聊面板（PrivateChatPane.tsx）',
    '宽屏消息左列（WideMessagesSidebar.tsx）',
    '快捷消息栏（QuickMessagesSheet.tsx）',
    'AylaImageViewer（ImageViewer.tsx + app.css 1459–1836 + auroraqua.css 55–94）',
  ],
  'live · 直播域': <String>[
    'AylaDanmakuList / AylaDanmakuInput / AylaDanmakuOverlay（components/live/Danmaku{List,Input,Overlay}.tsx 139+180+213 行 + danmakuTracks.ts 55 行 + app.css 3671–3827 + live.css 756–784/860–929/1006–1018 + auroraqua.css 347–359/378–383/390/502–523）',
    'AylaLiveChannelCard / AylaLiveHall（components/live/LiveChannelCard.tsx 53 行 + LiveHall.tsx 45 行 + app.css 3275–3397 + live.css 486–493/559–596/617–655/811–814/1333–1354 + shell.css 619–629 + auroraqua.css 29–52）',
    'AylaLiveChannelRail / AylaLiveStartSheet（components/live/LiveChannelRail.tsx 168 行 + LiveStartSheet.tsx 86 行 + live.css 10–29/48–139/232–239/311–423/1356–1370 + auroraqua.css 125–139/175–205/412–454）',
    'AylaLiveViewerStrip / AylaLiveViewerSheet / AylaLiveHostAvatar / AylaLiveStreamAddresses（components/live/LiveViewerStrip.tsx 85 行 + LiveViewerSheet.tsx 147 行 + LiveHostAvatar.tsx 52 行 + LiveStreamAddresses.tsx 72 行 + live.css 206–229/1095–1325/249–257 + app.css 3443–3477）',
    'AylaLiveHostAvatar / AylaLiveStreamAddresses（同批：主播头像 + 推流地址区）',
    'AylaLiveCreate（components/live/LiveCreate.tsx 189 行 + app.css 3401–3477 + live.css 32–33/164–174 + auroraqua.css 502–531）',
    'AylaLiveOwnerPanel（components/live/LiveOwnerPanel.tsx 217 行 + app.css 3831–3843 + live.css 168–180/190–269）',
    'AylaLivePlayer（components/live/LivePlayer.tsx 420 行 + app.css 3517–3636 + live.css 939–1005）',
    'AylaLiveMiniPlayer（components/live/LiveMiniPlayer.tsx 228 行 + live.css 1021–1095）',
    'AylaLiveRoomBody（components/live/LiveRoomBody.tsx 566 行 + live.css 10–29/520–760 + auroraqua.css 202–211/316–321/437–445）',
  ],
  'voice · 语音域': <String>[
    'AylaVoiceChannelCard / AylaVoiceChannelList / AylaVoiceControls（components/voice/*.tsx 121 行 + app.css 2811–2832 · 2910–2915 · 3099–3120 + voice.css 471–485 · 505–628 · 647–659 · 690–789）',
    'AylaVoiceMemberRow（components/voice/VoiceMemberRow.tsx 219 行 + app.css 2917–3095 + auroraqua.css 59/77/89/664）',
    'AylaVoiceChannelCreate（components/voice/VoiceChannelCreate.tsx 80 行 + app.css 2848–2869 + auroraqua.css 502–531 + private.css 229–236）',
    'AylaVoiceChannelPanel（components/voice/VoiceChannelPanel.tsx 158 行 + app.css 2873–2915 + voice.css 32–56/377–381 + auroraqua.css 584–610）',
    'AylaElysiaVoicePanel（components/voice/ElysiaVoicePanel.tsx 108 行 + app.css 3122–3156 / 1324–1333 / 1362）',
    'AylaVoiceRoomBody（components/voice/VoiceRoomBody.tsx 327 行 + voice.css 12–470 + app.css 2105–2138/3473–3477 + base.css 463–472）',
  ],
  'posts · 帖子 / 评论': <String>[
    'AylaMasonryGrid（useMasonryColumns.ts 146 行 + posts.css 607–694 / profile.css 458–545）',
    'AylaPostCard / AylaPostVideoCover（PostCard.tsx + posts.css 9–217 + typed-result-cards.css 5,7）',
    'AylaPostEditor（PostEditor.tsx + posts.css 219–418 + auroraqua.css 105–166）',
    'AylaGroupPostsComposer（posts.css 933–951/1011–1108 + auroraqua.css 347–368）',
    'AylaCommentList / AylaCommentComposer（CommentList.tsx + CommentComposer.tsx + posts.css 420–583）',
  ],
  'group · 群与目录': <String>[
    'GroupCard / GroupCarousel（home.css 224–503 + auroraqua 29–52）',
    '子群弹窗（SubGroupDialog.tsx 111 行 + group.css 2131–2231）',
    '群聊申请弹窗（GroupApplyDialog.tsx 25–137 行 + search.css 175–296）',
    '建群对话框（GroupCreateDialog.tsx 184 行 + private.css 66–186 / 188–280）',
    '目录结果卡（DirectoryResultCards.tsx 119 行 + typed-result-cards.css）',
    'AylaTransferOwnerDialog（GroupInfo.tsx 904–1010 + app.css 3894–4005）',
    'AylaGroupRoleChip（group.css 1734–1750 + GroupInfo.tsx 52–56）',
    'AylaGroupInfoProfile（GroupInfo.tsx 461–520 + group.css 1382–1610 / 2235–2240）',
    'AylaGroupInfoSettingRow / AylaGroupInfoSwitch / AylaGroupInfoSelect / AylaGroupJoinRequests / 成员搜索 / 子群展开（GroupInfo.tsx 531–624/709–718/754 + group.css 1678–1687/1796–2047/2109–2116）',
    'AylaGroupInfoSectionTitle / AylaGroupInfoCardHead / AylaGroupInfoDangerActions（GroupInfo.tsx 523–526/628–645/651–663/748–752 + group.css 1610–1675/2050–2107）',
    'AylaGroupInfoLayout / AylaGroupSubgroupList / AylaGroupMemberList（GroupInfo.tsx 401–405/670–790/1012–1018 + group.css 1421–1459/1461–1465/1690–1732/1752–1787/2062–2128）',
    'AylaDirectoryPage / AylaDirectoryContent / AylaDirectorySidebarHeader / AylaDirectoryDecorIcon / AylaDirectoryBackButton / AylaPageState（directory-filters.css 2–257 + home.css 620–629 + shell.css 595–629 + 六个目录页 TSX）',
    'AylaGroupSceneHead / AylaGroupScenePlaceholder（group.css 358–475 + auroraqua.css 336/419/621/637）',
    'AylaGroupChatSubgroupBar（group.css 152–331 + GroupChat.tsx 334–407）',
  ],
  'boardgame · 桌游域': <String>[
    'AylaGamesGrid / AylaGamesGridSkeleton（GamesHubPage.tsx 184–216 + boardgame.css 232–275）',
    '桌游室卡片（GameRoomCard.tsx 53 行 + boardgame.css 9–119 + auroraqua.css 28–52 + typed-result-cards.css 44）',
    '创建桌游室表单（GameRoomCreate.tsx 78 行 + boardgame.css 123–132 + app.css 70–79 + private.css 229–236）',
    '桌游室占位整页壳（GameRoomPlaceholder.tsx 189 行 + boardgame.css 136–219 + auroraqua.css 335/402–408/418）',
  ],
  'profile · 个人主页域': <String>[
    'AylaFavoriteItem（FavoritesPage.tsx 95 + profile.css 474–487 / 539–541）',
    'AylaProfileCard / AylaProfileIdentity / AylaProfileAvatarActions（ProfilePage.tsx 154–180 + app.css 241–248/2657–2695 + profile.css 14–16/44–52/142–171/584–591/623–625）',
    'AylaFavoritesSkeleton（FavoritesPage.tsx 268–271 + profile.css 452–456）',
    '个人主页内容分区（ProfileContentSections.tsx 211 行 + profile.css 174–380）',
    'AylaStatusChips / AylaProfileSwitch / AylaProfileForm（ProfilePage.tsx 212–305 + app.css 2696–2749 + profile.css 47–51/377–440/593–611 + auth.css 79–87）',
  ],
  'search · 搜索域': <String>[
    'AylaSearchHistoryChips（search.css 11–30 + SearchPage.tsx 362–372）',
    'AylaSearchResultGroup（ResultGroup：SearchPage.tsx 494–521 + search.css 68–105）',
    'AylaSearchUserRow（search.css 107–176 + SearchPage.tsx 391–408）',
  ],
  'motion · 转场与手势': <String>[
    'AylaPageTransition / AylaPageSwap（PageTransition.tsx 117 行 + AppShell.tsx:113）',
    '手势动画（空白卡片模拟）—— 淡入淡出 · 左上右下四向滑入 · 右滑返回 · 切换选项卡',
    'AylaPanelTransition / AylaConversationTransition / AylaFullScreenSwipeBack / AylaPrimaryNavPage（auroraquaMotion panel 段 + useSwipeCommit / useEdgeSwipeBack / ConversationTransition / FullScreenSwipeBack / PrimaryNavPage）',
  ],
  '通用件 · 分享 / 分页 / 弹层 / 资源': <String>[
    'AylaShareSheet / AylaShareButton（ShareSheet.tsx + ShareButton.tsx + share.css 1–275）',
    'AylaResourceImage（AylaResourceImage.tsx + api/media.ts）',
    'AylaConfirmDialog / AsyncState（AylaConfirmDialog.tsx + AsyncState.tsx）',
    'PullToRefresh / AylaSignedVideo（PullToRefresh.tsx + AylaSignedVideo.tsx）',
    '分页族 / 收藏按钮（DirectoryLoadMore + AylaStablePaginationFooter + FavoriteButton）',
    'VisibilitySelector / 资料卡 / 筛选条 / 隐私设置',
    '覆盖层滚动条（OverlayScrollbar.tsx 311 行 + base.css 385–421）',
  ],
};

void main() {
  /// 真实宿主等价环境：MaterialApp 提供 Directionality/Material/Localizations。
  Widget host(Widget child) => MaterialApp(home: previewScope(child));

  /// 画布真实宽度（组件画布按 1800 宽排布）。
  ///
  /// ⚠️ 必须显式钉死：默认测试窗口物理 800×600 / **DPR 3** ⇒ 逻辑仅 266×200，
  /// 带固定侧栏的样张会被挤到溢出（2026-09-22 实测）。
  void pinCanvas(WidgetTester tester) {
    tester.view.physicalSize = const Size(1800, 1400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
  }

  testWidgets('画布：分类导航可切换；未访问的分类不构建；未分类必须为空', (
    WidgetTester tester,
  ) async {
    pinCanvas(tester);
    await tester.pumpWidget(host(const ComponentGallery()));
    await tester.pump();

    // 导航项数 = 分类数 + 「未分类」兜底
    expect(kGalleryCategories.length, kExpectedSections.keys.length);
    expect(find.text(kExpectedSections.keys.first), findsOneWidget);

    // 其它分类**不构建**（连 offstage 都没有）
    expect(
      find.text('聊天消息气泡（MessageBubble.tsx）', skipOffstage: false),
      findsNothing,
    );

    // 逐类点选，断言该类的全部分区标题
    for (final MapEntry<String, List<String>> entry
        in kExpectedSections.entries) {
      // 导航上的分类计数（= `prefixes.length`）必须与该类分区数一致
      final AylaGalleryCategory category = kGalleryCategories.firstWhere(
        (AylaGalleryCategory c) => c.label == entry.key,
      );
      expect(category.prefixes.length, entry.value.length, reason: entry.key);
      await tester.tap(find.text(entry.key));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 320)); // 共享胶囊迁移 300ms
      for (final String title in entry.value) {
        expect(
          find.text(title),
          findsOneWidget,
          reason: '${entry.key} → $title',
        );
      }
    }

    // 兜底类：映射必须无遗漏 —— 该桶自己报数（0 = 全部标题前缀都进了 kGalleryCategories）
    await tester.tap(find.text('未分类（映射遗漏）'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 320));
    expect(find.textContaining('无未分类分区'), findsOneWidget);
    for (final List<String> titles in kExpectedSections.values) {
      for (final String title in titles) {
        expect(
          find.text(title), // 只看**可见**的（访问过的分类此时 offstage 保活，不算）
          findsNothing,
          reason: '未分类里不该出现 $title（前缀映射漏了？）',
        );
      }
    }
  });

  testWidgets('hover AylaGlassButton 触发扫光与缩放不抛错', (WidgetTester tester) async {
    pinCanvas(tester);
    await tester.pumpWidget(host(const ComponentGallery()));
    await tester.pump();

    // 模拟鼠标指针(3.47 无 tester.hover,用 createGesture)
    final TestGesture mouse = await tester.createGesture(
      kind: PointerDeviceKind.mouse,
    );
    await mouse.addPointer(location: Offset.zero);
    await mouse.moveTo(tester.getCenter(find.text('登录').first));
    await tester.pump();
    // 扫光 600ms 全段
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 200));

    // 移出后再走一遍 reverse
    await mouse.moveTo(const Offset(0, 0));
    await tester.pump(const Duration(milliseconds: 700));
  });
}
