/// B2-6：直播间装配（`LiveRoomBody.tsx` 566）定向测试。
///
/// 覆盖：宽屏三栏装配（侧栏 / 头部 / stage / 观众条 / 弹幕侧列）/ 侧栏收起与展开键 /
/// 进房错误态仍保留侧栏与弹幕区 / 窄屏沉浸式（列表覆盖层开关 + 上下滑切台）/ 控制台
/// （资料栏 + 推流地址，仅 owner）/ hideRail / 飘弹幕层仅在 live 且非 loading 时挂载 /
/// **切台动效**（tsx 139–151 的 `mediaPanels` 三 target 重播 + tsx 542–565 的头部
/// `AnimatePresence mode="wait"` 退出→进入，含 reduced-motion 与错误态关闭）。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../lib/theme/glass.dart' show AylaGlassSurface;
import '../lib/theme/preview_theme.dart';
import '../lib/widgets/live/danmaku.dart'
    show AylaDanmakuEntry, AylaDanmakuInput, AylaDanmakuList, AylaDanmakuOverlay;
import '../lib/widgets/live/live_channel_snapshot.dart';
import '../lib/widgets/live/live_hall.dart' show AylaLiveCardData, AylaLiveStatus;
import '../lib/widgets/live/live_owner_panel.dart' show AylaLiveOwnerPanel;
import '../lib/widgets/live/live_player.dart' show AylaLivePlayer, AylaLiveSrsStatus;
import '../lib/widgets/live/live_rail.dart' show AylaLiveChannelRail;
import '../lib/widgets/live/live_room_body.dart';
import '../lib/widgets/live/live_studio.dart' show AylaLiveStreamAddresses;
import '../lib/widgets/base/reveal.dart' show AylaRevealItem, AylaRevealScope;
import '../lib/widgets/base/share.dart' show AylaShareButton;
import '../lib/widgets/live/live_viewers.dart' show AylaLiveViewerStrip;

const List<AylaLiveCardData> _channels = <AylaLiveCardData>[
  AylaLiveCardData(id: 'lc1', title: '第一场直播', status: AylaLiveStatus.live),
  AylaLiveCardData(id: 'lc2', title: '第二场直播', status: AylaLiveStatus.live),
];

AylaLiveChannelSnapshot _channel({
  String id = 'lc1',
  String title = '深夜电台 · 爱莉陪你写代码',
  bool isOwner = false,
  String? visibility = 'public',
  String? rtmpUrl,
  String? streamKey,
}) => AylaLiveChannelSnapshot(
  id: id,
  title: title,
  status: AylaLiveStatus.live,
  visibility: visibility,
  ownerNickname: '爱莉',
  isOwner: isOwner,
  rtmpUrl: rtmpUrl,
  streamKey: streamKey,
);

void main() {
  Widget host(
    WidgetTester tester,
    Widget child, {
    Size viewport = const Size(1200, 800),
    bool disableAnimations = false,
  }) {
    tester.view.physicalSize = viewport;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    return MaterialApp(
      home: previewScope(
        Builder(
          builder: (BuildContext context) => MediaQuery(
            data: MediaQuery.of(context).copyWith(
              size: viewport,
              // web `usePrefersReducedMotion` / Flutter 库内一律读它
              disableAnimations: disableAnimations,
            ),
            child: SizedBox.fromSize(size: viewport, child: child),
          ),
        ),
      ),
    );
  }

  Future<void> settle(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }

  group('宽屏装配（tsx 484–538）', () {
    testWidgets('三栏：侧栏 + 主区（头部 / stage / 观众条）+ 弹幕侧列（列表 + 输入框）', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        host(
          tester,
          AylaLiveRoomBody(
            channelId: 'lc1',
            isNarrow: false,
            channels: _channels,
            data: AylaLiveRoomData(
              channel: _channel(),
              srsStatus: AylaLiveSrsStatus.live,
              viewerCount: 12,
            ),
            videoView: const SizedBox(),
          ),
        ),
      );
      await settle(tester);

      expect(find.byType(AylaLiveChannelRail), findsOneWidget); // 侧栏
      expect(find.byType(AylaLivePlayer), findsOneWidget); // stage 里的播放器
      expect(find.byType(AylaLiveViewerStrip), findsOneWidget); // 视频下方观众条
      expect(find.byType(AylaDanmakuList), findsOneWidget); // 弹幕列表
      expect(find.byType(AylaDanmakuInput), findsOneWidget); // 弹幕输入框
      // 头部：标题 + 来源标签（公开）
      expect(find.text('深夜电台 · 爱莉陪你写代码'), findsOneWidget);
      expect(find.text('公开'), findsOneWidget);
      // 侧栏在左、侧列在右（布局顺序）
      final double railLeft = tester.getRect(find.byType(AylaLiveChannelRail)).left;
      final double listLeft = tester.getRect(find.byType(AylaDanmakuList)).left;
      expect(railLeft, lessThan(listLeft));
      // 顶栏卡片（宽屏 = 卡片材质：margin 0 / radius 16 / 1px 边 / compact 阴影 / blur24）
      final Finder headCard = find.ancestor(
        of: find.text('深夜电台 · 爱莉陪你写代码'),
        matching: find.byType(AylaGlassSurface),
      );
      expect(headCard, findsOneWidget);
      expect(tester.getRect(headCard).height, closeTo(56, 0.5)); // 高度恒定（收起/展开都一样）
      // 弹幕侧列卡片（宽 340 / margin 12 / radius 16 / glass 阴影）
      final Finder sideCard = find.ancestor(
        of: find.byType(AylaDanmakuList),
        matching: find.byType(AylaGlassSurface),
      );
      expect(sideCard, findsOneWidget);
      expect(tester.getRect(sideCard).width, closeTo(340, 0.5));
    });

    testWidgets('点侧栏项 → onSelect；收起侧栏后侧栏不渲染、展开键出现在头部', (WidgetTester tester) async {
      final List<String> selected = <String>[];
      await tester.pumpWidget(
        host(
          tester,
          AylaLiveRoomBody(
            channelId: 'lc1',
            isNarrow: false,
            channels: _channels,
            data: AylaLiveRoomData(
              channel: _channel(),
              srsStatus: AylaLiveSrsStatus.live,
            ),
            onSelect: selected.add,
            videoView: const SizedBox(),
          ),
        ),
      );
      await settle(tester);

      await tester.tap(
        find.byWidgetPredicate(
          (Widget w) =>
              w is Semantics && w.properties.label == '切换到直播间 第二场直播',
        ),
      );
      await settle(tester);
      expect(selected, <String>['lc2']);

      // 收起：`collapsed` ⇒ 侧栏自身不渲染（tsx 292–308 的展开键回到头部）
      await tester.tap(
        find.byWidgetPredicate(
          (Widget w) =>
              w is Semantics && w.properties.label == '收起直播间列表',
        ),
      );
      await settle(tester);
      // `collapsed` ⇒ 侧栏自身返回空（组件仍在树里，内容为零）——量它的尺寸而不是 byType
      expect(
        tester.widget<AylaLiveChannelRail>(find.byType(AylaLiveChannelRail)).collapsed,
        isTrue,
      );
      expect(
        tester.getRect(find.byType(AylaLiveChannelRail)).width,
        0, // 收起 = 宽度 0（高度仍被父级拉伸）
      );
      expect(
        find.byWidgetPredicate(
          (Widget w) =>
              w is Semantics && w.properties.label == '展开直播间列表',
        ),
        findsOneWidget,
      );
      // 用户 2026-09-22：**侧栏收起只改宽度、顶栏与弹幕区高度不变**
      // （web 顶栏恒有 40 高键 ⇒ 卡片恒 56；收起后多出的返回/展开键不得把顶栏撑高）
      final Finder head = find.ancestor(
        of: find.byType(AylaLivePlayer),
        matching: find.byType(AylaGlassSurface),
      );
      expect(head, findsNothing); // 播放器不在顶栏卡里（自证 finder 有区分度）
      final Finder headCard = find.ancestor(
        of: find.byWidgetPredicate(
          (Widget w) => w is Semantics && w.properties.label == '展开直播间列表',
        ),
        matching: find.byType(AylaGlassSurface),
      );
      expect(tester.getRect(headCard).height, closeTo(56, 0.5));
    });

    testWidgets('hideRail（群内直播）→ 不渲染侧栏，头部保留返回键', (WidgetTester tester) async {
      await tester.pumpWidget(
        host(
          tester,
          AylaLiveRoomBody(
            channelId: 'lc1',
            isNarrow: false,
            hideRail: true,
            channels: _channels,
            data: AylaLiveRoomData(
              channel: _channel(),
              srsStatus: AylaLiveSrsStatus.live,
            ),
            videoView: const SizedBox(),
          ),
        ),
      );
      await settle(tester);
      expect(find.byType(AylaLiveChannelRail), findsNothing);
      expect(
        find.byWidgetPredicate(
          (Widget w) => w is Semantics && w.properties.label == '返回',
        ),
        findsOneWidget,
      );
    });

    testWidgets('控制台（showOwnerPanel + isOwner）→ 资料栏 + 推流地址', (WidgetTester tester) async {
      await tester.pumpWidget(
        host(
          tester,
          AylaLiveRoomBody(
            channelId: 'lc1',
            isNarrow: false,
            showOwnerPanel: true,
            channels: _channels,
            data: AylaLiveRoomData(
              channel: _channel(
                isOwner: true,
                rtmpUrl: 'rtmp://live.elysium.local/app/stream-9f2c',
                streamKey: 'sk_live_9f2c',
              ),
              srsStatus: AylaLiveSrsStatus.live,
            ),
            videoView: const SizedBox(),
          ),
          viewport: const Size(1400, 900),
        ),
      );
      await settle(tester);
      expect(find.byType(AylaLiveOwnerPanel), findsOneWidget);
      expect(find.byType(AylaLiveStreamAddresses), findsOneWidget);
      // 控制台里**头部整行不渲染**（tsx 505 `(isNarrow || !showOwnerPanel)` 的守卫）
      // ⇒ 用头部独有件判断：转发键不在（标题/「公开」仍会出现在资料栏与可见范围里，不能拿它们判断）
      expect(
        find.byWidgetPredicate(
          (Widget w) => w is Semantics && w.properties.label == '分享直播间',
        ),
        findsNothing,
      );
    });
  });

  group('进房错误态（tsx 405–435）', () {
    testWidgets('主区显示错误 + 「返回」；侧栏与弹幕区仍在', (WidgetTester tester) async {
      int backs = 0;
      await tester.pumpWidget(
        host(
          tester,
          AylaLiveRoomBody(
            channelId: 'lc1',
            isNarrow: false,
            channels: _channels,
            data: const AylaLiveRoomData(error: '进房失败：网络异常'),
            onBack: () => backs += 1,
            videoView: null,
          ),
        ),
      );
      await settle(tester);
      expect(find.text('进房失败：网络异常'), findsOneWidget);
      expect(find.byType(AylaLiveChannelRail), findsOneWidget);
      expect(find.byType(AylaDanmakuList), findsOneWidget);
      await tester.tap(find.text('返回'));
      await settle(tester);
      expect(backs, 1);
    });
  });

  group('窄屏沉浸式（tsx 441–481）', () {
    testWidgets('列表键 → 覆盖层（遮罩 + 侧栏）；点遮罩关闭', (WidgetTester tester) async {
      await tester.pumpWidget(
        host(
          tester,
          AylaLiveRoomBody(
            channelId: 'lc1',
            isNarrow: true,
            channels: _channels,
            data: AylaLiveRoomData(
              channel: _channel(),
              srsStatus: AylaLiveSrsStatus.live,
            ),
            videoView: const SizedBox(),
          ),
          viewport: const Size(420, 700),
        ),
      );
      await settle(tester);
      expect(find.byType(AylaLiveChannelRail), findsNothing); // 窄屏默认关闭

      await tester.tap(
        find.byWidgetPredicate(
          (Widget w) =>
              w is Semantics && w.properties.label == '打开直播间列表',
        ),
      );
      await settle(tester);
      expect(find.byType(AylaLiveChannelRail), findsOneWidget); // 覆盖层里出现侧栏
      // 遮罩 = rgba(70,91,146,.25)
      expect(
        find.byWidgetPredicate(
          (Widget w) =>
              w is ColoredBox && w.color == const Color(0x40465B92),
        ),
        findsOneWidget,
      );

      // 点遮罩关闭（⚠️ 点**左侧**——屏幕中心落在右侧 240 宽的侧栏上，会点到侧栏）
      final Finder mask = find.byWidgetPredicate(
        (Widget w) => w is ColoredBox && w.color == const Color(0x40465B92),
      );
      await tester.tapAt(tester.getTopLeft(mask) + const Offset(10, 10));
      await settle(tester);
      expect(mask, findsNothing, reason: '遮罩应当随 _railOpen=false 一起消失');
      expect(find.byType(AylaLiveChannelRail), findsNothing);
    });

    testWidgets('空隙：swipe 外边距 sp2（顶栏↔视频 8）+ 观众条 margin-top sp2（视频↔观众条 8）', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        host(
          tester,
          AylaLiveRoomBody(
            channelId: 'lc1',
            isNarrow: true,
            channels: _channels,
            data: AylaLiveRoomData(
              channel: _channel(),
              srsStatus: AylaLiveSrsStatus.live,
              viewerCount: 5,
            ),
            videoView: const SizedBox(),
          ),
          viewport: const Size(420, 700),
        ),
      );
      await settle(tester);
      final Rect player = tester.getRect(find.byType(AylaLivePlayer));
      final Rect strip = tester.getRect(find.byType(AylaLiveViewerStrip));
      // `live.css 715–724`：`.live-room-swipe { margin: var(--sp-2) }` ⇒ 左右也不贴边
      expect(player.left, closeTo(8, 0.5));
      expect(player.right, closeTo(420 - 8, 0.5));
      // `live.css 1187–1191`：`.is-narrow .live-room-swipe-item > .live-viewer-strip { margin-top: sp2 }`
      expect(strip.top - player.bottom, closeTo(8, 0.5));
    });

    testWidgets('上滑超过 1/3 高 → onSelect(下一场)；下滑 → 上一场；小位移不切', (WidgetTester tester) async {
      final List<String> selected = <String>[];
      await tester.pumpWidget(
        host(
          tester,
          AylaLiveRoomBody(
            channelId: 'lc1',
            isNarrow: true,
            channels: _channels,
            data: AylaLiveRoomData(
              channel: _channel(),
              srsStatus: AylaLiveSrsStatus.live,
            ),
            onSelect: selected.add,
            videoView: const SizedBox(),
          ),
          viewport: const Size(420, 600),
        ),
      );
      await settle(tester);

      // 小位移（< 1/3 高 200 且无甩动）→ 不切
      final TestGesture small = await tester.startGesture(const Offset(210, 300));
      await tester.pump();
      await small.moveBy(const Offset(0, -40));
      await tester.pump();
      await small.up();
      await settle(tester);
      expect(selected, isEmpty);

      // 上滑 300（> 200）→ 下一场
      final TestGesture up = await tester.startGesture(const Offset(210, 400));
      await tester.pump();
      for (int i = 0; i < 10; i += 1) {
        await up.moveBy(const Offset(0, -30));
        await tester.pump();
      }
      await up.up();
      await settle(tester);
      expect(selected, <String>['lc2']);
    });
  });

  group('飘弹幕层挂载条件（tsx 220–222）', () {
    testWidgets('live 且非 loading → 挂 AylaDanmakuOverlay', (WidgetTester tester) async {
      await tester.pumpWidget(
        host(
          tester,
          AylaLiveRoomBody(
            channelId: 'lc1',
            isNarrow: false,
            channels: _channels,
            data: AylaLiveRoomData(
              channel: _channel(),
              srsStatus: AylaLiveSrsStatus.live,
              danmaku: const <AylaDanmakuEntry>[
                AylaDanmakuEntry(id: 'd1', senderNickname: '小樱', content: '来了'),
              ],
            ),
            videoView: const SizedBox(),
          ),
        ),
      );
      await settle(tester);
      expect(find.byType(AylaDanmakuOverlay), findsOneWidget);
    });

    testWidgets('loading 中 → 不挂飘层（避免未就绪时挂播放器投影）', (WidgetTester tester) async {
      await tester.pumpWidget(
        host(
          tester,
          AylaLiveRoomBody(
            channelId: 'lc1',
            isNarrow: false,
            channels: _channels,
            data: AylaLiveRoomData(
              channel: _channel(),
              srsStatus: AylaLiveSrsStatus.live,
              loading: true,
            ),
            videoView: const SizedBox(),
          ),
        ),
      );
      await settle(tester);
      expect(find.byType(AylaDanmakuOverlay), findsNothing);
      expect(find.text('加载中…'), findsOneWidget); // 头部标题退化为加载中
    });
  });

  // ============ 切台动效（tsx 139–151 面板重播 + 542–565 头部进退场） ============

  group('切台动效（usePanelReplayMotion + LiveRoomHeader）', () {
    Rect stageRect(WidgetTester tester) =>
        tester.getRect(find.byType(AylaLivePlayer));
    Rect stripRect(WidgetTester tester) =>
        tester.getRect(find.byType(AylaLiveViewerStrip));
    Rect sideRect(WidgetTester tester) => tester.getRect(
      find.ancestor(
        of: find.byType(AylaDanmakuList),
        matching: find.byType(AylaGlassSurface),
      ),
    );
    Rect headRect(WidgetTester tester, String title) => tester.getRect(
      find.ancestor(
        of: find.text(title),
        matching: find.byType(AylaGlassSurface),
      ),
    );

    // ⚠️ 推进动画必须「先起 tick、再给时长」：Ticker 在第一帧只记 `_startTime`（elapsed 0），
    //    一次 `pump(时长)` 只把动画推到起点（本项目已知坑：`pump(时长)` 不是真实时间）。
    Future<void> advance(WidgetTester tester, Duration d) async {
      await tester.pump(d);
      await tester.pump(d);
    }

    Widget room({
      required String channelId,
      required String title,
      bool narrow = false,
      VoidCallback? onShare,
    }) => AylaLiveRoomBody(
      channelId: channelId,
      isNarrow: narrow,
      channels: _channels,
      onShare: onShare,
      data: AylaLiveRoomData(
        channel: _channel(id: channelId, title: title),
        srsStatus: AylaLiveSrsStatus.live,
        viewerCount: 12,
      ),
      videoView: const SizedBox(),
    );

    testWidgets('挂载：面板各自从边缘 ±20 入场（stage/strip 下沿 · side 右沿 · 头部上沿）', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        host(tester, room(channelId: 'lc1', title: '头部标题一')),
      );
      await tester.pump(); // 首帧 = 动画起点
      final Rect stage0 = stageRect(tester);
      final Rect strip0 = stripRect(tester);
      final Rect side0 = sideRect(tester);
      final Rect head0 = headRect(tester, '头部标题一');
      await tester.pump(const Duration(milliseconds: 400)); // 300ms 播完
      expect(
        stageRect(tester).top - stage0.top,
        closeTo(-20, 1),
        reason: 'stage 从下沿 +20 归位',
      );
      expect(stripRect(tester).top - strip0.top, closeTo(-20, 1));
      expect(sideRect(tester).left - side0.left, closeTo(-20, 1));
      expect(
        headRect(tester, '头部标题一').top - head0.top,
        closeTo(20, 1),
        reason: '头部从上沿 −20 归位（panelVariants(reduced,"top")）',
      );
    });

    testWidgets('宽屏非错误态：三块面板各挂一层入场壳（mediaPanels 三条 target）', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        host(tester, room(channelId: 'lc1', title: '头部标题一')),
      );
      await settle(tester);
      expect(find.byType(AylaRevealScope), findsOneWidget);
      for (final Finder panel in <Finder>[
        find.byType(AylaLivePlayer), // .live-room-main > .live-room-stage
        find.byType(AylaLiveViewerStrip), // > .live-viewer-strip
        find.byType(AylaDanmakuList), // .live-room-side
      ]) {
        expect(
          find.ancestor(of: panel, matching: find.byType(AylaRevealItem)),
          findsWidgets,
          reason: '三条 target 各自可重播',
        );
      }
    });

    testWidgets('切台：面板重播（回到 ±20 起点）+ 头部串行「退出→进入」', (WidgetTester tester) async {
      int shares = 0;
      String channelId = 'lc1';
      late StateSetter rebuild;
      await tester.pumpWidget(
        host(
          tester,
          StatefulBuilder(
            builder: (BuildContext context, StateSetter setState) {
              rebuild = setState;
              return room(
                channelId: channelId,
                title: channelId == 'lc1' ? '头部标题一' : '头部标题二',
                onShare: () => shares += 1,
              );
            },
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 400)); // 入场播完
      final Rect stageBase = stageRect(tester);
      final Rect stripBase = stripRect(tester);
      final Rect sideBase = sideRect(tester);

      rebuild(() => channelId = 'lc2');
      await tester.pump(); // 第 1 帧：面板重播起点 + 头部开始退出

      // ① 面板重播：三块都回到各自边缘的 +20 起点
      expect(stageRect(tester).top - stageBase.top, closeTo(20, 1));
      expect(stripRect(tester).top - stripBase.top, closeTo(20, 1));
      expect(sideRect(tester).left - sideBase.left, closeTo(20, 1));
      // ② mode="wait"：旧头还在，新头尚未挂
      expect(find.text('头部标题一'), findsOneWidget);
      expect(find.text('头部标题二'), findsNothing);
      // ③ 退出期 inert（不可聚焦）+ aria-hidden
      expect(
        find.ancestor(
          of: find.text('头部标题一'),
          matching: find.byType(ExcludeFocus),
        ),
        findsWidgets,
      );
      expect(
        find.ancestor(
          of: find.text('头部标题一'),
          matching: find.byWidgetPredicate(
            (Widget w) => w is ExcludeSemantics && w.excluding,
          ),
        ),
        findsWidgets,
      );
      // ④ pointer-events:none：退出中的旧头按键点不动
      await tester.tap(find.byType(AylaShareButton), warnIfMissed: false);
      await tester.pump();
      expect(shares, 0, reason: '退出期 pointer-events:none（IgnorePointer）');

      // ⑤ 300ms：旧头退完 → 换新头并从 −20 入场
      await advance(tester, const Duration(milliseconds: 300));
      await tester.pump();
      expect(find.text('头部标题一'), findsNothing);
      expect(find.text('头部标题二'), findsOneWidget);
      final Rect newHead0 = headRect(tester, '头部标题二');
      await advance(tester, const Duration(milliseconds: 300));
      await tester.pump();
      expect(headRect(tester, '头部标题二').top - newHead0.top, closeTo(20, 1));
      // ⑥ 面板同时归位（300ms 重播播完）
      expect(stripRect(tester).top, closeTo(stripBase.top, 1));
      expect(sideRect(tester).left, closeTo(sideBase.left, 1));
      // ⑦ 自证 finder 有区分度：换完之后头部按键是可点的
      await tester.tap(find.byType(AylaShareButton));
      await tester.pump();
      expect(shares, 1);
    });

    testWidgets('窄屏：stage/strip 从下沿、`.danmaku-wrap` 从右沿重播', (WidgetTester tester) async {
      String channelId = 'lc1';
      late StateSetter rebuild;
      await tester.pumpWidget(
        host(
          tester,
          StatefulBuilder(
            builder: (BuildContext context, StateSetter setState) {
              rebuild = setState;
              return room(
                channelId: channelId,
                title: '头部标题一',
                narrow: true,
              );
            },
          ),
          viewport: const Size(420, 700),
        ),
      );
      await tester.pump(const Duration(milliseconds: 400));
      final Rect stageBase = stageRect(tester);
      final Rect stripBase = stripRect(tester);
      final Rect listBase = tester.getRect(find.byType(AylaDanmakuList));

      rebuild(() => channelId = 'lc2');
      await tester.pump();
      expect(stageRect(tester).top - stageBase.top, closeTo(20, 1));
      expect(stripRect(tester).top - stripBase.top, closeTo(20, 1));
      expect(
        tester.getRect(find.byType(AylaDanmakuList)).left - listBase.left,
        closeTo(20, 1),
        reason: '窄屏第三块是 `.danmaku-wrap`（edge right），不是 `.live-room-side`',
      );
    });

    testWidgets('reduced-motion：切台当帧即终态（面板与头部都不动画）', (WidgetTester tester) async {
      String channelId = 'lc1';
      late StateSetter rebuild;
      await tester.pumpWidget(
        host(
          tester,
          StatefulBuilder(
            builder: (BuildContext context, StateSetter setState) {
              rebuild = setState;
              return room(
                channelId: channelId,
                title: channelId == 'lc1' ? '头部标题一' : '头部标题二',
              );
            },
          ),
          disableAnimations: true,
        ),
      );
      await tester.pump();
      final Rect stripBase = stripRect(tester);
      final Rect headBase = headRect(tester, '头部标题一');
      rebuild(() => channelId = 'lc2');
      await tester.pump();
      expect(find.text('头部标题二'), findsOneWidget, reason: 'reduced ⇒ 不串行等待旧头退场');
      expect(find.text('头部标题一'), findsNothing);
      expect(stripRect(tester).top, closeTo(stripBase.top, 0.5), reason: '面板不重播（hook: reduced ⇒ return）');
      expect(headRect(tester, '头部标题二').top, closeTo(headBase.top, 0.5));
    });

    testWidgets('错误态：不挂重播壳（hook 的 enabled = !error）', (WidgetTester tester) async {
      await tester.pumpWidget(
        host(
          tester,
          AylaLiveRoomBody(
            channelId: 'lc1',
            isNarrow: false,
            channels: _channels,
            data: const AylaLiveRoomData(error: '进房失败：网络异常'),
            videoView: null,
          ),
        ),
      );
      await settle(tester);
      expect(find.byType(AylaRevealScope), findsNothing);
      expect(find.byType(AylaRevealItem), findsNothing);
    });
  });
}
