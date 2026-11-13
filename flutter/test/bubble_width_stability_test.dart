library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show FontLoader, rootBundle;
import 'package:flutter_test/flutter_test.dart';
import 'dart:typed_data';

import '../lib/core/models/chat_message.dart';
import '../lib/core/models/media_kind.dart';
import '../lib/core/models/post.dart' show AylaMediaDescriptor;
import '../lib/theme/preview_theme.dart';
import '../lib/theme/sample_media.dart';
import '../lib/widgets/chat/message_bubble.dart';

const String LONG =
    'This is a fairly long message used to measure the max bubble width so we can check whether the 75 percent cap is applied against the right base box.';

AylaChatMessage _msg({
  String content = LONG,
  String senderId = 'me',
  bool pending = false,
  double? uploadProgress,
  bool sendFailed = false,
  int secondsAgo = 30,
}) =>
    AylaChatMessage(
      id: 'm1',
      conversationId: 'c1',
      senderId: senderId,
      type: AylaMessageType.text,
      content: content,
      status: AylaMessageStatus.sent,
      seq: 1,
      createdAt: DateTime.now()
          .subtract(Duration(seconds: secondsAgo))
          .toUtc()
          .toIso8601String(),
      pending: pending,
      uploadProgress: uploadProgress,
      sendFailed: sendFailed,
    );

Future<void> _loadFonts() async {
  for (final String f in <String>['Nunito_400Regular.ttf', 'Nunito_700Bold.ttf']) {
    final ByteData data = await rootBundle.load('assets/fonts/' + f);
    await (FontLoader('Nunito')..addFont(Future<ByteData>.value(data))).load();
  }
}

void main() {
  setUp(aylaDisableSampleMedia);

  Future<void> pump(
    WidgetTester tester,
    Widget bubble,
    Size size,
  ) async {
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
                child: bubble,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  double bubbleWidth(WidgetTester tester, String text) => tester
      .getRect(find
          .ancestor(of: find.text(text), matching: find.byType(ClipRRect))
          .first)
      .width;

  // ================================================================
  // 核心不变量（2026-11-12 用户裁决）：气泡宽度从发送瞬间到终态**完全一致**
  // ================================================================
  //
  // 用户实报：窄屏下气泡被左侧工具栏（+发送转圈）挤压，等 120s 后撤回键消失、
  // 上传结束后气泡才变正常比例 ⇒ 宽度跳变。
  //
  // 裁决：以**终态**（无撤回、无加载）为准，消息刚发出就必须是这个宽度。
  // 本组用例把「四态同宽」逐档锁死：
  //   ① 3 键（含撤回，120s 内）     ← 刚发出的形态
  //   ② 2 键（撤回已消失）          ← 120s 后的终态
  //   ③ 3 键 + 纯 spinner 发送中
  //   ④ 3 键 + 「上传中 99% + 取消」
  for (final double vw in <double>[320, 375, 414, 480, 768, 900, 1280, 1440]) {
    testWidgets('★ vw=${vw.toInt()}：四态气泡宽度必须完全相同（无跳变）', (
      WidgetTester tester,
    ) async {
      await _loadFonts();
      final Size size = Size(vw, 1200);
      final List<double> widths = <double>[];

      // ① 3 键（120s 内 ⇒ 撤回键存在）
      await pump(
        tester,
        AylaMessageBubble(
          msg: _msg(),
          isSelf: true,
          senderAvatarLabel: 'me',
          currentUserId: 'me',
          onQuote: (_) {},
          onRecall: (_) {},
        ),
        size,
      );
      widths.add(bubbleWidth(tester, LONG));

      // ② 2 键（>120s ⇒ 撤回键消失，= 终态）
      await pump(
        tester,
        AylaMessageBubble(
          msg: _msg(secondsAgo: 600),
          isSelf: true,
          senderAvatarLabel: 'me',
          currentUserId: 'me',
          onQuote: (_) {},
          onRecall: (_) {},
        ),
        size,
      );
      widths.add(bubbleWidth(tester, LONG));

      // ③ 3 键 + 纯 spinner（乐观消息发送中）
      await pump(
        tester,
        AylaMessageBubble(
          msg: _msg(pending: true),
          isSelf: true,
          senderAvatarLabel: 'me',
          currentUserId: 'me',
          onQuote: (_) {},
          onRecall: (_) {},
        ),
        size,
      );
      widths.add(bubbleWidth(tester, LONG));

      // ④ 3 键 + 「上传中 99% + 取消」
      await pump(
        tester,
        AylaMessageBubble(
          msg: _msg(pending: true, uploadProgress: 99),
          isSelf: true,
          senderAvatarLabel: 'me',
          currentUserId: 'me',
          onQuote: (_) {},
          onRecall: (_) {},
        ),
        size,
      );
      widths.add(bubbleWidth(tester, LONG));

      expect(widths[0], closeTo(widths[1], 0.01),
          reason: '★ 撤回键消失后气泡**不得**变宽（用户实报的核心 bug）');
      expect(widths[2], closeTo(widths[1], 0.01),
          reason: '★ 发送中 spinner 不得挤压气泡（web 侧是 absolute，本件走固定槽位）');
      expect(widths[3], closeTo(widths[1], 0.01),
          reason: '★ 「上传中 + 取消」不得挤压气泡');
      expect(tester.takeException(), isNull);
    });
  }

  // 他人行没有撤回键、没有发送态 ⇒ 与自己的终态同宽（同一算式，不同槽位内容）
  testWidgets('★ 375：自己（3 键）与他人（2 键）气泡同宽', (WidgetTester tester) async {
    await _loadFonts();
    const Size size = Size(375, 1200);
    await pump(
      tester,
      AylaMessageBubble(
        msg: _msg(),
        isSelf: true,
        senderAvatarLabel: 'me',
        currentUserId: 'me',
        onQuote: (_) {},
        onRecall: (_) {},
      ),
      size,
    );
    final double selfW = bubbleWidth(tester, LONG);
    await pump(
      tester,
      AylaMessageBubble(
        msg: _msg(senderId: 'other'),
        isSelf: false,
        senderAvatarLabel: 'o',
        currentUserId: 'me',
        onQuote: (_) {},
      ),
      size,
    );
    expect(bubbleWidth(tester, LONG), closeTo(selfW, 0.01),
        reason: '★ 工具栏槽位是常量 ⇒ 自己（3 键）与他人（2 键）气泡同宽');
  });

  // 图片气泡（320px 宽）在发送态下不得变窄 —— 用户截图里的典型场景
  testWidgets('★ 375：图片气泡在有/无发送态时同宽（截图里的典型场景）', (
    WidgetTester tester,
  ) async {
    await _loadFonts();
    const Size size = Size(375, 1200);
    final AylaMediaDescriptor media = AylaMediaDescriptor(
      mediaId: 'mi',
      kind: AylaMediaKind.image,
      mimeType: 'image/png',
      width: 640,
      height: 480,
    );
    AylaChatMessage mediaMsg({bool pending = false, double? progress}) =>
        AylaChatMessage(
          id: 'm2',
          conversationId: 'c1',
          senderId: 'me',
          type: AylaMessageType.image,
          content: '',
          mediaId: media.mediaId,
          media: media,
          status: AylaMessageStatus.sent,
          seq: 2,
          createdAt: DateTime.now().toUtc().toIso8601String(),
          pending: pending,
          uploadProgress: progress,
        );

    await pump(
      tester,
      AylaMessageBubble(
        msg: mediaMsg(),
        isSelf: true,
        senderAvatarLabel: 'me',
        currentUserId: 'me',
        onQuote: (_) {},
        onRecall: (_) {},
      ),
      size,
    );
    final double doneW = tester.getRect(find.byType(ClipRRect).last).width;

    await pump(
      tester,
      AylaMessageBubble(
        msg: mediaMsg(pending: true, progress: 99),
        isSelf: true,
        senderAvatarLabel: 'me',
        currentUserId: 'me',
        onQuote: (_) {},
        onRecall: (_) {},
      ),
      size,
    );
    final double sendingW = tester.getRect(find.byType(ClipRRect).last).width;
    expect(sendingW, closeTo(doneW, 0.01),
        reason: '★ 图片气泡（320px）在发送态下不得被挤压（用户截图的原始场景）');
  });
}
