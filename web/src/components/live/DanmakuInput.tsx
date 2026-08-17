/**
 * DanmakuInput —— 文本/图片弹幕输入（M5-4）。
 * 图片先走受控媒体上传，再发送 media_id；失败保留文件可重试。
 */
import { useState } from "react";
import { uploadMediaFile } from "../../api/media";
import { IconImage } from "../icons";
import { DANMAKU_MAX_LENGTH } from "../../hooks/useDanmaku";

export function DanmakuInput({
  sending,
  error,
  onSend,
}: {
  sending: boolean;
  error: string | null;
  onSend: (content: string, mediaId?: string | null) => Promise<boolean>;
}) {
  const [text, setText] = useState("");
  const [uploading, setUploading] = useState(false);
  const [failedFile, setFailedFile] = useState<File | null>(null);

  const submit = async (mediaId?: string | null) => {
    const ok = await onSend(text, mediaId);
    if (ok) {
      setText("");
      setFailedFile(null);
    }
  };

  const sendImageFile = async (file: File) => {
    if (sending || uploading) return;
    setUploading(true);
    setFailedFile(null);
    try {
      const uploaded = await uploadMediaFile(file, "image");
      await submit(uploaded.media_id);
    } catch {
      setFailedFile(file);
    } finally {
      setUploading(false);
    }
  };

  return (
    <div className="danmaku-input-area">
      {(uploading || failedFile) && (
        <div className="danmaku-input-status" role={uploading ? "status" : "alert"}>
          {uploading ? "图片上传中…" : "图片发送失败"}
          {failedFile && (
            <button
              type="button"
              className="msg-action-btn"
              disabled={uploading}
              onClick={() => {
                const file = failedFile;
                setFailedFile(null);
                void sendImageFile(file);
              }}
            >
              重试图片
            </button>
          )}
        </div>
      )}
      <div className="danmaku-input-row">
        <label className="danmaku-image-btn" aria-label="发送弹幕图片">
          <IconImage width={17} height={17} />
          <input
            type="file"
            accept="image/*"
            hidden
            onChange={async (e) => {
              const file = e.target.files?.[0];
              e.target.value = "";
              if (!file || sending || uploading) return;
              await sendImageFile(file);
            }}
          />
        </label>
        <input
          className="danmaku-input"
          placeholder="发条弹幕吧"
          value={text}
          maxLength={DANMAKU_MAX_LENGTH * 2}
          disabled={sending || uploading}
          onChange={(e) => setText(e.target.value)}
          onKeyDown={(e) => {
            if (e.key === "Enter" && !e.nativeEvent.isComposing) void submit();
          }}
        />
        <button
          type="button"
          className="btn btn-glow"
          disabled={sending || uploading || !text.trim()}
          onClick={() => void submit()}
        >
          {sending ? "发送中…" : "发送"}
        </button>
      </div>
      <div className="danmaku-input-meta">
        {error ? (
          <span className="live-form-error">{error}</span>
        ) : (
          <span className="danmaku-counter">
            {text.trim().length}/{DANMAKU_MAX_LENGTH}
          </span>
        )}
      </div>
    </div>
  );
}
