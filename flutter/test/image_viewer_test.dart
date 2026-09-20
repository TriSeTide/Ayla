/// B5：查看器定向测试（AylaImageViewer，ImageViewer.tsx + app.css 1459–1836 对照）。
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:flutter_test/flutter_test.dart';

import '../lib/core/media/media_signer.dart';
import '../lib/core/models/post.dart';
import '../lib/theme/preview_theme.dart';
import '../lib/widgets/image_viewer.dart';

void main() {
  setUp(() => MediaSigner.instance.detach()); // 隔离：不做真实签名
  tearDown(() => MediaSigner.instance.detach());

  Widget host(Widget child) => MaterialApp(home: previewScope(child));

  AylaViewerItem mediaItem(String id) => AylaViewerItem(
        media: AylaMediaDescriptor(
          mediaId: id,
          kind: AylaMediaKind.image,
          mimeType: 'image/png',
          thumbnail: '/api/v1/media/' + id + '/thumbnail',
        ),
        alt: '图 ' + id,
      );

  group('AylaImageViewer', () {
    testWidgets('单图：有关闭钮，无计数与导航', (WidgetTester tester) async {
      await tester.pumpWidget(
        host(
          AylaImageViewer(
            items: <AylaViewerItem>[mediaItem('a')],
            onClose: () {},
          ),
        ),
      );
      await tester.pump();
      expect(find.byType(AylaImageViewer), findsOneWidget); // 关闭钮为语义节点（bySemanticsLabel 需 ensureSemantics）
      expect(find.text('1/1'), findsNothing);
      expect(find.text('‹'), findsNothing);
      expect(find.text('保存'), findsOneWidget);
    });

    testWidgets('多图：计数 + 上一张/下一张 + 首尾禁用；点导航切换', (WidgetTester tester) async {
      await tester.pumpWidget(
        host(
          AylaImageViewer(
            items: <AylaViewerItem>[mediaItem('a'), mediaItem('b'), mediaItem('c')],
            initialIndex: 1,
            onClose: () {},
          ),
        ),
      );
      await tester.pump();
      expect(find.text('2/3'), findsOneWidget);
      expect(find.text('‹'), findsOneWidget);
      expect(find.text('›'), findsOneWidget);
      await tester.tap(find.text('›'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('3/3'), findsOneWidget);
      // 末页：下一张禁用（opacity 0.35）
      final Opacity nextOpacity = tester.widget<Opacity>(
        find
            .ancestor(of: find.text('›'), matching: find.byType(Opacity))
            .first,
      );
      expect(nextOpacity.opacity, 0.35);
    });

    testWidgets('键盘：ESC 关闭、左右方向键切换', (WidgetTester tester) async {
      bool closed = false;
      await tester.pumpWidget(
        host(
          AylaImageViewer(
            items: <AylaViewerItem>[mediaItem('a'), mediaItem('b')],
            onClose: () => closed = true,
          ),
        ),
      );
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('2/2'), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('1/2'), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(closed, isTrue);
    });

    testWidgets('本地预览：保存禁用显示「发送后可保存」', (WidgetTester tester) async {
      await tester.pumpWidget(
        host(
          AylaImageViewer(
            items: const <AylaViewerItem>[
              AylaViewerItem(localPath: '/tmp/x.png', alt: '本地'),
            ],
            onClose: () {},
          ),
        ),
      );
      await tester.pump();
      expect(find.text('发送后可保存'), findsOneWidget);
    });

    testWidgets('embedded：嵌入宿主不建 backdrop 模糊层（不糊画布）', (WidgetTester tester) async {
      await tester.pumpWidget(
        host(
          AylaImageViewer(
            items: <AylaViewerItem>[mediaItem('a')],
            onClose: () {},
            embedded: true,
          ),
        ),
      );
      await tester.pump();
      // 嵌入模式：遮罩与操作条都不建 BackdropFilter（否则会采样并糊掉宿主画布）
      expect(find.byType(BackdropFilter), findsNothing);
    });

    testWidgets('无媒体无本地预览 → 「媒体不可用」', (WidgetTester tester) async {
      await tester.pumpWidget(
        host(
          AylaImageViewer(
            items: const <AylaViewerItem>[AylaViewerItem(alt: '空')],
            onClose: () {},
          ),
        ),
      );
      await tester.pump();
      expect(find.text('媒体不可用'), findsOneWidget);
    });
  }); // group
}
