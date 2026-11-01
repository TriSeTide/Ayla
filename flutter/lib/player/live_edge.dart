/// 直播「贴边」（seek to live edge）的**纯计算**部分。
///
/// ## 为什么单独抽出来（开发文档 §3 R1 / 需求 §3.3 R1）
/// 旧实现是 `seek(duration)`，而 HLS 直播的 `duration` 是**整个 playlist 的总长**
/// （实测 ≈66s），不是直播边缘 ⇒ 点「刷新」实际上是跳到 playlist 末尾附近，
/// 语义错误（需求文档 §3.3 R1）。
///
/// 直播真实边缘只能从播放器自己的 seekable 窗口拿：
/// - **media_kit / mpv**：`seekable-ranges` 属性（形如
///   `[{start=0.000000, end=66.000000}]`，多段时是多个 map）；
/// - **video_player / ExoPlayer**：Dart 侧没有 seekable API，只能退回
///   `duration - 1 个分片`。
///
/// 两端的兜底顺序一致（需求 §5.3 I1、开发文档 §3 R1/R3）：
/// **先 seek，失败才 rebuild**（`HlsPlaybackController.refreshToLiveEdge`）。
///
/// 本文件不依赖任何播放器插件 ⇒ 目标值可以被单元测试确定性地锁住
/// （`test/live_refresh_to_edge_test.dart`）。
library;

/// 贴边时从边缘回退的时长 = **1 个分片**（开发文档 §3 R1：`end - 2s`）。
///
/// 为什么不直接 seek 到 `end`：playlist 末尾那一片可能**还没写完**（SRS 正在追加
/// 分片），seek 到边缘常常立刻 EOF / 重新缓冲；退一片既能贴住直播边缘，
/// 又落在已经落盘的可播区间内。需求 §5.3 I1 的口径是「距离边缘 ≤2 个分片」。
const Duration kLiveEdgeSeekBackoff = Duration(seconds: 2);

/// `duration` 兜底路径的最低门槛（开发文档 §3 R1：`duration > 4s` 才做）。
///
/// 为什么：短视频 / VOD / 尚未拿到 playlist 时 `duration` 可能是 0 或几秒，
/// 对它做 `- 2s` 会算出 0 甚至负值 ⇒ seek 回开头（等于"刷新把直播倒回去了"）。
const Duration kLiveEdgeMinDuration = Duration(seconds: 4);

/// 解析 mpv 的 `seekable-ranges` 属性字符串，返回**最后一段的结束时间**。
///
/// 真实输出形如：
/// ```
/// [{start=0.000000, end=12.000000}]
/// [{start=52.000000, end=66.000000}, {start=66.000000, end=68.000000}]
/// ```
/// 多段时取**最大 end**（= 直播窗口的右边缘）；解析不到 / 空串 / 非法值 ⇒ null
/// （调用方退回 `duration` 兜底，绝不抛异常 —— seek 失败不该让刷新键炸掉）。
Duration? aylaParseSeekableEnd(String raw) {
  final RegExp endPattern = RegExp(r'end\s*=\s*([0-9]+(?:\.[0-9]+)?)');
  double? best;
  for (final RegExpMatch match in endPattern.allMatches(raw)) {
    final double? value = double.tryParse(match.group(1) ?? '');
    if (value == null || !value.isFinite || value <= 0) continue;
    if (best == null || value > best) best = value;
  }
  if (best == null) return null;
  return Duration(microseconds: (best * Duration.microsecondsPerSecond).round());
}

/// 计算贴边 seek 的目标位置。
///
/// 顺序（开发文档 §3 R1）：
/// 1. `seekableEnd` 有效 ⇒ `seekableEnd - [kLiveEdgeSeekBackoff]`（回退 1 个分片）；
/// 2. 否则 `duration - [kLiveEdgeSeekBackoff]`（且 `duration` 必须 > [kLiveEdgeMinDuration]）；
/// 3. 都不成立 ⇒ null（调用方走「重建」兜底）。
///
/// 结果恒 > 0：回退到负值时退回 `seekableEnd` 本身（宁可贴边也不倒回开头）。
Duration? aylaLiveEdgeSeekTarget({
  Duration? seekableEnd,
  Duration? duration,
}) {
  if (seekableEnd != null && seekableEnd > Duration.zero) {
    final Duration target = seekableEnd - kLiveEdgeSeekBackoff;
    return target > Duration.zero ? target : seekableEnd;
  }
  if (duration != null && duration > kLiveEdgeMinDuration) {
    return duration - kLiveEdgeSeekBackoff;
  }
  return null;
}
