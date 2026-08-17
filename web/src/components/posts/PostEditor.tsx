/**
 * PostEditor —— 发帖表单（R-F3 / R-P2 / 群内 R-G5）。
 *
 * 标题（可选）+ 正文（必填）+ 图片（最多 9 张）。图片先走三步媒体上传，
 * 再把 media_id 列表随帖子提交；一级 tab 与群内路径共用本编辑器。
 */
import { useState } from "react";
import * as postsApi from "../../api/posts";
import { mediaContentUrl, resolveMediaPath, uploadMediaFile } from "../../api/media";
import type { MediaDescriptor, Post } from "../../api/types";
import { IconImage } from "../icons";
import { ResourceImage } from "../ResourceImage";

type PostImageDraft = {
  mediaId: string;
  descriptor: MediaDescriptor;
};

export function PostEditor({
  group,
  onCreated,
  compact = false,
}: {
  /** 群内发帖归属的群 id；一级 tab 为 null（公开） */
  group?: string | null;
  onCreated: (post: Post) => void;
  /** 紧凑模式（群内底部输入框变体：单行正文，无标题） */
  compact?: boolean;
}) {
  const [title, setTitle] = useState("");
  const [body, setBody] = useState("");
  const [images, setImages] = useState<PostImageDraft[]>([]);
  const [failedFiles, setFailedFiles] = useState<File[]>([]);
  const [submitting, setSubmitting] = useState(false);
  const [uploading, setUploading] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const uploadFiles = async (files: File[]) => {
    if (uploading || submitting || files.length === 0) return;
    const remaining = Math.max(0, 9 - images.length);
    if (files.length > remaining) {
      setError(`最多添加 9 张图片，还可添加 ${remaining} 张`);
      files = files.slice(0, remaining);
    }
    if (files.length === 0) return;

    setUploading(true);
    setError(null);
    const uploaded: PostImageDraft[] = [];
    const failed: File[] = [];
    for (const file of files) {
      try {
        const result = await uploadMediaFile(file, "image");
        uploaded.push({ mediaId: result.media_id, descriptor: result.descriptor });
      } catch {
        failed.push(file);
      }
    }
    setImages((prev) => [...prev, ...uploaded]);
    setFailedFiles((prev) => [...prev, ...failed]);
    if (failed.length > 0) setError(`${failed.length} 张图片上传失败，可点击重试`);
    setUploading(false);
  };

  const submit = async () => {
    const trimmed = body.trim();
    if (!trimmed) {
      setError("正文不能为空");
      return;
    }
    if (failedFiles.length > 0 || uploading) {
      setError("请先完成图片上传或重试失败图片");
      return;
    }
    setSubmitting(true);
    setError(null);
    try {
      const post = await postsApi.createPost({
        title: title.trim(),
        body: trimmed,
        group,
        images: images.map((image) => image.mediaId),
      });
      setTitle("");
      setBody("");
      setImages([]);
      setFailedFiles([]);
      onCreated(post);
    } catch (e) {
      setError(e instanceof Error ? e.message : "发布失败");
    } finally {
      setSubmitting(false);
    }
  };

  return (
    <div className="post-editor">
      {!compact && (
        <input
          className="field post-editor-title"
          placeholder="标题（可选）"
          value={title}
          maxLength={128}
          onChange={(e) => setTitle(e.target.value)}
        />
      )}
      <textarea
        className="field post-editor-body"
        placeholder={compact ? "发一条帖子…" : "正文（必填）"}
        value={body}
        rows={compact ? 1 : 4}
        onChange={(e) => setBody(e.target.value)}
      />
      {images.length > 0 && (
        <div className="post-editor-images" aria-label={`已添加 ${images.length} 张图片`}>
          {images.map((image) => (
            <div className="post-editor-image" key={image.mediaId}>
              <ResourceImage
                src={resolveMediaPath(image.descriptor.thumbnail) ?? mediaContentUrl(image.mediaId)}
                alt="已添加的帖子图片"
                loading="lazy"
              />
              <button
                type="button"
                className="post-editor-image-remove"
                aria-label="移除图片"
                disabled={submitting || uploading}
                onClick={() => setImages((prev) => prev.filter((item) => item.mediaId !== image.mediaId))}
              >
                ×
              </button>
            </div>
          ))}
        </div>
      )}
      {error && <p className="post-editor-error" role="alert">{error}</p>}
      {failedFiles.length > 0 && (
        <button
          type="button"
          className="msg-action-btn"
          disabled={submitting || uploading}
          onClick={() => {
            const retry = failedFiles;
            setFailedFiles([]);
            void uploadFiles(retry);
          }}
        >
          重试失败图片（{failedFiles.length}）
        </button>
      )}
      <div className="post-editor-actions">
        <label className="post-editor-image-btn" aria-label="添加帖子图片">
          <IconImage width={18} height={18} />
          <span>图片 {images.length}/9</span>
          <input
            type="file"
            accept="image/*"
            multiple
            hidden
            disabled={submitting || uploading || images.length >= 9}
            onChange={async (e) => {
              const files = Array.from(e.target.files ?? []);
              e.target.value = "";
              await uploadFiles(files);
            }}
          />
        </label>
        <button
          type="button"
          className="btn btn-primary post-editor-submit"
          disabled={submitting || uploading || !body.trim() || failedFiles.length > 0}
          onClick={() => void submit()}
        >
          {uploading ? "图片上传中…" : submitting ? "发布中…" : "发布"}
        </button>
      </div>
    </div>
  );
}
