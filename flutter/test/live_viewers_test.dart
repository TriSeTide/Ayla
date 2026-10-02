/// B2-4：在看观众条 + 在看名单弹层定向测试 —— 逐条对照
/// `components/live/LiveViewerStrip.tsx`(85) / `LiveViewerSheet.tsx`(147)、
/// `live.css:1095–1325`，并移植官方用例 `vitest/live-viewers.test.tsx:161–256`
/// （整排可点 / 未知不冒充 0 / 0 是真实读数 / 纯展示不拉数据 / 行跳主页后关闭 /
/// 截断提示 / 503 明示 + 重试 / portal 到 body）。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../lib/theme/preview_theme.dart';
import '../lib/theme/tokens.dart';
import '../lib/widgets/base/avatar_halo.dart';
import '../lib/widgets/base/dialogs.dart' show AylaModalCard;
import '../lib/widgets/base/loading.dart' show AylaSkeleton;
import '../lib/core/api/live_api.dart'
    show AylaLiveViewer, AylaLiveViewersResult;
import '../lib/pages/live_support.dart'
    show AylaLiveViewerSheetController, kLiveViewerSheetRowCap;
import '../lib/widgets/live/live_viewers.dart';

const List<AylaLiveViewerItem> _watchers = <AylaLiveViewerItem>[
  AylaLiveViewerItem(userId: 'u1', nickname: '小冰'),
  AylaLiveViewerItem(userId: 'u2', nickname: '小樱'),
];

void main() {
  Widget host(
    WidgetTester tester,
    Widget child, {
    Size viewport = const Size(900, 700),
  }) {
    tester.view.physicalSize = viewport;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    return MaterialApp(
      home: previewScope(
        Builder(
          builder: (BuildContext context) => MediaQuery(
            data: MediaQuery.of(context).copyWith(size: viewport),
            child: Align(
              alignment: Alignment.topLeft,
              child: SizedBox.fromSize(size: viewport, child: child),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> settle(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }

  /// 整排按钮（aria 文案定位，官方用例用 role+name 同义）。
  Finder strip(String label) => find.byWidgetPredicate(
    (Widget w) => w is Semantics && w.properties.label == label,
  );

  group('LiveViewerStrip（官方用例 161–209）', () {
    testWidgets('渲染人数 + 头像 + 三圆点「更多」，整排可点开名单', (WidgetTester tester) async {
      await tester.pumpWidget(
        host(
          tester,
          const AylaLiveViewerStrip(count: 2, viewers: _watchers),
          viewport: const Size(560, 300),
        ),
      );
      await settle(tester);

      expect(strip('正在观看 2 人，查看完整名单'), findsOneWidget);
      expect(find.text('2'), findsOneWidget);
      // 预览头像复用 AylaAvatarHalo（在流光环）
      expect(find.byType(AylaAvatarHalo), findsNWidgets(2));
      // 排尾是「更多」三圆点图标（不是文本省略号）
      expect(
        find.byWidgetPredicate(
          (Widget w) =>
              w is Container && w.constraints?.maxWidth == 26 && w.constraints?.maxHeight == 26,
        ),
        findsOneWidget,
      );

      await tester.tap(strip('正在观看 2 人，查看完整名单'));
      await settle(tester);
      // 弹层标题 = 「正在观看 · N 人」（tsx 83–86）
      expect(find.text('正在观看 · 2 人'), findsOneWidget);
      expect(find.byType(AylaLiveViewerSheet), findsOneWidget);
    });

    testWidgets('人数未知仍占位：显示 –，不冒充 0，且高度与已知态一致', (WidgetTester tester) async {
      // ⚠️ 同一用例里不能第二次 pumpWidget 换 props（`previewScope` 的 Overlay 只在首次创建
      //    生效，§6.19/§6.21 已两次记录；实测第二次 pump 连 didUpdateWidget 都不触发）
      //    ⇒ 用树内 StatefulBuilder 的 setState 切态。
      int? count = 3;
      late StateSetter setLocal;
      await tester.pumpWidget(
        host(
          tester,
          StatefulBuilder(
            builder: (BuildContext context, StateSetter setState) {
              setLocal = setState;
              return AylaLiveViewerStrip(count: count);
            },
          ),
          viewport: const Size(560, 300),
        ),
      );
      await settle(tester);
      final double known = tester.getRect(find.byType(AylaLiveViewerStrip)).height;
      expect(find.text('3'), findsOneWidget);

      setLocal(() => count = null);
      await settle(tester);
      expect(find.text('–'), findsOneWidget);
      expect(find.text('0'), findsNothing);
      expect(
        tester.getRect(find.byType(AylaLiveViewerStrip)).height,
        known,
        reason: '未知态高度必须与已知态完全一致（禁止画面跳变）',
      );
    });

    testWidgets('0 人是真实读数：显示 0，无头像，仍有「更多」入口', (WidgetTester tester) async {
      await tester.pumpWidget(
        host(
          tester,
          const AylaLiveViewerStrip(count: 0),
          viewport: const Size(560, 300),
        ),
      );
      await settle(tester);
      expect(find.text('0'), findsOneWidget);
      expect(find.byType(AylaAvatarHalo), findsNothing);
      expect(find.text('–'), findsNothing);
    });

    testWidgets('预览上限 12：多给只渲染前 12 个头像（tsx 27）', (WidgetTester tester) async {
      await tester.pumpWidget(
        host(
          tester,
          AylaLiveViewerStrip(
            count: 20,
            viewers: <AylaLiveViewerItem>[
              for (int i = 1; i <= 15; i += 1)
                AylaLiveViewerItem(userId: '$i', nickname: '观众$i'),
            ],
          ),
          viewport: const Size(560, 300),
        ),
      );
      await settle(tester);
      expect(kAylaLiveViewerPreviewMax, 12);
      expect(find.byType(AylaAvatarHalo), findsNWidgets(12));
    });

    testWidgets('纯展示：空数据也不报错、不弹层（不自行拉数据）', (WidgetTester tester) async {
      await tester.pumpWidget(
        host(
          tester,
          const AylaLiveViewerStrip(count: null),
          viewport: const Size(560, 300),
        ),
      );
      await settle(tester);
      expect(tester.takeException(), isNull);
      expect(find.byType(AylaLiveViewerSheet), findsNothing);
    });

    testWidgets('几何：min-height 44 / padding sp1 sp3 / radius-input / 玻璃底', (WidgetTester tester) async {
      await tester.pumpWidget(
        host(
          tester,
          const AylaLiveViewerStrip(count: 1),
          viewport: const Size(560, 300),
        ),
      );
      await settle(tester);
      final Rect rect = tester.getRect(find.byType(AylaLiveViewerStrip));
      expect(rect.height, greaterThanOrEqualTo(44)); // min-height: 44px
      final Container box = tester.widget<Container>(
        find
            .descendant(
              of: find.byType(AylaLiveViewerStrip),
              matching: find.byType(Container),
            )
            .first,
      );
      final BoxDecoration deco = box.decoration! as BoxDecoration;
      expect(deco.color, AylaColors.glassBg);
      expect(
        (deco.borderRadius! as BorderRadius).topLeft.x,
        AylaRadii.rInput,
      );
      expect(box.padding, isNotNull);
    });
  });

  group('LiveViewerSheet（官方用例 211–256）', () {
    testWidgets('名单渲染头像 + 昵称；点整行 → 回调 + 关闭弹层', (WidgetTester tester) async {
      String? picked;
      await tester.pumpWidget(
        host(
          tester,
          AylaLiveViewerSheet(
            preview: _watchers,
            data: AylaLiveViewerSheetData(
              viewers: _watchers,
              count: 2,
              onOpenProfile: (AylaLiveViewerItem v) => picked = v.userId,
            ),
            onClose: () {},
          ),
          viewport: const Size(900, 700),
        ),
      );
      await settle(tester);

      expect(find.text('小冰'), findsOneWidget);
      expect(find.text('小樱'), findsOneWidget);
      expect(find.byType(AylaAvatarHalo), findsNWidgets(2));

      await tester.tap(strip('查看 小冰 的个人主页'));
      await settle(tester);
      expect(picked, 'u1');
    });

    testWidgets('点行后由组件调用 onClose（跳转并关闭）', (WidgetTester tester) async {
      int closes = 0;
      await tester.pumpWidget(
        host(
          tester,
          AylaLiveViewerSheet(
            preview: _watchers,
            data: const AylaLiveViewerSheetData(
              viewers: _watchers,
              count: 2,
            ),
            onClose: () => closes += 1,
          ),
          viewport: const Size(900, 700),
        ),
      );
      await settle(tester);
      await tester.tap(strip('查看 小樱 的个人主页'));
      await settle(tester);
      expect(closes, 1);
    });

    testWidgets('截断 → 「仅显示前 N 位」；爱莉标记走 AylaAvatarHalo 的 elysia 档', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        host(
          tester,
          AylaLiveViewerSheet(
            preview: _watchers,
            data: const AylaLiveViewerSheetData(
              viewers: _watchers,
              count: 200,
              hasMore: true,
              elysiaUserId: 'u2',
            ),
            onClose: () {},
          ),
          viewport: const Size(900, 700),
        ),
      );
      await settle(tester);
      expect(find.text('仅显示前 2 位'), findsOneWidget);
      final List<AylaAvatarHalo> avatars = tester
          .widgetList<AylaAvatarHalo>(find.byType(AylaAvatarHalo))
          .toList();
      expect(avatars[1].core, AylaAvatarCore.elysia); // u2 = 爱莉
      expect(avatars[0].core, AylaAvatarCore.user);
    });

    testWidgets('503 → role=alert 明示读不到 + 重试；**不**回落空名单', (WidgetTester tester) async {
      int retries = 0;
      await tester.pumpWidget(
        host(
          tester,
          AylaLiveViewerSheet(
            preview: _watchers, // 有预览也要走错误态（web：rows = error ? [] : preview）
            data: AylaLiveViewerSheetData(
              error: '暂时读不到在看名单',
              onRetry: () => retries += 1,
            ),
            onClose: () {},
          ),
          viewport: const Size(900, 700),
        ),
      );
      await settle(tester);

      expect(find.text('暂时读不到在看名单'), findsOneWidget);
      expect(find.text('还没有人在看'), findsNothing); // 不冒充空名单
      expect(find.text('小冰'), findsNothing);
      // 标题退化：`count === null && error` → 「正在观看」
      expect(find.text('正在观看'), findsOneWidget);
      await tester.tap(find.text('重试'));
      await settle(tester);
      expect(retries, 1);
    });

    testWidgets('空态：viewers 为空列表 → 「还没有人在看」', (WidgetTester tester) async {
      await tester.pumpWidget(
        host(
          tester,
          const AylaLiveViewerSheet(
            preview: <AylaLiveViewerItem>[],
            data: AylaLiveViewerSheetData(
              viewers: <AylaLiveViewerItem>[],
              count: 0,
            ),
            onClose: _noop,
          ),
          viewport: const Size(900, 700),
        ),
      );
      await settle(tester);
      expect(find.text('还没有人在看'), findsOneWidget);
      expect(find.text('正在观看 · 0 人'), findsOneWidget);
    });

    testWidgets('骨架：viewers == null 且无预览 → 6 行（头像 41 + 名字 40%）', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        host(
          tester,
          const AylaLiveViewerSheet(
            preview: <AylaLiveViewerItem>[],
            data: AylaLiveViewerSheetData(),
            onClose: _noop,
          ),
          viewport: const Size(900, 700),
        ),
      );
      await settle(tester);
      // 6 行 × 2 块骨架
      expect(
        find.byType(AylaSkeleton),
        findsNWidgets(AylaLiveViewerSheet.skeletonRows * 2),
      );
      expect(find.text('还没有人在看'), findsNothing);
    });

    testWidgets('预览打底：viewers == null 但有预览 → 直接渲染预览（不显示骨架）', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        host(
          tester,
          const AylaLiveViewerSheet(
            preview: _watchers,
            data: AylaLiveViewerSheetData(),
            onClose: _noop,
          ),
          viewport: const Size(900, 700),
        ),
      );
      await settle(tester);
      expect(find.text('小冰'), findsOneWidget);
      // total = count ?? rows.length → 2
      expect(find.text('正在观看 · 2 人'), findsOneWidget);
      expect(find.byType(AylaSkeleton), findsNothing);
    });

    testWidgets('窄屏（≤768）→ 弹层高度 = 60vh（web `.live-viewer-sheet-card` 档）', (
      WidgetTester tester,
    ) async {
      const Size vp = Size(420, 600);
      await tester.pumpWidget(
        host(
          tester,
          const AylaLiveViewerSheet(
            preview: _watchers,
            data: AylaLiveViewerSheetData(viewers: _watchers, count: 2),
            onClose: _noop,
          ),
          viewport: vp,
        ),
      );
      await settle(tester);
      final Rect card = tester.getRect(find.byType(AylaModalCard));
      expect(card.height, closeTo(vp.height * 0.6, 0.5)); // height: 60vh
      expect(card.bottom, vp.height); // 贴底上滑
    });

    testWidgets('窄屏 60vh 是**内容盒自身**高：玻璃面/边框/圆角铺满整档（用户实报问题 11）', (
      WidgetTester tester,
    ) async {
      // ⚠️ **2026-10-02 用户实报（问题 11）**：窄屏弹层呈「居中矮条」——卡片的
      // `ConstrainedBox` 确实被撑成 60vh 且贴底，但**玻璃面只画内容高**（实机
      // 857×1092 @dpr1.25 实测 135px），停在卡片顶部，下方整片透明 ⇒ 观感就是
      // 「凭空在屏幕中间弹出一个小弹窗」；外加四角圆角 = 更像浮卡。
      //
      // 事实源：`live.css:1321–1327` 的 `.live-viewer-sheet-card { height: 60vh;
      // max-height: 60vh }` 是**内容盒自身**高 60vh ⇒ 背景/边框/圆角自然铺满。
      // Flutter 侧 `minHeight: fixedH` 只作用于紧邻子级，且 face 作为 Stack 的
      // 非定位子级收到的是 loose 约束 ⇒ 会按内容收缩（本用例锁死该回归）。
      //
      // 断言用**装饰盒（面）**而不是 `AylaModalCard` 的外框 —— 后者曾一直是对的，
      // 正是它掩盖了这个缺陷（详见 `test/create_sheet_test.dart` 的同源用例）。
      const Size vp = Size(420, 600);
      await tester.pumpWidget(
        host(
          tester,
          const AylaLiveViewerSheet(
            preview: _watchers,
            data: AylaLiveViewerSheetData(viewers: _watchers, count: 2),
            onClose: _noop,
          ),
          viewport: vp,
        ),
      );
      await settle(tester);

      final Rect card = tester.getRect(find.byType(AylaModalCard));
      // 面的矩形 = 卡的内框（无 margin；卡外框就是面）
      final Rect face = tester.getRect(
        find
            .descendant(
              of: find.byType(AylaModalCard),
              matching: find.byType(DecoratedBox),
            )
            .first,
      );
      expect(
        face.height,
        closeTo(vp.height * 0.6, 0.5),
        reason: '玻璃面必须铺满 60vh（web `height: 60vh` 是内容盒自身高，不是 max-height）',
      );
      expect(face.bottom, closeTo(vp.height, 0.5), reason: '面同样贴底');
      expect(
        face.height,
        closeTo(card.height, 0.5),
        reason: '面高 == 卡框高（不得只画内容高）',
      );

      // 贴底档特征：**只有上两角**圆角（`radius 24 24 0 0`）
      final DecoratedBox faceBox = tester.widget<DecoratedBox>(
        find
            .descendant(
              of: find.byType(AylaModalCard),
              matching: find.byType(DecoratedBox),
            )
            .first,
      );
      final BorderRadius rad =
          (faceBox.decoration as BoxDecoration).borderRadius! as BorderRadius;
      expect(rad.bottomLeft, Radius.zero, reason: '贴底档下方无圆角');
      expect(rad.bottomRight, Radius.zero, reason: '贴底档下方无圆角');
      expect(rad.topLeft.x, 24); // create-sheet 窄屏 radius 24 24 0 0
      expect(rad.topRight.x, 24);
    });

    testWidgets('宽屏浮卡仍是**按内容收缩**（不能被上一条的铺满修复带偏）', (
      WidgetTester tester,
    ) async {
      // 上一条修的是「窄屏固定高」档；宽屏浮卡（`live.css` 无媒体查询 ⇒ max-height 80vh）
      // 保持内容高 + 居中 + 四角圆角（既有行为不变）。
      const Size vp = Size(900, 700);
      await tester.pumpWidget(
        host(
          tester,
          const AylaLiveViewerSheet(
            preview: _watchers,
            data: AylaLiveViewerSheetData(viewers: _watchers, count: 2),
            onClose: _noop,
          ),
          viewport: vp,
        ),
      );
      await settle(tester);
      final Rect card = tester.getRect(find.byType(AylaModalCard));
      expect(card.height, lessThan(vp.height * 0.8), reason: '浮卡按内容收缩，不吃满 80vh');
      expect(card.center.dy, closeTo(vp.height / 2, 1.0), reason: '宽屏居中');
      final DecoratedBox faceBox = tester.widget<DecoratedBox>(
        find
            .descendant(
              of: find.byType(AylaModalCard),
              matching: find.byType(DecoratedBox),
            )
            .first,
      );
      final BorderRadius rad =
          (faceBox.decoration as BoxDecoration).borderRadius! as BorderRadius;
      expect(rad.bottomLeft.x, 20, reason: '浮卡四角圆角 --radius-panel');
    });

    testWidgets('head 固定：标题行**不在**滚动视图内，只有名单本身滚动', (WidgetTester tester) async {
      await tester.pumpWidget(
        host(
          tester,
          AylaLiveViewerSheet(
            preview: _watchers,
            data: AylaLiveViewerSheetData(
              viewers: <AylaLiveViewerItem>[
                for (int i = 1; i <= 40; i += 1)
                  AylaLiveViewerItem(userId: '$i', nickname: '观众$i'),
              ],
              count: 40,
            ),
            onClose: () {},
          ),
          viewport: const Size(900, 500),
        ),
      );
      await settle(tester);

      // 标题不在任何滚动视图内（`.create-sheet-head { flex: none }`）
      expect(
        find.ancestor(
          of: find.text('正在观看 · 40 人'),
          matching: find.byType(SingleChildScrollView),
        ),
        findsNothing,
      );
      // 名单在滚动视图内
      expect(
        find.ancestor(
          of: find.text('观众40'),
          matching: find.byType(SingleChildScrollView),
        ),
        findsWidgets,
      );
      // 内容确实超过可视区（限高生效）
      final Rect card = tester.getRect(find.byType(AylaModalCard));
      expect(
        tester.getRect(find.text('观众40')).bottom,
        greaterThan(card.bottom),
      );
    });

    testWidgets('弹层插在 root Overlay（等价 web portal 到 body）：不在条子组件子树内', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        host(
          tester,
          const Center(
            child: SizedBox(
              width: 480,
              child: AylaLiveViewerStrip(count: 2, viewers: _watchers),
            ),
          ),
          viewport: const Size(900, 700),
        ),
      );
      await settle(tester);
      await tester.tap(strip('正在观看 2 人，查看完整名单'));
      await settle(tester);

      expect(find.byType(AylaLiveViewerSheet), findsOneWidget);
      // 不在 strip 子树内（说明是插到 root overlay 的独立子树）
      expect(
        find.ancestor(
          of: find.byType(AylaLiveViewerSheet),
          matching: find.byType(AylaLiveViewerStrip),
        ),
        findsNothing,
      );
      // 覆盖整个窗口（stage 之外的区域也属于弹层遮罩）
      final Rect card = tester.getRect(find.byType(AylaModalCard));
      expect(card.top, greaterThan(0)); // 居中卡 ⇒ 上下都有遮罩
      expect(card.width, 480); // min(480, 100%)
    });
  });

  // ================== 弹层打开时传真实数据（问题 11 附带） ==================
  //
  // web 的权威名单是**弹层自己在打开时拉的**（`LiveViewerSheet.tsx:44–65` 的
  // `getLiveChannelViewers` + `:67–79` 的 `getElysiaProfile`；弹幕 WS 预览只在
  // `viewers === null` 时打底，`:81`）。Flutter 的网络层不进 `lib/widgets`
  // ⇒ 组件暴露 `onOpen`，页面（`live_support.dart` 的
  // `AylaLiveViewerSheetController`）承接同一次拉取。
  group('弹层打开 → 页面承接同一次拉取（LiveViewerSheet.tsx:44–79）', () {
    AylaLiveViewersResult page({
      String channelId = '7',
      int count = 7,
      bool hasMore = false,
      List<AylaLiveViewer> viewers = const <AylaLiveViewer>[],
    }) =>
        AylaLiveViewersResult(
          channelId: channelId,
          count: count,
          hasMore: hasMore,
          viewers: viewers,
        );

    testWidgets('点整排 → onOpen 触发；控制器拉到真实数据后弹层渲染真实名单（非骨架）', (
      WidgetTester tester,
    ) async {
      int opened = 0;
      final AylaLiveViewerSheetController controller =
          AylaLiveViewerSheetController(
        fetcher: (String channelId) async => page(
          channelId: channelId,
          count: 7,
          hasMore: true,
          viewers: const <AylaLiveViewer>[
            AylaLiveViewer(userId: 'u1', nickname: '小冰'),
            AylaLiveViewer(userId: 'u2', nickname: '小樱'),
          ],
        ),
      );
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        host(
          tester,
          ListenableBuilder(
            listenable: controller,
            builder: (BuildContext context, Widget? _) => AylaLiveViewerStrip(
              count: 7,
              viewers: const <AylaLiveViewerItem>[
                AylaLiveViewerItem(userId: 'u3', nickname: '仅预览'),
              ],
              sheet: controller.value,
              onOpen: () {
                opened += 1;
                controller.onOpen('7');
              },
            ),
          ),
          viewport: const Size(560, 300),
        ),
      );
      await settle(tester);
      expect(opened, 0, reason: '未打开时不该拉');

      await tester.tap(strip('正在观看 7 人，查看完整名单'));
      await settle(tester);
      expect(opened, 1, reason: '打开弹层 → 页面发起拉取');

      // 弹层里渲染**权威名单**（不是骨架、也不是仅预览）
      expect(find.text('小冰'), findsOneWidget);
      expect(find.text('小樱'), findsOneWidget);
      expect(find.text('仅预览'), findsNothing, reason: '权威名单到达后替换预览打底');
      expect(find.text('正在观看 · 7 人'), findsOneWidget);
      expect(find.text('仅显示前 2 位'), findsOneWidget, reason: 'has_more');
      expect(find.byType(AylaSkeleton), findsNothing, reason: '不再骨架');
    });

    testWidgets('打开 → 503（presence 不可用）→ 明示「暂时读不到在看名单」+ 重试可再拉', (
      WidgetTester tester,
    ) async {
      int calls = 0;
      final AylaLiveViewerSheetController controller =
          AylaLiveViewerSheetController(
        fetcher: (String channelId) async {
          calls += 1;
          if (calls == 1) throw StateError('presence unavailable');
          return page(
            channelId: channelId,
            count: 1,
            viewers: const <AylaLiveViewer>[
              AylaLiveViewer(userId: 'u1', nickname: '小冰'),
            ],
          );
        },
      );
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        host(
          tester,
          ListenableBuilder(
            listenable: controller,
            builder: (BuildContext context, Widget? _) => AylaLiveViewerStrip(
              count: null,
              sheet: controller.value.copyWith(onRetry: controller.retry('9')),
              onOpen: () => controller.onOpen('9'),
            ),
          ),
          viewport: const Size(560, 320),
        ),
      );
      await settle(tester);
      await tester.tap(strip('正在观看人数未知，查看名单'));
      await settle(tester);
      expect(find.text('暂时读不到在看名单'), findsOneWidget, reason: '不回落空名单');
      expect(find.text('还没有人在看'), findsNothing);

      await tester.tap(find.text('重试'));
      await settle(tester);
      expect(calls, 2);
      expect(find.text('小冰'), findsOneWidget);
    });

    testWidgets('已拿到权威名单后再打开 → 不重复拉（幂等）', (WidgetTester tester) async {
      int calls = 0;
      final AylaLiveViewerSheetController controller =
          AylaLiveViewerSheetController(
        fetcher: (String channelId) async {
          calls += 1;
          return page(
            channelId: channelId,
            count: 1,
            viewers: const <AylaLiveViewer>[
              AylaLiveViewer(userId: 'u1', nickname: '小冰'),
            ],
          );
        },
      );
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        host(
          tester,
          ListenableBuilder(
            listenable: controller,
            builder: (BuildContext context, Widget? _) => AylaLiveViewerStrip(
              count: 1,
              sheet: controller.value,
              onOpen: () => controller.onOpen('1'),
            ),
          ),
          viewport: const Size(560, 300),
        ),
      );
      await settle(tester);
      await tester.tap(strip('正在观看 1 人，查看完整名单'));
      await settle(tester);
      expect(calls, 1);
      // 第二次打开（弹层已关掉再开，等价）：已有名单 ⇒ 不重复拉
      controller.onOpen('1');
      await settle(tester);
      expect(calls, 1, reason: '已有名单 → 再打开不重拉');
    });

    test('行数上限 = 200（web tsx 23–24：后端已截断，前端不重复限制）', () {
      expect(kLiveViewerSheetRowCap, 200);
    });
  });
}

void _noop() {}
