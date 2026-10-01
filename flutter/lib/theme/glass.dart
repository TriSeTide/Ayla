/// 玻璃基类：AylaGlassSurface / AylaGlassCard / AylaGlassButton / AylaGlassInput（全站单材料 owner）。
///
/// 事实源（逐条对应 web CSS，禁自由发挥）：
/// - 材料：`tokens.css` `--glass-bg`(.55) / `--glass-bg-strong`(.78) /
///   `--glass-border`(白 .65) / `--glass-filter`(blur 24px saturate 1.4) /
///   `--glass-shadow`(0 8px 32px .2) / `--glass-inset`(顶沿内高光 .5)
/// - 卡：`app.css .glass-card` + auroraqua.css 卡片族
///   （hover 上浮 2px + 阴影 12/40、active scale .99，300ms/200ms）
/// - 按钮：`app.css .btn/.btn-primary/.btn-glow/.btn-ghost`
///   + auroraqua.css（.btn-ghost 覆写、hover 1.02 / press .98、600ms 扫光）
/// - 输入：`app.css .field` + auroraqua.css 统一 owner
///   （`--glass-inset` 内阴影 + `--glass-filter`）与 focus 辉光边
///
/// 纪律（05 §4）：
/// - **单材料 owner**：一张卡只保留一个材料层，内部布局块不再叠玻璃/blur；
/// - **禁裸色值**：一切颜色走 [AylaColors]；
/// - **reduced-motion**（`MediaQuery.disableAnimations`）：关闭上浮/缩放/扫光，
///   保留焦点与状态反馈；手势路径不依赖动画。
///
/// ## 公开面
/// `AylaGlassConfig` · `AylaGlassSurface` · `AylaGlassShadow` · `AylaGlass` · `AylaGlassInset` · `AylaGlassCard` · `AylaCardInteraction` · `AylaGlassButtonVariant` · `AylaGlassButton` · `AylaGlassInput`

library;

import 'dart:async';
import 'dart:ui' as ui;
import 'dart:ui' show ImageFilter;

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';

import '../widgets/base/reveal.dart' show AylaRevealProgress;
import 'package:flutter/services.dart' show TextInputFormatter;
import 'package:flutter/services.dart'
    show KeyDownEvent, LogicalKeyboardKey;

import 'app_theme.dart';
import 'css_gradient.dart';
import 'tokens.dart';

/// 毛玻璃质量档 —— **性能旋钮**（默认档不改任何视觉）。
///
/// 背景逐帧流动 ⇒ 玻璃卡的 `BackdropFilter` 每帧都要重新采样并高斯模糊背后
/// 的内容（13 号 §8.5：这是全库最贵的一项）。本枚举给出三个档位：默认保持
/// web 的一比一观感，另两档是「用户拍板后才用」的性能取舍。
///
/// 切换方式：`AylaGlassConfig.quality = AylaGlassQuality.preblurred;` —— 全站
/// 玻璃件（卡片 / 按钮 / 输入框 / 导航条 / 弹层遮罩）同一次生效，组件不用改。
enum AylaGlassQuality {
  /// 真玻璃（**默认**）：`BackdropFilter` 逐帧采样 + blur（+ saturate），
  /// 与 web 的 `backdrop-filter` 逐像素等价。
  realBackdrop,

  /// 预模糊：**不装滤镜**，改用 [AylaBackdropSnapshot]（背景静态九层的低频
  /// 快照）按卡片在屏幕上的位置采样。
  ///
  /// ⚠️ **web 里没有这一档**（web 只有「真玻璃」与 `@supports` 实底两条路径，
  /// tokens.css:19 + auroraqua.css:527–551）—— 它是 **Flutter 侧的性能兜底选项**，
  /// 由用户在画布上拍板后才用；**不是默认档**，任何情况下都不得设为默认
  /// （默认必须是 [realBackdrop]，见 `test/glass_quality_test.dart`）。
  ///
  /// 代价（**降档近似，不是等价实现**）：采样的是相位无关的静态层 ⇒ 卡片里
  /// 看不到流层的动态变化；卡片若在滚动容器里且重绘被 `RepaintBoundary` 挡住，
  /// 采样会滞留在上一帧位置。
  /// 收益：整屏玻璃卡从「每帧 N 次高斯模糊」降到「N 次纹理采样」。
  preblurred,

  /// 实底：连采样都不做，面层换成 web `@supports` 降级路径的实底。
  ///
  /// **与 web 同色同透明度**：主值 = `--surface`（`#fffafb`，**无 alpha**），
  /// 事实源 = auroraqua.css:527–551（覆盖全部卡片 / 顶栏 / 侧栏 / 输入框 / 弹卡；
  /// 与 app.css:252–270 的 `.92` 段重叠时因后加载而实际生效）；
  /// 少数只在 app.css:252–270 清单里的件（别人气泡 / 回底钮 / 会话菜单 /
  /// 服务器弹层 / 历史加载 pill）用 `.92`（[AylaColors.glassOpaqueFallbackSoft]）——
  /// 由 [AylaGlassConfig.resolveBackground] 的 `opaqueSoft` 逐件选择。
  opaque,
}

/// 毛玻璃运行期配置（性能降级链，05 坑 1 / d:§9）。
///
/// web 端降级条件是「浏览器不支持 `backdrop-filter`」：`@supports not (…)` 把面层
/// 换成实底。**web 有两段、两个值**（2026-09-27 逐条核对）：
///   · auroraqua.css:527–551 → `background: var(--surface)` = `#fffafb`（**无 alpha**）；
///   · app.css:252–270      → `background: rgba(255,250,251,0.92)`（只列了少数件）。
/// 两段重叠的件由**后加载**的 auroraqua 段胜出 ⇒ 主值取 `--surface`；只落在
/// app.css 段的件（别人气泡 / 回底钮 / 会话菜单 / 服务器弹层 / 历史加载 pill）
/// 用 `.92`。Flutter 侧对应「平台/设备不适合逐帧离屏模糊」的兜底档
/// （[AylaGlassQuality.opaque]），保住可读性且不再付模糊代价。
abstract final class AylaGlassConfig {
  /// 当前质量档。**默认 [AylaGlassQuality.realBackdrop]**（与改造前逐像素
  /// 一致，见 `test/glass_quality_test.dart` 的结构锁）。
  static AylaGlassQuality quality = AylaGlassQuality.realBackdrop;

  /// **背底层纹理缓存总开关**（默认开；见 `_AylaBackdropCache`）。
  ///
  /// 打开时，面积 ≥ [kAylaBackdropCacheMinArea] 的玻璃件把背底层冻成纹理并按
  /// [kAylaBackdropCachePeriod] 错峰刷新（= web「合成层纹理缓存」的等价物）；
  /// 关闭即回到「每帧重新捕获 + 高斯模糊」的改前行为（零观感差异，只是更慢）。
  /// 用途：性能对照测试、以及万一某页出现「卡内背景不跟随」时的止血开关。
  static bool backdropCacheEnabled = true;

  /// 兼容旧 API：等价于 `quality == AylaGlassQuality.opaque`。
  ///
  /// 低端设备 / 性能告警时手动开启（置 true）即切到实底档；置回 false 回到
  /// 真玻璃档。需要「预模糊」档就直接写 [quality]。
  static bool get useOpaqueFallback => quality == AylaGlassQuality.opaque;
  static set useOpaqueFallback(bool value) {
    quality = value ? AylaGlassQuality.opaque : AylaGlassQuality.realBackdrop;
  }

  /// 是否逐帧 `BackdropFilter`（真玻璃档）。
  static bool get backdropEnabled => quality == AylaGlassQuality.realBackdrop;

  /// 是否走「预模糊」采样档（不装滤镜，改用背景低频快照）。
  static bool get preblurEnabled => quality == AylaGlassQuality.preblurred;

  /// 是否还需要「背后内容」层（真玻璃 或 预模糊）。实底档整层不装。
  static bool get backdropLayerEnabled => quality != AylaGlassQuality.opaque;

  /// 依据当前环境解析材料底色（默认 .55 / strong .78）。
  ///
  /// 实底档（[AylaGlassQuality.opaque]）返回的是 web 的降级值：
  ///   · 默认 [AylaColors.glassOpaqueFallback] = `--surface`（`#fffafb`，无 alpha）
  ///     —— auroraqua.css:527–551，web 上绝大多数玻璃件的实际降级色；
  ///   · `opaqueSoft: true` → [AylaColors.glassOpaqueFallbackSoft] = `.92`
  ///     —— app.css:252–270，只给 web 上仅命中该清单的件用
  ///     （`.bubble-other` / `.message-jump-bottom` / `.conv-menu` / `.server-pop` /
  ///      `.message-history-spinner`）。
  static Color resolveBackground({required bool strong, bool opaqueSoft = false}) {
    if (useOpaqueFallback) {
      return opaqueSoft
          ? AylaColors.glassOpaqueFallbackSoft
          : AylaColors.glassOpaqueFallback;
    }
    return strong ? AylaColors.glassBgStrong : AylaColors.glassBg;
  }

  /// `backdrop-filter: blur(Npx) saturate(1.4)` 的 Flutter 等价物。
  ///
  /// CSS 里凡带模糊的玻璃材质**都同时带 saturate(1.4)**（tokens.css
  /// `--glass-filter`、shell.css `.corner-fab`/`.message-fab` 的
  /// `blur(18px) saturate(1.4)`、按钮的 `blur(8px)` 三档）。
  /// `ColorFilter implements ImageFilter` ⇒ 可用 `ImageFilter.compose`
  /// 组合；顺序必须是 `outer: saturate`、`inner: blur`（= 先模糊后饱和，
  /// 与 CSS 一致）。**只做 blur 会丢失玻璃的通透鲜艳感**（此前实测）。
  static ImageFilter backdropFilter({required double sigma}) {
    return ImageFilter.compose(
      outer: const ColorFilter.matrix(kSaturation14), // saturate(1.4)
      inner: ImageFilter.blur(sigmaX: sigma, sigmaY: sigma),
    );
  }

  /// 只模糊、不饱和（用于 CSS 中确实没写 saturate 的场合）。
  static ImageFilter blurOnly({required double sigma}) {
    return ImageFilter.blur(sigmaX: sigma, sigmaY: sigma);
  }
}

/// 预模糊档（[AylaGlassQuality.preblurred]）的采样源 —— 背景低频快照。
///
/// 由 [AylaAuroraBackground] 在预模糊档下烘焙并登记：一张「静态九层 + 白底」
/// 的小图（长边 ≤ [maxSide]），坐标系 = 背景自己的盒（[viewport]），
/// [origin] 是它在全局坐标里的左上角。玻璃卡用 `localToGlobal` 定位后
/// `drawImageRect` 采样 —— **一次纹理采样**，没有滤镜。
///
/// 只在预模糊档被写；默认（真玻璃）档下永远是 null，玻璃卡走
/// `BackdropFilter`，零额外成本。
abstract final class AylaBackdropSnapshot {
  /// 快照长边上限（逻辑像素）。九层 radial 是低频渐变，256 足够 —— 玻璃面
  /// 上还压着 .55 半透明白底，采样细节本来就被压掉。
  static const int maxSide = 256;

  static ui.Image? _image;
  static Size _viewport = Size.zero;
  static Offset _origin = Offset.zero;
  static int _revision = 0;

  /// 当前快照（null = 未就绪 ⇒ 玻璃卡不画背后内容，退化为纯透明）。
  static ui.Image? get image => _image;

  /// 快照覆盖的视口尺寸（逻辑像素）。
  static Size get viewport => _viewport;

  /// 视口左上角在全局坐标里的位置。
  static Offset get origin => _origin;

  /// 版本号（每次登记 / 清空 +1）：采样层用它判断是否需要重绘。
  static int get revision => _revision;

  /// 登记新快照（旧图立即释放）。
  static void register({
    required ui.Image image,
    required Size viewport,
    required Offset origin,
  }) {
    _image?.dispose();
    _image = image;
    _viewport = viewport;
    _origin = origin;
    _revision++;
  }

  /// 清空（测试收尾 / 背景卸载）。
  static void clear() {
    _image?.dispose();
    _image = null;
    _viewport = Size.zero;
    _origin = Offset.zero;
    _revision++;
  }
}

/// 玻璃卡的「背后内容」层 —— 按 [AylaGlassConfig.quality] 走三条路径。
///
/// **所有玻璃件都通过本件装背后内容**（卡片 / 按钮 / 输入框 / 导航条 /
/// 弹层遮罩），不要各自直接写 `BackdropFilter`：质量档才能一次切换全站，
/// 这也是 05 §4「单材料 owner」的延续。
///
/// 默认档（[AylaGlassQuality.realBackdrop]）的 widget 结构与直接写
/// `ClipRRect(child: BackdropFilter(...))` 完全一致 ⇒ **零视觉代价**。
class AylaGlassBackdrop extends StatelessWidget {
  const AylaGlassBackdrop({
    super.key,
    required this.filter,
    this.radius,
    this.child,
    this.repaintBoundary = true,
  });

  /// 真玻璃档的滤镜（blur / blur+saturate），由 [AylaGlassConfig] 构造。
  final ImageFilter filter;

  /// 裁剪圆角（对齐 CSS 的 `border-radius` + `overflow`）；null = 不裁。
  final BorderRadius? radius;

  /// 是否为滤镜层挂独立 `RepaintBoundary`（默认 true）。
  ///
  /// ⚠️ **`SnapshotWidget` 子树内必须传 false**（2026-09-30 实机「卡片就位时消失」的根因）：
  /// `_RenderSnapshotWidget._paintAndDetachToImage` 用**独立离屏 `OffsetLayer`** 捕获子树，
  /// 捕获后 `offsetLayer.dispose()` 会连同**被 detach 进来的 repaint-boundary layer** 一起销毁
  /// （`snapshot_widget.dart:297–321`）；解冻时该 RenderObject 的 `_needsPaint` 已为 false，
  /// 重新附加的是**已 dispose 的空 layer** ⇒ 滤镜层不再绘制。
  /// 快照子树里去掉它没有代价：整卡在 [AylaGlassSurface.build] 已有自己的边界。
  final bool repaintBoundary;

  /// 滤镜层的 child；null = 纯透明 `SizedBox.expand`（只贡献滤镜层）。
  ///
  /// 极少数调用点把内容画在滤镜层内（弹层遮罩色、圆形播放键里的图标）——
  /// 真玻璃档下保持原结构，故透传；预模糊档下它被挪到采样层**之上**。
  final Widget? child;

  @override
  Widget build(BuildContext context) {
    switch (AylaGlassConfig.quality) {
      case AylaGlassQuality.opaque:
        // 实底档：面层已换成不透明底（或本来就是半透明遮罩），
        // 这里不再装任何「背后内容」层。
        return child ?? const SizedBox.expand();
      case AylaGlassQuality.preblurred:
        final Widget sampled = AylaBackdropSampler(radius: radius);
        if (child == null) return sampled;
        return Stack(
          fit: StackFit.passthrough,
          children: <Widget>[Positioned.fill(child: sampled), child!],
        );
      case AylaGlassQuality.realBackdrop:
        // ⚠️ **用 `BackdropFilter.grouped`**（2026-09-30 查官方文档后落地）：
        // 官方原文 ——「Sharing a backdrop filter layer will improve the performance of
        // **multiple** backdrop filters」；`grouped` 会自动并入**最近的 `BackdropGroup`**，
        // 与兄弟/子级 filter **共享同一份背景输入**。
        // 本应用一次入场有 12+ 张玻璃卡（+ 侧栏 + 内容区），此前**每件各自捕获一次背景**；
        // 共享后每帧只捕获一次 ⇒ 这是「多玻璃件同屏」的主要成本来源。
        // 组由 `main.dart` 的 `BackdropGroup` 提供（包裹整个 app 内容）。
        final Widget filtered = BackdropFilter.grouped(
          filter: filter,
          // child 必须是纯透明内容：只贡献滤镜层，不携带颜色。
          child: child ?? const SizedBox.expand(),
        );
        final Widget clipped = radius == null
            ? filtered
            : ClipRRect(borderRadius: radius!, child: filtered);
        // **滤镜层自己的 repaint 边界**（2026-09-27 §8.19，量化后加）。
        //
        // 事实：真实 app 的页面内容挂在 `AylaAuroraBackground.child` 下
        // （`main.dart:84–102`），而背景四层流层的动画与内容同属
        // `aurora_background.dart:1106` 那一个 `RepaintBoundary` ⇒ 背景每帧
        // 变化会让整棵内容树重绘、**玻璃滤镜层每帧重录**（定向测试实测
        // 10 帧 = 10 次；`test/repaint_boundary_audit_test.dart`）。
        // 这里给滤镜层一个独立边界：祖先/邻居重绘时它的 layer 直接复用
        // （同测 0 次），代价是每张玻璃卡多一个 `OffsetLayer`（远小于它本来
        // 就有的 `BackdropFilterLayer`）。
        // ⚠️ 若背景线把 `aurora_background.dart:1106` 的边界下移到「只包背景层」，
        // 这里就会变成冗余边界 —— 届时可连同本条注释一起评估移除。
        // ⚠️ 快照档（`repaintBoundary: false`）必须去掉它：见字段注释（解冻后空白的根因）。
        return repaintBoundary ? RepaintBoundary(child: clipped) : clipped;
    }
  }
}

/// 预模糊档的采样层：把背景低频快照按**本层在屏幕上的矩形**裁一块画出来。
///
/// 用 [CustomPaint] 而不是 `Image`：快照是整视口的，必须按位置裁取。
class AylaBackdropSampler extends StatelessWidget {
  const AylaBackdropSampler({super.key, this.radius});

  /// 与玻璃面一致的裁剪圆角。
  final BorderRadius? radius;

  @override
  Widget build(BuildContext context) {
    if (AylaBackdropSnapshot.image == null) {
      // 快照未就绪（背景没烘完 / 当前宿主没有背景）：退化为纯透明，
      // 不画白板、也不报错。
      return const SizedBox.expand();
    }
    final Widget painter = CustomPaint(
      painter: _AylaBackdropSnapshotPainter(
        context,
        AylaBackdropSnapshot.revision,
      ),
    );
    return radius == null
        ? painter
        : ClipRRect(
            borderRadius: radius!,
            clipBehavior: Clip.hardEdge,
            child: painter,
          );
  }
}

/// 把整视口快照按「本层全局矩形」裁取绘制。
class _AylaBackdropSnapshotPainter extends CustomPainter {
  _AylaBackdropSnapshotPainter(this.context, this.revision);

  /// 采样层自己的 BuildContext：paint 时用 `findRenderObject` 取全局位置。
  final BuildContext context;

  /// 采样时刻的快照版本（[AylaBackdropSnapshot.revision]）。
  final int revision;

  @override
  void paint(Canvas canvas, Size size) {
    final ui.Image? image = AylaBackdropSnapshot.image;
    final Size viewport = AylaBackdropSnapshot.viewport;
    if (image == null || viewport.isEmpty || size.isEmpty) return;
    final RenderObject? ro = context.findRenderObject();
    if (ro is! RenderBox || !ro.hasSize) return;
    // 本层左上角在全局坐标里的位置（paint 期间只读，不触发 layout）。
    final Offset topLeft = ro.localToGlobal(Offset.zero);
    final double sx = image.width / viewport.width;
    final double sy = image.height / viewport.height;
    final Rect src = Rect.fromLTWH(
      (topLeft.dx - AylaBackdropSnapshot.origin.dx) * sx,
      (topLeft.dy - AylaBackdropSnapshot.origin.dy) * sy,
      size.width * sx,
      size.height * sy,
    );
    canvas.drawImageRect(
      image,
      src,
      Offset.zero & size,
      Paint()..filterQuality = FilterQuality.low,
    );
  }

  @override
  bool shouldRepaint(covariant _AylaBackdropSnapshotPainter oldDelegate) =>
      oldDelegate.revision != revision;
}

/// 背底层快照缓存的**最小启用面积**（逻辑像素²）。
///
/// 阈值必须**同时覆盖窄屏卡片**（2026-10-01 用户实机：「不只是语音卡，窄屏都有问题的，
/// 不要再漏了」）：此前 40000（≥200×200）只放进了宽屏大卡，**窄屏两列卡只有
/// ~170×150 ≈ 26000** ⇒ 全部落到「无缓存」档 ⇒ 又变成 `Opacity` 罩在实时
/// `BackdropFilter` 上 ⇒ 实机「动画过程中卡片颜色不对」（正是宽屏靠本缓存修好的那一条）。
/// 取 20000（≈141×141）：
/// · 覆盖**窄屏的全部卡片**（两列 / 单列都好）；
/// · 仍然挡掉按钮（36×36=1296）、输入框（24 0×36≈8640）、徽标一类小件 ——
///   它们单次模糊面积小、数量极多（画布 chat 分类就有 140 个 `BackdropFilter`），
///   加捕获开销得不偿失。
const double kAylaBackdropCacheMinArea = 20000;

/// 背底层快照的**刷新周期**（静止时每张卡按自己的相位错峰重新捕获）。
///
/// 依据（`test/tmp_aurora_drift_probe_test.dart`，极光动画开）：卡区域颜色漂移
/// 250ms 只有 **|Δ|=2.3/255**、500ms 7.0、1s 13.9、2s 23.5
/// ⇒ 250ms 刷新与逐帧更新**肉眼不可辨**。
const Duration kAylaBackdropCachePeriod = Duration(milliseconds: 250);

/// **滚动期**的背底层刷新周期（更密，但**不解冻**）。
///
/// ⚠️ 为什么不「滚动时解冻、停止后重新冻结」（2026-09-30 实机第四轮）：
/// 解冻 = 结构切换 ⇒ 停止滚动那一帧要让**屏幕上所有卡**同时重新捕获
/// （= N 次同步离屏渲染 + N 次模糊）⇒ 若用户正好在那时「滚到底加载更多」，
/// 新卡入场动画与这一帧尖峰叠在一起 ⇒ 实机「最后一批卡片动画时机不对 + 顿一下」。
/// 而解冻到重新冻结之间的窗口若走裸背底层（实时模糊），窗口内每帧又是 N 次模糊，更贵。
/// ⇒ 改为**始终冻结**，只把刷新周期调密：60ms ≈ 16fps，
/// 600px/s 滚动下卡内背景滞后仅 ~36px（blur 24 之后不可辨）。
const Duration kAylaBackdropScrollPeriod = Duration(milliseconds: 60);

/// 背底层**纹理缓存** —— web「合成层纹理缓存」在 Flutter 的等价物。
///
/// ## 为什么（用户要求「看看 web 为什么不卡」——查证结果）
/// web 的入场是 WAAPI / CSS **只动 `opacity` + `transform`**
/// （`useListEntryMotion.ts:74–80`、`base.css:495–499`）——两者都是**合成属性**
/// ⇒ 元素被提升为合成层，**渲染结果（含 `backdrop-filter` 的高斯模糊）被缓存成纹理**
/// ⇒ 动画期间**零 backdrop 重算**；动画结束 `animation.cancel()` 撤销提升，但浏览器的
/// 重新光栅化是惰性、分块、逐元素的。
/// 更根本的是：**浏览器对 backdrop-filter 的结果本来就有缓存**，只在 backdrop 内容真的
/// 变化时才重算。
///
/// Flutter 的 `BackdropFilter` 语义恰恰相反：**每帧重新捕获身后内容 + 高斯模糊**，
/// 没有任何跨帧缓存（实测静止的 6 张卡连续 6 帧 34–37ms，一模一样）——
/// 这就是「原生 app 反而比 web 卡」的结构性来源。
///
/// ## 做法
/// 把**背底层**（只背底层！卡面 / 内容 / 阴影都在快照之外 ⇒ 未读徽标、图片、hover、
/// 文字更新全部照常实时）冻成纹理：
/// - **静止**：保持冻结，按 [kAylaBackdropCachePeriod] + 本卡相位**错峰刷新**
///   （每帧只让 1–2 张卡重新捕获）⇒ 每帧成本 ≈「画一张纹理」；
/// - **滚动**：卡在屏幕上移动 ⇒ backdrop 采样区域每帧都在变 ⇒ **切回实时模糊**
///   （结构切换，同 `_RenderSnapshotWidget` 的语义：切走时整个 render object 被丢弃，
///   不存在「解冻后附加已 dispose layer」的问题）；
/// - **入场**：沿用 `AylaRevealItem` 下发的 controller（它负责按 index 错峰捕获），
///   入场结束后**继续用同一个 controller** ⇒ **零成本交接**（纹理不重捕获）。
///
/// ## 视觉代价（已量化，可裁决）
/// 卡内模糊背景的更新率从逐帧降到 4fps：背景动画下 250ms 的颜色漂移是 2.3/255
/// （肉眼不可辨）；**若用户认为可辨，把 [kAylaBackdropCachePeriod] 调小或把
/// [kAylaBackdropCacheMinArea] 调大即可关闭本机制**（不涉及任何 CSS 事实源）。
class _AylaBackdropCache extends StatefulWidget {
  const _AylaBackdropCache({
    required this.child,
    required this.enabled,
    required this.entryController,
  });

  /// 背底层（[AylaGlassBackdrop]）。
  final Widget child;

  /// 面积是否够大（见 [kAylaBackdropCacheMinArea]）。
  final bool enabled;

  /// 入场期由 `AylaRevealItem` 下发的 controller（非 null = 入场中）。
  final SnapshotController? entryController;

  @override
  State<_AylaBackdropCache> createState() => _AylaBackdropCacheState();
}

class _AylaBackdropCacheState extends State<_AylaBackdropCache> {
  /// 全局序号 → 本卡**刷新相位**（每张 16ms，8 组一轮 = 0–112ms）
  /// ⇒ 同屏卡的周期刷新分散在不同帧（每帧只让 1–2 张重新捕获）。
  ///
  /// ⚠️ **只用于刷新，不用于「首次接管」**：接管窗口内本卡走的是裸背底层
  /// （= 每帧全额实时模糊，N 张卡同帧就是 N 次模糊），比「同帧各捕获一次」更贵 ——
  /// 实测依据见 `tmp_last_batch_probe_test.dart` 的窗口统计。所以接管一律**立即**做，
  /// 代价是挂载/滚动停止那一帧的集中捕获，换来之后每帧 ≈「画一张纹理」。
  static int _seq = 0;

  /// 无入场上下文时本卡自己的 controller（恒允许捕获；「解冻」一律靠**结构切换**，
  /// 不用 `allowSnapshotting = false` —— 后者会 detach + dispose 子树里的
  /// repaint-boundary layer，真实引擎上解冻帧可能画不出内容）。
  final SnapshotController _own = SnapshotController(allowSnapshotting: true);
  late final int _phaseMs = 16 * (_seq++ % 16);

  /// 入场 controller 的延续引用：入场结束后**继续用它**（纹理不重捕获 ⇒ 零成本交接）。
  ///
  /// 生命周期安全：`AylaRevealItem` 是本件的**祖先**（列表项 / 侧栏卡），两者同生共死；
  /// Flutter 的卸载顺序是**先子后父**（`_InactiveElements._unmount` 递归子级后再 unmount 自己）
  /// ⇒ 本件先释放引用，祖先随后才 dispose controller。
  SnapshotController? _inherited;

  Timer? _refreshTimer;
  ScrollPosition? _position;
  bool _scrolling = false;

  /// 当前有效的快照 controller（null = 不冻结，走实时模糊）。
  ///
  /// 入场期用 `AylaRevealItem` 下发的（它已按 index 错峰捕获）；入场结束后**继续用它**
  /// ⇒ 纹理不重捕获、零成本交接；无入场上下文的卡用自己的 `_own`。
  SnapshotController? get _active =>
      widget.entryController ?? _inherited ?? _own;

  /// 生效的 controller（面积不够 ⇒ null ⇒ 实时模糊）。
  ///
  /// ⚠️ **滚动中不再解冻**（见 [kAylaBackdropScrollPeriod]）：滚动只加密刷新周期，
  /// 结构恒定为「冻结」⇒ 没有解冻/重新冻结的尖峰，也没有「窗口内走裸背底层」的高成本。
  SnapshotController? get _effective => widget.enabled ? _active : null;

  /// 当前刷新周期：滚动期更密（卡在移动，卡内背景需要更快跟随）。
  Duration get _period =>
      _scrolling ? kAylaBackdropScrollPeriod : kAylaBackdropCachePeriod;

  @override
  void initState() {
    super.initState();
    _inherited = widget.entryController;
    _sync();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _bindScrollPosition();
  }

  @override
  void didUpdateWidget(covariant _AylaBackdropCache oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.entryController != null) _inherited = widget.entryController;
    if (oldWidget.entryController != widget.entryController ||
        oldWidget.enabled != widget.enabled) {
      _sync();
    }
  }

  /// 绑定最近祖先 `ScrollPosition`（滚动 ⇒ 卡在屏幕上移动 ⇒ 实时模糊）。
  ///
  /// 用 `visitAncestorElements` 而不是 `NotificationListener`：滚动通知只向上冒泡，
  /// 位于 `Scrollable` 子树下面的组件收不到（skill 已记录该坑）。
  void _bindScrollPosition() {
    ScrollPosition? found;
    context.visitAncestorElements((Element e) {
      if (e is StatefulElement && e.state is ScrollableState) {
        found = (e.state as ScrollableState).position;
        return false;
      }
      return true;
    });
    if (identical(found, _position)) return;
    _position?.isScrollingNotifier.removeListener(_onScrollChanged);
    _position = found;
    _position?.isScrollingNotifier.addListener(_onScrollChanged);
    _onScrollChanged();
  }

  void _onScrollChanged() {
    final bool now = _position?.isScrollingNotifier.value ?? false;
    if (now == _scrolling) return;
    setState(() => _scrolling = now);
    _sync();
  }

  /// 重新排布「冻结 / 刷新」：不冻结、或入场期时停掉刷新定时器。
  void _sync() {
    if (_effective == null) {
      _refreshTimer?.cancel();
      return;
    }
    // ⚠️ **入场期不刷新**：入场由 `AylaRevealItem` 的**错峰捕获**负责，动画中段再插一次
    // `clear()` 只会多一个尖峰（实测 `tmp_last_batch_probe_test.dart` 第 31 帧 ≈ 512ms）。
    if (widget.entryController != null) {
      _refreshTimer?.cancel();
      return;
    }
    _scheduleRefresh();
  }

  /// 周期刷新：按本卡相位错峰重新捕获（全屏卡分散在不同帧，每帧 1–2 张）。
  void _scheduleRefresh() {
    _refreshTimer?.cancel();
    _refreshTimer = Timer(
      Duration(milliseconds: _period.inMilliseconds + _phaseMs % 32),
      () {
        if (!mounted) return;
        final SnapshotController? c = _effective;
        if (c == null) return;
        c.clear(); // 重新捕获一张
        _scheduleRefresh();
      },
    );
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    _position?.isScrollingNotifier.removeListener(_onScrollChanged);
    _own.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final SnapshotController? c = _effective;
    if (c == null) return widget.child;
    return SnapshotWidget(
      // `permissive`：子树含平台视图时回退为直接渲染（不抛错）。
      mode: SnapshotMode.permissive,
      controller: c,
      child: widget.child,
    );
  }
}

/// 玻璃材料的通用绘制（底色 + 模糊 + 亮边 + 宽软阴影 + 顶沿内高光）。
///
/// 只做一层离屏模糊（每处 `BackdropFilter` = 一次离屏模糊，全站用量必须
/// 收敛到本基类；d:§4 单材料 owner）。
class AylaGlassSurface extends StatelessWidget {
  const AylaGlassSurface({
    super.key,
    required this.child,
    this.radius = AylaRadii.rCard,
    this.blur = AylaGlass.blurCard,
    this.strong = false,
    this.shadow = AylaShadows.glass,
    this.border = true,
    this.padding,
    this.radiusOverride,
    this.borderOverride,
    this.shadowTransition = Duration.zero,
    this.dimAlpha,
    this.opaqueSoft = false,
  });

  /// 内容。
  final Widget child;

  /// 圆角。
  final double radius;

  /// 模糊半径（卡片 24 / 导航 18 / 按钮 8）。
  final double blur;

  /// 是否使用强玻璃底（.78，弹层）。
  final bool strong;

  /// 实底档（[AylaGlassQuality.opaque]）用 web 的「软」降级值 `.92` 而不是
  /// `--surface`。
  ///
  /// 只给 web 上**仅命中 app.css:252–270 清单**的件开：`.bubble-other` /
  /// `.message-jump-bottom` / `.conv-menu` / `.server-pop` / `.message-history-spinner`
  /// （auroraqua.css:527–551 覆盖不到的件）。其余件保持默认 false ⇒ `--surface`。
  final bool opaqueSoft;

  /// 外阴影。
  final List<BoxShadow> shadow;

  /// 是否绘制 1px 亮边。
  final bool border;

  /// 圆角覆盖（用于「无圆角顶栏」：`BorderRadius.zero`；以及只做顶部圆角）。
  ///
  /// 传了就优先于 [radius]（后者只能表达均匀圆角）。
  final BorderRadius? radiusOverride;

  /// 边框覆盖（用于「只有下边框」的顶栏：`Border(bottom: ...)`）。
  ///
  /// 传了就优先于 [border]（后者只能表达「四边都有 / 都没有」）。
  final BoxBorder? borderOverride;

  /// 内边距。
  final EdgeInsetsGeometry? padding;

  /// 外阴影过渡时长（对应 CSS `transition: box-shadow <dur>`）。
  ///
  /// [Duration.zero]（默认）= 阴影瞬时切换；非零时用 `BoxShadow.lerpList`
  /// 在两份阴影之间插值（auroraqua.css 卡片族为 300ms、按钮族为 200ms）。
  /// 插值在 ring painter 内完成 → 即便某帧 blur 为 0 也只画形状之外，
  /// 不会出现「实心矩形闪现」。
  final Duration shadowTransition;

  /// 禁用态降透明系数（null = 不降透明）。
  ///
  /// 等价 web 的 `:disabled { opacity: .7 }`（如 `.share-bubble-card:disabled`），
  /// 但**必须按颜色降透明**、不能用整层 `Opacity`：本件的玻璃层含
  /// `BackdropFilter`，整层 Opacity 在 Windows/Impeller 下会被拒绝
  /// （`Contents::SetInheritedOpacity should never be called when
  /// Contents::CanAcceptOpacity returns false`）**且禁用态根本不生效**
  /// （2026-09-22 用户批准的全库修法，见 13 号 §6.33）。
  ///
  /// 覆盖范围：底色、亮边（含 [borderOverride]）、顶沿内高光、外阴影。
  /// **不含子内容** —— 内容层（图标/文字，无模糊）由调用方自行
  /// `Opacity(opacity: dimAlpha)` 保持同一观感。
  final double? dimAlpha;

  @override
  Widget build(BuildContext context) {
    // 入场进度（`AylaRevealItem(fadeGlass: false)` 经 [AylaRevealProgress] 下发）——
    // 无入场上下文 ⇒ null ⇒ 与改前**逐帧等价**（零行为变化）。
    // 入场进度：由 `AylaRevealItem(fadeGlass: false)` 经 [AylaRevealProgress] 下发（已带曲线）。
    // ⚠️ **不再用 `AnimatedBuilder` 重建卡面**（2026-09-30 实机反馈「还是很卡」的根因）：
    // 每帧重建会连带 `LayoutBuilder`（内高光）与阴影 `CustomPaint` 重新布局/绘制，
    // 实机 12+ 张卡同时入场时明显掉帧。改为把进度交给 `FadeTransition`（见 [_buildBody]）——
    // 它只驱动 `OpacityLayer`，**每帧不重建任何 widget**。
    // ⚠️ **整卡独立绘制边界**（2026-09-30，纯软件层优化、**零观感变化**）。
    //
    // 官方依据（`docs.flutter.dev/tools/devtools/performance` 的 Raster 一节）：
    // 「slow raster performance is often caused by Dart-level workloads that are difficult
    // for the GPU, such as unnecessary **saveLayer** calls, **intersecting opacities**,
    // **clips**, or **shadows**」—— 玻璃卡这四样全占（`BackdropFilter`/`ClipRRect`/
    // `Opacity`/阴影环）。官方的处置口径是**隔离重绘范围**（`RepaintBoundary` 一节：
    // 「Isolate widget repaints … isolate repainting to just that subtree」）：
    // 有了它，邻居变化或父级 `Transform` 变化时整卡作为**独立 layer** 被移动/复用，
    // 不再把滤镜层、阴影、内容一起拖进重绘。
    // 代价：每卡多一个 layer（官方原话「creating a new canvas uses additional memory」）。
    return RepaintBoundary(
      child: _buildBody(
        context,
        AylaRevealProgress.of(context),
        AylaRevealProgress.snapshotOf(context),
      ),
    );
  }

  /// 按入场进度 [entryT]（0→1）构建卡面。
  ///
  /// **淡入用「颜色 × t + 模糊强度 × t」表达，不产生 `OpacityLayer`** ——
  /// web 的 `.reveal-item`（`base.css:483–506`）是整层 `opacity` 淡入；Flutter 侧若
  /// 照搬会与玻璃的 `BackdropFilter` 冲突（Impeller 拒绝「Opacity 祖先 + BackdropFilter」，
  /// 见 `widgets/base/reveal.dart` 文件头），故按颜色/模糊强度等价表达：
  /// 底色、亮边、顶沿内高光、外阴影全部随 t 淡入，模糊强度同时从 0 升到 [blur]
  /// （附带收益：入场期间模糊采样更便宜 ⇒ 动画更流畅）。
  Widget _buildBody(
    BuildContext context,
    Animation<double>? entry,
    SnapshotController? snapshot,
  ) {
    final bool opaque = AylaGlassConfig.useOpaqueFallback;
    final bool reduceMotion = MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    // 禁用态降透明（[dimAlpha]）与入场淡入（[entry]）**分开**：前者按颜色表达（web 的
    // `:disabled { opacity }` 等价），后者交给 `FadeTransition`（见下方 faceLayer）。
    final double dimA = (dimAlpha ?? 1.0).clamp(0.0, 1.0);
    Color dimColor(Color c) =>
        dimA >= 1.0 ? c : c.withValues(alpha: c.a * dimA);
    List<BoxShadow> dimShadows(List<BoxShadow> list) => dimA >= 1.0
        ? list
        : <BoxShadow>[
            for (final BoxShadow sh in list) sh.copyWith(color: dimColor(sh.color)),
          ];
    BoxBorder? dimBorder(BoxBorder? b) {
      if (b == null || dimA >= 1.0) return b;
      // 只处理四边均匀的 [Border]（库内 borderOverride 的两种用法：全 null /
      // Border(bottom:)）；方向性边框（BorderDirectional）保持原样。
      if (b is Border) {
        return Border(
          top: b.top.copyWith(color: dimColor(b.top.color)),
          right: b.right.copyWith(color: dimColor(b.right.color)),
          bottom: b.bottom.copyWith(color: dimColor(b.bottom.color)),
          left: b.left.copyWith(color: dimColor(b.left.color)),
        );
      }
      return b;
    }

    // 卡面（底色 + 亮边 + 顶沿内高光）。**不含外阴影**——阴影必须在裁剪
    // 之外绘制，否则会被 ClipRRect 连同圆角裁掉（web box-shadow 在元素外侧）。
    // 圆角/边框优先用 override（支持「无圆角顶栏」与「只下边框」）
    final BorderRadius radiusValue =
        radiusOverride ?? BorderRadius.circular(radius);
    final BoxBorder? borderValue = dimBorder(borderOverride ??
        (border ? Border.all(color: AylaColors.glassBorder) : null));
    final Widget face = DecoratedBox(
      decoration: BoxDecoration(
        color: dimColor(
          AylaGlassConfig.resolveBackground(
            strong: strong,
            opaqueSoft: opaqueSoft,
          ),
        ),
        borderRadius: radiusValue,
        border: borderValue,
      ),
      child: Stack(
        children: <Widget>[
          // 顶沿内高光：`--glass-inset` = `inset 0 1px 0 rgba(255,255,255,.5)`。
          // Flutter 的 BoxShadow 无 inset 变体，且「非均匀 Border + borderRadius」
          // 会被断言拒绝，故用 `AylaInset.topHighlight(height)`——它按实际高度
          // 取 stops = 1/height，视觉上恰为 1px（固定比例近似会被拉成一条带）。
          Positioned.fill(
            child: IgnorePointer(
              child: LayoutBuilder(
                builder: (BuildContext context, BoxConstraints c) {
                  final LinearGradient inset = AylaInset.topHighlight(c.maxHeight);
                  return DecoratedBox(
                    decoration: BoxDecoration(
                      borderRadius: radiusValue,
                      gradient: dimA >= 1.0
                          ? inset
                          : LinearGradient(
                              begin: inset.begin,
                              end: inset.end,
                              stops: inset.stops,
                              colors: <Color>[
                                for (final Color color in inset.colors)
                                  dimColor(color),
                              ],
                            ),
                    ),
                  );
                },
              ),
            ),
          ),
          Padding(padding: padding ?? EdgeInsets.zero, child: child),
        ],
      ),
    );

    // 玻璃层结构（对齐 CSS `backdrop-filter: blur(24px) saturate(1.4)`）：
    //   Stack[
    //     ① BackdropFilter(blur+saturate) ← 只作用于卡背后的页面内容
    //     ② 阴影环（只画在卡外；在模糊层之上，避免被模糊采样）
    //     ③ face（.55 半透明白底 + 亮边 + 内高光）
    //   ]
    //
    // 两个 Flutter 与 CSS 的关键差异（必须这样处理，否则卡内发黑）：
    //  a) CSS 的 backdrop-filter **不含元素自身 box-shadow**，而 Flutter 的
    //     BackdropFilter 会把它所在离屏层内已绘制的内容一并模糊 → 阴影画在
    //     模糊层**之上**；
    //  b) CSS 的 box-shadow **只在 border-box 之外绘制**，Flutter 的 BoxShadow
    //     会铺满整个形状（含内部）→ 用 CustomPainter 把内部挖空。
    // 入场快照档判定 + 背底层（槽位 0 的内容）。
    //
    // ⚠️ **快照只包背底层**（2026-09-30 重构；实机「阴影被截断」「就位时消失」两条的根治）：
    // - `SnapshotWidget` 按 child 边界捕获并裁剪 ⇒ 把含阴影的整卡交给它，会把
    //   `box-shadow`（画在形状之外）裁成硬边；阴影必须在快照**之外**唯一绘制一次；
    // - 捕获走**独立离屏 layer**（`snapshot_widget.dart:297–321`）⇒ 子树里的
    //   repaint-boundary layer 会被 detach + dispose，解冻后可能不再绘制
    //   ⇒ 快照子树内一律 `repaintBoundary: false`（整卡本身已有自己的边界）；
    // - 槽位结构与普通档**完全一致**（背底层 / 阴影 / 卡面）⇒ 解冻那一帧
    //   （`AylaRevealItem` 把 snapshot 传回 null）只有 slot0 换内容，
    //   卡面与阴影的 element 稳定复用，调用方内容（可能带 State）不会重建。
    final bool useSnapshot = entry != null && snapshot != null && !opaque;
    // 非空局部（供 slot0 做类型提升）：Dart 不会把 `useSnapshot` 的成立传导回 `snapshot`。
    final SnapshotController? frozen = useSnapshot ? snapshot : null;
    final Widget backdropLayer = AylaGlassBackdrop(
      radius: radiusValue,
      // ⚠️ **恒不挂滤镜层边界**：本件会被 [_AylaBackdropCache] 的 `SnapshotWidget` 包住
      //（捕获用独立离屏 layer ⇒ 子树里的 repaint-boundary layer 会被 detach + dispose）；
      // 而整卡在 `build` 里已有自己的 `RepaintBoundary`（2026-09-30 第九批），
      // 背景层也已有独立边界（`aurora_background.dart`）⇒ 这一层边界已是冗余。
      repaintBoundary: false,
      filter: ImageFilter.compose(
        // 外层：饱和度 1.4（在模糊结果上做，等价 CSS 顺序）
        outer: const ColorFilter.matrix(kSaturation14),
        // 内层：blur(24px)（t:--glass-filter）
        inner: ImageFilter.blur(
          // **恒定**半径（不乘 t）—— 见下方 ① 处注释：随 t 变化会让滤镜层每帧重建。
          sigmaX: blur,
          sigmaY: blur,
        ),
      ),
    );
    final Widget glassBody = opaque
        ? face
        : Stack(
            fit: StackFit.passthrough,
            clipBehavior: Clip.none,
            children: <Widget>[
              // ① 模糊 + 饱和层：CSS `backdrop-filter: blur(24px) saturate(1.4)`
              //    的完整等价实现。
              //
              //    关键 API（dart:ui）：`ColorFilter implements ImageFilter`
              //    → 可作 BackdropFilter 的 filter；配合
              //    `ImageFilter.compose(outer:, inner:)` 组合两个滤镜，
              //    即 result = outer(inner(source))。
              //    compose 已在多端可用（sky_engine painting.dart:4406）。
              // blur <= 0 → 不建滤镜层：sigma 0 只是白白多一个 saveLayer，
              // 且嵌入式场景（如组件画布里的查看器样张）会采样宿主页面造成糊页。
              // ⚠️ **滤镜必须恒定**（2026-09-30 实机反馈「原生比 web 还卡」的根因就在这）：
              // 若让 sigma 随入场进度变化，`BackdropFilter.filter` 每帧都是新值 ⇒
              // Impeller 每帧重建滤镜层 + 重采样整块背景，比 web 的整层 opacity 贵得多。
              // web 的 `opacity` 淡入**不改变 blur 半径**（恒 24px，只有整体透明度在变）⇒
              // 这里同样保持 sigma 恒定，淡入**完全交给颜色**（面层/亮边/内高光/阴影 × t）。
              // 入场最初不建滤镜层（省一次 saveLayer；此时面层几乎全透明，也避免露出模糊块）。
              if (blur > 0)
              Positioned.fill(
                // 背后内容层统一走 AylaGlassBackdrop（质量档 owner，§8.17）：
                // 真玻璃档 = BackdropFilter，预模糊档 = 采样，实底档 = 不画。
                //
                // ⚠️ **入场快照档**（`AylaRevealProgress.snapshot` 非 null）把这一层
                // 整层冻成纹理：外层 `Opacity` 作用在**纹理**上 ⇒ 模糊必然跟着淡
                //（不受 Impeller「拒绝把继承不透明度传给 BackdropFilter」影响 ⇒
                // 根治实机「动画过程中变色」），且移动的是纹理 ⇒ 不再每帧重采样 + 重模糊
                //（实测 raster 收益 22×：`test/tmp_snapshot_gain_probe_test.dart`）。
                //
                // ⚠️ **背底层纹理缓存**（2026-09-30 第十二批，用户要求「看 web 为什么不卡」）：
                // `_AylaBackdropCache` 把大卡的背底层冻成纹理并错峰刷新，等价 web 的
                // **合成层纹理缓存**（web 的入场只动 opacity/transform ⇒ 模糊结果被缓存、
                // 动画期零重算；Flutter 的 `BackdropFilter` 是每帧重采 + 重模糊）。
                // 面积阈值由 `LayoutBuilder` 给出：小件（按钮/输入框）不开，避免放大开销。
                child: LayoutBuilder(
                  builder: (BuildContext context, BoxConstraints c) {
                    final bool big = AylaGlassConfig.backdropCacheEnabled &&
                        c.maxWidth.isFinite &&
                        c.maxHeight.isFinite &&
                        c.maxWidth * c.maxHeight >= kAylaBackdropCacheMinArea;
                    return _AylaBackdropCache(
                      enabled: big,
                      // 入场期沿用 `AylaRevealItem` 下发的 controller（错峰捕获在那边）；
                      // 入场结束后本件继续沿用它 ⇒ 零成本交接，不再有「解冻帧」峰值。
                      entryController: frozen,
                      child: backdropLayer,
                    );
                  },
                ),
              ),
              // ② 阴影环（在模糊层之上、卡面之下；只画形状之外）
              if (shadow.isNotEmpty)
                Positioned.fill(
                  child: IgnorePointer(
                    // ⚠️ **性能（2026-09-30 实机「侧栏好顿」的另一处来源）**：入场时
                    // `AylaRevealItem` 的 `Transform` 每帧 `markNeedsPaint`，**同一层内**
                    // 未加边界的兄弟会跟着重绘 —— 阴影环的 `CustomPaint` 里是
                    // `Path.combine(difference, …)` 布尔运算，逐帧重算代价很高。
                    // 它自身只在 [shadowTransition] 时变化 ⇒ 给一个独立边界即可复用 layer
                    //（父级变换只移动该 layer，不重新绘制）。
                    child: RepaintBoundary(
                      child: shadowTransition == Duration.zero || reduceMotion
                        ? CustomPaint(
                            painter: _OuterShadowPainter(
                              radius: radiusValue,
                              shadows: dimShadows(shadow),
                            ),
                          )
                        : TweenAnimationBuilder<List<BoxShadow>>(
                            tween: _ShadowListTween(end: dimShadows(shadow)),
                            duration: shadowTransition,
                            curve: AylaCurves.auroraqua,
                            builder: (BuildContext context,
                                List<BoxShadow> value, Widget? _) {
                              return CustomPaint(
                                painter: _OuterShadowPainter(
                                  radius: radiusValue,
                                  shadows: value,
                                ),
                              );
                            },
                          ),
                      ),
                  ),
                ),
              // ③ 卡面
              face,
            ],
          );

    // 入场淡入：**整块（含玻璃滤镜层）一起淡入** —— 与 web 的 `.reveal-item`
    //（`base.css:483–506`）和 `auroraqua-*-in`（`auroraqua.css:8–26`）的**整层 opacity**
    // 逐帧等价。
    //
    // ⚠️ **为什么必须连滤镜层一起包**（2026-09-30 实机截图）：「web 端根本就没有这一帧」——
    // 只包面层时，`t = 0` 面层透明而 `BackdropFilter` 仍在工作 ⇒ 卡片/侧栏位置露出
    // 一块被模糊的背景（实机表现为大片蓝/粉色块）。
    //
    // ⚠️ 代价：`Opacity` 祖先 + `BackdropFilter` 后代会被 Impeller 记一条 **debug** 校验日志
    //（`Contents::SetInheritedOpacity should never be called when …`）。这是「一比一还原
    // web 入场」的必要代价 —— web 的 `backdrop-filter` 由浏览器合成层缓存，Flutter 无等价
    // 机制；release 构建无此日志。性能上 `FadeTransition` 只驱动 `OpacityLayer`，
    // **不重建任何 widget**（对比按颜色 × t 重建卡面）。
    // ⚠️ 快照档的完整说明见上方 `useSnapshot` / `backdropLayer`（只冻背底层、
    // 阴影留在快照之外、槽位与非快照档一致 ⇒ 解冻只换 slot0 的内容）。
    // ⚠️ **不再自己包一层 `FadeTransition`**（2026-09-30）：淡入统一由外层 `AylaRevealItem`
    // 的**整层 `Opacity`** 负责（= web 的 `.reveal-item` 语义）。这里再包一层会与它相乘
    //（t²）⇒ 中间态过白 —— 实机「动画过程中变色」的另一半来源；且多推一个 `OpacityLayer`
    // 属官方点名的 `intersecting opacities`。
    return glassBody;
  }
}

/// `box-shadow` 的「只画形状之外」工具（等价 CSS 的 border-box 裁剪）。
///
/// **为什么需要**：CSS 规范规定 `box-shadow` **不在 border-box 内部绘制**
/// （outer shadow is clipped inside the border-box）；而 Flutter 的
/// [BoxShadow] / `BoxDecoration(boxShadow:)` **会铺满整个形状含内部**：
/// - 半透明卡面 → 阴影透过卡面被看见，卡内发灰暗；
/// - 悬停时给按钮加 `--glass-shadow-nav`（`0 0 8px rgba(157,191,230,.3)`）
///   → 冰蓝阴影染进按钮内部，**悬停瞬间闪一下蓝色**。
///
/// 本项目此前只在 [AylaGlassSurface] 内部（私有 `_OuterShadowPainter`）处理过，
/// 导致其他组件各自裸用 `BoxShadow` 时重现同一问题 → 提升为公共 API。
abstract final class AylaGlassShadow {
  /// 外阴影层：铺满父级，但**只在形状之外**绘制 [shadows]。
  ///
  /// 用法（叠在面层**之下**）：
  /// ```dart
  /// Stack(children: <Widget>[
  ///   Positioned.fill(child: AylaGlassShadow.ring(
  ///     radius: BorderRadius.circular(12), shadows: AylaShadows.nav)),
  ///   face,
  /// ])
  /// ```
  static Widget ring({
    required BorderRadius radius,
    required List<BoxShadow> shadows,
  }) {
    if (shadows.isEmpty) return const SizedBox.shrink();
    return CustomPaint(painter: _OuterShadowPainter(radius: radius, shadows: shadows));
  }

  /// 在 [child] 之下叠一层**只画形状之外**的外阴影（形状尺寸取 child 的）。
  ///
  /// [shadows] 变化时按 CSS `transition: box-shadow` 语义插值；
  /// 两侧都有阴影时不会出现「blur 从 0 起步」的硬边（形状内部始终被挖空）。
  /// [shadows] 为空 = 不画（web 未声明 box-shadow 的构件）。
  ///
  /// [curve] 是插值缓动：CSS 里各构件的 `transition` 缓动**不统一**——按钮组用
  /// `--auroraqua-ease`（= `ease`，本参数默认值，既有调用点全部不变），
  /// 而 `.session-activity-ball` 用的是 `--ease-out`（`shell.css:495–496`，150ms）
  /// ⇒ 该处显式传 [AylaCurves.easeOut]。
  static Widget animatedRing({
    required Widget child,
    required BorderRadius radius,
    required List<BoxShadow> shadows,
    Duration duration = AylaDurations.auroraqua,
    Cubic curve = AylaCurves.auroraqua,
  }) {
    if (shadows.isEmpty) return child;
    return Stack(
      clipBehavior: Clip.none,
      children: <Widget>[
        Positioned.fill(
          child: IgnorePointer(
            child: _AnimatedShadowRing(
              radius: radius,
              shadows: shadows,
              duration: duration,
              curve: curve,
            ),
          ),
        ),
        child,
      ],
    );
  }

  /// 在 [child] 之下叠一层**淡入淡出**的外阴影环（用于「无 → 有」的场景：
  /// hover/focus 才出现的光晕）。
  ///
  /// 为什么不用 [animatedRing]：从「无阴影」插值时 `BoxShadow.lerp` 会把
  /// blurRadius 从 0 拉起，头几帧是**硬边**（实测会闪一下）；淡入固定阴影
  /// 既无硬边，也与 CSS 观感一致。
  static Widget fadeRing({
    required Widget child,
    required BorderRadius radius,
    required List<BoxShadow> shadows,
    required bool visible,
    Duration duration = AylaDurations.button,
  }) {
    if (shadows.isEmpty) return child;
    return Stack(
      clipBehavior: Clip.none,
      children: <Widget>[
        Positioned.fill(
          child: IgnorePointer(
            child: AnimatedOpacity(
              duration: duration,
              curve: AylaCurves.auroraqua,
              opacity: visible ? 1.0 : 0.0,
              child: CustomPaint(
                painter: _OuterShadowPainter(radius: radius, shadows: shadows),
              ),
            ),
          ),
        ),
        child,
      ],
    );
  }
}

/// [AylaGlassShadow.animatedRing] 的插值实现（reduced-motion 时不做过渡）。
class _AnimatedShadowRing extends StatelessWidget {
  const _AnimatedShadowRing({
    required this.radius,
    required this.shadows,
    required this.duration,
    this.curve = AylaCurves.auroraqua,
  });

  final BorderRadius radius;
  final List<BoxShadow> shadows;
  final Duration duration;
  final Cubic curve;

  @override
  Widget build(BuildContext context) {
    final bool reduceMotion =
        MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    if (reduceMotion) {
      return CustomPaint(
        painter: _OuterShadowPainter(radius: radius, shadows: shadows),
      );
    }
    return TweenAnimationBuilder<List<BoxShadow>>(
      tween: _ShadowListTween(end: shadows),
      duration: duration,
      curve: curve,
      builder: (BuildContext context, List<BoxShadow> value, Widget? _) {
        return CustomPaint(
          painter: _OuterShadowPainter(radius: radius, shadows: value),
        );
      },
    );
  }
}

/// 只绘制「形状之外」的外阴影（等价 CSS `box-shadow` 的 border-box 裁剪）。
///
/// Flutter 的 `BoxShadow` 会把阴影铺满整个形状（含内部），在半透明卡面下
/// 透出灰暗；本 painter 用 `Path.combine(difference, 外框, 形状)` 挖空内部。
class _OuterShadowPainter extends CustomPainter {
  const _OuterShadowPainter({required this.radius, required this.shadows});

  final BorderRadius radius;
  final List<BoxShadow> shadows;

  @override
  void paint(Canvas canvas, Size size) {
    final Path hole = Path()..addRRect(radius.toRRect(Offset.zero & size));
    // 外框足够大以容纳 blur 扩散与 offset
    final Path frame = Path()
      ..addRect(Rect.fromLTWH(
        -size.width * 2,
        -size.height * 2,
        size.width * 5,
        size.height * 5,
      ));
    final Path ring = Path.combine(PathOperation.difference, frame, hole);

    canvas.save();
    canvas.clipPath(ring);
    for (final BoxShadow s in shadows) {
      final Paint paint = s.toPaint();
      final Rect r = (Offset.zero & size).shift(s.offset);
      canvas.drawRRect(radius.toRRect(r), paint);
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _OuterShadowPainter old) =>
      old.radius != radius ||
      // ⚠️ **逐项比较**（2026-09-30 纯软件层优化、零观感变化）：
      // 此前写的是 `old.shadows != shadows` —— `List` 的 `!=` 是**引用比较**，
      // 而调用方每次 build 都会用 `dimShadows(shadow)` **新建一个 List** ⇒ 父级每次
      // rebuild 都被判成「变了」并重绘阴影环。官方（DevTools Performance 的 Raster 一节）
      // 把 `shadows` 列为 raster 线程慢的来源之一。逐项比较后，阴影只在真正变化时重绘。
      !listEquals(old.shadows, shadows);
}

/// 两组阴影之间的插值（等价 CSS `transition: box-shadow`）。
///
/// `BoxShadow.lerpList` 按索引逐项插值（长度不等时短的一方按「无阴影」补齐），
/// 语义与浏览器一致：color / offset / blur / spread 各自线性插值。
class _ShadowListTween extends Tween<List<BoxShadow>> {
  _ShadowListTween({super.end});

  @override
  List<BoxShadow> lerp(double t) =>
      BoxShadow.lerpList(begin, end, t) ?? const <BoxShadow>[];
}

/// 模糊半径归一（--glass-filter blur(24px)；导航 18 / 按钮 8 有各自覆写）。
abstract final class AylaGlass {
  /// blur(24px) saturate(1.4)（t:--glass-filter）——卡片/侧栏/弹层/输入框
  static const double blurCard = 24;
  /// blur(18px)——底栏/顶栏/搜索面板/FAB
  static const double blurNav = 18;
  /// blur(8px)——ghost 按钮/工具钮
  static const double blurButton = 8;
}

/// `--glass-inset` 的组合工具（把顶沿 1px 内高光铺到任意形状上）。
///
/// web 的每个玻璃材质都由**四层**组成：半透明底 + 1px 亮边 + 外阴影 +
/// **顶沿内高光 `--glass-inset`**；Flutter 的 `BoxShadow` 无 inset 变体，
/// 故内高光用 `AylaInset.topHighlight` 单独叠一层。
abstract final class AylaGlassInset {
  /// 在 [child] 之上叠一层「形状内顶沿 1px 白色高光」。
  ///
  /// [radius] 必须与 [child] 的形状圆角一致，否则高光会溢出/被裁。
  static Widget over({
    required Widget child,
    required BorderRadius radius,
  }) {
    return Stack(
      children: <Widget>[
        child,
        Positioned.fill(
          child: IgnorePointer(
            child: LayoutBuilder(
              builder: (BuildContext context, BoxConstraints c) {
                return DecoratedBox(
                  decoration: BoxDecoration(
                    borderRadius: radius,
                    gradient: AylaInset.topHighlight(c.maxHeight),
                  ),
                );
              },
            ),
          ),
        ),
      ],
    );
  }
}

/// AylaGlassCard —— 全站卡面材料（app.css .glass-card / d:§4 Cards）。
///
/// [interactive] 为 true 时启用「可交互卡」行为（hover 上浮 2px + 阴影升
/// 12/40、按下 scale .99）；非交互卡保持稳定位置（d:§4「仅可交互列表卡抬升」）。
///
/// 2026-09-20 组件库审查 R6：交互动效本体收敛到公共件 [AylaCardInteraction]，
/// 与卡片族（群卡 / 群列表行）共用同一份实现（此前 AylaGlassCard 与 group_card
/// 各写一份，是同一 CSS 配方两套代码）。
class AylaGlassCard extends StatelessWidget {
  const AylaGlassCard({
    super.key,
    required this.child,
    this.padding,
    this.radius = AylaRadii.rCard,
    this.blur = AylaGlass.blurCard,
    this.strong = false,
    this.shadow,
    this.interactive = false,
    this.onTap,
    this.semanticLabel,
  });

  /// 内容。
  final Widget child;

  /// 内边距（默认 16px，d:§12.8 帖子卡 padding 16；调用方可覆盖）。
  final EdgeInsetsGeometry? padding;

  /// 圆角（.glass-card = --radius-card 16）。
  final double radius;

  /// 模糊半径。
  final double blur;

  /// 强玻璃（弹层用 .78，d:§4 Panels）。
  final bool strong;

  /// 覆盖阴影（默认静止 `--glass-shadow`、hover `--glass-shadow-hover`）。
  final List<BoxShadow>? shadow;

  /// 可交互（hover 抬升 + 按下缩放）。
  final bool interactive;

  /// 点击回调（传入即渲染为可点击卡）。
  final VoidCallback? onTap;

  /// 可访问性标签。
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    return AylaCardInteraction(
      interactive: interactive,
      onTap: onTap,
      semanticLabel: semanticLabel,
      builder: (BuildContext context, bool hovered) => AylaGlassSurface(
        radius: radius,
        blur: blur,
        strong: strong,
        // hover → `--glass-shadow-hover`（12/40）；静止 → `--glass-shadow`（8/32）。
        // box-shadow 300ms 过渡由 AylaGlassSurface.shadowTransition 表达（卡片族）。
        shadow:
            shadow ?? (hovered ? AylaShadows.glassHover : AylaShadows.glass),
        shadowTransition: AylaDurations.auroraqua,
        padding: padding ?? const EdgeInsets.all(AylaSpacing.sp4),
        child: child,
      ),
    );
  }
}

/// 卡片族交互动效（auroraqua.css 29–52 卡片族；与按钮族 55–94 区分）。
///
/// 事实源：
/// ```
/// transition: translate 300ms var(--auroraqua-ease), scale 200ms var(--auroraqua-ease);
/// :hover  → translate: 0 -2px; box-shadow: var(--glass-shadow-hover);
/// :active → translate: 0 0;    scale: 0.99;
/// ```
/// 与 [AylaPressScale]（按钮族 hover 1.02 / active .98）区分：
/// 卡片是「上浮 2px + 轻微缩小 .99」，按钮是「放大 1.02 / 缩小 .98」。
///
/// [interactive] == false 时完全不挂指针层（静态卡）；有 [onTap] 时仍可点击。
class AylaCardInteraction extends StatefulWidget {
  const AylaCardInteraction({
    super.key,
    required this.builder,
    this.onTap,
    this.semanticLabel,
    this.interactive = true,
    this.focusRingColor,
    this.focusRingRadius = const BorderRadius.all(Radius.circular(AylaRadii.rCard)),
  });

  /// 内容构建器（`hovered` 用于切换阴影与其它 hover 态）。
  final Widget Function(BuildContext context, bool hovered) builder;

  /// 点击回调（null 则不响应；交互动效仍保留）。
  final VoidCallback? onTap;

  /// 可访问性标签。
  final String? semanticLabel;

  /// 是否参与卡片族交互动效（hover 上浮 2px / 按下 scale .99）。
  final bool interactive;

  /// `:focus-visible` 环色；**null = 不画、也不进 tab 序列**（保持既有组件现状）。
  ///
  /// 事实源：卡片族的焦点环是**逐域声明**的，且都用 **`--ice-500`** ——
  /// `voice.css:547`（`.voice-hub .voice-channel-card`）、`voice.css:718`
  /// （`.group-voice`）、`typed-result-cards.css:68`；
  /// `outline: 2px solid var(--ice-500); outline-offset: 2px`（环跟随卡片自身 radius 16）。
  ///
  /// ⚠️ 环画在**形状之外**（`left/top/right/bottom: -4` 的 2px 描边 = offset 2 + width 2），
  /// **不参与布局** —— 库内 `AylaPressScale` 的环是内嵌 Container，会让元素长大 4px，
  /// 卡片上会明显撑大（`13-*` §6.21 已记录该差异）。
  ///
  /// 传了环色即表示**该卡参与键盘可达性**：`tab` 可聚焦 + `Enter` / `Space` 触发 [onTap]
  /// （web 卡片是 `role="button" tabIndex={0}` + `onKeyDown` 同语义，如
  /// `VoiceChannelCard.tsx:21–24`）。
  final Color? focusRingColor;

  /// 环的内侧圆角（默认 `--radius-card` 16；环自身半径 = 该值 + 2）。
  final BorderRadius focusRingRadius;

  @override
  State<AylaCardInteraction> createState() => _AylaCardInteractionState();
}

class _AylaCardInteractionState extends State<AylaCardInteraction> {
  bool _hovered = false;
  bool _pressed = false;
  bool _focused = false;

  /// `outline` 环层：画在形状之外、不吃指针（等价 CSS outline）。
  Widget _focusRing() {
    final Color? ring = widget.focusRingColor;
    if (ring == null || !_focused) return const SizedBox.shrink();
    return Positioned(
      left: -4,
      top: -4,
      right: -4,
      bottom: -4,
      child: IgnorePointer(
        child: DecoratedBox(
          decoration: BoxDecoration(
            border: Border.all(color: ring, width: 2), // outline: 2px
            borderRadius: BorderRadius.only(
              topLeft: Radius.circular(widget.focusRingRadius.topLeft.x + 2),
              topRight: Radius.circular(widget.focusRingRadius.topRight.x + 2),
              bottomLeft:
                  Radius.circular(widget.focusRingRadius.bottomLeft.x + 2),
              bottomRight:
                  Radius.circular(widget.focusRingRadius.bottomRight.x + 2),
            ),
          ),
        ),
      ),
    );
  }

  /// 键盘可达（`tab` + `Enter` / `Space`）与焦点环；未传环色时原样返回。
  Widget _withFocus(Widget child) {
    if (widget.focusRingColor == null) return child;
    return Focus(
      onFocusChange: (bool has) => setState(() => _focused = has),
      onKeyEvent: (FocusNode node, KeyEvent event) {
        if (event is! KeyDownEvent) return KeyEventResult.ignored;
        final bool activate = event.logicalKey == LogicalKeyboardKey.enter ||
            event.logicalKey == LogicalKeyboardKey.space;
        if (!activate || widget.onTap == null) return KeyEventResult.ignored;
        widget.onTap!();
        return KeyEventResult.handled;
      },
      child: Stack(
        clipBehavior: Clip.none, // 环画在卡片之外，不能被裁
        children: <Widget>[_focusRing(), child],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final bool reduceMotion = MediaQuery.disableAnimationsOf(context);

    // 非交互卡：不挂 hover/按压动效；有 onTap 时保持可点击（对齐原 AylaGlassCard
    // interactive=false 的行为）。
    if (!widget.interactive) {
      if (widget.onTap == null) return widget.builder(context, false);
      return Semantics(
        button: true,
        label: widget.semanticLabel,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onTap,
          child: widget.builder(context, false),
        ),
      );
    }

    // translate：hover → -2px；按下复位 0（CSS `:active { translate: 0 0 }`）
    final double dy = reduceMotion
        ? 0
        : (_pressed
              ? 0
              : (_hovered ? -2 : 0));
    // scale：按下 .99（200ms）
    final double scale = reduceMotion || !_pressed ? 1.0 : 0.99;

    // CSS `translate` 是**像素位移**（不影响布局、不改变自身坐标系原点），
    // 故用 Transform.translate 而非 AnimatedSlide（后者 offset 是尺寸百分比）。
    Widget content = TweenAnimationBuilder<double>(
      tween: Tween<double>(begin: 0, end: dy),
      duration: reduceMotion
          ? Duration.zero
          : AylaDurations.auroraqua, // translate / box-shadow 300ms
      curve: AylaCurves.auroraqua,
      builder: (BuildContext context, double v, Widget? child) {
        return Transform.translate(offset: Offset(0, v), child: child);
      },
      child: AnimatedScale(
        duration: reduceMotion
            ? Duration.zero
            : AylaDurations.button, // scale 200ms
        curve: AylaCurves.auroraqua,
        scale: scale,
        child: widget.builder(context, _hovered),
      ),
    );

    if (widget.semanticLabel != null) {
      content = Semantics(
        button: widget.onTap != null,
        label: widget.semanticLabel,
        child: content,
      );
    }

    return _withFocus(
      MouseRegion(
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() {
          _hovered = false;
          _pressed = false;
        }),
        child: Listener(
          onPointerDown: (_) => setState(() => _pressed = true),
          onPointerUp: (_) => setState(() => _pressed = false),
          onPointerCancel: (_) => setState(() => _pressed = false),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: widget.onTap,
            child: content,
          ),
        ),
      ),
    );
  }
}

/// 按钮类型（.btn-primary / .btn-glow / .btn-ghost）。
enum AylaGlassButtonVariant {
  /// .btn-primary：indigo 实底 + 白字 + compact 阴影；hover 换 glow 阴影
  primary,

  /// .btn-glow：sakura→glow 135deg 渐变 + grape 字 + 常驻辉光；hover brightness(1.06)
  glow,

  /// .btn-ghost：玻璃底 + 亮边 + blur(8px) + button 阴影；hover 换 ice 蓝底
  ghost,

  /// .btn-destructive（app.css 2764–2770）：`--destructive` 实底 + `#fffafb` 字；
  /// `:hover:not(:disabled) → filter: brightness(1.06)`。
  /// 用于确认删除等危险操作（AylaConfirmDialog 的确认键、群管理类操作）。
  destructive,

  /// `.voice-leave-btn`（app.css 3108–3112）：**透明底 + `--destructive` 字 +
  /// 1px `--destructive` 边**，无阴影（`.btn` 基础块本身不声明 background/box-shadow）。
  /// 与 [destructive]（红**实底**）不是一档；2026-09-21 由 voice 域第一批按
  /// 「先加档位、不新造」补入。
  outlineDestructive,
}

/// AylaGlassButton —— 严格照 web CSS 实现的三类按钮。
///
/// **事实源（app.css + auroraqua.css，逐条对应，无自由发挥）**：
///
/// `.btn`（盒模型）：inline-flex / gap 8 / min-height 40 / padding 0 24
///   / radius 12 / 14px / 700 / ls .2
/// `.btn-primary`：background --indigo-700 / #fffafb / box-shadow compact；
///   :hover → box-shadow glow-shadow
/// `.btn-glow`：background 135deg #f9b0ff→#f796ff / color grape-700 /
///   box-shadow glow-shadow（常驻）；:hover → filter brightness(1.06)
/// `.btn-ghost`（base）：transparent / 1px rgba(70,91,146,.35) / indigo-700；
///   :hover → rgba(157,191,230,.18)。auroraqua.css 覆写：glass-bg /
///   glass-border / glass-shadow-button / blur(8px)；:hover → button-hover
///
/// auroraqua.css 交互：200ms transition 组；hover scale 1.02、active
///   scale .98（独立 scale 属性）；600ms 扫光（::after：90deg transparent→
///   glass-border→transparent，opacity .5，translateX(-120%→120%)）。
/// base.css button:disabled：opacity .55。
/// 窄屏（≤768）：辉光降 30%（0 0 11px rgba(247,150,255,.32)）。
class AylaGlassButton extends StatefulWidget {
  const AylaGlassButton({
    super.key,
    required this.label,
    this.onPressed,
    this.variant = AylaGlassButtonVariant.primary,
    this.icon,
    this.minHeight = 40,
    this.minWidth,
    this.padding = const EdgeInsets.symmetric(horizontal: AylaSpacing.sp6),
    this.fontSize = 14,
    this.expand = false,
    this.semanticLabel,
    this.glowHover = false,
    this.glowBorderOnHover = false,
    this.borderRadius,
  });

  /// 圆角覆盖（null ⇒ `.btn { border-radius: var(--radius-input) }` = 12）。
  ///
  /// 事实源（逐处）：
  /// - `.group-info-request .btn { border-radius: var(--radius-pill) }`（group.css 2041–2047）
  ///   —— 入群申请行的「同意 / 拒绝」；
  /// - `.group-info-head-action` 同族（group.css 2100–2107）。
  final double? borderRadius;

  /// hover 态改走 **glow 边 + 粉辉光**（web `.post-editor-image-btn:hover
  /// { border-color: var(--glow-500); box-shadow: var(--glow-shadow) }`，
  /// posts.css 410–414）：与 ghost 默认的「冰蓝底 + button-hover 阴影」不同，
  /// 供帖子编辑器「图片/视频」等媒体选择钮使用。
  final bool glowHover;

  /// **只**在 hover / focus 时把边色换成 `--glow-500`，其余仍按 ghost 本档
  /// （hover 保留冰蓝底 `.18` 与 `--glass-shadow-button-hover`）。
  ///
  /// 事实源：`.danmaku-image-btn`（app.css 3774–3791，元素同时带
  /// `btn btn-ghost`）的高亮是**三条规则共存、各属性分别胜出**：
  /// - 底色：`.btn-ghost:hover:not(:disabled)`（app.css 65，0-3-0）→ `rgba(157,191,230,.18)`
  /// - 阴影：auroraqua 按钮组 `:is(.btn-ghost,…):not(:disabled):hover`（134–139，0-3-0）
  ///   → `--glass-shadow-button-hover`（压过本条自己的 `--glow-shadow`，0-2-0）
  /// - 边色：`.danmaku-image-btn:hover/:focus-within`（3787–3791，0-2-0）
  ///   → `--glow-500`（压过静止档 0-1-0 的 `--glass-border`）
  ///
  /// 故它是 [glowHover]（连底色/阴影一起换成辉光）之外的另一档；focus 无 hover 时
  /// 三条 hover 规则不命中 ⇒ 边 `--glow-500` + 阴影 `--glow-shadow`。
  final bool glowBorderOnHover;

  /// 文案。
  final String label;

  /// 点击回调；null = disabled（对应 :disabled，opacity .55）。
  final VoidCallback? onPressed;

  /// 变体。
  final AylaGlassButtonVariant variant;

  /// 前置图标（.btn 的 gap 8 作用在图标与文字之间）。
  final Widget? icon;

  /// `.btn { min-height: 40px }`；认证页传 44（auth.css .auth-submit）。
  final double minHeight;

  /// `min-width`（.auth-switch-link 72 / .auth-code-btn 104）；null = 内容决定。
  final double? minWidth;

  /// `.btn { padding: 0 24px }`；认证页可传 padding-inline 16。
  final EdgeInsetsGeometry padding;

  /// `.btn { font-size: 14px }`。
  ///
  /// 逐处覆写的档位：`.voice-join-btn` **13**、`.voice-rejoin-btn` **12**
  /// （app.css 623–628 区的 `voice.css` 覆写 / app.css 3114–3118）。
  final double fontSize;

  /// `.auth-submit { width: 100% }`。
  final bool expand;

  /// 可访问性标签（默认 [label]）。
  final String? semanticLabel;

  @override
  State<AylaGlassButton> createState() => _GlassButtonState();
}

class _GlassButtonState extends State<AylaGlassButton>
    with SingleTickerProviderStateMixin {
  /// 扫光位置：0 = translateX(-120%)，1 = translateX(+120%)（::after）。
  late final AnimationController _sweep = AnimationController(
    vsync: this,
    duration: AylaDurations.sweep, // 600ms
  );

  /// ::after 的 `transition: transform 600ms var(--auroraqua-ease)` 是
  /// **ease 曲线**（先快后慢），不是 linear——直接用 controller 的线性值
  /// 会让扫光匀速掠过，与 web 手感不一致（实测）。
  late final Animation<double> _sweepEased = CurvedAnimation(
    parent: _sweep,
    curve: AylaCurves.auroraqua,
  );

  bool _hovered = false;
  bool _pressed = false;
  bool _focused = false;

  bool get _enabled => widget.onPressed != null;

  bool get _reduceMotion => MediaQuery.disableAnimationsOf(context);

  @override
  void dispose() {
    _sweep.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final AylaTextStyles text = AylaTextStyles.of(context);
    final bool narrow = AylaBreakpoints.isNarrow(MediaQuery.sizeOf(context).width);
    final bool animate = _enabled && !_reduceMotion;
    final bool hovered = _hovered && animate;
    // `:focus-within` 与 hover 同列的高亮来源（**不受** reduced-motion 影响：
    // 它换的是边色/阴影，不是位移动画）
    final bool focused = _focused && _enabled;

    // ---- 三类材质 ----
    late final Color background;
    late final Color foreground;
    late final Color? borderColor;
    final List<BoxShadow> shadow;
    late final LinearGradient? gradient;

    switch (widget.variant) {
      case AylaGlassButtonVariant.primary:
        background = AylaColors.indigo700;
        foreground = AylaColors.surface;
        borderColor = null;
        gradient = null;
        shadow = hovered ? AylaShadows.glow : AylaShadows.compact;
      case AylaGlassButtonVariant.glow:
        background = AylaColors.sakura300; // 渐变盖其上，底色兜底
        foreground = AylaColors.grape700;
        borderColor = null;
        // 135deg #f9b0ff → #f796ff（app.css .btn-glow）
        gradient = cssLinearGradient(
          angleDeg: 135,
          colors: AylaGradients.btnGlow,
        );
        // 常驻辉光；窄屏（≤768）强度降 30%
        shadow = narrow ? AylaShadows.glowNarrow : AylaShadows.glow;
      case AylaGlassButtonVariant.ghost:
        // auroraqua 覆写：glass-bg + glass-border + button 阴影 + blur(8px)
        // glowHover（.post-editor-image-btn）：hover 不改底色，只换 glow 边 + 粉辉光
        // glowBorderOnHover（.danmaku-image-btn）：hover 保留 ghost 底色/阴影，只换 glow 边
        final bool hoverGlow = hovered && widget.glowHover;
        // `:focus-within` 在两条 web 规则里都与 `:hover` 同列（posts.css 410 / app.css 3787）
        final bool focusGlow =
            focused && (widget.glowHover || widget.glowBorderOnHover);
        final bool glowBorder =
            hoverGlow || (hovered && widget.glowBorderOnHover) || focusGlow;
        background = (hovered && !widget.glowHover)
            ? AylaColors.ice500.withValues(alpha: 0.18) // :hover rgba(157,191,230,.18)
            : AylaGlassConfig.resolveBackground(strong: false);
        foreground = AylaColors.indigo700;
        borderColor = glowBorder
            ? AylaColors.glow500 // :hover/:focus-within border-color: var(--glow-500)
            : AylaColors.glassBorder; // auroraqua 覆写 --glass-border
        gradient = null;
        shadow = hoverGlow
            ? AylaShadows.glow
            : (hovered
                ? AylaShadows.buttonHover // auroraqua 按钮组 hover 阴影（0-3-0 胜出）
                : (focusGlow ? AylaShadows.glow : AylaShadows.button));
      case AylaGlassButtonVariant.destructive:
        // `.btn-destructive { background: var(--destructive); color: #fffafb }`
        // 无边框、无阴影（web 未声明）；hover 走下方 brightness(1.06) 滤镜分支
        background = AylaColors.destructive;
        foreground = AylaColors.surface;
        borderColor = null;
        gradient = null;
        shadow = const <BoxShadow>[]; // 空 = 无阴影（web 未声明 box-shadow）
      case AylaGlassButtonVariant.outlineDestructive:
        // `.voice-leave-btn { background: transparent; color: var(--destructive);
        //  border: 1px solid var(--destructive) }`（app.css 3108–3112）
        // ⚠️ web 的 `transparent` 就是 `rgba(0,0,0,0)`，且本档**没有** hover 换底
        //    （`.voice-leave-btn` 不声明 :hover）⇒ 不存在「透明黑插值闪灰」问题，
        //    故按字面写 Colors.transparent（不是同色相近似）。
        background = Colors.transparent;
        foreground = AylaColors.destructive;
        borderColor = AylaColors.destructive;
        gradient = null;
        shadow = const <BoxShadow>[]; // `.btn` 基础块未声明 box-shadow
    }

    // 圆角：`.btn { border-radius: var(--radius-input) }`，可按调用方覆写（如申请行 pill）
    final double cornerRadius = widget.borderRadius ?? AylaRadii.rInput;
    final BorderRadius rInput = BorderRadius.all(Radius.circular(cornerRadius));

    // ---- 禁用态：**按颜色降透明度**（裁决）----
    //
    // 事实源：`base.css button:disabled { opacity: .55 }`。
    // ⚠️ 不能用整层 `Opacity(.55)`：ghost 档的 face 内含 `BackdropFilter`（blur 8px），
    //    Opacity 叠在 BackdropFilter 上会被 Impeller 拒绝并刷屏
    //    （实测：`ImpellerValidationBreak: Contents::SetInheritedOpacity should never be called
    //    when Contents::CanAcceptOpacity returns false`），且**禁用态的变暗不生效**。
    //    ⇒ 把 .55 落到**颜色**上（底/渐变/边/字/阴影各乘 .55），视觉等价、无层叠冲突。
    const double kDisabledAlpha = 0.55;
    Color dimColor(Color c) =>
        _enabled ? c : c.withValues(alpha: c.a * kDisabledAlpha);
    Color? dimColorOrNull(Color? c) => _enabled || c == null ? c : dimColor(c);
    /// 渐变降透明：本库按钮只可能出现 [LinearGradient]（glow 档），其余档为 null。
    Gradient? dimGradient(Gradient? g) => _enabled || g == null || g is! LinearGradient
        ? g
        : LinearGradient(
            begin: g.begin,
            end: g.end,
            stops: g.stops,
            colors: <Color>[for (final Color c in g.colors) dimColor(c)],
          );
    List<BoxShadow> dimShadows(List<BoxShadow> list) => _enabled
        ? list
        : <BoxShadow>[
            for (final BoxShadow sh in list)
              sh.copyWith(color: dimColor(sh.color)),
          ];

    // ---- 卡面：底色/渐变 + 描边 + 圆角裁剪（.btn 盒模型与材质）----
    // 注意：padding 必须放在 Stack **内部**（内容 Row 外包 Padding）——
    // CSS `.btn::after { inset: 0 }` 的扫光是相对 padding box（含左右
    // 24px），若 padding 留在外层面板，Positioned.fill 扫光层只能覆盖
    // 内容区，光条会比按钮窄、扫不过按钮两端。
    //
    // 渐变角度换算需要**真实宽高比**（CSS 渐变线长 = |W sinθ|+|H cosθ|，
    // 而 Flutter Alignment 端点在归一化空间插值 → 只有正方形时等价；
    // 宽扁按钮上 135deg 斜向渐变会整体错位，实测偏差可达 0.58）。
    // 故这里用 LayoutBuilder 拿到实际尺寸再生成渐变；非渐变变体直接复用。
    Widget buildFace(double aspectRatio) {
      final Gradient? g = switch (widget.variant) {
        AylaGlassButtonVariant.glow => cssLinearGradient(
            angleDeg: 135, // 135deg #f9b0ff → #f796ff（app.css .btn-glow）
            colors: AylaGradients.btnGlow,
            aspectRatio: aspectRatio,
          ),
        _ => gradient,
      };
      return AnimatedContainer(
      duration: _reduceMotion ? Duration.zero : AylaDurations.fast,
      curve: AylaCurves.easeOut,
      constraints: BoxConstraints(
        minHeight: widget.minHeight,
        minWidth: widget.minWidth ?? 0,
      ),
      decoration: BoxDecoration(
        color: dimColor(background),
        gradient: dimGradient(g),
        borderRadius: rInput,
        border: borderColor == null
            ? null
            : Border.all(color: dimColorOrNull(borderColor)!),
      ),
      // ::after 在圆角内裁剪（.btn { overflow: hidden; isolation: isolate }）
      child: ClipRRect(
        borderRadius: rInput,
        clipBehavior: Clip.hardEdge,
        child: Stack(
          fit: StackFit.passthrough,
          alignment: Alignment.center,
          children: <Widget>[
            // .btn::after 扫光：覆盖整个 padding box；opacity .5，
            // -120% → +120%（600ms）。
            // 性能（2026-09-27 §8.17）：.5 已乘进渐变色（sweepHalf），不再套
            // 整层 Opacity —— 单层渐变无重叠，两者逐像素等价但省一次 saveLayer。
            if (animate)
              Positioned.fill(
                child: IgnorePointer(
                  child: AnimatedBuilder(
                    animation: _sweepEased,
                    builder: (BuildContext context, Widget? child) {
                      return FractionalTranslation(
                        translation: Offset(-1.2 + _sweepEased.value * 2.4, 0),
                        child: child,
                      );
                    },
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: cssLinearGradient(
                          angleDeg: 90, // linear-gradient(90deg, …)
                          colors: AylaGradients.sweepHalf,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            // 内容：gap 8px；14px/700/ls .2（padding 在 Stack 内部）
            Padding(
              padding: widget.padding,
              child: Row(
                mainAxisSize:
                    widget.expand ? MainAxisSize.max : MainAxisSize.min,
                mainAxisAlignment: MainAxisAlignment.center,
                children: <Widget>[
                  if (widget.icon != null) ...<Widget>[
                    IconTheme(
                      data: IconThemeData(color: dimColor(foreground), size: 18),
                      child: widget.icon!,
                    ),
                    // ⚠️ `gap: var(--sp-2)` **只在图标与文字同时存在**时生效——
                    // CSS 的 `gap` 对单个子元素不产生任何间距。空 label 的图标钮
                    // （窄屏发帖/评论/房内聊天的发送键）曾因这 8px 多出半个间隙而整体偏左
                    // 4px（实测「这三个发送键好歪」）。
                    if (widget.label.isNotEmpty)
                      const SizedBox(width: AylaSpacing.sp2),
                  ],
                  // 文字：外层 Flexible(loose) 承接超长省略，内层 Center 保证
                  // 文字自身居中——不用 tight flex（会吃掉主轴空间把字推到左侧，
                  // expand 满宽时可见，实测）。
                  if (widget.label.isNotEmpty)
                    Flexible(
                      fit: FlexFit.loose,
                      child: Center(
                        widthFactor: 1,
                        // ⚠️ heightFactor **必须**给 1：Center（= Align）在缺省
                        // heightFactor 时会**取满 maxHeight** —— 按钮落在有界松高
                        // 宿主里时，文字行被撑到宿主高 → Row → Stack → 按钮整体
                        // 拉高（实测 600 高宿主里按钮 600×106.8）。
                        // 事实源：web .btn 恒为「内容高 + min-height 40」
                        // （app.css 的 .btn { min-height: 40px; padding: 0 24px }），
                        // 没有任何拉伸语义 ⇒ 文字行取内容高，再由 AnimatedContainer
                        // 的 minHeight 兜底成 40。
                        heightFactor: 1,
                        child: Text(
                          widget.label,
                          maxLines: 1,
                          textAlign: TextAlign.center,
                          overflow: TextOverflow.ellipsis,
                          style: text.label.copyWith(
                            color: dimColor(foreground),
                            fontSize: widget.fontSize,
                            fontWeight: FontWeight.w700,
                            letterSpacing: 0.2,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
    } // end buildFace
    // 用 LayoutBuilder 取真实尺寸 → 生成含正确宽高比的 face
    final Widget face = LayoutBuilder(
      builder: (BuildContext context, BoxConstraints c) {
        // 渐变宽高比的**高度基准**（与上面 heightFactor 修复配套）：
        // web `.btn` 的高恒为「内容高 + min-height 40」——只有父级给**紧**
        // 高度约束（flex `align-items: stretch`）时按钮才被拉伸。此前直接取
        // c.maxHeight，把「有界松高宿主」也当成按钮高（宿主 600 ⇒ 宽高比按
        // w/600 算，而按钮只有 40 高）⇒ 判据必须是「高度紧约束才算拉伸」。
        final bool stretched = c.minHeight.isFinite &&
            c.minHeight > 0 &&
            c.minHeight == c.maxHeight;
        final double h = stretched ? c.maxHeight : widget.minHeight;
        final double w = c.maxWidth.isFinite && c.maxWidth > 0
            ? c.maxWidth
            : (widget.minWidth ?? h);
        return buildFace(w / h);
      },
    );

    // ---- 外阴影：不参与裁剪（box-shadow 在元素外侧）----
    //
    // ⚠️ `fit: StackFit.passthrough` **必须给**：`Stack` 默认 `StackFit.loose`
    // 会把约束**放宽**后再传给非 positioned 子项（face），于是「父级给 tight 高度」
    // （= CSS flex `align-items: stretch` 的等价物，如 `.live-owner-start` 的 60 高槽）
    // 传不到 face ⇒ 玻璃面只按 `minHeight` 取 40、在 60 高的槽里居中留白。
    // 加上之后 face 拿到的就是**原约束**：tight 时撑满、松时按内容高 + minHeight。
    Widget decorated = Stack(
      fit: StackFit.passthrough,
      clipBehavior: Clip.none,
      children: <Widget>[
        // 外阴影**只画形状之外**（2026-09-20 审查 R2：原裸 boxShadow 会把
        // `--glass-shadow-*` 的 indigo 铺进 ghost 的 .55 玻璃面内部）
        // + `transition: box-shadow 200ms`（auroraqua.css 55–70）。
        Positioned.fill(
          child: IgnorePointer(
            child: _AnimatedShadowRing(
              radius: rInput,
              shadows: dimShadows(shadow),
              duration: AylaDurations.button,
            ),
          ),
        ),
        face,
        // --glass-inset（顶沿 1px 内高光）：`.btn-primary` 的
        // `--glass-shadow-compact`、`.btn-ghost` 的 `--glass-shadow-button[-hover]`
        // 两个 token 都含 `var(--glass-inset)`（tokens.css 126–128）。
        // `.btn-glow` 用的是 `--glow-shadow`（不含 inset），故不叠加；
        // 新档 `outlineDestructive` 的 `.btn` 基础块**没有任何 box-shadow**
        // ⇒ 也不该有内高光（`--glass-inset` 只随阴影 token 出现）。
        if (widget.variant != AylaGlassButtonVariant.glow &&
            widget.variant != AylaGlassButtonVariant.outlineDestructive)
          Positioned.fill(
            child: IgnorePointer(
              child: LayoutBuilder(
                builder: (BuildContext context, BoxConstraints c) {
                  return DecoratedBox(
                    decoration: BoxDecoration(
                      borderRadius: rInput,
                      gradient: AylaInset.topHighlight(c.maxHeight),
                    ),
                  );
                },
              ),
            ),
          ),
      ],
    );

    // `.btn-glow:hover:not(:disabled) { filter: brightness(1.06) }`
    // `.btn-destructive:hover:not(:disabled) { filter: brightness(1.06) }`
    // CSS filter 是通道乘法（×1.06 后钳位）→ ColorFilter.matrix 等价。
    if ((widget.variant == AylaGlassButtonVariant.glow ||
            widget.variant == AylaGlassButtonVariant.destructive) &&
        hovered) {
      decorated = ColorFiltered(
        colorFilter: const ColorFilter.matrix(<double>[
          1.06, 0, 0, 0, 0, //
          0, 1.06, 0, 0, 0, //
          0, 0, 1.06, 0, 0, //
          0, 0, 0, 1, 0,
        ]),
        child: decorated,
      );
    }

    // .btn-ghost { backdrop-filter: blur(8px) }（auroraqua.css）
    if (widget.variant == AylaGlassButtonVariant.ghost &&
        !AylaGlassConfig.useOpaqueFallback) {
      decorated = Stack(
        // 同上：不能让 loose 把 tight 槽位的高度约束吃掉
        fit: StackFit.passthrough,
        clipBehavior: Clip.none,
        children: <Widget>[
          Positioned.fill(
            // 背后内容层统一走 AylaGlassBackdrop（质量档 owner，§8.17）。
            child: AylaGlassBackdrop(
              radius: rInput,
              // auroraqua.css 100–101（`.btn-ghost`）：`backdrop-filter: blur(8px)`
              // ——**无 saturate**（8px 档三处均为纯 blur；18px/24px 档才带 1.4）。
              filter: AylaGlassConfig.blurOnly(sigma: AylaGlass.blurButton),
            ),
          ),
          decorated,
        ],
      );
    }

    // :hover { scale: 1.02 } / :active { scale: .98 }（独立 scale，200ms）
    //
    // 优先级：CSS 中 :active 规则写在 :hover 之后且同等特异性 → 按下时 .98
    // 胜出；因此这里必须让 pressed 覆盖 hovered（此前写成
    // `hovered ? 1.02 : pressScale`，鼠标按下时 hovered 恒为 true，
    // 0.98 永远显示不出来 = 「没有按压动画」，实测）。
    final double scaleTarget = _reduceMotion
        ? 1.0
        : (!_enabled
            ? 1.0
            : (_pressed
                ? 0.98
                : (_hovered ? 1.02 : 1.0)));
    final Widget body = AnimatedScale(
      scale: scaleTarget,
      // auroraqua.css 按钮组统一 200ms（覆盖 app.css .btn 的 180ms）
      duration: _reduceMotion ? Duration.zero : AylaDurations.button,
      curve: AylaCurves.auroraqua,
      child: decorated,
    );

    return Semantics(
      button: true,
      enabled: _enabled,
      // 空 label 的图标钮：语义标签只取 semanticLabel（否则会写进一个空串）
      label: widget.semanticLabel ??
          (widget.label.isEmpty ? null : widget.label),
      child: Focus(
        // base.css `:focus-visible { outline: 2px solid #F796FF; outline-offset: 2px }`
        onFocusChange: (bool has) => setState(() => _focused = has),
        child: MouseRegion(
          cursor:
              _enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
          onEnter: (_) {
            setState(() => _hovered = true);
            if (animate) _sweep.forward(); // ::after → translateX(120%)
          },
          onExit: (_) {
            setState(() {
              _hovered = false;
              _pressed = false;
            });
            if (animate) _sweep.reverse(); // 移出时 600ms 扫回
          },
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: widget.onPressed,
            onTapDown:
                _enabled ? (_) => setState(() => _pressed = true) : null,
            onTapCancel:
                _enabled ? () => setState(() => _pressed = false) : null,
            onTapUp:
                _enabled ? (_) => setState(() => _pressed = false) : null,
            // `base.css button:disabled { opacity: .55 }` 已改为**按颜色降透明**
            // （见上方 dimColor 段）——不能再套整层 Opacity（Impeller 拒绝 Opacity 叠 BackdropFilter）
            child: _focused && _enabled
                // focus ring：2px 辉光边 + 2px offset（outline-offset）
                ? Container(
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(cornerRadius + 2 + 2),
                      border: Border.all(
                        color: AylaColors.glow500,
                        width: 2,
                      ),
                    ),
                    padding: const EdgeInsets.all(2),
                    child: body,
                  )
                : body,
          ),
        ),
      ),
    );
  }
}

/// AylaGlassInput —— 文本输入基类（.field + auroraqua 统一 owner）。
///
/// 材料（app.css .field + auroraqua.css 统一 owner）：
/// 底 `--glass-bg`(.55) + 1px `--glass-border` + 12px 圆角 +
/// `--glass-inset` 内阴影 + `--glass-filter`(blur 24px)；内边距 12×16。
/// focus：边框转 `--glow-500` + `--glow-shadow`（180ms）。
/// placeholder：`--slate-500`。
///
/// 认证上下文（d:§5）：字段描边覆写为 rgba(70,91,146,.3)
/// （白边在浅玻璃上不可见）、min-height 44px。[onGlassBorder] 控制前者。
class AylaGlassInput extends StatefulWidget {
  const AylaGlassInput({
    super.key,
    required this.controller,
    this.hintText,
    this.obscureText = false,
    this.onSubmitted,
    this.autofocus = false,
    this.enabled = true,
    this.minHeight = 44,
    this.textInputAction,
    this.autofillHints,
    this.onGlassBorder = false,
    this.textStyle,
    this.semanticLabel,
    this.focusNode,
    this.invalid = false,
    this.padding,
    this.keyboardType,
    this.inputFormatters,
    this.maxLength,
    this.onChanged,
    this.minLines,
    this.maxLines,
  });

  /// 文本控制器。
  final TextEditingController controller;

  /// 占位文案（--slate-500）。
  final String? hintText;
  /// 密码输入。
  final bool obscureText;

  /// 回车提交。
  final ValueChanged<String>? onSubmitted;

  /// 自动聚焦（web 登录页 userName 字段 autoFocus）。
  final bool autofocus;

  /// 是否可编辑。
  final bool enabled;

  /// 最小高度（认证字段 44px）。
  final double minHeight;

  /// 键盘动作。
  final TextInputAction? textInputAction;

  /// 自动填充提示（web autoComplete="username"）。
  final Iterable<String>? autofillHints;

  /// 是否使用认证卡内描边 rgba(70,91,146,.3)。
  final bool onGlassBorder;

  /// 覆盖文字样式（认证字段继承 .auth-field 的 14px）。
  final TextStyle? textStyle;

  /// 可访问性标签。
  final String? semanticLabel;

  /// 焦点节点。
  final FocusNode? focusNode;

  /// 校验失败态：`.auth-field .field[aria-invalid="true"] { border-color:
  /// var(--destructive) }`（auth.css 74）。
  final bool invalid;

  /// 内部内边距；null = `.field` 基类 `padding: 12px 16px`（app.css 70–73）。
  ///
  /// 覆写场景：`.visibility-selector-groups .field { padding-block: var(--sp-2);
  /// min-height: 40px }`（app.css 186–189）等按位置改内沿的字段。
  final EdgeInsetsGeometry? padding;

  /// 键盘类型（验证码/邮箱等场景，web 用 `inputMode` 表达）。
  final TextInputType? keyboardType;

  /// 输入格式化（例：验证码 `FilteringTextInputFormatter.digitsOnly`
  /// 对应 web 的 `e.target.value.replace(/\D/g, "")`）。
  final List<TextInputFormatter>? inputFormatters;

  /// 最大长度（tsx `maxLength`）。
  final int? maxLength;

  /// 输入变化回调（供调用方按内容启用/禁用提交按钮）。
  final ValueChanged<String>? onChanged;

  /// 文本域最小行数（web `<textarea rows>`；null = 单行输入框）。
  final int? minLines;

  /// 文本域最大行数（web `rows` + `resize: vertical`；null = 单行、>1 可换行）。

  final int? maxLines;

  @override
  State<AylaGlassInput> createState() => _GlassInputState();
}

class _GlassInputState extends State<AylaGlassInput> {
  FocusNode? _ownedFocus;
  bool _focused = false;

  FocusNode get _focus => widget.focusNode ?? (_ownedFocus ??= FocusNode());

  @override
  void initState() {
    super.initState();
    _focus.addListener(_onFocusChanged);
  }

  void _onFocusChanged() {
    if (!mounted) return;
    setState(() => _focused = _focus.hasFocus);
  }

  @override
  void dispose() {
    _focus.removeListener(_onFocusChanged);
    _ownedFocus?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final AylaTextStyles text = AylaTextStyles.of(context);
    final bool reduceMotion = MediaQuery.disableAnimationsOf(context);
    final bool opaque = AylaGlassConfig.useOpaqueFallback;

    // ── `.field` 材料统一 owner：app.css 70–88 + **auroraqua.css 502–510 覆写** ──
    //   :is(.field, .voice-create-input, …) {
    //     background: var(--glass-bg);
    //     background-image: none;               ← 清除背景图（单一材料 owner）
    //     border: 1px solid var(--glass-border);
    //     border-radius: var(--radius-input);
    //     box-shadow: var(--glass-inset);       ← 顶沿 1px 内高光
    //     backdrop-filter: var(--glass-filter); ← **blur(24px) saturate(1.4)**
    //   }
    //   :focus → border-color: --glow-500; box-shadow: --glow-shadow
    //   auth.css 73–78：认证上下文 min-height 44 / 描边 rgba(70,91,146,.3) /
    //     focus 仍走辉光边；auth.css 74：`[aria-invalid="true"]` → --destructive
    final Color border = widget.invalid
        // auth.css 74：`[aria-invalid="true"]` → --destructive
        ? AylaColors.destructive
        : (_focused
            ? AylaColors.glow500
            : (widget.onGlassBorder
                ? AylaColors.fieldBorderOnGlass
                : AylaColors.glassBorder));

    final BorderRadius rInput =
        BorderRadius.all(Radius.circular(AylaRadii.rInput));

    // 卡面（底 + 边 + 圆角）。**不含阴影/内高光**——它们按 CSS 语义分层。
    final Widget face = AnimatedContainer(
      duration: reduceMotion ? Duration.zero : AylaDurations.fast,
      curve: AylaCurves.easeOut,
      constraints: BoxConstraints(minHeight: widget.minHeight),
      padding: widget.padding ??
          const EdgeInsets.symmetric(
            horizontal: AylaSpacing.sp4, // .field: padding 12px 16px
            vertical: AylaSpacing.sp3,
          ),
      decoration: BoxDecoration(
        // background: var(--glass-bg)（降级时 --surface，auroraqua 526–531）
        color: AylaGlassConfig.resolveBackground(strong: false),
        // background-image: none —— 不叠任何渐变（清除背景图语义）
        borderRadius: rInput,
        border: Border.all(color: border),
      ),
      child: TextField(
        controller: widget.controller,
        focusNode: _focus,
        enabled: widget.enabled,
        obscureText: widget.obscureText,
        autofocus: widget.autofocus,
        textInputAction: widget.textInputAction,
        autofillHints: widget.autofillHints,
        onSubmitted: widget.onSubmitted,
        // 新增能力（供验证码/邮箱等场景；web 用 inputMode + maxLength +
        // `replace(/\D/g,"")` 表达）
        keyboardType: widget.keyboardType,
        inputFormatters: widget.inputFormatters,
        maxLength: widget.maxLength,
        onChanged: widget.onChanged,
        minLines: widget.minLines,
        // ⚠️ TextField 的 maxLines 语义：**null = 不限行数**（不是默认单行）——
        // 直接透传 null 会把所有单行字段变成多行（实测：隐私设置校验/画布冒烟全崩）。
        // 故未显式传时统一回落 1（= TextField 默认单行）。
        maxLines: widget.maxLines ?? 1,
        cursorColor: AylaColors.indigo700,
        style: widget.textStyle ??
            text.body.copyWith(color: AylaColors.textPrimary),
        decoration: InputDecoration(
          isDense: true,
          border: InputBorder.none,
          enabledBorder: InputBorder.none,
          focusedBorder: InputBorder.none,
          disabledBorder: InputBorder.none,
          contentPadding: EdgeInsets.zero,
          hintText: widget.hintText,
          hintStyle: text.body.copyWith(color: AylaColors.textSecondary),
        ),
      ),
    );

    // 层序（对齐 CSS）：
    //   ① backdrop-filter（blur 24 + saturate 1.4）——只模糊字段背后的内容
    //   ② --glass-inset 顶沿 1px 内高光（不参与裁剪）
    //   ③ face（半透明底 + 亮边）
    Widget field = Stack(
      children: <Widget>[
        if (!opaque)
          Positioned.fill(
            // 背后内容层统一走 AylaGlassBackdrop（质量档 owner，§8.17）。
            child: AylaGlassBackdrop(
              radius: rInput,
              // auroraqua.css 507：`.field { backdrop-filter: var(--glass-filter) }`
              // = `blur(24px) saturate(1.4)`（tokens.css 76）
              filter: AylaGlassConfig.backdropFilter(sigma: AylaGlass.blurCard),
            ),
          ),
        // `:focus → box-shadow: var(--glow-shadow)`（auroraqua.css 513–518）——
        // 只画形状之外 + 200ms 淡入淡出；2026-09-20 审查 R2：原裸 boxShadow 会把
        // `.45` 粉辉光铺进 `.55` 玻璃内部（聚焦时输入框内部发粉）。
        Positioned.fill(
          child: IgnorePointer(
            child: AnimatedOpacity(
              duration: AylaDurations.button,
              curve: AylaCurves.auroraqua,
              opacity: _focused ? 1.0 : 0.0,
              child: AylaGlassShadow.ring(
                radius: rInput,
                shadows: AylaShadows.glow,
              ),
            ),
          ),
        ),
        Positioned.fill(
          child: IgnorePointer(
            child: LayoutBuilder(
              builder: (BuildContext context, BoxConstraints c) {
                return DecoratedBox(
                  decoration: BoxDecoration(
                    borderRadius: rInput,
                    gradient: AylaInset.topHighlight(c.maxHeight),
                  ),
                );
              },
            ),
          ),
        ),
        face,
      ],
    );

    return Semantics(
      textField: true,
      label: widget.semanticLabel ?? widget.hintText,
      child: field,
    );
  }
}

// ======================= 样张 =======================


class _GlassInputSample extends StatefulWidget {
  const _GlassInputSample();

  @override
  State<_GlassInputSample> createState() => _GlassInputSampleState();
}

class _GlassInputSampleState extends State<_GlassInputSample> {
  final TextEditingController _a = TextEditingController();
  final TextEditingController _b = TextEditingController(text: '123');

  @override
  void dispose() {
    _a.dispose();
    _b.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(AylaSpacing.sp6),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: <Widget>[
          AylaGlassInput(controller: _a, hintText: 'hint = slate-500'),
          const SizedBox(height: AylaSpacing.sp4),
          AylaGlassInput(controller: _b, autofocus: true),
        ],
      ),
    );
  }
}
