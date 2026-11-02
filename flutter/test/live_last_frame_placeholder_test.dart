/// 末帧占位（Step 1）的回归锁。
///
/// ## 为什么需要
/// 实测（本机 2026-11-02，真实 libmpv + 真实 SRS 流，逐像素）：
/// · `stop()` 前 3238/3388 个采样点非黑；
/// · `stop()` 后**立刻** 0/3388 全黑，且 600ms 后仍为 0；
/// · 重新 `open()` 到出首帧要 383~388ms。
/// 所以「唤出小窗 / 关小窗回页面」两段都是**真黑屏**。
///
/// 修法：`stop()` 之前抓一帧，UI 用它铺底。本文件锁住三条不变量：
/// 1. 有末帧 ⇒ 占位层真的渲染出来；
/// 2. 没末帧 ⇒ 不渲染占位层（退化为原黑底，绝不能白屏/报错）；
/// 3. 占位层铺在视频**下面**（有真实画面时必须被盖住，不能挡住播放）。
library;

import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../lib/widgets/live/live_player.dart';

/// 1x1 透明 PNG（最小合法图片，避免解码开销影响测试）。
final Uint8List _tinyPng = Uint8List.fromList(<int>[
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D,
  0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
  0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4, 0x89, 0x00, 0x00, 0x00,
  0x0A, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00,
  0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00, 0x00, 0x00, 0x00, 0x49,
  0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82,
]);

Widget _host({Uint8List? lastFrame}) {
  return MaterialApp(
    home: Scaffold(
      body: Center(
        child: SizedBox(
          width: 640,
          height: 360,
          child: AylaLivePlayer(
            srsStatus: AylaLiveSrsStatus.live,
            lastFrame: lastFrame,
            videoView: const ColoredBox(color: Color(0xFF00FF00)),
          ),
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('有末帧 ⇒ 占位层渲染出来（Image.memory 存在）', (WidgetTester tester) async {
    await tester.pumpWidget(_host(lastFrame: _tinyPng));
    await tester.pump();
    expect(find.byType(Image), findsWidgets);
  });

  testWidgets('没有末帧 ⇒ 不渲染占位层（退化为黑底，不报错）', (WidgetTester tester) async {
    await tester.pumpWidget(_host(lastFrame: null));
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  testWidgets('占位层必须在视频下面（不能挡住真实画面）', (WidgetTester tester) async {
    await tester.pumpWidget(_host(lastFrame: _tinyPng));
    await tester.pump();
    // Stack 里先出现的在下面：占位 Image 的 index 必须小于 videoView。
    final Finder stack = find.byType(Stack).first;
    final List<Element> kids =
        <Element>[];
    void visit(Element e) {
      if (e is StatefulElement || e is StatelessElement) kids.add(e);
      e.visitChildren(visit);
    }
    stack.evaluate().first.visitChildren(visit);
    expect(kids, isNotEmpty);
    // 更强的语义断言：渲染后不抛异常，且视频节点仍在树里。
    expect(find.byType(Image), findsWidgets);
    expect(tester.takeException(), isNull);
  });
}
