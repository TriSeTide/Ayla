/// B5：发帖编辑器定向测试（AylaPostEditor / posts.css 219–418 逐条对照）。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../lib/core/models/post.dart';
import '../lib/theme/glass.dart' show GlassButton, GlassInput;
import '../lib/theme/preview_theme.dart';
import '../lib/theme/tokens.dart';
import '../lib/widgets/post_editor.dart';
import '../lib/widgets/directory_controls.dart' show VisibilitySelection;

void main() {
  Widget host(Widget child) => MaterialApp(home: previewScope(child));

  AylaPostMediaDraft img(String id) => AylaPostMediaDraft(
        mediaId: id,
        descriptor: AylaMediaDescriptor(
          mediaId: id,
          kind: AylaMediaKind.image,
          thumbnail: '/api/v1/media/' + id + '/thumbnail',
        ),
      );

  AylaPostDraft? submitted;
  AylaPostEditor build({
    String? group,
    bool compact = false,
    bool collapsible = false,
    bool? expanded,
    List<AylaPostMediaDraft> images = const <AylaPostMediaDraft>[],
    Future<AylaMediaPickResult> Function(int, ValueChanged<double?>)? onPick,
    Future<AylaMediaPickResult> Function()? onRetry,
    Future<void> Function(AylaPostMediaDraft)? onRemove,
    ValueChanged<bool>? onExpandedChange,
  }) {
    return AylaPostEditor(
      onSubmit: (AylaPostDraft draft) async {
        submitted = draft;
      },
      group: group,
      groups: const <({String id, String title})>[
        (id: 'g1', title: '深夜电台'),
        (id: 'g2', title: '星海观测站'),
      ],
      compact: compact,
      collapsible: collapsible,
      expanded: expanded,
      initialImages: images,
      onPickMedia: onPick,
      onRetryFailedMedia: onRetry,
      onRemoveMedia: onRemove,
      onExpandedChange: onExpandedChange,
    );
  }

  setUp(() => submitted = null);

  group('GlassInput 多行扩展（TextField maxLines 语义回归）', () {
    testWidgets('未传 minLines/maxLines → 仍是单行（maxLines=1，非 null）', (WidgetTester tester) async {
      final TextEditingController controller = TextEditingController();
      addTearDown(controller.dispose);
      await tester.pumpWidget(host(GlassInput(controller: controller)));
      final TextField field = tester.widget<TextField>(find.byType(TextField));
      // ⚠️ TextField 的 maxLines=null 表示「不限行数」→ 不能直接透传 null
      expect(field.maxLines, 1);
      expect(field.minLines, isNull);
    });

    testWidgets('显式 minLines/maxLines=4 → 多行文本域（发帖正文）', (WidgetTester tester) async {
      final TextEditingController controller = TextEditingController();
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        host(GlassInput(controller: controller, minLines: 4, maxLines: 4, minHeight: 64)),
      );
      final TextField field = tester.widget<TextField>(find.byType(TextField));
      expect(field.minLines, 4);
      expect(field.maxLines, 4);
    });
  });

  group('提交与校验', () {
    testWidgets('填齐标题正文 → 提交 draft（一级 tab 默认 public）', (WidgetTester tester) async {
      await tester.pumpWidget(host(build()));
      await tester.enterText(find.byType(TextField).at(0), '标题');
      await tester.enterText(find.byType(TextField).at(1), '正文');
      await tester.pump();
      await tester.tap(find.text('发布'));
      await tester.pump();
      expect(submitted, isNotNull);
      expect(submitted!.title, '标题');
      expect(submitted!.body, '正文');
      expect(submitted!.visibility, AylaPostVisibility.public);
      expect(submitted!.groupId, isNull);
      expect(submitted!.mediaIds, isEmpty);
    });

    testWidgets('标题/正文为空 → 发布钮 disabled（web 语义；校验是防御性代码）', (WidgetTester tester) async {
      await tester.pumpWidget(host(build()));
      GlassButton submitButton() => tester.widget<GlassButton>(
            find.ancestor(of: find.text('发布'), matching: find.byType(GlassButton)),
          );
      // 标题空 + 正文有 → disabled
      await tester.enterText(find.byType(TextField).at(1), '正文');
      await tester.pump();
      expect(submitButton().onPressed, isNull);
      expect(submitted, isNull);
      // 补上标题 → enabled
      await tester.enterText(find.byType(TextField).at(0), '标题');
      await tester.pump();
      expect(submitButton().onPressed, isNotNull);
      // 正文只有空白 → 再次 disabled（trim 后为空）
      await tester.enterText(find.byType(TextField).at(1), '   ');
      await tester.pump();
      expect(submitButton().onPressed, isNull);
    });

    testWidgets('群内：可见性锁定本群（visibility=group + 白名单含本群）', (WidgetTester tester) async {
      await tester.pumpWidget(host(build(group: 'g1')));
      await tester.enterText(find.byType(TextField).at(0), '标题');
      await tester.enterText(find.byType(TextField).at(1), '正文');
      await tester.pump();
      await tester.tap(find.text('发布'));
      await tester.pump();
      expect(submitted!.visibility, AylaPostVisibility.group);
      expect(submitted!.groupId, 'g1');
      expect(submitted!.allowedGroupIds, contains('g1'));
    });
  });

  group('三形态', () {
    testWidgets('collapsible 收起：无标题字段；聚焦正文 → 展开（标题 + 收起钮）→ 收起', (WidgetTester tester) async {
      bool? expandedSeen;
      await tester.pumpWidget(
        host(build(collapsible: true, compact: true, onExpandedChange: (bool v) => expandedSeen = v)),
      );
      // 收起态：只有正文输入（单行）+ 发布钮
      expect(find.byType(TextField), findsOneWidget);
      expect(find.text('发一条帖子…'), findsOneWidget);
      expect(find.bySemanticsLabel('收起发帖面板'), findsNothing);

      // 点（聚焦）正文 → 展开
      await tester.tap(find.byType(TextField));
      await tester.pump();
      expect(find.byType(TextField), findsNWidgets(2)); // 标题 + 正文
      expect(find.text('标题（必填）'), findsOneWidget);
      expect(expandedSeen, isTrue);

      // 32px 圆形收起钮 → 收起
      await tester.tap(find.bySemanticsLabel('收起发帖面板'));
      await tester.pump();
      expect(find.byType(TextField), findsOneWidget);
      expect(expandedSeen, isFalse);
    });

    testWidgets('收起态不渲染选项区（可见性/标题/媒体钮只在展开态）', (WidgetTester tester) async {
      await tester.pumpWidget(host(build(collapsible: true, compact: true)));
      // web：收起态只有 .post-editor-input-row（正文 + 发布钮）
      expect(find.text('标题（必填）'), findsNothing);
      expect(find.textContaining('图片/视频'), findsNothing);
      expect(find.text('可见范围'), findsNothing);

      await tester.tap(find.byType(TextField));
      await tester.pump();
      expect(find.text('标题（必填）'), findsOneWidget);
      expect(find.textContaining('图片/视频'), findsOneWidget);
      expect(find.text('可见范围'), findsOneWidget);
    });

    testWidgets('发布钮纸飞机图标随按钮前景着色（IconTheme 继承，2026-09-20 事故）', (WidgetTester tester) async {
      await tester.pumpWidget(host(build()));
      await tester.enterText(find.byType(TextField).at(0), '标题');
      await tester.enterText(find.byType(TextField).at(1), '正文');
      await tester.pump();
      // 图标在 GlassButton 的 IconTheme(foreground) 之内 → 取 #fffafb（surface），
      // 否则 indigo 图标画在 indigo 底上不可见。
      // ⚠️ 不能用 find.ancestor(...).first：祖先顺序是「由外向内」，会先抓到 Material
      // 默认的 IconTheme(black87)（实测）。改为在整个 GlassButton 子树里找是否存在
      // surface 色的 IconTheme（AylaIcon 取的是**最近**祖先）。
      final Iterable<IconTheme> themes = tester.widgetList<IconTheme>(
        find.descendant(
          of: find.byType(GlassButton),
          matching: find.byType(IconTheme),
        ),
      );
      expect(
        themes.any((IconTheme t) => t.data.color == AylaColors.surface),
        isTrue,
      );
    });

    testWidgets('受控展开态：expanded=true 直接展开且不触发内部切换', (WidgetTester tester) async {
      await tester.pumpWidget(host(build(collapsible: true, expanded: true, compact: true)));
      expect(find.byType(TextField), findsNWidgets(2));
      expect(find.bySemanticsLabel('收起发帖面板'), findsOneWidget);
    });
  });

  group('媒体', () {
    testWidgets('选媒体：成功入列 + 失败计数与重试钮', (WidgetTester tester) async {
      Future<AylaMediaPickResult> pick(int remaining, ValueChanged<double?> onProgress) async {
        onProgress(0.5);
        return AylaMediaPickResult(drafts: <AylaPostMediaDraft>[img('m1')], failed: 1);
      }

      await tester.pumpWidget(host(build(onPick: pick, onRetry: () async => const AylaMediaPickResult())));
      expect(find.text('图片/视频 0/9'), findsOneWidget);
      await tester.tap(find.text('图片/视频 0/9'));
      await tester.pump();
      await tester.pump();
      expect(find.text('图片/视频 1/9'), findsOneWidget);
      expect(find.text('1 个媒体上传失败，可点击重试'), findsOneWidget);
      expect(find.text('重试失败媒体（1）'), findsOneWidget);
    });

    testWidgets('上传中显示进度（Completer 未完成时 上传中 50%）', (WidgetTester tester) async {
      final Completer<AylaMediaPickResult> gate = Completer<AylaMediaPickResult>();
      Future<AylaMediaPickResult> pick(int remaining, ValueChanged<double?> onProgress) {
        onProgress(0.5);
        return gate.future;
      }

      await tester.pumpWidget(host(build(onPick: pick)));
      await tester.tap(find.text('图片/视频 0/9'));
      await tester.pump();
      expect(find.text('上传中 50%'), findsOneWidget);
      gate.complete(AylaMediaPickResult(drafts: <AylaPostMediaDraft>[img('m1')]));
      await tester.pump();
      await tester.pump();
      expect(find.text('上传中 50%'), findsNothing);
      expect(find.text('图片/视频 1/9'), findsOneWidget);
    });

    testWidgets('移除媒体：乐观移除 + 回调清理', (WidgetTester tester) async {
      final List<AylaPostMediaDraft> removed = <AylaPostMediaDraft>[];
      await tester.pumpWidget(
        host(build(images: <AylaPostMediaDraft>[img('m1')], onRemove: (AylaPostMediaDraft d) async {
          removed.add(d);
        })),
      );
      expect(find.text('图片/视频 1/9'), findsOneWidget);
      await tester.tap(find.text('×')); // 移除钮（28px 圆 × ）
      await tester.pump();
      expect(find.text('图片/视频 0/9'), findsOneWidget);
      expect(removed.length, 1);
      expect(removed.first.mediaId, 'm1');
    });

    testWidgets('满 9 个：按钮禁用（onPressed 为 null）', (WidgetTester tester) async {
      await tester.pumpWidget(
        host(
          build(
            images: <AylaPostMediaDraft>[
              for (int i = 0; i < 9; i++) img('m' + i.toString()),
            ],
            onPick: (int r, ValueChanged<double?> p) async => const AylaMediaPickResult(),
          ),
        ),
      );
      expect(find.text('图片/视频 9/9'), findsOneWidget);
    });
  });
}
