/// 「选文件 → 本地校验 → 三步上传 →（视频）抓帧海报」的组合动作。
///
/// 直接满足组件库的注入契约：
/// - `AylaPostEditor.onPickMedia` / `onRetryFailedMedia`（签名见组件内定义）；
/// - `AylaCommentComposer.onPickImages`；
/// - `onRemoveMedia` / `onRemoveImage`（`Future<void> Function(AylaPostMediaDraft)`）。
///
/// 页面/组件接线只需一行，例如：
/// ```dart
/// onPickImages: (int remaining, ValueChanged<double?> onProgress) =>
///     AylaMediaActions.pickImages(remaining: remaining, onProgress: onProgress),
/// onRemoveImage: AylaMediaActions.removeDraft,
/// ```
///
/// ## 错误语义（对齐 web PostEditor 的消费方式）
/// - **本地校验失败**（类型/空文件/超限）→ 抛 [AylaUploadException]（message 即可展示
///   文案，组件 catch 后显示，不伪造成功）；
/// - **用户取消选择** → 返回空结果（不是错误）；
/// - **单张上传失败** → 计入 `failed` 交给组件显示「可点击重试」（web `failedFiles.length`）；
/// - **超出上限** → 计入 `overLimit`（web：`最多添加 N 个媒体`）。
///
/// ## 进度聚合
/// 多张时按「已完成张数 + 当前张进度」/ 总张数上报（0..1）；单张即该张进度；
/// 结束或取消时上报 null（组件据此收起进度条）。
library;

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show ValueChanged;

import '../models/media_kind.dart';
import '../models/post.dart'
    show AylaMediaDescriptor, AylaMediaPickResult, AylaPostMediaDraft;
import 'media_picker.dart';
import 'media_upload.dart';
import 'video_poster.dart';

/// 组合动作入口（全部为静态方法，页面直接注入）。
class AylaMediaActions {
  AylaMediaActions._();

  /// 发帖编辑器一次最多 9 个媒体（web `PostEditor`：`最多添加 9 个媒体`）。
  static const int maxPostMedia = 9;

  /// 评论输入框最多 4 张（web `CommentComposer`）。
  static const int maxCommentImages = 4;

  /// 选图片并上传（评论输入框；[remaining] = 4 − 已选）。
  static Future<AylaMediaPickResult> pickImages({
    required int remaining,
    ValueChanged<double?>? onProgress,
  }) =>
      _pick(
        kind: AylaPickKind.image,
        mediaKind: AylaMediaKind.image,
        remaining: remaining,
        onProgress: onProgress,
      );

  /// 选媒体（发帖编辑器「图片」钮：多选图片；[remaining] = 9 − 已选）。
  static Future<AylaMediaPickResult> pickMedia({
    required int remaining,
    ValueChanged<double?>? onProgress,
  }) =>
      _pick(
        kind: AylaPickKind.image,
        mediaKind: AylaMediaKind.image,
        remaining: remaining,
        onProgress: onProgress,
      );

  /// 选视频并上传（发帖编辑器「视频」钮；成功后自动抓首帧海报，失败静默）。
  static Future<AylaMediaPickResult> pickVideo({
    required int remaining,
    ValueChanged<double?>? onProgress,
  }) =>
      _pick(
        kind: AylaPickKind.video,
        mediaKind: AylaMediaKind.video,
        remaining: remaining,
        onProgress: onProgress,
      );

  /// 选任意文件并上传（发帖编辑器「文件」钮 / 聊天文件）。
  static Future<AylaMediaPickResult> pickFile({
    required int remaining,
    ValueChanged<double?>? onProgress,
  }) =>
      _pick(
        kind: AylaPickKind.file,
        mediaKind: AylaMediaKind.file,
        remaining: remaining,
        onProgress: onProgress,
      );

  /// 移除草稿媒体（`DELETE /media/{id}`；异常透传，组件据此报错且不移回）。
  static Future<void> removeDraft(AylaPostMediaDraft draft) =>
      AylaMediaUploader.instance.deleteMedia(draft.mediaId);

  static Future<AylaMediaPickResult> _pick({
    required AylaPickKind kind,
    required AylaMediaKind mediaKind,
    required int remaining,
    ValueChanged<double?>? onProgress,
  }) async {
    if (remaining <= 0) {
      return const AylaMediaPickResult(overLimit: 1);
    }
    final AylaPickResult picked = switch (kind) {
      AylaPickKind.image => await AylaMediaPicker.pickImages(),
      AylaPickKind.video => await AylaMediaPicker.pickVideo(),
      AylaPickKind.file => await AylaMediaPicker.pickFile(),
    };
    // 本地校验失败：文案交回组件展示（不静默丢弃、不伪造成功）
    final String? error = picked.error;
    if (error != null) throw AylaUploadException(error);
    if (picked.files.isEmpty) return const AylaMediaPickResult(); // 用户取消

    final int accepted = math.min(picked.files.length, remaining);
    final int overLimit = picked.files.length - accepted;
    final List<AylaPostMediaDraft> drafts = <AylaPostMediaDraft>[];
    int failed = 0;

    for (int index = 0; index < accepted; index++) {
      final AylaPickedFile file = picked.files[index];
      try {
        final Uint8List bytes = await file.readBytes();
        final AylaUploadResult uploaded =
            await AylaMediaUploader.instance.uploadBytes(
          bytes: bytes,
          kind: mediaKind,
          mimeType: file.mimeType,
          onProgress: (AylaUploadProgress progress) {
            final double? fraction = progress.fraction;
            if (fraction == null) {
              onProgress?.call(null);
              return;
            }
            onProgress?.call((index + fraction) / accepted);
          },
        );
        drafts.add(
          AylaPostMediaDraft(
            mediaId: uploaded.mediaId,
            // descriptor 缺失时只填已知字段（mediaId/kind），不伪造其它（认知零规则）
            descriptor: uploaded.descriptor ??
                AylaMediaDescriptor(
                  mediaId: uploaded.mediaId,
                  kind: mediaKind,
                ),
            localPath: file.path,
            uploadId: uploaded.uploadId,
          ),
        );
        // 视频：抓 0.1s 首帧上传海报（失败静默，不影响视频本体）。
        // 抓帧需要本地路径；无路径（web blob）时跳过。
        final String? path = file.path;
        if (mediaKind == AylaMediaKind.video && path != null) {
          await AylaVideoPoster.captureAndUpload(
            mediaId: uploaded.mediaId,
            path: path,
          );
        }
      } catch (_) {
        // 单张失败 → 计数交回组件（web `failedFiles.length`），不阻断其余文件
        failed++;
      }
    }
    onProgress?.call(null); // 结束收起进度
    return AylaMediaPickResult(
      drafts: drafts,
      failed: failed,
      overLimit: overLimit,
    );
  }
}
