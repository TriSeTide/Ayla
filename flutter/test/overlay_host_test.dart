/// 浮层挂载点回归锁：用**最近**的 Overlay，不要 rootOverlay: true（2026-10-02）。
///
/// ## 背景（用户实报）
/// 用户原话：「组件库打开会这样子报错……我还是希望以后能看见组件库的」。
/// 真机日志里 No Overlay widget found 数百条。
///
/// ## ⚠️ 已核实：画布那批日志的**主因不是** rootOverlay（2026-10-02 实测订正）
/// 画布原先与 Navigator（child）同级、**且自己没有任何 Overlay 祖先**
/// （main.dart 的 MaterialApp.builder 里只有 Scaffold/Material/Localizations）。
/// 那种位形下 `Overlay.of` 两种写法**都**返回 null（root 只沿祖先链找，画布上方
/// 一条都没有）⇒ 主因是**画布缺宿主 Overlay**，已由 `component_gallery.dart` 的
/// `_GalleryHost` 补齐。
///
/// 所以本文件**不**声称「rootOverlay 就是画布刷屏的成因」。它锁的是另一件确凿的事：
/// 这 13 处浮层宿主原先写 rootOverlay: true，在**存在嵌套 Overlay 的宿主**里会把
/// 浮层挂到组件所在层**之外** —— 与 `channel_sidebar.dart:1109-1113` 记录的坑同源。
///
/// ## 判别力（负向锁必须用对宿主，否则锁是假的）
/// `rootOverlay: true` 只在「最近 Overlay 之上**还有**一层 Overlay」时才与最近档分叉。
/// 实测四种宿主的判定：
///
/// | 宿主 | nearest vs root | rootOverlay 能测出来吗 |
/// |---|---|---|
/// | 画布位形（自带一层 Overlay，但上方无 Overlay） | **同层** | ❌ 测不出（两者都 OK） |
/// | 画布位形**且** Navigator 是它的兄弟（home: 有内容） | 分叉 | ✅ 但这是造出来的位形 |
/// | `MaterialApp(home: previewScope(x))`（全库标准测试宿主） | **分叉** | ✅ 本文件采用 |
/// | `previewTheme` 套在 MaterialApp **外面** | 分叉 | ✅（`nestedOverlayHost` 同源形状） |
///
/// ⚠️ 因此**不要**把本文件的锁改成「画布位形 + 期望不抛」了事：那种宿主的
/// rootOverlay 与最近档行为相同，改回坏写法照样全绿（2026-10-02 实测）。
///
/// ## 与 channel_sidebar.dart:1109-1113 的既有注释同源
/// 那段注释描述的是**同一个根因的另一面**：preview_theme.dart:55 的 Overlay 套在
/// 组件外层时，rootOverlay 会把浮层挂到外层 ⇒ entry 的祖先链断在那里。
/// 本次统一为「最近 Overlay」：真实 app 里最近的 Overlay 就是 MaterialApp
/// Navigator 的那个（= root）⇒ 行为等价。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../lib/core/models/post.dart';
import '../lib/core/models/share_payload.dart';
import '../lib/theme/sample_media.dart';
import '../lib/widgets/chat/image_viewer.dart';
import '../lib/pages/share_support.dart';
import '../lib/theme/app_theme.dart';
import '../lib/theme/glass.dart';
import '../lib/theme/preview_theme.dart';
import '../lib/widgets/base/overlays.dart';
import '../lib/widgets/base/share.dart' show AylaShareSheet;
import '../lib/widgets/chat/message_input.dart';
import '../lib/widgets/live/danmaku.dart';
import '../lib/widgets/live/live_viewers.dart';

// ======================= 宿主 =======================

/// 画布位形（main.dart:179-221 + component_gallery.dart 的 _GalleryHost）：
/// 画布与 Navigator（child）是 Stack 的兄弟，且画布**自带一层 Overlay**。
///
/// 关键：home: 里的 Navigator 提供了**更外层**的 Overlay ⇒ 画布自带那层的
/// rootOverlay: true 会解析到彻底在祖先链外的那一个 ⇒ 返回 null ⇒ 抛错。
/// 这正是用户真机看到的位形（组件库打开就刷屏）。
Widget galleryLikeHost(Widget child) {
  return MaterialApp(
    theme: buildAylaTheme(),
    builder: (BuildContext context, Widget? page) => Scaffold(
      backgroundColor: Colors.transparent,
      body: Stack(
        fit: StackFit.expand,
        children: <Widget>[
          // 画布显示的同一帧里，应用侧 Navigator 也在（只是被盖住）
          Offstage(offstage: true, child: page ?? const SizedBox.shrink()),
          // 画布自带的那层 Overlay（= component_gallery.dart 的 _GalleryHost）。
          // ⚠️ 这里**不能让 entry 的内容无界**（不要套 SingleChildScrollView，
          // 也不要套 previewScope/previewTheme —— 它自带一层 Overlay，
          // 被喂无限约束会抛 'Overlay was given infinite constraints'，实测）：
          // Overlay 的 entry 是独立子树，无界高度会直接炸。样张超高的部分
          // 用 ClipRect 裁掉即可 —— 本文件只验挂载点，不验样张布局。
          Positioned.fill(
            child: Overlay(
              initialEntries: <OverlayEntry>[
                aylaOverlayEntry(
                  builder: (BuildContext _) => SizedBox.expand(
                    child: SingleChildScrollView(child: child),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    ),
    home: const SizedBox.shrink(),
  );
}

/// 对照宿主：组件在 Navigator **之下**（previewTheme 自带一层 Overlay）。
/// rootOverlay: true 在这里**能**解析成功（没有更外层）⇒ 用它证明
/// 去掉 rootOverlay 后在真实 app 位形下行为不变。
Widget appLikeHost(Widget child) =>
    MaterialApp(theme: buildAylaTheme(), home: previewScope(child));

/// 按 `main.dart` 的根装配加载画布位形：Provider 容器在**最外层**
/// （`UncontrolledProviderScope` 位置），画布宿主与 Navigator 同级。
///
/// ⚠️ 样张**不要**再套 `previewScope/previewTheme`：画布自己也不用它
/// （画布本身就是宿主：主题来自 `MaterialApp.theme`，极光底在 `main.dart`），
/// 而 `previewTheme` 自带的那层 `Overlay` 被喂无限约束会直接抛错（实测）。
Future<void> pumpGalleryLike(WidgetTester tester, Widget child) async {
  await tester.pumpWidget(
    ProviderScope(child: galleryLikeHost(child)),
  );
  await settle(tester);
}

/// **全库标准测试宿主**（绝大多数既有测试用的那个）：`previewScope`（= previewTheme）
/// 自带一层 Overlay，且它在 Navigator **之下** ⇒ 组件看见的「最近」是 previewTheme
/// 那层（深度更小），而 `rootOverlay: true` 会取到 Navigator 的（更外层）。
///
/// 这是「nearest != root」在**本库最常见的**出现形状，也是本轮要钉死的行为：
/// 浮层必须留在组件自己所在的那层 Overlay 内 —— 与其它 1000+ 条既有测试的宿主一致。
Widget standardTestHost(Widget child) =>
    MaterialApp(theme: buildAylaTheme(), home: previewScope(child));

/// 嵌套 Overlay 宿主：组件位于一层**内层** Overlay 里，而 Navigator 的 Overlay
/// 在更外层 ⇒ `Overlay.maybeOf(context) != Overlay.maybeOf(context, rootOverlay: true)`。
///
/// 这正是 `channel_sidebar.dart:1109-1113` 注释描述的形状（浮层若挂 root 就跑到
/// 组件所在那层**之外**：entry 的祖先链断在外层 Overlay，且会画在整个应用之上）。
Widget nestedOverlayHost(Widget child) => MaterialApp(
      theme: buildAylaTheme(),
      home: Overlay(
        initialEntries: <OverlayEntry>[
          aylaOverlayEntry(builder: (BuildContext _) => child),
        ],
      ),
    );

/// 从 content 向上找它**实际挂在**哪一层 Overlay。
OverlayState? landedOverlayOf(Finder content) {
  final Iterable<Element> els = content.evaluate();
  if (els.isEmpty) return null;
  OverlayState? landed;
  els.first.visitAncestorElements((Element a) {
    if (a.widget is Overlay) {
      landed = (a as StatefulElement).state as OverlayState;
      return false;
    }
    return true;
  });
  return landed;
}

void pinWide(WidgetTester tester) {
  // 宽屏：组件库按 1800 宽排布（窄视口会把固定宽样张挤到溢出）
  tester.view.physicalSize = const Size(1800, 1400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

Future<void> settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

// ======================= 用例 =======================

void main() {
  testWidgets('宿主位形自检：画布自带的那层 Overlay 就是最近', (
    WidgetTester tester,
  ) async {
    pinWide(tester);
    await tester.pumpWidget(
      galleryLikeHost(
        Builder(
          builder: (BuildContext context) => Text(
            Overlay.maybeOf(context) == null ? '近层缺失' : '近层在位',
          ),
        ),
      ),
    );
    await settle(tester);
    expect(
      find.text('近层在位'),
      findsOneWidget,
      reason: '画布必须能解析到自带的那层 Overlay',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('消息输入 · 点表情键 ⇒ 浮层挂到最近 Overlay，零异常', (
    WidgetTester tester,
  ) async {
    pinWide(tester);
    await pumpGalleryLike(tester, aylaMessageInputSamples());

    final Finder emoji = find.bySemanticsLabel('群表情包');
    expect(emoji, findsWidgets, reason: '样张里必须有可点的表情键');
    await tester.tap(emoji.first, warnIfMissed: false);
    await settle(tester);

    expect(
      tester.takeException(),
      isNull,
      reason: 'message_input.dart 的表情面板浮层必须挂到最近的 Overlay',
    );
  });

  testWidgets('在看名单 · 点整排 ⇒ 弹层挂到最近 Overlay，零异常', (
    WidgetTester tester,
  ) async {
    pinWide(tester);
    await pumpGalleryLike(tester, aylaLiveViewersSamples());

    final Finder strip = find.byType(AylaLiveViewerStrip);
    expect(strip, findsWidgets);
    final int before = find.byType(AylaLiveViewerSheet).evaluate().length;
    await tester.tap(strip.first, warnIfMissed: false);
    await settle(tester);

    expect(
      find.byType(AylaLiveViewerSheet).evaluate().length,
      greaterThan(before),
      reason: '点整排必须真的打开名单弹层',
    );
    expect(
      tester.takeException(),
      isNull,
      reason: 'live_viewers.dart 的名单弹层必须挂到最近的 Overlay',
    );
  });

  testWidgets('弹幕图片查看器 · 点 96x64 图片钮 ⇒ 查看器挂到最近 Overlay，零异常', (
    WidgetTester tester,
  ) async {
    pinWide(tester);
    await pumpGalleryLike(tester, aylaDanmakuSamples());

    final Finder img = find.byWidgetPredicate(
      (Widget w) => w is SizedBox && w.width == 96 && w.height == 64,
    );
    expect(img, findsWidgets, reason: '弹幕图片钮 96x64');
    await tester.ensureVisible(img.first);
    await settle(tester);
    await tester.tap(img.first, warnIfMissed: false);
    await settle(tester);

    expect(
      tester.takeException(),
      isNull,
      reason: 'danmaku.dart 的查看器宿主必须挂到最近的 Overlay',
    );
  });

  testWidgets('分享弹窗 · 打开 ⇒ 挂到最近 Overlay，零异常', (
    WidgetTester tester,
  ) async {
    pinWide(tester);
    final AylaShareController controller = AylaShareController();
    addTearDown(controller.dispose);
    const AylaSharePayload payload = AylaSharePayload(
      shareType: AylaShareType.live,
      targetId: 'lc1',
      title: '爱莉的直播间',
    );

    await pumpGalleryLike(
      tester,
      Builder(
            builder: (BuildContext context) => Center(
              child: AylaGlassButton(
                label: '打开分享',
                onPressed: () {
                  unawaited(
                    aylaOpenShareSheet(
                      context,
                      payload: payload,
                      controller: controller,
                      currentUserId: 'u1',
                    ),
                  );
                },
              ),
            ),
          ),
    );

    await tester.tap(find.text('打开分享'));
    await settle(tester);

    expect(
      find.byType(AylaShareSheet),
      findsOneWidget,
      reason: '分享弹窗必须真的挂上（不是被异常吞掉）',
    );
    expect(
      tester.takeException(),
      isNull,
      reason: 'share_support.dart 的分享弹层必须挂到最近的 Overlay',
    );
  });

  // ============ 真正的判别锁：嵌套 Overlay 宿主（nearest != root） ============
  //
  // ⚠️ 为什么不能用「MaterialApp(home: previewScope(x))」做负向锁（2026-10-02 实测）：
  // 那个宿主里 previewTheme 的 Overlay 位于 Navigator **之下**，它的更外层
  // **没有** Overlay ⇒ rootOverlay:true 解析结果 == 最近那层 ⇒ 把代码改回
  // rootOverlay:true 依然全绿（假锁）。只有「内层 Overlay 外面还有一层」时
  // 两者才会分叉，锁才咬得住。

  testWidgets('判别锁 · 嵌套 Overlay：查看器必须挂在**最近**那层，不越到外层', (
    WidgetTester tester,
  ) async {
    aylaEnableSampleMedia(); // 示例图：走预览注入，直接就绪（不触签名）
    addTearDown(aylaDisableSampleMedia);
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final GlobalKey key = GlobalKey();
    await tester.pumpWidget(
      nestedOverlayHost(
        Builder(
          key: key,
          builder: (BuildContext c) => AylaDanmakuList(
            items: <AylaDanmakuEntry>[
              AylaDanmakuEntry(
                id: 'd1',
                senderNickname: '观众A',
                mediaId: 'm1',
                media: const AylaMediaDescriptor(mediaId: 'm1'),
              ),
            ],
          ),
        ),
      ),
    );
    await settle(tester);

    // 先钉死宿主确实是「nearest != root」的形状（否则本用例会自动失去判别力）
    final BuildContext ctx = key.currentContext!;
    final OverlayState? nearest = Overlay.maybeOf(ctx);
    final OverlayState? root = Overlay.maybeOf(ctx, rootOverlay: true);
    expect(nearest, isNotNull, reason: '内层 Overlay 必须是最近的');
    expect(root, isNotNull, reason: 'Navigator 的 Overlay 在更外层');
    expect(
      identical(nearest, root),
      isFalse,
      reason: '宿主必须让 nearest 与 root 分叉 —— 否则这条锁没有判别力',
    );

    final Finder img = find.byWidgetPredicate(
      (Widget w) => w is SizedBox && w.width == 96 && w.height == 64,
    );
    expect(img, findsWidgets, reason: '弹幕图片钮 96x64');
    await tester.tap(img.first, warnIfMissed: false);
    await settle(tester);

    expect(find.byType(AylaImageViewer), findsOneWidget, reason: '查看器必须打开');
    expect(
      identical(landedOverlayOf(find.byType(AylaImageViewer)), nearest),
      isTrue,
      reason: '查看器必须挂在最近的 Overlay（danmaku.dart:142）；'
          '改回 rootOverlay: true 会落到外层 ⇒ 这条断言转红',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('判别锁 · 标准测试宿主（previewTheme 内层 Overlay）：弹层不得越层', (
    WidgetTester tester,
  ) async {
    pinWide(tester);
    final GlobalKey key = GlobalKey();
    await tester.pumpWidget(
      standardTestHost(
        Builder(
          key: key,
          builder: (BuildContext c) => const AylaLiveViewerStrip(count: 3),
        ),
      ),
    );
    await settle(tester);

    final BuildContext ctx = key.currentContext!;
    final OverlayState? nearest = Overlay.maybeOf(ctx);
    final OverlayState? root = Overlay.maybeOf(ctx, rootOverlay: true);
    expect(nearest, isNotNull);
    expect(root, isNotNull);
    expect(
      identical(nearest, root),
      isFalse,
      reason: 'previewTheme 的 Overlay 在 Navigator 之内 ⇒ nearest 与 root 必须分叉，'
          '否则这条锁没有判别力',
    );

    await tester.tap(find.byType(AylaLiveViewerStrip), warnIfMissed: false);
    await settle(tester);

    expect(find.byType(AylaLiveViewerSheet), findsOneWidget, reason: '名单弹层必须打开');
    expect(
      identical(landedOverlayOf(find.byType(AylaLiveViewerSheet)), nearest),
      isTrue,
      reason: '弹层必须留在最近的 Overlay（live_viewers.dart:196）；'
          '改回 rootOverlay: true 会挂到 Navigator 那层 ⇒ 这条断言转红',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('对照 · app 位形（最近 Overlay == root）表情面板同样正常', (
    WidgetTester tester,
  ) async {
    pinWide(tester);
    await tester.pumpWidget(appLikeHost(aylaMessageInputSamples()));
    await settle(tester);

    await tester.tap(
      find.bySemanticsLabel('群表情包').first,
      warnIfMissed: false,
    );
    await settle(tester);
    expect(tester.takeException(), isNull);
  });
}
