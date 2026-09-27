///
///  一次性烘焙图层 —— 把「内容 + CSS `filter: blur()`」录制成 [ui.Picture]，再烘焙成
///  [ui.Image]；之后**每帧只做「纹理绘制 + 变换」**。
///
///  ## 为什么必须烘焙（2026-09-25 用户实测事故）
///  web 的 `filter: blur(Npx)` 由浏览器合成器把结果缓存成纹理，旋转 / 缩放只是纹理变换；
///  Flutter 的 [ImageFiltered] 是 **layer 属性** —— 每帧合成都会重新执行模糊。首版把四层
///  （150vmax 渐变层 / 1.5×视口 湍流层 / 两个 40vw 光斑）各自套 [ImageFiltered] 后，用户实测
///  「太卡了完全没法正常看，debug 模式也是直接闪退」⇒ 逐帧大层模糊把 GPU 拖死。
///  烘焙后每帧成本 = 一次纹理绘制 ✓ 与 web 同量级。
///
///  ## 口径
///  - 烘焙分辨率 = 逻辑尺寸 × [MediaQuery.devicePixelRatioOf]（对齐 web 的设备像素语义），
///    最长边按 [kMaxAuroraBakeSide] clamp（极端大屏按比例降采样；内容经 blur 后是低频信号，
///    差异只在逐像素对账时可见）；
///  - 尺寸 / [revision] 变化才重新烘焙（[revision] 用于表达「依赖的外部资源变了」，
///    例如湍流纹理加载完成）；
///  - 模糊用 [Canvas.saveLayer] 的 `imageFilter` 在录制期施加 ⇒ 模糊被「烤进」纹理。
///
library;

import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

/// 烘焙纹理的最大边长（像素）。
const double kMaxAuroraBakeSide = 4096;

/// 流层渲染帧间隔：**默认 [Duration.zero] = 每个 vsync 都更新（满帧，有多少帧上多少帧）**。
///
/// 2026-09-25 用户裁定：优化方向是**降低每帧成本**（烘焙纹理 / 纹理预算 /
/// 减少 «BackdropFilter» 重算），不是减少帧数。这个旋钮只作为「低端设备 / 省电模式」
/// 的预留档位存在（想降档时把它设成 33ms 之类即可），正常路径**不要动它**。
const Duration kAuroraFrameInterval = Duration.zero;

/// 图层绘制函数：在**逻辑坐标**（尺寸 = [AylaAuroraBakedLayer.size]）里画内容。
typedef AylaAuroraPaint = void Function(Canvas canvas, Size size);

/// 一次性烘焙图层（见库注释）。
class AylaAuroraBakedLayer extends StatefulWidget {
  const AylaAuroraBakedLayer({
    super.key,
    required this.size,
    required this.draw,
    this.blurSigma = 0,
    this.blurOverscan = 0,
    this.opacity = 1,
    this.bakeMaxSide,
    this.revision,
  });

  /// 逻辑尺寸（CSS px / vw·vmax 的换算结果）。
  final Size size;

  /// 内容绘制。
  final AylaAuroraPaint draw;

  /// `filter: blur(Npx)` 的标准差（CSS Filter Effects 与 [ImageFilter.blur] 同语义）；0 = 不模糊。
  final double blurSigma;

  /// 模糊**向外扩散**要预留的边距（= 3 × [blurSigma]）。
  ///
  /// 为什么需要：CSS 的 filter 有 filter region（默认向外扩 10%），模糊结果可以**超出元素盒**；
  /// 而 [Canvas.saveLayer] 会把内容裁在 bounds 内 ⇒ 边缘扩散被切掉，露出**硬直边**
  /// （2026-09-25 用户实报：「背景总是出现裁切边旋转露出来」）。预留 overscan 后，烘焙图
  /// 四周多出空环、内容按原尺寸居中绘制，模糊自然渐隐到透明 —— 与 web 的 filter region 同义。
  final double blurOverscan;

  /// 图层整体不透明度（`opacity: .08` 等）—— 走 [RawImage.opacity] 的 alpha 调制，
  /// 不额外套 [Opacity]（避免再起一层离屏合成）。
  final double opacity;

  /// 烘焙纹理的**最长边像素上限**（null = 只受 [kMaxAuroraBakeSide] 约束）。
  ///
  /// 低频内容（模糊后的渐变 / 噪声雾 / 光斑）用 0.3–0.5× 分辨率烘焙：显存与带宽
  /// 按面积平方下降，而内容经 blur 后本就没有高频细节 —— iOS/Android 的系统模糊、
  /// Windows Acrylic 内部都是这么做的。1:1 只留给需要清晰的层。
  final double? bakeMaxSide;

  /// 依赖的外部资源标识（如湍流纹理）；变化即重新烘焙。
  final Object? revision;

  @override
  State<AylaAuroraBakedLayer> createState() => _AylaAuroraBakedLayerState();
}

class _AylaAuroraBakedLayerState extends State<AylaAuroraBakedLayer> {
  ui.Image? _image;
  Size? _bakedSize;
  Object? _bakedRevision;
  bool _baking = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // MediaQuery（devicePixelRatio）只能在 didChangeDependencies 之后读。
    _maybeBake();
  }

  @override
  void didUpdateWidget(covariant AylaAuroraBakedLayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    _maybeBake();
  }

  void _maybeBake() {
    if (_baking) return;
    if (_image != null &&
        _bakedSize == widget.size &&
        _bakedRevision == widget.revision) {
      return;
    }
    _bake();
  }

  Future<void> _bake() async {
    final Size size = widget.size;
    if (size.isEmpty || !size.isFinite) return;
    _baking = true;
    _bakedSize = size;
    _bakedRevision = widget.revision;

    // 含 overscan 的**外框**：烘焙图按它出图，内容按 [widget.size] 居中绘制。
    final Size outer = Size(
      size.width + widget.blurOverscan * 2,
      size.height + widget.blurOverscan * 2,
    );
    final double longestLogical = math.max(outer.width, outer.height);
    double ratio = MediaQuery.devicePixelRatioOf(context);
    final double cap = math.min(
      widget.bakeMaxSide ?? kMaxAuroraBakeSide,
      kMaxAuroraBakeSide,
    );
    if (longestLogical * ratio > cap) ratio = cap / longestLogical;
    final int width = math.max(1, (outer.width * ratio).round());
    final int height = math.max(1, (outer.height * ratio).round());

    final ui.PictureRecorder recorder = ui.PictureRecorder();
    final Canvas canvas = Canvas(recorder);
    canvas.scale(width / outer.width, height / outer.height);
    canvas.translate(widget.blurOverscan, widget.blurOverscan);
    if (widget.blurSigma > 0) {
      canvas.saveLayer(
        Offset.zero & size,
        Paint()
          ..imageFilter = ui.ImageFilter.blur(
            sigmaX: widget.blurSigma,
            sigmaY: widget.blurSigma,
          ),
      );
      widget.draw(canvas, size);
      canvas.restore();
    } else {
      widget.draw(canvas, size);
    }
    final ui.Picture picture = recorder.endRecording();
    final ui.Image image = await picture.toImage(width, height);
    picture.dispose();
    _baking = false;
    if (!mounted || _bakedSize != size || _bakedRevision != widget.revision) {
      return;
    }
    setState(() => _image = image);
  }

  @override
  Widget build(BuildContext context) {
    return RawImage(
      image: _image,
      // 尺寸含 overscan：调用方的 Positioned 也必须按 size + 2×overscan 布局
      //（内容仍在中间、中心不变 ⇒ 旋转/缩放的基准点不受影响）。
      width: widget.size.width + widget.blurOverscan * 2,
      height: widget.size.height + widget.blurOverscan * 2,
      fit: BoxFit.fill,
      // 烘焙像素 = 逻辑 × DPR ⇒ 常态是 1:1 映射；clamp 到 4096 或系统缩放变化时才
      // 需要重采样，低质量插值足够（内容经 blur 后是低频信号）。
      filterQuality: FilterQuality.low,
      opacity: widget.opacity >= 1
          ? null
          : AlwaysStoppedAnimation<double>(widget.opacity),
    );
  }
}


/// 背景时间轴的通知闸门（默认**不节流**：每个 vsync 都通知 = 满帧）。
///
/// 它是为「低端设备 / 省电模式降档」预留的旋钮（[kAuroraFrameInterval]），**不是**
/// 性能优化的默认手段 —— 2026-09-25 用户裁定「有多少帧上多少帧」：该做的是把
/// **每帧成本**压下去（烘焙纹理、纹理预算、减少 BackdropFilter 重算），而不是减少
/// 帧数。默认 interval = [Duration.zero] 时行为等价于直接监听控制器。
///
/// 用法：把它传给各层的 AnimatedBuilder(animation:)，层内读 clock.value
/// （就是控制器的当前进度；闸门只影响**通知频率**，不改时间轴本身）。
class AylaAuroraClock extends ChangeNotifier {
  AylaAuroraClock(
    this._controller, {
    this.interval = kAuroraFrameInterval,
  }) {
    _controller.addListener(_onTick);
  }

  final AnimationController _controller;

  /// 两次通知之间的最小间隔（默认 [kAuroraFrameInterval] = [Duration.zero] ⇒ 满帧）。
  final Duration interval;

  Duration _lastEmit = Duration.zero;

  /// 时间轴当前进度（0..1；直接读控制器，永远是**最新**值）。
  double get value => _controller.value;

  void _onTick() {
    final Duration? elapsed = _controller.lastElapsedDuration;
    if (elapsed != null && elapsed - _lastEmit < interval) return;
    _lastEmit = elapsed ?? Duration.zero;
    notifyListeners();
  }

  @override
  void dispose() {
    _controller.removeListener(_onTick);
    super.dispose();
  }
}
