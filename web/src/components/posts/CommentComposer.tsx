import { useState } from "react";
import { uploadMediaFile, validateMediaFile } from "../../api/media";
import { apiRequest } from "../../api/client";
import type { MediaDescriptor, PostComment } from "../../api/types";
import { IconImage } from "../icons";
import { ResourceImage } from "../ResourceImage";
import { NARROW_QUERY, useMediaQuery } from "../../hooks/useMediaQuery";

type PendingImage = {
  mediaId: string;
  descriptor: MediaDescriptor;
  /** 上传会话 id：移除时清理对象存储 */
  uploadId: string;
  /** 本地预览 objectURL */
  localUrl: string;
};

export function CommentComposer({
  onSend,
  replyTarget,
  onReplyClear,
  className = "",
  inputEntered = true,
}: {
  /** body + 图片 mediaId 列表一起提交（图文同发） */
  onSend: (body: string, replyTo: number | null, imageIds: string[]) => Promise<void>;
  replyTarget: PostComment | null;
  onReplyClear: () => void;
  className?: string;
  /** 窄屏详情页复用进直播间的底部输入框滑入状态。 */
  inputEntered?: boolean;
}) {
  const [body, setBody] = useState("");
  const [pending, setPending] = useState<PendingImage[]>([]);
  const [sending, setSending] = useState(false);
  const [uploading, setUploading] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [failedFiles, setFailedFiles] = useState<File[]>([]);
  const isNarrow = useMediaQuery(NARROW_QUERY);

  const MAX_IMAGES = 4;

  const sendComment = async () => {
    const trimmed = body.trim();
    if ((!trimmed && pending.length === 0) || sending || uploading) return;
    setSending(true);
    setError(null);
    try {
      await onSend(
        trimmed,
        replyTarget ? Number(replyTarget.id) : null,
        pending.map((p) => p.mediaId),
      );
      setBody("");
      setPending([]);
      setFailedFiles([]);
      if (replyTarget) onReplyClear();
    } catch (e) {
      setError(e instanceof Error ? e.message : "发送失败");
    } finally {
      setSending(false);
    }
  };

  const removePending = (p: PendingImage) => {
    setPending((prev) => prev.filter((x) => x.mediaId !== p.mediaId));
    // 已直传到 MinIO 的对象即时回收（owner 删除端点）
    void apiRequest(`/media/${p.mediaId}`, { method: "DELETE" }).catch(() => {});
  };

  const uploadFiles = async (files: File[]) => {
    if (uploading || sending || files.length === 0) return;
    const room = Math.max(0, MAX_IMAGES - pending.length);
    const take = files.slice(0, Math.max(0, room));
    const overflow = files.length - take.length;
    if (overflow > 0) setError(`最多 ${MAX_IMAGES} 张图片`);
    if (take.length === 0) return;

    setUploading(true);
    setError(overflow > 0 ? `最多 ${MAX_IMAGES} 张图片` : null);
    setFailedFiles([]);
    const ok: PendingImage[] = [];
    const failed: File[] = [];
    for (const file of take) {
      const check = validateMediaFile(file);
      if (check.error || check.kind !== "image") {
        failed.push(file);
        continue;
      }
      try {
        const uploaded = await uploadMediaFile(file, "image");
        ok.push({
          mediaId: uploaded.media_id,
          descriptor: uploaded.descriptor,
          uploadId: uploaded.upload_id,
          localUrl: URL.createObjectURL(file),
        });
      } catch (err) {
        failed.push(file);
        setError(err instanceof Error ? err.message : "图片发送失败");
      }
    }
    setPending((prev) => [...prev, ...ok]);
    setFailedFiles(failed);
    if (failed.length > 0) setError(`${failed.length} 张图片上传失败，可重试`);
    setUploading(false);
  };

  return (
    <div
      className={`comment-composer ${className}`.trim()}
      style={{
        transform: inputEntered ? "translateY(0)" : "translateY(100%)",
        transition: "transform 250ms var(--ease-out)",
      }}
    >
      {replyTarget && (
        <div className="comment-reply-bar">
          回复 @{replyTarget.author.nickname || replyTarget.author.username}
          <button type="button" className="comment-action" onClick={onReplyClear}>取消</button>
        </div>
      )}
      {error && <p className="post-editor-error">{error}</p>}
      {failedFiles.length > 0 && (
        <button
          type="button"
          className="msg-action-btn"
          disabled={uploading}
          onClick={() => {
            const files = failedFiles;
            setFailedFiles([]);
            void uploadFiles(files);
          }}
        >
          重试图片（{failedFiles.length}）
        </button>
      )}
      {pending.length > 0 && (
        <div className="composer-pending-images">
          {pending.map((p) => (
            <div key={p.mediaId} className="composer-pending-image">
              {/* 签名缩略图直连（原生 img 401 会显示损坏图） */}
              <ResourceImage
                src={`/api/v1/media/${p.mediaId}/thumbnail`}
                alt="待发送图片"
                variant="thumb"
                fallback={<span className="skeleton" style={{ width: 64, height: 64 }} />}
              />
              <button
                type="button"
                aria-label="移除图片（同时从服务器删除）"
                onClick={() => removePending(p)}
              >
                ×
              </button>
            </div>
          ))}
        </div>
      )}
      <div className="composer-row">
        <label className="composer-tool-btn" aria-label="添加图片（可多选，与文字一起发送）">
          <IconImage width={18} height={18} />
          <input
            type="file"
            accept="image/*"
            multiple
            hidden
            onChange={(event) => {
              const files = Array.from(event.target.files ?? []);
              event.target.value = "";
              void uploadFiles(files);
            }}
          />
        </label>
        <textarea
          className="field composer-input"
          placeholder={isNarrow ? "写评论…" : "写评论…（可与图片一起发）"}
          rows={1}
          value={body}
          onChange={(event) => setBody(event.target.value)}
        />
        <button
          type="button"
          className="btn btn-primary"
          disabled={sending || uploading || (!body.trim() && pending.length === 0)}
          onClick={() => void sendComment()}
        >
          {sending || uploading ? "发送中…" : "发送"}
        </button>
      </div>
    </div>
  );
}
