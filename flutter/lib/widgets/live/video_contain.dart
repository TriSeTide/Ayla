/// 视频画面「等比铺满 + 多余留黑」（= CSS `object-fit: contain`）。
///
/// ## 为什么需要这一件（2026-11-01 用户实报「不要拉伸屏幕，要正常长宽比，多余的留黑」）
///
/// 直播全屏时播放器容器是**整块屏幕**（手机上是 19.5:9 之类的非 16:9 比例），
/// 而平台视图默认按**自己的尺寸**铺满父约束：
///
/// | 平台 | `buildView()` 交出的东西 | 父约束下的默认行为 |
/// |---|---|---|
/// | Android / iOS（`video_player`） | `Texture` | `RenderTexture` 是 **RenderProxyBox**：尺寸 = 父约束，纹理按**拉伸**绘制 ⇒ 画面变形 |
/// | Windows（`media_kit`） | `Video`（内部自带 `FittedBox(fit: BoxFit.contain)`） | 已正确，本件再收一遍也不会变差（见下「为什么不用 FittedBox」） |
///
/// web 侧没有这个问题：`object-fit: contain` 挂在 `<video>` 元素**自身**
/// （`app.css:3528–3533`），元素铺满 100%×100%、由元素内部做 letterbox。
/// Flutter 的 `video_player` **没有** `fit` 参数，只能在**外层**给出
/// 「最大等比盒 + 居中」来表达同一语义。
///
/// ## 🔒 比例是**限死**的，不是「等播放器上报」（2026-11-01 用户第二轮反馈）
///
/// 用户原话：「还是有概率拉伸，直接把全屏播放器的长宽比限死不就行了」——
/// 完全正确。上一版按「平台上报比例、报不出来就原样铺满」实现，于是**上报晚于
/// 进全屏那一刻**（刚进房 / 播放器刚自愈重建）就必然拉伸一次，而且（配合
/// overlay 快照的那个缺陷）可能**永远**停在拉伸态。「概率」就是这么来的。
///
/// ⇒ 现在语义改成：**默认比例 = [kAylaLiveVideoAspectRatio]（16:9），锁死**；
/// 播放器报出真实比例时才用它覆盖。最坏情况是「非 16:9 的流被按 16:9 收盒」
/// （画面略小、四周留黑），**绝不会变成拉伸**。
///
/// ## ⚠️ 与「外层不要套 FittedBox」那条既有结论的关系（别搞混）
///
/// `live_player.dart` 的既有注释警告过：**不要在 media_kit 的 `Video` 外面裸套
/// FittedBox** —— 那会把无界约束传给 mpv 内部的 `Stack(fit: expand)`，
/// 展开出 Infinity ⇒ 无效变换矩阵 ⇒ 黑屏（2026-10-01 实测）。
///
/// 那一条针对的是「`Video` 已经自己 contain 了，外面再包一层 FittedBox 反而破坏约束」。
/// 本件解决的是**相反**的场景：平台视图**没有** contain 能力（`Texture`）。
/// 因此这里**不用 FittedBox**（避免任何无界约束传导），而是用 [LayoutBuilder]
/// 直接算出**有界的确定尺寸**交给平台视图。
///
/// ## 事实源
/// `app.css:3528–3533`：
/// ```
/// .live-player-video { width: 100%; height: 100%; object-fit: contain; background: #000; }
/// ```
/// —— 以及 `app.css:3640–3645` 的 `.live-player:fullscreen { width:100vw; height:100vh; aspect-ratio:auto; background:#000 }`
/// （**容器**铺满、**画面**在其中 letterbox）。
library;

import 'dart:math' as math;

import 'package:flutter/widgets.dart';

/// 直播画面的**默认**宽高比（锁死值）。
///
/// 事实源：`app.css:3521` 的 `.live-player { aspect-ratio: 16 / 9 }` ——
/// 站内播放器、封面、小窗全部按 16:9 设计，直播流本身也是 16:9 输出。
///
/// 用途见 [AylaVideoContain]：播放器没上报（或上报晚于进全屏）时用它兜底，
/// **保证任何时刻都有确定的盒子**，而不是「铺满父约束」（那就是拉伸）。
const double kAylaLiveVideoAspectRatio = 16 / 9;

/// 把「任意比例的播放面」等比放进父约束、多余留黑（= `object-fit: contain`）。
class AylaVideoContain extends StatelessWidget {
  const AylaVideoContain({
    super.key,
    required this.aspectRatio,
    required this.child,
  });

  /// 画面宽高比（宽 / 高）。**不可为 null**：null 由调用方解析成
  /// [kAylaLiveVideoAspectRatio]（见文件头「比例是限死的」）。
  final double aspectRatio;

  /// 平台视图（`Texture` / 平台视图 widget）。
  final Widget child;

  /// 归一化比例：非有限 / ≤0 ⇒ 退回 [kAylaLiveVideoAspectRatio]（不产出 NaN 尺寸）。
  double get _safeRatio =>
      aspectRatio.isFinite && aspectRatio > 0
          ? aspectRatio
          : kAylaLiveVideoAspectRatio;

  @override
  Widget build(BuildContext context) {
    final double ratio = _safeRatio;
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints c) {
        final bool finiteW = c.maxWidth.isFinite;
        final bool finiteH = c.maxHeight.isFinite;
        final double w;
        final double h;
        if (finiteW && finiteH) {
          // 两边都有界：取「按高算的宽」与可用宽的较小者（= contain 的核心一步）
          final double wByHeight = c.maxHeight * ratio;
          if (wByHeight <= c.maxWidth) {
            w = wByHeight;
            h = c.maxHeight;
          } else {
            w = c.maxWidth;
            h = c.maxWidth / ratio;
          }
        } else if (finiteW) {
          w = c.maxWidth;
          h = c.maxWidth / ratio;
        } else if (finiteH) {
          h = c.maxHeight;
          w = c.maxHeight * ratio;
        } else {
          // 两边都无界（极少见）：交给调用方的约束，本件不猜尺寸
          return child;
        }
        // ---- 退化分支不再 `return child`（2026-11-02 逐帧实测修正）--------
        //
        // 旧写法在 `w<=0 || h<=0` 时直接把 child 交回去 ⇒ child 拿到的是**父约束**，
        // 而这里的父约束可能仍是无界/零尺寸。逐帧探针实测（P2 定性）：
        // 首次进全屏时恰好有 **1 帧** `zeroSizeFrames=1` —— 那一帧视频节点被放进
        // 一个零尺寸盒子，视觉上就是「闪一下黑」。
        //
        // 现在改成：**永远产出有界的正尺寸**（最小 1px）。代价只是那一帧画面被
        // 压到 1px（几乎看不见），收益是彻底消除零尺寸帧，且不会把无界约束
        // 传给平台视图（无界约束会导致 media_kit 内部 Stack 展开出 Infinity ⇒
        // NaN 变换矩阵 ⇒ 整层不绘制，见 live_player.dart 记录的 2026-10-01 事故）。
        final double safeW = w > 0 ? w : 1.0;
        final double safeH = h > 0 ? h : 1.0;
        // 不取整：亚像素抖动在全屏下逐帧 ±1px 很显眼
        return Center(
          child: SizedBox(
            width: math.max(safeW, 0),
            height: math.max(safeH, 0),
            child: child,
          ),
        );
      },
    );
  }
}
