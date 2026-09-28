/// B3 chat 域第二批：群表情包面板定向测试 —— 逐条对照
/// `components/chat/EmojiPackPanel.tsx`(252) 与 `app.css:2186–2323`（面板全族）、
/// `app.css:3211–3215`（窄屏档）。
///
/// 覆盖：权限兜底三档（后端值优先 / 未建包按角色 / 摘要未加载不显示加号）/ 结构（头 + 关闭键 +
/// 网格列数 auto-fill minmax(56) gap 8 + 格 aspect 1 + 半径 8 + `--surface` 底）/ 空态两档文案 /
/// 错误态 / 交互（点表情发送且**不关闭面板**、hover 显示删除键、上传链回调与失败文案）/
/// **分页页脚接线（tsx 227–228：loading / error / hasMore / invalidated / refresh / loadMore /
/// retainCompletedSpace）与空态五条件（tsx 230）**。
library;

import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../lib/core/models/emoji_item.dart';
import '../lib/core/models/media_kind.dart';
import '../lib/core/models/post.dart'
    show AylaMediaDescriptor, AylaMediaPickResult, AylaPostMediaDraft;
import '../lib/theme/preview_theme.dart';
import '../lib/theme/sample_media.dart';
import '../lib/theme/tokens.dart';
import '../lib/widgets/base/dashed_border.dart';
import '../lib/widgets/base/directory_load_more.dart' show AylaDirectoryLoadMore;
import '../lib/widgets/base/pagination_footer.dart' show AylaPaginationLoadingDots;
import '../lib/widgets/chat/emoji_pack_panel.dart';
import '../lib/widgets/base/resource_image.dart';

AylaEmojiItem _emoji(String id) => AylaEmojiItem(
      id: id,
      media: AylaMediaDescriptor(
        mediaId: 'media-$id',
        kind: AylaMediaKind.emoji,
        mimeType: 'image/png',
        size: 12000,
        width: 240,
        height: 240,
        status: 'ready',
      ),
    );

Future<AylaMediaPickResult> _pickOne() async => AylaMediaPickResult(
      drafts: <AylaPostMediaDraft>[
        AylaPostMediaDraft(
          mediaId: 'uploaded-1',
          descriptor: const AylaMediaDescriptor(
            mediaId: 'uploaded-1',
            kind: AylaMediaKind.emoji,
            mimeType: 'image/gif',
            size: 4096,
            status: 'ready',
          ),
        ),
      ],
    );

void main() {
  setUp(aylaEnableSampleMedia);
  tearDown(aylaDisableSampleMedia);

  void setViewport(WidgetTester tester, Size size) {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
  }

  Widget host(
    WidgetTester tester,
    Widget child, {
    Size viewport = const Size(460, 700),
  }) {
    setViewport(tester, viewport);
    return MaterialApp(
      home: previewTheme(
        Builder(
          builder: (BuildContext context) => MediaQuery(
            data: MediaQuery.of(context).copyWith(size: viewport),
            child: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(width: 420, child: child),
            ),
          ),
        ),
      ),
    );
  }

  // ======================= 权限兜底（tsx 61–62） =======================

  testWidgets('权限：后端值优先（can_upload=false → 无加号）', (WidgetTester tester) async {
    await tester.pumpWidget(
      host(
        tester,
        AylaEmojiPackPanel(
          myRole: 'owner',
          onClose: () {},
          data: AylaEmojiPackData(
            packId: 'p1',
            canUploadFromPack: false,
            summaryLoaded: true,
            items: <AylaEmojiItem>[_emoji('a')],
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.byType(AylaDashedBorder), findsNothing, reason: '后端 can_upload=false 优先');
  });

  testWidgets('权限：未建包 + owner/admin → 显示加号（角色兜底）', (WidgetTester tester) async {
    await tester.pumpWidget(
      host(
        tester,
        AylaEmojiPackPanel(
          myRole: 'admin',
          onClose: () {},
          data: const AylaEmojiPackData(summaryLoaded: true),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.byType(AylaDashedBorder), findsOneWidget, reason: '未建包时按 myRole 兜底');
  });

  testWidgets('权限：未建包 + member → 不显示加号', (WidgetTester tester) async {
    await tester.pumpWidget(
      host(
        tester,
        AylaEmojiPackPanel(
          myRole: 'member',
          onClose: () {},
          data: const AylaEmojiPackData(summaryLoaded: true),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.byType(AylaDashedBorder), findsNothing);
  });

  testWidgets('权限：摘要未加载完成时不做角色兜底（不显示加号）', (WidgetTester tester) async {
    await tester.pumpWidget(
      host(
        tester,
        AylaEmojiPackPanel(
          myRole: 'owner',
          onClose: () {},
          data: const AylaEmojiPackData(),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.byType(AylaDashedBorder), findsNothing);
  });

  // ======================= 结构与尺寸 =======================

  testWidgets('头：标题「群表情包」+ 32 关闭键；点关闭键回调', (WidgetTester tester) async {
    int closed = 0;
    await tester.pumpWidget(
      host(
        tester,
        AylaEmojiPackPanel(
          onClose: () => closed++,
          data: AylaEmojiPackData(
            packId: 'p1',
            summaryLoaded: true,
            items: <AylaEmojiItem>[_emoji('a')],
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.text('群表情包'), findsOneWidget);
    final Finder closeBtn = find.bySemanticsLabel('关闭表情面板');
    expect(closeBtn, findsOneWidget, reason: '`.icon-btn-32`（tsx 162–164）');
    await tester.tap(closeBtn);
    await tester.pump();
    expect(closed, 1);
  });

  testWidgets('网格：auto-fill minmax(56px,1fr) + gap 8 ⇒ 420 宽 → 6 列', (WidgetTester tester) async {
    await tester.pumpWidget(
      host(
        tester,
        AylaEmojiPackPanel(
          onClose: () {},
          data: AylaEmojiPackData(
            packId: 'p1',
            summaryLoaded: true,
            items: <AylaEmojiItem>[for (int i = 0; i < 10; i++) _emoji('$i')],
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 50));

    // 面板 padding sp3×2 = 24 ⇒ 网格可用宽 396；列数 = floor((396+8)/(56+8)) = 6
    final Finder firstCell = find.byType(AylaResourceImage).first;
    final double cellWidth = tester.getSize(
      find.ancestor(of: firstCell, matching: find.byType(AspectRatio)).first,
    ).width;
    final double expected = (396 - AylaEmojiPackPanel.gridGap * 5) / 6;
    expect(cellWidth, moreOrLessEquals(expected, epsilon: 0.5));
    // 格是正方形（aspect-ratio: 1）
    expect(
      tester.getSize(find.ancestor(of: firstCell, matching: find.byType(AspectRatio)).first).height,
      moreOrLessEquals(cellWidth, epsilon: 0.5),
    );
  });

  testWidgets('删除键：canDelete 时存在且初始 opacity 0；hover 单元格后显示', (WidgetTester tester) async {
    await tester.pumpWidget(
      host(
        tester,
        AylaEmojiPackPanel(
          onClose: () {},
          data: AylaEmojiPackData(
            packId: 'p1',
            canDeleteFromPack: true,
            summaryLoaded: true,
            items: <AylaEmojiItem>[_emoji('a')],
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 50));

    final Finder remove = find.bySemanticsLabel('删除表情');
    expect(remove, findsOneWidget);
    double opacityOf() => tester
        .widget<AnimatedOpacity>(
          find
              .descendant(of: remove, matching: find.byType(AnimatedOpacity))
              .first,
        )
        .opacity;
    expect(opacityOf(), 0, reason: '`.emoji-pack-remove { opacity: 0 }`（app.css 2303）');

    final TestGesture mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    addTearDown(mouse.removePointer);
    await mouse.moveTo(tester.getCenter(find.byType(AylaResourceImage)));
    await tester.pump(const Duration(milliseconds: 200));
    expect(opacityOf(), 1, reason: '单元格 hover 显示（app.css 2307–2310）');
  });

  // ======================= 交互 =======================

  testWidgets('点表情 → 发送 emoji 消息，且**面板不自动收起**', (WidgetTester tester) async {
    String? sent;
    int closed = 0;
    await tester.pumpWidget(
      host(
        tester,
        AylaEmojiPackPanel(
          onClose: () => closed++,
          onSendEmoji: (String id) async => sent = id,
          data: AylaEmojiPackData(
            packId: 'p1',
            summaryLoaded: true,
            items: <AylaEmojiItem>[_emoji('a')],
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 50));

    await tester.tap(find.byType(AylaResourceImage));
    await tester.pump(const Duration(milliseconds: 50));
    expect(sent, 'media-a');
    expect(closed, 0, reason: '连发表情时面板保持打开（tsx 131–134）');
  });

  testWidgets('上传：选图 → 加入群包 → 刷新；失败计入错误文案', (WidgetTester tester) async {
    final List<String> added = <String>[];
    int reloads = 0;
    await tester.pumpWidget(
      host(
        tester,
        AylaEmojiPackPanel(
          myRole: 'owner',
          onClose: () {},
          onAddEmoji: (String mediaId) async => added.add(mediaId),
          onReload: () async => reloads++,
          pickImages: _pickOne,
          data: const AylaEmojiPackData(summaryLoaded: true),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 50));

    await tester.tap(find.byType(AylaDashedBorder));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(added, <String>['uploaded-1'], reason: '三步上传成功后交给「加入群包」回调');
    expect(reloads, 1, reason: '上传完成后刷新');
  });

  testWidgets('上传失败：显示「部分表情上传失败」文案（role=alert 语义位）', (WidgetTester tester) async {
    await tester.pumpWidget(
      host(
        tester,
        AylaEmojiPackPanel(
          myRole: 'owner',
          onClose: () {},
          onAddEmoji: (_) async {},
          pickImages: () async => const AylaMediaPickResult(failed: 2),
          data: const AylaEmojiPackData(summaryLoaded: true),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 50));

    await tester.tap(find.byType(AylaDashedBorder));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.textContaining('部分表情上传失败'), findsOneWidget);
    final Text errorText = tester.widget<Text>(find.textContaining('部分表情上传失败'));
    expect(errorText.style!.color, AylaColors.destructive, reason: '`.emoji-pack-error`');
  });

  // ======================= 空态与错误态 =======================

  testWidgets('空态两档文案：可上传 / 不可上传', (WidgetTester tester) async {
    await tester.pumpWidget(
      host(
        tester,
        AylaEmojiPackPanel(
          myRole: 'owner',
          onClose: () {},
          data: const AylaEmojiPackData(summaryLoaded: true),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('还没有表情，点加号上传'), findsOneWidget);
  });

  testWidgets('空态（成员视角）：群内还没有表情包', (WidgetTester tester) async {
    await tester.pumpWidget(
      host(
        tester,
        AylaEmojiPackPanel(
          myRole: 'member',
          onClose: () {},
          data: const AylaEmojiPackData(summaryLoaded: true),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('群内还没有表情包'), findsOneWidget);
  });

  testWidgets('摘要错误：显示错误文案', (WidgetTester tester) async {
    await tester.pumpWidget(
      host(
        tester,
        AylaEmojiPackPanel(
          myRole: 'owner',
          onClose: () {},
          data: const AylaEmojiPackData(
            summaryLoaded: true,
            summaryError: '加载群表情包失败',
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('加载群表情包失败'), findsOneWidget);
  });

  // ======================= 分页页脚（tsx 227–228 接线） =======================

  group('分页页脚（复用 AylaDirectoryLoadMore）', () {
    AylaDirectoryLoadMore footerOf(WidgetTester tester) =>
        tester.widget<AylaDirectoryLoadMore>(find.byType(AylaDirectoryLoadMore));

    testWidgets('摘要未加载 ⇒ loading=true + 页脚三点', (WidgetTester tester) async {
      await tester.pumpWidget(
        host(
          tester,
          AylaEmojiPackPanel(
            myRole: 'owner',
            onClose: () {},
            data: const AylaEmojiPackData(), // summaryLoaded: false
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 50));
      expect(
        footerOf(tester).loading,
        isTrue,
        reason: 'tsx 227：loading = !metaLoaded || pages.loading',
      );
      expect(find.byType(AylaPaginationLoadingDots), findsOneWidget);
    });

    testWidgets('摘要已加载 + 分页加载中 ⇒ loading=true', (WidgetTester tester) async {
      await tester.pumpWidget(
        host(
          tester,
          AylaEmojiPackPanel(
            myRole: 'owner',
            onClose: () {},
            data: const AylaEmojiPackData(summaryLoaded: true, itemsLoading: true),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 50));
      expect(footerOf(tester).loading, isTrue);
      expect(find.byType(AylaPaginationLoadingDots), findsOneWidget);
    });

    testWidgets('空闲（已加载 / 无更多 / 无错）⇒ 页脚不渲染（retainCompletedSpace:false）', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        host(
          tester,
          AylaEmojiPackPanel(
            myRole: 'owner',
            onClose: () {},
            data: const AylaEmojiPackData(summaryLoaded: true),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 50));
      expect(footerOf(tester).retainCompletedSpace, isFalse);
      expect(find.byType(AylaPaginationLoadingDots), findsNothing);
      expect(find.text('加载更多'), findsNothing);
      // 组件本身仍在树上（渲染为空盒子），只是页脚内容为零
      expect(find.byType(AylaDirectoryLoadMore), findsOneWidget);
    });

    testWidgets('hasMore ⇒ 「加载更多」按钮；点它走 onLoadMore（不是 refresh）', (
      WidgetTester tester,
    ) async {
      int loads = 0;
      int reloads = 0;
      await tester.pumpWidget(
        host(
          tester,
          AylaEmojiPackPanel(
            myRole: 'owner',
            onClose: () {},
            onReload: () async => reloads += 1,
            onLoadMore: () async => loads += 1,
            data: AylaEmojiPackData(
              packId: 'p1',
              summaryLoaded: true,
              hasMore: true,
              items: <AylaEmojiItem>[_emoji('a')],
            ),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 50));
      expect(footerOf(tester).hasMore, isTrue);
      await tester.tap(find.text('加载更多'));
      await tester.pump();
      expect(loads, 1, reason: 'tsx 228：loadMore = metaError ? refresh : pages.loadMore');
      expect(reloads, 0);
    });

    testWidgets('摘要错误 ⇒ error 传页脚（不渲染）+ loadMore 改走 refresh', (
      WidgetTester tester,
    ) async {
      int loads = 0;
      int reloads = 0;
      await tester.pumpWidget(
        host(
          tester,
          AylaEmojiPackPanel(
            myRole: 'owner',
            onClose: () {},
            onReload: () async => reloads += 1,
            onLoadMore: () async => loads += 1,
            data: const AylaEmojiPackData(
              summaryLoaded: true,
              summaryError: '加载群表情包失败',
            ),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 50));
      final AylaDirectoryLoadMore footer = footerOf(tester);
      expect(footer.error, '加载群表情包失败', reason: 'tsx 227：error = metaError ?? pages.error');
      expect(footer.loading, isFalse, reason: '摘要已加载（metaLoaded=true）');
      // error 非 null ⇒ 组件返回 SizedBox.shrink（tsx 29），页脚内容不渲染
      expect(find.text('加载更多'), findsNothing);
      expect(find.byType(AylaPaginationLoadingDots), findsNothing);
      // 摘要失败时页脚的重试目标是**摘要**
      await footer.loadMore();
      expect(reloads, 1);
      expect(loads, 0);
    });

    testWidgets('分页错误 ⇒ error = itemsError（页脚不渲染）', (WidgetTester tester) async {
      await tester.pumpWidget(
        host(
          tester,
          AylaEmojiPackPanel(
            myRole: 'owner',
            onClose: () {},
            data: const AylaEmojiPackData(
              summaryLoaded: true,
              itemsError: '加载失败，请重试',
            ),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 50));
      expect(footerOf(tester).error, '加载失败，请重试');
      expect(find.byType(AylaPaginationLoadingDots), findsNothing);
    });

    testWidgets('invalidated 恒为 false（tsx 228 字面量）', (WidgetTester tester) async {
      await tester.pumpWidget(
        host(
          tester,
          AylaEmojiPackPanel(
            myRole: 'owner',
            onClose: () {},
            data: AylaEmojiPackData(
              packId: 'p1',
              summaryLoaded: true,
              itemsLoading: true,
              hasMore: true,
            ),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 50));
      expect(footerOf(tester).invalidated, isFalse);
    });

    testWidgets('空态五条件（tsx 230）：分页加载中不出空态文案', (WidgetTester tester) async {
      await tester.pumpWidget(
        host(
          tester,
          AylaEmojiPackPanel(
            myRole: 'owner',
            onClose: () {},
            data: const AylaEmojiPackData(summaryLoaded: true, itemsLoading: true),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 50));
      expect(find.text('还没有表情，点加号上传'), findsNothing, reason: '!pages.loading 是空态条件之一');
    });

    testWidgets('空态五条件（tsx 230）：分页错误时不出空态文案', (WidgetTester tester) async {
      await tester.pumpWidget(
        host(
          tester,
          AylaEmojiPackPanel(
            myRole: 'owner',
            onClose: () {},
            data: const AylaEmojiPackData(
              summaryLoaded: true,
              itemsError: '加载失败，请重试',
            ),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 50));
      expect(find.text('还没有表情，点加号上传'), findsNothing, reason: '!pages.error 是空态条件之一');
      expect(find.text('加载失败，请重试'), findsOneWidget);
    });
  });
}
