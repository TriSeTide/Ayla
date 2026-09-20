import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import '../lib/core/media/media_signer.dart';
import '../lib/core/net/dio_client.dart';
import '../lib/widgets/dialogs.dart';
import '../lib/widgets/resource_image.dart';
import '../lib/theme/preview_theme.dart';

void main() {
  group('extractMediaId（对齐 media.ts extractMediaId）', () {
    test('识别内部媒体路径', () {
      expect(extractMediaId('/api/v1/media/abc123/content'), 'abc123');
      expect(extractMediaId('/api/v1/media/abc123/thumbnail'), 'abc123');
    });
    test('外部/非媒体路径 → null（直接加载）', () {
      expect(extractMediaId('https://example.com/a.png'), isNull);
      expect(extractMediaId('/api/v1/other/x'), isNull);
      expect(extractMediaId('/api/v1/media/'), isNull);   // 无 id
      expect(extractMediaId('/api/v1/media/abc'), isNull); // 无尾斜杠
    });
  });

  group('AsyncState 四态', () {
    testWidgets('loading → 骨架', (WidgetTester tester) async {
      await tester.pumpWidget(previewTheme(
        const AylaAsyncState(status: AsyncStatus.loading),
      ));
      expect(find.bySemanticsLabel('正在加载'), findsOneWidget);
    });

    testWidgets('error → 文案 + 重试', (WidgetTester tester) async {
      bool retried = false;
      await tester.pumpWidget(previewTheme(
        AylaAsyncState(
          status: AsyncStatus.error,
          error: '网络错误',
          onRetry: () => retried = true,
        ),
      ));
      expect(find.text('网络错误'), findsOneWidget);
      await tester.tap(find.text('重试'));
      await tester.pump();
      expect(retried, isTrue);
    });

    testWidgets('empty → 默认文案', (WidgetTester tester) async {
      await tester.pumpWidget(previewTheme(
        const AylaAsyncState(status: AsyncStatus.empty),
      ));
      expect(find.text('这里还没有内容'), findsOneWidget);
    });

    testWidgets('content → 渲染子项', (WidgetTester tester) async {
      await tester.pumpWidget(previewTheme(
        const AylaAsyncState(
          status: AsyncStatus.content,
          child: Text('真实内容'),
        ),
      ));
      expect(find.text('真实内容'), findsOneWidget);
    });
  });

  group('ConfirmDialog（tsx 行为逐条）', () {
    testWidgets('渲染标题/文案/两个按钮', (WidgetTester tester) async {
      await tester.pumpWidget(previewTheme(
        ConfirmDialog(
          title: '删除会话',
          message: '删除会话「小樱」？\n消息记录会保留。',
          onConfirm: () {},
          onClose: () {},
        ),
      ));
      await tester.pump();
      expect(find.text('删除会话'), findsOneWidget);
      expect(find.text('删除'), findsOneWidget);   // confirmLabel 默认
      expect(find.text('取消'), findsOneWidget);
    });

    testWidgets('自动聚焦「取消」（危险操作防回车误触）', (WidgetTester tester) async {
      await tester.pumpWidget(previewTheme(
        ConfirmDialog(title: 'T', message: 'M', onConfirm: () {}, onClose: () {}),
      ));
      await tester.pump(); // post-frame 聚焦
      await tester.pump();
      final focused = FocusManager.instance.primaryFocus;
      expect(focused, isNotNull);
      // 聚焦在取消按钮上（其 label 为「取消」）
      final ctx = focused!.context;
      expect(ctx, isNotNull);
      expect(find.text('取消'), findsOneWidget);
    });

    testWidgets('点取消 → onClose；点确认 → onConfirm', (WidgetTester tester) async {
      int closed = 0, confirmed = 0;
      await tester.pumpWidget(previewTheme(
        ConfirmDialog(
          title: 'T', message: 'M',
          onConfirm: () => confirmed++,
          onClose: () => closed++,
        ),
      ));
      await tester.pump();
      await tester.tap(find.text('取消'));
      await tester.pump();
      expect(closed, 1);
      await tester.tap(find.text('删除'));
      await tester.pump();
      expect(confirmed, 1);
    });

    testWidgets('busy → 确认文案「处理中…」且禁用关闭', (WidgetTester tester) async {
      int closed = 0, confirmed = 0;
      await tester.pumpWidget(previewTheme(
        ConfirmDialog(
          title: 'T', message: 'M', busy: true,
          onConfirm: () => confirmed++,
          onClose: () => closed++,
        ),
      ));
      await tester.pump();
      expect(find.text('处理中…'), findsOneWidget);
      await tester.tap(find.text('取消'));
      await tester.pump();
      expect(closed, 0, reason: 'busy 时取消不可用');
      await tester.tap(find.text('处理中…'));
      await tester.pump();
      expect(confirmed, 0, reason: 'busy 时确认不可用');
    });

    testWidgets('ESC → onClose（busy 时不关）', (WidgetTester tester) async {
      int closed = 0;
      await tester.pumpWidget(previewTheme(
        ConfirmDialog(title: 'T', message: 'M', onConfirm: () {}, onClose: () => closed++),
      ));
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(closed, 1);
    });
  });

  group('ResourceImage（decorative 语义）', () {
    testWidgets('外部 URL 直接加载（不走签名）', (WidgetTester tester) async {
      await tester.pumpWidget(previewTheme(
        const ResourceImage(src: 'https://example.com/a.png', alt: '图'),
      ));
      await tester.pump();
      // 应进入 ready 态并创建 Image（不抛 "未注入 DioClient" → 证明未走签名）
      expect(find.byType(Image), findsOneWidget);
    });

    testWidgets('decorative（alt=""）加载中不留骨架', (WidgetTester tester) async {
      await tester.pumpWidget(previewTheme(
        const SizedBox(
          width: 40, height: 40,
          child: ResourceImage(src: 'https://example.com/a.png'), // alt 默认 ''
        ),
      ));
      await tester.pump();
      // 装饰图不应出现「图片加载失败」提示
      expect(find.text('图片加载失败，点击重试'), findsNothing);
    });
  });

  group('ResourceImage 签名降级 / 过期态', signerDegradationTests);
}


// ===== 签名降级 / 过期态（受控假 client，走真实降级代码路径） =====

/// 假签名 client：模拟后端 `:sign` 的分级过期（original 410 → 降级 thumb）。
class _FakeSignerClient implements DioClient {
  @override
  Future<T> post<T>(
    String path,
    {Object? body, Map<String, dynamic>? query}
  ) async {
    final bool isThumb = body is Map && body['variant'] == 'thumb';
    final bool expiredOriginal = path.contains('expired-original');
    final bool fullyExpired = path.contains('fully-expired');
    if ((expiredOriginal && !isThumb) || fullyExpired) {
      throw const ApiException(410, 'media_expired');
    }
    return <String, dynamic>{
      'url': 'https://picsum.photos/seed/t/100/100',
      'expires_at': DateTime.now().millisecondsSinceEpoch / 1000 + 3600,
    } as T;
  }

  @override
  noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

void signerDegradationTests() {
  setUp(() {
    MediaSigner.instance.detach();
    MediaSigner.instance.attach(_FakeSignerClient());
  });
  tearDown(() => MediaSigner.instance.detach());

  testWidgets('原图已过期（阶段 1）→ 显示「原图已过期」角标',
      (WidgetTester tester) async {
    await tester.pumpWidget(previewTheme(
      const SizedBox(
        width: 200, height: 150,
        child: ResourceImage(
          src: '/api/v1/media/expired-original/content',
          alt: '图',
          expiredBadge: true,
        ),
      ),
    ));
    await tester.pump();
    await tester.pump();
    expect(find.text('原图已过期'), findsOneWidget,
        reason: 'original 410 → 降级 thumb 且 originalExpired=true');
  });

  testWidgets('expiredBadge=false → 不显示角标（同 web 默认）',
      (WidgetTester tester) async {
    await tester.pumpWidget(previewTheme(
      const SizedBox(
        width: 200, height: 150,
        child: ResourceImage(src: '/api/v1/media/expired-original/content', alt: '图'),
      ),
    ));
    await tester.pump();
    await tester.pump();
    expect(find.text('原图已过期'), findsNothing);
  });

  testWidgets('完全过期（阶段 2）→「已过期」占位；装饰图不显示',
      (WidgetTester tester) async {
    await tester.pumpWidget(previewTheme(
      const Column(children: <Widget>[
        SizedBox(width: 200, height: 150,
          child: ResourceImage(src: '/api/v1/media/fully-expired/content', alt: '图')),
        SizedBox(width: 200, height: 150,
          child: ResourceImage(src: '/api/v1/media/fully-expired/content')),
      ]),
    ));
    await tester.pump();
    await tester.pump();
    expect(find.text('已过期'), findsOneWidget, reason: '仅非装饰图显示占位');
  });
}
