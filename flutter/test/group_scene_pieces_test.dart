/// 群内场景 4 件定向测试 —— group_scene.dart / group_chat_subgroup_bar.dart /
/// group_posts_composer.dart，逐条对照 web：
/// `group.css 152–475` · `posts.css 933–951 / 1011–1108` · `auroraqua.css 190–197 / 347–368` ·
/// `GroupChat.tsx 334–407` · `GroupPosts.tsx 477–493` · `GroupVoice/Posts/Games/Live/Info 的调用点`。
///
/// ⚠️ 一态一用例（同用例二次 pumpWidget 换 props 不生效 —— 库内既有纪律）。
library;

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';

import '../lib/core/models/post.dart';
import '../lib/theme/app_icons.dart';
import '../lib/theme/glass.dart';
import '../lib/theme/preview_theme.dart';
import '../lib/theme/tokens.dart';
import '../lib/widgets/base/nav_highlight_list.dart';
import '../lib/widgets/group/group_chat_subgroup_bar.dart';
import '../lib/widgets/group/group_posts_composer.dart';
import '../lib/widgets/group/group_scene.dart';
import '../lib/widgets/posts/post_editor.dart';

void main() {
  /// 真实宿主：MaterialApp + 画布主题；宽高由调用方钉死（窄屏/宽屏两档）。
  /// height = null ⇒ 高度不设约束（头部/占位等"由内容决定高度"的件必须这样，
  /// 否则 SizedBox 会把被测件拉满）。MediaQuery 里仍给一个名义高度（窄/宽档判宽用 width）。
  Widget host(Widget child, {double width = 600, double? height}) => MaterialApp(
    home: previewScope(
      Builder(
        builder: (BuildContext context) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(size: Size(width, height ?? 400)),
          child: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(width: width, height: height, child: child),
          ),
        ),
      ),
    ),
  );

  /// 展开态面板的滚动口（= .group-posts-input.is-expanded 的盒）—— 贴底与 max-height 都量它。
  Finder panelViewport() => find
      .ancestor(
        of: find.byType(AylaPostEditor),
        matching: find.byType(SingleChildScrollView),
      )
      .first;

  /// 展开遮罩（rgba(70,91,146,.25)）。
  Finder scrimFinder() => find.byWidgetPredicate(
    (Widget w) => w is ColoredBox && w.color == AylaColors.overlayDim,
  );

  /// 本件内所有有限 maxHeight（> 100）—— 用于对账展开态面板的 max-height 档。
  List<double> panelMaxHeights(WidgetTester tester) => <double>[
    for (final ConstrainedBox box in tester.widgetList<ConstrainedBox>(
      find.byType(ConstrainedBox),
    ))
      if (box.constraints.maxHeight.isFinite && box.constraints.maxHeight > 100)
        box.constraints.maxHeight,
  ];

  /// 内容轨道的模拟列表项（每项 60 高，可点，用于验证吸顶拦截）。
  Widget rows(List<int> taps, {int count = 12}) => Column(
    children: <Widget>[
      for (int i = 0; i < count; i++)
        SizedBox(
          height: 60,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => taps.add(i),
            child: Center(child: Text('row-$i')),
          ),
        ),
    ],
  );

  // ===================== ① AylaGroupSceneHead =====================

  group('AylaGroupSceneHead（group.css 358–452）', () {
    testWidgets('min-height 72 · 玻璃档（radius16 / blur24 sat1.4 / compact 阴影）· 标题描述字号', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        host(
          const AylaGroupSceneHead(
            title: '群内语音房',
            description: '选择一个房间加入，或点击右下角创建新的群内语音房',
            enter: false,
          ),
        ),
      );

      final Rect head = tester.getRect(find.byType(AylaGroupSceneHead));
      expect(head.height, greaterThanOrEqualTo(72)); // min-height: 72px
      expect(head.width, 600); // flex none + 铺满内容轨道

      final AylaGlassSurface glass = tester.widget<AylaGlassSurface>(
        find.descendant(
          of: find.byType(AylaGroupSceneHead),
          matching: find.byType(AylaGlassSurface),
        ),
      );
      expect(glass.radius, 16); // border-radius: 16px
      expect(glass.blur, AylaGlass.blurCard); // --glass-filter = blur(24px) saturate(1.4)
      expect(glass.shadow, AylaShadows.compact); // --glass-shadow-compact

      final Text title = tester.widget<Text>(find.text('群内语音房'));
      expect(title.style?.fontSize, 18); // font-size: 18px
      expect(title.style?.fontWeight, FontWeight.w500);
      expect(title.style?.height, 1.25); // line-height: 1.25
      expect(title.style?.color, AylaColors.textPrimary);

      final Text desc = tester.widget<Text>(
        find.text('选择一个房间加入，或点击右下角创建新的群内语音房'),
      );
      expect(desc.style?.fontSize, 14); // font-size: 14px
      expect(desc.style?.height, 1.45); // line-height: 1.45
      expect(desc.style?.color, AylaColors.textSecondary);
      expect(desc.maxLines, 1); // white-space: nowrap
      expect(desc.overflow, TextOverflow.ellipsis); // text-overflow: ellipsis

      // padding: sp4（内容左缘 = 16）
      expect(tester.getRect(find.text('群内语音房')).left, AylaSpacing.sp4);
    });

    testWidgets('sticky：滚动后仍钉在滚动口上沿（内容从玻璃头下面穿过）', (
      WidgetTester tester,
    ) async {
      final List<int> taps = <int>[];
      await tester.pumpWidget(
        host(
          AylaGroupSceneStickyHead(
            head: const AylaGroupSceneHead(
              title: '群内语音房',
              description: '滚动看吸顶',
              enter: false,
            ),
            child: rows(taps),
          ),
          // 滚动壳必须落在有界高宿主里（否则 SingleChildScrollView 会撑到内容高、无法滚动）
          height: 400,
        ),
      );

      // 未滚动：头部在 padding sp4 的自然位置，流内占位 = 精确高度
      final Rect at0 = tester.getRect(find.byType(AylaGroupSceneHead));
      expect(at0.top, AylaSpacing.sp4);
      final double headHeight = at0.height;
      expect(headHeight, greaterThanOrEqualTo(AylaGroupSceneHead.minHeight));

      await tester.drag(
        find.byType(SingleChildScrollView),
        const Offset(0, -300),
      );
      // pumpAndSettle：拖拽末段带惯性/夹紧过渡，静止后才量几何（吸附是逐帧求值的）
      await tester.pumpAndSettle();
      final Rect pinned = tester.getRect(find.byType(AylaGroupSceneHead));
      expect(pinned.top, 0); // CSS position: sticky; top: 0（滚动口上沿）
      expect(pinned.height, headHeight); // 高度不变（流内自然占位）

      // 再滚仍钉在同一位置（不是"跟着滚一段"）
      await tester.drag(
        find.byType(SingleChildScrollView),
        const Offset(0, -400),
      );
      await tester.pumpAndSettle();
      expect(tester.getRect(find.byType(AylaGroupSceneHead)).top, 0);

      // 内容确实从玻璃头下面穿过：至少有一行的盒与头部盒相交
      final Rect headBox = tester.getRect(find.byType(AylaGroupSceneHead));
      final bool underHead = <int>[0, 1, 2, 3, 4, 5, 6, 7].any(
        (int i) => tester.getRect(find.text('row-' + i.toString())).top <
            headBox.bottom,
      );
      expect(underHead, isTrue);
    });

    testWidgets('z-index 10：被玻璃头压住的列表项点不到；头部下方点位照常可点', (
      WidgetTester tester,
    ) async {
      final List<int> taps = <int>[];
      await tester.pumpWidget(
        host(
          AylaGroupSceneStickyHead(
            head: const AylaGroupSceneHead(
              title: '群内语音房',
              description: 'desc',
              enter: false,
            ),
            child: rows(taps, count: 8),
          ),
          height: 400,
        ),
      );
      await tester.drag(
        find.byType(SingleChildScrollView),
        const Offset(0, -300),
      );
      await tester.pumpAndSettle();

      final Rect headBox = tester.getRect(find.byType(AylaGroupSceneHead));
      // 头部覆盖区内（x 取中、y 取头部中段）——底层列表项收不到
      await tester.tapAt(Offset(headBox.center.dx, headBox.center.dy));
      await tester.pump();
      expect(taps, isEmpty);

      // 头部下沿之外（同一列、稍下 20px）——列表项收得到
      await tester.tapAt(
        Offset(headBox.center.dx, headBox.bottom + 20),
      );
      await tester.pump();
      expect(taps, hasLength(1));
    });

    testWidgets('入场 auroraqua-panel-from-top（0 −20px → 0,0）；reduced-motion 直出', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        host(
          const AylaGroupSceneHead(
            title: '群内语音房',
            description: 'desc',
          ),
        ),
      );
      // 测试环境 disableAnimations = false ⇒ 入场动画真实播放。
      // ⚠️ 量头部**内部内容**：位移挂在 AylaRevealItem 的 Transform 上，而
      // 「AylaGroupSceneHead 元素的最外 RenderObject」是 Transform 之上的 Opacity
      // ⇒ 对头部件直接 getRect 读到的是布局位（实测 0），不是绘制位。
      expect(
        tester.getRect(find.text('群内语音房')).top,
        -20 + AylaSpacing.sp4, // 头部盒 −20 + padding sp4
      );

      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump();
      expect(
        tester.getRect(find.text('群内语音房')).top,
        AylaSpacing.sp4, // 终态回位
      );
    });

    testWidgets('reduced-motion（disableAnimations）⇒ 不挂动画、直出终态', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: previewScope(
            Builder(
              builder: (BuildContext context) => MediaQuery(
                data: MediaQuery.of(context).copyWith(
                  size: const Size(520, 400),
                  disableAnimations: true,
                ),
                child: const Align(
                  alignment: Alignment.topLeft,
                  child: SizedBox(
                    width: 520,
                    child: AylaGroupSceneHead(title: '群内桌游', description: 'desc'),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      // auroraqua.css 621/637：reduced-motion 把 animation / translate 关掉
      expect(tester.getRect(find.byType(AylaGroupSceneHead)).top, 0);
    });

    testWidgets('≤480：align-items flex-start（尾键顶对齐）；>480 居中', (
      WidgetTester tester,
    ) async {
      final Widget head = AylaGroupSceneHead(
        title: '群内帖子',
        description: '浏览本群的最新动态',
        enter: false,
        trailing: AylaGlassButton(
          label: '我的帖子',
          variant: AylaGlassButtonVariant.ghost,
          onPressed: () {},
        ),
      );
      await tester.pumpWidget(host(head, width: 375));
      final Rect narrowHead = tester.getRect(find.byType(AylaGroupSceneHead));
      final Rect narrowBtn = tester.getRect(find.byType(AylaGlassButton));
      expect(narrowBtn.top, narrowHead.top + AylaSpacing.sp4); // flex-start：与标题同顶
      expect(narrowBtn.center.dy, isNot(closeTo(narrowHead.center.dy, 0.5)));

      // 一态一用例：宽档另起用例
    });

    testWidgets('>480：align-items center（尾键垂直居中）', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        host(
          AylaGroupSceneHead(
            title: '群内帖子',
            description: '浏览本群的最新动态',
            enter: false,
            trailing: AylaGlassButton(
              label: '我的帖子',
              variant: AylaGlassButtonVariant.ghost,
              onPressed: () {},
            ),
          ),
          width: 800,
        ),
      );
      final Rect wideHead = tester.getRect(find.byType(AylaGroupSceneHead));
      final Rect wideBtn = tester.getRect(find.byType(AylaGlassButton));
      expect(wideBtn.center.dy, closeTo(wideHead.center.dy, 0.5));
    });
  });

  // ===================== ② AylaGroupScenePlaceholder =====================

  group('AylaGroupScenePlaceholder（group.css 456–475）', () {
    testWidgets('父高确定 ⇒ height 100% + 内容居中（justify/align center）', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        host(
          SizedBox(
            width: 300,
            height: 300,
            child: AylaGroupScenePlaceholder(
              title: '群内还没有语音房',
              description: '建一个群内语音房，一起连麦',
              actions: <Widget>[
                AylaGlassButton(
                  label: '返回聊天',
                  variant: AylaGlassButtonVariant.ghost,
                  onPressed: () {},
                ),
              ],
            ),
          ),
          width: 300,
          height: 300,
        ),
      );

      // 占位壳自身撑满父高（height: 100%）
      expect(
        tester.getRect(find.byType(AylaGroupScenePlaceholder)).height,
        300,
      );
      // 内容块（标题上沿 → 按钮下沿）垂直居中于父盒
      final double contentTop = tester
          .getRect(find.text('群内还没有语音房'))
          .top;
      final double contentBottom = tester
          .getRect(find.byType(AylaGlassButton))
          .bottom;
      expect((contentTop + contentBottom) / 2, closeTo(150, 1));
      // text-align: center + align-items: center
      expect(
        tester.getRect(find.text('群内还没有语音房')).center.dx,
        closeTo(150, 0.5),
      );
    });

    testWidgets('单键直出 / 多键进 actions 行（gap sp2 + margin-top sp1 + flex-wrap 换行）', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        host(
          SizedBox(
            width: 260,
            height: 300,
            child: AylaGroupScenePlaceholder(
              title: '群内还没有直播',
              description: '发起本群的第一场直播吧',
              actions: <Widget>[
                AylaGlassButton(
                  label: '创建群内直播',
                  variant: AylaGlassButtonVariant.glow,
                  onPressed: () {},
                ),
                AylaGlassButton(
                  label: '返回聊天',
                  variant: AylaGlassButtonVariant.ghost,
                  onPressed: () {},
                ),
              ],
            ),
          ),
          width: 260,
          height: 300,
        ),
      );

      // 文案逐字（GroupLive.tsx:134–152）
      expect(find.text('群内还没有直播'), findsOneWidget);
      expect(find.text('发起本群的第一场直播吧'), findsOneWidget);
      expect(find.text('创建群内直播'), findsOneWidget);
      expect(find.text('返回聊天'), findsOneWidget);

      // 260 宽容纳不下两个键（40 + 8 + ... 实际放得下？→ 断言行内间距/换行结构）
      final Rect first = tester.getRect(find.text('创建群内直播'));
      final Rect second = tester.getRect(find.text('返回聊天'));
      final Wrap actions = tester.widget<Wrap>(
        find.descendant(
          of: find.byType(AylaGroupScenePlaceholder),
          matching: find.byType(Wrap),
        ),
      );
      expect(actions.spacing, AylaSpacing.sp2); // gap: var(--sp-2)
      expect(actions.runSpacing, AylaSpacing.sp2);
      expect(actions.alignment, WrapAlignment.center); // justify-content: center
      // 两键并排（同一行）或换行（第二行）都必须落在壳内且居中
      expect(first.center.dy == second.center.dy || second.top > first.bottom,
          isTrue);
      expect(
        tester.getRect(find.byType(AylaGlassButton).first).center.dx,
        closeTo(130, 24),
      );
    });

    testWidgets('role=alert / status ⇒ liveRegion 语义（assertive / polite）', (
      WidgetTester tester,
    ) async {
      final SemanticsHandle handle = tester.ensureSemantics();
      await tester.pumpWidget(
        host(
          const SizedBox(
            width: 300,
            height: 300,
            child: AylaGroupScenePlaceholder(
              role: AylaGroupScenePlaceholderRole.alert,
              title: '群内直播加载失败',
              description: '加载直播间失败',
            ),
          ),
          width: 300,
          height: 300,
        ),
      );
      final SemanticsNode node = tester.getSemantics(
        find.byType(AylaGroupScenePlaceholder),
      );
      expect(node.flagsCollection.isLiveRegion, isTrue);
      handle.dispose();
    });

    testWidgets('加载档（骨架 + 文案）不带标题也居中；expandHeight:false ⇒ 自然高度', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        host(
          const SizedBox(
            width: 300,
            height: 200,
            // Align：父给"有界但松"的约束 ⇒ 才能验 height: auto 由内容决定
            child: Align(
              alignment: Alignment.topLeft,
              child: AylaGroupScenePlaceholder(
                expandHeight: false, // .group-games-full { height: auto }
                title: '群内还没有桌游室',
                description: '建一个群内桌游室吧',
              ),
            ),
          ),
          width: 300,
          height: 200,
        ),
      );
      final double height = tester
          .getRect(find.byType(AylaGroupScenePlaceholder))
          .height;
      expect(height, lessThan(200)); // height: auto ⇒ 由内容决定
      expect(find.text('群内还没有桌游室'), findsOneWidget);
      expect(find.text('建一个群内桌游室吧'), findsOneWidget);
    });
  });

  // ===================== ③ AylaGroupChatSubgroupBar =====================

  group('AylaGroupChatSubgroupBar（group.css 152–300 + GroupChat.tsx 334–407）', () {
    const List<AylaGroupChatSubgroupTab> subgroups =
        <AylaGroupChatSubgroupTab>[
          AylaGroupChatSubgroupTab(id: 'all', name: '默认组'),
          AylaGroupChatSubgroupTab(id: 'sg-1', name: '星海观测站', unread: 3),
          AylaGroupChatSubgroupTab(id: 'sg-2', name: '深夜电台', muted: true),
          AylaGroupChatSubgroupTab(id: 'sg-3', name: '长名', unread: 120),
        ];

    testWidgets('收起态：无选项卡 · 把手 48×32 · aria-expanded=false · 点把手回调一次', (
      WidgetTester tester,
    ) async {
      final List<bool> collapsedCalls = <bool>[];
      await tester.pumpWidget(
        host(
          Align(
            alignment: Alignment.bottomCenter,
            child: AylaGroupChatSubgroupBar(
              subgroups: subgroups,
              activeId: 'all',
              onSelect: (AylaGroupChatSubgroupTab sg) {},
              collapsed: true,
              onCollapsedChanged: collapsedCalls.add,
            ),
          ),
          width: 375,
          height: 200,
        ),
      );

      // 收起态只有把手：选项卡（含子群名）不渲染
      expect(find.text('默认组'), findsNothing);
      // 把手 48×32（group.css 201–202）
      final Rect handle = tester.getRect(find.byTooltip('展开子群'));
      expect(handle.width, 48);
      expect(handle.height, 32);
      // aria-expanded=false + aria-label（GroupChat.tsx:348–351）
      final SemanticsHandle semantics = tester.ensureSemantics();
      final Finder handleIcon = find.descendant(
        of: find.byKey(AylaGroupChatSubgroupBar.collapseHandleKey),
        matching: find.byType(AylaIcon),
      );
      final SemanticsNode handleNode = tester.getSemantics(handleIcon);
      expect(handleNode.flagsCollection.isExpanded.toBoolOrNull(), isFalse);
      expect(handleNode.label, contains('展开子群选项卡')); // aria-label
      semantics.dispose();

      await tester.tap(find.byTooltip('展开子群'));
      await tester.pump();
      expect(collapsedCalls, <bool>[false]); // 半受控：回调只报一次
    });

    testWidgets('展开态：tablist 语义 + 横向滚动 + 共享胶囊（AylaNavHighlightList）', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        host(
          Align(
            alignment: Alignment.bottomCenter,
            child: AylaGroupChatSubgroupBar(
              subgroups: subgroups,
              activeId: 'sg-1',
              onSelect: (AylaGroupChatSubgroupTab sg) {},
              collapsed: false,
            ),
          ),
          width: 375,
          height: 200,
        ),
      );

      // 四个子群名都在（展开态渲染选项卡行）
      expect(find.text('默认组'), findsOneWidget);
      expect(find.text('星海观测站'), findsOneWidget);

      // role=tablist（aria-label「子群切换」）+ 窄屏横滚
      final AylaNavHighlightList list = tester.widget<AylaNavHighlightList>(
        find.byType(AylaNavHighlightList),
      );
      expect(list.semanticLabel, '子群切换');
      expect(list.axis, Axis.horizontal);
      final SingleChildScrollView scroller = tester.widget<SingleChildScrollView>(
        find.descendant(
          of: find.byType(AylaGroupChatSubgroupBar),
          matching: find.byType(SingleChildScrollView),
        ),
      );
      expect(scroller.scrollDirection, Axis.horizontal);

      // 选中胶囊由公共件绘制（本件不自己画选中底）
      final SemanticsHandle semantics = tester.ensureSemantics();
      final SemanticsNode active = tester.getSemantics(
        find.text('星海观测站'),
      );
      expect(active.flagsCollection.isSelected.toBoolOrNull(), isTrue);
      semantics.dispose();
    });

    testWidgets('选中回调只触发一次；点当前选中项不触发（switchSubgroup 提前 return）', (
      WidgetTester tester,
    ) async {
      final List<String> selected = <String>[];
      await tester.pumpWidget(
        host(
          Align(
            alignment: Alignment.bottomCenter,
            child: AylaGroupChatSubgroupBar(
              subgroups: subgroups,
              activeId: 'all',
              onSelect: (AylaGroupChatSubgroupTab sg) => selected.add(sg.id),
              collapsed: false,
            ),
          ),
          width: 375,
          height: 200,
        ),
      );

      await tester.tap(find.text('星海观测站'));
      await tester.pump();
      expect(selected, <String>['sg-1']); // 恰好一次

      await tester.tap(find.text('默认组')); // 已选中项
      await tester.pump();
      expect(selected, <String>['sg-1']); // 不追加
    });

    testWidgets('未读徽标（>99 ⇒ 99+）与禁言 chip', (WidgetTester tester) async {
      await tester.pumpWidget(
        host(
          Align(
            alignment: Alignment.bottomCenter,
            child: AylaGroupChatSubgroupBar(
              subgroups: subgroups,
              activeId: 'all',
              onSelect: (AylaGroupChatSubgroupTab sg) {},
              collapsed: false,
            ),
          ),
          width: 375,
          height: 200,
        ),
      );

      expect(find.text('3'), findsOneWidget); // unreadByKey 的未读数
      expect(find.text('99+'), findsOneWidget); // >99 ⇒ 「99+」
      expect(find.text('禁言'), findsOneWidget); // sg.muted ⇒ chip
      // 徽标底 --pink-500（group.css 309）
      final Container badge = tester.widget<Container>(
        find
            .ancestor(of: find.text('3'), matching: find.byType(Container))
            .first,
      );
      expect(
        (badge.decoration! as BoxDecoration).color,
        AylaColors.pink500,
      );
    });

    testWidgets('hasMore / loadingMore：文案「加载更多子群」→「加载中…」且禁用', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        host(
          Align(
            alignment: Alignment.bottomCenter,
            child: AylaGroupChatSubgroupBar(
              subgroups: subgroups,
              activeId: 'all',
              onSelect: (AylaGroupChatSubgroupTab sg) {},
              collapsed: false,
              hasMore: true,
              loadingMore: true,
              onLoadMore: () {},
            ),
          ),
          width: 375,
          height: 200,
        ),
      );
      expect(find.text('加载中…'), findsOneWidget);
      expect(find.text('加载更多子群'), findsNothing);
    });

    testWidgets('hasMore 且不在加载：显示「加载更多子群」，点击走 onLoadMore（不选子群）', (
      WidgetTester tester,
    ) async {
      int loadMore = 0;
      final List<String> selected = <String>[];
      await tester.pumpWidget(
        host(
          Align(
            alignment: Alignment.bottomCenter,
            child: AylaGroupChatSubgroupBar(
              // 只放 1 个子群：保证「加载更多子群」键落在 375 宽视口内（窄屏横滚下末键会出屏）
              subgroups: const <AylaGroupChatSubgroupTab>[
                AylaGroupChatSubgroupTab(id: 'all', name: '默认组'),
              ],
              activeId: 'all',
              onSelect: (AylaGroupChatSubgroupTab sg) => selected.add(sg.id),
              collapsed: false,
              hasMore: true,
              onLoadMore: () => loadMore++,
            ),
          ),
          width: 375,
          height: 200,
        ),
      );
      expect(find.text('加载更多子群'), findsOneWidget);
      await tester.tap(find.text('加载更多子群'));
      await tester.pump();
      expect(loadMore, 1);
      expect(selected, isEmpty); // 附加键不参与选中（索引越界防护）
    });
  });

  // ===================== ④ AylaGroupPostsComposer =====================

  group('AylaGroupPostsComposer（posts.css 933–951 / 1011–1108 + auroraqua 347–368）', () {
    Future<void> submit(AylaPostDraft draft) async {}

    Widget composer({required bool expanded, bool controlled = true}) =>
        AylaGroupPostsComposer(
          onSubmit: submit,
          groupId: 'g1',
          expanded: controlled ? expanded : null,
          child: const SizedBox.expand(),
        );

    testWidgets('收起态：无遮罩 · 输入面板在流内 · 正文行高 22（字段高 40）', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        host(composer(expanded: false), width: 375, height: 400),
      );
      // 入场 auroraqua-panel-from-bottom（+20px，300ms）落定后再量几何
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump();

      // 无 scrim（rgba(70,91,146,.25)）
      expect(
        find.byWidgetPredicate(
          (Widget w) => w is ColoredBox && w.color == AylaColors.overlayDim,
        ),
        findsNothing,
      );
      // 正文字段：composerShell 档 ⇒ padding sp2 sp3 + line-height 22 ⇒ height 40
      final Rect field = tester.getRect(find.byType(AylaGlassInput));
      // posts.css 1047–1049：padding sp2 sp3 + line-height 22 ⇒ 40
      // （Flutter TextField 固有高比 CSS 行盒多 1px ⇒ 实测 41，登记 1px 容差）
      expect(field.height, closeTo(40, 1));
      // 输入面板仍在流内：底边贴宿主底（窄屏无 margin）
      final Rect surface = tester.getRect(
        find.descendant(
          of: find.byType(AylaGroupPostsComposer),
          matching: find.byType(AylaGlassSurface),
        ),
      );
      expect(surface.bottom, 400);
    });

    testWidgets('展开态：遮罩出现（z45）· 面板贴底（z50）· 点遮罩 ⇒ onExpandedChange(false) 一次', (
      WidgetTester tester,
    ) async {
      final List<bool> changes = <bool>[];
      await tester.pumpWidget(
        host(
          AylaGroupPostsComposer(
            onSubmit: submit,
            groupId: 'g1',
            expanded: true,
            onExpandedChange: changes.add,
            child: const SizedBox.expand(),
          ),
          width: 375,
          height: 400,
        ),
      );
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump();

      final Finder scrim = scrimFinder();
      expect(scrim, findsOneWidget);
      expect(tester.getRect(scrim), const Rect.fromLTWH(0, 0, 375, 400)); // inset: 0

      // 面板贴底：bottom: 0（面板盒 = 展开态滚动口）
      final Rect panel = tester.getRect(panelViewport());
      expect(panel.bottom, closeTo(400, 0.5));
      expect(panel.top, greaterThan(0)); // 面板之上的压暗带仍是遮罩

      // 点遮罩：落在面板**之上**的压暗带里（面板盖住遮罩的部分点不到，与 web 一致）
      await tester.tapAt(Offset(panel.center.dx, panel.top / 2));
      await tester.pump();
      expect(changes, <bool>[false]);
    });

    testWidgets('展开态 max-height：窄屏 100% / 宽屏 calc(100% − 2×sidebar-gutter)', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        host(composer(expanded: true), width: 375, height: 400),
      );
      await tester.pump(const Duration(milliseconds: 300));
      final List<double> heights = panelMaxHeights(tester);
      expect(heights, contains(400)); // max-height: 100%
      expect(heights, isNot(contains(376))); // 窄屏不减 sidebar-gutter
    });

    testWidgets('宽屏 ≥769：margin 12 + max-height 减 2×sidebar-gutter + 浮动玻璃卡档', (
      WidgetTester tester,
    ) async {
      // 默认测试窗口逻辑宽 800 ⇒ 820 宽宿主会被夹到 800（断点判定走 MediaQuery，
      // 但布局盒会变）；钉死窗口后再验几何。
      tester.view.physicalSize = const Size(1800, 1400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        host(composer(expanded: true), width: 820, height: 400),
      );
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump();
      // 面板滚动口：贴底（bottom 0）且高度 = calc(100% − 2 × 12) = 376
      final Rect panel = tester.getRect(panelViewport());
      expect(panel.bottom, closeTo(400, 0.5));
      expect(panel.height, closeTo(400 - 2 * AylaSpacing.sidebarGutter, 0.5));

      // margin：surface 左缘贴 0（auroraqua 367 margin-left: 0）、上缘让出 12
      final Rect surface = tester.getRect(
        find.descendant(
          of: find.byType(AylaGroupPostsComposer),
          matching: find.byType(AylaGlassSurface),
        ),
      );
      expect(surface.left, 0);
      expect(surface.right, 820 - AylaSpacing.sidebarGutter);

      // calc(100% − 2 × 12) = 376
      expect(
        panelMaxHeights(tester),
        contains(400 - 2 * AylaSpacing.sidebarGutter),
      );
    });

    testWidgets('半受控：expanded=null 时内部自持（点输入框展开 ⇒ 出遮罩）', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        host(composer(expanded: false, controlled: false), width: 375, height: 400),
      );
      expect(
        find.byWidgetPredicate(
          (Widget w) => w is ColoredBox && w.color == AylaColors.overlayDim,
        ),
        findsNothing,
      );

      // 点正文框 ⇒ 编辑器 onFocus 展开 ⇒ 外壳跟随出遮罩
      await tester.tap(find.byType(TextField));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(
        find.byWidgetPredicate(
          (Widget w) => w is ColoredBox && w.color == AylaColors.overlayDim,
        ),
        findsOneWidget,
      );
    });
  });
}
