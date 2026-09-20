/// B5 帖子卡族定向测试（AylaPostCard / AylaPostVideoCover / 时间与可见性工具）。
///
/// 事实源：web `components/posts/PostCard.tsx`、`utils/visibility.ts`、`posts.css`。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../lib/core/media/media_signer.dart';
import '../lib/core/models/post.dart';
import '../lib/theme/preview_theme.dart';
import '../lib/theme/tokens.dart';
import '../lib/theme/buttons.dart' show AylaIconButton;
import '../lib/widgets/directory_controls.dart' show AylaFavoriteButton;
import '../lib/widgets/primitives.dart' show AylaCapsuleTag;
import '../lib/widgets/post_card.dart';
import '../lib/widgets/resource_image.dart';

void main() {
  setUp(() => MediaSigner.instance.detach()); // 隔离：避免真实签名请求
  tearDown(() => MediaSigner.instance.detach());

  Widget host(Widget child) => MaterialApp(home: previewScope(child));

  AylaPost sample({
    String body = '正文',
    String title = '',
    List<AylaPostImage> images = const <AylaPostImage>[],
    int? commentCount,
    int? viewCount,
    AylaPostVisibility? visibility,
    String? groupName,
    List<String> allowedGroupNames = const <String>[],
    String createdAt = '2026-09-20T11:00:00Z',
  }) {
    return AylaPost(
      id: 1,
      author: const AylaPostAuthor(id: 'u1', nickname: '星野遥', online: true),
      title: title,
      body: body,
      visibility: visibility,
      groupName: groupName,
      allowedGroupNames: allowedGroupNames,
      images: images,
      commentCount: commentCount,
      viewCount: viewCount,
      createdAt: createdAt,
    );
  }

  AylaMediaDescriptor media(String id, {AylaMediaKind? kind, String? thumb}) =>
      AylaMediaDescriptor(mediaId: id, kind: kind, thumbnail: thumb);

  group('aylaPostCardTime（PostCard.tsx:23–36 同源）', () {
    final DateTime now = DateTime(2026, 9, 20, 12, 0, 0);
    test('刚刚 / 分钟 / 小时 / 日期 / 非法值', () {
      expect(
        aylaPostCardTime(
          now.subtract(const Duration(seconds: 30)).toIso8601String(),
          now: now,
        ),
        '刚刚',
      );
      expect(
        aylaPostCardTime(
          now.subtract(const Duration(minutes: 5)).toIso8601String(),
          now: now,
        ),
        '5 分钟前',
      );
      expect(
        aylaPostCardTime(
          now.subtract(const Duration(hours: 3)).toIso8601String(),
          now: now,
        ),
        '3 小时前',
      );
      expect(
        aylaPostCardTime(
          now.subtract(const Duration(days: 2)).toIso8601String(),
          now: now,
        ),
        '2026/9/18',
      );
      expect(aylaPostCardTime(null), '');
      expect(aylaPostCardTime('not-a-date'), '');
    });
  });

  group('aylaVisibilityLabels（utils/visibility.ts 同源）', () {
    test('公开/好友互斥 + 群名叠加 + 旧数据回退 + 兜底', () {
      expect(
        aylaVisibilityLabels(visibility: AylaPostVisibility.public),
        <String>['公开'],
      );
      expect(
        aylaVisibilityLabels(visibility: AylaPostVisibility.friends),
        <String>['好友'],
      );
      expect(
        aylaVisibilityLabels(
          visibility: AylaPostVisibility.public,
          allowedGroupNames: const <String>['深夜电台'],
        ),
        <String>['公开', '深夜电台'],
      );
      expect(
        aylaVisibilityLabels(
          visibility: AylaPostVisibility.group,
          groupName: '旧群',
        ),
        <String>['旧群'],
      );
      expect(
        aylaVisibilityLabels(visibility: AylaPostVisibility.group),
        <String>['群可见'],
      );
      expect(aylaVisibilityLabels(visibility: null), <String>['群可见']);
    });
  });

  group('AylaPostCard', () {
    testWidgets('长文 >120 字：三行折叠 + 展开/收起切换', (WidgetTester tester) async {
      await tester.pumpWidget(
        host(
          SizedBox(
            width: 360,
            child: AylaPostCard(post: sample(body: '很长的正文。' * 40), onOpen: () {}),
          ),
        ),
      );
      Text bodyText() => tester.widget<Text>(
            find.byWidgetPredicate(
              (Widget w) => w is Text && (w.data ?? '').startsWith('很长的正文。'),
            ),
          );
      expect(bodyText().maxLines, 3); // -webkit-line-clamp: 3
      expect(find.text('展开'), findsOneWidget);
      await tester.tap(find.text('展开'));
      await tester.pump();
      expect(bodyText().maxLines, isNull); // .is-expanded → line-clamp: unset
      expect(find.text('收起'), findsOneWidget);
    });

    testWidgets('短文本不出现折叠按钮', (WidgetTester tester) async {
      await tester.pumpWidget(
        host(
          SizedBox(width: 360, child: AylaPostCard(post: sample(), onOpen: () {})),
        ),
      );
      expect(find.text('展开'), findsNothing);
      expect(find.text('收起'), findsNothing);
    });

    testWidgets('九宫格最多 9 格 + 视频格子带 ▶ 角标', (WidgetTester tester) async {
      await tester.pumpWidget(
        host(
          SizedBox(
            width: 360,
            child: AylaPostCard(
              post: sample(
                images: <AylaPostImage>[
                  for (int i = 0; i < 10; i++)
                    AylaPostImage(id: i, media: media('m' + i.toString())),
                  AylaPostImage(
                    id: 99,
                    media: media('v1', kind: AylaMediaKind.video),
                  ),
                ],
              ),
              onOpen: () {},
              previewOnly: true, // 视频无海报帧 → 文字占位
            ),
          ),
        ),
      );
      await tester.pump();
      // slice(0, 9)：10 张图 + 1 视频 → 只渲染前 9 个（含第 10 张图片位）
      expect(find.byType(ResourceImage), findsNWidgets(9));
      expect(find.text('▶'), findsNothing); // 视频在 slice(0,9) 之外
    });

    testWidgets('视频格子有海报帧时渲染缩略图 + ▶ 角标', (WidgetTester tester) async {
      await tester.pumpWidget(
        host(
          SizedBox(
            width: 360,
            child: AylaPostCard(
              post: sample(
                images: <AylaPostImage>[
                  AylaPostImage(
                    id: 1,
                    media: media(
                      'v1',
                      kind: AylaMediaKind.video,
                      thumb: '/api/v1/media/v1/thumbnail',
                    ),
                  ),
                  AylaPostImage(id: 2, media: media('m1')),
                  AylaPostImage(id: 3, media: media('m2')),
                  AylaPostImage(id: 4, media: media('m3')),
                ],
              ),
              onOpen: () {},
            ),
          ),
        ),
      );
      await tester.pump();
      expect(find.text('▶'), findsOneWidget); // .post-card-video-badge
    });

    testWidgets('底排：统计仅在后端给了数字时出现；收藏位为 compact 形态', (WidgetTester tester) async {
      await tester.pumpWidget(
        host(
          SizedBox(
            width: 360,
            child: AylaPostCard(
              post: sample(commentCount: 3, viewCount: null),
              onOpen: () {},
            ),
          ),
        ),
      );
      expect(find.text('查看帖子'), findsOneWidget); // .post-card-open
      expect(find.text('3'), findsOneWidget); // comment_count
      expect(find.text('0'), findsNothing); // view_count 为 null → 不写 0
      expect(find.byType(AylaFavoriteButton), findsOneWidget);
    });

    testWidgets('可见性标签复用组件库 AylaCapsuleTag（tone=ice）', (WidgetTester tester) async {
      await tester.pumpWidget(
        host(
          SizedBox(
            width: 420,
            child: AylaPostCard(
              post: sample(
                visibility: AylaPostVisibility.public,
                allowedGroupNames: const <String>['深夜电台'],
              ),
              onOpen: () {},
            ),
          ),
        ),
      );
      // 2026-09-20 用户要求：标签必须复用组件库胶囊（不再自造）
      expect(find.byType(AylaCapsuleTag), findsNWidgets(2));
    });

    testWidgets('常规卡（360）+ 2 标签 → 时间与标签同排单行（2026-09-20 用户截图 case）', (WidgetTester tester) async {
      await tester.pumpWidget(
        host(
          SizedBox(
            width: 360,
            child: AylaPostCard(
              post: sample(
                visibility: AylaPostVisibility.public,
                allowedGroupNames: const <String>['深夜电台'],
              ),
              onOpen: () {},
            ),
          ),
        ),
      );
      final double groupHeight = tester
          .getSize(
            find
                .ancestor(
                  of: find.byType(AylaCapsuleTag).first,
                  matching: find.byType(Wrap),
                )
                .first,
          )
          .height;
      // 单行约 21px（11px × 1.55 + 2×2 padding）→ 必须不折行
      expect(groupHeight, lessThan(30));

      // 靠右：标签右缘贴卡片内容右缘（相对卡片矩形算，避免居中布局的坐标假设）
      final Rect cardRect = tester.getRect(find.byType(AylaPostCard));
      final double contentRight = cardRect.right - AylaSpacing.sp4;
      final double tagsRight =
          tester.getRect(find.byType(AylaCapsuleTag).last).right;
      expect((tagsRight - contentRight).abs(), lessThan(2));
    });

    testWidgets('极端窄卡（220）+ 4 个长标签 → 兜底折行且不溢出', (WidgetTester tester) async {
      await tester.pumpWidget(
        host(
          SizedBox(
            width: 220,
            child: AylaPostCard(
              post: sample(
                visibility: AylaPostVisibility.public,
                allowedGroupNames: const <String>[
                  '深夜电台',
                  '作业互助连麦',
                  '星海观测站',
                  '周末桌游局',
                ],
              ),
              onOpen: () {},
            ),
          ),
        ),
      );
      final double groupHeight = tester
          .getSize(
            find
                .ancestor(
                  of: find.byType(AylaCapsuleTag).first,
                  matching: find.byType(Wrap),
                )
                .first,
          )
          .height;
      expect(groupHeight, greaterThan(30)); // 兜底折行
      expect(tester.takeException(), isNull); // 不出现 RenderFlex overflow
    });

    testWidgets('宽卡 + 少量标签 → 单行（与时间同排，不折行）', (WidgetTester tester) async {
      await tester.pumpWidget(
        host(
          SizedBox(
            width: 680,
            child: AylaPostCard(
              post: sample(
                visibility: AylaPostVisibility.public,
                allowedGroupNames: const <String>['深夜电台'],
              ),
              onOpen: () {},
            ),
          ),
        ),
      );
      final double tagsHeight = tester
          .getSize(
            find
                .ancestor(
                  of: find.byType(AylaCapsuleTag).first,
                  matching: find.byType(Wrap),
                )
                .first,
          )
          .height;
      expect(tagsHeight, lessThan(30)); // 单行
    });

    testWidgets('分享钮是纯圆钮（.icon-btn-40 radius-pill，非 12 方角）', (WidgetTester tester) async {
      await tester.pumpWidget(
        host(
          SizedBox(width: 360, child: AylaPostCard(post: sample(), onOpen: () {})),
        ),
      );
      final AylaIconButton share = tester.widget<AylaIconButton>(
        find.byType(AylaIconButton),
      );
      expect(share.square, isFalse); // false → pill（40×40 = 正圆）
      expect(share.size, 40);
    });

    testWidgets('可见性标签渲染（公开 + 群名叠加）', (WidgetTester tester) async {
      await tester.pumpWidget(
        host(
          SizedBox(
            width: 420,
            child: AylaPostCard(
              post: sample(
                visibility: AylaPostVisibility.public,
                allowedGroupNames: const <String>['深夜电台'],
              ),
              onOpen: () {},
            ),
          ),
        ),
      );
      expect(find.text('公开'), findsOneWidget);
      expect(find.text('深夜电台'), findsOneWidget);
    });
  });

  group('aylaPostCardSamples（排列对齐 design.md §12.18 帖子流瀑布流）', () {
    testWidgets('>1025：内容轨道 1200 → 两列各 594 + 列间距 12', (WidgetTester tester) async {
      // ⚠️ flutter_test 默认画布 800x600：不放大画布的话 SizedBox(width:1300) 会被夹到
      // 800 → 走单列分支（实测踩过），断言必须配大画布。
      await tester.binding.setSurfaceSize(const Size(1400, 2400));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        host(SizedBox(width: 1300, child: aylaPostCardSamples())),
      );
      final Rect r0 = tester.getRect(find.byType(AylaPostCard).at(0));
      final Rect r1 = tester.getRect(find.byType(AylaPostCard).at(1));
      final Rect r2 = tester.getRect(find.byType(AylaPostCard).at(2));
      // 轨道 = min(1300 - 左右 sp6, 1200) = 1200；(1200 - 12) / 2 = 594
      expect(r0.width, closeTo(594, 1));
      expect(r2.width, closeTo(594, 1));
      // 左列两张（0 与 1 同左缘）；右列（2）在列间距 12 之后
      expect((r0.left - r1.left).abs(), lessThan(1));
      expect((r2.left - (r0.right + AylaSpacing.sp3)).abs(), lessThan(1));
    });

    testWidgets('<=1024：单列，卡片吃满可用宽', (WidgetTester tester) async {
      await tester.binding.setSurfaceSize(const Size(1000, 2600));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        host(SizedBox(width: 900, child: aylaPostCardSamples())),
      );
      final Rect r0 = tester.getRect(find.byType(AylaPostCard).at(0));
      final Rect r1 = tester.getRect(find.byType(AylaPostCard).at(1));
      expect(r0.width, closeTo(900 - AylaSpacing.sp6 * 2, 1)); // 900 - 24 x 2
      expect((r0.left - r1.left).abs(), lessThan(1)); // 同列
      expect(r1.top, greaterThan(r0.bottom)); // 纵向排布
    });
  });

  group('AylaPostVideoCover', () {
    testWidgets('有海报帧 → 缩略图；无海报帧 + previewOnly → 「视频」占位', (WidgetTester tester) async {
      await tester.pumpWidget(
        host(
          Column(
            children: <Widget>[
              AylaPostVideoCover(
                media: media(
                  'v1',
                  kind: AylaMediaKind.video,
                  thumb: '/api/v1/media/v1/thumbnail',
                ),
              ),
              AylaPostVideoCover(
                media: media('v2', kind: AylaMediaKind.video),
                placeholder: true,
              ),
            ],
          ),
        ),
      );
      await tester.pump();
      expect(find.byType(ResourceImage), findsOneWidget);
      expect(find.text('视频'), findsOneWidget);
    });
  });
}
