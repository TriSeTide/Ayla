/**
 * PostEditor —— 发帖表单（R-F3 / R-P2 / 群内 R-G5）。
 *
 * 标题（可选）+ 正文（必填）+ 图片（最多 9 张）。图片先走三步媒体上传，
 * 再把 media_id 列表随帖子提交；一级 tab 与群内路径共用本编辑器。
 *
 * 可展开/收起模式（collapsible）：默认收起只显示输入框+发布按钮+展开按钮，
 * 点击输入框或展开按钮展开完整编辑器，展开后顶部有收起按钮。
 */
import { useState } from "react";
import * as postsApi from "../../api/posts";
import { mediaContentUrl, resolveMediaPath, uploadMediaFile } from "../../api/media";
import type { MediaDescriptor, Post } from "../../api/types";
import { IconImage, IconChevronUp, IconChevronDown } from "../icons";
import { ResourceImage } from "../ResourceImage";
import { VisibilitySelector, type VisibilitySelection } from "../VisibilitySelector";

type PostImageDraft = {
  mediaId: string;
  descriptor: MediaDescriptor;
};

export function PostEditor({
  group,
  onCreated,
  compact = false,
  collapsible = false,
}: {
  /** 群内发帖归属的群 id；一级 tab 为 null（公开） */
  group?: string | null;
  onCreated: (post: Post) => void;
  /** 紧凑模式（群内底部输入框变体：单行正文，无标题） */
  compact?: boolean;
  /** 可展开/收起模式（默认收起，点击输入框或展开按钮展开） */
  collapsible?: boolean;
}) {
  const [title, setTitle] = useState("");
  const [body, setBody] = useState("");
  const [visibility, setVisibility] = useState<VisibilitySelection>(
    group ? { public: false, friends: false, group: true } : { public: true, friends: false, group: false }
  );
  const [selectedGroupIds, setSelectedGroupIds] = useState<string[]>(group ? [group] : []);
  const [images, setImages] = useState<PostImageDraft[]>([]);
  const [failedFiles, setFailedFiles] = useState<File[]>([]);
  const [submitting, setSubmitting] = useState(false);
  const [uploading, setUploading] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [expanded, setExpanded] = useState(!collapsible);

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
      // 多选转后端格式：public 单选；friends + group 可共存，优先 friends
      const backendVisibility = visibility.public
        ? "public"
        : visibility.friends
          ? "friends"
          : "group";
      const post = await postsApi.createPost({
        title: title.trim(),
        body: trimmed,
        group,
        visibility: backendVisibility,
        allowed_group_ids: selectedGroupIds.length > 0 ? selectedGroupIds : undefined,
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
    <div className={`post-editor ${collapsible ? "is-collapsible" : ""} ${expanded ? "is-expanded" : ""}`}>
      {collapsible && expanded && (
        <div className="post-editor-collapse-bar">
          <button
            type="button"
            className="post-editor-collapse-btn"
            onClick={() => setExpanded(false)}
            aria-label="收起发帖面板"
            title="收起"
          >
            <IconChevronDown width={18} height={18} />
          </button>
        </div>
      )}
      {!compact && expanded && (
        <input
          className="field post-editor-title"
          placeholder="标题（可选）"
          value={title}
          maxLength={128}
          onChange={(e) => setTitle(e.target.value)}
        />
      )}
      <div className="post-editor-input-row">
        <textarea
          className="field post-editor-body"
          placeholder={compact ? "发一条帖子…" : "正文（必填）"}
          value={body}
          rows={compact && !expanded ? 1 : expanded ? 4 : 1}
          onFocus={() => collapsible && !expanded && setExpanded(true)}
          onChange={(e) => setBody(e.target.value)}
        />
        <button
          type="button"
          className="btn btn-primary post-editor-submit"
          disabled={submitting || uploading || !body.trim() || failedFiles.length > 0}
          onClick={() => void submit()}
        >
          {uploading ? "上传中…" : submitting ? "发布中…" : "发布"}
        </button>
        {collapsible && !expanded && (
          <button
            type="button"
            className="post-editor-expand-btn"
            onClick={() => setExpanded(true)}
            aria-label="展开发帖面板"
            title="展开"
          >
            <IconChevronUp width={18} height={18} />
          </button>
        )}
      </div>
      {expanded && (
        <>
          <VisibilitySelector value={visibility} onChange={setVisibility} selectedGroupIds={selectedGroupIds} onSelectedGroupIdsChange={setSelectedGroupIds} initialGroupId={group} />
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
          </div>
        </>
      )}
    </div>
  );
}
