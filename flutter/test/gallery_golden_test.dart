/// 组件库画布 golden：整张画布一次出图(1800×1700)，供逐项核对。
///
/// 更新: flutter.bat test test\gallery_golden_test.dart --update-goldens
/// 产物: test/goldens/gallery_full.png
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../lib/preview/component_gallery.dart';
import '../lib/theme/preview_theme.dart';

void main() {
  testWidgets('gallery full sheet 1800x1700', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1800, 1700);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        home: previewScope(
          const SizedBox(
            width: 1800,
            height: 1700,
            child: ComponentGallery(),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 120));

    await expectLater(
      find.byType(ComponentGallery),
      matchesGoldenFile('goldens/gallery_full.png'),
    );
  });
}
