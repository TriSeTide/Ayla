/// 量化：`BackdropGroup` + `BackdropFilter.grouped` 在多玻璃件同屏时的收益。
/// 判定口径：6 张卡的成本若**远小于** 6×单张 ⇒ 共享背景输入生效（官方语义）。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../lib/theme/aurora_background.dart';
import '../lib/theme/preview_theme.dart';
import '../lib/widgets/base/reveal.dart' show AylaRevealItem;
import '../lib/widgets/base/sidebar_card.dart';

void main() {
  Widget page(int cards) => AylaAuroraBackground(
        child: Wrap(
          children: <Widget>[
            for (int i = 0; i < cards; i += 1)
              SizedBox(
                width: 224,
                height: 300,
                child: AylaRevealItem(
                  fadeGlass: false,
                  delay: Duration(milliseconds: i * 50),
                  offset: const Offset(-20, 0),
                  duration: const Duration(milliseconds: 500),
                  child: AylaSidebarCard(child: Text('房间' + i.toString())),
                ),
              ),
          ],
        ),
      );

  Future<double> avgFrameMs(WidgetTester tester, int cards, int frames) async {
    await tester.pumpWidget(MaterialApp(home: previewScope(page(cards))));
    await tester.pump();
    final Stopwatch sw = Stopwatch();
    for (int i = 0; i < frames; i += 1) {
      sw.start();
      await tester.pump(const Duration(milliseconds: 16));
      sw.stop();
    }
    return sw.elapsedMicroseconds / frames / 1000.0;
  }

  testWidgets('玻璃卡数量 vs 每帧耗时（BackdropGroup 共享）', (WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(1440, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    // 预热（首个 pumpWidget 含 JIT/首次布局成本，必须丢弃）。
    await avgFrameMs(tester, 6, 5);
    final double one = await avgFrameMs(tester, 1, 25);
    final double six = await avgFrameMs(tester, 6, 25);
    final double oneAgain = await avgFrameMs(tester, 1, 25);
    debugPrint('每帧耗时（预热后）：1 卡 = ' +
        one.toStringAsFixed(3) + ' ms，6 卡 = ' +
        six.toStringAsFixed(3) + ' ms，再测 1 卡 = ' +
        oneAgain.toStringAsFixed(3) + ' ms；6/1 比值 = ' +
        (six / oneAgain).toStringAsFixed(2) + '（无共享时应≈6）');
  });
}
