/// B2-4：主播头像 + 推流地址复制区定向测试 —— 逐条对照
/// `components/live/LiveHostAvatar.tsx`(52) / `LiveStreamAddresses.tsx`(72) /
/// `LiveCreate.tsx:15–18`、`live.css:206–229/249–257`、`app.css:3443–3477`。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../lib/theme/glass.dart';
import '../lib/theme/preview_theme.dart';
import '../lib/theme/tokens.dart';
import '../lib/widgets/avatar_halo.dart';
import '../lib/widgets/live_studio.dart';

void main() {
  Widget host(
    WidgetTester tester,
    Widget child, {
    Size viewport = const Size(1000, 700),
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

  group('obsServerFromRtmpUrl（LiveCreate.tsx:15–18）', () {
    test('取最后一个 / 之前；无斜杠原样返回；前导斜杠不切（idx > 0 守卫）', () {
      expect(
        obsServerFromRtmpUrl('rtmp://live.elysium.local/app/stream-9f2c'),
        'rtmp://live.elysium.local/app',
      );
      expect(obsServerFromRtmpUrl('rtmp:xyz'), 'rtmp:xyz');
      expect(obsServerFromRtmpUrl('/only-slash'), '/only-slash');
      expect(obsServerFromRtmpUrl('a/b/c'), 'a/b');
    });
  });

  group('AylaLiveHostAvatar（tsx 40–51）', () {
    testWidgets('label 回退链四级：资料昵称 → 用户名 → owner_nickname → 「主播」', (
      WidgetTester tester,
    ) async {
      // ⚠️ 一个用例里不能多次 pumpWidget 换 props（`previewScope` 的 Overlay 只在首次创建生效）
      // ⇒ 用树内 StatefulBuilder 逐档切态。
      const List<AylaLiveHostAvatar> cases = <AylaLiveHostAvatar>[
        AylaLiveHostAvatar(
          hostNickname: '爱莉',
          hostUsername: 'elysia',
          ownerNickname: '频道昵称',
        ),
        AylaLiveHostAvatar(hostUsername: 'elysia', ownerNickname: '频道昵称'),
        AylaLiveHostAvatar(ownerNickname: '频道昵称'),
        AylaLiveHostAvatar(),
        AylaLiveHostAvatar(hostNickname: '', ownerNickname: '频道昵称'),
      ];
      int idx = 0;
      late StateSetter setLocal;
      await tester.pumpWidget(
        host(
          tester,
          StatefulBuilder(
            builder: (BuildContext context, StateSetter setState) {
              setLocal = setState;
              return cases[idx];
            },
          ),
          viewport: const Size(400, 200),
        ),
      );
      await settle(tester);

      Future<String> labelAt(int i) async {
        setLocal(() => idx = i);
        await settle(tester);
        return tester.widget<AvatarHalo>(find.byType(AvatarHalo)).label;
      }

      expect(await labelAt(0), '爱莉');
      expect(await labelAt(1), 'elysia');
      expect(await labelAt(2), '频道昵称');
      expect(await labelAt(3), '主播');
      // 空串不算命中（web 的 `||` 语义）
      expect(await labelAt(4), '频道昵称');
    });

    testWidgets('aria = 「查看主播 X 的个人主页」；size 默认 36；在线/头像透传', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        host(
          tester,
          const Center(
            child: AylaLiveHostAvatar(
              hostNickname: '爱莉',
              avatarUrl: 'https://cdn.local/a.png',
              online: true,
            ),
          ),
        ),
      );
      await settle(tester);
      final AvatarHalo halo = tester.widget<AvatarHalo>(find.byType(AvatarHalo));
      expect(halo.semanticLabel, '查看主播 爱莉 的个人主页');
      expect(halo.size, 36); // tsx 18 `size = 36`
      expect(halo.online, isTrue);
      expect(halo.resourceUrl, 'https://cdn.local/a.png');
      // 头像本体 36；含流光环外扩 2.5×2 ⇒ 渲染盒 41（与名单骨架头像 41×41 同源）
      expect(tester.getSize(find.byType(AvatarHalo)).width, 41);
    });

    testWidgets('空头像 → 无 resourceUrl（走首字符光环）；点击走注入回调', (
      WidgetTester tester,
    ) async {
      int taps = 0;
      await tester.pumpWidget(
        host(
          tester,
          Center(
            child: AylaLiveHostAvatar(
              hostNickname: '爱莉',
              avatarUrl: '',
              onOpenProfile: () => taps += 1,
            ),
          ),
        ),
      );
      await settle(tester);
      expect(tester.widget<AvatarHalo>(find.byType(AvatarHalo)).resourceUrl, isNull);
      await tester.tap(find.byType(AvatarHalo));
      await settle(tester);
      expect(taps, 1);
    });
  });

  group('AylaLiveStreamAddresses（tsx 11–71）', () {
    testWidgets('三行：标签（64 / secondary 12）+ 值（utility 12 / 省略号 / 卡内玻璃覆写）+ 复制键', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        host(
          tester,
          const Center(
            child: AylaLiveStreamAddresses(
              rtmpUrl: 'rtmp://live.elysium.local/app/stream-9f2c',
              streamKey: 'sk_live_9f2c4a7b1e',
              flvUrl: 'http://live.elysium.local/live/stream-9f2c.flv',
            ),
          ),
        ),
      );
      await settle(tester);

      expect(find.text('服务器'), findsOneWidget);
      expect(find.text('串流密钥'), findsOneWidget);
      expect(find.text('FLV 地址'), findsOneWidget);
      // 服务器 = rtmp 去掉末段
      expect(find.text('rtmp://live.elysium.local/app'), findsOneWidget);
      expect(find.text('sk_live_9f2c4a7b1e'), findsOneWidget);
      expect(find.text('http://live.elysium.local/live/stream-9f2c.flv'), findsOneWidget);
      expect(find.text('复制'), findsNWidgets(3));

      // 标签：width 64 + 12px secondary
      final SizedBox labelBox = tester.widget<SizedBox>(
        find
            .ancestor(
              of: find.text('服务器'),
              matching: find.byType(SizedBox),
            )
            .first,
      );
      expect(labelBox.width, 64); // `.live-copy-label { width: 64px }`
      final Text label = tester.widget<Text>(find.text('服务器'));
      expect(label.style?.fontSize, 12);
      expect(label.style?.color, AylaColors.textSecondary);

      // 值：utility 12 + 单行省略
      final Text value = tester.widget<Text>(
        find.text('rtmp://live.elysium.local/app'),
      );
      expect(value.style?.fontFamily, AylaFonts.utility);
      expect(value.style?.fontSize, 12);
      expect(value.maxLines, 1);
      expect(value.overflow, TextOverflow.ellipsis);
      expect(value.softWrap, isFalse);
      // 卡内覆写：玻璃底 + radius-input + 1px 亮边
      final Iterable<Container> boxes = tester.widgetList<Container>(
        find.descendant(
          of: find.byType(AylaLiveStreamAddresses),
          matching: find.byType(Container),
        ),
      );
      final Container valueBox = boxes.firstWhere(
        (Container c) =>
            c.decoration is BoxDecoration &&
            (c.decoration! as BoxDecoration).color == AylaColors.glassBg,
      );
      final BoxDecoration deco = valueBox.decoration! as BoxDecoration;
      expect(
        (deco.borderRadius! as BorderRadius).topLeft.x,
        AylaRadii.rInput,
      );
      expect(deco.border, isNotNull);
    });

    testWidgets('卡规格：width min(100%, 960) + padding sp3', (WidgetTester tester) async {
      await tester.pumpWidget(
        host(
          tester,
          const Center(
            child: SizedBox(
              width: 1200, // 比 960 宽 ⇒ 卡应被 960 夹住
              child: AylaLiveStreamAddresses(
                rtmpUrl: 'rtmp://h/app/key',
                streamKey: 'sk',
              ),
            ),
          ),
          viewport: const Size(1400, 400),
        ),
      );
      await settle(tester);
      expect(tester.getSize(find.byType(GlassSurface)).width, 960);
      final GlassSurface glass = tester.widget<GlassSurface>(
        find.byType(GlassSurface),
      );
      expect(glass.padding, const EdgeInsets.all(AylaSpacing.sp3));
    });

    testWidgets('缺 rtmp_url / stream_key → 整个组件不渲染（tsx 19）', (WidgetTester tester) async {
      await tester.pumpWidget(
        host(
          tester,
          const Column(
            children: <Widget>[
              AylaLiveStreamAddresses(rtmpUrl: null, streamKey: 'sk'),
              AylaLiveStreamAddresses(rtmpUrl: 'rtmp://h/app/key', streamKey: null),
              AylaLiveStreamAddresses(rtmpUrl: '', streamKey: 'sk'),
              AylaLiveStreamAddresses(rtmpUrl: 'rtmp://h/app/key', streamKey: ''),
            ],
          ),
        ),
      );
      await settle(tester);
      expect(find.byType(GlassSurface), findsNothing);
      expect(find.text('服务器'), findsNothing);
    });

    testWidgets('复制 → onCopy 收到该行文本 + 「已复制」1.5s 后复位', (WidgetTester tester) async {
      final List<String> copied = <String>[];
      await tester.pumpWidget(
        host(
          tester,
          Center(
            child: AylaLiveStreamAddresses(
              rtmpUrl: 'rtmp://live.elysium.local/app/stream-9f2c',
              streamKey: 'sk_live_9f2c',
              flvUrl: 'http://live.elysium.local/a.flv',
              onCopy: (String text) async {
                copied.add(text);
                return true;
              },
            ),
          ),
        ),
      );
      await settle(tester);

      await tester.tap(find.text('复制').first); // 第一行 = 服务器
      await settle(tester);
      expect(copied, <String>['rtmp://live.elysium.local/app']);
      expect(find.text('已复制'), findsOneWidget); // tsx 44
      expect(find.text('复制'), findsNWidgets(2));

      // 1.5s 后复位（tsx 29）
      await tester.pump(AylaLiveStreamAddresses.copiedHold);
      await tester.pump();
      expect(find.text('已复制'), findsNothing);
      expect(find.text('复制'), findsNWidgets(3));
    });

    testWidgets('复制失败 → destructive 文案「复制失败，请手动选择复制」', (WidgetTester tester) async {
      await tester.pumpWidget(
        host(
          tester,
          Center(
            child: AylaLiveStreamAddresses(
              rtmpUrl: 'rtmp://h/app/key',
              streamKey: 'sk',
              onCopy: (String text) async => false,
            ),
          ),
        ),
      );
      await settle(tester);
      await tester.tap(find.text('复制').first);
      await settle(tester);

      expect(find.text('复制失败，请手动选择复制'), findsOneWidget); // `.live-form-error`
      final Text error = tester.widget<Text>(
        find.text('复制失败，请手动选择复制'),
      );
      expect(error.style?.color, AylaColors.destructive);
      expect(error.style?.fontSize, 13);
      expect(find.text('已复制'), findsNothing);
    });

    testWidgets('窄屏（≤768）→ 行交叉轴对齐 flex-start；宽屏 center', (WidgetTester tester) async {
      bool narrow = true;
      late StateSetter setLocal;
      await tester.pumpWidget(
        MaterialApp(
          home: previewScope(
            Builder(
              builder: (BuildContext context) => StatefulBuilder(
                builder: (BuildContext context, StateSetter setState) {
                  setLocal = setState;
                  final Size vp = narrow
                      ? const Size(420, 500)
                      : const Size(1000, 500);
                  return MediaQuery(
                    data: MediaQuery.of(context).copyWith(size: vp),
                    child: SizedBox.fromSize(
                      size: const Size(1000, 500),
                      child: const Center(
                        child: AylaLiveStreamAddresses(
                          rtmpUrl: 'rtmp://h/app/key',
                          streamKey: 'sk',
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
        ),
      );
      tester.view.physicalSize = const Size(1000, 500);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await settle(tester);

      Row rowNow() => tester.widget<Row>(
        find.ancestor(of: find.text('服务器'), matching: find.byType(Row)).first,
      );
      expect(rowNow().crossAxisAlignment, CrossAxisAlignment.start);

      setLocal(() => narrow = false);
      await settle(tester);
      expect(rowNow().crossAxisAlignment, CrossAxisAlignment.center);
    });
  });
}
