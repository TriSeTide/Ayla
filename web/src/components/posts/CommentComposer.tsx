import { useState } from "react";
import { uploadMediaFile } from "../../api/media";
import type { PostComment } from "../../api/types";
import { IconImage } from "../icons";

export function CommentComposer({
  onSend,
  replyTarget,
  onReplyClear,
  className = "",
  inputEntered = true,
}: {
  onSend: (body: string, replyTo: number | null, mediaId?: string | null) => Promise<void>;
  replyTarget: PostComment | null;
  onReplyClear: () => void;
  className?: string;
  /** 窄屏详情页复用进直播间的底部输入框滑入状态。 */
  inputEntered?: boolean;
}) {
  const [body, setBody] = useState("");
  const [sending, setSending] = useState(false);
  const [uploading, setUploading] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [failedMedia, setFailedMedia] = useState<File | null>(null);

  const sendComment = async (mediaId?: string | null) => {
    const trimmed = body.trim();
    if ((!trimmed && !mediaId) || sending) return;
    setSending(true);
    setError(null);
    try {
      await onSend(trimmed || (mediaId ? "图片" : ""), replyTarget ? Number(replyTarget.id) : null, mediaId ?? null);
      setBody("");
      setFailedMedia(null);
      if (replyTarget) onReplyClear();
    } catch (e) {
      setError(e instanceof Error ? e.message : "发送失败");
    } finally {
      setSending(false);
    }
  };

  const sendImageFile = async (file: File) => {
    if (sending || uploading) return;
    setUploading(true);
    setError(null);
    setFailedMedia(null);
    try {
      const uploaded = await uploadMediaFile(file, "image");
      await sendComment(uploaded.media_id);
    } catch (err) {
      setFailedMedia(file);
      setError(err instanceof Error ? err.message : "图片发送失败");
    } finally {
      setUploading(false);
    }
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
      {failedMedia && (
        <button
          type="button"
          className="msg-action-btn"
          disabled={uploading}
          onClick={() => {
            const file = failedMedia;
            setFailedMedia(null);
            setError(null);
            void sendImageFile(file);
          }}
        >
          重试图片
        </button>
      )}
      <div className="composer-row">
        <label className="composer-tool-btn" aria-label="评论发送图片">
          <IconImage width={18} height={18} />
          <input type="file" accept="image/*" hidden onChange={async (event) => {
            const file = event.target.files?.[0];
            event.target.value = "";
            if (!file || sending || uploading) return;
            await sendImageFile(file);
          }} />
        </label>
        <textarea
          className="field composer-input"
          placeholder="写评论…"
          rows={1}
          value={body}
          onChange={(event) => setBody(event.target.value)}
        />
        <button
          type="button"
          className="btn btn-primary"
          disabled={sending || uploading || (!body.trim() && !failedMedia)}
          onClick={() => void sendComment()}
        >
          {sending || uploading ? "发送中…" : "发送"}
        </button>
      </div>
    </div>
  );
}
