// PoC 最小壳 smoke test：渲染 PocApp（双 PoC 入口 HomePage），
// 断言两个入口按钮存在即可（不触发任何音频/网络/HLS）。
import 'package:flutter_test/flutter_test.dart';

import 'package:ayla_flutter/main.dart';

void main() {
  testWidgets('PoC shell smoke test', (WidgetTester tester) async {
    await tester.pumpWidget(const PocApp());
    expect(find.text('Ayla Flutter PoC'), findsOneWidget);
    expect(find.text('PoC-A 音频 Echo（语音中继）'), findsOneWidget);
    expect(find.text('PoC-B HLS 播放（直播）'), findsOneWidget);
  });
}
