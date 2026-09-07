/**
 * DanmakuInput —— 文本/图片弹幕输入（M5-4）。
 * 图片先走受控媒体上传，再发送 media_id；发送失败保留已上传媒体及原文字快照。
 * 草稿和重试属于当前账号/频道，旧成功只清除未再编辑的发送快照。
 */
import { useLayoutEffect, useRef, useState } from "react";
import { uploadMediaFile } from "../../api/media";
import { useAuthStore } from "../../stores/auth";
import { IconImage } from "../icons";
import { DANMAKU_MAX_LENGTH } from "../../hooks/useDanmaku";

interface DanmakuInputProps {
  channelId: number;
  sending: boolean;
  error: string | null;
  onSend: (content: string, mediaId?: string | null) => Promise<boolean>;
}

interface DraftSnapshot {
  content: string;
  revision: number;
}

interface ImageAttempt extends DraftSnapshot {
  file: File;
  mediaId?: string;
}

export function DanmakuInput(props: DanmakuInputProps) {
  const accountId = useAuthStore((s) => s.currentUser?.id ?? "");
  // A new owner gets a fresh draft. The old instance cannot submit a late upload
  // or alter the new owner's draft/retry state, even when returning to the same room.
  return <ScopedDanmakuInput key={`${accountId}:${props.channelId}`} {...props} />;
}

function ScopedDanmakuInput({
  sending,
  error,
  onSend,
}: DanmakuInputProps) {
  const [text, setText] = useState("");
  const [working, setWorking] = useState<"uploading" | "sending" | null>(null);
  const [failedImage, setFailedImage] = useState<ImageAttempt | null>(null);
  const [localError, setLocalError] = useState<string | null>(null);
  const revision = useRef(0);
  const busy = useRef(false);
  const mounted = useRef(true);
  const inputRef = useRef<HTMLInputElement | null>(null);
  useLayoutEffect(() => {
    mounted.current = true;
    return () => { mounted.current = false; };
  }, []);

  const sendSnapshot = async (snapshot: DraftSnapshot, mediaId?: string) => {
    if (!mounted.current) return false;
    const ok = await onSend(snapshot.content, mediaId);
    if (!mounted.current) return false;
    if (ok) {
      if (revision.current === snapshot.revision) {
        revision.current += 1;
        setText("");
      }
      // 发送成功保持输入焦点（连续发弹幕不打断；点发送按钮时焦点在按钮上，需还回输入框）
      inputRef.current?.focus();
    }
    return ok;
  };

  const submit = async () => {
    if (sending || busy.current || !mounted.current) return;
    busy.current = true;
    setWorking("sending");
    setLocalError(null);
    try {
      await sendSnapshot({ content: text, revision: revision.current });
    } catch (e) {
      if (mounted.current) setLocalError(e instanceof Error ? e.message : "发送失败");
    } finally {
      if (mounted.current) { busy.current = false; setWorking(null); }
    }
  };

  const sendImage = async (original: ImageAttempt) => {
    if (sending || busy.current || !mounted.current) return;
    busy.current = true;
    let attempt = original;
    setFailedImage(null);
    setLocalError(null);
    setWorking(attempt.mediaId ? "sending" : "uploading");
    try {
      if (!attempt.mediaId) {
        const uploaded = await uploadMediaFile(attempt.file, "image");
        if (!mounted.current) return;
        attempt = { ...attempt, mediaId: uploaded.media_id };
      }
      setWorking("sending");
      const ok = await sendSnapshot(attempt, attempt.mediaId);
      if (mounted.current && !ok) setFailedImage(attempt);
    } catch {
      if (mounted.current) setFailedImage(attempt);
    } finally {
      if (mounted.current) { busy.current = false; setWorking(null); }
    }
  };
  const disabled = sending || working !== null;
  const visibleError = localError ?? error;

  return (
    <div className="danmaku-input-area">
      {(working === "uploading" || failedImage) && (
        <div className="danmaku-input-status" role={working === "uploading" ? "status" : "alert"}>
          {working === "uploading" ? "图片上传中…" : failedImage?.mediaId ? "图片发送失败" : "图片上传失败"}
          {failedImage && (
            <button
              type="button"
              className="msg-action-btn"
              disabled={disabled}
              onClick={() => void sendImage(failedImage)}
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
            disabled={disabled}
            onChange={async (e) => {
              const file = e.target.files?.[0];
              e.target.value = "";
              if (!file) return;
              await sendImage({ file, content: text, revision: revision.current });
            }}
          />
        </label>
        <input
          ref={inputRef}
          className="danmaku-input"
          placeholder="发条弹幕吧"
          value={text}
          maxLength={DANMAKU_MAX_LENGTH * 2}
          // 发送中不禁用输入框：disabled 会强制失焦，破坏连续发弹幕；
          // 同tick重复Enter和上传期间Enter由同步busy锁共同约束。
          onChange={(e) => { revision.current += 1; setText(e.target.value); }}
          onKeyDown={(e) => {
            if (e.key === "Enter" && !e.nativeEvent.isComposing) void submit();
          }}
        />
        <button
          type="button"
          className="btn btn-glow danmaku-send-btn"
          disabled={disabled || !text.trim()}
          onClick={() => void submit()}
        >
          {sending || working === "sending" ? "发送中…" : "发送"}
        </button>
      </div>
      <div className="danmaku-input-meta">
        {visibleError ? (
          <span className="live-form-error">{visibleError}</span>
        ) : (
          <span className="danmaku-counter">
            {text.trim().length}/{DANMAKU_MAX_LENGTH}
          </span>
        )}
      </div>
    </div>
  );
}
