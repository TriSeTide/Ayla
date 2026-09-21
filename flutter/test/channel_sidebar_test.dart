/// AylaChannelSidebar 定向测试（重做版）。
///
/// 事实源：`layout/ChannelSidebar.tsx`（627 行）+ `group.css` 680–1370 +
/// `auroraqua.css` 54–94 / 142–197 / 236–249 / 288–291 / 310–313 / 655–676 +
/// `hooks/useSidebarContentClip.ts` + `auroraquaMotion.ts`。
/// 推导表：`docs/flutter/16-频道侧栏推导表.md`。
///
/// ⚠️ 两条既有教训（`13-*` §测试坑）：
/// 1. `previewScope` 的 `Overlay(initialEntries:)` **只在首次创建生效** →
///    同一 `testWidgets` 里换参数必须走 `StatefulBuilder`（见 [hostStateful]）；
/// 2. `SemanticsHandle` 必须在**测试体内** dispose（`addTearDown` 晚于框架校验）。
library;

import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../lib/theme/buttons.dart' show AylaPressScale;
import '../lib/theme/glass.dart' show GlassSurface;
import '../lib/theme/preview_theme.dart';
import '../lib/theme/tokens.dart';
import '../lib/widgets/channel_sidebar.dart';
import '../lib/widgets/directory_controls.dart' show AylaDirectoryLoadMore;
import '../lib/widgets/primitives.dart'
    show AylaNavHighlight, AylaNavHighlightState;
import '../lib/widgets/reveal.dart' show AylaRevealItem;
import '../lib/widgets/tab_badge.dart';

// ======================= 测试数据 =======================

const List<AylaChannelSubgroup> kSubgroups = <AylaChannelSubgroup>[
  AylaChannelSubgroup(
    id: 'sg1',
    name: '默认组',
    isDefault: true,
    lastMessageSeq: 10,
  ),
  AylaChannelSubgroup(
    id: 'sg2',
    name: '摸鱼',
    lastMessageSeq: 30,
    unreadCount: 5,
  ),
  AylaChannelSubgroup(id: 'sg3', name: '技术', lastMessageSeq: 20, muted: true),
  AylaChannelSubgroup(id: 'sg4', name: '第四个', lastMessageSeq: 5),
  AylaChannelSubgroup(id: 'sg5', name: '第五个', lastMessageSeq: 1),
];

const List<AylaChannelVoiceRoom> kVoiceRooms = <AylaChannelVoiceRoom>[
  AylaChannelVoiceRoom(id: 'v1', name: '语音房A', memberCount: 3),
  AylaChannelVoiceRoom(id: 'v2', name: '语音房B'),
  AylaChannelVoiceRoom(id: 'v3', name: '语音房C', memberCount: 1),
  AylaChannelVoiceRoom(id: 'v4', name: '语音房D'),
];

const List<AylaChannelLiveRoom> kLiveRooms = <AylaChannelLiveRoom>[
  AylaChannelLiveRoom(id: 1, title: '直播间一', isLive: true),
  AylaChannelLiveRoom(id: 2, title: '直播间二'),
  AylaChannelLiveRoom(id: 3, title: '直播间三'),
  AylaChannelLiveRoom(id: 4, title: '直播间四'),
];

/// 长内容数据集（内容远超视口，用于 sticky 的顶部/底部吸附）。
List<AylaChannelSubgroup> longSubgroups() => <AylaChannelSubgroup>[
  const AylaChannelSubgroup(
    id: 'sg1',
    name: '默认组',
    isDefault: true,
    lastMessageSeq: 10,
  ),
  for (int i = 2; i <= 12; i++)
    AylaChannelSubgroup(id: 'sg$i', name: '子群$i', lastMessageSeq: 100 - i),
];

List<AylaChannelVoiceRoom> longVoiceRooms() => <AylaChannelVoiceRoom>[
  for (int i = 1; i <= 12; i++)
    AylaChannelVoiceRoom(id: 'v$i', name: '语音房$i', memberCount: i),
];

List<AylaChannelLiveRoom> longLiveRooms() => <AylaChannelLiveRoom>[
  for (int i = 1; i <= 12; i++)
    AylaChannelLiveRoom(id: i, title: '直播间$i', isLive: i == 1),
];

// ======================= 测试宿主（可被 StatefulBuilder 驱动） =======================

/// 宿主状态：所有 props 都可改，改完调 [update] 就重建。
class SidebarHostState {
  SidebarHostState({
    this.groupId = 'g1',
    this.groupName = '技术群',
    this.scene = AylaGroupScene.chat,
    this.subgroupId = 'sg1',
    this.voiceChannelId,
    this.liveChannelId,
    this.subgroups = kSubgroups,
    this.voiceRooms = kVoiceRooms,
    this.liveRooms = kLiveRooms,
    this.canManage = true,
    this.postUnread = 0,
    this.voiceMemberCount = 7,
    this.subgroupTotal = 5,
    this.voiceTotal = 4,
    this.liveTotal = 4,
    this.animateEntrance = false,
    this.playing = true,
    this.height = 620,
  });

  String groupId;
  String groupName;
  AylaGroupScene scene;
  String? subgroupId;
  String? voiceChannelId;
  String? liveChannelId;
  List<AylaChannelSubgroup> subgroups;
  List<AylaChannelVoiceRoom> voiceRooms;
  List<AylaChannelLiveRoom> liveRooms;
  bool canManage;
  int postUnread;
  int voiceMemberCount;
  int subgroupTotal;
  int voiceTotal;
  int liveTotal;
  bool animateEntrance;
  bool playing;
  double height;

  void Function(VoidCallback)? _rebuild;

  /// 改字段后调用（内部 setState）。
  void update(VoidCallback fn) {
    fn();
    _rebuild?.call(() {});
  }
}

void main() {
  AylaGroupScene? pickedScene;
  String? pickedSubgroup;
  String? pickedVoice;
  int? pickedLive;
  int openInfoTaps = 0;
  int loadMoreCalls = 0;
  int refreshCalls = 0;

  setUp(() {
    pickedScene = null;
    pickedSubgroup = null;
    pickedVoice = null;
    pickedLive = null;
    openInfoTaps = 0;
    loadMoreCalls = 0;
    refreshCalls = 0;
  });

  Widget hostStateful(SidebarHostState st) => MaterialApp(
    home: previewScope(
      Center(
        child: SizedBox(
          height: st.height,
          child: StatefulBuilder(
            builder: (BuildContext context, StateSetter setState) {
              st._rebuild = setState;
              return AylaChannelSidebar(
                groupId: st.groupId,
                groupName: st.groupName,
                activeScene: st.scene,
                activeSubgroupId: st.subgroupId,
                activeVoiceChannelId: st.voiceChannelId,
                activeLiveChannelId: st.liveChannelId,
                subgroups: st.subgroups,
                voiceRooms: st.voiceRooms,
                liveRooms: st.liveRooms,
                canManageSubgroups: st.canManage,
                postUnread: st.postUnread,
                voiceMemberCount: st.voiceMemberCount,
                animateEntrance: st.animateEntrance,
                playing: st.playing,
                subgroupDirectory: AylaChannelDirectory(
                  total: st.subgroupTotal,
                  hasMore: true,
                  loadMore: () async => loadMoreCalls++,
                  refresh: () async => refreshCalls++,
                ),
                voiceDirectory: AylaChannelDirectory(
                  total: st.voiceTotal,
                  hasMore: true,
                  loadMore: () async => loadMoreCalls++,
                  refresh: () async => refreshCalls++,
                ),
                liveDirectory: AylaChannelDirectory(
                  total: st.liveTotal,
                  hasMore: true,
                  loadMore: () async => loadMoreCalls++,
                  refresh: () async => refreshCalls++,
                ),
                onSelectScene: (AylaGroupScene s) => pickedScene = s,
                onOpenInfo: () => openInfoTaps++,
                onSelectSubgroup: (String id) => pickedSubgroup = id,
                onSelectVoiceChannel: (String id) => pickedVoice = id,
                onSelectLiveChannel: (int id) => pickedLive = id,
              );
            },
          ),
        ),
      ),
    ),
  );

  Widget host({
    String groupId = 'g1',
    String groupName = '技术群',
    AylaGroupScene activeScene = AylaGroupScene.chat,
    String? activeSubgroupId = 'sg1',
    String? activeVoiceChannelId,
    String? activeLiveChannelId,
    List<AylaChannelSubgroup> subgroups = kSubgroups,
    List<AylaChannelVoiceRoom> voiceRooms = kVoiceRooms,
    List<AylaChannelLiveRoom> liveRooms = kLiveRooms,
    bool canManage = true,
    int postUnread = 0,
    int voiceMemberCount = 7,
    int subgroupTotal = 5,
    int voiceTotal = 4,
    int liveTotal = 4,
    bool animateEntrance = false,
    bool playing = true,
    double height = 620,
  }) => hostStateful(
    SidebarHostState(
      groupId: groupId,
      groupName: groupName,
      scene: activeScene,
      subgroupId: activeSubgroupId,
      voiceChannelId: activeVoiceChannelId,
      liveChannelId: activeLiveChannelId,
      subgroups: subgroups,
      voiceRooms: voiceRooms,
      liveRooms: liveRooms,
      canManage: canManage,
      postUnread: postUnread,
      voiceMemberCount: voiceMemberCount,
      subgroupTotal: subgroupTotal,
      voiceTotal: voiceTotal,
      liveTotal: liveTotal,
      animateEntrance: animateEntrance,
      playing: playing,
      height: height,
    ),
  );

  /// 长内容宿主（sticky 顶部/底部吸附用）。
  SidebarHostState longHost() => SidebarHostState(
    subgroups: longSubgroups(),
    voiceRooms: longVoiceRooms(),
    liveRooms: longLiveRooms(),
    subgroupTotal: 12,
    voiceTotal: 12,
    liveTotal: 12,
  );

  // ======================= 工具 =======================

  /// 宽屏视口（默认测试视口只有 600 高，会把 `SizedBox(height: 620)` 夹到 600
  /// → 几何断言整体偏移）。
  Future<void> pumpHost(
    WidgetTester tester,
    Widget widget, {
    Size size = const Size(1000, 800),
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(widget);
  }

  /// 语义树作用域（`find.bySemanticsLabel` 需要；必须在测试体内 dispose）。
  Future<void> withSemantics(
    WidgetTester tester,
    Future<void> Function() body,
  ) async {
    final SemanticsHandle handle = tester.ensureSemantics();
    try {
      await body();
    } finally {
      handle.dispose();
    }
  }

  Finder sceneRow(String label) => find.ancestor(
    of: find.text(label),
    matching: find.byWidgetPredicate(
      (Widget w) => w is AnimatedContainer && w.constraints?.maxHeight == 40,
    ),
  );

  AnimatedContainer sceneRowWidget(WidgetTester tester, String label) =>
      tester.widget<AnimatedContainer>(sceneRow(label).first);

  Color? rowColor(WidgetTester tester, String label) =>
      (sceneRowWidget(tester, label).decoration! as BoxDecoration).color;

  Rect viewportRect(WidgetTester tester) =>
      tester.getRect(find.byType(SingleChildScrollView));

  double rowCenterInViewport(WidgetTester tester, String label) =>
      tester.getRect(find.text(label)).center.dy - viewportRect(tester).top;

  Rect highlightRect(WidgetTester tester, [int index = -1]) => tester.getRect(
    index < 0
        ? find.byType(AylaNavHighlight).last
        : find.byType(AylaNavHighlight).at(index),
  );

  int sweepActiveCount(WidgetTester tester) => tester
      .widgetList<AylaNavHighlight>(find.byType(AylaNavHighlight))
      .where((AylaNavHighlight w) => w.sweepActive)
      .length;

  ScrollableState scrollable(WidgetTester tester) =>
      tester.state(find.byType(Scrollable).first);

  Future<void> scrollTo(WidgetTester tester, double offset) async {
    scrollable(tester).position.jumpTo(offset);
    await tester.pumpAndSettle();
  }

  /// 点击目标；只有当它**贴顶或贴底**时先滚到视口中部（那两处会被吸顶/吸底行盖住）。
  Future<void> tapVisible(WidgetTester tester, Finder target) async {
    final Rect vp = viewportRect(tester);
    final Rect r = tester.getRect(target);
    if (r.top < vp.top + 130 || r.bottom > vp.bottom - 60) {
      final ScrollableState st = scrollable(tester);
      st.position.jumpTo(
        (st.position.pixels + (r.top - (vp.top + vp.height * 0.5))).clamp(
          0.0,
          st.position.maxScrollExtent,
        ),
      );
      await tester.pumpAndSettle();
    }
    await tester.tap(target, warnIfMissed: false);
    await tester.pumpAndSettle();
  }

  /// 点某个下拉的「更多 / 收起」按钮。
  ///
  /// ⚠️ 只有在目标**贴顶或贴底**时才滚动：那两处会被吸顶行（0/44/88）或吸底行
  /// （52/8）盖住 —— 与 web 的 `clip-path` 命中语义一致（被盖住的内容点不到）。
  /// 无条件 `ensureVisible` 反而会把目标推到被遮挡的位置（实测踩过）。
  Future<void> tapMore(
    WidgetTester tester,
    String label, {
    bool last = false,
  }) async {
    await tapVisible(
      tester,
      last ? find.text(label).last : find.text(label).first,
    );
  }

  /// 依次展开三个下拉的「展开更多」。
  Future<void> expandAll(WidgetTester tester) async {
    for (int i = 0; i < 3; i++) {
      final Finder more = find.textContaining('展开更多');
      if (more.evaluate().isEmpty) break;
      await tapMore(tester, tester.widget<Text>(more.first).data!);
    }
    await scrollTo(tester, 0);
  }

  // ======================= 容器几何 =======================

  testWidgets('容器：slot 284 = 260 + 2×12；卡片 1px 边框用内边距补位 → 列表轨道 242', (
    WidgetTester tester,
  ) async {
    await pumpHost(tester, host());
    await tester.pumpAndSettle();

    // `.channel-sidebar-slot { width: calc(260px + 2 * var(--sidebar-gutter)) }`
    expect(
      find.byWidgetPredicate((Widget w) => w is SizedBox && w.width == 284),
      findsOneWidget,
    );
    // `.channel-sidebar { width: 260px; margin: 12px; border: 1px }`
    final Rect card = tester.getRect(find.byType(GlassSurface).first);
    expect(card.width, 260);
    expect(card.height, 620 - 24); // 620 − 上下 margin 12×2
    // 列表视口宽 = 260 − 2(边框) − 2×8(padding) = 242（§6.5 的 1px 补位）
    expect(viewportRect(tester).width, 242);
  });

  testWidgets('群名头：Fredoka 500 20px + 16px chevron；点击进群信息', (
    WidgetTester tester,
  ) async {
    await pumpHost(tester, host());
    await tester.pumpAndSettle();

    final Text title = tester.widget<Text>(find.text('技术群'));
    expect(title.style!.fontFamily, AylaFonts.display);
    expect(title.style!.fontSize, 20);
    expect(title.style!.fontWeight, FontWeight.w500);
    expect(title.style!.color, AylaColors.textPrimary);

    // tsx 605–611 的 chevron（16px，内联 SVG → 组件内私有 glyph）
    expect(
      find.byWidgetPredicate(
        (Widget w) => w is CustomPaint && w.size == const Size(16, 16),
      ),
      findsWidgets,
    );

    await tester.tap(find.text('技术群'));
    await tester.pumpAndSettle();
    expect(openInfoTaps, 1);
  });

  // ======================= 场景项 =======================

  testWidgets('场景项：五个 + 顺序（聊天/语音/直播在主列，帖子/桌游锁定置底）', (
    WidgetTester tester,
  ) async {
    await pumpHost(tester, host());
    await tester.pumpAndSettle();

    expect(
      find.byWidgetPredicate(
        (Widget w) => w is AnimatedContainer && w.constraints?.maxHeight == 40,
      ),
      findsNWidgets(5),
    );

    final double chat = tester.getRect(find.text('聊天')).top;
    final double voice = tester.getRect(find.text('语音')).top;
    final double live = tester.getRect(find.text('直播')).top;
    final double posts = tester.getRect(find.text('帖子')).top;
    final double games = tester.getRect(find.text('桌游')).top;
    expect(chat, lessThan(voice));
    expect(voice, lessThan(live));
    expect(live, lessThan(posts)); // 底部列在滚动列之下
    expect(posts, lessThan(games));

    // 未选中项底 = rgba(255,250,251,.4)（group.css 756）+ radius 12 + 1px 亮边
    final BoxDecoration d =
        sceneRowWidget(tester, '帖子').decoration! as BoxDecoration;
    expect(d.color, const Color(0x66FFFAFB));
    expect(d.borderRadius, BorderRadius.circular(AylaRadii.rInput));
    expect((d.border! as Border).top.color, AylaColors.glassBorder);
  });

  testWidgets('状态标识三型：语音人数 / LIVE 是裸文本，帖子未读是粉徽标贴右', (
    WidgetTester tester,
  ) async {
    await pumpHost(tester, host(postUnread: 12));
    await tester.pumpAndSettle();

    // 语音在麦人数（tsx 271）：web `.channel-scene-status` 零样式 → 继承按钮
    // 的 15px / w600 / --text-secondary
    final Text count = tester.widget<Text>(find.text('7'));
    expect(count.style!.fontSize, 15);
    expect(count.style!.fontWeight, FontWeight.w600);
    expect(count.style!.color, AylaColors.textSecondary);

    // LIVE（tsx 346）：同样是裸文本（不是胶囊）
    final Text live = tester.widget<Text>(find.text('LIVE'));
    expect(live.style!.fontSize, 15);
    expect(live.style!.fontWeight, FontWeight.w600);

    // 帖子未读（tsx 517–519）：唯一有独立样式的状态（粉徽标 + margin-left auto）
    final Finder badge = find.descendant(
      of: sceneRow('帖子').first,
      matching: find.byType(TabBadge),
    );
    expect(badge, findsOneWidget);
    expect(
      tester.widget<TabBadge>(badge).metrics,
      TabBadgeMetrics.channelBadge,
    );

    final Rect badgeRect = tester.getRect(badge);
    final Rect rowRect = tester.getRect(sceneRow('帖子').first);
    // 行 padding-right 40 + 1px 边框（border-box 语义）→ 徽标右缘距外框 41
    expect(rowRect.right - badgeRect.right, closeTo(41, 0.5));
  });

  testWidgets('点击回调：场景项 / 语音房行 / 直播间行', (WidgetTester tester) async {
    await pumpHost(tester, host(activeScene: AylaGroupScene.games));
    await tester.pumpAndSettle();

    await tester.tap(find.text('聊天'));
    await tester.pumpAndSettle();
    expect(pickedScene, AylaGroupScene.chat);
    expect(pickedSubgroup, 'sg1'); // tsx 451：点聊天同时选中默认子群

    await tester.tap(find.text('语音房A'));
    await tester.pumpAndSettle();
    expect(pickedVoice, 'v1');
    expect(pickedScene, AylaGroupScene.voice); // tsx 315 同时选场景

    await tapVisible(tester, find.text('直播间一'));
    expect(pickedLive, 1);
  });

  testWidgets('点击子群行：切换子群（单独测，避免受场景项点击引发的滚动影响）', (WidgetTester tester) async {
    await pumpHost(tester, host());
    await tester.pumpAndSettle();

    await tester.tap(find.text('摸鱼'));
    await tester.pumpAndSettle();
    expect(pickedSubgroup, 'sg2');
    expect(pickedScene, AylaGroupScene.chat);
  });

  // ======================= 排序 =======================

  test('排序：默认组第一 → last_message_seq 降序 → 并列保持原序（Dart sort 不稳定）', () {
    expect(
      sortSubgroupsByActivity(
        kSubgroups,
      ).map((AylaChannelSubgroup s) => s.id).toList(),
      <String>['sg1', 'sg2', 'sg3', 'sg4', 'sg5'],
    );

    final List<AylaChannelSubgroup> tie = <AylaChannelSubgroup>[
      for (final String id in <String>['a', 'b', 'c', 'd', 'e', 'f', 'g', 'h'])
        AylaChannelSubgroup(id: id, name: id),
    ];
    expect(
      sortSubgroupsByActivity(
        tie,
      ).map((AylaChannelSubgroup s) => s.id).toList(),
      <String>['a', 'b', 'c', 'd', 'e', 'f', 'g', 'h'],
    );
  });

  // ======================= sticky =======================

  testWidgets('sticky 吸顶：滚到底后 chat 0 / voice 44 / live 88（group.css 814–816）', (
    WidgetTester tester,
  ) async {
    await pumpHost(tester, hostStateful(longHost()));
    await tester.pumpAndSettle();
    await expandAll(tester);
    expect(
      scrollable(tester).position.maxScrollExtent,
      greaterThan(950),
      reason: '长数据必须真的能滚过三行的吸附位',
    );

    await scrollTo(tester, scrollable(tester).position.maxScrollExtent);
    expect(rowCenterInViewport(tester, '聊天'), closeTo(20, 0.5)); // 0 + 40/2
    expect(rowCenterInViewport(tester, '语音'), closeTo(64, 0.5)); // 44 + 20
    expect(rowCenterInViewport(tester, '直播'), closeTo(108, 0.5)); // 88 + 20
  });

  testWidgets('sticky 吸底：未滚到该行时 live 贴底 8、voice 在其上方 52', (
    WidgetTester tester,
  ) async {
    await pumpHost(tester, hostStateful(longHost()));
    await tester.pumpAndSettle();
    await expandAll(tester);
    await scrollTo(tester, 0);

    // 内容远超视口 → voice / live 的自然位置都在视口下方 → 被 `bottom` 夹住
    final double vpHeight = viewportRect(tester).height;
    expect(rowCenterInViewport(tester, '直播'), closeTo(vpHeight - 8 - 20, 0.5));
    expect(rowCenterInViewport(tester, '语音'), closeTo(vpHeight - 52 - 20, 0.5));
  });

  testWidgets('行浮层的命中与绘制同偏移（applyPaintTransform 覆盖）', (
    WidgetTester tester,
  ) async {
    await pumpHost(tester, host());
    await tester.pumpAndSettle();

    await tester.tap(find.text('语音'));
    await tester.pumpAndSettle();
    expect(pickedScene, AylaGroupScene.voice);
  });

  // ======================= 动态裁剪 =======================

  testWidgets('动态裁剪层：三个下拉各一个 + 子群/直播胶囊各一个（同参数裁剪）', (
    WidgetTester tester,
  ) async {
    await pumpHost(tester, host());
    await tester.pumpAndSettle();

    // 3 个下拉容器 + 2 个胶囊裁剪层（子群、直播间）。
    // 胶囊在 web 里是按钮子元素 → 被下拉的 `overflow:hidden` 裁住；Flutter 侧
    // 胶囊画在卡片级，必须再套一层**同参数**的裁剪，否则高亮块会超出视口
    // （用户 2026-09-21 实报）。
    expect(
      find.byWidgetPredicate(
        (Widget w) => w.runtimeType.toString() == '_SidebarDropdownClip',
      ),
      findsNWidgets(5),
    );
  });

  testWidgets('裁剪是 paint-only：滚动到吸附位后布局未被改变', (WidgetTester tester) async {
    await pumpHost(tester, host());
    await tester.pumpAndSettle();

    await scrollTo(tester, 60);
    expect(find.text('摸鱼'), findsWidgets);
    expect(viewportRect(tester).width, 242);
  });

  // ======================= 三个下拉的差异 =======================

  testWidgets('子群下拉：前三条 + 条件渲染追加段 + 页脚（tsx 476–499）', (
    WidgetTester tester,
  ) async {
    await pumpHost(tester, host());
    await tester.pumpAndSettle();

    expect(find.text('默认组'), findsOneWidget);
    expect(find.text('摸鱼'), findsOneWidget);
    expect(find.text('技术'), findsOneWidget);
    expect(find.text('第四个'), findsNothing); // 条件渲染
    expect(find.text('展开更多（2）'), findsOneWidget);

    await tapMore(tester, '展开更多（2）');
    expect(find.text('第四个'), findsOneWidget);
    expect(find.text('第五个'), findsOneWidget);
    expect(find.byType(AylaDirectoryLoadMore), findsOneWidget);
  });

  testWidgets('语音房下拉：折叠高度 = min(3,n)×31−1，行全渲染但被裁且禁用（tsx 297–315）', (
    WidgetTester tester,
  ) async {
    await pumpHost(tester, host());
    await tester.pumpAndSettle();

    // 4 个房间**全部渲染**（与子群的条件渲染不同）
    for (final String name in <String>['语音房A', '语音房B', '语音房C', '语音房D']) {
      expect(find.text(name), findsOneWidget);
    }
    // 折叠高度 = 3×31 − 1 = 92
    final Finder collapsed = find
        .byWidgetPredicate((Widget w) => w is SizedBox && w.height == 92)
        .first;
    expect(collapsed, findsOneWidget);
    // 第四条落在折叠高度之外（被裁区域）
    expect(
      tester.getRect(find.text('语音房D')).top,
      greaterThan(tester.getRect(collapsed).bottom),
    );
    // 折叠时页脚不渲染（tsx 331）
    expect(find.byType(AylaDirectoryLoadMore), findsNothing);

    await tapMore(tester, '展开更多（1）');
    expect(find.byType(AylaDirectoryLoadMore), findsOneWidget);
  });

  testWidgets('直播下拉：前三条 + 分开的追加列表 + 页脚（tsx 367–419）', (
    WidgetTester tester,
  ) async {
    await pumpHost(tester, host());
    await tester.pumpAndSettle();

    expect(find.text('直播间一'), findsOneWidget);
    expect(find.text('直播间二'), findsOneWidget);
    expect(find.text('直播间三'), findsOneWidget);
    expect(find.text('直播间四'), findsNothing); // 条件渲染

    await tapMore(tester, '展开更多（1）', last: true); // 直播在语音之后
    expect(find.text('直播间四'), findsOneWidget);
    expect(find.byType(AylaDirectoryLoadMore), findsOneWidget);
  });

  testWidgets('直播行：封面 64×36 / LIVE 点 8×8 贴封面右上（4+1px 边框）', (
    WidgetTester tester,
  ) async {
    await pumpHost(tester, host());
    await tester.pumpAndSettle();

    final Rect cover = tester.getRect(
      find
          .byWidgetPredicate(
            (Widget w) => w is SizedBox && w.width == 64 && w.height == 36,
          )
          .first,
    );
    expect(cover.height, 36);

    final Rect dot = tester.getRect(
      find
          .byWidgetPredicate(
            (Widget w) =>
                w is Container &&
                w.constraints?.maxWidth == 8 &&
                w.constraints?.maxHeight == 8,
          )
          .first,
    );
    expect(dot.width, 8);
    expect(dot.top - cover.top, closeTo(5, 0.5)); // 1(边框) + 4
    expect(cover.right - dot.right, closeTo(5, 0.5));
  });

  // ======================= 展开/收起的同帧同步 =======================

  testWidgets('同帧同步：收起子群动画期间「语音行 ↔ 语音房首行」距离恒定（§6.11 判据）', (
    WidgetTester tester,
  ) async {
    await pumpHost(tester, host());
    await tester.pumpAndSettle();

    final double before =
        tester.getRect(find.text('语音房A')).top -
        tester.getRect(find.text('语音')).top;

    final List<double> gaps = <double>[];
    await withSemantics(tester, () async {
      await tester.tap(find.bySemanticsLabel('收起').first); // 聊天行的三角
      await tester.pump();
      for (int i = 0; i < 18; i++) {
        await tester.pump(const Duration(milliseconds: 16));
        if (find.text('语音房A').evaluate().isEmpty) break;
        gaps.add(
          tester.getRect(find.text('语音房A')).top -
              tester.getRect(find.text('语音')).top,
        );
      }
    });
    expect(gaps.length, greaterThan(5), reason: '动画期间必须取到多帧');
    for (final double gap in gaps) {
      expect(gap, closeTo(before, 0.01), reason: '每一帧行与下拉首行的距离恒定');
    }
  });

  testWidgets('展开更多把后续行往下推，收起后精确回收（缩小的方向也要生效）', (WidgetTester tester) async {
    await pumpHost(tester, host());
    await tester.pumpAndSettle();

    final double voiceBefore = tester.getRect(find.text('语音')).top;
    await tapMore(tester, '展开更多（2）');
    expect(tester.getRect(find.text('语音')).top, greaterThan(voiceBefore));

    await tapMore(tester, '收起');
    expect(tester.getRect(find.text('语音')).top, closeTo(voiceBefore, 0.5));
  });

  // ======================= hover 两套 + 扫光 =======================

  testWidgets('扫光触发面：按钮本体 hover 才扫光；浮层钮 hover 只驱动底色（auroraqua 163 vs 878）', (
    WidgetTester tester,
  ) async {
    // 选中「帖子」→ 胶囊在场景项本体上（选中子群行时胶囊不在场景按钮上）
    await pumpHost(tester, host(activeScene: AylaGroupScene.posts));
    await tester.pumpAndSettle();

    final TestGesture gesture = await tester.createGesture(
      kind: PointerDeviceKind.mouse,
    );
    await gesture.addPointer(location: Offset.zero);
    addTearDown(gesture.removePointer);

    await gesture.moveTo(tester.getCenter(find.text('帖子')));
    await tester.pumpAndSettle();
    expect(sweepActiveCount(tester), 1, reason: '按钮本体 hover → 扫光');

    // 指针移到同一行的三角展开键 → 扫光必须停（行级 hover 只管底色）
    await withSemantics(tester, () async {
      await gesture.moveTo(tester.getCenter(find.bySemanticsLabel('收起').last));
      await tester.pumpAndSettle();
      expect(sweepActiveCount(tester), 0, reason: '浮层钮 hover 不驱动扫光');
    });
  });

  testWidgets('底色归谁画：选中项自身底透明（交给胶囊）；浮层钮 hover 时行底 .18', (
    WidgetTester tester,
  ) async {
    await pumpHost(tester, host());
    await tester.pumpAndSettle();

    // 选中项自身底取消（auroraqua 194–197）——**零透明用同色相**
    // （`Colors.transparent` 是透明黑，`Color.lerp` 会闪灰；见组件内 _SidebarZeroTint 注释），
    // 所以断言 alpha == 0 而不是与某个具体颜色相等。
    expect(rowColor(tester, '聊天')!.a, 0);
    expect(rowColor(tester, '语音'), const Color(0x66FFFAFB)); // 未选中 = .4 白

    final TestGesture gesture = await tester.createGesture(
      kind: PointerDeviceKind.mouse,
    );
    await gesture.addPointer(location: Offset.zero);
    addTearDown(gesture.removePointer);
    await withSemantics(tester, () async {
      await gesture.moveTo(tester.getCenter(find.bySemanticsLabel('收起').first));
      await tester.pumpAndSettle();
    });
    // group.css 878–881 特异性高于 auroraqua 194–197 → 选中行也变 .18
    expect(rowColor(tester, '聊天'), const Color(0x2E9DBFE6));
  });

  testWidgets('按压档位：三角键在按钮组（hover 1.02 + active .98）；＋ 与笔不在任何组', (
    WidgetTester tester,
  ) async {
    await pumpHost(tester, host());
    await tester.pumpAndSettle();

    await withSemantics(tester, () async {
      final Finder togglePress = find.ancestor(
        of: find.bySemanticsLabel('收起').first,
        matching: find.byType(AylaPressScale),
      );
      expect(togglePress, findsOneWidget);
      expect(
        tester.widget<AylaPressScale>(togglePress).hoverScale,
        isTrue,
        reason: '三个 toggle 在 auroraqua 按钮组（60/78/90）内',
      );
      expect(
        find.ancestor(
          of: find.bySemanticsLabel('创建语音房'),
          matching: find.byType(AylaPressScale),
        ),
        findsNothing,
        reason: '＋ 不在按钮组 → 不挂 AylaPressScale',
      );
      expect(
        find.ancestor(
          of: find.bySemanticsLabel('编辑'),
          matching: find.byType(AylaPressScale),
        ),
        findsNothing,
        reason: '笔不在按钮组 → 不挂 AylaPressScale',
      );
    });
  });

  // ======================= 共享胶囊 =======================

  testWidgets('共享胶囊：容器级单实例 + 300ms 跨项迁移（不是旧底消失/新底出现）', (
    WidgetTester tester,
  ) async {
    final SidebarHostState st = SidebarHostState(scene: AylaGroupScene.posts);
    await pumpHost(tester, hostStateful(st));
    await tester.pumpAndSettle();

    final Rect atPosts = highlightRect(tester);
    expect(
      atPosts.center.dy,
      closeTo(tester.getRect(find.text('帖子')).center.dy, 0.5),
    );
    expect(atPosts.width, 242); // trackWidth
    expect(atPosts.height, 40);

    st.update(() => st.scene = AylaGroupScene.games);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 150));
    final Rect midway = highlightRect(tester);
    await tester.pumpAndSettle();
    final Rect atGames = highlightRect(tester);

    expect(
      atGames.center.dy,
      closeTo(tester.getRect(find.text('桌游')).center.dy, 0.5),
    );
    expect(midway.center.dy, greaterThanOrEqualTo(atPosts.center.dy));
    expect(midway.center.dy, lessThanOrEqualTo(atGames.center.dy));
  });

  testWidgets('跨组迁移：从场景项迁到子群行，尺寸随之变为 200×30', (WidgetTester tester) async {
    final SidebarHostState st = SidebarHostState(scene: AylaGroupScene.posts);
    await pumpHost(tester, hostStateful(st));
    await tester.pumpAndSettle();
    expect(highlightRect(tester).height, 40);

    st.update(() {
      st.scene = AylaGroupScene.chat;
      st.subgroupId = 'sg2';
    });
    await tester.pumpAndSettle();

    final Rect r = highlightRect(tester);
    expect(r.width, 200);
    expect(r.height, 30);
    expect(
      r.center.dy,
      closeTo(tester.getRect(find.text('摸鱼')).center.dy, 0.5),
    );
  });

  testWidgets('胶囊几何 = 选中按钮的实测矩形（照范本，不按组推算尺寸）', (WidgetTester tester) async {
    final SidebarHostState st = SidebarHostState(scene: AylaGroupScene.posts);
    await pumpHost(tester, hostStateful(st));
    await tester.pumpAndSettle();

    // 场景项：铺满 242×40 的按钮
    Rect cap = highlightRect(tester);
    Rect btn = tester.getRect(sceneRow('帖子').first);
    expect(cap, btn);

    // 子群行：铺满 200×30 的按钮（换组后尺寸随之变化）
    st.update(() {
      st.scene = AylaGroupScene.chat;
      st.subgroupId = 'sg2';
    });
    await tester.pumpAndSettle();
    cap = highlightRect(tester);
    expect(cap.width, 200);
    expect(cap.height, 30);
    expect(
      cap.center.dy,
      closeTo(tester.getRect(find.text('摸鱼')).center.dy, 0.5),
    );
  });

  testWidgets('语音房行不参与共享迁移：胶囊在该行内部（web sharedLayout={false}）', (
    WidgetTester tester,
  ) async {
    await pumpHost(
      tester,
      host(activeScene: AylaGroupScene.voice, activeVoiceChannelId: 'v2'),
    );
    await tester.pumpAndSettle();

    // 该场景下应有两组胶囊：① 场景组（父级「语音」项，宽 242 / 高 40）
    // ② 语音房**行内**那一个（web `sharedLayout={false}`，宽 200 / 高 30）
    expect(find.byType(AylaNavHighlight), findsNWidgets(2));
    final List<Rect> rects = <Rect>[
      for (int i = 0; i < 2; i++) highlightRect(tester, i),
    ];
    expect(
      rects.any((Rect r) => r.height == 30 && r.width == 200),
      isTrue,
      reason: '行内胶囊（200×30）必须在语音房行内',
    );
    expect(
      rects.any((Rect r) => r.height == 40 && r.width == 242),
      isTrue,
      reason: '父级「语音」场景项也要有自己的胶囊（每组一个）',
    );
    final Rect inRow = rects.firstWhere((Rect r) => r.height == 30);
    expect(
      inRow.center.dy,
      closeTo(tester.getRect(find.text('语音房B')).center.dy, 0.5),
    );
  });

  // ======================= 编辑态 =======================

  testWidgets('编辑态：canManage 才有笔；点笔 → 追加段全显 + 行内笔 + ＋添加（tsx 456–504）', (
    WidgetTester tester,
  ) async {
    await pumpHost(tester, host(canManage: true));
    await tester.pumpAndSettle();

    await withSemantics(tester, () async {
      expect(find.bySemanticsLabel('编辑'), findsOneWidget);
      expect(find.bySemanticsLabel('添加子群'), findsNothing);

      await tester.tap(find.bySemanticsLabel('编辑'));
      await tester.pumpAndSettle();

      expect(find.text('第四个'), findsOneWidget); // 编辑态直接全显
      expect(find.text('第五个'), findsOneWidget);
      expect(find.text('展开更多（2）'), findsNothing); // `showMore = !editing && …`
      expect(find.bySemanticsLabel('添加子群'), findsOneWidget);
      expect(find.bySemanticsLabel('编辑子群 摸鱼'), findsOneWidget);
    });
  });

  testWidgets('非管理员：聊天行没有笔', (WidgetTester tester) async {
    await pumpHost(tester, host(canManage: false));
    await tester.pumpAndSettle();
    await withSemantics(tester, () async {
      expect(find.bySemanticsLabel('编辑'), findsNothing);
    });
  });

  testWidgets(
    '禁言标签：ice-300 底 + indigo-700 字 + Fredoka 10px（group.css 318–331）',
    (WidgetTester tester) async {
      await pumpHost(tester, host());
      await tester.pumpAndSettle();

      final Text tag = tester.widget<Text>(find.text('禁言'));
      expect(tag.style!.fontFamily, AylaFonts.display);
      expect(tag.style!.fontSize, 10);
      expect(tag.style!.height, 1.4);
      expect(tag.style!.color, AylaColors.indigo700);

      final Container box = tester.widget<Container>(
        find
            .ancestor(
              of: find.text('禁言'),
              matching: find.byWidgetPredicate(
                (Widget w) =>
                    w is Container &&
                    w.decoration is BoxDecoration &&
                    (w.decoration! as BoxDecoration).color == AylaColors.ice300,
              ),
            )
            .first,
      );
      expect((box.decoration! as BoxDecoration).color, AylaColors.ice300);
    },
  );

  // ======================= 目录接线 =======================

  testWidgets('目录页脚：展开后出现，点「加载更多」触发 loadMore（retainCompletedSpace=false）', (
    WidgetTester tester,
  ) async {
    await pumpHost(tester, host());
    await tester.pumpAndSettle();

    await tapMore(tester, '展开更多（2）');

    final AylaDirectoryLoadMore footer = tester.widget<AylaDirectoryLoadMore>(
      find.byType(AylaDirectoryLoadMore),
    );
    expect(footer.retainCompletedSpace, isFalse);

    await tapMore(tester, '加载更多');
    expect(loadMoreCalls, 1);
  });

  // ======================= 入场 / 退场 =======================

  testWidgets('入场：animateEntrance=false 不播动画；true 时左入 −20 / 300ms easeInOut', (
    WidgetTester tester,
  ) async {
    final SidebarHostState st = SidebarHostState();
    await pumpHost(tester, hostStateful(st));
    await tester.pumpAndSettle();

    AylaRevealItem reveal() => tester.widget<AylaRevealItem>(
      find.descendant(
        of: find.byType(AylaChannelSidebar),
        matching: find.byType(AylaRevealItem),
      ),
    );
    expect(reveal().enabled, isFalse); // animateEntrance=false → 不挂动画

    st.update(() => st.animateEntrance = true);
    await tester.pump();
    expect(reveal().enabled, isTrue);
    expect(reveal().offset, const Offset(-20, 0));
    expect(reveal().duration, AylaDurations.auroraqua);
    expect(reveal().curve, AylaCurves.auroraquaEaseInOut);
    await tester.pumpAndSettle();
  });

  testWidgets('切群：旧面板先退场（mode="wait"）再挂新面板；面板状态随之重挂', (
    WidgetTester tester,
  ) async {
    final SidebarHostState st = SidebarHostState();
    await pumpHost(tester, hostStateful(st));
    await tester.pumpAndSettle();

    await tapMore(tester, '展开更多（2）');
    expect(find.text('第四个'), findsOneWidget);

    st.update(() {
      st.groupId = 'g2';
      st.groupName = '摸鱼群';
    });
    await tester.pump(const Duration(milliseconds: 150));
    // 退场中：旧群内容仍在、新群还没挂
    expect(find.text('技术群'), findsOneWidget);
    expect(find.text('摸鱼群'), findsNothing);

    await tester.pumpAndSettle();
    expect(find.text('摸鱼群'), findsOneWidget);
    expect(find.text('技术群'), findsNothing);
    // 状态重挂：新面板回到「只显示前三条」
    expect(find.text('第四个'), findsNothing);
    expect(find.text('展开更多（2）'), findsOneWidget);
  });

  testWidgets('playing=false（退场态）：胶囊照常显示、但不可交互（inert 语义）', (
    WidgetTester tester,
  ) async {
    await pumpHost(tester, host(playing: false));
    await tester.pumpAndSettle();
    // web 退场只加 `inert` / `aria-hidden`，视觉（含高亮）不变
    expect(find.byType(AylaNavHighlight), findsWidgets);
    await tester.tap(find.text('直播'), warnIfMissed: false);
    await tester.pumpAndSettle();
    expect(pickedScene, isNull);
  });

  // ======================= 画布/预览样张（可交互） =======================

  testWidgets('可交互样张：一级与二级选项卡都能真实点击（不是摆状态）', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1400, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: previewTheme(
          SingleChildScrollView(child: aylaChannelSidebarSamples()),
        ),
      ),
    );
    await tester.pumpAndSettle();

    /// 第 1 个 cell（默认档）里某行按钮的底色。
    Color? firstRowColor(String label) {
      final Finder row = find
          .ancestor(
            of: find.text(label).first,
            matching: find.byWidgetPredicate(
              (Widget w) =>
                  w is AnimatedContainer && w.constraints?.maxHeight == 40,
            ),
          )
          .first;
      return (tester.widget<AnimatedContainer>(row).decoration!
              as BoxDecoration)
          .color;
    }

    // 一级：点「帖子」→ 该行自身底被取消（选中底交给胶囊）
    expect(firstRowColor('帖子'), const Color(0x66FFFAFB));
    await tester.tap(find.text('帖子').first);
    await tester.pumpAndSettle();
    expect(firstRowColor('帖子')!.a, 0); // 零透明（同色相）

    // 二级：点第一个 cell 的子群行「技术」→ 高亮迁到该行（胶囊 rect 覆盖它）
    await tester.tap(find.text('技术').first);
    await tester.pumpAndSettle();
    // 三组胶囊并存 → 按尺寸取「子群组」那一个（200×30）
    final List<Rect> caps = <Rect>[
      for (
        int i = 0;
        i < find.byType(AylaNavHighlight).evaluate().length;
        i++
      )
        highlightRect(tester, i),
    ];
    final Rect cap = caps.firstWhere((Rect r) => r.height == 30);
    expect(cap.width, 200);
    expect(cap.height, 30);
    expect(
      cap.center.dy,
      closeTo(tester.getRect(find.text('技术').first).center.dy, 0.5),
    );

    // 一级：展开/收起三角也是活的（点「聊天」行右端的收起键 → 该档子群行消失）
    final int before = find.text('技术').evaluate().length;
    expect(before, greaterThan(1)); // 多个 cell 都有子群，只影响被点的那一档
    final Rect chatRow = tester.getRect(sceneRow('聊天').first);
    await tester.tapAt(chatRow.centerRight - const Offset(20, 0)); // toggle 中心
    await tester.pumpAndSettle();
    expect(find.text('技术').evaluate().length, before - 1);
  });

  // ======================= 滚动到吸顶位 =======================

  testWidgets('点击场景项滚到自身吸顶位（tsx 161–172）', (WidgetTester tester) async {
    await pumpHost(tester, hostStateful(longHost()));
    await tester.pumpAndSettle();
    await expandAll(tester);

    await tester.tap(find.text('直播'));
    await tester.pumpAndSettle();
    // 滚到 live 的吸顶位（88）→ live 行中心 = 88 + 20
    expect(rowCenterInViewport(tester, '直播'), closeTo(108, 1.5));
    expect(pickedScene, AylaGroupScene.live);
  });
  testWidgets('语音房活跃排序：点某房 → 排到最前，行随之平滑位移（web layout="position"）', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(1400, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: previewTheme(
          SingleChildScrollView(child: aylaChannelSidebarSamples()),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 语音那档：先点「语音」场景项切进去
    await tester.tap(find.text('语音').first);
    await tester.pumpAndSettle();

    final Finder target = find.text('闲聊房').first;
    final double before = tester.getRect(target).top;

    // 点它 → 样张按活跃排序把它提到最前 → 该行上移到第 1 位
    await tester.tap(target);
    await tester.pumpAndSettle();
    final double after = tester.getRect(find.text('闲聊房').first).top;
    expect(
      after,
      lessThan(before - 20),
      reason: '活跃排序后该行应上移到第 1 位（web motion.li layout="position" 的位移动画）',
    );
  });
  testWidgets('扫光触发面（帖子/桌游大卡）：只 hover 选中项才扫，hover 其它项不扫', (
    WidgetTester tester,
  ) async {
    await pumpHost(tester, host(activeScene: AylaGroupScene.posts));
    await tester.pumpAndSettle();

    final TestGesture mouse = await tester.createGesture(
      kind: PointerDeviceKind.mouse,
    );
    await mouse.addPointer(location: Offset.zero);
    addTearDown(mouse.removePointer);
    await tester.pump();

    await mouse.moveTo(tester.getCenter(find.text('帖子').first));
    await tester.pumpAndSettle();
    expect(sweepActiveCount(tester), 1, reason: 'hover 选中项 → 扫光');

    await mouse.moveTo(tester.getCenter(find.text('桌游').first));
    await tester.pumpAndSettle();
    expect(
      sweepActiveCount(tester),
      0,
      reason: 'hover 未选中项 → 不得扫光（扫光只在被 hover 且含胶囊的按钮上）',
    );
  });

  testWidgets('三组子菜单胶囊都不带入场动画（照 web 的 initial={false}）＋迁移由容器级承担', (
    WidgetTester tester,
  ) async {
    // chat + 子群选中 → 场景组与子群组两个胶囊同时在场
    await pumpHost(tester, host(activeSubgroupId: 'sg2'));
    await tester.pumpAndSettle();

    // web 的 AuroraquaNavHighlight：initial={false} → 挂载即到位、没有入场动画；
    // 「切换」动画全部来自 layoutId 的共享迁移（Flutter 侧 = 容器级
    // AnimatedPositioned 300ms）⇒ 三组行为天然统一。
    expect(
      find.byType(TweenAnimationBuilder<double>),
      findsNothing,
      reason: '不得自造入场动画（web 用 initial={false}）',
    );
    expect(
      find.byType(AnimatedPositioned),
      findsWidgets,
      reason: '迁移由容器级 AnimatedPositioned 承担',
    );

    // 点「直播」→ 默认选中第一个直播间 → 直播组胶囊出现（同样无入场动画）
    await tester.tap(find.text('直播').first);
    await tester.pumpAndSettle();
    expect(
      find.byType(AylaNavHighlight).evaluate().length,
      greaterThanOrEqualTo(2),
      reason: '点直播默认选中第一个直播间 → 直播组也有胶囊',
    );
    expect(find.byType(TweenAnimationBuilder<double>), findsNothing);
  });

  testWidgets('帖子/桌游没有任何浮层钮（tsx 511–522）—— 右侧不再被钮盖住', (
    WidgetTester tester,
  ) async {
    // 之前 hasSecondary 写成 '_ => open'，使底部两项也渲染 ＋/三角：钮盖住按钮右端，
    // 鼠标落在右侧时命中的是「钮」（只点亮行级 hover）→ 扫光不触发。
    await pumpHost(tester, host(activeScene: AylaGroupScene.posts));
    await tester.pumpAndSettle();
    // 只应有**中部直播行**那一个 ＋（底部两项必须一个都没有）；
    // 若 hasSecondary 仍写成 `_ => open`，这里会变成 3 个。
    expect(find.bySemanticsLabel('创建直播'), findsOneWidget);
    // 语音行展开时也有自己的 ＋（与底部两项无关）—— 两个 ＋ 各自只在对应行，
    // 若底部两项也被渲染成带钮的行，这里的计数会翻倍。
    expect(find.bySemanticsLabel('创建语音房'), findsOneWidget);

    // 切到直播（展开态）→ 该行才应有 ＋
    await tester.tap(find.text('直播').first);
    await tester.pumpAndSettle();
    expect(find.bySemanticsLabel('创建直播'), findsOneWidget);
  });

  testWidgets('语音房切换：整行（含高亮）一起位移 —— 中途位置在旧位与新位之间', (
    WidgetTester tester,
  ) async {
    // web：语音房行是 motion.li layout=position（300ms），高亮是它的子元素
    // ⇒ 切到某房时**行带着高亮一起移动**（用户要的「高亮移动动画」）。
    // 排序由调用方给（组件是受控的）⇒ 用**样张**（自持活跃排序）验证这条。
    tester.view.physicalSize = const Size(1400, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: previewTheme(
          SingleChildScrollView(child: aylaChannelSidebarSamples()),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('语音').first); // 切到语音档
    await tester.pumpAndSettle();

    final Finder room = find.text('闲聊房').first;
    final double before = tester.getRect(room).top;
    await tester.tap(room);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 150));
    final double mid = tester.getRect(find.text('闲聊房').first).top;
    await tester.pumpAndSettle();
    final double after = tester.getRect(find.text('闲聊房').first).top;

    expect(after, lessThan(before), reason: '选中后该房应上移');
    expect(
      mid,
      greaterThan(after),
      reason: '中途应仍在旧位与新位之间（行位移有真实动画，而不是瞬移）',
    );
  });
  testWidgets('扫光「挂载即命中」：点中部项与底部项都**立刻在终点**（不重播左→右）', (
    WidgetTester tester,
  ) async {
    // web：点击使胶囊迁到鼠标所在项时，该帧 computed style 已是 translateX(120%)
    // （:hover 从第一帧就匹配）⇒ 没有 transition。之后指针移开才跑出完整的一次
    // 从右往左扫。此前底部两项（帖子/桌游）漏了这个 jump ⇒ 会从左往右重播一次。
    List<double> progress() => <double>[
      for (int i = 0; i < find.byType(AylaNavHighlight).evaluate().length; i++)
        tester
            .state<AylaNavHighlightState>(find.byType(AylaNavHighlight).at(i))
            .sweepProgress,
    ];

    await pumpHost(tester, host(activeScene: AylaGroupScene.voice));
    await tester.pumpAndSettle();

    await tester.tap(find.text('帖子').first);
    await tester.pump();
    await tester.pump(); // postFrame：jump 生效
    expect(
      progress().any((double p) => p == 1.0),
      isTrue,
      reason: '点中部项后扫光必须立刻在终点',
    );

    // 底部项（桌游）—— 用户实报有差异的那个
    await tester.tap(find.text('桌游').first);
    await tester.pump();
    await tester.pump();
    expect(
      progress().any((double p) => p == 1.0),
      isTrue,
      reason: '点底部项（桌游）后扫光也必须立刻在终点，不得从左往右重播',
    );
  });
  testWidgets('三角展开键：常态透明（.is-open 只旋转，不点底色）', (
    WidgetTester tester,
  ) async {
    // host 默认三个下拉**都是展开的** —— 也就是三角键都处于 .is-open。
    // web group.css 874–876 的 .is-open **只有 transform**（rotate 180deg）；
    // 底色/字色**只有 :hover 才给**（883–886）。此前把 is-open 也当成 activeState
    // ⇒ 展开时三角键常驻亮底（用户 2026-09-21 实报「常态时这里不高亮的」）。
    await pumpHost(tester, host());
    await tester.pumpAndSettle();

    Iterable<AnimatedContainer> toggles() => tester
        .widgetList<AnimatedContainer>(find.byType(AnimatedContainer))
        .where(
          (AnimatedContainer c) =>
              c.constraints?.maxWidth == 28 && c.constraints?.maxHeight == 28,
        );

    expect(toggles().isNotEmpty, isTrue, reason: '三个三角展开键应存在（28×28）');
    expect(
      toggles().every(
        (AnimatedContainer c) =>
            ((c.decoration as BoxDecoration?)?.color?.a ?? 0) == 0,
      ),
      isTrue,
      reason: '未 hover 时三角键必须透明（展开态只旋转，不点亮底色）',
    );

    // 而旋转是给了的：展开态 turns == 0.5
    expect(
      tester
          .widgetList<AnimatedRotation>(find.byType(AnimatedRotation))
          .where((AnimatedRotation r) => r.turns == 0.5)
          .isNotEmpty,
      isTrue,
      reason: '展开态应旋转 180°',
    );
  });
  testWidgets('同一行的两个浮层钮分开高亮（＋ 与 三角互不串扰）', (
    WidgetTester tester,
  ) async {
    // web 里每个钮有自己的 :hover（.channel-scene-voice-add:hover 852 /
    // .channel-scene-voice-toggle:hover 883），但两者都联动词条底色（878–881）。
    // 此前两个钮共用行级 hover 身份 ⇒ 悬停一个两个一起亮（用户 2026-09-21 实报）。
    await pumpHost(tester, host(activeScene: AylaGroupScene.voice));
    await tester.pumpAndSettle();

    List<Color?> overlayColors() => tester
        .widgetList<AnimatedContainer>(find.byType(AnimatedContainer))
        .where(
          (AnimatedContainer c) =>
              c.constraints?.maxWidth == 28 && c.constraints?.maxHeight == 28,
        )
        .map((AnimatedContainer c) => (c.decoration as BoxDecoration?)?.color)
        .toList();

    expect(
      overlayColors().every((Color? c) => (c?.a ?? 0) == 0),
      isTrue,
      reason: '常态下所有浮层钮都应透明',
    );

    final TestGesture mouse = await tester.createGesture(
      kind: PointerDeviceKind.mouse,
    );
    await mouse.addPointer(location: Offset.zero);
    addTearDown(mouse.removePointer);
    await tester.pump();

    // 悬停「创建语音房」＋（语音行右侧左钮）
    await mouse.moveTo(tester.getCenter(find.bySemanticsLabel('创建语音房').first));
    await tester.pumpAndSettle();
    expect(
      overlayColors().where((Color? c) => (c?.a ?? 0) > 0).length,
      1,
      reason: '只有被 hover 的那一个钮亮，同行的三角键必须保持透明',
    );
  });
}
