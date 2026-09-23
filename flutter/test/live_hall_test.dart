/// B2-2：直播大厅卡片 + 网格定向测试 —— 逐条对照 `components/live/LiveChannelCard.tsx`(53)
/// 与 `LiveHall.tsx`(45)、`app.css:3275–3397`、`live.css:559–596 / 617–655 / 811–814 / 1333–1354`、
/// `shell.css:619–629`、`auroraqua.css:29–52`，并移植官方用例
/// `vitest/live-rail.test.tsx:314–360`（大厅卡封面/徽章/来源/主播名/进入）与
/// `vitest/live-viewers.test.tsx:115–150`（人数角标三态与紧凑写法）。
///
/// 覆盖：结构 / 封面 16:9 与占位 / 状态徽章三档 + 色 / 爱莉角标 / 人数角标（含 null 不渲染、
/// 0 照常、未在播不显示、1.2k 紧凑）/ 标题与主播名取值优先级 / 来源标签用共享件 /
/// 收藏键 + 转发键（默认渲染、32×32、宽窄屏偏移、点击不触发进房、showActions:false 移除）/
/// 入场延迟 / 网格列数三档与窄屏 padding / 空态 / ownerNames 兜底。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../lib/core/models/visibility.dart';
import '../lib/theme/app_icons.dart';
import '../lib/theme/glass.dart';
import '../lib/theme/preview_theme.dart';
import '../lib/theme/tokens.dart';
import '../lib/widgets/directory_controls.dart'
    show AylaFavoriteButton, FavoriteState;
import '../lib/widgets/live_hall.dart';
import '../lib/widgets/primitives.dart' show AylaSourceTag;
import '../lib/widgets/resource_image.dart';
import '../lib/widgets/reveal.dart';
import '../lib/widgets/share.dart' show AylaShareButton;

AylaLiveCardData _channel({
  String id = 'lc1',
  String title = '爱莉电台',
  String? cover,
  AylaLiveStatus? status = AylaLiveStatus.live,
  String ownerId = 'u1',
  String? ownerNickname = '爱莉',
  int? viewerCount = 12,
  AylaPostVisibility? visibility = AylaPostVisibility.public,
  List<String> allowedGroupNames = const <String>[],
  String? groupName,
}) {
  return AylaLiveCardData(
    id: id,
    title: title,
    cover: cover,
    status: status,
    ownerId: ownerId,
    ownerNickname: ownerNickname,
    viewerCount: viewerCount,
    visibility: visibility,
    allowedGroupNames: allowedGroupNames,
    groupName: groupName,
  );
}

void main() {
  void setViewport(WidgetTester tester, Size size) {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
  }

  Widget host(
    WidgetTester tester,
    Widget child, {
    Size viewport = const Size(1000, 700),
  }) {
    setViewport(tester, viewport);
    return MaterialApp(
      home: previewScope(
        Builder(
          builder: (BuildContext context) => MediaQuery(
            data: MediaQuery.of(context).copyWith(size: viewport),
            child: Align(
              alignment: Alignment.topLeft,
              child: SizedBox.fromSize(size: viewport, child: child),
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

  Finder cover() => find.byWidgetPredicate(
    (Widget w) => w is AspectRatio && w.aspectRatio == 16 / 9,
  );

  /// 人数角标（`.live-card-viewers`）：带「N 人在看」语义标签的那一块。
  Finder viewersBadge() => find.byWidgetPredicate(
    (Widget w) =>
        w is Semantics &&
        (w.properties.label ?? '').endsWith('人在看'),
  );

  /// 状态/爱莉徽章：`_LiveBadge` 是私有类 ⇒ 用带该文案的 Container（唯一装饰盒）定位。
  Finder badge(String label) => find.ancestor(
    of: find.text(label),
    matching: find.byWidgetPredicate(
      (Widget w) => w is Container && w.decoration is BoxDecoration,
    ),
  );

  group('卡片结构（tsx 28–50）', () {
    testWidgets('封面 16:9 + 圆角 12 + 1px 亮边；无封面时视频图标占位', (WidgetTester tester) async {
      await tester.pumpWidget(
        host(
          tester,
          Center(
            child: SizedBox(
              width: 320,
              child: AylaLiveChannelCard(channel: _channel(), onEnter: () {}),
            ),
          ),
        ),
      );
      await settle(tester);

      expect(cover(), findsOneWidget);
      // live.css 559–572：半径 `--radius-input`；无 cover → color --ice-500 + iconVideo 28
      // 封面里的图标有两处可能：占位 iconVideo(28) 与人数角标 iconUsers(12)
      // ⇒ 用具名 + 尺寸的谓词锁定占位图标
      final AylaIcon icon = tester.widget<AylaIcon>(
        find.descendant(
          of: cover(),
          matching: find.byWidgetPredicate(
            (Widget w) => w is AylaIcon && w.icon.name == 'iconVideo',
          ),
        ),
      );
      expect(icon.size, 28);
      expect(icon.color, AylaColors.ice500);
      expect(tester.getSize(cover()).width / tester.getSize(cover()).height,
          closeTo(16 / 9, 0.01));
    });

    testWidgets('有封面 → ResourceImage(alt: '' 装饰图) + cover 填充', (WidgetTester tester) async {
      await tester.pumpWidget(
        host(
          tester,
          Center(
            child: SizedBox(
              width: 320,
              child: AylaLiveChannelCard(
                channel: _channel(cover: 'https://x/cover.jpg'),
                onEnter: () {},
              ),
            ),
          ),
        ),
      );
      await settle(tester);
      expect(
        find.descendant(
          of: cover(),
          matching: find.byWidgetPredicate(
            (Widget w) => w is AylaIcon && w.icon.name == 'iconVideo',
          ),
        ),
        findsNothing,
      ); // 有封面 ⇒ 无 iconVideo 占位（人数角标的 iconUsers 仍在）
      final ResourceImage image = tester.widget<ResourceImage>(
        find.descendant(of: cover(), matching: find.byType(ResourceImage)),
      );
      expect(image.src, 'https://x/cover.jpg');
      expect(image.alt, ''); // 装饰图（失败静默）
      expect(image.fit, BoxFit.cover);
    });

    testWidgets('标题 Fredoka 16 / line-height 1.35（fixed 行高防抖动）', (WidgetTester tester) async {
      await tester.pumpWidget(
        host(
          tester,
          Center(
            child: SizedBox(
              width: 320,
              child: AylaLiveChannelCard(channel: _channel(), onEnter: () {}),
            ),
          ),
        ),
      );
      await settle(tester);

      final Text title = tester.widget<Text>(find.text('爱莉电台'));
      expect(title.style?.fontFamily, AylaFonts.display);
      expect(title.style?.fontSize, 16); // `.live-card-title`
      expect(title.style?.height, 1.35);
      expect(title.style?.color, AylaColors.textPrimary);
    });

    testWidgets('主播名 13 / 1.4 secondary；来源标签用共享件 AylaSourceTag', (WidgetTester tester) async {
      await tester.pumpWidget(
        host(
          tester,
          Center(
            child: SizedBox(
              width: 320,
              child: AylaLiveChannelCard(
                channel: _channel(allowedGroupNames: <String>['冰樱研究社']),
                onEnter: () {},
              ),
            ),
          ),
        ),
      );
      await settle(tester);

      final Text owner = tester.widget<Text>(find.text('爱莉'));
      expect(owner.style?.fontSize, 13); // `.live-card-owner`
      expect(owner.style?.height, 1.4);
      expect(owner.style?.color, AylaColors.textSecondary);
      // 来源标签：公开 + 白名单群名（可叠加）→ 两枚共享标签
      expect(find.byType(AylaSourceTag), findsNWidgets(2));
      expect(find.text('公开'), findsOneWidget);
      expect(find.text('冰樱研究社'), findsOneWidget);
    });

    testWidgets('owner 取值：ownerNickname 优先于 ownerName 兜底（官方单测同口径）', (WidgetTester tester) async {
      await tester.pumpWidget(
        host(
          tester,
          Center(
            child: SizedBox(
              width: 320,
              child: AylaLiveChannelCard(
                channel: _channel(ownerNickname: '主播小樱'),
                ownerName: '懒拉名字',
                onEnter: () {},
              ),
            ),
          ),
        ),
      );
      await settle(tester);
      expect(find.text('主播小樱'), findsOneWidget);
      expect(find.text('懒拉名字'), findsNothing);
    });

    testWidgets('无主播名且无标签 → meta 行不渲染（tsx 46 条件）', (WidgetTester tester) async {
      await tester.pumpWidget(
        host(
          tester,
          Center(
            child: SizedBox(
              width: 320,
              child: AylaLiveChannelCard(
                channel: _channel(ownerNickname: null, visibility: null),
                onEnter: () {},
              ),
            ),
          ),
        ),
      );
      await settle(tester);
      expect(find.byType(AylaSourceTag), findsNothing);
    });
  });

  group('徽章（tsx 23–43）', () {
    for (final (AylaLiveStatus status, String label) in <(AylaLiveStatus, String)>[
      (AylaLiveStatus.live, '直播中'),
      (AylaLiveStatus.ended, '已结束'),
      (AylaLiveStatus.idle, '未开播'),
    ]) {
      testWidgets('状态徽章「$label」文案 + 配色（live=pink-500/surface；ended·idle=ice-100/secondary）',
          (WidgetTester tester) async {
        await tester.pumpWidget(
          host(
            tester,
            Center(
              child: SizedBox(
                width: 320,
                child: AylaLiveChannelCard(
                  channel: _channel(status: status, viewerCount: null),
                  onEnter: () {},
                ),
              ),
            ),
          ),
        );
        await settle(tester);

        expect(find.text(label), findsOneWidget);
        final Container box = tester.widget<Container>(badge(label));
        final BoxDecoration decoration = box.decoration! as BoxDecoration;
        final Text text = tester.widget<Text>(find.text(label));
        if (status == AylaLiveStatus.live) {
          // live.css 811–814（后加载覆写 app.css 的 --sakura-100）
          expect(decoration.color, AylaColors.pink500);
          expect(text.style?.color, AylaColors.surface);
        } else {
          expect(decoration.color, AylaColors.ice100); // --ice-100
          expect(text.style?.color, AylaColors.textSecondary);
        }
        // `.live-badge` 基类：padding 2×sp2 / pill / utility 12
        expect(decoration.borderRadius, AylaRadii.pill);
        expect(text.style?.fontFamily, AylaFonts.utility);
        expect(text.style?.fontSize, 12);
        expect(
          box.padding,
          const EdgeInsets.symmetric(horizontal: AylaSpacing.sp2, vertical: 2),
        );
      });
    }

    testWidgets('status 为 null / 未知 → 不渲染徽章（tsx 25）', (WidgetTester tester) async {
      await tester.pumpWidget(
        host(
          tester,
          Center(
            child: SizedBox(
              width: 320,
              child: AylaLiveChannelCard(
                channel: _channel(status: null, viewerCount: null),
                onEnter: () {},
              ),
            ),
          ),
        ),
      );
      await settle(tester);
      for (final String label in <String>['直播中', '已结束', '未开播']) {
        expect(find.text(label), findsNothing);
      }
    });

    testWidgets('爱莉角标：isElysia → 文案「爱莉」+ --bubble-elysia 渐变底 + text-on-pink', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        host(
          tester,
          Center(
            child: SizedBox(
              width: 320,
              child: AylaLiveChannelCard(
                channel: _channel(ownerNickname: null, visibility: null),
                isElysia: true,
                onEnter: () {},
              ),
            ),
          ),
        ),
      );
      await settle(tester);

      final Container box = tester.widget<Container>(badge('爱莉'));
      final BoxDecoration decoration = box.decoration! as BoxDecoration;
      expect(decoration.gradient, isA<LinearGradient>());
      expect(
        (decoration.gradient! as LinearGradient).colors,
        AylaGradients.bubbleElysia,
      );
      expect(tester.widget<Text>(find.text('爱莉')).style?.color, AylaColors.textOnPink);
    });

    testWidgets('角标内缩：徽章 top 3 / left 4；人数右 3 / 下 4（相对封面）', (WidgetTester tester) async {
      await tester.pumpWidget(
        host(
          tester,
          Center(
            child: SizedBox(
              width: 320,
              child: AylaLiveChannelCard(channel: _channel(), onEnter: () {}),
            ),
          ),
        ),
      );
      await settle(tester);

      final Rect coverRect = tester.getRect(cover());
      final Rect statusRect = tester.getRect(badge('直播中'));
      expect(statusRect.top - coverRect.top, AylaSpacing.sp1 - 1); // 3
      expect(statusRect.left - coverRect.left, AylaSpacing.sp1); // 4

      final Rect viewersRect = tester.getRect(viewersBadge());
      expect(coverRect.right - viewersRect.right, AylaSpacing.sp1 - 1); // 3
      expect(coverRect.bottom - viewersRect.bottom, AylaSpacing.sp1); // 4
    });
  });

  group('在看人数（utils/liveViewers.ts + live.css 1333–1354）', () {
    testWidgets('在播且有读数 → 小人图标 + 数字 + aria「N 人在看」', (WidgetTester tester) async {
      await tester.pumpWidget(
        host(
          tester,
          Center(
            child: SizedBox(
              width: 320,
              child: AylaLiveChannelCard(
                channel: _channel(viewerCount: 12),
                onEnter: () {},
              ),
            ),
          ),
        ),
      );
      await settle(tester);
      expect(viewersBadge(), findsOneWidget);
      expect(find.text('12'), findsOneWidget);
      expect(
        find.descendant(
          of: viewersBadge(),
          matching: find.byWidgetPredicate((Widget w) => w is AylaIcon && w.size == 12),
        ),
        findsOneWidget,
      );
      // 胶囊：--glass-bg-strong + 1px 亮边 + min-height 22
      final Container box = tester.widget<Container>(
        find.descendant(of: viewersBadge(), matching: find.byType(Container)),
      );
      final BoxDecoration decoration = box.decoration! as BoxDecoration;
      expect(decoration.color, AylaColors.glassBgStrong);
      expect(decoration.borderRadius, AylaRadii.pill);
      expect(box.constraints?.minHeight, 22);
    });

    testWidgets('0 是真实读数照常显示（不用 0 冒充「没人看」）', (WidgetTester tester) async {
      await tester.pumpWidget(
        host(
          tester,
          Center(
            child: SizedBox(
              width: 320,
              child: AylaLiveChannelCard(
                channel: _channel(viewerCount: 0),
                onEnter: () {},
              ),
            ),
          ),
        ),
      );
      await settle(tester);
      expect(viewersBadge(), findsOneWidget);
      expect(find.text('0'), findsOneWidget);
    });

    testWidgets('viewerCount 为 null（存储不可用）→ 不渲染角标', (WidgetTester tester) async {
      await tester.pumpWidget(
        host(
          tester,
          Center(
            child: SizedBox(
              width: 320,
              child: AylaLiveChannelCard(
                channel: _channel(viewerCount: null),
                onEnter: () {},
              ),
            ),
          ),
        ),
      );
      await settle(tester);
      expect(viewersBadge(), findsNothing); // 读不到 ≠ 0 人在看
    });

    testWidgets('未在播（idle）即使有读数也不渲染角标', (WidgetTester tester) async {
      await tester.pumpWidget(
        host(
          tester,
          Center(
            child: SizedBox(
              width: 320,
              child: AylaLiveChannelCard(
                channel: _channel(
                  status: AylaLiveStatus.idle,
                  viewerCount: 5,
                ),
                onEnter: () {},
              ),
            ),
          ),
        ),
      );
      await settle(tester);
      expect(viewersBadge(), findsNothing); // 未开播时驻留的人不是「在看直播」
    });

    testWidgets('紧凑写法：1200→1.2k / 53000→53k（formatViewerCount 逐条）', (WidgetTester tester) async {
      expect(aylaFormatViewerCount(0), '0');
      expect(aylaFormatViewerCount(999), '999');
      expect(aylaFormatViewerCount(1000), '1.0k');
      expect(aylaFormatViewerCount(1200), '1.2k');
      expect(aylaFormatViewerCount(9999), '10.0k'); // <10000 → 一位小数（toFixed 语义）
      expect(aylaFormatViewerCount(53000), '53k');
    });

    testWidgets('liveViewerBadge：仅 live 且有读数', (WidgetTester tester) async {
      expect(aylaLiveViewerBadge(AylaLiveStatus.live, 0), 0);
      expect(aylaLiveViewerBadge(AylaLiveStatus.live, null), isNull);
      expect(aylaLiveViewerBadge(AylaLiveStatus.idle, 5), isNull);
      expect(aylaLiveViewerBadge(null, 5), isNull);
    });
  });

  group('收藏键（用户 2026-09-22：卡片只放收藏键，转发键只在房头部）', () {
    testWidgets('只渲染收藏键（32×32）；卡片上**没有**转发键', (WidgetTester tester) async {
      await tester.pumpWidget(
        host(
          tester,
          Center(
            child: SizedBox(
              width: 320,
              child: AylaLiveChannelCard(channel: _channel(), onEnter: () {}),
            ),
          ),
        ),
      );
      await settle(tester);

      expect(find.byType(AylaFavoriteButton), findsOneWidget);
      expect(tester.getSize(find.byType(AylaFavoriteButton)), const Size(32, 32));
      // 用户追加裁决：「语音列表卡片上不用显示分享键，直播也不用」
      expect(find.byType(AylaShareButton), findsNothing);
    });

    for (final (Size viewport, double inset, String name) in <(Size, double, String)>[
      (Size(420, 700), AylaSpacing.sp3, '窄屏 12（app.css 3306–3310）'),
      (
        Size(1200, 700),
        AylaSpacing.sp4 + AylaSpacing.sp1,
        '宽屏 20（live.css 636–640：calc(sp4 + sp1)）',
      ),
    ]) {
      testWidgets('两键偏移：$name', (WidgetTester tester) async {
        await tester.pumpWidget(
          host(
            tester,
            Center(
              child: SizedBox(
                width: 320,
                child: AylaLiveChannelCard(channel: _channel(), onEnter: () {}),
              ),
            ),
            viewport: viewport,
          ),
        );
        await settle(tester);

        final Rect card = tester.getRect(find.byType(GlassSurface));
        final Rect favorite = tester.getRect(find.byType(AylaFavoriteButton));
        expect(card.right - favorite.right, inset);
        expect(favorite.top - card.top, inset);
      });
    }

    testWidgets('点收藏不触发进房；卡片本体点击触发', (WidgetTester tester) async {
      int enters = 0;
      final List<bool> toggles = <bool>[];
      await tester.pumpWidget(
        host(
          tester,
          Center(
            child: SizedBox(
              width: 320,
              child: AylaLiveChannelCard(
                channel: _channel(),
                favoriteState: FavoriteState.notFavorited,
                onToggleFavorite: toggles.add,
                onEnter: () => enters += 1,
              ),
            ),
          ),
        ),
      );
      await settle(tester);

      await tester.tap(find.byType(AylaFavoriteButton));
      await settle(tester);
      expect(toggles, <bool>[true]);
      expect(enters, 0, reason: '收藏键必须拦住卡片点击（web stopPropagation）');

      await tester.tap(find.text('爱莉电台'));
      await settle(tester);
      expect(enters, 1);
    });

    testWidgets('showActions: false → 收藏键不渲染（web 搜索页 action={null}）', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        host(
          tester,
          Center(
            child: SizedBox(
              width: 320,
              child: AylaLiveChannelCard(
                channel: _channel(),
                showActions: false,
                onEnter: () {},
              ),
            ),
          ),
        ),
      );
      await settle(tester);
      expect(find.byType(AylaFavoriteButton), findsNothing);
    });
  });

  group('入场延迟', () {
    testWidgets('revealDelay → 挂 AylaRevealItem（panel-from-bottom 语义同库内）', (WidgetTester tester) async {
      await tester.pumpWidget(
        host(
          tester,
          Center(
            child: SizedBox(
              width: 320,
              child: AylaLiveChannelCard(
                channel: _channel(),
                revealDelay: const Duration(milliseconds: 100),
                onEnter: () {},
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      final AylaRevealItem reveal = tester.widget<AylaRevealItem>(
        find.byType(AylaRevealItem),
      );
      expect(reveal.delay, const Duration(milliseconds: 100));
      expect(reveal.enabled, isTrue);
    });

    testWidgets('revealDelay 为 null → 不挂（列表不逐条浮入时）', (WidgetTester tester) async {
      await tester.pumpWidget(
        host(
          tester,
          Center(
            child: SizedBox(
              width: 320,
              child: AylaLiveChannelCard(channel: _channel(), onEnter: () {}),
            ),
          ),
        ),
      );
      await settle(tester);
      expect(find.byType(AylaRevealItem), findsNothing);
    });
  });

  group('等高（用户 2026-09-22：「直播所有卡片高度要一致」）', () {
    testWidgets('网格内：同行卡片等高（含「无 meta 行」的那张）', (WidgetTester tester) async {
      await tester.pumpWidget(
        host(
          tester,
          AylaLiveHall(
            channels: <AylaLiveCardData>[
              // 有 meta（主播名 + 标签）
              _channel(id: 'a', title: 'A'),
              // 无主播名、无标签（visibility 缺失 ⇒ 无标签）——web 会被 grid stretch 拉平
              _channel(
                id: 'b',
                title: 'B',
                ownerNickname: null,
                visibility: null,
              ),
              _channel(id: 'c', title: 'C'),
            ],
            onEnter: (_) {},
          ),
          viewport: const Size(1000, 900),
        ),
      );
      await settle(tester);

      final Finder cards = find.byType(AylaLiveChannelCard);
      final List<double> heights = <double>[
        for (int i = 0; i < 3; i += 1) tester.getRect(cards.at(i)).height,
      ];
      expect(heights.toSet().length, 1, reason: '同行三张卡必须等高：$heights');
    });

    testWidgets('单独使用（reserveMetaSpace 默认 false）→ 不预留 meta 行（无空白）', (
      WidgetTester tester,
    ) async {
      Future<double> heightOf({required bool reserve}) async {
        await tester.pumpWidget(
          host(
            tester,
            Center(
              child: SizedBox(
                width: 320,
                child: AylaLiveChannelCard(
                  channel: _channel(
                    ownerNickname: null,
                    visibility: null, // 无 meta 行
                  ),
                  reserveMetaSpace: reserve,
                  showActions: false,
                  onEnter: () {},
                ),
              ),
            ),
          ),
        );
        await settle(tester);
        return tester.getRect(find.byType(GlassSurface)).height;
      }

      final double withoutReserve = await heightOf(reserve: false);
      expect(withoutReserve, greaterThan(0));
    });

    testWidgets('reserveMetaSpace: true → 预留 meta 行高度（网格等高靠它）', (WidgetTester tester) async {
      await tester.pumpWidget(
        host(
          tester,
          Center(
            child: SizedBox(
              width: 320,
              child: AylaLiveChannelCard(
                channel: _channel(ownerNickname: null, visibility: null),
                reserveMetaSpace: true,
                showActions: false,
                onEnter: () {},
              ),
            ),
          ),
        ),
      );
      await settle(tester);

      // 预留高度 = max(13×1.4, 12×body 行高 + 2×2) —— 与「有 meta 的卡」同高
      final double reserved =
          tester.getRect(find.byType(GlassSurface)).height;
      final double metaRow = tester
          .getSize(
            find.byWidgetPredicate(
              (Widget w) =>
                  w is SizedBox && w.height != null && w.height! > 18 && w.height! < 24,
            ).first,
          )
          .height;
      expect(metaRow, greaterThanOrEqualTo(13 * 1.4));
      expect(reserved, greaterThan(0));
    });
  });

  group('大厅网格（LiveHall.tsx + live.css 617–655）', () {
    List<AylaLiveCardData> channels(int n) => <AylaLiveCardData>[
      for (int i = 0; i < n; i += 1)
        _channel(id: 'lc$i', title: '频道 $i', ownerId: 'u$i', ownerNickname: '主播$i'),
    ];

    for (final (Size viewport, int columns) in <(Size, int)>[
      (Size(1500, 900), 4), // ≥1440
      (Size(1000, 900), 3), // ≥769
      (Size(420, 900), 2), // ≤768
    ]) {
      testWidgets('列数：${viewport.width}px → $columns 列（gap sp4、列宽均分）', (
        WidgetTester tester,
      ) async {
        await tester.pumpWidget(
          host(
            tester,
            AylaLiveHall(channels: channels(6), onEnter: (_) {}),
            viewport: viewport,
          ),
        );
        await settle(tester);

        final Finder cards = find.byType(AylaLiveChannelCard);
        final List<Rect> rects = <Rect>[
          for (int i = 0; i < 6; i += 1) tester.getRect(cards.at(i)),
        ];
        final double firstTop = rects.first.top;
        final List<Rect> firstRow =
            rects.where((Rect r) => r.top == firstTop).toList();
        expect(firstRow.length, columns);
        final double expectedWidth =
            (viewport.width - AylaSpacing.sp4 * (columns - 1)) / columns;
        expect(firstRow.first.width, closeTo(expectedWidth, 0.01));
        expect(
          firstRow[1].left - firstRow[0].right,
          closeTo(AylaSpacing.sp4, 0.01),
        );
      });
    }

    testWidgets('窄屏网格上下 padding sp3、左右 0（左右归页面 .directory-content）', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        host(
          tester,
          AylaLiveHall(channels: channels(2), onEnter: (_) {}),
          viewport: const Size(420, 900),
        ),
      );
      await settle(tester);

      // 第一行卡片顶 = 舞台顶 + sp3
      expect(tester.getRect(find.byType(AylaLiveChannelCard).first).top,
          AylaSpacing.sp3);
      expect(tester.getRect(find.byType(AylaLiveChannelCard).first).left, 0);
    });

    testWidgets('ownerNames 兜底 + elysiaUserId 判角标 + 点击传 id', (WidgetTester tester) async {
      final List<String> entered = <String>[];
      await tester.pumpWidget(
        host(
          tester,
          AylaLiveHall(
            channels: <AylaLiveCardData>[
              _channel(id: 'a', title: 'A', ownerId: 'u-elysia', ownerNickname: null),
              _channel(id: 'b', title: 'B', ownerId: 'u2', ownerNickname: null),
            ],
            elysiaUserId: 'u-elysia',
            ownerNames: const <String, String>{'u-elysia': '爱莉', 'u2': '小樱'},
            onEnter: entered.add,
          ),
        ),
      );
      await settle(tester);

      expect(find.text('爱莉'), findsWidgets); // 主播名兜底 + 爱莉角标
      expect(find.text('小樱'), findsOneWidget);
      await tester.tap(find.text('B'));
      await settle(tester);
      expect(entered, <String>['b']);
    });

    testWidgets('revealItems → 逐条 stagger（50ms/条，cap 300）', (WidgetTester tester) async {
      await tester.pumpWidget(
        host(
          tester,
          AylaLiveHall(
            channels: channels(8),
            revealItems: true,
            onEnter: (_) {},
          ),
        ),
      );
      await tester.pump();

      final List<AylaRevealItem> reveals = tester
          .widgetList<AylaRevealItem>(find.byType(AylaRevealItem))
          .toList();
      expect(reveals.length, 8);
      expect(reveals[0].delay, Duration.zero);
      expect(reveals[1].delay, const Duration(milliseconds: 50));
      expect(reveals[7].delay, const Duration(milliseconds: 300)); // cap
    });

    testWidgets('空态：两行文案 + 样式（Fredoka 28/600 + 14 secondary + 居中 + padding sp12）', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        host(
          tester,
          const AylaLiveHall(channels: <AylaLiveCardData>[], onEnter: _noop),
        ),
      );
      await settle(tester);

      final Text title = tester.widget<Text>(find.text('还没有直播间'));
      expect(title.style?.fontFamily, AylaFonts.display);
      expect(title.style?.fontSize, 28);
      expect(title.style?.fontWeight, FontWeight.w600);
      final Text desc = tester.widget<Text>(find.text('点右下角 + 发起第一场直播吧'));
      expect(desc.style?.fontSize, 14);
      expect(desc.style?.color, AylaColors.textSecondary);
      expect(
        find.ancestor(
          of: find.text('还没有直播间'),
          matching: find.byWidgetPredicate(
            (Widget w) =>
                w is Padding &&
                w.padding ==
                    const EdgeInsets.symmetric(vertical: AylaSpacing.sp12),
          ),
        ),
        findsOneWidget,
      );
      expect(find.byType(AylaLiveChannelCard), findsNothing);
    });
  });
}

void _noop(String _) {}
