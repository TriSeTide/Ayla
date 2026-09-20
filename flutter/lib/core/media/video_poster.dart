/// 视频首帧海报抓取 —— 对齐 web `captureVideoPoster` / `uploadPoster`
/// （`Ayla/web/src/api/media.ts:458–518`）。
///
/// ## web 的做法
/// 用 `<video>` 加载文件 → `loadeddata` → seek 到 0.1s → `<canvas>` 绘制
/// （宽边压到 640）→ `canvas.toBlob('image/jpeg', 85)` →
/// `POST /media/{id}:poster`；**海报失败静默**（封面缺失不影响视频本体）。
///
/// ## Flutter 的做法
/// 没有 DOM 画布：改用 **media_kit（mpv）** 解码 —— `Player.open(path, play: false)`
/// → 等解码器就绪 → `seek(0.1s)` → `Player.screenshot(format: 'image/jpeg')`。
/// media_kit 的 `screenshot` 默认就是 JPEG，与 web 的输出格式一致；
/// 缩放由 mpv 决定（web 的 640 宽边压缩是浏览器侧的额外处理，这里不做二次缩放，
/// 避免引入图像处理依赖）。
///
/// ⚠️ 依赖 `MediaKit.ensureInitialized()`（本模块内幂等调用）与桌面端 mpv 运行库
/// （项目已在 `build/windows/x64/` 落盘）。抓帧需要真实视频文件与平台解码，
/// widget test 里通过 [AylaPosterCaptureBackend] 注入替身验证组合逻辑。
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:media_kit/media_kit.dart';

import 'media_upload.dart';

/// 抓帧后端（生产 = [AylaMediaKitPosterCapture]；测试注入替身）。
abstract interface class AylaPosterCaptureBackend {
  /// 抓取 [path] 视频在 [at] 处的帧（JPEG 字节）；失败返回 null。
  Future<Uint8List?> captureFrame(
    String path,
    Duration at,
    Duration timeout,
  );
}

/// 生产后端：media_kit（mpv）解码 + `Player.screenshot(image/jpeg)`。
class AylaMediaKitPosterCapture implements AylaPosterCaptureBackend {
  const AylaMediaKitPosterCapture();

  @override
  Future<Uint8List?> captureFrame(
    String path,
    Duration at,
    Duration timeout,
  ) async {
    MediaKit.ensureInitialized(); // 幂等
    final Player player = Player();
    try {
      await player.open(Media(path), play: false);
      // 解码器就绪（轨道参数可用）后再 seek，避免对未初始化的轨道截图。
      await player.stream.videoParams
          .firstWhere((VideoParams? params) => params != null)
          .timeout(timeout);
      await player.seek(at);
      // seek 到位（位置到达目标附近）后再截图，避免拿到 0 帧（黑帧）。
      await player.stream.position
          .firstWhere(
            (Duration position) =>
                position >= at - const Duration(milliseconds: 50),
          )
          .timeout(timeout);
      return await player.screenshot(format: 'image/jpeg');
    } finally {
      await player.dispose();
    }
  }
}

/// 海报抓取入口（web `captureVideoPoster` + `uploadPoster` 的组合）。
class AylaVideoPoster {
  AylaVideoPoster._();

  /// 抓帧时间点（web：seek 到 0.1s，`media.ts:487`）。
  static const Duration captureAt = Duration(milliseconds: 100);

  /// 抓帧超时（web：15s，`media.ts:479`）。
  static const Duration captureTimeout = Duration(seconds: 15);

  /// 抓帧后端（测试可替换）。
  static AylaPosterCaptureBackend backend = const AylaMediaKitPosterCapture();

  /// 抓取 [path] 的 0.1s 帧（null = 抓帧失败）。
  static Future<Uint8List?> capture(String path) =>
      backend.captureFrame(path, captureAt, captureTimeout);

  /// 抓帧并上传海报；**失败静默**（返回 false，不抛）——
  /// 与 web 同语义：海报缺失只影响封面展示，不影响视频本体（`media.ts:449–451`）。
  ///
  /// [upload] 默认走 [AylaMediaUploader.uploadPoster]；测试可注入替身。
  static Future<bool> captureAndUpload({
    required String mediaId,
    required String path,
    Future<void> Function(String mediaId, Uint8List jpeg)? upload,
  }) async {
    try {
      final Uint8List? jpeg = await capture(path);
      if (jpeg == null || jpeg.isEmpty) return false;
      final Future<void> Function(String, Uint8List) send =
          upload ?? AylaMediaUploader.instance.uploadPoster;
      await send(mediaId, jpeg);
      return true;
    } catch (_) {
      // 海报失败静默（web 同样忽略）：不把封面问题升级为上传失败
      return false;
    }
  }
}
