/// 三处发图按钮接线的回归锁（2026-10-22 用户实报「按钮没反应」）。
///
/// ## 为什么需要这组测试
/// 三个图片按钮**组件能力都已实现**，缺的是页面/装配层的回调注入；而组件在回调为
/// null 时**并不禁用按钮**（`danmaku.dart` 的 `_disabled` 只看 sending/working；
/// `post_editor.dart:526` / `comments.dart:411` 的 `onPressed: null` 在 Flutter 里
/// 也不必然表现为「灰」），所以用户看到的是「点得动但毫无反应」——这正是本次实报的
/// 形状。本组测试逐处断言「点下去 → 注入的动作真的被调用」。
///
/// ## 事实源（web）
/// - 弹幕图片：`components/live/DanmakuInput.tsx:129–145`（hidden input + `sendImage`）
/// - 帖子媒体：`components/posts/PostEditor.tsx:103–146`（`uploadFiles`）
/// - 评论图片：`components/posts/CommentComposer.tsx:105–133`（`uploadFiles`）
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import '../lib/core/media/media_picker.dart' show AylaPickedFile;
import '../lib/core/models/post.dart';
import '../lib/layout/create_sheet_forms.dart' show AylaCreatePostForm;
import '../lib/state/auth_state.dart' show authNotifierProvider;
import '../lib/theme/app_theme.dart' show buildAylaTheme;
import '../lib/theme/buttons.dart' show AylaToolButton;
import '../lib/theme/glass.dart' show AylaGlassButton;
import '../lib/theme/preview_theme.dart';
import '../lib/widgets/group/group_posts_composer.dart' show AylaGroupPostsComposer;
import '../lib/widgets/live/danmaku.dart';
import '../lib/widgets/live/live_channel_snapshot.dart';
import '../lib/widgets/live/live_hall.dart' show AylaLiveCardData;
import '../lib/widgets/live/live_room_body.dart';
import '../lib/widgets/posts/comments.dart';
import '../lib/widgets/posts/post_editor.dart';

void main() {
  Widget host(Widget child) => MaterialApp(home: previewScope(child));

  AylaPickedFile fakeFile() => AylaPickedFile(
        path: '/tmp/x.png',
        name: 'x.png',
        mimeType: 'image/png',
        size: 16,
        readBytes: () async => throw UnimplementedError('测试不读字节'),
      );

  // ===================== ① 直播间弹幕图片 =====================

  group('① 直播间弹幕发图（LiveRoomBody → AylaDanmakuInput 的三层接线）', () {
    Widget roomBody({
      Future<AylaPickedFile?> Function()? onPick,
      Future<String> Function(AylaPickedFile, ValueChanged<double?>)? onUpload,
      Future<bool> Function(String, String?)? onSend,
    }) =>
        host(
          Scaffold(
            body: AylaLiveRoomBody(
              channelId: 'lc1',
              isNarrow: false,
              topInset: false,
              channels: const <AylaLiveCardData>[
                AylaLiveCardData(id: 'lc1', title: '第一场直播'),
              ],
              data: AylaLiveRoomData(
                channel: AylaLiveChannelSnapshot(id: 'lc1', title: '第一场直播'),
                danmaku: const <AylaDanmakuEntry>[],
              ),
              onSendDanmaku: onSend,
              onPickDanmakuImage: onPick,
              onUploadDanmakuImage: onUpload,
            ),
          ),
        );

    testWidgets('图片钮存在，且默认已接上库内组合动作（不是死按钮）',
        (WidgetTester tester) async {
      tester.view.physicalSize = const Size(1400, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(roomBody());
      await tester.pump();

      final AylaDanmakuInput input = tester.widget<AylaDanmakuInput>(
        find.byType(AylaDanmakuInput),
      );
      // 根因回归锁：这两个回调此前恒为 null ⇒ 按钮点下去 `_pickImage` 直接 return。
      expect(input.onPickImage, isNotNull,
          reason: 'web DanmakuInput.tsx:129–135 选图必须可达');
      expect(input.onUploadImage, isNotNull,
          reason: 'web DanmakuInput.tsx:90–98 上传必须可达');
    });

    testWidgets('页面注入的选图回调被真实调用（点击 → 回调计数）',
        (WidgetTester tester) async {
      tester.view.physicalSize = const Size(1400, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      int picked = 0;
      String? sentMediaId;
      await tester.pumpWidget(roomBody(
        onPick: () async {
          picked += 1;
          return fakeFile();
        },
        onUpload: (AylaPickedFile file, ValueChanged<double?> _) async => 'mid-1',
        onSend: (String content, String? mediaId) async {
          sentMediaId = mediaId;
          return true;
        },
      ));
      await tester.pump();

      // 用组件类型 + 语义标签定位（bySemanticsLabel 在宽屏侧栏档存在同名
      // Semantics 包裹层，定位不稳）。
      final Finder imageBtn = find.byWidgetPredicate(
        (Widget w) => w is AylaGlassButton && w.semanticLabel == '发送弹幕图片',
      );
      expect(imageBtn, findsOneWidget);
      await tester.tap(imageBtn);
      await tester.pumpAndSettle();

      expect(picked, 1, reason: '图片钮点下去必须走到页面注入的选图动作');
      expect(sentMediaId, 'mid-1',
          reason: '选图 → 上传 → 用 media_id 发送（web DanmakuInput.tsx:90–98）');
    });
  });

  // ===================== ② 帖子编辑器媒体 =====================

  group('② 发帖编辑器媒体（AylaCreatePostForm → AylaPostEditor 的三层接线）', () {
    Future<void> pumpCreatePost(WidgetTester tester) async {
      tester.view.physicalSize = const Size(1440, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final ProviderContainer container = ProviderContainer();
      addTearDown(container.dispose);
      container.read(authNotifierProvider.notifier).setTokens('access', 'refresh');
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp.router(
            routerConfig: GoRouter(
              initialLocation: '/',
              routes: <RouteBase>[
                GoRoute(
                  path: '/',
                  builder: (BuildContext c, GoRouterState s) => Scaffold(
                    body: AylaCreatePostForm(
                      loadGroups: () async => const <({String id, String title})>[],
                      createPost: (AylaPostDraft d) async => const AylaPost(id: 1),
                      onClose: () {},
                    ),
                  ),
                ),
              ],
            ),
            theme: buildAylaTheme(),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('三个回调都已接线（不再是 null ⇒ 图片钮不再不可点）',
        (WidgetTester tester) async {
      await pumpCreatePost(tester);
      final AylaPostEditor editor =
          tester.widget<AylaPostEditor>(find.byType(AylaPostEditor));
      // 根因回归锁：此前这里只有 onSubmit，onPickMedia 恒 null ⇒
      // post_editor.dart 的 onPressed 恒 null（用户实报「帖子发图没反应」）。
      expect(editor.onPickMedia, isNotNull,
          reason: 'web PostEditor.tsx:103–146 uploadFiles 必须可达');
      expect(editor.onRemoveMedia, isNotNull,
          reason: 'web PostEditor.tsx removeMedia（deleteMedia）必须可达');
      expect(editor.onRetryFailedMedia, isNotNull,
          reason: 'web PostEditor.tsx:256–268 重试必须可达');
    });

    testWidgets('图片钮可点（onPressed 非 null）', (WidgetTester tester) async {
      await pumpCreatePost(tester);
      final Finder mediaBtn = find.byWidgetPredicate(
        (Widget w) => w is AylaGlassButton && w.label.startsWith('图片/视频'),
      );
      expect(mediaBtn, findsOneWidget);
      final AylaGlassButton btn = tester.widget<AylaGlassButton>(mediaBtn);
      expect(btn.onPressed, isNotNull,
          reason: '回调缺失时 post_editor.dart:526 会把按钮置为不可点');
    });
  });

  // ===================== ③ 帖子评论图片 =====================

  group('③ 帖子评论图片（评论输入框三层接线）', () {
    testWidgets('详情页固定 composer 三回调已接线', (WidgetTester tester) async {
      await tester.pumpWidget(host(Scaffold(
        body: AylaCommentComposer(
          onSend: (String b, int? r, List<String> m) async {},
          onPickImages: (int remaining, ValueChanged<double?> p) async =>
              const AylaMediaPickResult(),
          onRemoveImage: (AylaPostMediaDraft d) async {},
          onRetryFailedImages: () async => const AylaMediaPickResult(),
        ),
      )));
      await tester.pumpAndSettle();
      final AylaToolButton btn = tester.widget<AylaToolButton>(
        find.byType(AylaToolButton).first,
      );
      expect(btn.onPressed, isNotNull,
          reason: '回调接线后图片钮必须可点（comments.dart:411）');
    });

    testWidgets('评论列表内嵌 composer 默认已接上库内动作（不再恒不可点）',
        (WidgetTester tester) async {
      await tester.pumpWidget(host(
        Scaffold(
          body: AylaCommentList(
            comments: const <AylaPostComment>[],
            onSend: (String b, int? r, List<String> m) async {},
          ),
        ),
      ));
      await tester.pumpAndSettle();
      final AylaCommentComposer composer = tester.widget<AylaCommentComposer>(
        find.byType(AylaCommentComposer),
      );
      expect(composer.onPickImages, isNotNull,
          reason: '列表内嵌 composer 未注入时必须落到库内 AylaMediaActions');
      expect(composer.onRemoveImage, isNotNull);
      expect(composer.onRetryFailedImages, isNotNull);
    });
  });

  // ===================== ④ 群内发帖（AylaGroupPostsComposer 透传层） =====================

  group('④ 群内发帖（AylaGroupPostsComposer 未注入时也不该是死按钮）', () {
    testWidgets('未传媒体回调 ⇒ 编辑器拿到的三回调仍非 null（落到库内动作）',
        (WidgetTester tester) async {
      tester.view.physicalSize = const Size(1200, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(host(
        Scaffold(
          body: AylaGroupPostsComposer(
            onSubmit: (AylaPostDraft d) async {},
            groupId: 'g1',
            expanded: true,
            child: const SizedBox.expand(),
          ),
        ),
      ));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      final AylaPostEditor editor =
          tester.widget<AylaPostEditor>(find.byType(AylaPostEditor));
      expect(editor.onPickMedia, isNotNull,
          reason: '群内发帖编辑器同样必须能选图（web GroupPosts.tsx 自带 uploadMediaFile）');
      expect(editor.onRemoveMedia, isNotNull);
      expect(editor.onRetryFailedMedia, isNotNull);
    });
  });
}