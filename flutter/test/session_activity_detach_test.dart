/// 「悬浮球脱离应用」（语音 / 直播会话浮层 → 系统层悬浮球）的回归锁。
///
/// 用户要求：「手机电脑语音直播浮层悬浮球（默认在右上角的那个）也要脱离应用」。
/// 契约在 `lib/core/platform/detached_live.dart`（Lead 持有），本文件测的是**接线**：
/// 组件层只做参数注入、壳层宿主负责通道调用与事件路由。
///
/// ## 覆盖
/// 组件层（`AylaSessionActivityIndicator`，**不碰任何平台通道**）：
/// ① 不传 `onDetach` ⇒ 不渲染脱离键（视觉与旧版完全一致，历史用例的前提）；
/// ② 传 `onDetach` ⇒ 出现脱离键；点它回调**被注入的**回调，且带**直播优先**的会话；
/// ③ 只有语音会话时回落语音；④ `detached` 只翻高亮语义（「取消脱离应用」），几何不变；
/// ⑤ 两个会话都 null ⇒ 整组零渲染（含脱离键）。
///
/// 壳层事件路由（`AylaDetachedLiveEvents`）：
/// ⑥ `onBallTap` 事件（走 `debugEmit`，**不真调通道**）被解析成 `ballTap` 且
///    `sourceRoute` / `sessionKind` 正确 —— 这是「离开 App 后点球回房」的数据面；
/// ⑦ `ballClosed` 事件可被解析（壳层据此复位「已脱离」）。
///
/// ⚠️ 真实压到系统层（Android 叠加窗 / Windows 置顶窗）**不在单元测试可证范围内**：
/// 那需要真机授权 + 真窗口，见交付说明里的「未验证」清单。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../lib/core/platform/detached_live.dart';
import '../lib/state/session_activity_state.dart';
import '../lib/theme/app_theme.dart';
import '../lib/widgets/shell/session_activity.dart';

const AylaActivitySession _voice = AylaActivitySession(
  sessionId: '5',
  sourceRoute: '/voice/5',
  title: '语音房',
);

const AylaActivitySession _live = AylaActivitySession(
  sessionId: '9',
  sourceRoute: '/live/start/9',
  title: '直播间',
  kind: AylaActivityKind.live,
);

/// 组件返回 [Positioned]（等价 web 的 `position: fixed`）⇒ 必须放在 `Stack` 里。
Future<void> _pumpIndicator(
  WidgetTester tester, {
  AylaActivitySession? voice,
  AylaActivitySession? live,
  ValueChanged<AylaActivitySession>? onDetach,
  bool detached = false,
}) async {
  tester.view.physicalSize = const Size(1200, 800);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      theme: buildAylaTheme(),
      home: Scaffold(
        body: Stack(
          children: <Widget>[
            AylaSessionActivityIndicator(
              voice: voice,
              live: live,
              onDetach: onDetach,
              detached: detached,
            ),
          ],
        ),
      ),
    ),
  );
  await tester.pump(const Duration(milliseconds: 300));
}

void main() {
  group('组件层：脱离键是纯参数注入', () {
    testWidgets('① 不传 onDetach ⇒ 不渲染脱离键（历史视觉/用例前提）',
        (WidgetTester tester) async {
      await _pumpIndicator(tester, voice: _voice, live: _live);

      expect(
        find.byKey(AylaSessionActivityIndicator.detachKey),
        findsNothing,
        reason: '未接线时不能凭空多出一个键（平台不支持的 iOS/Web 也走这条）',
      );
      // 两个球仍在（旧行为不受影响）。
      expect(find.text('›'), findsOneWidget);
    });

    testWidgets('② 传 onDetach ⇒ 出现脱离键，点击回传**直播**会话（两球并存时以直播为准）',
        (WidgetTester tester) async {
      final List<AylaActivitySession> detached = <AylaActivitySession>[];
      await _pumpIndicator(
        tester,
        voice: _voice,
        live: _live,
        onDetach: detached.add,
      );

      final Finder key = find.byKey(AylaSessionActivityIndicator.detachKey);
      expect(key, findsOneWidget);
      expect(
        tester.getSize(key),
        const Size(
          AylaSessionActivityIndicator.detachWidth,
          AylaSessionActivityIndicator.detachHeight,
        ),
        reason: '与把手同一 28×44 规格（不改既有视觉规格）',
      );

      await tester.tap(key);
      await tester.pump();

      expect(detached.length, 1);
      expect(
        detached.single.sessionId,
        '9',
        reason: '视频脱离是这条需求的主场景 ⇒ 两球并存时以直播为准',
      );
      expect(detached.single.kind, AylaActivityKind.live);
    });

    testWidgets('③ 只有语音会话 ⇒ 脱离键回传语音', (WidgetTester tester) async {
      final List<AylaActivitySession> detached = <AylaActivitySession>[];
      await _pumpIndicator(
        tester,
        voice: _voice,
        onDetach: detached.add,
      );

      await tester.tap(find.byKey(AylaSessionActivityIndicator.detachKey));
      await tester.pump();

      expect(detached.single.sessionId, '5');
      expect(detached.single.kind, AylaActivityKind.voice);
      expect(detached.single.sourceRoute, '/voice/5');
    });

    testWidgets('④ detached 只翻语义与配色，不改几何/位置', (WidgetTester tester) async {
      await _pumpIndicator(
        tester,
        live: _live,
        onDetach: (_) {},
      );
      final Rect before = tester.getRect(
        find.byKey(AylaSessionActivityIndicator.detachKey),
      );
      expect(
        tester.getSemantics(find.byKey(AylaSessionActivityIndicator.detachKey)),
        isNotNull,
      );

      await _pumpIndicator(
        tester,
        live: _live,
        onDetach: (_) {},
        detached: true,
      );
      final Rect after = tester.getRect(
        find.byKey(AylaSessionActivityIndicator.detachKey),
      );

      expect(
        after,
        before,
        reason: '键的几何在两个状态完全相同 —— 否则根 widget 类型变化会重建子树、'
            '把球的收起动画吃掉（文件头「脱离应用」一节）',
      );
      // 语义标签换档（可见文案不出现在界面上，只有可访问名）。
      expect(find.bySemanticsLabel('取消脱离应用'), findsOneWidget);
    });

    testWidgets('⑤ 两个会话都 null ⇒ 整组零渲染（含脱离键）', (WidgetTester tester) async {
      await _pumpIndicator(tester, onDetach: (_) {});

      expect(find.byKey(AylaSessionActivityIndicator.detachKey), findsNothing);
      expect(
        tester.getSize(find.byType(AylaSessionActivityIndicator)),
        Size.zero,
        reason: 'tsx 135：两球都无 ⇒ return null',
      );
    });
  });

  group('壳层事件路由（脱离后点球回房）', () {
    test('⑥ onBallTap 事件解析出 sourceRoute + kind', () async {
      final List<AylaDetachedLiveEvent> events = <AylaDetachedLiveEvent>[];
      final subscription = AylaDetachedLiveEvents.instance.stream.listen(events.add);
      addTearDown(subscription.cancel);

      AylaDetachedLiveEvents.instance
          .debugEmit(const AylaDetachedLiveEvent.ballTap(
        kind: 'live',
        sourceRoute: '/live/start/9',
      ));
      await Future<void>.delayed(Duration.zero);

      expect(events.length, 1);
      expect(events.single.kind, AylaDetachedLiveEventKind.ballTap);
      expect(events.single.sourceRoute, '/live/start/9');
      expect(events.single.sessionKind, 'live');
    });

    test('⑦ ballClosed 事件可被解析（壳层据此复位「已脱离」）', () async {
      final List<AylaDetachedLiveEvent> events = <AylaDetachedLiveEvent>[];
      final subscription = AylaDetachedLiveEvents.instance.stream.listen(events.add);
      addTearDown(subscription.cancel);

      AylaDetachedLiveEvents.instance
          .debugEmit(const AylaDetachedLiveEvent.ballClosed());
      await Future<void>.delayed(Duration.zero);

      expect(events.single.kind, AylaDetachedLiveEventKind.ballClosed);
    });
  });

  group('平台能力静态判断', () {
    test('⑧ 测试环境（无原生实现）下通道能力为 false，而不是抛异常', () async {
      // ① 单元测试跑在 `flutter_test` 的默认 `TargetPlatform.android` 上，
      //    但**没有任何原生实现** ⇒ `aylaShowDetachedBall` 必须走
      //    MissingPluginException 分支返回 unsupported（契约：不抛异常）。
      final result = await aylaShowDetachedBall(
        kind: 'live',
        sessionId: '9',
        title: '直播间',
        sourceRoute: '/live/start/9',
      );
      expect(
        result,
        AylaDetachedBallResult.unsupported,
        reason: '原生未实现时必须是明确降级，不能抛异常、也不能假装 shown',
      );
      // hide / openOverlaySettings 同理：静默安全。
      await aylaHideDetachedBall();
      expect(await aylaOpenOverlayPermissionSettings(), isFalse);
    });
  });
}
