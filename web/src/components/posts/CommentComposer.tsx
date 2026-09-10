import { useEffect, useRef, useState } from "react";
import { deleteMedia, uploadMediaFile, validateMediaFile } from "../../api/media";
import type { MediaDescriptor, PostComment } from "../../api/types";
import { IconImage, IconSend } from "../icons";
import { ResourceImage } from "../ResourceImage";
import { NARROW_QUERY, useMediaQuery } from "../../hooks/useMediaQuery";

type PendingImage = {
  mediaId: string;
  descriptor: MediaDescriptor;
  /** 上传会话 id：移除时清理对象存储 */
  uploadId: string;
};

export function CommentComposer({
  onSend,
  replyTarget,
  onReplyClear,
  className = "",
  inputEntered = true,
  inert = false,
}: {
  /** body + 图片 mediaId 列表一起提交（图文同发） */
  onSend: (body: string, replyTo: number | null, imageIds: string[]) => Promise<void>;
  replyTarget: PostComment | null;
  onReplyClear: () => void;
  className?: string;
  /** 窄屏详情页复用进直播间的底部输入框滑入状态。 */
  inputEntered?: boolean;
  /** 编辑层覆盖时保留草稿 DOM，但从焦点与无障碍树中隔离。 */
  inert?: boolean;
}) {
  const [body, setBody] = useState("");
  const [pending, setPending] = useState<PendingImage[]>([]);
  const [sending, setSending] = useState(false);
  const [uploading, setUploading] = useState(false);
  const [removing, setRemoving] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [failedFiles, setFailedFiles] = useState<File[]>([]);
  const isNarrow = useMediaQuery(NARROW_QUERY);
  const active = useRef(true);
  const busy = useRef(false);
  const currentReply = useRef(replyTarget?.id ?? null);
  currentReply.current = replyTarget?.id ?? null;
  useEffect(() => {
    active.current = true;
    return () => { active.current = false; };
  }, []);

  const MAX_IMAGES = 4;

  const sendComment = async () => {
    const trimmed = body.trim();
    if ((!trimmed && pending.length === 0) || busy.current || failedFiles.length > 0) return;
    busy.current = true;
    const sentIds = new Set(pending.map((item) => item.mediaId));
    const sentReply = replyTarget?.id ?? null;
    setSending(true);
    setError(null);
    try {
      await onSend(
        trimmed,
        replyTarget ? Number(replyTarget.id) : null,
        pending.map((p) => p.mediaId),
      );
      if (!active.current) return;
      setBody((current) => current === body ? "" : current);
      setPending((current) => current.filter((item) => !sentIds.has(item.mediaId)));
      setFailedFiles([]);
      if (sentReply !== null && currentReply.current === sentReply) onReplyClear();
    } catch (e) {
      if (active.current) setError(e instanceof Error ? e.message : "发送失败");
    } finally {
      busy.current = false;
      if (active.current) setSending(false);
    }
  };

  const removePending = async (p: PendingImage) => {
    if (busy.current) return;
    busy.current = true;
    setRemoving(true);
    setError(null);
    try {
      await deleteMedia(p.mediaId);
      if (active.current) setPending((prev) => prev.filter((x) => x.mediaId !== p.mediaId));
    } catch (error) {
      if (active.current) setError(error instanceof Error ? error.message : "移除图片失败，请重试");
    } finally {
      busy.current = false;
      if (active.current) setRemoving(false);
    }
  };

  const uploadFiles = async (files: File[]) => {
    if (busy.current || files.length === 0) return;
    const room = Math.max(0, MAX_IMAGES - pending.length);
    const take = files.slice(0, Math.max(0, room));
    const overflow = files.length - take.length;
    if (overflow > 0) setError(`最多 ${MAX_IMAGES} 张图片`);
    if (take.length === 0) return;

    busy.current = true;
    setUploading(true);
    setError(overflow > 0 ? `最多 ${MAX_IMAGES} 张图片` : null);
    setFailedFiles([]);
    const ok: PendingImage[] = [];
    const failed: File[] = [];
    for (const file of take) {
      if (!active.current) break;
      const check = validateMediaFile(file);
      if (check.error || check.kind !== "image") {
        failed.push(file);
        continue;
      }
      try {
        const uploaded = await uploadMediaFile(file, "image");
        if (!active.current) break;
        ok.push({
          mediaId: uploaded.media_id,
          descriptor: uploaded.descriptor,
          uploadId: uploaded.upload_id,
        });
      } catch (err) {
        failed.push(file);
        if (active.current) setError(err instanceof Error ? err.message : "图片发送失败");
      }
    }
    busy.current = false;
    if (!active.current) return;
    setPending((prev) => [...prev, ...ok]);
    setFailedFiles(failed);
    if (failed.length > 0) setError(`${failed.length} 张图片上传失败，可重试`);
    setUploading(false);
  };

  return (
    <div
      className={`comment-composer ${className}`.trim()}
      {...(inert ? { inert: "", "aria-hidden": true as const } : {})}
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
      {error && <p className="post-editor-error" role="alert">{error}</p>}
      {failedFiles.length > 0 && (
        <div><button
          type="button"
          className="msg-action-btn"
          disabled={uploading || sending || removing}
          onClick={() => {
            const files = failedFiles;
            setFailedFiles([]);
            void uploadFiles(files);
          }}
        >
          重试图片（{failedFiles.length}）
        </button><button type="button" className="msg-action-btn" disabled={uploading || sending || removing} onClick={() => { setFailedFiles([]); setError(null); }}>移除失败图片</button></div>
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
                disabled={uploading || sending || removing}
                onClick={() => void removePending(p)}
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
            disabled={uploading || sending || removing}
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
          disabled={sending || uploading || removing || failedFiles.length > 0 || (!body.trim() && pending.length === 0)}
          onClick={() => void sendComment()}
          aria-label="发送"
        >
          <IconSend width={15} height={15} />
          {!isNarrow && (sending || uploading ? "发送中…" : "发送")}
        </button>
      </div>
    </div>
  );
}
