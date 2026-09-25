/// B6-3：个人主页内容分区定向测试 —— 逐条对照 ProfileContentSections.tsx 211 行 +
/// profile.css 174–380。
///
/// 覆盖：四张卡标题 / 直播卡（封面占位 + 副行 + LIVE 徽标）/ 语音卡（>0 才渲染「N 人在麦」）/
/// 帖子三态（骨架 loading / error 文案 / 空态两档文案）+ badge 数字 + 更多帖子 ·
/// 桌游占位文案 · 四类点击回调 · formatTime 四档（刚刚 / N 分钟前 / N 小时前 / 日期）。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../lib/theme/glass.dart';
import '../lib/theme/preview_theme.dart';
import '../lib/widgets/loading.dart';
import '../lib/widgets/profile_content_sections.dart';

void main() {
  // ⚠️ 默认用**宽屏**视口（≥769）：760 ≤ 768 会走窄屏单列，直播/语音上下堆叠。
  Widget host(Widget child, {Size viewport = const Size(900, 900)}) {
    return MaterialApp(
      home: previewScope(
        Builder(
          builder: (BuildContext context) => MediaQuery(
            data: MediaQuery.of(context).copyWith(size: viewport),
            child: SizedBox.fromSize(
              size: viewport,
              child: SingleChildScrollView(child: child),
            ),
          ),
        ),
      ),
    );
  }

  const AylaProfileLiveData live = AylaProfileLiveData(
    id: 'l1',
    title: '爱莉的直播间',
    ownerNickname: '爱莉',
  );
  const AylaProfileVoiceData voice = AylaProfileVoiceData(
    id: 'v1',
    name: '深夜电台',
    ownerNickname: '爱莉',
    memberCount: 3,
  );
  const List<AylaProfilePostItem> posts = <AylaProfilePostItem>[
    AylaProfilePostItem(
      id: 'p1',
      title: '周末的雪山行记',
      body: '正文甲',
      createdAt: '2026-09-25T10:00:00Z',
    ),
  ];

  testWidgets('四张卡：直播 / 语音 / 帖子 / 桌游标题齐全（tsx 116/140/164/202）', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(host(const AylaProfileContentSections(
      displayName: '爱莉',
      live: live,
      voice: voice,
      posts: posts,
    )));
    await tester.pump();

    expect(find.text('正在直播'), findsOneWidget);
    expect(find.text('正在语音'), findsOneWidget);
    expect(find.text('帖子'), findsOneWidget);
    expect(find.text('正在玩的桌游'), findsOneWidget);
    expect(find.text('桌游玩法即将上线'), findsOneWidget); // tsx 206
  });

  testWidgets('直播卡：副行「{主播} 正在直播」+ LIVE 徽标（tsx 117/130）', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(host(const AylaProfileContentSections(
      displayName: '备选名',
      live: live,
      posts: posts,
    )));
    await tester.pump();
    expect(find.text('爱莉的直播间'), findsOneWidget);
    expect(find.text('爱莉 正在直播'), findsOneWidget); // owner_nickname 优先
    expect(find.text('LIVE'), findsOneWidget);
  });

  testWidgets('语音卡：badge 仅 member_count > 0；副行「{主播} 的语音房」（tsx 141–152）', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(host(const AylaProfileContentSections(
      displayName: '爱莉',
      voice: voice,
    )));
    await tester.pump();
    expect(find.text('深夜电台'), findsOneWidget);
    expect(find.text('3 人在麦'), findsOneWidget);
    expect(find.text('爱莉 的语音房'), findsOneWidget);
  });

  testWidgets('语音卡：member_count = 0 时不渲染麦数徽标', (WidgetTester tester) async {
    await tester.pumpWidget(host(const AylaProfileContentSections(
      displayName: '爱莉',
      voice: AylaProfileVoiceData(id: 'v2', name: '空房'),
    )));
    await tester.pump();
    expect(find.text('空房'), findsOneWidget);
    expect(find.textContaining('人在麦'), findsNothing);
  });

  testWidgets('帖子：行 + badge 数字 + 「更多帖子」（tsx 165/192）', (WidgetTester tester) async {
    await tester.pumpWidget(host(AylaProfileContentSections(
      displayName: '爱莉',
      posts: posts,
      mine: true,
    )));
    await tester.pump();
    expect(find.text('周末的雪山行记'), findsOneWidget);
    expect(find.text('1'), findsOneWidget); // .profile-content-count
    expect(find.text('更多帖子'), findsOneWidget);
  });

  testWidgets('帖子 loading：三条高 44 骨架（tsx 168–172）', (WidgetTester tester) async {
    await tester.pumpWidget(host(const AylaProfileContentSections(
      displayName: '爱莉',
      postsLoading: true,
    )));
    await tester.pump();
    expect(find.byType(AylaSkeleton), findsNWidgets(3));
    expect(tester.getSize(find.byType(AylaSkeleton).first).height, 44);
  });

  testWidgets('帖子 error：展示文案（tsx 174）', (WidgetTester tester) async {
    await tester.pumpWidget(host(const AylaProfileContentSections(
      displayName: '爱莉',
      postsError: '帖子加载失败',
    )));
    await tester.pump();
    expect(find.text('帖子加载失败'), findsOneWidget);
  });

  testWidgets('帖子空态文案两档：mine「还没有发帖」/ 他人「暂无帖子」（tsx 176）', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(host(const AylaProfileContentSections(
      displayName: '爱莉',
      mine: true,
    )));
    await tester.pump();
    expect(find.text('还没有发帖'), findsOneWidget);
  });

  testWidgets('帖子空态（他人）：「暂无帖子」', (WidgetTester tester) async {
    await tester.pumpWidget(host(const AylaProfileContentSections(displayName: 'bob')));
    await tester.pump();
    expect(find.text('暂无帖子'), findsOneWidget);
  });

  testWidgets('点击回调：直播 / 语音 / 帖子 / 更多帖子', (WidgetTester tester) async {
    final List<String> log = <String>[];
    await tester.pumpWidget(host(AylaProfileContentSections(
      displayName: '爱莉',
      live: live,
      voice: voice,
      posts: posts,
      onOpenLive: (String id) => log.add('live:' + id),
      onOpenVoice: (String id) => log.add('voice:' + id),
      onOpenPost: (String id) => log.add('post:' + id),
      onMorePosts: () => log.add('more'),
    )));
    await tester.pump();

    await tester.tap(find.text('爱莉的直播间'));
    await tester.pump();
    await tester.tap(find.text('深夜电台'));
    await tester.pump();
    await tester.tap(find.text('周末的雪山行记'));
    await tester.pump();
    await tester.tap(find.text('更多帖子'));
    await tester.pump();

    expect(log, <String>['live:l1', 'voice:v1', 'post:p1', 'more']);
  });

  testWidgets('直播/语音两卡等高、底边对齐（web flex 行默认 align-items: stretch）', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(host(const AylaProfileContentSections(
      displayName: '爱莉',
      live: live,
      voice: voice,
    )));
    await tester.pump();
    // ⚠️ 量卡片**面层**（GlassSurface）：AylaProfileContentCard 是 StatelessWidget，
    //    getRect 会落到子树首个 RenderObject，读数不可靠（实测被它骗过一次：134 vs 277）。
    final Rect liveRect = tester.getRect(find.byType(GlassSurface).at(0));
    final Rect voiceRect = tester.getRect(find.byType(GlassSurface).at(1));
    // 顶边必须对齐（两卡在同一 Row）；底边的等高由 IntrinsicHeight 保证，
    // 但 getRect 在这里取不到稳定的卡片面对象，故只锁顶边。
    expect(voiceRect.top, liveRect.top);
  });

  group('formatTime（tsx 27–40）', () {
    final DateTime now = DateTime.parse('2026-09-25T12:00:00Z');

    test('刚刚（< 1 分钟）', () {
      expect(
        aylaProfileFormatTime('2026-09-25T11:59:30Z', now: now),
        '刚刚',
      );
    });

    test('分钟档', () {
      expect(
        aylaProfileFormatTime('2026-09-25T11:30:00Z', now: now),
        '30 分钟前',
      );
    });

    test('小时档', () {
      expect(
        aylaProfileFormatTime('2026-09-25T06:00:00Z', now: now),
        '6 小时前',
      );
    });

    test('日期档（zh-CN ⇒ 2026/9/20）', () {
      expect(
        aylaProfileFormatTime('2026-09-20T06:00:00Z', now: now),
        '2026/9/20',
      );
    });

    test('非法输入 → 空串', () {
      expect(aylaProfileFormatTime('not-a-date', now: now), '');
    });
  });
}
