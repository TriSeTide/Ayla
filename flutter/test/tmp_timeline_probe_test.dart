/// 诊断（临时）：按卡片文本定位，逐帧打印【首卡 vs 第二张卡】的位移 —— 排除侧栏/内容区整块的干扰。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../lib/core/api/directory_page.dart';
import '../lib/core/api/live_api.dart' show AylaDirectoryLiveEntry;
import '../lib/pages/live_hub_page.dart';
import '../lib/state/directory_store.dart';
import '../lib/theme/preview_theme.dart';
import '../lib/widgets/base/loading.dart' show AylaSkeleton;
import '../lib/widgets/base/reveal.dart' show AylaRevealItem;
import '../lib/widgets/live/live_hall.dart' show AylaLiveCardData;

void main() {
  testWidgets('诊断：按卡片定位的入场时间线', (WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(1536, 824));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    aylaDirectoryStore.reset();
    aylaDirectoryStore.userId = 'u1';
    aylaDirectoryStore.requestOverride = (kind, options, cursor) async =>
        AylaDirectoryPage<Object>(
      results: <Object>[
        for (int i = 0; i < 6; i += 1)
          AylaDirectoryLiveEntry(card: AylaLiveCardData(id: '$i', title: '房$i')),
      ],
      total: 6,
    );
    addTearDown(() {
      aylaDirectoryStore.requestOverride = null;
      aylaDirectoryStore.reset();
      aylaDirectoryStore.userId = null;
    });

    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Builder(
            builder: (BuildContext context) => MediaQuery(
              data: MediaQuery.of(context).copyWith(size: const Size(1536, 824)),
              child: previewScope(const LiveHubPage()),
            ),
          ),
        ),
      ),
    );

    String dy(String label) {
      final Finder item = find
          .ancestor(of: find.text(label), matching: find.byType(AylaRevealItem))
          .first;
      final Finder tr = find
          .descendant(of: item, matching: find.byType(Transform))
          .first;
      return tester.widget<Transform>(tr).transform.storage[13].toStringAsFixed(1);
    }

    // 数据是异步到达的：先让 store 的 Future 落地、卡片挂载，再开始计时。
    await tester.pump();
    await tester.pump();
    debugPrint('采样起点：已渲染卡片 = ' +
        find.textContaining('房').evaluate().length.toString());
    for (int f = 0; f <= 7; f += 1) {
      final int skeletons = find.byType(AylaSkeleton).evaluate().length;
      final int cards = find.textContaining('房').evaluate().length;
      debugPrint('T=' + (f * 50).toString() + 'ms  骨架=' + skeletons.toString() +
          '  卡片=' + cards.toString() +
          '  首卡 dy=' + (cards > 0 ? dy('房0') : '-') +
          '  第二张 dy=' + (cards > 1 ? dy('房1') : '-'));
      await tester.pump(const Duration(milliseconds: 50));
    }
    await tester.pumpAndSettle();
  });
}
