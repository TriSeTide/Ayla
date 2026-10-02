/// 问题 4 回归锁：宽屏侧栏「添加子群」弹窗出现时，**背景仍在渲染、弹层在视口级 Overlay**。
///
/// ## 事实源（web）
/// ── `components/group/SubGroupDialog.tsx:41–42`：`createPortal` 到 `document.body`
///    （tsx 109）⇒ 弹层相对**视口**定位，不落在侧栏/群信息容器的 stacking context 里；
/// ── `styles/group.css:2131–2144`：`.subgroup-dialog-overlay` = `position:fixed; inset:0;
///    z-index:60; padding: var(--sp-4); background: rgba(70,91,146,.18);
///    backdrop-filter: blur(3px)` —— 半透明轻遮罩，**不是**不透明底；
/// ── `styles/group.css:2146–2159`：`.subgroup-dialog` 卡片本体（360 宽 / glass-bg-strong）；
/// ── `layout/ChannelSidebar.tsx:558–586`：`{present && dialog && <SubGroupDialog/>}`
///    —— 与语音/直播浮层（tsx 541 / 547）是**三个独立条件**，可同时在场。
///
/// ## 本文件锁的判据（= 问题 4「背景全空」四个候选的逐条排除）
/// 实测定位（2026-10-02，完整证据见交付报告）：
///   (a) 遮罩**不是**把背后刷成纯色/白 —— 遮罩色为 `rgba(70,91,146,.18)`（半透明），
///       极光背景在被遮罩后**仍然可见**（仅压暗 + 模糊）；
///   (b) 弹层**没有**挂进侧栏内部 —— `AylaModalOverlay` 铺满测试视口（1000 宽），
///       而不是 260 宽的侧栏卡；侧栏几何（284×620）在弹窗前后**逐值不变**；
///   (c) 侧栏与页面内容**仍在树中、尺寸不变**（不是布局塌陷）；
///   (d) 取到的是**最近的** Overlay（`channel_sidebar.dart:1094–1099` 的口径），
///       真实 app 里即 `MaterialApp` Navigator 那一个。
///
/// ## 已知观感（不在本文件断言，移交用户裁决）
/// 遮罩的 `backdrop-filter: blur(3px)`（`group.css:2142`）是**逐帧真实模糊**：
/// 实测侧栏文字锐度 22.5 → **1.0**（关闭 `maskBlur` 后回到 16.9）⇒ 15px 级正文在
/// 白底玻璃卡上被糊成一片，肉眼即用户所述的「背景全空」。该模糊**是 web 的规格**
/// （`group.css:2142` 原文 `blur(3px)`），故本文件只锁「背景没消失」，
/// 不锁「模糊强度」——后者需用户对公共件 `AylaModalOverlay` 的裁决。
library;

import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import '../lib/layout/create_sheet_forms.dart'
    show AylaCreateLiveForm, AylaCreateVoiceForm;
import '../lib/theme/preview_theme.dart';
import '../lib/widgets/base/dialogs.dart' show AylaModalOverlay;
import '../lib/widgets/group/subgroup_dialog.dart';
import '../lib/widgets/shell/channel_sidebar.dart';

const List<AylaChannelSubgroup> _kSubgroups = <AylaChannelSubgroup>[
  AylaChannelSubgroup(id: 'sg1', name: '默认组', isDefault: true, lastMessageSeq: 10),
  AylaChannelSubgroup(id: 'sg2', name: '摸鱼', lastMessageSeq: 30, unreadCount: 5),
  AylaChannelSubgroup(id: 'sg3', name: '技术', lastMessageSeq: 20, muted: true),
  AylaChannelSubgroup(id: 'sg4', name: '第四个', lastMessageSeq: 5),
  AylaChannelSubgroup(id: 'sg5', name: '第五个', lastMessageSeq: 1),
];

/// 宽屏宿主：侧栏（第二列）+ 页面内容区（第三列）。
///
/// 第三列是判据的一部分 —— web 的子群弹窗 portal 到 `body`，
/// 所以它必须与侧栏**同层**覆盖整个视口，而不是只覆盖侧栏。
Widget _host({required bool playing}) => MaterialApp(
  home: previewScope(
    Row(
      children: <Widget>[
        SizedBox(
          height: 620,
          child: AylaChannelSidebar(
            groupId: 'g1',
            groupName: '技术群',
            activeScene: AylaGroupScene.chat,
            activeSubgroupId: 'sg1',
            subgroups: _kSubgroups,
            canManageSubgroups: true,
            playing: playing,
            subgroupDirectory: AylaChannelDirectory(
              total: 5,
              hasMore: false,
              loadMore: () async {},
              refresh: () async {},
            ),
          ),
        ),
        const Expanded(
          child: Center(child: Text('页面内容区')),
        ),
      ],
    ),
  ),
);

Future<void> _openAddDialog(WidgetTester tester) async {
  final SemanticsHandle handle = tester.ensureSemantics();
  try {
    await tester.tap(find.bySemanticsLabel('编辑').first); // tsx 456–457
    await tester.pumpAndSettle();
    await tester.tap(find.bySemanticsLabel('添加子群').first); // tsx 501
    await tester.pumpAndSettle();
  } finally {
    handle.dispose();
  }
}

void main() {
  Future<void> pumpWide(WidgetTester tester, {bool playing = true}) async {
    tester.view.physicalSize = const Size(1000, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(_host(playing: playing));
    await tester.pumpAndSettle();
  }

  testWidgets('弹层铺满视口（portal 到 body 语义），不是挂在 260 宽的侧栏卡里', (
    WidgetTester tester,
  ) async {
    await pumpWide(tester);
    // 侧栏 slot 宽 284（.channel-sidebar-slot = 260 + 2×12，group.css:684）
    expect(
      tester.getSize(find.byType(AylaChannelSidebar)).width,
      284,
      reason: '侧栏 slot 宽 284（组件既有口径）',
    );

    await _openAddDialog(tester);
    expect(find.byType(AylaSubGroupDialog), findsOneWidget); // tsx 558

    // `.subgroup-dialog-overlay { position: fixed; inset: 0 }`（group.css:2131–2133）
    // ⇒ 遮罩必须铺满**测试视口**（1000 宽），而不是侧栏卡（284 宽）。
    final Size overlay = tester.getSize(find.byType(AylaModalOverlay));
    expect(overlay.width, greaterThan(900), reason: '铺满视口而非侧栏卡');
    expect(overlay.height, 800, reason: 'inset: 0 ⇒ 与视口等高');
  });

  testWidgets('遮罩档位对齐 group.css：rgba(70,91,146,.18) + blur(3px)，非不透明底', (
    WidgetTester tester,
  ) async {
    await pumpWide(tester);
    await _openAddDialog(tester);

    final AylaModalOverlay overlay = tester.widget<AylaModalOverlay>(
      find.byType(AylaModalOverlay),
    );
    expect(overlay.maskColor, const Color(0x2E465B92)); // group.css:2141
    expect(overlay.maskColor.a, closeTo(0.18, 0.005));
    expect(overlay.maskBlur, 3); // group.css:2142–2143
    expect(overlay.padding, 16); // padding: var(--sp-4)
    expect(overlay.centerBoth, isTrue, reason: 'web 无窄屏媒体查询 ⇒ 两档都居中');
  });

  testWidgets('背景仍在渲染：侧栏与页面内容区都在树中且几何逐值不变', (
    WidgetTester tester,
  ) async {
    await pumpWide(tester);
    final Rect before = tester.getRect(find.byType(AylaChannelSidebar));
    final Rect contentBefore = tester.getRect(find.text('页面内容区'));
    final Rect titleBefore = tester.getRect(find.text('技术群'));

    await _openAddDialog(tester);

    // 候选 (b)/(c) 的排除：弹窗出现**不得**让背景塌陷、移位或卸载。
    expect(find.byType(AylaChannelSidebar), findsOneWidget);
    expect(tester.getRect(find.byType(AylaChannelSidebar)), before);
    expect(tester.getRect(find.text('技术群')), titleBefore, reason: '侧栏头几何不变');
    expect(tester.getRect(find.text('页面内容区')), contentBefore, reason: '内容区几何不变');
    // 侧栏行仍在树中（被遮罩模糊 ≠ 被移除）
    expect(find.text('语音'), findsOneWidget);
    expect(find.text('摸鱼'), findsOneWidget);
  });

  testWidgets('语音/直播浮层在子群弹窗场景下惰性挂载（不进树、不发数据请求）', (
    WidgetTester tester,
  ) async {
    await pumpWide(tester);
    await _openAddDialog(tester);

    // `AylaChannelSidebarDialogs.build` 只在对应布尔为真时才挂 child
    // ⇒ 子群弹窗单独在场时，两个表单**不得**进树（= 无 initState / 无目录请求）。
    expect(find.byType(AylaCreateVoiceForm), findsNothing);
    expect(find.byType(AylaCreateLiveForm), findsNothing);
    // 子群弹窗自带唯一遮罩（AylaChannelSidebarDialogs 的 Stack 本身不画遮罩）
    expect(find.byType(AylaModalOverlay), findsOneWidget);
  });

  testWidgets('弹窗是活的：取消关闭后背景回到原状（几何不变）', (WidgetTester tester) async {
    await pumpWide(tester);
    final Rect before = tester.getRect(find.byType(AylaChannelSidebar));

    await _openAddDialog(tester);
    await tester.tap(find.text('取消')); // tsx 91–93
    await tester.pumpAndSettle();

    expect(find.byType(AylaSubGroupDialog), findsNothing);
    expect(find.byType(AylaModalOverlay), findsNothing, reason: '遮罩随弹窗一起卸载');
    expect(tester.getRect(find.byType(AylaChannelSidebar)), before);
  });

  testWidgets('playing=false（面板退场态）：弹层不挂（tsx 558 的 present 守卫）', (
    WidgetTester tester,
  ) async {
    await pumpWide(tester, playing: false);
    final SemanticsHandle handle = tester.ensureSemantics();
    // 退场态下侧栏 inert（web 加 inert/aria-hidden）⇒ 直接驱动内部状态不可行，
    // 这里只锁「没有任何弹层在场」。
    expect(find.byType(AylaSubGroupDialog), findsNothing);
    expect(find.byType(AylaModalOverlay), findsNothing);
    handle.dispose();
  });

  // ======================= 像素判据：排除候选 (a)「遮罩刷成纯色/白」 =======================

  /// 取当前帧的 RGBA 像素。
  Future<Uint8List> grab(WidgetTester tester, GlobalKey boundary) async {
    late Uint8List bytes;
    await tester.runAsync(() async {
      final RenderRepaintBoundary b =
          boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final ui.Image img = await b.toImage();
      final ByteData? data =
          await img.toByteData(format: ui.ImageByteFormat.rawRgba);
      bytes = data!.buffer.asUint8List();
      img.dispose();
    });
    return bytes;
  }

  /// 纯背景区（右下角，无任何内容）的平均亮度 + 极值跨度。
  ///
  /// 候选 (a)「遮罩把背后刷成纯色/白」会让跨度塌到 ≈ 0。
  ({double mean, double span}) sample(Uint8List p, int w, int h) {
    double sum = 0;
    int n = 0;
    double lo = 255;
    double hi = 0;
    for (int y = h - 420; y < h - 60; y += 6) {
      for (int x = w - 300; x < w - 40; x += 6) {
        final int i = (y * w + x) * 4;
        final double lum =
            p[i] * 0.299 + p[i + 1] * 0.587 + p[i + 2] * 0.114;
        sum += lum;
        n++;
        if (lum < lo) lo = lum;
        if (lum > hi) hi = lum;
      }
    }
    return (mean: sum / n, span: hi - lo);
  }

  testWidgets('像素：遮罩是半透明的（极光仍透出），不是不透明底', (WidgetTester tester) async {
    final GlobalKey boundary = GlobalKey();
    tester.view.physicalSize = const Size(1000, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      RepaintBoundary(key: boundary, child: _host(playing: true)),
    );
    await tester.pumpAndSettle();

    final ({double mean, double span}) b = sample(
      await grab(tester, boundary),
      1000,
      800,
    );

    await _openAddDialog(tester);
    expect(find.byType(AylaSubGroupDialog), findsOneWidget);

    final ({double mean, double span}) a = sample(
      await grab(tester, boundary),
      1000,
      800,
    );

    // 遮罩 = rgba(70,91,146,.18)（group.css:2141）⇒ 只压暗，不刷白也不刷黑：
    //  · 排除候选 (a)：不透明底会让 mean 塌到 ~70（纯遮罩色）或 ~255（纯白）；
    //  · 极光渐变本身有明暗跨度 ⇒ 跨度为 0 即「被刷成纯色」。
    expect(a.mean, greaterThan(140), reason: '遮罩 .18 半透明 ⇒ 背景仍明亮');
    expect(a.mean, lessThan(240), reason: '不是被刷成纯白');
    expect(a.span, greaterThan(4), reason: '极光渐变仍透出 ⇒ 未被刷成纯色');
    debugPrint(
      '像素对账：before mean=${b.mean.toStringAsFixed(1)} span=${b.span.toStringAsFixed(1)}'
      ' | after mean=${a.mean.toStringAsFixed(1)} span=${a.span.toStringAsFixed(1)}',
    );
  });
}
