/// 气泡布局对账回归锁（2026-10-22）—— 用户实报三类问题：
/// ①「有的气泡长有的气泡短」②「工具栏不会自适应挤压」③「图片被拉伸」。
///
/// ## 事实源与测量方法
///
/// 本文件所有期望值来自**真实浏览器实测**，不是从 CSS 推算：
/// - 对账台 `tool/web_bubble_measure.html` 用 `file://` 加载 web 的四份 CSS
///   （tokens/base/app/auroraqua，与 `main.tsx` 同序）+ 与 `MessageBubble.tsx`
///   同构的 DOM，字体换成与 Flutter 侧**同一批 TTF**（`assets/fonts/*`）⇒ 字体度量一致；
/// - Playwright（系统 Chrome）读 `getBoundingClientRect()`，375/480/900/1440 四档；
/// - Flutter 侧用本文件的同构 widget 树量同样的 rect。
///
/// ⇒ 差值只反映**布局**，不掺字体差异。
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show FontLoader, rootBundle;
import 'package:flutter_test/flutter_test.dart';

import '../lib/core/models/chat_message.dart';
import '../lib/core/models/media_kind.dart';
import '../lib/core/models/post.dart' show AylaMediaDescriptor;
import '../lib/theme/buttons.dart' show AylaMsgActionButton;
import '../lib/theme/preview_theme.dart';
import '../lib/theme/sample_media.dart';
import '../lib/theme/tokens.dart';
import '../lib/widgets/base/avatar_halo.dart';
import '../lib/widgets/base/css_flex_row.dart';
import '../lib/widgets/base/resource_image.dart';
import '../lib/widgets/chat/message_bubble.dart';

/// ⚠️ 数值断言必须用**拉丁文本**：Nunito 字体在两侧已对齐（同一个 TTF），
/// 而 CJK 走系统回退字体（Flutter 测试引擎无系统字体表 / web 用浏览器回退链），
/// 度量天然不同 —— 那是**字体类差异**，不是布局差异，不能用它断言像素。
const String _kLong =
    'This is a fairly long message used to measure the max bubble width so we can check whether the 75 percent cap is applied against the right base box.';


AylaChatMessage _msg({
  String id = 'm1',
  AylaMessageType type = AylaMessageType.text,
  String content = '你好',
  String senderId = 'u1',
  AylaMediaDescriptor? media,
}) =>
    AylaChatMessage(
      id: id,
      conversationId: 'c1',
      senderId: senderId,
      type: type,
      content: content,
      mediaId: media?.mediaId,
      media: media,
      status: AylaMessageStatus.sent,
      seq: 1,
      // 落在 120s 撤回窗口内（web 对账台恒渲染「撤回」键，口径必须一致）
      createdAt: DateTime.now()
          .subtract(const Duration(seconds: 30))
          .toUtc()
          .toIso8601String(),
    );

AylaMediaDescriptor _image({int w = 640, int h = 480}) => AylaMediaDescriptor(
      mediaId: 'm-img',
      kind: AylaMediaKind.image,
      mimeType: 'image/png',
      size: 240000,
      width: w,
      height: h,
      thumbnail: '/api/v1/media/m-img/thumbnail',
      status: 'ready',
    );

/// 与 web 对账台**同一批字体**（字体度量一致 ⇒ 差异只剩布局）。
Future<void> _loadFonts() async {
  const List<List<String>> families = <List<String>>[
    <String>['Nunito', 'Nunito_400Regular.ttf'],
    <String>['Nunito', 'Nunito_600SemiBold.ttf'],
    <String>['Nunito', 'Nunito_700Bold.ttf'],
    <String>['Space Grotesk', 'SpaceGrotesk_400Regular.ttf'],
    <String>['Fredoka', 'Fredoka_500Medium.ttf'],
  ];
  for (final List<String> f in families) {
    final ByteData data = await rootBundle.load('assets/fonts/' + f[1]);
    final FontLoader loader = FontLoader(f[0])
      ..addFont(Future<ByteData>.value(data));
    await loader.load();
  }
}

void main() {
  setUp(aylaDisableSampleMedia);

  Future<void> pumpBubble(
    WidgetTester tester,
    Widget bubble,
    Size size, {
    EdgeInsets? padding,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        home: previewScope(
          Builder(
            builder: (BuildContext context) => MediaQuery(
              data: MediaQuery.of(context).copyWith(size: size),
              child: SizedBox(
                width: size.width,
                height: size.height,
                // 与 web 同构的「消息列」：`.message-scroll`（padding sp6 / 窄屏 sp4 sp3）
                // → `.message-column`（max-width 960，居中）→ 行。
                // 对账台的期望值就是这套几何下测出来的，重建不一致会引入假差值。
                child: SingleChildScrollView(
                  padding: padding ??
                      (AylaBreakpoints.isNarrow(size.width)
                          ? const EdgeInsets.symmetric(
                              horizontal: AylaSpacing.sp3,
                              vertical: AylaSpacing.sp4,
                            )
                          : const EdgeInsets.all(AylaSpacing.sp6)),
                  child: Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 960),
                      child: bubble,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// `.msg-row` content box × 比例（web 的百分比基数）。
  double rowInnerLimit(WidgetTester tester, double viewportWidth, double ratio) {
    final Rect row = tester.getRect(find.byType(AylaMessageBubble));
    return row.width * ratio;
  }

  Rect bubbleRect(WidgetTester tester, String text) => tester.getRect(
        find.ancestor(of: find.text(text), matching: find.byType(ClipRRect)).first,
      );

  // ================================================================
  // ③ 图片被拉伸（用户实报）—— 根因在**解码层**，不在 fit 层
  // ================================================================
  //
  // resource_image.dart 曾把 cacheWidth + cacheHeight **同时**传给
  // Image.network/file，而这两个参数经 ImageProvider.resizeIfNeeded
  // （flutter/lib/src/painting/image_provider.dart:1306–1315）落到
  // ResizeImagePolicy.exact。exact 的文档原话（同文件 :838–851）：
  //   "If width and height are both non-null, the output image will have the specified
  //    width and height regardless of whether it matches the source image's intrinsic
  //    aspect ratio. This case is similar to BoxFit.fill."
  // ⇒ 解码缓冲被压成显示框宽高比，出图再 BoxFit.cover 也救不回来。
  //
  // 断言口径：布局矩形一直是对的（这正是该 bug 长期没被测出的原因），
  // 所以要锁**解码维度只挑一条边**这一实现约束。

  test('★ 解码维度只挑一条边（否则 exact 策略压变宽高比）', () {
    final String src =
        File('lib/widgets/base/resource_image.dart').readAsStringSync();
    expect(
      src.contains('if (widget.width == null && widget.height == null) {'),
      isTrue,
      reason: '★ 解码维度必须走「只挑一条边」分支（见 resource_image.dart 注释）',
    );
    expect(
      src.contains('ResizeImagePolicy.exact'),
      isTrue,
      reason: '★ 注释里必须写明 exact 陷阱（image_provider.dart:838–851）',
    );
    // 反向锁：不得回到「两个维度各自独立算」的老写法
    expect(
      RegExp(r'final int\? decodeW = widget\.width == null').hasMatch(src),
      isFalse,
      reason: '★ 老写法会让 exact 压变宽高比 ⇒ 图片拉伸',
    );
  });
  // ================================================================
  // ① 气泡宽度：「短消息不被撑宽」+「长消息不超过 web 的 75% 上限」
  // ================================================================
  //
  // web 事实源：.msg-body { max-width: 75%; min-width: 0 }（app.css:1073–1083）
  // + 注释原文「子项按自身内容宽度排列，禁止 stretch：否则对方消息的气泡会被
  //   .bubble-meta 时间文本撑到整行宽度，导致短消息气泡长短不一、偏宽」。
  // 窄屏 84%（app.css:3217–3219）。

  testWidgets('★ 短消息气泡 = 内容宽（不被 meta 撑宽）', (
    WidgetTester tester,
  ) async {
    await _loadFonts();
    await pumpBubble(
      tester,
      AylaMessageBubble(
        msg: _msg(content: 'Hi'),
        isSelf: false,
        senderAvatarLabel: 'x',
        onQuote: (_) {},
      ),
      const Size(900, 600),
    );
    final Rect bubble = bubbleRect(tester, 'Hi');
    // web 实测（900 档，同字体）：bubble=44.91（= 文本 14.91 + padding 28 + border 2）
    expect(bubble.width, lessThan(120),
        reason: '★ 短消息气泡按内容收缩（web 实测 44.91），不得被 75% 上限撑宽');
    expect(bubble.width, greaterThan(20));
  });

  testWidgets('★ 长消息气泡 = 75% 上限（web 900 档实测 633）', (
    WidgetTester tester,
  ) async {
    await _loadFonts();
    await pumpBubble(
      tester,
      AylaMessageBubble(
        msg: _msg(content: _kLong),
        isSelf: false,
        senderAvatarLabel: 'x',
        onQuote: (_) {},
      ),
      const Size(900, 600),
    );
    final Rect bubble = bubbleRect(tester, _kLong);
    expect(bubble.width, closeTo(633, 4),
        reason: '★ 长消息上限须与 web 同值（app.css:1073–1083 的 75%）');
  });

  testWidgets('★ 短消息气泡宽 < 长消息气泡宽（用户实报「有的长有的短」）', (
    WidgetTester tester,
  ) async {
    await _loadFonts();
    const Size size = Size(900, 1400);
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        home: previewScope(
          Builder(
            builder: (BuildContext c) => MediaQuery(
              data: MediaQuery.of(c).copyWith(size: size),
              child: SizedBox(
                width: size.width,
                height: size.height,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    AylaMessageBubble(
                      key: const ValueKey<String>('short'),
                      msg: _msg(id: 's', content: 'Hi'),
                      isSelf: false,
                      senderAvatarLabel: 'x',
                      onQuote: (_) {},
                    ),
                    AylaMessageBubble(
                      key: const ValueKey<String>('long'),
                      msg: _msg(id: 'l', content: _kLong),
                      isSelf: false,
                      senderAvatarLabel: 'x',
                      onQuote: (_) {},
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    double widthOf(String key, String text) => tester
        .getRect(find
            .ancestor(
              of: find.descendant(
                of: find.byKey(ValueKey<String>(key)),
                matching: find.text(text),
              ),
              matching: find.byType(ClipRRect),
            )
            .first)
        .width;
    final double shortW = widthOf('short', 'Hi');
    final double longW = widthOf('long', _kLong);
    expect(shortW, lessThan(longW),
        reason: '★ 短消息必须比长消息窄（否则就是「长短不一 / 被撑宽」）');
    expect(longW - shortW, greaterThan(100));
  });
  // ================================================================
  // ② 工具栏自适应挤压
  // ================================================================
  //
  // web 事实源：.msg-row { display:flex; align-items:flex-end; gap:var(--sp-2) }
  // （app.css:1041–1046）+ .msg-body { max-width:75%; min-width:0 }（1073–1083）
  // + .msg-actions { display:flex; gap:var(--sp-1) }（1290–1298）。
  // **实测结论（2026-10-22）**：web 里操作栏就是主轴普通子项
  // （探测 getComputedStyle(.msg-actions).position === 'static'，不是 absolute）
  // ⇒ 与 Flutter 的 Row 子项语义一致，挤压关系必须一致。

  testWidgets('★ 工具栏与气泡同行：自己行工具栏在气泡左侧（row-reverse）', (
    WidgetTester tester,
  ) async {
    await _loadFonts();
    await pumpBubble(
      tester,
      AylaMessageBubble(
        msg: _msg(content: 'OK', senderId: 'me'),
        isSelf: true,
        senderAvatarLabel: 'me',
        currentUserId: 'me',
        onQuote: (_) {},
        onRecall: (_) {},
      ),
      const Size(900, 600),
    );
    final Finder actBtn = find.byType(AylaMsgActionButton);
    expect(actBtn, findsWidgets, reason: '自己行且 120s 内 ⇒ 工具栏应渲染');
    final Rect actions = tester.getRect(
        find.ancestor(of: actBtn.first, matching: find.byType(AylaCssFlexRow)).first);
    final Rect bubble = bubbleRect(tester, 'OK');
    expect(actions.right, lessThanOrEqualTo(bubble.left + 1),
        reason: '★ 自己的工具栏在气泡**左侧**（.msg-row.self row-reverse，app.css:1069–1071）');
    final Rect halo = tester.getRect(find.byType(AylaAvatarHalo));
    expect(halo.left, greaterThan(bubble.right - 1),
        reason: '★ 自己的头像在最右（row-reverse 把主轴起点移到右侧）');
  });

  testWidgets('★ 窄屏 375 长消息：气泡宽对齐 web 且不溢出', (
    WidgetTester tester,
  ) async {
    await _loadFonts();
    await pumpBubble(
      tester,
      AylaMessageBubble(
        msg: _msg(content: _kLong, senderId: 'me'),
        isSelf: true,
        senderAvatarLabel: 'me',
        currentUserId: 'me',
        onQuote: (_) {},
        onRecall: (_) {},
      ),
      const Size(375, 700),
    );
    final Rect bubble = bubbleRect(tester, _kLong);
    // web 实测（375 档，`tool/web_bubble_measure.html` + Playwright）：
    //  · self-long（渲染 收藏+引用+撤回）= **183**
    //  · self-long（不渲染操作栏）= 288.29
    // `.msg-actions` 被 `flex-shrink:1` 压到 107.2（3 键各 33.6 + gap 4×2）。
    //
    // 2026-10-22 补：Flutter 侧改走自写的 [AylaCssFlexRow]（CSS flex-shrink
    // 语义）后，本档实测 **182.80**（Δ 0.20，来自文本测量差）—— 该用例原来锁的
    // 158 是「不收缩」时代的旧基线，随实现更新为与 web 同值。
    expect(bubble.width, closeTo(183, 2),
        reason: '★ 窄屏长消息气泡宽须与 web 同值（flex-shrink 语义已对齐）');
    expect(bubble.width, lessThan(rowInnerLimit(tester, 375, 0.84) + 1),
        reason: '★ 不得超过 84% 上限（app.css:3217–3219）');
    expect(tester.takeException(), isNull,
        reason: '★ 不得溢出（Row 被挤压时的经典症状）');
  });

  testWidgets('★ 工具栏按钮不换行、不重叠（web 单行 flex）', (
    WidgetTester tester,
  ) async {
    await _loadFonts();
    await pumpBubble(
      tester,
      AylaMessageBubble(
        msg: _msg(content: 'OK', senderId: 'me'),
        isSelf: true,
        senderAvatarLabel: 'me',
        currentUserId: 'me',
        onQuote: (_) {},
        onRecall: (_) {},
      ),
      const Size(375, 700),
    );
    final int n = find.byType(AylaMsgActionButton).evaluate().length;
    expect(n, greaterThanOrEqualTo(2), reason: '传了 onQuote + onRecall ⇒ 两个按钮');
    final List<Rect> btns = <Rect>[
      for (int i = 0; i < n; i++)
        tester.getRect(find.byType(AylaMsgActionButton).at(i)),
    ];
    final double cy = btns.first.center.dy;
    for (final Rect r in btns) {
      expect(r.center.dy, closeTo(cy, 1.5),
          reason: '★ 按钮必须同一行（不换行、不错位）');
    }
    for (int i = 1; i < btns.length; i++) {
      expect(btns[i].left, greaterThanOrEqualTo(btns[i - 1].right - 1),
          reason: '★ 相邻按钮不得重叠');
    }
  });
  // ================================================================
  // ③ 图片帧布局 —— 与 web mediaFrameStyle 同算法
  // ================================================================
  // web 事实源：MediaContent.tsx:86–97 —— scale = min(320/w, 320/h, 1)（不放大），
  // 容器发送即占最终尺寸（width + aspect-ratio），图片 object-fit: cover
  // （app.css:1474–1480）⇒ 显示比例 = 原图比例，不裁不拉。

  testWidgets('★ 图片帧 640×480 → 320×240（4:3，不放大）', (
    WidgetTester tester,
  ) async {
    aylaEnableSampleMedia();
    addTearDown(aylaDisableSampleMedia);
    await pumpBubble(
      tester,
      AylaMessageBubble(
        msg: _msg(type: AylaMessageType.image, content: '', media: _image()),
        isSelf: false,
        senderAvatarLabel: 'x',
      ),
      const Size(900, 700),
    );
    final Rect frame = tester.getRect(find.byType(AylaResourceImage).first);
    expect(frame.width, closeTo(320, 1), reason: '★ 长边压到 320 且不放大');
    expect(frame.height, closeTo(240, 1));
    expect(frame.width / frame.height, closeTo(640 / 480, 0.001),
        reason: '★ 帧宽高比必须等于原图宽高比（拉伸的直接判据）');
  });

  testWidgets('★ 竖图 480×640 → 240×320（3:4）', (
    WidgetTester tester,
  ) async {
    aylaEnableSampleMedia();
    addTearDown(aylaDisableSampleMedia);
    await pumpBubble(
      tester,
      AylaMessageBubble(
        msg: _msg(
            type: AylaMessageType.image,
            content: '',
            media: _image(w: 480, h: 640)),
        isSelf: false,
        senderAvatarLabel: 'x',
      ),
      const Size(900, 700),
    );
    final Rect frame = tester.getRect(find.byType(AylaResourceImage).first);
    expect(frame.width, closeTo(240, 1));
    expect(frame.height, closeTo(320, 1));
    expect(frame.width / frame.height, closeTo(480 / 640, 0.001));
  });
}