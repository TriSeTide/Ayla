/// `AylaFavoriteItem` 定向测试 —— 对照 `FavoritesPage.tsx:95` + `profile.css 474–487 / 539–541`。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../lib/theme/glass.dart';
import '../lib/theme/preview_theme.dart';
import '../lib/theme/tokens.dart';
import '../lib/widgets/base/favorite_item.dart';

void main() {
  Widget host(Widget child, {double width = 420}) => MaterialApp(
    home: previewScope(
      Builder(
        builder: (BuildContext context) => MediaQuery(
          data: MediaQuery.of(context).copyWith(size: Size(width, 800)),
          child: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(width: width, child: child),
          ),
        ),
      ),
    ),
  );

  testWidgets('窄档（<769）padding sp3；走玻璃 + 紧凑阴影 + radius-input', (WidgetTester tester) async {
    await tester.pumpWidget(
      host(const AylaFavoriteItem(child: Text('内容')), width: 420),
    );
    final AylaGlassSurface surface = tester.widget<AylaGlassSurface>(
      find.byType(AylaGlassSurface),
    );
    expect(surface.padding, const EdgeInsets.all(AylaSpacing.sp3));
    expect(surface.radius, AylaRadii.rInput);
    expect(surface.shadow, AylaShadows.compact);
  });

  testWidgets('宽档（≥769）padding sp4（profile.css 539）', (WidgetTester tester) async {
    await tester.pumpWidget(
      host(const AylaFavoriteItem(child: Text('内容')), width: 900),
    );
    final AylaGlassSurface surface = tester.widget<AylaGlassSurface>(
      find.byType(AylaGlassSurface),
    );
    expect(surface.padding, const EdgeInsets.all(AylaSpacing.sp4));
  });
}
