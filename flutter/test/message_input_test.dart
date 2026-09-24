/// B3 chat 第三批：消息输入区定向测试 —— 对照 `MessageInput.tsx`（594 行）
/// 与 `app.css` 1983–2185 / 2431–2527。
///
/// 覆盖：两形态结构（宽屏工具键横排带「发送」文字 / 窄屏工具键在下方一行）/
/// 提交（文本+@+媒体三条件、发送后清空与草稿回调）/ Enter 发送与 Shift+Enter 换行 /
/// @ 触发与选中插入胶囊 / 媒体入队与单文件互斥 / 引用条 / 禁用态 / 录音入口有无。
library;

import 'dart:typed_data' show Uint8List;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:flutter_test/flutter_test.dart';

import '../lib/core/media/media_picker.dart' show AylaPickResult, AylaPickedFile;
import '../lib/core/media/voice_recorder.dart';
import '../lib/core/models/chat_message.dart';
import '../lib/core/models/conversation.dart';
import '../lib/core/models/mention.dart';
import '../lib/core/models/user_public.dart';
import '../lib/theme/preview_theme.dart';
import '../lib/theme/sample_media.dart';
import '../lib/theme/tokens.dart';
import '../lib/widgets/mention_editor.dart';
import '../lib/widgets/mention_picker.dart';
import '../lib/widgets/message_input.dart';

AylaChatMessage _quote() => AylaChatMessage(
      id: '9',
      conversationId: 'c1',
      senderId: 'u1',
      type: AylaMessageType.text,
      content: '晚上一起看直播吗？',
      status: AylaMessageStatus.sent,
      seq: 9,
      createdAt: '2026-09-24T13:30:00Z',
    );

AylaConversationMember _member(String id, String name) => AylaConversationMember(
      id: 'm-$id',
      user: AylaUserPublic(id: id, nickname: name, username: 'user_$id'),
    );

AylaPickedFile _file(String name, String mime) => AylaPickedFile(
      name: name,
      size: 1024,
      mimeType: mime,
      readBytes: () async => Uint8List(0),
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
    Size viewport = const Size(760, 700),
  }) {
    setViewport(tester, viewport);
    return MaterialApp(
      home: previewTheme(
        Builder(
          builder: (BuildContext context) => MediaQuery(
            data: MediaQuery.of(context).copyWith(size: viewport),
            child: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(width: viewport.width, child: child),
            ),
          ),
        ),
      ),
    );
  }

  // ======================= 结构 =======================

  testWidgets('宽屏：工具键在输入框左侧横排，发送键带「发送」文字', (WidgetTester tester) async {
    await tester.pumpWidget(
      host(
        tester,
        AylaMessageInput(
          onSubmit: (_) {},
          draftKey: 'k',
          groupId: 'g1',
          showEmojiButton: true,
          emojiPanel: const SizedBox.shrink(),
          members: <AylaConversationMember>[_member('u1', '小樱')],
          voiceRecorder: AylaNoopVoiceRecorder(),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.text('发送'), findsOneWidget);
    // 工具键：图片 / 文件 / 语音（表情由 showEmojiButton 控制）
    expect(find.bySemanticsLabel('发送图片或视频'), findsOneWidget);
    expect(find.bySemanticsLabel('发送文件'), findsOneWidget);
    expect(find.bySemanticsLabel('群表情包'), findsOneWidget);
    // 宽屏：工具组与输入框同一 Row（工具组在左）
    final double toolsLeft = tester.getTopLeft(find.bySemanticsLabel('发送图片或视频')).dx;
    final double editorLeft = tester.getTopLeft(find.byType(TextField)).dx;
    expect(toolsLeft, lessThan(editorLeft), reason: '宽屏工具键在输入框左侧');
  });

  testWidgets('窄屏：工具键在输入框下方一行（无「发送」文字）', (WidgetTester tester) async {
    await tester.pumpWidget(
      host(
        tester,
        AylaMessageInput(
          onSubmit: (_) {},
          narrow: true,
          draftKey: 'k',
          voiceRecorder: AylaNoopVoiceRecorder(),
        ),
        viewport: const Size(375, 700),
      ),
    );
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.text('发送'), findsNothing, reason: '窄屏发送键只有图标（tsx 522–531）');
    final double toolsTop = tester.getTopLeft(find.bySemanticsLabel('发送图片或视频')).dy;
    final double editorBottom = tester.getBottomLeft(find.byType(TextField)).dy;
    expect(toolsTop, greaterThanOrEqualTo(editorBottom), reason: '工具键在输入框下方');
  });

  // ======================= 提交 =======================

  testWidgets('输入文本 → 点发送：提交 blocks 并清空编辑器与草稿', (WidgetTester tester) async {
    AylaMessageInputSubmission? sent;
    final List<String> drafts = <String>[];
    await tester.pumpWidget(
      host(
        tester,
        AylaMessageInput(
          onSubmit: (AylaMessageInputSubmission s) => sent = s,
          onDraftChanged: (String key, String v) => drafts.add(v),
          draftKey: 'k',
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 50));

    await tester.enterText(find.byType(TextField), '你好呀');
    await tester.pump();
    await tester.tap(find.text('发送'));
    await tester.pump();

    expect(sent, isNotNull);
    expect(aylaBlocksText(sent!.blocks), '你好呀');
    expect(sent!.picked, isEmpty);
    expect(find.text('你好呀'), findsNothing, reason: '发送后清空');
    expect(drafts.last, '', reason: '清空草稿（web clearDraft）');
  });

  testWidgets('空提交不发送（无文本、无媒体、无 @）', (WidgetTester tester) async {
    int calls = 0;
    await tester.pumpWidget(
      host(
        tester,
        AylaMessageInput(onSubmit: (_) => calls++, draftKey: 'k'),
      ),
    );
    await tester.pump(const Duration(milliseconds: 50));
    // 发送键禁用 ⇒ 点击无效
    await tester.tap(find.text('发送'), warnIfMissed: false);
    await tester.pump();
    expect(calls, 0);
  });

  testWidgets('Enter 发送 / Shift+Enter 换行（tsx 501–504）', (WidgetTester tester) async {
    int calls = 0;
    await tester.pumpWidget(
      host(
        tester,
        AylaMessageInput(onSubmit: (_) => calls++, draftKey: 'k'),
      ),
    );
    await tester.pump(const Duration(milliseconds: 50));

    await tester.enterText(find.byType(TextField), 'hi');
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(calls, 1, reason: 'Enter 发送');

    await tester.enterText(find.byType(TextField), 'a');
    await tester.pump();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pump();
    expect(calls, 1, reason: 'Shift+Enter 换行不发送');
  });

  // ======================= @ 路径 =======================

  testWidgets('输入 @ → 打开成员选择器；选中 → 插入不可拆分胶囊并同步草稿', (WidgetTester tester) async {
    final List<String> drafts = <String>[];
    await tester.pumpWidget(
      host(
        tester,
        AylaMessageInput(
          onSubmit: (_) {},
          onDraftChanged: (String k, String v) => drafts.add(v),
          draftKey: 'k',
          groupId: 'g1',
          members: <AylaConversationMember>[
            _member('u1', '小樱'),
            _member('u2', '阿澈'),
          ],
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 50));

    await tester.enterText(find.byType(TextField), '@樱');
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.byType(AylaMentionPicker), findsOneWidget, reason: '@ 触发选择器（含过滤词）');
    expect(find.text('小樱'), findsWidgets);

    // 选中成员（点选择器里的行）
    await tester.tap(find.text('小樱').last);
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.byType(AylaMentionPicker), findsNothing, reason: '选中后关闭');
    expect(drafts.last, '@[u1]', reason: '草稿序列化用 `@[user_id]`（跨端格式一致）');
  });

  testWidgets('私聊（无 groupId）不触发 @ 选择器', (WidgetTester tester) async {
    await tester.pumpWidget(
      host(
        tester,
        AylaMessageInput(onSubmit: (_) {}, draftKey: 'k'),
      ),
    );
    await tester.pump(const Duration(milliseconds: 50));
    await tester.enterText(find.byType(TextField), '@樱');
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.byType(AylaMentionPicker), findsNothing);
  });

  // ======================= 媒体队列 =======================

  testWidgets('媒体入队：点图片键 → 待发条出现（44 缩略图）+ 可移除', (WidgetTester tester) async {
    await tester.pumpWidget(
      host(
        tester,
        AylaMessageInput(
          onSubmit: (_) {},
          draftKey: 'k',
          pickImages: () async => AylaPickResult(
            files: <AylaPickedFile>[_file('a.png', 'image/png')],
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 50));

    await tester.tap(find.bySemanticsLabel('发送图片或视频'));
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.bySemanticsLabel('移除'), findsOneWidget, reason: '`.picked-remove`');

    await tester.tap(find.bySemanticsLabel('移除'));
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.bySemanticsLabel('移除'), findsNothing);
  });

  testWidgets('单文件互斥：先入队图片，再选文件 → 队列只剩文件（tsx 169–180）', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      host(
        tester,
        AylaMessageInput(
          onSubmit: (_) {},
          draftKey: 'k',
          pickImages: () async => AylaPickResult(
            files: <AylaPickedFile>[_file('a.png', 'image/png')],
          ),
          pickFile: () async => AylaPickResult(
            files: <AylaPickedFile>[_file('doc.pdf', 'application/pdf')],
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 50));

    await tester.tap(find.bySemanticsLabel('发送图片或视频'));
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.bySemanticsLabel('移除'), findsOneWidget);

    await tester.tap(find.bySemanticsLabel('发送文件'));
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.bySemanticsLabel('移除'), findsOneWidget, reason: '文件入队 ⇒ 丢弃旧图片（单媒体契约）');
    expect(find.text('doc.pdf'), findsOneWidget, reason: '文件项展示文件名');
  });

  testWidgets('媒体入队后提交带上 picked', (WidgetTester tester) async {
    AylaMessageInputSubmission? sent;
    await tester.pumpWidget(
      host(
        tester,
        AylaMessageInput(
          onSubmit: (AylaMessageInputSubmission s) => sent = s,
          draftKey: 'k',
          pickFile: () async => AylaPickResult(
            files: <AylaPickedFile>[_file('doc.pdf', 'application/pdf')],
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 50));

    await tester.tap(find.bySemanticsLabel('发送文件'));
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(find.text('发送'));
    await tester.pump();
    expect(sent?.picked.length, 1);
    expect(sent?.picked.first.file.name, 'doc.pdf');
  });

  // ======================= 引用 / 禁用 / 录音入口 =======================

  testWidgets('引用条：显示引用文案；取消 → onQuoteClear', (WidgetTester tester) async {
    int cleared = 0;
    await tester.pumpWidget(
      host(
        tester,
        AylaMessageInput(
          onSubmit: (_) {},
          draftKey: 'k',
          quote: _quote(),
          onQuoteClear: () => cleared++,
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.text('引用回复'), findsOneWidget);
    expect(find.text('晚上一起看直播吗？'), findsOneWidget);
    await tester.tap(find.bySemanticsLabel('取消引用'));
    await tester.pump();
    expect(cleared, 1);
  });

  testWidgets('禁用态：提示在上方，发送不可用', (WidgetTester tester) async {
    int calls = 0;
    await tester.pumpWidget(
      host(
        tester,
        AylaMessageInput(
          onSubmit: (_) => calls++,
          disabled: true,
          disabledHint: '本子群已禁言，仅管理员可发言',
          draftKey: 'k',
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('本子群已禁言，仅管理员可发言'), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'hi');
    await tester.pump();
    await tester.tap(find.text('发送'), warnIfMissed: false);
    await tester.pump();
    expect(calls, 0, reason: 'disabled 时不可发送（tsx 324）');
  });

  testWidgets('录音入口：按平台支持显示（web `isVoiceRecordingSupported()`）；替身不支持则不显示', (
    WidgetTester tester,
  ) async {
    // 未注入 ⇒ 按平台支持判断（web 同语义：支持即渲染入口，实例懒创建）
    await tester.pumpWidget(
      host(
        tester,
        AylaMessageInput(onSubmit: (_) {}, draftKey: 'k'),
      ),
    );
    await tester.pump(const Duration(milliseconds: 50));
    expect(
      find.bySemanticsLabel('发送语音'),
      aylaVoiceRecordingSupported() ? findsOneWidget : findsNothing,
      reason: '入口由平台支持决定，而不是由是否注入录音器决定',
    );
  });

  testWidgets('录音入口：注入「不支持」替身时隐藏（等价 web 浏览器不支持 getUserMedia）', (
    WidgetTester tester,
  ) async {
    final AylaNoopVoiceRecorder rec = AylaNoopVoiceRecorder();
    addTearDown(rec.close);
    await tester.pumpWidget(
      host(
        tester,
        AylaMessageInput(
          onSubmit: (_) {},
          draftKey: 'k2',
          voiceRecorder: rec,
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.bySemanticsLabel('发送语音'), findsNothing, reason: 'isSupported=false 时不显示');
  });

  testWidgets('初始草稿：`@[u1]` 还原为胶囊 + 原文', (WidgetTester tester) async {
    await tester.pumpWidget(
      host(
        tester,
        AylaMessageInput(
          onSubmit: (_) {},
          draftKey: 'k',
          initialDraft: '早 @[u1] 好',
          members: <AylaConversationMember>[_member('u1', '小樱')],
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('@小樱'), findsOneWidget, reason: '草稿里的 mention 还原成胶囊');
    final TextField field = tester.widget<TextField>(find.byType(TextField));
    expect(
      field.controller!.text.contains(AylaMentionTextController.placeholder),
      isTrue,
    );
    expect(aylaBlocksText(
      (field.controller! as AylaMentionTextController).extractBlocks(),
    ), '早  好');
  });
}
