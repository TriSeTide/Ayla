/// B2-1：弹幕列表定向测试 —— 逐条对照 `components/live/DanmakuList.tsx`(139)
/// 与 `app.css:3671–3762`（列表族全部样式，全库唯一命中、不在任何 @media 内）、
/// `live.css:756–764 / 830–838`（上下文材质档）、`ResourceImage.tsx:96–115`
/// （失败态的 enclosingControl 重试语义）。
///
/// 覆盖：结构（wrap/list/行/空态/新弹幕提示/查看器）/ 关键尺寸（20 头像、96×64 图片、
/// 圆角 8、padding 12、gap 8、min-height 96）/ 关键样式（字体族与色值）/ 交互回调
/// （头像、图片、跳底、滚动上报）/ 材质三档 / 历史控件位置 / **失败态照实渲染**
/// （骨架铺满 + 点击=重试而不是开查看器）。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../lib/core/media/media_signer.dart';
import '../lib/core/models/media_kind.dart';
import '../lib/core/models/post.dart' show AylaMediaDescriptor;
import '../lib/theme/glass.dart';
import '../lib/theme/preview_theme.dart';
import '../lib/theme/sample_media.dart';
import '../lib/theme/tokens.dart';
import '../lib/widgets/avatar_halo.dart';
import '../lib/widgets/danmaku.dart';
import '../lib/widgets/directory_controls.dart';
import '../lib/widgets/image_viewer.dart';
import '../lib/widgets/loading.dart';
import '../lib/widgets/resource_image.dart';

AylaDanmakuEntry _entry(
  String id,
  String nickname, {
  String content = '一条弹幕',
  bool online = true,
  String avatar = '',
  String? mediaId,
  bool withDescriptor = true,
}) {
  return AylaDanmakuEntry(
    id: id,
    senderNickname: nickname,
    senderUserId: 'u-$id',
    senderAvatarUrl: avatar,
    senderOnline: online,
    content: content,
    mediaId: mediaId,
    media: mediaId == null || !withDescriptor
        ? null
        : AylaMediaDescriptor(
            mediaId: mediaId,
            kind: AylaMediaKind.image,
            thumbnail: '$kMediaPathPrefix$mediaId/thumbnail',
          ),
  );
}

void main() {
  setUp(() {
    aylaDisableSampleMedia();
    MediaSigner.instance.detach(); // 隔离：不触真实签名（失败态即由此产生）
  });
  tearDown(() {
    aylaDisableSampleMedia();
    MediaSigner.instance.detach();
  });

  /// 视口显式钉死（默认测试窗口是 800×600 物理 / DPR 3 ⇒ 逻辑仅 266×200，
  /// 会让 SizedBox 被父约束夹住、行左边界读数失真）。
  void setViewport(WidgetTester tester, Size size) {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
  }

  Widget host(
    WidgetTester tester,
    Widget child, {
    Size viewport = const Size(420, 320),
  }) {
    setViewport(tester, viewport);
    return MaterialApp(
      home: previewScope(
        Builder(
          builder: (BuildContext context) => MediaQuery(
            data: MediaQuery.of(context).copyWith(size: viewport),
            child: SizedBox.fromSize(size: viewport, child: child),
          ),
        ),
      ),
    );
  }

  Future<void> settle(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }

  /// 图片钮（`.danmaku-image-open`）＝ 96×64 的外层框（其 child 是圆角裁剪层）；
  /// 不能用语义标签定位——失败态下标签会换成「…：图片加载失败，重试」（web 同语义）。
  Finder imageButton() => find.byWidgetPredicate(
    (Widget w) =>
        w is SizedBox &&
        w.width == 96 &&
        w.height == 64 &&
        w.child is ClipRRect,
  );

  /// 语义标签（就绪态 / 失败态两种）。
  Finder imageSemantics(String label) => find.byWidgetPredicate(
    (Widget w) => w is Semantics && w.properties.label == label,
  );

  group('结构', () {
    testWidgets('wrap → list → 行；行有 id key（web data-history-id）', (WidgetTester tester) async {
      await tester.pumpWidget(
        host(
          tester,
          AylaDanmakuList(
            items: <AylaDanmakuEntry>[_entry('a', '观众A'), _entry('b', '观众B')],
          ),
        ),
      );
      await settle(tester);

      expect(find.byType(AylaDanmakuList), findsOneWidget);
      expect(find.byKey(const ValueKey<String>('a')), findsOneWidget);
      expect(find.byKey(const ValueKey<String>('b')), findsOneWidget);
      // 昵称 + 全角冒号（tsx 60 `{nickname}：`）
      expect(find.text('观众A：'), findsOneWidget);
      expect(find.text('一条弹幕'), findsNWidgets(2));
    });

    testWidgets('.danmaku-list padding sp3 + gap sp2（3681/3684）', (WidgetTester tester) async {
      await tester.pumpWidget(
        host(
          tester,
          AylaDanmakuList(
            items: <AylaDanmakuEntry>[_entry('a', '观众A'), _entry('b', '观众B')],
          ),
        ),
      );
      await settle(tester);

      final SingleChildScrollView list = tester.widget<SingleChildScrollView>(
        find.byType(SingleChildScrollView),
      );
      expect(list.padding, const EdgeInsets.all(AylaSpacing.sp3));

      final Rect first = tester.getRect(find.byKey(const ValueKey<String>('a')));
      final Rect second = tester.getRect(find.byKey(const ValueKey<String>('b')));
      expect(second.top - first.bottom, AylaSpacing.sp2); // gap: 8
      expect(first.left, AylaSpacing.sp3); // 左内边距
      expect(first.width, 420 - AylaSpacing.sp3 * 2); // flex column 的 stretch
    });

    testWidgets('空态文案与样式（3687–3692 + tsx 110）', (WidgetTester tester) async {
      await tester.pumpWidget(
        host(tester, const AylaDanmakuList(items: <AylaDanmakuEntry>[])),
      );
      await settle(tester);

      final Finder empty = find.text('还没有弹幕，来说点什么吧');
      expect(empty, findsOneWidget);
      final Text text = tester.widget<Text>(empty);
      expect(text.textAlign, TextAlign.center);
      expect(text.style?.fontSize, 13);
      expect(text.style?.color, AylaColors.textSecondary);
      // padding: var(--sp-6) 0
      expect(
        find.ancestor(
          of: empty,
          matching: find.byWidgetPredicate(
            (Widget w) =>
                w is Padding &&
                w.padding ==
                    const EdgeInsets.symmetric(vertical: AylaSpacing.sp6),
          ),
        ),
        findsOneWidget,
      );
    });
  });

  group('行内元素', () {
    testWidgets('头像 size 20 + 光环在线态 + aria 标签 + 点击回调', (WidgetTester tester) async {
      final List<String> opened = <String>[];
      await tester.pumpWidget(
        host(
          tester,
          AylaDanmakuList(
            items: <AylaDanmakuEntry>[
              _entry('a', '观众A', online: true, avatar: 'https://x/a.png'),
              _entry('b', '观众B', online: false),
            ],
            onOpenSenderProfile: opened.add,
          ),
        ),
      );
      await settle(tester);

      final List<AvatarHalo> avatars = tester
          .widgetList<AvatarHalo>(find.byType(AvatarHalo))
          .toList();
      expect(avatars.length, 2);
      expect(avatars.first.size, 20); // tsx 54 `size={20}`
      expect(avatars.first.online, isTrue);
      expect(avatars.first.resourceUrl, 'https://x/a.png');
      expect(avatars.first.semanticLabel, '查看 观众A 的个人主页'); // tsx 58
      expect(avatars.last.online, isFalse);

      await tester.tap(find.byType(AvatarHalo).first);
      await tester.pump();
      expect(opened, <String>['u-a']);
    });

    testWidgets('昵称 = Space Grotesk 12 secondary + padding-top 2（3703–3709）', (WidgetTester tester) async {
      await tester.pumpWidget(
        host(
          tester,
          AylaDanmakuList(items: <AylaDanmakuEntry>[_entry('a', '观众A')]),
        ),
      );
      await settle(tester);

      final Text sender = tester.widget<Text>(find.text('观众A：'));
      expect(sender.style?.fontFamily, AylaFonts.utility);
      expect(sender.style?.fontSize, 12);
      expect(sender.style?.color, AylaColors.textSecondary);
      expect(
        find.ancestor(
          of: find.text('观众A：'),
          matching: find.byWidgetPredicate(
            (Widget w) =>
                w is Padding && w.padding == const EdgeInsets.only(top: 2),
          ),
        ),
        findsOneWidget,
      );
    });

    testWidgets('内容 14 / line-height 1.5 / textPrimary（3694–3713）', (WidgetTester tester) async {
      await tester.pumpWidget(
        host(
          tester,
          AylaDanmakuList(
            items: <AylaDanmakuEntry>[_entry('a', '观众A', content: '正文内容')],
          ),
        ),
      );
      await settle(tester);

      final Text content = tester.widget<Text>(find.text('正文内容'));
      expect(content.style?.fontSize, 14);
      expect(content.style?.height, 1.5);
      expect(content.style?.color, AylaColors.textPrimary);
    });

    testWidgets('媒体弹幕：图片 96×64 + 圆角 8 + 占位文案「图片」不再渲染（3717–3747 / tsx 81）', (
      WidgetTester tester,
    ) async {
      aylaEnableSampleMedia(); // 例图注入 ⇒ 图片钮处于就绪档（语义标签为「查看弹幕图片」）
      await tester.pumpWidget(
        host(
          tester,
          AylaDanmakuList(
            items: <AylaDanmakuEntry>[
              _entry('a', '观众A', content: '图片', mediaId: 'm1'),
            ],
          ),
        ),
      );
      await settle(tester);

      expect(find.text('图片'), findsNothing);
      final Finder button = imageButton();
      expect(button, findsOneWidget);
      expect(tester.getSize(button), const Size(96, 64)); // width/height 96×64
      expect(imageSemantics('查看弹幕图片'), findsOneWidget); // tsx 69
      final ClipRRect clip = tester.widget<ClipRRect>(
        find.descendant(of: button, matching: find.byType(ClipRRect)),
      );
      expect(clip.borderRadius, BorderRadius.circular(AylaRadii.rSm));
      // 图源 = resolveMediaPath(thumbnail) ?? mediaContentUrl(media_id)
      final ResourceImage image = tester.widget<ResourceImage>(
        find.byType(ResourceImage),
      );
      expect(image.src, '${kMediaPathPrefix}m1/thumbnail');
      expect(image.alt, '图片'); // tsx 67 `item.content || "弹幕图片"`
      expect(image.fit, BoxFit.cover);
    });

    testWidgets('media 缺字段时不渲染图片钮（tsx 62 `item.media_id && item.media`）', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        host(
          tester,
          AylaDanmakuList(
            items: <AylaDanmakuEntry>[
              _entry('a', '观众A', mediaId: 'm1', withDescriptor: false),
            ],
          ),
        ),
      );
      await settle(tester);
      expect(find.byType(ResourceImage), findsNothing);
    });
  });

  group('新弹幕提示（3749–3762 + tsx 121–129）', () {
    testWidgets('文案 / 渐变底 / pill / 辉光 / 位置 bottom sp3 居中', (WidgetTester tester) async {
      int scrolls = 0;
      await tester.pumpWidget(
        host(
          tester,
          AylaDanmakuList(
            items: <AylaDanmakuEntry>[_entry('a', '观众A')],
            hasNewBelow: true,
            onScrollToBottom: () => scrolls += 1,
          ),
        ),
      );
      await settle(tester);

      final Finder hint = find.text('有新弹幕 ↓');
      expect(hint, findsOneWidget);
      final Text text = tester.widget<Text>(hint);
      expect(text.style?.fontSize, 12);
      expect(text.style?.color, AylaColors.textOnPink); // --text-on-pink

      final Finder pill = find
          .ancestor(of: hint, matching: find.byType(DecoratedBox))
          .first;
      final BoxDecoration decoration =
          tester.widget<DecoratedBox>(pill).decoration as BoxDecoration;
      expect(decoration.borderRadius, AylaRadii.pill);
      expect(decoration.boxShadow, AylaShadows.glow); // --glow-shadow
      // --bubble-elysia 135deg 渐变（cssLinearGradient）
      expect(
        (decoration.gradient! as LinearGradient).colors,
        AylaGradients.bubbleElysia,
      );
      // padding: sp1 sp3
      expect(
        find.ancestor(
          of: hint,
          matching: find.byWidgetPredicate(
            (Widget w) =>
                w is Padding &&
                w.padding ==
                    const EdgeInsets.symmetric(
                      horizontal: AylaSpacing.sp3,
                      vertical: AylaSpacing.sp1,
                    ),
          ),
        ),
        findsOneWidget,
      );

      // 位置：距 wrap 底 sp3、水平居中
      final Rect wrap = tester.getRect(find.byType(AylaDanmakuList));
      final Rect button = tester.getRect(pill);
      expect(wrap.bottom - button.bottom, AylaSpacing.sp3);
      expect(button.center.dx, closeTo(wrap.center.dx, 0.5));

      await tester.tap(hint);
      await tester.pump();
      expect(scrolls, 1);
    });

    testWidgets('hasNewBelow=false 时不渲染（tsx 121）', (WidgetTester tester) async {
      await tester.pumpWidget(
        host(
          tester,
          AylaDanmakuList(items: <AylaDanmakuEntry>[_entry('a', '观众A')]),
        ),
      );
      await settle(tester);
      expect(find.text('有新弹幕 ↓'), findsNothing);
    });
  });

  group('材质归调用方（组件自身永不持材质；用户 2026-09-22 裁决「就是卡片而已」）', () {
    testWidgets('组件子树内没有材质件：只有布局（app.css 3671–3676）', (WidgetTester tester) async {
      await tester.pumpWidget(
        host(tester, const AylaDanmakuList(items: <AylaDanmakuEntry>[])),
      );
      await settle(tester);
      expect(
        find.descendant(
          of: find.byType(AylaDanmakuList),
          matching: find.byType(GlassSurface),
        ),
        findsNothing,
      );
      // 默认不设 min-height（窄屏滑动单元才要 96，见 live.css 758/830）
      expect(
        find.byWidgetPredicate(
          (Widget w) => w is ConstrainedBox && w.constraints.minHeight == 96,
        ),
        findsNothing,
      );
    });

    testWidgets('minHeight=96 是**布局档**（窄屏滑动单元），不是材质', (WidgetTester tester) async {
      await tester.pumpWidget(
        host(
          tester,
          const AylaDanmakuList(
            items: <AylaDanmakuEntry>[],
            minHeight: 96,
          ),
        ),
      );
      await settle(tester);
      expect(
        find.byWidgetPredicate(
          (Widget w) => w is ConstrainedBox && w.constraints.minHeight == 96,
        ),
        findsOneWidget,
      );
      // 仍然没有材质：窄屏实渲染是透明的（live.css 830–838 清零 756–764 的玻璃）
      expect(
        find.descendant(
          of: find.byType(AylaDanmakuList),
          matching: find.byType(GlassSurface),
        ),
        findsNothing,
      );
    });

    testWidgets('宽屏：材质来自调用方卡片（`.live-room-side` 规格），列表自身仍无底', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        host(
          tester,
          Padding(
            padding: const EdgeInsets.all(AylaSpacing.sidebarGutter),
            child: GlassSurface(
              radiusOverride: BorderRadius.all(
                Radius.circular(AylaRadii.rCard),
              ),
              blur: AylaGlass.blurCard,
              child: const AylaDanmakuList(items: <AylaDanmakuEntry>[]),
            ),
          ),
        ),
      );
      await settle(tester);

      // 卡片在列表**外面**（祖先），列表子树内没有材质件
      expect(
        find.ancestor(
          of: find.byType(AylaDanmakuList),
          matching: find.byType(GlassSurface),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byType(AylaDanmakuList),
          matching: find.byType(GlassSurface),
        ),
        findsNothing,
      );
      final GlassSurface card = tester.widget<GlassSurface>(
        find.byType(GlassSurface),
      );
      expect(card.blur, AylaGlass.blurCard); // auroraqua 392–400：blur24 sat1.4
    });
  });

  group('历史控件（tsx 108）', () {
    testWidgets('作为列表**内部第一子元素**渲染（随内容滚动）', (WidgetTester tester) async {
      await tester.pumpWidget(
        host(
          tester,
          AylaDanmakuList(
            items: <AylaDanmakuEntry>[_entry('a', '观众A')],
            history: const AylaHistoryControlsData(
              hasMore: true,
              hasNewer: true,
            ),
          ),
        ),
      );
      await settle(tester);

      expect(find.byType(AylaHistoryControls), findsOneWidget);
      expect(find.text('加载更早记录'), findsOneWidget);
      expect(find.text('返回最新消息'), findsOneWidget);
      // 在滚动容器内部（不是悬浮在列表外）
      expect(
        find.ancestor(
          of: find.byType(AylaHistoryControls),
          matching: find.byType(SingleChildScrollView),
        ),
        findsOneWidget,
      );
      // 且在第一条弹幕**之上**
      expect(
        tester.getRect(find.byType(AylaHistoryControls)).bottom,
        lessThanOrEqualTo(
          tester.getRect(find.byKey(const ValueKey<String>('a'))).top,
        ),
      );
    });

    testWidgets('不传 history 时不渲染（web 可选 props）', (WidgetTester tester) async {
      await tester.pumpWidget(
        host(
          tester,
          AylaDanmakuList(items: <AylaDanmakuEntry>[_entry('a', '观众A')]),
        ),
      );
      await settle(tester);
      expect(find.byType(AylaHistoryControls), findsNothing);
    });
  });

  group('滚动上报（tsx 107 onScroll）', () {
    testWidgets('拖动列表 → onUserScroll 被调用（web 由元素自身上报）', (WidgetTester tester) async {
      int reports = 0;
      final List<AylaDanmakuEntry> many = <AylaDanmakuEntry>[
        for (int i = 0; i < 20; i += 1) _entry('e$i', '观众$i'),
      ];
      await tester.pumpWidget(
        host(
          tester,
          AylaDanmakuList(items: many, onUserScroll: () => reports += 1),
          viewport: const Size(420, 300),
        ),
      );
      await settle(tester);

      await tester.drag(
        find.byType(SingleChildScrollView),
        const Offset(0, -120),
      );
      await settle(tester);
      expect(reports, greaterThan(0));
    });
  });

  group('图片交互', () {
    testWidgets('就绪态点击 → 打开全屏查看器（root overlay，等价 web fixed 全屏）', (WidgetTester tester) async {
      aylaEnableSampleMedia(); // 示例图：走预览注入，直接就绪（不触签名）
      await tester.pumpWidget(
        host(
          tester,
          AylaDanmakuList(
            items: <AylaDanmakuEntry>[
              _entry('a', '观众A', content: '看图', mediaId: 'm1'),
            ],
          ),
        ),
      );
      await settle(tester);

      expect(find.byType(AylaImageViewer), findsNothing);
      await tester.tap(imageButton(), warnIfMissed: false);
      await settle(tester);
      expect(find.byType(AylaImageViewer), findsOneWidget);
    });

    testWidgets('失败态**照实渲染**：骨架铺满 + 点击=重试（不开查看器）', (WidgetTester tester) async {
      await tester.pumpWidget(
        host(
          tester,
          AylaDanmakuList(
            items: <AylaDanmakuEntry>[
              _entry('a', '观众A', content: '看图', mediaId: 'm1'),
            ],
          ),
        ),
      );
      await settle(tester);

      // 未注入 DioClient ⇒ 签名抛 StateError ⇒ 失败态；web 的 fallback 骨架铺满 96×64
      expect(find.byType(AylaSkeleton), findsAtLeastNWidgets(1));
      expect(find.byType(AylaImageViewer), findsNothing);
      // 语义标签按 web 的 enclosingControl 语义切换为「重试」
      expect(imageSemantics('看图：图片加载失败，重试'), findsOneWidget);
      final Key? before = tester
          .widget<ResourceImage>(find.byType(ResourceImage))
          .key;

      await tester.tap(imageButton(), warnIfMissed: false);
      await settle(tester);

      // 点击被路由到重试（重建 ResourceImage），且**不**打开查看器
      expect(find.byType(AylaImageViewer), findsNothing);
      final Key? after = tester
          .widget<ResourceImage>(find.byType(ResourceImage))
          .key;
      expect(after, isNot(before));
    });
  });
}
