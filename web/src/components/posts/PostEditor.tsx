/**
 * PostEditor —— 发帖表单（R-F3 / R-P2 / 群内 R-G5）。
 *
 * 标题（必填）+ 正文（必填）+ 图片（最多 9 张）。图片先走三步媒体上传，
 * 再把 media_id 列表随帖子提交；一级 tab 与群内路径共用本编辑器。
 *
 * 可展开/收起模式（collapsible）：默认收起只显示单行输入框+发布按钮，
 * 点击输入框直接展开完整编辑器（无独立展开按钮），展开后顶部有收起按钮。
 * 上方遮罩由使用方渲染（onExpandedChange 通知展开状态），遮罩层级必须
 * 与面板容器平级才能夹在内容与面板之间（面板后代 fixed 无法跨堆叠上下文）。
 *
 * 整个编辑器是手势孤岛：touch + pointerdown 事件不向外冒泡，避免图片预览条
 * 横滑、正文横移光标等操作触发外层左右滑动切屏（群内五子界面手势，
 * 以及未来一级页面的切屏手势）。pointer 隔离是横滑改由 framer-motion
 * `drag="x"`（Pointer 事件）驱动后的必要补充：drag 用 pointerdown，touch 的
 * stopPropagation 拦不住（二者是不同原生事件流，且 framer-motion 直接
 * addEventListener 在场景容器上、先于 React 委托触发）。
 */
import { useState } from "react";
import type { TouchEvent as ReactTouchEvent, PointerEvent as ReactPointerEvent } from "react";
import * as postsApi from "../../api/posts";
import {
  uploadMediaFile,
  validateMediaFile,
} from "../../api/media";
import type { MediaDescriptor, Post } from "../../api/types";
import { IconImage, IconChevronDown } from "../icons";
import { VisibilitySelector, type VisibilitySelection } from "../VisibilitySelector";

type PostMediaDraft = {
  mediaId: string;
  descriptor: MediaDescriptor;
  /** 上传会话 id：移除时调 DELETE 清理对象存储 */
  uploadId: string;
  /** 本地预览 objectURL（视频/图片通用，页面生命周期内有效） */
  localUrl: string;
};

/** 面板内 touch 一律不冒泡：断开外层横滑切屏手势链，不影响默认滚动 */
const stopTouchPropagation = (e: ReactTouchEvent) => e.stopPropagation();

/**
 * 面板内 pointerdown 捕获阶段拦截：framer-motion drag（Pointer 事件）直接监听在场景容器上，
 * 先于 React 委托触发，故必须在 capture 阶段 stopPropagation，事件才不会冒泡到场景容器。
 */
const stopPointerPropagation = (e: ReactPointerEvent) => e.stopPropagation();

export function PostEditor({
  group,
  onCreated,
  compact = false,
  collapsible = false,
  expanded: expandedProp,
  onExpandedChange,
}: {
  /** 群内发帖归属的群 id；一级 tab 为 null（公开） */
  group?: string | null;
  onCreated: (post: Post) => void;
  /** 紧凑模式（群内底部输入框变体：收起时单行正文；展开后含标题/可见性/图片） */
  compact?: boolean;
  /** 可展开/收起模式（默认收起，点击输入框展开） */
  collapsible?: boolean;
  /** 受控展开态：传入后展开/收起完全由外部驱动（点遮罩收起等） */
  expanded?: boolean;
  /** 展开/收起状态变化通知（使用方据此渲染上方遮罩并更新受控状态） */
  onExpandedChange?: (expanded: boolean) => void;
}) {
  const [title, setTitle] = useState("");
  const [body, setBody] = useState("");
  const [visibility, setVisibility] = useState<VisibilitySelection>(
    group ? { public: false, friends: false, group: true } : { public: true, friends: false, group: false }
  );
  const [selectedGroupIds, setSelectedGroupIds] = useState<string[]>(group ? [group] : []);
  const [images, setImages] = useState<PostMediaDraft[]>([]);
  const [failedFiles, setFailedFiles] = useState<File[]>([]);
  const [submitting, setSubmitting] = useState(false);
  const [uploading, setUploading] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [internalExpanded, setInternalExpanded] = useState(!collapsible);
  // 半受控：传入 expanded 时以外部为准（点遮罩收起由使用方驱动）
  const expanded = expandedProp ?? internalExpanded;
  const updateExpanded = (value: boolean) => {
    setInternalExpanded(value);
    onExpandedChange?.(value);
  };
  const [progress, setProgress] = useState<number | null>(null);

  const removeMedia = (draft: PostMediaDraft) => {
    // 从待发列表移除；已直传到 MinIO 的对象即时回收（owner 删除端点）
    setImages((prev) => prev.filter((item) => item.mediaId !== draft.mediaId));
    if (draft.uploadId) {
      void import("../../api/client").then(({ apiRequest }) =>
        apiRequest(`/media/uploads/${draft.uploadId}`, { method: "DELETE" }).catch(() => {}),
      );
    } else {
      void import("../../api/media").then(({ deleteMedia }) =>
        deleteMedia(draft.mediaId).catch(() => {}),
      );
    }
  };

  const uploadFiles = async (files: File[]) => {
    if (uploading || submitting || files.length === 0) return;
    const remaining = Math.max(0, 9 - images.length);
    if (files.length > remaining) {
      setError(`最多添加 9 个媒体，还可添加 ${remaining} 个`);
      files = files.slice(0, remaining);
    }
    if (files.length === 0) return;

    setUploading(true);
    setError(null);
    const uploaded: PostMediaDraft[] = [];
    const failed: File[] = [];
    for (const file of files) {
      // 类型白名单校验（图片/视频），kind 随文件类型自动分流
      const check = validateMediaFile(file);
      if (check.error) {
        setError(check.error);
        failed.push(file);
        continue;
      }
      try {
        const result = await uploadMediaFile(file, check.kind, {
          onProgress: (p) => {
            const pct = p.total > 0 ? Math.round((p.loaded / p.total) * 100) : 0;
            setProgress(pct);
          },
        });
        uploaded.push({
          mediaId: result.media_id,
          descriptor: result.descriptor,
          uploadId: result.upload_id,
          localUrl: URL.createObjectURL(file),
        });
        setProgress(100);
      } catch {
        failed.push(file);
      }
    }
    setProgress(null);
    setImages((prev) => [...prev, ...uploaded]);
    setFailedFiles((prev) => [...prev, ...failed]);
    if (failed.length > 0) setError(`${failed.length} 个媒体上传失败，可点击重试`);
    setUploading(false);
  };

  const submit = async () => {
    const trimmedTitle = title.trim();
    const trimmed = body.trim();
    if (!trimmedTitle) {
      setError("标题不能为空");
      return;
    }
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
        title: trimmedTitle,
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
      // 发布完成收起编辑器（collapsible 模式回到单行输入）
      updateExpanded(false);
      onCreated(post);
    } catch (e) {
      setError(e instanceof Error ? e.message : "发布失败");
    } finally {
      setSubmitting(false);
    }
  };

  return (
    <div
      className={`post-editor ${collapsible ? "is-collapsible" : ""} ${expanded ? "is-expanded" : ""}`}
      onTouchStart={stopTouchPropagation}
      onTouchMove={stopTouchPropagation}
      onTouchEnd={stopTouchPropagation}
      onTouchCancel={stopTouchPropagation}
      onPointerDownCapture={stopPointerPropagation}
    >
      {collapsible && expanded && (
        <div className="post-editor-collapse-bar">
          <button
            type="button"
            className="post-editor-collapse-btn"
            onClick={() => updateExpanded(false)}
            aria-label="收起发帖面板"
            title="收起"
          >
            <IconChevronDown width={18} height={18} />
          </button>
        </div>
      )}
      {expanded && (
        <input
          className="field post-editor-title"
          placeholder="标题（必填）"
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
          onFocus={() => {
            if (collapsible && !expanded) updateExpanded(true);
          }}
          onChange={(e) => setBody(e.target.value)}
        />
        <button
          type="button"
          className="btn btn-primary post-editor-submit"
          disabled={submitting || uploading || !body.trim() || !title.trim() || failedFiles.length > 0}
          onClick={() => void submit()}
        >
          {uploading ? "上传中…" : submitting ? "发布中…" : "发布"}
        </button>
      </div>
      {expanded && (
        /* 低频配置区（可见性/群列表）内部滚动；媒体预览与进度固定在其下方始终可见 */
        <div className="post-editor-extra">
          <VisibilitySelector value={visibility} onChange={setVisibility} selectedGroupIds={selectedGroupIds} onSelectedGroupIdsChange={setSelectedGroupIds} initialGroupId={group} />
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
              重试失败媒体（{failedFiles.length}）
            </button>
          )}
        </div>
      )}
      {images.length > 0 && (
        /* 媒体预览横排固定可见（不进滚动区）——发图时缩略块始终在输入框下方 */
        <div className="post-editor-images" aria-label={`已添加 ${images.length} 个媒体`}>
          {images.map((image) => (
            <div className="post-editor-image" key={image.mediaId}>
              {image.descriptor.kind === "video" ? (
                // #t=0.1 强制 seek 首帧：moov 尾置 mp4 在 preload=metadata 下
                // 只显示黑帧，media fragment 让浏览器定位到 0.1s 渲染真实首帧
                <video src={`${image.localUrl}#t=0.1`} muted playsInline preload="metadata" />
              ) : (
                <img src={image.localUrl} alt="待发布媒体" />
              )}
              <button
                type="button"
                className="post-editor-image-remove"
                aria-label="移除媒体"
                disabled={submitting || uploading}
                onClick={() => removeMedia(image)}
              >
                ×
              </button>
            </div>
          ))}
        </div>
      )}
      {progress != null && (
        <div className="post-editor-progress" role="status">
          上传中 {progress}%
          <div className="post-editor-progress-bar">
            <div className="post-editor-progress-fill" style={{ width: `${progress}%` }} />
          </div>
        </div>
      )}
      {expanded && (
        <div className="post-editor-actions">
            <label className="post-editor-image-btn" aria-label="添加图片或视频">
              <IconImage width={18} height={18} />
              <span>图片/视频 {images.length}/9</span>
              <input
                type="file"
                accept="image/*,video/*"
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
      )}
    </div>
  );
}
