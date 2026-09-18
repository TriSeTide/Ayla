/// 图标 golden 测试:把 47 个图标铺成一张图,用于人工/模型逐项核对形状。
///
/// 跑法(生成/更新图片):
///   flutter.bat test test\icons_golden_test.dart --update-goldens
/// 产物:test/goldens/icons.png(8 列 × N 行,每格 64px,图标 40px)。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../lib/theme/app_icons.dart';
import '../lib/theme/app_icons_data.dart';

void main() {
  testWidgets('icons golden sheet', (WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        home: Align(
          alignment: Alignment.topLeft,
          child: RepaintBoundary(
            child: Container(
              width: 560, // 8 列 × 64px + 内沿
              color: const Color(0xFFFFFFFF),
              padding: const EdgeInsets.all(16),
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                children: <Widget>[
                  for (final AylaIconData icon in kAylaIcons)
                    Container(
                      width: 56,
                      height: 56,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        border: Border.all(
                          color: const Color(0x1A000000),
                        ),
                      ),
                      child: AylaIcon(
                        icon,
                        size: 40,
                        color: const Color(0xFF465B92),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await expectLater(
      find.byType(RepaintBoundary).first,
      matchesGoldenFile('goldens/icons.png'),
    );
  });
}
