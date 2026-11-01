/// 播放器**纹理尺寸固定**策略（开发文档 §3 B4，Flutter 独有缺陷）。
///
/// ## 根因（B4）
/// `media_kit_video` 的 `VideoOutput::CheckAndResize()`
/// （`third_party/media_kit_video/windows/video_output.cc:241–266`）每次渲染前比对
/// 「视频要求尺寸」与「当前纹理尺寸」：
/// ```cpp
/// auto required_width = GetVideoWidth(), required_height = GetVideoHeight();
/// if (required_width == current_width && required_height == current_height) return;
/// Resize(required_width, required_height);   // ← UnregisterTexture + 新建纹理
/// ```
/// 而 `GetVideoWidth()`（同文件 `:366–413`）在 `width_` 为空时读的是
/// **`video-out-params` 的 dw/dh（视频自身分辨率）**；只有显式调用
/// `VideoController.setSize()` 才会把 `width_` / `height_` 钉死。
///
/// **Ayla 从未调用过 `setSize()`**（全仓 grep 0 命中）⇒ 纹理尺寸完全跟随视频分辨率，
/// 任何让 mpv 重算输出尺寸的事件（窗口尺寸变化 / 最大化 / 全屏切换）都可能驱动
/// `Resize()` ⇒ 注销并重建纹理 ⇒ 用户看到「闪黑一帧，严重时永久黑」
/// （需求 §3.1 B4 / §5.1 S4）。
///
/// ## 修法
/// 只在**视频原生分辨率真的变化时**调 `setSize(width, height)`：视频是 1920×1080 就
/// 固定 1920×1080，此后窗口怎么缩放都不再改变 `required_width/height`
/// ⇒ `CheckAndResize` 恒走 early-return ⇒ 不重建纹理。
///
/// 本文件只做**决策**（纯逻辑），不做平台调用 ⇒ 能被单元测试确定性地锁住
/// （`test/media_kit_texture_size_test.dart`）。
library;

import 'dart:async';

/// 连续变化的合并窗口（用户方案：「去抖（连续变化 200ms 内合并）」）。
///
/// 为什么需要：分辨率在上报时可能分两次到达（先 width 后 height，或 mpv 重算输出参数
/// 时给出中间值）。若每次都立刻 `setSize`，一次真实的分辨率切换会连续调 2~3 次
/// `setSize`，而每次 `setSize` 之前若巧逢 `CheckAndResize` 都可能触发一次
/// Resize ⇒ 一次切换闪黑多帧。合并到 200ms 之后，同一轮变化只落一次。
const Duration kTextureSizeDebounce = Duration(milliseconds: 200);

/// 一次 `setSize` 的目标。
class AylaTextureSize {
  const AylaTextureSize(this.width, this.height);

  final int width;
  final int height;

  bool get isValid => width > 0 && height > 0;

  @override
  bool operator ==(Object other) =>
      other is AylaTextureSize && other.width == width && other.height == height;

  @override
  int get hashCode => Object.hash(width, height);

  @override
  String toString() => '${width}x$height';
}

/// 纹理尺寸决策器：**同一分辨率只调一次 setSize，分辨率变化才更新**。
///
/// 用法（`media_kit_impl.dart`）：
/// ```dart
/// _sizeDecider = AylaTextureSizeDecider(
///   onApply: (AylaTextureSize size) => unawaited(
///     _videoController?.setSize(width: size.width, height: size.height) ??
///         Future<void>.value(),
///   ),
/// );
/// _subs.add(p.stream.width.listen((w) => _sizeDecider?.offer(w, p.state.height)));
/// ```
///
/// 语义（逐条对应验收口径）：
/// 1. 首次拿到有效分辨率 ⇒ 应用；
/// 2. 分辨率**未变** ⇒ 不重复调用（幂等）；窗口尺寸变化根本不进本类；
/// 3. 分辨率**变了** ⇒ 去抖后应用（连续变化 200ms 内合并为最后一次）。
///
/// 无效值（null / 0 / 负数）一律忽略：mpv 在切分片、重建解码器期间会短暂上报 0，
/// 那不是「分辨率变成 0」，跟着改会把纹理改成 0×0（比黑屏更难恢复）。
class AylaTextureSizeDecider {
  AylaTextureSizeDecider({
    required this.onApply,
    this.debounce = kTextureSizeDebounce,
  });

  /// 真正下发 `setSize` 的动作（平台实现注入）。
  final void Function(AylaTextureSize size) onApply;

  /// 去抖窗口（生产固定 [kTextureSizeDebounce]；测试可缩短）。
  final Duration debounce;

  /// 已经下发过的尺寸（null = 还没下发过）。
  AylaTextureSize? _applied;

  /// 去抖窗口内最近一次被接受的尺寸（会被后续上报覆盖）。
  AylaTextureSize? _pending;

  Timer? _timer;

  /// 已经下发过的尺寸（测试断言用；生产只读）。
  AylaTextureSize? get applied => _applied;

  /// 是否有待下发的变更（测试断言用）。
  bool get hasPending => _pending != null;

  /// 平台上报一次「视频原生分辨率」。
  ///
  /// 返回 true = 本次**接受**了这个尺寸（去抖后会下发 setSize）；
  /// false = 忽略（无效值 / 与已下发或待下发的尺寸相同）。
  bool offer(int? width, int? height) {
    if (width == null || height == null) return false;
    if (width <= 0 || height <= 0) return false;
    final AylaTextureSize size = AylaTextureSize(width, height);
    if (size == _applied || size == _pending) return false;
    _pending = size;
    _timer?.cancel();
    _timer = Timer(debounce, _flush);
    return true;
  }

  void _flush() {
    _timer = null;
    final AylaTextureSize? size = _pending;
    _pending = null;
    if (size == null || size == _applied) return;
    _applied = size;
    onApply(size);
  }

  /// 取消挂起的计时器（`dispose` 用；不下发挂起的变更）。幂等。
  void dispose() {
    _timer?.cancel();
    _timer = null;
    _pending = null;
  }
}
