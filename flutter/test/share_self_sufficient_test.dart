/// `AylaShareButton` **自给自足档**回归锁（用户 2026-10-09 裁决）。
///
/// ## 裁决原文（覆盖「从 web 推导」的结论，勿反向修改）
/// 1. **尺寸保留库内 32×32 统一**，不改成 web 的 40×40 —— `size: 32` + 图标 16 是
///    用户认可的**有意偏离**（web 里 `.favorite-toggle.is-compact` 32 与
///    `.icon-btn-40` 40 同排不等大，被判为 web 自身错误）。
/// 2. **架构按 web 改成「自给自足」**：web `components/share/ShareButton.tsx:16,22–30`
///    自己 `useState(open)` + `createPortal` 打开 `ShareSheet`，**不需要页面注入
///    onPressed** ⇒ 永远可点；Flutter 侧原先是纯注入式，页面漏传 `onShare` 就永久禁用
///    （`theme/buttons.dart:176–178` 给 `SystemMouseCursors.forbidden`）——
///    这正是用户实报的「帖子分享键鼠标悬停直接变禁止，仍无法点击」。
///
/// ## 本文件锁的六件事
/// ① 自给自足档可点（`onPressed == null` + 有 payload）；
/// ② 点击真的打开 `AylaShareSheet`；
/// ③ **向后兼容**：注入档 `onPressed` 优先级更高、行为不变；
/// ④ 两档都无 ⇒ 仍禁用（既有语义不破）；
/// ⑤ `AylaPostCard` **不依赖页面注入**：`onShare` 缺省时底排分享键也可点并能开弹窗；
/// ⑥ 尺寸仍是 32×32 + 图标 16（**用户裁决，勿改 40**）。
library;

import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RendererBinding;
import 'package:flutter_riverpod/flutter_riverpod.dart' show ProviderScope;
import 'package:flutter_test/flutter_test.dart';

import '../lib/core/models/post.dart';
import '../lib/core/models/share_payload.dart';
import '../lib/pages/share_support.dart' show AylaShareController;
import '../lib/theme/app_icons.dart' show AylaIcon;
import '../lib/theme/app_theme.dart' show buildAylaTheme;
import '../lib/theme/buttons.dart' show AylaIconButton;
import '../lib/theme/preview_theme.dart';
import '../lib/widgets/base/share.dart' show AylaShareButton, AylaShareSheet;
import '../lib/widgets/posts/post_card.dart' show AylaPostCard;

/// 帖子分享负载（与 `AylaPostCard` 内部同源构造）。
const AylaSharePayload _postPayload = AylaSharePayload(
  shareType: AylaShareType.post,
  targetId: '1',
  title: '标题',
);

void main() {
  Widget host(Widget child) => MaterialApp(home: previewScope(child));

  /// 从一棵已渲染的树里取出「本次要分享的负载」。
  ///
  /// ⚠️ `AylaPostCard` 传的是 **`payloadBuilder`（惰性）**，`payload` 字段为 null —
  /// 这是有意的（长正文的 `\s+` 正则在 build 期求值会让每张卡多花约 53µs；
  /// 见 `share.dart` 的 [AylaShareButton.payloadBuilder]）。故断言要读**求值结果**：
  /// 直接读 `payload` 字段会是 null（早期版本的本测试即因此误报）。
  AylaSharePayload resolvedPayload(WidgetTester tester, Finder finder) {
    final AylaShareButton b = tester.widget<AylaShareButton>(finder);
    return b.payload ?? b.payloadBuilder!();
  }

  /// 可**重复 pump** 的宿主（覆盖同一棵树时子级真的重建）。
  ///
  /// ⚠️ 为什么不能用 [previewTheme] 系的 host 做多段 pump：它把 `child` 塞进
  /// `Overlay(initialEntries: [...])`（`preview_theme.dart:55–70`），而
  /// `Overlay` 的 `initialEntries` **只在首次挂载时读一次** ⇒ 第二次
  /// `pumpWidget` 换新的 `post` 时，子树**根本不会重建**（实测连卡片标题都停在旧值、
  /// `identical(旧 widget, 新 widget) == true`）。那是测试宿主的既有限制，
  /// 与被测的 payload 构造无关 —— 多段 pump 一律走本宿主。
  ///
  /// `MaterialApp` 自带 `Navigator → Overlay`（分享弹层要的 `Overlay.of` 就在），
  /// `theme: buildAylaTheme()` 亦提供 `AylaTextStyles`（与 `previewTheme` 同一份）。
  Widget rebuildableHost(Widget child) => ProviderScope(
        child: MaterialApp(
          theme: buildAylaTheme(),
          home: Scaffold(backgroundColor: Colors.transparent, body: child),
        ),
      );

  AylaPost sample({
    List<AylaPostImage> images = const <AylaPostImage>[],
    String title = '深夜电台的歌单',
    String body = '今晚的歌单在这里',
  }) =>
      AylaPost(
        id: 1,
        title: title,
        body: body,
        groupId: 'g1',
        images: images,
        visibility: AylaPostVisibility.public,
      );

  // ==================== ① ② 自给自足档 ====================

  group('① 自给自足档（onPressed == null + payload）', () {
    testWidgets('可点：onPressed 落到 AylaIconButton 且非 null（不再禁用）',
        (WidgetTester tester) async {
      await tester.pumpWidget(host(const AylaShareButton(payload: _postPayload)));

      final AylaIconButton button =
          tester.widget<AylaIconButton>(find.byType(AylaIconButton));
      expect(
        button.onPressed,
        isNotNull,
        reason: 'onPressed == null 会让 buttons.dart:176–178 给 forbidden 指针',
      );
    });

    testWidgets('hover 实际指针 = click（不是 not-allowed）', (WidgetTester tester) async {
      await tester.pumpWidget(host(const AylaShareButton(payload: _postPayload)));
      final TestGesture mouse =
          await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: Offset.zero);
      addTearDown(mouse.removePointer);
      await mouse.moveTo(tester.getCenter(find.byType(AylaIconButton)));
      await tester.pump();

      expect(
        RendererBinding.instance.mouseTracker.debugDeviceActiveCursor(1),
        SystemMouseCursors.click,
        reason: '用户实报的形态就是这一个指针变成 not-allowed',
      );
    });

    testWidgets('点击 ⇒ 打开 AylaShareSheet', (WidgetTester tester) async {
      await tester.pumpWidget(host(const AylaShareButton(payload: _postPayload)));
      expect(find.byType(AylaShareSheet), findsNothing);

      await tester.tap(find.byType(AylaIconButton));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(
        find.byType(AylaShareSheet),
        findsOneWidget,
        reason: 'web `ShareButton.tsx` 内部 portal 出 ShareSheet（自给自足）',
      );
    });

    testWidgets('自建控制器在 dispose 时回收（不泄漏）', (WidgetTester tester) async {
      await tester.pumpWidget(host(const AylaShareButton(payload: _postPayload)));
      // 换掉整棵树 ⇒ 触发 dispose；有泄漏/双重 dispose 会在这里抛。
      await tester.pumpWidget(host(const SizedBox.shrink()));
      await tester.pump();
      expect(tester.takeException(), isNull);
    });

    testWidgets('弹层比按钮活得久：按钮卸载后弹层仍可交互（控制器不随按钮回收）',
        (WidgetTester tester) async {
      // ⚠️ 这条锁的是**第一版实现的实际缺陷**：自建控制器原本挂在按钮的 `State`
      // 上 dispose，而弹层是 Overlay 的独立子树、比按钮活得久 ⇒ 弹层会拿着已 dispose
      // 的 controller（`AylaShareController` 的 `groups/privates` getter 是
      // `??=` 惰性建 ⇒ dispose 后（置 null）再读会**偷偷重建**两条 AylaPagedList，
      // 且 `_started` 已为真 ⇒ 永不加载 ⇒ 弹层停在空态 = 泄漏 + 功能坏）。
      // 现在控制器随「弹窗关闭」回收 ⇒ 卸载按钮不影响弹层。
      await tester.pumpWidget(
        rebuildableHost(Center(child: AylaShareButton(payload: _postPayload))),
      );
      await tester.tap(find.byType(AylaIconButton));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byType(AylaShareSheet), findsOneWidget);

      // 只卸载按钮（Overlay 与宿主留着 ⇒ 弹层仍在树上）
      await tester.pumpWidget(rebuildableHost(const Center(child: SizedBox.shrink())));
      await tester.pump();
      expect(find.byType(AylaShareSheet), findsOneWidget, reason: '弹层应仍在');
      expect(tester.takeException(), isNull);

      // 继续操作弹层：切「私信」标签（会读 controller.privatePage()）
      await tester.tap(find.text('私信'), warnIfMissed: false);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      expect(
        tester.takeException(),
        isNull,
        reason: '控制器必须仍可用（不得随按钮 dispose）',
      );

      // 收尾：放掉去抖/定时器
      await tester.pump(const Duration(milliseconds: 400));
    });
  });

  // ==================== ③ ④ 向后兼容 ====================

  group('③ 注入档优先（向后兼容，签名与语义都不动）', () {
    testWidgets('给了 onPressed ⇒ 走旧路径，点击只调回调、不开弹窗',
        (WidgetTester tester) async {
      int taps = 0;
      await tester.pumpWidget(
        host(AylaShareButton(
          payload: _postPayload,
          onPressed: () => taps++,
        )),
      );

      await tester.tap(find.byType(AylaIconButton));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));

      expect(taps, 1, reason: '注入档回调必须被调用');
      expect(
        find.byType(AylaShareSheet),
        findsNothing,
        reason: '注入档由页面自己开弹窗 ⇒ 本件不得越权自作主张（其余 agent 正在改调用点）',
      );
    });

    testWidgets('onPressed == null 且无 payload ⇒ 仍禁用（既有语义不破）',
        (WidgetTester tester) async {
      await tester.pumpWidget(host(const AylaShareButton(onPressed: null)));
      expect(
        tester.widget<AylaIconButton>(find.byType(AylaIconButton)).onPressed,
        isNull,
      );
    });

    testWidgets('给了共享 controller ⇒ 由调用方持有（本件不自建、不代 dispose）',
        (WidgetTester tester) async {
      final AylaShareController controller = AylaShareController();
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        host(AylaShareButton(payload: _postPayload, controller: controller)),
      );
      await tester.tap(find.byType(AylaIconButton));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byType(AylaShareSheet), findsOneWidget);

      // 收尾：关掉弹层（发完/关闭都会 complete 那个 Future）⇒ 触发自建档的回收分支。
      // ⚠️ 这里用的是**调用方**的 controller ⇒ 该分支必须**跳过** dispose。
      await tester.pumpWidget(host(const SizedBox.shrink()));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(tester.takeException(), isNull);

      // 仍可用 = 没被本件误 dispose（dispose 后用会抛
      // 「A ChangeNotifier was used after being disposed」）。
      controller.notifyListeners();
      expect(tester.takeException(), isNull);
    });

    testWidgets('自建档：弹窗关闭后控制器被回收（重复开关不累积实例）',
        (WidgetTester tester) async {
      // 判据：连开两次，每次都应能正常构建弹层（若第一次的 controller 被提前
      // dispose 且弹层仍持有，第二次会因惰性 getter 重建 AylaPagedList 而异常/空态）。
      for (int i = 0; i < 2; i++) {
        await tester.pumpWidget(
          rebuildableHost(Center(child: AylaShareButton(payload: _postPayload))),
        );
        await tester.tap(find.byType(AylaIconButton));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        expect(find.byType(AylaShareSheet), findsOneWidget, reason: '第 ${i + 1} 次打开');
        // 关掉弹层：点遮罩（ShareSheet 的 overlay onClick = close）
        await tester.tapAt(const Offset(5, 5));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        expect(tester.takeException(), isNull, reason: '第 ${i + 1} 次关闭');
      }
    });
  });

  // ==================== ⑤ 帖子卡不依赖注入 ====================

  group('⑤ AylaPostCard 自给自足（不依赖页面注入 onShare）', () {
    testWidgets('不传 onShare ⇒ 底排分享键仍可点（onPressed 非 null）',
        (WidgetTester tester) async {
      await tester.pumpWidget(
        host(SizedBox(width: 360, child: AylaPostCard(post: sample(), onOpen: () {}))),
      );
      final AylaShareButton share = tester.widget<AylaShareButton>(
        find.byType(AylaShareButton),
      );
      expect(
        share.payload ?? share.payloadBuilder,
        isNotNull,
        reason: '卡片必须自己交出负载（web PostCard.tsx:146–153 无条件渲染的自给自足形态）；'
            '卡片走的是惰性 payloadBuilder',
      );
      expect(resolvedPayload(tester, find.byType(AylaShareButton)).targetId, '1');
      expect(
        tester
            .widget<AylaIconButton>(find.descendant(
              of: find.byType(AylaShareButton),
              matching: find.byType(AylaIconButton),
            ))
            .onPressed,
        isNotNull,
        reason: '页面漏传 onShare 时不得落到禁用（用户实报的根因）',
      );
    });

    testWidgets('不传 onShare 时点击能真的开分享弹层', (WidgetTester tester) async {
      await tester.pumpWidget(
        host(SizedBox(width: 360, child: AylaPostCard(post: sample(), onOpen: () {}))),
      );
      await tester.tap(find.byType(AylaShareButton));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byType(AylaShareSheet), findsOneWidget);
    });

    testWidgets('传了 onShare ⇒ 仍走注入档（卡片不抢页面控制权）', (WidgetTester tester) async {
      int taps = 0;
      await tester.pumpWidget(
        host(SizedBox(
          width: 360,
          child: AylaPostCard(post: sample(), onOpen: () {}, onShare: () => taps++),
        )),
      );
      await tester.tap(find.byType(AylaShareButton));
      await tester.pump();
      expect(taps, 1);
    });

    testWidgets('payload 封面回退链 = thumbnail 优先 / 否则 mediaContentUrl / 无图 null',
        (WidgetTester tester) async {
      // ⚠️ 本用例**三段 pump 换不同 post** ⇒ 必须用可重建宿主（见 [rebuildableHost]：
      // `previewTheme` 系的 Overlay 捕获会让子树停在首帧）。
      // ① 有 thumbnail ⇒ 用它
      await tester.pumpWidget(rebuildableHost(SizedBox(
        width: 360,
        child: AylaPostCard(
          post: sample(images: <AylaPostImage>[
            AylaPostImage(
              id: 1,
              media: const AylaMediaDescriptor(
                mediaId: 'm1',
                thumbnail: '/api/v1/media/m1/thumbnail',
              ),
            ),
          ]),
          onOpen: () {},
        ),
      )));
      expect(
        resolvedPayload(tester, find.byType(AylaShareButton)).cover,
        '/api/v1/media/m1/thumbnail',
      );

      // ② 无 thumbnail ⇒ mediaContentUrl(media_id)（web `PostCard.tsx:149` 的 || 链）
      await tester.pumpWidget(rebuildableHost(SizedBox(
        width: 360,
        child: AylaPostCard(
          post: sample(images: <AylaPostImage>[
            AylaPostImage(
              id: 1,
              media: const AylaMediaDescriptor(mediaId: 'm2'),
            ),
          ]),
          onOpen: () {},
        ),
      )));
      // `mediaContentUrl` 现在是绝对地址（Image/media_kit 需要 origin），但
      // `normalizeCover` 与 web 同一条规则（只接受站内相对路径）⇒ 绝对地址归 null。
      // 行为与 web 一致：没有 thumbnail 的帖子分享载荷不带封面。
      expect(
        resolvedPayload(tester, find.byType(AylaShareButton)).cover,
        isNull,
      );

      // ③ 无图 ⇒ null
      await tester.pumpWidget(rebuildableHost(SizedBox(
        width: 360,
        child: AylaPostCard(post: sample(), onOpen: () {}),
      )));
      expect(
        resolvedPayload(tester, find.byType(AylaShareButton)).cover,
        isNull,
      );
    });

    testWidgets('payload 其余字段与 web postSharePayload 入参同源',
        (WidgetTester tester) async {
      await tester.pumpWidget(host(SizedBox(
        width: 360,
        child: AylaPostCard(
          post: sample(title: '深夜电台的歌单', body: '今晚的歌单在这里'),
          onOpen: () {},
        ),
      )));
      final AylaSharePayload p =
          resolvedPayload(tester, find.byType(AylaShareButton));
      expect(p.shareType, AylaShareType.post);
      expect(p.targetId, '1'); // String(post.id)
      expect(p.title, '深夜电台的歌单');
      expect(p.subtitle, '今晚的歌单在这里'); // ≤24 字 ⇒ 原样
      expect(p.extra, <String, Object?>{'group_id': 'g1'});
    });

    testWidgets('`action` 分支**不遮蔽**底排分享键（核实项）', (WidgetTester tester) async {
      // web `PostCard.tsx:145` 的 `action` 只替换**收藏位**（`action === undefined ?
      // <FavoriteButton/> : action`），其后的 `<ShareButton>` 无条件渲染
      // ⇒ Flutter 侧 `post_card.dart:516–517` 同样只换收藏位，分享键在
      // `if (!widget.detail)` 内独立渲染 ⇒ 传 action 也必须有分享键。
      await tester.pumpWidget(host(SizedBox(
        width: 360,
        child: AylaPostCard(
          post: sample(),
          onOpen: () {},
          action: const SizedBox(width: 32, height: 32),
        ),
      )));
      expect(
        find.byType(AylaShareButton),
        findsOneWidget,
        reason: 'action 只覆盖收藏位 ⇒ 不得连带遮蔽分享键',
      );
      expect(
        tester
            .widget<AylaIconButton>(find.descendant(
              of: find.byType(AylaShareButton),
              matching: find.byType(AylaIconButton),
            ))
            .onPressed,
        isNotNull,
      );
    });

    testWidgets('详情档（detail: true）仍**不渲染**分享键（与 web 同）', (WidgetTester tester) async {
      await tester.pumpWidget(host(SizedBox(
        width: 400,
        child: AylaPostCard(post: sample(), onOpen: () {}, detail: true, expanded: true),
      )));
      expect(find.byType(AylaShareButton), findsNothing);
    });
  });

  // ==================== ⑥ 尺寸（用户裁决，勿改 40） ====================

  group('⑥ 尺寸 = 32×32 + 图标 16（用户裁决；web 的 40 是 web 自身错误）', () {
    testWidgets('自给自足档默认仍是 32×32、图标 16', (WidgetTester tester) async {
      await tester.pumpWidget(host(const AylaShareButton(payload: _postPayload)));
      final AylaIconButton button =
          tester.widget<AylaIconButton>(find.byType(AylaIconButton));
      expect(button.size, 32);
      expect(tester.getSize(find.byType(AylaIconButton)), const Size(32, 32));
      expect(tester.widget<AylaIcon>(find.byType(AylaIcon)).size, 16);
    });

    testWidgets('帖子卡底排分享键 = 32×32，与左侧收藏键 compact 同尺寸',
        (WidgetTester tester) async {
      await tester.pumpWidget(
        host(SizedBox(width: 360, child: AylaPostCard(post: sample(), onOpen: () {}))),
      );
      expect(tester.getSize(find.byType(AylaShareButton)), const Size(32, 32));
    });
  });
}
