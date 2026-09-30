/// 回归锁（2026-09-30，第十三批）：**时间切片挂载 + 批次时间原点**。
///
/// 用户实机判断「最后一帧突然出现太多卡」已被量化证实
/// （`test/tmp_mount_frame_probe_test.dart`：一帧挂载 20 张玻璃卡 = UI 线程 282ms；
/// 分 5 帧 ⇒ 单帧最大 72ms）。但用户同时要求「**最好不要与 web 的视觉效果有区别**」
/// ⇒ 分帧必须**零视觉差异**：
/// web 的 `.reveal-item` 用 CSS `animation-delay`，而**所有卡是同一帧拿到那个类的**
/// （共享同一时间原点）；Flutter 侧若只是把挂载分帧，后挂载的项会晚几帧开始计时
/// ⇒ 动画时机整体后移。本锁验证 [AylaRevealScopeState.noteBatchMember] 的**追赶**：
/// 分帧与同帧全挂，在**同一时刻**的动画进度必须一致。
///
/// 跑法：`flutter test test/reveal_chunked_test.dart --concurrency 1`
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../lib/theme/app_theme.dart';
import '../lib/theme/aurora_background.dart';
import '../lib/widgets/base/reveal.dart'
    show AylaChunkedChildren, AylaRevealItem, AylaRevealScope;

void main() {
  Widget item(int i) => KeyedSubtree(
        key: ValueKey<String>('item$i'),
        // ⚠️ 用非玻璃档（默认 `fadeGlass: true`）：玻璃档在进度 0 时会用
        // `kAylaInvisibleButPainted` 的 alpha（≈0.001）⇒ 读到的不是动画进度。
        child: AylaRevealItem(
          index: i,
          child: SizedBox(width: 80, height: 30, child: Text('$i')),
        ),
      );

  Widget host({required bool chunked, int perFrame = 1, int count = 4}) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: buildAylaTheme(),
      home: AylaAuroraBackground(
        animate: false,
        child: AylaRevealScope(
          child: chunked
              ? AylaChunkedChildren(
                  itemCount: count,
                  perFrame: perFrame,
                  layout: (List<Widget> children) =>
                      Column(mainAxisSize: MainAxisSize.min, children: children),
                  builder: (BuildContext c, int i) => item(i),
                )
              : Column(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[for (int i = 0; i < count; i += 1) item(i)],
                ),
        ),
      ),
    );
  }

  /// 读第 i 项当前的整层 opacity（= 入场进度）。
  double progressOf(WidgetTester tester, int i) {
    final Finder f = find.descendant(
      of: find.byKey(ValueKey<String>('item$i')),
      matching: find.byType(Opacity),
    );
    if (f.evaluate().isEmpty) return -1; // 还没挂载
    return tester.widget<Opacity>(f.first).opacity;
  }

  testWidgets('时间切片：每帧只新增 perFrame 个单元', (WidgetTester tester) async {
    await tester.pumpWidget(host(chunked: true, perFrame: 1, count: 4));
    // 首帧：只有 item0（其余还没挂载 ⇒ 那一帧不用为它们付 build/layout 成本）。
    expect(find.byKey(const ValueKey<String>('item0')), findsOneWidget);
    expect(find.byKey(const ValueKey<String>('item1')), findsNothing);
    await tester.pump(const Duration(milliseconds: 16));
    expect(find.byKey(const ValueKey<String>('item1')), findsOneWidget);
    expect(find.byKey(const ValueKey<String>('item3')), findsNothing);
    await tester.pump(const Duration(milliseconds: 16));
    await tester.pump(const Duration(milliseconds: 16));
    expect(find.byKey(const ValueKey<String>('item3')), findsOneWidget);
  });

  /// 步进推进到 [totalMs]（单次 `pump(大时长)` 只跑一帧：既触发不了 delay Timer，
  /// 也推不动已开始的动画 ⇒ 必须小步走）。
  Future<double> progressAt(
    WidgetTester tester, {
    required bool chunked,
    required int totalMs,
  }) async {
    await tester.pumpWidget(host(chunked: chunked, perFrame: 1));
    await tester.pump();
    int elapsed = 0;
    while (elapsed < totalMs) {
      await tester.pump(const Duration(milliseconds: 16));
      elapsed += 16;
    }
    return progressOf(tester, 3);
  }

  testWidgets('分帧会推迟后挂载项的动画起点 ⇒ 生产不启用分帧（与 web 时序一致）', (WidgetTester tester) async {
    // ⚠️ 这条锁记录的是**结论**，不是某个机制：
    // web 的 `.reveal-item` 是「**同一帧**全部拿到类 ⇒ CSS `animation-delay` 共享同一起点」；
    // 而分帧挂载（`AylaChunkedChildren` 的小 `perFrame`）会让后挂载的项**晚开始**。
    // 曾试图用「批次时间原点追赶」补偿，但那是**从中间进度开始** ⇒ 视觉上是「跳一下」
    // 而不是「淡入」—— 用户实机当场指出「不是掉帧，是很流畅的，但是好好的动画就是顿了一下，
    // 一定是和 web 实现有差异」⇒ 已回退。
    // ⇒ 生产里 `perFrame` 一律取「一次挂完」（`1 << 20`）；若将来要重新启用分帧，
    // 必须解决「动画起点对齐」，且**不得**再用「跳到中间进度」。
    final double inline = await progressAt(tester, chunked: false, totalMs: 400);
    final double chunked = await progressAt(tester, chunked: true, totalMs: 400);
    expect(inline, greaterThan(0.5), reason: '对照组自身必须跑起来（inline=$inline）');
    expect(
      inline - chunked,
      greaterThan(0.05),
      reason: '分帧确实推迟了起点（inline=$inline vs chunked=$chunked）'
          '—— 这正是生产不启用分帧的原因',
    );
  });

  testWidgets('重播：按「重播序号」从 0 计数（对齐 web），不是列表下标', (WidgetTester tester) async {
    // 场景：列表后半段的 5 张卡（index 10..14 ⇒ 首次入场 delay 全是 cap 300ms）。
    // web 重播语义（useListEntryMotion.ts:38–48）：对**已入场节点**重新
    // `let index = 0` ⇒ delay = 0/50/100/150/200 ⇒ 依次浮现。
    // 若沿用列表下标 ⇒ 5 张全部 delay 300ms ⇒ **同时重播** = 实机「看着就像停顿」。
    late StateSetter setHost;
    int nonce = 0;
    await tester.pumpWidget(
      StatefulBuilder(
        builder: (BuildContext context, StateSetter setState) {
          setHost = setState;
          return MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: buildAylaTheme(),
            home: AylaAuroraBackground(
              animate: false,
              child: AylaRevealScope(
                replayKey: nonce,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    for (int i = 0; i < 5; i += 1)
                      KeyedSubtree(
                        key: ValueKey<String>('r$i'),
                        child: AylaRevealItem(
                          index: 10 + i, // 列表下标：后半段
                          child: SizedBox(width: 80, height: 30, child: Text('$i')),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
    // 首次入场跑完（delay 300 + 动画 300 ⇒ 推进 700ms）。
    await tester.pump();
    for (int i = 0; i < 44; i += 1) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    // 触发重播。
    setHost(() => nonce += 1);
    await tester.pump();
    // 推进 112ms：按重播序号，第 1 张（delay 0）应已跑约 0.37；
    // 若错误地沿用列表下标（全部 300ms）则所有卡都还是 0。
    for (int i = 0; i < 7; i += 1) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    final Finder first = find.descendant(
      of: find.byKey(const ValueKey<String>('r0')),
      matching: find.byType(Opacity),
    );
    final double p = tester.widget<Opacity>(first.first).opacity;
    expect(
      p,
      greaterThan(0.2),
      reason: '重播第 1 张必须立即开始（实测进度 $p）——'
          '若为 0 说明 delay 仍按列表下标算（十几张会同时重播 = 停顿感）',
    );
  });
}
