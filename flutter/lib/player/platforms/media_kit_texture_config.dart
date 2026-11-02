/// media_kit（Windows/mpv）视频输出的**构造期纹理尺寸**。
///
/// 本文件对应开发文档 §3 B4 的**正确实现**（B4 早先那版用运行时
/// `VideoController.setSize()`，因 SIGSEGV 被整体禁用，见 `media_kit_impl.dart`
/// 的 B4 注释）。这里改成**创建 `VideoController` 时**传入固定尺寸。
///
/// ## 为什么这样能消除「尺寸变化过程黑屏」
///
/// 以下行号全部指向本仓库 vendor 副本 `third_party/media_kit_video/`：
///
/// 1. `VideoOutput` 构造时把 `configuration.width/height` 存进 `width_/height_`
///    （`windows/video_output.cc:25` 的初始化列表；参数解析在
///    `windows/media_kit_video_plugin.cc:140–153`，传 null 则保持 `std::nullopt`）；
/// 2. `GetVideoWidth()` 第一段就是「有固定值就直接返回」
///    （`windows/video_output.cc:366–370`）⇒ **永不读 `video-out-params`**；
/// 3. `CheckAndResize()`（`windows/video_output.cc:241–266`）比较 required 与
///    current，相等即 early-return。
///
/// 关键在于第 3 步**不是只在 resize 时跑**：`NotifyRender()` 每出一帧都会
/// `Post(CheckAndResize)`（`windows/video_output.cc:150–156`）。于是没有固定
/// 尺寸时，任何让 mpv 重算 `dw/dh` 的事件（窗口尺寸变化 / 最大化 / 进退全屏）
/// 都会让 required ≠ current ⇒ 走到 `Resize()`（`:268`）⇒
/// `UnregisterTexture` + `RegisterTexture` + 新建 `ID3D11Texture2D` / `EGLSurface`
/// （`:270–332`）⇒ 用户看到「窗口一动就闪黑」甚至永久黑。
///
/// 固定之后再怎么变尺寸，required 恒等于 current ⇒ 恒走 early-return ⇒
/// 纹理不再重建。
///
/// ## 为什么不用运行时 `setSize()`（那条路已禁用）
///
/// 除了「`VideoOutput` 未注册时 SIGSEGV」（`windows/video_output_manager.cc:30–37`
/// 只在 `video_outputs_` 里查得到才转发，否则静默丢弃；Dart 侧 `await` 的
/// `player.handle` 又不保证原生 `VideoOutput` 已注册），运行时那条路本身还有
/// 数据竞态：
/// - `VideoOutputManager::SetSize` 是 `std::thread(...).detach()`
///   （`windows/video_output_manager.cc:33`）；
/// - `Resize()` 在 `UnregisterTexture` 的**释放回调**里 `textures_.erase(id)`
///   （`windows/video_output.cc:285–292`）；
/// - `Render()` 读 `texture_id_` 时不持 `textures_mutex_`（`:159`）。
/// 三者并发 = 真实的 use-after-free 窗口。构造期传参**完全不经过**这条路径。
///
/// ## 与 fvp 的对比（为什么固定尺寸值得做）
///
/// media_kit 必然先建 **1×1 纹理**做 H/W 探测、再 Resize 到真实尺寸
/// （`lib/src/video/video_texture.dart:427–437` 的注释明说：a starting 1 pixel
/// sized texture is created to initialize the render context & check for H/W
/// support, then resized）。fvp 相反：延迟建纹理直到视频尺寸已知
/// （`fvp/lib/src/player.dart:203–237`，且 `CHANGELOG.md:230` 记录
/// "delay texture creation if video size is unknown, improve low latency
/// streams"）。固定尺寸把 media_kit 这次**必然发生**的重建也一并消掉了。
///
/// ## 代价（明确记录，避免后人误判）
///
/// - 纹理/视频输出固定 1920×1080：非 1080p 的流会被缩放。当前 SRS 推流固定
///   1080p30，因此无影响；**改推流分辨率时必须同步改本文件**。
/// - 纯音频流不会建纹理：`GetVideoWidth()` 返回 0 时 `CheckAndResize()`
///   在 `windows/video_output.cc:244` 直接 return，不会崩。
/// - Android 上 `width/height` 无效（上游文档
///   `lib/src/video_controller/video_controller.dart:45–46`），本配置只影响 Windows；
///   但移动端本来就不用 media_kit 播直播（见 `pubspec.yaml` 平台分派说明）。
library;

import 'package:media_kit_video/media_kit_video.dart';

/// 纹理 / 视频输出的固定宽度（像素）。
///
/// 必须与 SRS 推流分辨率一致（当前 1080p30 H264 3000kbps）。
const int kAylaTextureWidth = 1920;

/// 纹理 / 视频输出的固定高度（像素）。见 [kAylaTextureWidth]。
const int kAylaTextureHeight = 1080;

/// 创建 `VideoController` 时下发的固定输出尺寸配置。
///
/// 用法见 `media_kit_impl.dart` 的 `attach()`：
/// ```dart
/// _videoController = VideoController(p,
///     configuration: aylaMediaKitVideoConfiguration);
/// ```
///
/// `vo` / `hwdec` 显式写出上游默认值（`native_video_controller/real.dart:119–122`
/// 在 create() 里补的也是这两个），便于审计与排查。
const VideoControllerConfiguration aylaMediaKitVideoConfiguration =
    VideoControllerConfiguration(
  width: kAylaTextureWidth,
  height: kAylaTextureHeight,
  vo: 'libmpv',
  hwdec: 'auto',
);
