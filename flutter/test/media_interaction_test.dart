import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import '../lib/core/media/media_signer.dart';
import '../lib/core/net/dio_client.dart';
import '../lib/widgets/media_interaction.dart';
import '../lib/theme/preview_theme.dart';

void main() {
  group('dampPull 阻尼（对齐 tsx dampPull 46–49）', () {
    test('dy<=0 → 0', () {
      expect(dampPull(0), 0);
      expect(dampPull(-10), 0);
    });
    test('公式 = maxPull*(1-exp(-dy/dampFactor))', () {
      // dy=90（=dampFactor）→ 96*(1-e^-1) = 96*0.6321 = 60.68
      expect(dampPull(90), closeTo(96 * (1 - 0.36787944117), 0.001));
      // dy=64（默认 threshold）→ 96*(1-e^(-64/90)) = 96*0.50857 = 48.82
      final expected64 = 96 * (1 - math.exp(-64 / 90));
      expect(dampPull(64), closeTo(expected64, 0.001));
    });
    test('单调递增且渐近 maxPull（永不超上限）', () {
      double prev = -1;
      for (final dy in <double>[1, 10, 50, 100, 200, 500, 1000, 10000]) {
        final v = dampPull(dy);
        expect(v, greaterThan(prev), reason: 'dy=$dy 应递增');
        expect(v, lessThanOrEqualTo(96), reason: 'dy=$dy 不应超过 MAX_PULL');
        prev = v;
      }
    });
  });

  group('PullTracker 状态机（对齐 createPullTracker 57–100）', () {
    late double offset;
    late bool? endedWith;
    late int cancels;
    late bool atTop;

    PullTracker build({double threshold = 64}) => PullTracker(
          threshold: threshold,
          canPull: () => atTop,
          onOffsetChange: (v) => offset = v,
          onPullEnd: (r) => endedWith = r,
          onPullCancel: () => cancels++,
        );

    setUp(() {
      offset = -1;
      endedWith = null;
      cancels = 0;
      atTop = true;
    });

    test('不在顶部时 start 被忽略（方向锁）', () {
      atTop = false;
      final t = build();
      t.start(100);
      expect(t.isTracking, isFalse, reason: 'canPull=false 不应开始跟踪');
    });

    test('下拉 → 阻尼位移；上拉 → 0', () {
      final t = build();
      t.start(100);
      t.move(200); // dy=100
      expect(offset, closeTo(dampPull(100), 0.001));
      t.move(50); // dy=-50（上拉）
      expect(offset, 0);
    });

    test('达阈值松手 → onPullEnd(true)；不足 → false', () {
      final t = build(threshold: 64);
      t.start(0);
      t.move(100); // dy=100 ≥ 64
      t.end(100);
      expect(endedWith, isTrue, reason: '阈值判定用原始 dy（非阻尼值）');
    });

    test('不足阈值松手 → onPullEnd(false)（回弹）', () {
      final t = build(threshold: 64);
      t.start(0);
      t.move(30);
      t.end(30);
      expect(endedWith, isFalse);
    });

    test('移动中若容器不再在顶部 → 位移归零（放弃本次）', () {
      final t = build();
      t.start(0);
      t.move(80);
      expect(offset, greaterThan(0));
      atTop = false;
      t.move(120);
      expect(offset, 0, reason: '快速甩动/内容回弹时放弃下拉');
    });

    test('cancel → onPullCancel（不触发刷新）', () {
      final t = build();
      t.start(0);
      t.move(80);
      t.cancel();
      expect(cancels, 1);
      expect(endedWith, isNull, reason: '取消不应触发 onPullEnd');
      expect(t.isTracking, isFalse);
    });
  });

  group('AylaPullToRefresh 真实手势路径', () {
    testWidgets('下拉过阈值 → 触发 onRefresh → 完成后收起', (WidgetTester tester) async {
      int refreshCount = 0;
      await tester.pumpWidget(previewTheme(
        SizedBox(
          height: 400,
          child: AylaPullToRefresh(
            isAtTop: () => true,
            onRefresh: () async {
              refreshCount++;
              await Future<void>.delayed(const Duration(milliseconds: 50));
            },
            child: const SizedBox(height: 1000, child: Text('列表内容')),
          ),
        ),
      ));
      await tester.pump();

      // 真实手势：按下 → 移动（超过 threshold 64）→ 松开
      final gesture = await tester.startGesture(const Offset(200, 100));
      await tester.pump();
      await gesture.moveTo(const Offset(200, 200)); // dy=100 > 64
      await tester.pump();
      await gesture.up();
      await tester.pump(); // 进入 refreshing
      expect(refreshCount, 1, reason: '过阈值松手应触发刷新');

      // 等刷新完成 + done 停留 300ms + 收起
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('列表内容'), findsOneWidget);
    });

    testWidgets('不足阈值松手 → 不刷新（回弹）', (WidgetTester tester) async {
      int refreshCount = 0;
      await tester.pumpWidget(previewTheme(
        SizedBox(
          height: 400,
          child: AylaPullToRefresh(
            isAtTop: () => true,
            onRefresh: () async => refreshCount++,
            child: const SizedBox(height: 1000, child: Text('列表内容')),
          ),
        ),
      ));
      await tester.pump();

      final gesture = await tester.startGesture(const Offset(200, 100));
      await tester.pump();
      await gesture.moveTo(const Offset(200, 130)); // dy=30 < 64
      await tester.pump();
      await gesture.up();
      await tester.pump(const Duration(milliseconds: 300));
      expect(refreshCount, 0, reason: '不足阈值不应刷新');
    });

    testWidgets('不在顶部 → 下拉不触发（方向锁）', (WidgetTester tester) async {
      int refreshCount = 0;
      await tester.pumpWidget(previewTheme(
        SizedBox(
          height: 400,
          child: AylaPullToRefresh(
            isAtTop: () => false, // 模拟滚动容器不在顶部
            onRefresh: () async => refreshCount++,
            child: const SizedBox(height: 1000, child: Text('列表内容')),
          ),
        ),
      ));
      await tester.pump();
      final gesture = await tester.startGesture(const Offset(200, 100));
      await tester.pump();
      await gesture.moveTo(const Offset(200, 250));
      await tester.pump();
      await gesture.up();
      await tester.pump(const Duration(milliseconds: 400));
      expect(refreshCount, 0, reason: 'canPull=false 时不应响应下拉');
    });

    testWidgets('disabled → 下拉不触发', (WidgetTester tester) async {
      int refreshCount = 0;
      await tester.pumpWidget(previewTheme(
        SizedBox(
          height: 400,
          child: AylaPullToRefresh(
            disabled: true,
            isAtTop: () => true,
            onRefresh: () async => refreshCount++,
            child: const SizedBox(height: 1000, child: Text('列表内容')),
          ),
        ),
      ));
      await tester.pump();
      final gesture = await tester.startGesture(const Offset(200, 100));
      await tester.pump();
      await gesture.moveTo(const Offset(200, 250));
      await tester.pump();
      await gesture.up();
      await tester.pump(const Duration(milliseconds: 400));
      expect(refreshCount, 0);
    });
  });

  group('SignedVideo 状态机', () {
    setUp(() => MediaSigner.instance.detach()); // 隔离：还原为未注入态
    tearDown(() => MediaSigner.instance.detach());

    testWidgets('签发进行中 → 显示「视频加载中」骨架（注入挂起的 client）',
        (WidgetTester tester) async {
      // 用永不完成的 client 让 signing 停在 inflight → loading 帧可见
      MediaSigner.instance.attach(_PendingClient());
      await tester.pumpWidget(previewTheme(
        const SizedBox(
          width: 300, height: 200,
          child: SignedVideo(mediaId: 'v-pending'),
        ),
      ));
      await tester.pump();
      expect(find.bySemanticsLabel('视频加载中'), findsOneWidget,
          reason: '签发 inflight 期间应显示 loading 骨架');
      // 收尾：dispose 挂起的 Future（测试结束不等待）
    });

    testWidgets('无 client → 失败态 + 重试按钮', (WidgetTester tester) async {
      await tester.pumpWidget(previewTheme(
        const SizedBox(
          width: 300, height: 200,
          child: SignedVideo(mediaId: 'v1'),
        ),
      ));
      await tester.pump(); // 触发 _sign
      await tester.pump();
      // MediaSigner 未注入 → 异常 → failed 态
      expect(find.text('视频加载失败，点击重试'), findsOneWidget);
    });

    testWidgets('失败后点重试 → 重新签发（走真实重试路径）', (WidgetTester tester) async {
      await tester.pumpWidget(previewTheme(
        const SizedBox(
          width: 300, height: 200,
          child: SignedVideo(mediaId: 'v3'),
        ),
      ));
      await tester.pump();
      await tester.pump();
      expect(find.text('视频加载失败，点击重试'), findsOneWidget);
      // 点重试 → 重新签发。注意：未注入 client 时 `_sign()` **同步抛错**
      // （无 await 点），loading 帧不会渲染——这是刻意的 fail-fast，
      // 故这里断言「重试后仍为失败态且提示保留」，而非中间 loading 帧。
      await tester.tap(find.text('视频加载失败，点击重试'));
      await tester.pump();
      await tester.pump();
      expect(find.text('视频加载失败，点击重试'), findsOneWidget,
          reason: '重试后仍失败（client 未注入）→ 不伪造成功');
    });
  });

  // ===== 回归：条件表达式 int 传给 double 参数（运行时 TypeError，analyzer 不报）=====
  // `? 1 : 0` 的类型是 int，不会自动提升为 double；曾导致
  // `TypeError: type 'double' is not a subtype of type 'bool?'` 崩溃。
  group('数字类型回归（int/double）', () {
    testWidgets('PullToRefresh 指示器 opacity 全路径不崩', (WidgetTester tester) async {
      await tester.pumpWidget(previewTheme(
        SizedBox(
          height: 300,
          child: AylaPullToRefresh(
            isAtTop: () => true,
            onRefresh: () async {},
            child: const SizedBox(height: 800, child: Text('x')),
          ),
        ),
      ));
      await tester.pump();
      final g = await tester.startGesture(const Offset(200, 100));
      await tester.pump();
      await g.moveTo(const Offset(200, 180)); // 触发 pulling（opacity 0→1）
      await tester.pump();
      expect(tester.takeException(), isNull);
      await g.up();
      await tester.pump(const Duration(milliseconds: 400));
      expect(tester.takeException(), isNull);
    });
  });
}

/// 永不完成的假 client（让 signing 停在 inflight，用于验证 loading 帧）。
class _PendingClient implements DioClient {
  @override
  Future<T> post<T>(String path, {Object? body, Map<String, dynamic>? query}) {
    return Completer<T>().future; // 永不 settle
  }

  @override
  noSuchMethod(Invocation i) => throw UnimplementedError('${i.memberName}');
}
