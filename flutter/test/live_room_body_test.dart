/// B2-6：直播间装配（`LiveRoomBody.tsx` 566）定向测试。
///
/// 覆盖：宽屏三栏装配（侧栏 / 头部 / stage / 观众条 / 弹幕侧列）/ 侧栏收起与展开键 /
/// 进房错误态仍保留侧栏与弹幕区 / 窄屏沉浸式（列表覆盖层开关 + 上下滑切台）/ 控制台
/// （资料栏 + 推流地址，仅 owner）/ hideRail / 飘弹幕层仅在 live 且非 loading 时挂载。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../lib/theme/glass.dart' show GlassSurface;
import '../lib/theme/preview_theme.dart';
import '../lib/widgets/danmaku.dart'
    show AylaDanmakuEntry, AylaDanmakuInput, AylaDanmakuList, AylaDanmakuOverlay;
import '../lib/widgets/live_channel_snapshot.dart';
import '../lib/widgets/live_hall.dart' show AylaLiveCardData, AylaLiveStatus;
import '../lib/widgets/live_owner_panel.dart' show AylaLiveOwnerPanel;
import '../lib/widgets/live_player.dart' show AylaLivePlayer, AylaLiveSrsStatus;
import '../lib/widgets/live_rail.dart' show AylaLiveChannelRail;
import '../lib/widgets/live_room_body.dart';
import '../lib/widgets/live_studio.dart' show AylaLiveStreamAddresses;
import '../lib/widgets/live_viewers.dart' show AylaLiveViewerStrip;

const List<AylaLiveCardData> _channels = <AylaLiveCardData>[
  AylaLiveCardData(id: 'lc1', title: '第一场直播', status: AylaLiveStatus.live),
  AylaLiveCardData(id: 'lc2', title: '第二场直播', status: AylaLiveStatus.live),
];

AylaLiveChannelSnapshot _channel({
  bool isOwner = false,
  String? visibility = 'public',
  String? rtmpUrl,
  String? streamKey,
}) => AylaLiveChannelSnapshot(
  id: 'lc1',
  title: '深夜电台 · 爱莉陪你写代码',
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
  }) {
    tester.view.physicalSize = viewport;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    return MaterialApp(
      home: previewScope(
        Builder(
          builder: (BuildContext context) => MediaQuery(
            data: MediaQuery.of(context).copyWith(size: viewport),
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
        matching: find.byType(GlassSurface),
      );
      expect(headCard, findsOneWidget);
      expect(tester.getRect(headCard).height, closeTo(56, 0.5)); // 高度恒定（收起/展开都一样）
      // 弹幕侧列卡片（宽 340 / margin 12 / radius 16 / glass 阴影）
      final Finder sideCard = find.ancestor(
        of: find.byType(AylaDanmakuList),
        matching: find.byType(GlassSurface),
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
        matching: find.byType(GlassSurface),
      );
      expect(head, findsNothing); // 播放器不在顶栏卡里（自证 finder 有区分度）
      final Finder headCard = find.ancestor(
        of: find.byWidgetPredicate(
          (Widget w) => w is Semantics && w.properties.label == '展开直播间列表',
        ),
        matching: find.byType(GlassSurface),
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
}
