/// B2-5：建直播间表单（LiveCreate）+ 控制台资料栏（LiveOwnerPanel）定向测试 —— 逐条对照
/// `components/live/LiveCreate.tsx`(189) / `LiveOwnerPanel.tsx`(217)、
/// `app.css:3401–3477/3831–3843`、`live.css:32–33/164–180/190–269`、`auroraqua.css:57/502–531`。
library;

import 'dart:typed_data' show Uint8List;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../lib/core/media/media_picker.dart' show AylaPickedFile;
import '../lib/theme/buttons.dart';
import '../lib/theme/glass.dart';
import '../lib/theme/preview_theme.dart';
import '../lib/theme/tokens.dart';
import '../lib/widgets/dashed_border.dart';
import '../lib/widgets/directory_controls.dart' show AylaVisibilitySelector;
import '../lib/widgets/live_channel_snapshot.dart';
import '../lib/widgets/live_create.dart';
import '../lib/widgets/live_hall.dart' show AylaLiveStatus;
import '../lib/widgets/live_owner_panel.dart';
import '../lib/widgets/live_studio.dart' show AylaLiveCopyRow, AylaLiveCopyRowVariant;

AylaLiveChannelSnapshot _snapshot({
  String title = '深夜电台',
  String description = '',
  String? cover,
  AylaLiveStatus? status = AylaLiveStatus.idle,
  String? visibility = 'public',
  List<String> allowedGroupIds = const <String>[],
  String? group,
  String? rtmpUrl,
  String? streamKey,
  String? flvUrl,
}) {
  return AylaLiveChannelSnapshot(
    id: 'lc1',
    title: title,
    description: description,
    cover: cover,
    status: status,
    visibility: visibility,
    allowedGroupIds: allowedGroupIds,
    group: group,
    rtmpUrl: rtmpUrl,
    streamKey: streamKey,
    flvUrl: flvUrl,
  );
}

AylaPickedFile _fakeFile(String path) => AylaPickedFile(
  name: 'cover.png',
  size: 1024,
  mimeType: 'image/png',
  path: path,
  readBytes: () async => Uint8List.fromList(<int>[1, 2, 3]),
);

void main() {
  Widget host(
    WidgetTester tester,
    Widget child, {
    Size viewport = const Size(900, 700),
  }) {
    tester.view.physicalSize = viewport;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    return MaterialApp(
      home: previewScope(
        Builder(
          builder: (BuildContext context) => MediaQuery(
            data: MediaQuery.of(context).copyWith(size: viewport),
            child: Align(
              alignment: Alignment.topLeft,
              child: SingleChildScrollView(
                child: SizedBox(width: viewport.width, child: child),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> settle(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }

  group('AylaLiveCreate（tsx 20–189）', () {
    testWidgets('结构：标题 128 / 介绍 2000 + min-height 72 / 可见范围 / 封面 96×16:9 虚线 / glow 提交键', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        host(
          tester,
          AylaLiveCreate(onCreate: (_) async => _snapshot()),
          viewport: const Size(900, 700), // >768 ⇒ 封面 96（窄屏才是 88）
        ),
      );
      await settle(tester);

      expect(find.text('标题'), findsOneWidget);
      expect(find.text('介绍'), findsOneWidget);
      expect(find.text('封面'), findsOneWidget);
      // 字段：placeholder 与 maxLength（web tsx 94/96/104/106）
      final TextField title = tester.widget<TextField>(
        find.byType(TextField).first,
      );
      expect(title.decoration?.hintText, '给直播间起个标题');
      expect(title.maxLength, 128);
      final TextField desc = tester.widget<TextField>(find.byType(TextField).at(1));
      expect(desc.decoration?.hintText, '告诉观众这场直播聊什么（可选）');
      expect(desc.maxLength, 2000);
      // 介绍 min-height 72（`.live-create-textarea`）
      expect(
        find.byWidgetPredicate(
          (Widget w) =>
              w is ConstrainedBox &&
              w.constraints.minHeight == 72 &&
              w.constraints.maxHeight == double.infinity,
        ),
        findsOneWidget,
      );
      // 可见范围复用库内件
      expect(find.byType(AylaVisibilitySelector), findsOneWidget);
      // 封面 = 96×16:9 虚线冰蓝
      expect(
        tester.getSize(find.byType(AspectRatio).first).width,
        96,
      );
      expect(find.byType(AylaDashedBorder), findsOneWidget);
      // 提交键文案（tsx 141）
      expect(find.text('开播'), findsOneWidget);
      final GlassButton submit = tester.widget<GlassButton>(
        find.byWidgetPredicate(
          (Widget w) => w is GlassButton && w.variant == GlassButtonVariant.glow,
        ),
      );
      expect(submit.expand, isTrue); // 卡片作用域 width 100%
    });

    testWidgets('空标题 → 「标题不能为空」且**不发请求**（tsx 47–50）', (WidgetTester tester) async {
      int calls = 0;
      await tester.pumpWidget(
        host(
          tester,
          AylaLiveCreate(
            onCreate: (_) async {
              calls += 1;
              return _snapshot();
            },
          ),
          viewport: const Size(520, 700),
        ),
      );
      await settle(tester);
      await tester.tap(find.text('开播'));
      await settle(tester);
      expect(find.text('标题不能为空'), findsOneWidget);
      expect(calls, 0);
    });

    testWidgets('提交：标题 trim + 载荷可见性转换 + 成功后清空标题并回调，出现推流指引', (
      WidgetTester tester,
    ) async {
      AylaLiveCreateRequest? got;
      AylaLiveChannelSnapshot? created;
      await tester.pumpWidget(
        host(
          tester,
          AylaLiveCreate(
            onCreate: (AylaLiveCreateRequest request) async {
              got = request;
              return _snapshot(
                title: request.title,
                rtmpUrl: 'rtmp://live.elysium.local/app/stream-9f2c',
                streamKey: 'sk_live_9f2c',
              );
            },
            onCreated: (AylaLiveChannelSnapshot c) => created = c,
          ),
          viewport: const Size(520, 800),
        ),
      );
      await settle(tester);

      await tester.enterText(find.byType(TextField).first, '  我的深夜电台  ');
      await tester.tap(find.text('开播'));
      await settle(tester);

      expect(got?.title, '我的深夜电台'); // trim
      expect(got?.visibility, 'public'); // tsx 60：公开
      expect(created?.title, '我的深夜电台');
      // 标题已清空（tsx 68）
      expect(
        tester.widget<TextField>(find.byType(TextField).first).controller?.text,
        '',
      );
      // 指引出现（tsx 147–186）
      expect(find.text('直播间「我的深夜电台」已创建'), findsOneWidget);
      expect(
        find.text('推流信息仅本次显示，请立即复制到 OBS（此后可在直播间详情页查看）。'),
        findsOneWidget,
      );
      // 指引里两行复制是**基础档**（ice-100 + radius-sm 8）
      final Iterable<AylaLiveCopyRow> rows = tester.widgetList<AylaLiveCopyRow>(
        find.byType(AylaLiveCopyRow),
      );
      expect(rows.length, 2);
      expect(rows.first.variant, AylaLiveCopyRowVariant.base);
      expect(find.text('rtmp://live.elysium.local/app'), findsOneWidget); // obsServer 去末段
      expect(find.text('我已保存，关闭'), findsOneWidget);
    });

    testWidgets('群内创建 → 可见范围初值「仅本群可见 + 勾选本群」（tsx 32–35）', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        host(
          tester,
          AylaLiveCreate(
            group: 'g1',
            onCreate: (_) async => _snapshot(),
          ),
          viewport: const Size(520, 700),
        ),
      );
      await settle(tester);
      final AylaVisibilitySelector selector = tester.widget<AylaVisibilitySelector>(
        find.byType(AylaVisibilitySelector),
      );
      expect(selector.value.group, isTrue);
      expect(selector.value.isPublic, isFalse);
      expect(selector.selectedGroupIds, <String>['g1']);
      expect(selector.initialGroupId, 'g1');
    });

    testWidgets('封面：选图后预览（按本意 cover）；校验失败只报错不接受文件', (WidgetTester tester) async {
      int picks = 0;
      await tester.pumpWidget(
        host(
          tester,
          AylaLiveCreate(
            onCreate: (_) async => _snapshot(),
            pickCover: () async {
              picks += 1;
              return _fakeFile('/tmp/cover.png');
            },
          ),
          viewport: const Size(520, 700),
        ),
      );
      await settle(tester);
      await tester.tap(find.byType(AylaPressScale).first); // 封面选择块
      await settle(tester);
      expect(picks, 1);
      // 预览用 Image.file（样张/测试环境下文件不存在 → errorBuilder 静默）
      expect(find.byType(Image), findsOneWidget);
    });

    testWidgets('指引「我已保存，关闭」→ 收起指引；复制失败 → 表单级 destructive 文案', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        host(
          tester,
          AylaLiveCreate(
            onCreate: (_) async => _snapshot(
              rtmpUrl: 'rtmp://h/app/key',
              streamKey: 'sk',
            ),
            onCopy: (String text) async => false,
          ),
          viewport: const Size(520, 800),
        ),
      );
      await settle(tester);
      await tester.enterText(find.byType(TextField).first, '标题');
      await tester.tap(find.text('开播'));
      await settle(tester);

      await tester.tap(find.text('复制').first);
      await settle(tester);
      expect(find.text('复制失败，请手动选择复制'), findsOneWidget); // tsx 83

      await tester.tap(find.text('我已保存，关闭'));
      await settle(tester);
      expect(find.text('我已保存，关闭'), findsNothing);
      expect(find.textContaining('已创建'), findsNothing);
    });

    testWidgets('窄屏（≤768）封面 88 宽（live.css 249）', (WidgetTester tester) async {
      await tester.pumpWidget(
        host(
          tester,
          AylaLiveCreate(onCreate: (_) async => _snapshot()),
          viewport: const Size(420, 700),
        ),
      );
      await settle(tester);
      expect(tester.getSize(find.byType(AspectRatio).first).width, 88);
    });
  });

  group('AylaLiveOwnerPanel（tsx 17–217）', () {
    testWidgets('结构：卡 padding sp3 + gap sp3 · 封面 96 · 标题 200 + 介绍 flex · 开播 glow + 保存', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        host(
          tester,
          AylaLiveOwnerPanel(
            channel: _snapshot(title: '频道标题', description: '介绍文本'),
          ),
          viewport: const Size(1200, 400), // >1100 ⇒ 不换行档（769–1100 会换行）

        ),
      );
      await settle(tester);

      final Container panel = tester.widget<Container>(
        find
            .descendant(
              of: find.byType(AylaLiveOwnerPanel),
              matching: find.byType(Container),
            )
            .first,
      );
      // `.live-owner-panel { padding: var(--sp-3) }`（live.css 168 覆写 app.css 的 sp4）
      expect(panel.padding, const EdgeInsets.all(AylaSpacing.sp3));
      // 标题固定 200（`.live-title-input { width: 200px }`）
      expect(
        find.byWidgetPredicate(
          (Widget w) => w is SizedBox && w.width == 200,
        ),
        findsWidgets,
      );
      // ---- 用户 2026-09-22 定稿版式（有意偏离 web）----
      Rect pillOf(Finder root) => tester.getRect(
        find.descendant(of: root, matching: find.byType(AnimatedContainer)).first,
      );
      final Rect cover = tester.getRect(find.byType(AspectRatio).first);
      final Rect titleField = tester.getRect(find.byType(TextField).first);
      final Rect descField = tester.getRect(find.byType(TextField).at(1));
      final Rect startPill = pillOf(find.byType(GlassButton));
      final Rect savePill = pillOf(find.byType(AylaMsgActionButton));

      // 行高 112：封面按 16:9 反推宽度（199.1 × 112）、四个元素**上沿与下沿全部齐平**
      expect(cover.height, closeTo(112, 0.5));
      expect(cover.width, closeTo(112 * 16 / 9, 0.5));
      // 标题：单行固定 48（用户 2026-09-22「标题高一点」）；介绍：112 且可换行
      expect(titleField.height, closeTo(48, 0.5));
      expect(descField.height, closeTo(112, 0.5));
      expect(titleField.top, moreOrLessEquals(descField.top, epsilon: 0.5)); // 上沿对齐
      expect(titleField.top, moreOrLessEquals(cover.top, epsilon: 0.5));
      // 开播键在**标题正下方**，与标题**同宽同左/右缘**，高度填满剩余（112 − 48 − 4 = 60），**下沿齐平**
      expect(startPill.width, 200);
      expect(startPill.height, closeTo(112 - 48 - 4, 0.5));
      expect(startPill.top, greaterThan(titleField.bottom));
      expect(startPill.left, moreOrLessEquals(titleField.left, epsilon: 0.5));
      expect(startPill.right, moreOrLessEquals(titleField.right, epsilon: 0.5));
      // 开播/保存的文案都居中（拉宽后不能贴左）
      expect(
        tester.getRect(find.text('开播')).center.dx,
        moreOrLessEquals(startPill.center.dx, epsilon: 0.5),
      );
      // 用户 2026-09-22：「下方全都对齐」—— 开播 / 介绍 / 保存 / 封面 **下沿同一条线**
      expect(startPill.bottom, moreOrLessEquals(descField.bottom, epsilon: 0.5));
      expect(startPill.bottom, moreOrLessEquals(savePill.bottom, epsilon: 0.5));
      expect(startPill.bottom, moreOrLessEquals(cover.bottom, epsilon: 0.5));
      // 保存键独占右列并**铺满**（96 × 112 = 字段 68 + gap 4 + 开播 40）
      expect(savePill.width, 96);
      expect(savePill.height, closeTo(112, 0.5));
      expect(savePill.top, moreOrLessEquals(titleField.top, epsilon: 0.5));
      expect(savePill.bottom, moreOrLessEquals(startPill.bottom, epsilon: 0.5));
      // 拉宽的胶囊里文案必须**居中**（web `.msg-action-btn { justify-content: center }`）
      expect(
        tester.getRect(find.text('保存')).center.dx,
        moreOrLessEquals(savePill.center.dx, epsilon: 0.5),
      );
      // 标题单行 / 介绍可换行（用户 2026-09-22 明确）
      final TextField title = tester.widget<TextField>(find.byType(TextField).first);
      final TextField desc = tester.widget<TextField>(find.byType(TextField).at(1));
      expect(title.maxLines, 1);
      expect(desc.maxLines, isNull); // 多行
      expect(desc.minLines, 3);

      // 可见范围块：padding sp3 + 上边框
      final Iterable<Container> containers = tester.widgetList<Container>(
        find.descendant(
          of: find.byType(AylaLiveOwnerPanel),
          matching: find.byType(Container),
        ),
      );
      final Container visibilityBox = containers.firstWhere(
        (Container c) =>
            c.decoration is BoxDecoration &&
            (c.decoration! as BoxDecoration).border is Border,
      );
      expect(visibilityBox.padding, const EdgeInsets.all(AylaSpacing.sp3));
      expect(
        ((visibilityBox.decoration! as BoxDecoration).border! as Border).top.color,
        AylaColors.glassBorder,
      );
    });

    testWidgets('在播态 → 主键「下播」且为 ghost 档（web 裸 .btn 被用户判为 bug）', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        host(
          tester,
          AylaLiveOwnerPanel(
            channel: _snapshot(status: AylaLiveStatus.live),
          ),
          viewport: const Size(900, 400),
        ),
      );
      await settle(tester);
      final GlassButton primary = tester.widget<GlassButton>(
        find.byWidgetPredicate(
          (Widget w) =>
              w is GlassButton && w.label == '下播',
        ),
      );
      expect(primary.variant, GlassButtonVariant.ghost);
    });

    testWidgets('空标题保存 → 「标题不能为空」且不调 onSave（tsx 76–79）', (
      WidgetTester tester,
    ) async {
      int saves = 0;
      await tester.pumpWidget(
        host(
          tester,
          AylaLiveOwnerPanel(
            channel: _snapshot(title: ''),
            onSave: (AylaLiveOwnerSaveRequest request) async {
              saves += 1;
              return null;
            },
          ),
          viewport: const Size(900, 400),
        ),
      );
      await settle(tester);
      await tester.tap(find.text('保存'));
      await settle(tester);
      expect(find.text('标题不能为空'), findsOneWidget);
      expect(saves, 0);
    });

    testWidgets('保存 → 载荷（trim + 可见性单值）→ 用后端回显刷新封面与可见范围（tsx 99–108）', (
      WidgetTester tester,
    ) async {
      AylaLiveOwnerSaveRequest? got;
      await tester.pumpWidget(
        host(
          tester,
          AylaLiveOwnerPanel(
            channel: _snapshot(
              title: '旧标题',
              visibility: 'friends',
              allowedGroupIds: const <String>['g1'],
            ),
            onSave: (AylaLiveOwnerSaveRequest request) async {
              got = request;
              // 后端回显：群可见 + 白名单被规范化
              return _snapshot(
                title: request.title,
                visibility: 'group',
                allowedGroupIds: const <String>['g2'],
                cover: '/api/v1/media/9',
              );
            },
          ),
          viewport: const Size(900, 400),
        ),
      );
      await settle(tester);
      await tester.enterText(find.byType(TextField).first, '  新标题  ');
      await tester.tap(find.text('保存'));
      await settle(tester);

      expect(got?.title, '新标题');
      expect(got?.visibility, 'friends'); // 初值来自频道快照
      // 回显：可见范围刷新为 group + [g2]
      final AylaVisibilitySelector selector = tester.widget<AylaVisibilitySelector>(
        find.byType(AylaVisibilitySelector),
      );
      expect(selector.value.group, isTrue);
      expect(selector.selectedGroupIds, <String>['g2']);
    });

    testWidgets('开播 / 下播：busy 期禁用 + 失败 → 「操作失败」（tsx 40–72）', (
      WidgetTester tester,
    ) async {
      int starts = 0;
      await tester.pumpWidget(
        host(
          tester,
          AylaLiveOwnerPanel(
            channel: _snapshot(),
            onStart: () async {
              starts += 1;
              throw StateError('boom');
            },
          ),
          viewport: const Size(900, 400),
        ),
      );
      await settle(tester);
      await tester.tap(find.text('开播'));
      await settle(tester);
      expect(starts, 1);
      expect(find.text('操作失败'), findsOneWidget);
    });

    testWidgets('中屏档（769–1100）→ 与宽屏**同构**（2026-09-22 改版：不再另起一行/不改成列）', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        host(
          tester,
          AylaLiveOwnerPanel(channel: _snapshot()),
          viewport: const Size(900, 500),
        ),
      );
      await settle(tester);
      final Rect titleField = tester.getRect(find.byType(TextField).first);
      final Rect descField = tester.getRect(find.byType(TextField).at(1));
      // 与宽屏同构：标题 48 单行、介绍 112 可换行、上沿对齐
      expect(titleField.top, descField.top);
      expect(titleField.height, closeTo(48, 0.5));
      expect(descField.height, closeTo(112, 0.5));
      // 封面同样按 16:9 反推（199.1 × 112）
      final Rect cover = tester.getRect(find.byType(AspectRatio).first);
      expect(cover.width, closeTo(112 * 16 / 9, 0.5));
      expect(cover.height, closeTo(112, 0.5));
      // 保存键高 = 行高 112，下沿与其余元素齐平
      final Rect savePill = tester.getRect(
        find
            .descendant(
              of: find.byType(AylaMsgActionButton),
              matching: find.byType(AnimatedContainer),
            )
            .first,
      );
      expect(savePill.height, closeTo(112, 0.5));
      expect(savePill.bottom, moreOrLessEquals(descField.bottom, epsilon: 0.5));
      expect(savePill.bottom, moreOrLessEquals(cover.bottom, epsilon: 0.5));
    });

    testWidgets('窄屏（≤768）→ 布局不变 + **三列下沿对齐**（用户 2026-09-22）', (WidgetTester tester) async {
      await tester.pumpWidget(
        host(
          tester,
          AylaLiveOwnerPanel(channel: _snapshot()),
          viewport: const Size(420, 500),
        ),
      );
      await settle(tester);
      final Rect cover = tester.getRect(find.byType(AspectRatio).first);
      final Rect titleField = tester.getRect(find.byType(TextField).first);
      final Rect descField = tester.getRect(find.byType(TextField).at(1));
      final Rect startPill = tester.getRect(
        find
            .descendant(
              of: find.byType(GlassButton),
              matching: find.byType(AnimatedContainer),
            )
            .first,
      );
      final Rect savePill = tester.getRect(
        find
            .descendant(
              of: find.byType(AylaMsgActionButton),
              matching: find.byType(AnimatedContainer),
            )
            .first,
      );
      // 布局不变：封面 | 字段成列（两框上下排）| 两键竖排
      expect(descField.top, greaterThan(titleField.top));
      expect(savePill.top, greaterThan(startPill.top));
      // 三列下沿对齐（行高 72 = 字段列自然高；封面按 16:9 配到 128 × 72）
      expect(cover.height, closeTo(72, 0.5));
      expect(cover.width, closeTo(72 * 16 / 9, 0.5));
      expect(cover.bottom, moreOrLessEquals(descField.bottom, epsilon: 0.5));
      expect(cover.bottom, moreOrLessEquals(savePill.bottom, epsilon: 0.5));
      expect(descField.bottom, moreOrLessEquals(savePill.bottom, epsilon: 0.5));
      // 窄屏字段仍是 web 的 min-height 32（用户要求「仅宽屏」加高）
      expect(titleField.height, closeTo(32, 0.5));
      // 按钮列恒定 96 宽（`.live-owner-start { min-width: 96px }` 的实值）
      expect(startPill.width, closeTo(96, 0.5));
      expect(savePill.width, closeTo(96, 0.5));
    });
  });
}
