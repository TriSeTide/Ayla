/// B5：评论族定向测试（AylaCommentList / AylaCommentComposer，posts.css 420–583 对照）。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../lib/core/models/post.dart';
import '../lib/theme/buttons.dart' show AylaToolButton;
import '../lib/theme/glass.dart' show GlassButton;
import '../lib/theme/preview_theme.dart';
import '../lib/widgets/comments.dart';
import '../lib/widgets/resource_image.dart';

void main() {
  Widget host(Widget child) => MaterialApp(home: previewScope(child));

  AylaPostAuthor author(String id, String name) =>
      AylaPostAuthor(id: id, nickname: name, online: true);

  AylaPostComment comment(
    int id, {
    String body = '正文',
    String? replyTo,
    bool isAuthor = false,
    List<AylaMediaDescriptor> images = const <AylaMediaDescriptor>[],
    String createdAt = '2026-09-20T12:00:00Z',
  }) =>
      AylaPostComment(
        id: id,
        author: author('u' + id.toString(), '星野遥'),
        body: body,
        replyTo: replyTo,
        isAuthor: isAuthor,
        images: images,
        createdAt: createdAt,
      );

  AylaMediaDescriptor img(String id) => AylaMediaDescriptor(
        mediaId: id,
        kind: AylaMediaKind.image,
        thumbnail: '/api/v1/media/' + id + '/thumbnail',
      );

  group('时间格式化', () {
    test('aylaCommentTime = 本地 zh-CN 形态', () {
      final String out = aylaCommentTime('2026-09-20T12:34:56Z');
      expect(out, matches(RegExp(r'^2026/9/2[01] \d{2}:\d{2}:\d{2}$')));
      expect(aylaCommentTime(null), '');
      expect(aylaCommentTime('not-a-date'), '');
    });
  });

  group('AylaCommentList', () {
    testWidgets('空态：还没有评论', (WidgetTester tester) async {
      await tester.pumpWidget(
        host(
          AylaCommentList(
            comments: const <AylaPostComment>[],
            onSend: (String b, int? r, List<String> m) async {},
            hideComposer: true,
          ),
        ),
      );
      expect(find.text('还没有评论'), findsOneWidget);
    });

    testWidgets('评论项：昵称/时间/正文 + 回复提示（命中与未命中两种）', (WidgetTester tester) async {
      await tester.pumpWidget(
        host(
          AylaCommentList(
            comments: <AylaPostComment>[
              comment(1, body: '第一条'),
              comment(2, body: '回复第一条', replyTo: '1'),
              comment(3, body: '回复不在列表里的', replyTo: '99'),
            ],
            onSend: (String b, int? r, List<String> m) async {},
            hideComposer: true,
          ),
        ),
      );
      expect(find.text('星野遥'), findsNWidgets(3));
      expect(find.text('第一条'), findsOneWidget);
      expect(find.text('回复 @星野遥'), findsOneWidget);
      expect(find.text('回复评论 #99（未在当前列表中）'), findsOneWidget);
      expect(find.textContaining('2026/9/2'), findsWidgets);
    });

    testWidgets('仅评论作者有删除入口；删除中显示禁用态', (WidgetTester tester) async {
      final Completer<void> gate = Completer<void>();
      final List<AylaPostComment> deleted = <AylaPostComment>[];
      await tester.pumpWidget(
        host(
          AylaCommentList(
            comments: <AylaPostComment>[
              comment(1, body: '别人的'),
              comment(2, body: '我的', isAuthor: true),
            ],
            onSend: (String b, int? r, List<String> m) async {},
            onDelete: (AylaPostComment c) {
              deleted.add(c);
              return gate.future;
            },
            hideComposer: true,
          ),
        ),
      );
      // 只有一条评论带删除入口（is_author）
      expect(find.text('删除'), findsOneWidget);
      expect(find.text('回复'), findsNWidgets(2));
      await tester.tap(find.text('删除'));
      await tester.pump();
      expect(find.text('删除中…'), findsOneWidget); // 删除中禁用文案
      gate.complete();
      await tester.pump();
      expect(deleted.single.id, 2);
    });

    testWidgets('点回复 → onReply；图片网格渲染（2 图 → 2 个缩略图）', (WidgetTester tester) async {
      AylaPostComment? replied;
      await tester.pumpWidget(
        host(
          AylaCommentList(
            comments: <AylaPostComment>[
              comment(1, body: '带图', images: <AylaMediaDescriptor>[img('i1'), img('i2')]),
            ],
            onSend: (String b, int? r, List<String> m) async {},
            onReply: (AylaPostComment c) => replied = c,
            hideComposer: true,
          ),
        ),
      );
      await tester.tap(find.text('回复'));
      await tester.pump();
      expect(replied?.id, 1);
      expect(find.byType(ResourceImage), findsNWidgets(2));
    });
  });

  group('AylaCommentComposer', () {
    testWidgets('空正文 + 无图 → 发送钮 disabled；填正文后可发送且参数正确', (WidgetTester tester) async {
      String? sentBody;
      int? sentReply;
      List<String>? sentMedia;
      await tester.pumpWidget(
        host(
          AylaCommentComposer(
            onSend: (String body, int? replyTo, List<String> mediaIds) async {
              sentBody = body;
              sentReply = replyTo;
              sentMedia = mediaIds;
            },
          ),
        ),
      );
      GlassButton sendButton() => tester.widget<GlassButton>(
            find.ancestor(of: find.text('发送'), matching: find.byType(GlassButton)),
          );
      expect(sendButton().onPressed, isNull);
      await tester.enterText(find.byType(TextField), '写一条');
      await tester.pump();
      expect(sendButton().onPressed, isNotNull);
      await tester.tap(find.text('发送'));
      await tester.pump();
      expect(sentBody, '写一条');
      expect(sentReply, isNull);
      expect(sentMedia, isEmpty);
      await tester.pump();
      expect(find.byType(TextField), findsOneWidget); // 发完清空（仍单行）
    });

    testWidgets('回复条：回复 @昵称 + 取消回调', (WidgetTester tester) async {
      bool cleared = false;
      await tester.pumpWidget(
        host(
          AylaCommentComposer(
            onSend: (String b, int? r, List<String> m) async {},
            replyTarget: comment(1),
            onReplyClear: () => cleared = true,
          ),
        ),
      );
      expect(find.text('回复 @星野遥'), findsOneWidget);
      await tester.tap(find.text('取消'));
      await tester.pump();
      expect(cleared, isTrue);
    });

    testWidgets('待发图片：满 4 张时工具钮禁用；移除走 onRemoveImage', (WidgetTester tester) async {
      final List<AylaPostMediaDraft> removed = <AylaPostMediaDraft>[];
      AylaPostMediaDraft draft(String id) => AylaPostMediaDraft(
            mediaId: id,
            descriptor: AylaMediaDescriptor(
              mediaId: id,
              kind: AylaMediaKind.image,
              thumbnail: '/api/v1/media/' + id + '/thumbnail',
            ),
          );
      await tester.pumpWidget(
        host(
          AylaCommentComposer(
            onSend: (String b, int? r, List<String> m) async {},
            initialImages: <AylaPostMediaDraft>[
              for (int i = 0; i < 4; i++) draft('p' + i.toString()),
            ],
            onRemoveImage: (AylaPostMediaDraft d) async => removed.add(d),
          ),
        ),
      );
      expect(find.byType(AylaToolButton), findsOneWidget);
      expect(tester.widget<AylaToolButton>(find.byType(AylaToolButton)).onPressed, isNull);
      expect(find.text('×'), findsNWidgets(4));
      await tester.tap(find.text('×').first);
      await tester.pump();
      await tester.pump();
      expect(removed.length, 1);
      expect(find.text('×'), findsNWidgets(3));
    });

    testWidgets('底部滑入：inputEntered=false 时 translateY(100%)', (WidgetTester tester) async {
      await tester.pumpWidget(
        host(
          AylaCommentComposer(
            onSend: (String b, int? r, List<String> m) async {},
            inputEntered: false,
          ),
        ),
      );
      final AnimatedSlide slide =
          tester.widget<AnimatedSlide>(find.byType(AnimatedSlide));
      expect(slide.offset, const Offset(0, 1));
      expect(slide.duration, const Duration(milliseconds: 250));
    });
  });
}
