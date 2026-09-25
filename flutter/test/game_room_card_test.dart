/// B4 boardgame 域第一批（1/3）：桌游室卡片定向测试 —— 逐条对照
/// GameRoomCard.tsx 15–53 与 boardgame.css 9–119、auroraqua.css 28–52、
/// typed-result-cards.css 44、base.css 366–370。
///
/// 覆盖：结构 / 封面 16:9 与图标 48 / 名称样式 / 状态 tag 三档文案与两档颜色 /
/// 房主与人数与来源标签 / 条件渲染（缺字段即不渲染）/ visibility 缺失 ⇒ 无标签 /
/// 收藏键 compact 32×32 与 action 槽位三种语义 / 点卡进房 / reveal 挂载 /
/// **网格等高（reserveSpace 恒占位 ⇒ 缺行卡片与满行卡片等高）**。
///
/// ⚠️ 每个用例只 pumpWidget 一次：同一用例里二次 pumpWidget 换 props 在本工程实测
/// 不生效（13 号 §「一个用例里不能第二次 pumpWidget 换 props」）⇒ 换档一律拆用例。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../lib/core/models/game_room.dart';
import '../lib/core/models/user_public.dart';
import '../lib/core/models/visibility.dart';
import '../lib/theme/app_icons.dart';
import '../lib/theme/preview_theme.dart';
import '../lib/theme/tokens.dart';
import '../lib/widgets/directory_controls.dart';
import '../lib/widgets/game_room_card.dart';
import '../lib/widgets/primitives.dart';
import '../lib/widgets/reveal.dart';

void main() {
  const AylaUserPublic alice = AylaUserPublic(
    id: 'u1',
    nickname: '爱莉',
    username: 'elysia',
  );
  const AylaUserPublic bob = AylaUserPublic(id: 'u2', username: 'bob');

  Widget host(Widget child, {Size viewport = const Size(280, 700)}) {
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

  /// 卡片树里所有 DecoratedBox 的底色（状态 tag / 封面 / 玻璃底都在其中）。
  List<Color?> boxColors(WidgetTester tester) => tester
      .widgetList<DecoratedBox>(find.byType(DecoratedBox))
      .map((DecoratedBox d) => d.decoration is BoxDecoration
          ? (d.decoration as BoxDecoration).color
          : null)
      .toList();

  testWidgets('结构：封面（16:9 + IconGame 48）+ 名称 + 状态 + 房主 + 人数 + 标签 + 进房', (
    WidgetTester tester,
  ) async {
    int entered = 0;
    await tester.pumpWidget(host(AylaGameRoomCard(
      room: const AylaGameCardData(
        id: '1',
        name: '爱莉的桌游室',
        status: AylaGameRoomStatus.playing,
        owner: alice,
        memberCount: 3,
        visibility: AylaPostVisibility.public,
      ),
      onEnter: () => entered++,
    )));
    await tester.pump();

    expect(find.text('爱莉的桌游室'), findsOneWidget); // tsx 39
    expect(find.text('对局中'), findsOneWidget); // tsx 41
    expect(find.text('爱莉'), findsOneWidget); // tsx 43（nickname 优先）
    expect(find.text('3 人'), findsOneWidget); // tsx 45
    expect(find.byType(AylaSourceTag), findsOneWidget); // 统一档来源标签

    // 名称样式（boardgame.css 57–63）：15 / w700 / text-primary / lh 1.35
    final Text name = tester.widget<Text>(find.text('爱莉的桌游室'));
    expect(name.style?.fontSize, 15);
    expect(name.style?.fontWeight, FontWeight.w700);
    expect(name.style?.height, 1.35);
    expect(name.style?.color, AylaColors.textPrimary);

    // 封面图标 48 + --ice-500（tsx 36 / boardgame.css 44–45）
    final AylaIcon icon = tester.widget<AylaIcon>(
      find.byWidgetPredicate((Widget w) => w is AylaIcon && w.size == 48),
    );
    expect(icon.color, AylaColors.ice500);

    // 封面 16:9（boardgame.css 43）
    final Size cover = tester.getSize(find.byType(AspectRatio).first);
    expect(cover.width / cover.height, closeTo(16 / 9, 0.01));
    // 封面底色 --ice-100
    expect(boxColors(tester), contains(AylaColors.ice100));

    await tester.tap(find.text('爱莉的桌游室')); // tsx 34
    await tester.pump();
    expect(entered, 1);
  });

  for (final (AylaGameRoomStatus status, String label, Color bg, Color fg)
      in <(AylaGameRoomStatus, String, Color, Color)>[
    (AylaGameRoomStatus.waiting, '等待中', AylaColors.ice300, AylaColors.indigo700),
    (AylaGameRoomStatus.playing, '对局中', AylaColors.sakura300, AylaColors.grape700),
    // tsx 40 只看 playing ⇒ ended 走 waiting 同档
    (AylaGameRoomStatus.ended, '已结束', AylaColors.ice300, AylaColors.indigo700),
  ]) {
    testWidgets('状态 tag：$label（文案 / 底色 / 字色 / 字级）', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(host(AylaGameRoomCard(
        room: AylaGameCardData(id: 'x', name: '房间', status: status),
        onEnter: () {},
      )));
      await tester.pump();

      expect(find.text(label), findsOneWidget);
      expect(boxColors(tester), contains(bg)); // boardgame.css 75–83
      final Text tag = tester.widget<Text>(find.text(label));
      expect(tag.style?.color, fg);
      expect(tag.style?.fontSize, 11);
      expect(tag.style?.letterSpacing, 0.8);
      expect(tag.style?.fontFamily, 'Fredoka');
    });
  }

  testWidgets('条件渲染：缺 status / owner / member_count 即不渲染对应行', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(host(AylaGameRoomCard(
      room: const AylaGameCardData(id: '1', name: '空房间'),
      onEnter: () {},
    )));
    await tester.pump();

    expect(find.text('空房间'), findsOneWidget);
    expect(find.text('等待中'), findsNothing);
    expect(find.text('对局中'), findsNothing);
    expect(find.text('已结束'), findsNothing);
    expect(find.textContaining(' 人'), findsNothing);
    // visibility 缺失 ⇒ 空数组（cardData.ts 14–16）：不出现「群可见」兜底
    expect(find.byType(AylaSourceTag), findsNothing);
    expect(find.text('群可见'), findsNothing);
  });

  testWidgets('来源标签：公开 + 白名单群名可叠加（两条）', (WidgetTester tester) async {
    await tester.pumpWidget(host(AylaGameRoomCard(
      room: const AylaGameCardData(
        id: '1',
        name: '房间',
        visibility: AylaPostVisibility.public,
        allowedGroupNames: <String>['冰樱研究社'],
      ),
      onEnter: () {},
    )));
    await tester.pump();

    expect(find.byType(AylaSourceTag), findsNWidgets(2));
    expect(find.text('公开'), findsOneWidget);
    expect(find.text('冰樱研究社'), findsOneWidget);
  });

  testWidgets('来源标签：group 无白名单 ⇒ 回退 group_name（旧数据兼容）', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(host(AylaGameRoomCard(
      room: const AylaGameCardData(
        id: '1',
        name: '房间',
        visibility: AylaPostVisibility.group,
        groupName: '旧群名',
      ),
      onEnter: () {},
    )));
    await tester.pump();
    expect(find.text('旧群名'), findsOneWidget);
    expect(find.byType(AylaSourceTag), findsOneWidget);
  });

  testWidgets('房主行兜底：无 nickname 时用 username（tsx 43 的 || 链）', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(host(AylaGameRoomCard(
      room: const AylaGameCardData(id: '1', name: '房间', owner: bob),
      onEnter: () {},
    )));
    await tester.pump();
    expect(find.text('bob'), findsOneWidget);
  });

  testWidgets('收藏键：默认渲染 compact 32×32（tsx 50 的 undefined 分支）', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(host(AylaGameRoomCard(
      room: const AylaGameCardData(id: '1', name: '房间'),
      onEnter: () {},
    )));
    await tester.pump();
    expect(find.byType(AylaFavoriteButton), findsOneWidget);
    final Size fav = tester.getSize(find.byType(AylaFavoriteButton));
    expect(fav.width, 32); // .favorite-toggle.is-compact（app.css 3334–3338）
    expect(fav.height, 32);
  });

  testWidgets('收藏键：showFavorite false 不渲染（搜索页 action={null} 用法）', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(host(AylaGameRoomCard(
      room: const AylaGameCardData(id: '2', name: '房间'),
      onEnter: () {},
      showFavorite: false,
    )));
    await tester.pump();
    expect(find.byType(AylaFavoriteButton), findsNothing);
  });

  testWidgets('收藏键：action 非空 ⇒ 槽位替换（DirectoryResultCards 用法）', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(host(AylaGameRoomCard(
      room: const AylaGameCardData(id: '3', name: '房间'),
      onEnter: () {},
      action: const Icon(Icons.close, key: ValueKey<String>('slot')),
    )));
    await tester.pump();
    expect(find.byType(AylaFavoriteButton), findsNothing);
    expect(find.byKey(const ValueKey<String>('slot')), findsOneWidget);
  });

  testWidgets('reveal：无 revealDelay 不挂动画（tsx 31–32）', (WidgetTester tester) async {
    await tester.pumpWidget(host(AylaGameRoomCard(
      room: const AylaGameCardData(id: '1', name: '房间'),
      onEnter: () {},
    )));
    await tester.pump();
    expect(find.byType(AylaRevealItem), findsNothing);
  });

  testWidgets('reveal：revealDelay 非 null ⇒ 挂 AylaRevealItem 并透传延迟', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(host(AylaGameRoomCard(
      room: const AylaGameCardData(id: '2', name: '房间'),
      onEnter: () {},
      revealDelay: const Duration(milliseconds: 80),
    )));
    await tester.pump();
    expect(find.byType(AylaRevealItem), findsOneWidget);
    final AylaRevealItem item =
        tester.widget<AylaRevealItem>(find.byType(AylaRevealItem));
    expect(item.delay, const Duration(milliseconds: 80));
  });

  testWidgets('网格等高：reserveSpace 时缺行卡片与满行卡片等高', (WidgetTester tester) async {
    const AylaGameCardData full = AylaGameCardData(
      id: '1',
      name: '满行卡片',
      status: AylaGameRoomStatus.playing,
      owner: alice,
      memberCount: 4,
      visibility: AylaPostVisibility.public,
    );
    const AylaGameCardData bare = AylaGameCardData(id: '2', name: '缺行卡片');

    await tester.pumpWidget(host(
      Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Expanded(
            child: AylaGameRoomCard(
              room: full,
              onEnter: () {},
              reserveSpace: true,
            ),
          ),
          Expanded(
            child: AylaGameRoomCard(
              room: bare,
              onEnter: () {},
              reserveSpace: true,
            ),
          ),
        ],
      ),
      viewport: const Size(520, 700),
    ));
    await tester.pump();

    final double a = tester.getSize(find.byType(AylaGameRoomCard).first).height;
    final double b = tester.getSize(find.byType(AylaGameRoomCard).last).height;
    expect((a - b).abs(), lessThan(0.5), reason: 'reserveSpace 时两卡必须等高');
  });

  testWidgets('网格等高对照：不预留时高度由内容决定（缺行更矮）', (WidgetTester tester) async {
    const AylaGameCardData full = AylaGameCardData(
      id: '1',
      name: '满行卡片',
      status: AylaGameRoomStatus.playing,
      owner: alice,
      memberCount: 4,
      visibility: AylaPostVisibility.public,
    );
    const AylaGameCardData bare = AylaGameCardData(id: '2', name: '缺行卡片');

    await tester.pumpWidget(host(
      Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Expanded(child: AylaGameRoomCard(room: full, onEnter: () {})),
          Expanded(child: AylaGameRoomCard(room: bare, onEnter: () {})),
        ],
      ),
      viewport: const Size(520, 700),
    ));
    await tester.pump();

    final double a = tester.getSize(find.byType(AylaGameRoomCard).first).height;
    final double b = tester.getSize(find.byType(AylaGameRoomCard).last).height;
    expect(a > b, isTrue, reason: '不预留时缺行卡片更矮');
  });
}
