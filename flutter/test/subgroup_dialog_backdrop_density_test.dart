/// 问题 4 回归锁（量化版）：子群弹窗打开时，**背景含内容区仍有可辨结构**，
/// 且**关闭后逐值恢复**。
///
/// ## 判据来源：跨引擎同构实测（2026-10-02，证据见交付报告）
///
/// 用「16px 周期棋盘格」作**结构化内容**（天然可测「图案可见度」），
/// 在**同一视口 1000×800、同一 ROI、同一内容、同一算子**下分别测
/// web(Chromium) 与 Flutter(测试绑定)，取 3×3 拉普拉斯绝对值均值
/// （= Lead 所用 FIND_EDGES 的同族离散形式）：
///
/// ```
/// 引擎      ROI                        无弹窗   弹窗打开        关闭后
/// web       right   (700,60)-(960,740)  46.16   3.68 ( 8.0%)   46.16 (100.0%)
/// web       below   (320,560)-(680,780) 44.56   3.70 ( 8.3%)   44.56 (100.0%)
/// flutter   right   (700,60)-(960,740)  46.16   3.30 ( 7.2%)   46.16 (100.0%)
/// flutter   below   (320,560)-(680,780) 44.56   3.33 ( 7.5%)   44.56 (100.0%)
/// ```
///
/// ⇒ **web 自己也把背景压到 8.0%，Flutter 是 7.2%**：两侧同值同序，
/// 差异 < 1 个百分点。**「弹窗打开时背景被大幅抹平」不是 Flutter 侧偏差**，
/// 而是 web 规格 backdrop-filter: blur(3px)（styles/group.css:2142）自身的
/// 效果 —— 该规格由 lib/widgets/base/dialogs.dart 的 maskBlur 一比一承载。
///
/// 决定性的**同图对照**（把 web 的真实界面截图喂给 Flutter，施加产品同款遮罩，
/// 再与 web 自身 backdrop-filter 结果比）：三处 ROI 的残留比
/// Flutter/web = 0.81× / 0.94× / 1.12× ⇒ **两个引擎对同一输入图的衰减一致**，
/// 引擎间无实质差异。
///
/// ⚠️ 用**自然内容**测得的比值会随内容频谱大幅漂移（同一份 web 截图上，
/// 侧栏位 7.7%、消息位 10.9%、纯背景 12.2%），Lead 报的 32%/44% 即属此列；
/// 故本文件坚持用**固定周期的棋盘格**作为判据内容，保证比值可复现、可回归。
///
/// ## 本文件锁什么（双向锁：防「模糊过强」也防「模糊失效」）
///
/// 1. **结构没被抹掉**：有内容区弹窗打开后的边缘密度 ≥ 无弹窗的 [kMinRetain]
///    （web 实测 8.0%，阈值留余量）；
/// 2. **模糊确实在按 web 规格生效**：该比值 < [kMaxRetain]（无模糊对照实测 82%）
///    —— 若谁把 maskBlur 删了/调没了，这条会失败；
/// 3. **关闭后逐值恢复**：关闭后的边缘密度与打开前**相同**
///    （web 与 Flutter 实测都是 100.0%，即无不可逆渲染损坏）。
///
/// ## 与同目录 subgroup_dialog_backdrop_test.dart 的分工
/// 那份锁结构/几何/半透明（不塌陷、齐视口、不是不透明底）；
/// 本文件补像素级量化（内容可见度比例 + 可逆性）。
library;

import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import '../lib/theme/app_theme.dart';
import '../lib/theme/aurora_background.dart';
import '../lib/theme/preview_theme.dart';
import '../lib/widgets/shell/channel_sidebar.dart';

/// 结构化内容的棋盘格周期（逻辑 px）。与 web 同构实验的注入周期一致。
const double kCell = 16;

/// 有内容区弹窗打开后的边缘密度**下界**（相对无弹窗）。
///
/// 同构观测（16px 棋盘格，ROI = [kRoiContent]）：
/// - **同一张图**上 web(Chromium backdrop-filter) 与 Flutter(AylaModalOverlay)
///   的残留比一致：web 7.7% / Flutter 7.3%（侧栏位）、10.9% / 8.9%、
///   12.2% / 13.7%（三处 ROI 的 flut/web 比 = 0.81–1.12×）；
/// - Flutter 本体随 DPR 有偏移：dpr 1.0 → 6.8%、1.3 → 8.9%、2.0 → 5.0%。
///
/// 本文件把 DPR 固定为 1.0（见 [pumpWide]）⇒ 观测值 6.8%。
/// 取 3% 留约 56% 余量，同时**仍能抓出「背景被整片刷平」**
/// （不透明遮罩 / 过大 sigma 都会掉到 0%，负向验证见交付报告）。
const double kMinRetain = 0.03;

/// 上界：模糊必须**确实在生效**。
///
/// maskBlur 为 null 的对照实测 82%（只被 .18 遮罩压暗、没有模糊）；
/// 取 60% 可捕获「maskBlur 被删/被置空」的回归。
const double kMaxRetain = 0.60;

/// 高频棋盘格内容层（1 格 = [kCell]）。
class _Checker extends StatelessWidget {
  const _Checker();

  @override
  Widget build(BuildContext context) =>
      CustomPaint(size: Size.infinite, painter: _CheckerPainter());
}

class _CheckerPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final Paint dark = Paint()..color = const Color(0xFF23406E);
    final Paint light = Paint()..color = const Color(0xFFF2F5FA);
    canvas.drawRect(Offset.zero & size, light);
    int gy = 0;
    for (double y = 0; y < size.height; y += kCell, gy++) {
      int gx = 0;
      for (double x = 0; x < size.width; x += kCell, gx++) {
        if ((gx + gy).isEven) continue;
        canvas.drawRect(Rect.fromLTWH(x, y, kCell, kCell), dark);
      }
    }
  }

  @override
  bool shouldRepaint(covariant _CheckerPainter old) => false;
}

const List<AylaChannelSubgroup> _kSubgroups = <AylaChannelSubgroup>[
  AylaChannelSubgroup(
    id: 'sg1',
    name: '默认组',
    isDefault: true,
    lastMessageSeq: 10,
  ),
  AylaChannelSubgroup(id: 'sg2', name: '摸鱼', lastMessageSeq: 30, unreadCount: 5),
  AylaChannelSubgroup(id: 'sg3', name: '技术', lastMessageSeq: 20, muted: true),
];

/// 宽屏宿主：棋盘格铺满 ⇒ 侧栏玻璃**叠在棋盘格之上**（真实 app 里侧栏玻璃
/// 叠在极光背景上），弹窗经 Overlay.of 挂到 MaterialApp 的 Overlay
/// （= channel_sidebar.dart 的既定口径，与真实 app 一致）。
///
/// MaterialApp.builder 里的 [AylaAuroraBackground] 会把内容裹进
/// BackdropGroup（aurora_background.dart:1190–1191）—— 与真实 app 同结构，
/// 保证 BackdropFilter.grouped 的共享背景语义也被覆盖到。
Widget _host() => MaterialApp(
  debugShowCheckedModeBanner: false,
  theme: buildAylaTheme(),
  builder: (BuildContext ctx, Widget? child) => AylaAuroraBackground(
    animate: false,
    child: Stack(fit: StackFit.expand, children: <Widget>[child!]),
  ),
  home: previewScope(
    Stack(
      children: <Widget>[
        const Positioned.fill(child: _Checker()),
        Positioned(
          left: 0,
          top: 0,
          bottom: 0,
          child: AylaChannelSidebar(
            groupId: 'g1',
            groupName: '技术群',
            activeScene: AylaGroupScene.chat,
            activeSubgroupId: 'sg1',
            subgroups: _kSubgroups,
            canManageSubgroups: true,
            playing: true,
            subgroupDirectory: AylaChannelDirectory(
              total: 3,
              hasMore: false,
              loadMore: () async {},
              refresh: () async {},
            ),
          ),
        ),
      ],
    ),
  ),
);

/// ROI 全部**避开弹窗卡片**：卡片 width: min(360px,100%) 居中于 1000×800
/// ⇒ x 320..680、y 约 296..504（web 实测卡片矩形 [320,296,360,208]）。
const Rect kRoiContent = Rect.fromLTWH(700, 60, 260, 680); // 纯棋盘格
const Rect kRoiSidebar = Rect.fromLTWH(20, 300, 240, 300); // 侧栏玻璃之下

Future<Uint8List> _grab(WidgetTester tester, GlobalKey key) async {
  late Uint8List bytes;
  await tester.runAsync(() async {
    final RenderRepaintBoundary b =
        key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final ui.Image img = await b.toImage();
    final ByteData? data =
        await img.toByteData(format: ui.ImageByteFormat.rawRgba);
    bytes = data!.buffer.asUint8List();
    img.dispose();
  });
  return bytes;
}

double _lum(Uint8List p, int w, int x, int y) {
  final int i = (y * w + x) * 4;
  return p[i] * 0.299 + p[i + 1] * 0.587 + p[i + 2] * 0.114;
}

/// 3×3 拉普拉斯绝对值均值 —— 与 Lead 的 FIND_EDGES 同族，对「高频图案被模糊」
/// 最敏感（实测对本例的模糊档位单调：sigma=0 约 46、1 约 14、3 约 3.3、6 约 1.5）。
double _edgeDensity(Uint8List p, int w, Rect roi) {
  double sum = 0;
  int n = 0;
  for (int y = roi.top.round() + 1; y < roi.bottom.round() - 1; y++) {
    for (int x = roi.left.round() + 1; x < roi.right.round() - 1; x++) {
      sum += (4 * _lum(p, w, x, y) -
              _lum(p, w, x - 1, y) -
              _lum(p, w, x + 1, y) -
              _lum(p, w, x, y - 1) -
              _lum(p, w, x, y + 1))
          .abs();
      n++;
    }
  }
  return sum / n;
}

void main() {
  const int w = 1000;

  Future<void> pumpWide(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1000, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
  }

  /// 走**真实产品路径**开弹窗：侧栏「编辑」→「＋添加子群」（tsx 456/501）。
  Future<void> enterEditMode(WidgetTester tester) async {
    final SemanticsHandle handle = tester.ensureSemantics();
    try {
      await tester.tap(find.bySemanticsLabel('编辑').first);
      await tester.pumpAndSettle();
    } finally {
      handle.dispose();
    }
  }

  Future<void> openAddDialog(WidgetTester tester) async {
    final SemanticsHandle handle = tester.ensureSemantics();
    try {
      await tester.tap(find.bySemanticsLabel('添加子群').first);
      await tester.pumpAndSettle();
    } finally {
      handle.dispose();
    }
  }

  testWidgets('弹窗打开后：含内容 ROI 的边缘密度仍 ≥ 无弹窗的 3%（不是被刷平）', (
    WidgetTester tester,
  ) async {
    await pumpWide(tester);
    final GlobalKey key = GlobalKey();
    await tester.pumpWidget(RepaintBoundary(key: key, child: _host()));
    await tester.pumpAndSettle();
    await enterEditMode(tester);

    // 基线 = 编辑态、无弹窗。
    final Uint8List base = await _grab(tester, key);
    await openAddDialog(tester);
    expect(find.text('添加子群'), findsOneWidget); // 弹窗确实开了
    final Uint8List open = await _grab(tester, key);

    final double baseContent = _edgeDensity(base, w, kRoiContent);
    final double openContent = _edgeDensity(open, w, kRoiContent);
    final double ratio = openContent / baseContent;

    debugPrint(
      '内容区边缘密度：base=' +
          baseContent.toStringAsFixed(2) +
          ' open=' +
          openContent.toStringAsFixed(2) +
          ' (' +
          (100 * ratio).toStringAsFixed(1) +
          '%)',
    );

    expect(
      ratio,
      greaterThanOrEqualTo(kMinRetain),
      reason: '同一张图上 Chromium 7.7%/Flutter 7.3% ⇒ 背景仍保留结构，未被抹平。'
          '低于 3% 说明遮罩变成了「整片刷平」（web 规格不允许）。',
    );
    expect(
      ratio,
      lessThan(kMaxRetain),
      reason: '无模糊对照实测 82% ⇒ 该比值必须明显更低，'
          '否则 maskBlur 没生效（group.css:2142 的 blur(3px) 被丢失）。',
    );

    // 侧栏（玻璃背板之下）同样不该被抹平。
    final double baseSide = _edgeDensity(base, w, kRoiSidebar);
    final double openSide = _edgeDensity(open, w, kRoiSidebar);
    debugPrint(
      '侧栏区边缘密度：base=' +
          baseSide.toStringAsFixed(2) +
          ' open=' +
          openSide.toStringAsFixed(2) +
          ' (' +
          (100 * openSide / baseSide).toStringAsFixed(1) +
          '%)',
    );
    expect(
      openSide / baseSide,
      greaterThanOrEqualTo(kMinRetain),
      reason: '侧栏玻璃之下的内容同样必须保留（web 同构实测 7.9%）',
    );
  });

  testWidgets('关闭弹窗后：边缘密度逐值恢复（排除不可逆渲染损坏）', (WidgetTester tester) async {
    await pumpWide(tester);
    final GlobalKey key = GlobalKey();
    await tester.pumpWidget(RepaintBoundary(key: key, child: _host()));
    await tester.pumpAndSettle();
    await enterEditMode(tester);

    final Uint8List base = await _grab(tester, key);
    await openAddDialog(tester);
    await tester.tap(find.text('取消')); // tsx 91–93
    await tester.pumpAndSettle();

    final Uint8List closed = await _grab(tester, key);
    final double baseContent = _edgeDensity(base, w, kRoiContent);
    final double closedContent = _edgeDensity(closed, w, kRoiContent);

    debugPrint(
      '关闭后边缘密度：base=' +
          baseContent.toStringAsFixed(2) +
          ' closed=' +
          closedContent.toStringAsFixed(2),
    );

    // web 与 Flutter 实测关闭后都是 100.0%（逐位相同）⇒ 无不可逆损坏。
    expect(
      closedContent,
      closeTo(baseContent, 0.01),
      reason: '弹窗关闭后背景必须回到打开前的渲染状态（无残留模糊层）',
    );
    expect(
      _edgeDensity(closed, w, kRoiSidebar),
      closeTo(_edgeDensity(base, w, kRoiSidebar), 0.01),
      reason: '侧栏 ROI 同样逐值恢复',
    );
  });
}
