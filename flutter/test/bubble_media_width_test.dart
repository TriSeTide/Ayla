/// 气泡媒体宽度回归锁（2026-10-22 二轮）—— **语音/文件/混排气泡被撑满整行**。
///
/// ## 用户实报
/// 1. 「web 的图片会按比例调整气泡尺寸」（Flutter 侧被撑到 75%/84% 上限）；
/// 2. 「语音气泡怎么会这么长」（1440 档真机截图 = 占满整行）。
///
/// ## 根因（本轮定位，复现后修）
/// 上一轮 `AylaCssFlexRow`（`widgets/base/css_flex_row.dart`）用**主轴无界测量**
/// （`const BoxConstraints()`）实现 CSS 的 `flex-basis: auto` = max-content。
/// 但媒体子树里存在 `Expanded`（CSS `flex: 1`）：
/// - 语音卡主行 `Row([play, sp3, Expanded(波形), sp3, 时长])`
///   （= web `app.css:1529–1557` 的 `.voice-card-main` + `.voice-wave{flex:1}`）；
/// - 语音卡进度行 `Row([Expanded(Slider), sp2, 当前时长])`（`.voice-seek{flex:1}`）；
/// - 文件卡 `.file-info{flex:1}`。
///
/// CSS 在 **intrinsic 趟**里让 `flex:1` 项贡献**自身 max-content**；Flutter 的
/// `Expanded` 没有这一档 —— 无界主轴下 `RenderFlex` 直接断言，而「被
/// `ConstrainedBox(maxWidth: 75%)` 包住」的写法会退化成「拿上限当内容宽」
/// ⇒ 媒体卡横贯整行。
///
/// ## 修法（语义对齐 CSS 的两趟布局）
/// - `widgets/base/fit_content.dart` 新增 **[AylaFitContent]**：先无界主轴布局一次
///   拿 max-content，再 clamp(`min-width`/`max-width`/可用宽) 后按最终宽重排 ——
///   等价 CSS 的 `width: fit-content`（不用 `IntrinsicWidth` 是因为媒体子树含
///   `LayoutBuilder`，Flutter 不支持对其求 intrinsic）；
/// - **[AylaInlineSize]**：`flex:1` 的「有界占满 / 无界取 max-content」；
/// - **[AylaInlineNaturalSize]**：同上，但无界档取**子级自然宽**（文件名等动态内容）。
///
/// ## 期望值来源（浏览器实测，不是推算）
/// 对账台 `tool/web_media_measure.html` 用 `file://` 加载 web 四份 CSS（与
/// `main.tsx` 同序）+ 与 `MediaContent.tsx` **逐分支同构**的 DOM，字体换成与
/// Flutter 侧同一批 TTF；Playwright（系统 Chrome）在 375/480/900/1440 四档 +
/// 「2400 宽 + 取消 .message-column 的 960 上限」的 max-content 档读
/// `getBoundingClientRect()`。结果存 `tool/web_media_expected.json`。
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show FontLoader, rootBundle;
import 'package:flutter_test/flutter_test.dart';

import '../lib/core/models/chat_message.dart';
import '../lib/core/models/media_kind.dart';
import '../lib/core/models/post.dart' show AylaMediaDescriptor;
import '../lib/theme/preview_theme.dart';
import '../lib/theme/sample_media.dart';
import '../lib/theme/tokens.dart';
import '../lib/widgets/base/fit_content.dart';
import '../lib/widgets/chat/message_bubble.dart';

AylaMediaDescriptor _media({
  String id = 'm1',
  AylaMediaKind kind = AylaMediaKind.image,
  String mime = 'image/png',
  int? width,
  int? height,
  double? duration,
  bool thumbnail = false,
  bool waveform = false,
  int size = 240000,
}) =>
    AylaMediaDescriptor(
      mediaId: id,
      kind: kind,
      mimeType: mime,
      size: size,
      width: width,
      height: height,
      duration: duration,
      thumbnail: thumbnail ? '/api/v1/media/$id/thumbnail' : null,
      waveform: waveform ? '/api/v1/media/$id/waveform' : null,
      status: 'ready',
    );

AylaChatMessage _msg({
  String id = 'm1',
  AylaMessageType type = AylaMessageType.image,
  AylaMediaDescriptor? media,
  List<AylaMediaSegment> segments = const <AylaMediaSegment>[],
  String content = '',
  String senderId = 'u1',
}) =>
    AylaChatMessage(
      id: id,
      conversationId: 'c1',
      senderId: senderId,
      type: type,
      content: content,
      mediaId: media?.mediaId,
      media: media,
      segments: segments,
      status: AylaMessageStatus.sent,
      seq: 1,
      // 落在 120s 撤回窗口内（与对账台口径一致：工具栏恒渲染）
      createdAt: DateTime.now()
          .subtract(const Duration(seconds: 30))
          .toUtc()
          .toIso8601String(),
    );

Future<void> _loadFonts() async {
  const List<List<String>> families = <List<String>>[
    <String>['Nunito', 'Nunito_400Regular.ttf'],
    <String>['Nunito', 'Nunito_600SemiBold.ttf'],
    <String>['Nunito', 'Nunito_700Bold.ttf'],
    <String>['Space Grotesk', 'SpaceGrotesk_400Regular.ttf'],
    <String>['Fredoka', 'Fredoka_500Medium.ttf'],
  ];
  for (final List<String> f in families) {
    final ByteData data = await rootBundle.load('assets/fonts/${f[1]}');
    final FontLoader loader = FontLoader(f[0])
      ..addFont(Future<ByteData>.value(data));
    await loader.load();
  }
}

void main() {
  setUp(aylaDisableSampleMedia);

  /// 与对账台**完全同构**的消息列几何：`.message-scroll`（宽屏 padding sp6 /
  /// 窄屏 sp4 sp3）→ `.message-column`（max-width 960，居中）→ 行。
  Future<void> pumpBubble(WidgetTester tester, Widget bubble, Size size) async {
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
                child: SingleChildScrollView(
                  padding: AylaBreakpoints.isNarrow(size.width)
                      ? const EdgeInsets.symmetric(
                          horizontal: AylaSpacing.sp3,
                          vertical: AylaSpacing.sp4,
                        )
                      : const EdgeInsets.all(AylaSpacing.sp6),
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
    // 媒体帧/语音卡有异步 descriptor 与动画 ⇒ 多 pump 两拍（不用 pumpAndSettle：
    // 语音波形骨架有无限动画时它会超时）。
    await tester.pump(const Duration(milliseconds: 120));
    await tester.pump(const Duration(milliseconds: 120));
  }

  /// 气泡外框（`.bubble`，即最外层 ClipRRect）。
  Rect bubbleRect(WidgetTester tester) => tester.getRect(
        find
            .descendant(
              of: find.byType(AylaMessageBubble),
              matching: find.byType(ClipRRect),
            )
            .first,
      );

  // ================================================================
  // 一、语音气泡：必须是 min-width 撑开的**窄卡**，不是整行
  // ================================================================
  //
  // web 实测（`tool/web_media_expected.json`）：
  // | 档   | .bubble | .voice-card |
  // | 375  | 214.31  | 240（被气泡裁掉一截 —— min-width 压过可用宽） |
  // | 480  | 266.19  | 256.19 |
  // | 900  | 266.19  | 256.19 |
  // | 1440 | 266.19  | 256.19 |
  //
  // Flutter 侧同字体实测 264.19（Δ −2.00）—— 差值来自 `.voice-duration` 的
  // 文本度量（web 24.19 / Flutter 22.19，同一 TTF 但 Space Grotesk 的数字
  // advance 在 Skia 与 Blink 上差 0.1px/字符）。
  // ⚠️ **375 档的容差更大，原因是字体而不是布局**：
  // 375 档工具栏（`.msg-actions`）会被 `flex-shrink` 压窄，而压缩分配比例
  // 取决于 **工具栏的自然宽**（含中文标签「引用」/「撤回」的度量）。测试引擎
  // 没有系统 CJK 字体 ⇒ 标签走引擎内置回退，自然宽比浏览器小（实测 82 vs 94）
  // ⇒ 气泡分到的收缩量略多 6px。这与 `css_flex_row_test.dart` 文件头登记的
  // 「测试里工具栏自然宽 132 而非 web 155.2」**同一个已知度量差**，不是布局差。
  // 480/900/1440 三档空间充足（工具栏不收缩）⇒ 逐像素对齐。
  for (final List<double> c in <List<double>>[
    <double>[375, 214.31],
    <double>[480, 266.19],
    <double>[900, 266.19],
    <double>[1440, 266.19],
  ]) {
    testWidgets('★ peer 语音气泡 @ ${c[0].toInt()} 档（web 实测同值）', (
      WidgetTester tester,
    ) async {
      await _loadFonts();
      await pumpBubble(
        tester,
        AylaMessageBubble(
          msg: _msg(
            type: AylaMessageType.voice,
            media: _media(
              id: 'mv',
              kind: AylaMediaKind.voice,
              mime: 'audio/ogg',
              duration: 12,
              waveform: true,
            ),
          ),
          isSelf: false,
          senderAvatarLabel: 'x',
          onQuote: (_) {},
        ),
        Size(c[0], 1400),
      );
      // 375 档容差 8（CJK 度量差，见上）；其余三档 2.5。
      expect(bubbleRect(tester).width, closeTo(c[1], c[0] == 375 ? 8 : 2.5),
          reason: '★ 语音气泡宽须与浏览器实测同值（≈240 min-width 的窄卡）');
    });
  }

  testWidgets('★ 1440 档语音气泡 **不得**等于 84%/75% 上限（本轮回归的直接判据）', (
    WidgetTester tester,
  ) async {
    await _loadFonts();
    await pumpBubble(
      tester,
      AylaMessageBubble(
        msg: _msg(
          type: AylaMessageType.voice,
          media: _media(
            id: 'mv',
            kind: AylaMediaKind.voice,
            mime: 'audio/ogg',
            duration: 12,
            waveform: true,
          ),
        ),
        isSelf: false,
        senderAvatarLabel: 'x',
        onQuote: (_) {},
      ),
      const Size(1440, 1400),
    );
    final double bubbleW = bubbleRect(tester).width;
    // .msg-row 的 content box（= 1440 − 2×sp6 = 1392，再被 .message-column 夹到 960）
    // → 减去 .msg-row 的 padding（sp1×2）后 × 0.75 = 714。
    expect(bubbleW, lessThan(714 - 100),
        reason: '★ 修复前 1440 档语音气泡 = 714（= 75% 上限）；必须是 ≈266 的窄卡');
  });

  testWidgets('★ 语音波形宽 = 144（.voice-wave{flex:1} 在 max-content 档的内容宽）', (
    WidgetTester tester,
  ) async {
    await _loadFonts();
    await pumpBubble(
      tester,
      AylaMessageBubble(
        msg: _msg(
          type: AylaMessageType.voice,
          media: _media(
            id: 'mv',
            kind: AylaMediaKind.voice,
            mime: 'audio/ogg',
            duration: 12,
            waveform: true,
          ),
        ),
        isSelf: false,
        senderAvatarLabel: 'x',
        onQuote: (_) {},
      ),
      const Size(1440, 1400),
    );
    // 波形 PNG 固有 480×120（后端 derivatives.py），高度钉 36 ⇒ 36×480/120 = 144。
    // 浏览器实测 .voice-wave 宽 144（budget 见 constants 注释）。
    final Finder wave = find.byType(AylaInlineSize);
    expect(wave, findsWidgets);
    final List<double> ws = <double>[
      for (final Element e in wave.evaluate())
        (e.renderObject! as RenderBox).size.width,
    ];
    expect(ws, contains(144.0),
        reason: '★ .voice-wave 的 max-content 宽必须是 144（= 36 × 480/120）');
  });

  // ================================================================
  // 二、图片气泡：算法本来就对（aylaMediaFrameSize），要证明它**真正生效**
  // ================================================================
  //
  // web `MediaContent.tsx:86–97` mediaFrameStyle：
  //   scale = min(320/w, 320/h, 1) ⇒ 长边 ≤320、小图不放大；
  // bubble 宽 = 图宽 + `.bubble-media` padding sp1（4×2）+ 边框 1×2。
  // web 实测 640×480 → 330、480×640 → 250、100×100 → 110、emoji → 106。
  for (final List<double> c in <List<double>>[
    // [源宽, 源高, 期望气泡宽(web 实测)]
    <double>[640, 480, 330],
    <double>[480, 640, 250],
    <double>[100, 100, 110],
  ]) {
    testWidgets('★ 图片 ${c[0].toInt()}×${c[1].toInt()} @ 1440 档（按比例，非上限）', (
      WidgetTester tester,
    ) async {
      await _loadFonts();
      aylaEnableSampleMedia();
      addTearDown(aylaDisableSampleMedia);
      await pumpBubble(
        tester,
        AylaMessageBubble(
          msg: _msg(
            type: AylaMessageType.image,
            media: _media(
              id: 'mi',
              width: c[0].toInt(),
              height: c[1].toInt(),
              thumbnail: true,
            ),
          ),
          isSelf: false,
          senderAvatarLabel: 'x',
          onQuote: (_) {},
        ),
        const Size(1440, 1400),
      );
      final Rect b = bubbleRect(tester);
      expect(b.width, closeTo(c[2], 3),
          reason: '★ 图片气泡宽 = 图宽 + 媒体气泡 padding/border，不是 714 上限');
      expect(b.width, lessThan(714 - 100),
          reason: '★ 必须按比例收缩，不得撑到 75% 上限');
    });
  }

  testWidgets('★ 表情气泡 @ 1440 档 = 106（96 + padding；固定 96，不放大）', (
    WidgetTester tester,
  ) async {
    await _loadFonts();
    aylaEnableSampleMedia();
    addTearDown(aylaDisableSampleMedia);
    await pumpBubble(
      tester,
      AylaMessageBubble(
        msg: _msg(
          type: AylaMessageType.emoji,
          media: _media(
            id: 'me',
            kind: AylaMediaKind.emoji,
            width: 240,
            height: 240,
          ),
        ),
        isSelf: false,
        senderAvatarLabel: 'x',
        onQuote: (_) {},
      ),
      const Size(1440, 1400),
    );
    expect(bubbleRect(tester).width, closeTo(106, 3),
        reason: '★ .media-emoji { width:96px }（app.css:1505–1509）+ 媒体气泡 padding');
  });

  // ================================================================
  // 三、视频 / 文件 / 混排（全库同类排查的回归锁）
  // ================================================================
  //
  // web 实测（1440 档）：video 1280×720 → 330；file → 276.73；mixed → 378。
  testWidgets('★ 视频气泡 1280×720 @ 1440 档 = 330（320 + padding）', (
    WidgetTester tester,
  ) async {
    await _loadFonts();
    aylaEnableSampleMedia();
    addTearDown(aylaDisableSampleMedia);
    await pumpBubble(
      tester,
      AylaMessageBubble(
        msg: _msg(
          type: AylaMessageType.video,
          media: _media(
            id: 'v1',
            kind: AylaMediaKind.video,
            mime: 'video/mp4',
            width: 1280,
            height: 720,
            thumbnail: true,
          ),
        ),
        isSelf: false,
        senderAvatarLabel: 'x',
        onQuote: (_) {},
      ),
      const Size(1440, 1400),
    );
    expect(bubbleRect(tester).width, closeTo(330, 3),
        reason: '★ 视频帧 scale = min(320/1280, 320/720) = 0.25 ⇒ 320×180');
  });

  testWidgets('★ 文件气泡 @ 1440 档 ≈ 277（.file-card 240–320 的内容宽，不是 714）', (
    WidgetTester tester,
  ) async {
    await _loadFonts();
    await pumpBubble(
      tester,
      AylaMessageBubble(
        msg: _msg(
          type: AylaMessageType.file,
          media: _media(
            id: 'f1',
            kind: AylaMediaKind.file,
            mime: 'application/pdf',
          ),
        ),
        isSelf: false,
        senderAvatarLabel: 'x',
        onQuote: (_) {},
      ),
      const Size(1440, 1400),
    );
    final double w = bubbleRect(tester).width;
    // web 实测 276.73（文件名用中文字体，Flutter 测试引擎无 CJK ⇒ 自然宽可能更窄，
    // 故断言区间：必须落在 .file-card 的 240–320 区间 + 媒体气泡 padding/border，
    // 且**远小于** 75% 上限）。
    expect(w, greaterThan(240), reason: '★ 不得窄于 .file-card 的 min-width 240');
    expect(w, lessThan(320 + 20),
        reason: '★ 不得宽于 .file-card 的 max-width 320 + padding/border');
    expect(w, lessThan(714 - 100),
        reason: '★ 修复前是 328（被 .msg-body 上限撑满），必须回到卡片自身内容宽');
  });

  testWidgets('★ 混排气泡 @ 1440 档 = 内容宽（180 方块 + 文本），不是 714', (
    WidgetTester tester,
  ) async {
    await _loadFonts();
    aylaEnableSampleMedia();
    addTearDown(aylaDisableSampleMedia);
    await pumpBubble(
      tester,
      AylaMessageBubble(
        msg: _msg(
          type: AylaMessageType.mixed,
          segments: <AylaMediaSegment>[
            const AylaMediaSegment(type: AylaSegmentType.text, text: 'hey'),
            AylaMediaSegment(
              type: AylaSegmentType.image,
              mediaId: 'mi',
              media: _media(id: 'mi', width: 640, height: 480, thumbnail: true),
            ),
          ],
        ),
        isSelf: false,
        senderAvatarLabel: 'x',
        onQuote: (_) {},
      ),
      const Size(1440, 1400),
    );
    expect(bubbleRect(tester).width, lessThan(714 - 100),
        reason: '★ 混排媒体段固定 180 方块（app.css:1958–1961），气泡按内容收缩');
  });

  // ================================================================
  // 四、接线锁：生产代码必须真的用 fit-content / inline-size 原语
  // ================================================================
  test('★ 接线：语音卡走 AylaFitContent + AylaInlineSize（不得退回 Expanded）', () {
    final String src =
        File('lib/widgets/chat/media_content.dart').readAsStringSync();
    expect(src.contains('return AylaFitContent('), isTrue,
        reason: '★ 语音卡必须 fit-content 收缩（CSS width:fit-content 等价）');
    expect(
      RegExp(r'AylaInlineSize\(\s*minWidth: wave == null').hasMatch(src),
      isTrue,
      reason: '★ .voice-wave{flex:1} 必须用「有界占满/无界取 max-content」原语',
    );
    expect(
      src.contains('minWidth: kAylaVoiceSeekNaturalWidth'),
      isTrue,
      reason: '★ .voice-seek{flex:1} 同主行',
    );
    // 反例锁：语音卡主行/进度行不得再用裸 Expanded（无界测量下会撑满）
    final int voiceStart = src.indexOf('class _VoiceMediaState');
    final int voiceEnd = src.indexOf('class _VoicePlayButton', voiceStart);
    expect(voiceStart, greaterThan(0));
    final String voiceBody = src.substring(voiceStart, voiceEnd);
    // 只认**代码形态**（行首缩进后的 `Expanded(`）；注释里提到它不算。
    expect(
      RegExp(r'^\s*Expanded\(', multiLine: true).hasMatch(voiceBody),
      isFalse,
      reason: '★ 语音卡内不得用 Expanded：无界主轴测量下会把 75% 上限当内容宽',
    );
  });

  test('★ 接线：文件卡的 .file-info{flex:1} 用 AylaInlineNaturalSize', () {
    final String src =
        File('lib/widgets/chat/media_content.dart').readAsStringSync();
    final int start = src.indexOf('class _FileCard');
    expect(start, greaterThan(0));
    final String body = src.substring(start);
    expect(body.contains('AylaInlineNaturalSize('), isTrue,
        reason: '★ .file-info{flex:1} 的动态内容宽必须走自然宽原语');
    expect(
      RegExp(r'^\s*Expanded\(', multiLine: true).hasMatch(body),
      isFalse,
      reason: '★ 文件卡内不得用 Expanded（同上）',
    );
  });

  test('★ 原语语义：AylaFitContent = clamp(max-content, min, 可用宽)', () {
    // 直接锁 CSS fit-content 的三条边界，防止后续改动把语义弄坏。
    // 由三档 widget 用例覆盖（见 `test/fit_content_test.dart`），这里只锁接线名。
    final String src =
        File('lib/widgets/base/fit_content.dart').readAsStringSync();
    expect(src.contains('class AylaFitContent'), isTrue);
    expect(src.contains('class AylaInlineSize'), isTrue);
    expect(src.contains('class AylaInlineNaturalSize'), isTrue);
  });
}
