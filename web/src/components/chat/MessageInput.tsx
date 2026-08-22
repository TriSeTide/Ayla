/**
 * MessageInput —— 输入区：回车发送、typing 节流、引用条、失败可见。
 */
import { useEffect, useRef, useState } from "react";
import type { ChatMessage, MessageType } from "../../api/types";
import { useChatDraftsStore } from "../../stores/chatDrafts";
import { sendMessage } from "../../hooks/useChat";
import { uploadMediaFile, validateMediaFile } from "../../api/media";
import { IconImage } from "../icons";
import { useTyping } from "../../hooks/useTyping";
import { useVoiceRecorder, isVoiceRecordingSupported, formatDuration as formatRecDuration, type VoiceRecording } from "../../hooks/useVoiceRecorder";
import { IconClose, IconMic, IconSend } from "../icons";

/** 媒体消息类型（本输入区可发送的媒体：图片/语音/视频） */
type MediaMsgType = Extract<MessageType, "image" | "voice" | "video">;

interface FailedMediaPayload {
  content: string;
  idempotencyKey: string;
  mediaId?: string;
  type?: MediaMsgType;
}

interface FailedVoice {
  blob: Blob;
  mimeType: string;
  duration: number;
}

export function MessageInput({
  convId,
  quote,
  onQuoteClear,
}: {
  convId: string;
  quote: ChatMessage | null;
  onQuoteClear: () => void;
}) {
  const draft = useChatDraftsStore((state) => state.drafts[convId] ?? "");
  const setDraft = useChatDraftsStore((state) => state.setDraft);
  const clearDraft = useChatDraftsStore((state) => state.clearDraft);
  const [text, setText] = useState(draft);
  const [sending, setSending] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [failedPayload, setFailedPayload] = useState<FailedMediaPayload | null>(null);
  const [uploading, setUploading] = useState(false);
  const [failedFile, setFailedFile] = useState<File | null>(null);
  const [failedVoice, setFailedVoice] = useState<FailedVoice | null>(null);
  const idempotencyKeyRef = useRef<string | null>(null);
  const voice = useVoiceRecorder();
  const { onInput } = useTyping(convId || null);

  useEffect(() => {
    setText(draft);
    setError(null);
    setFailedPayload(null);
    idempotencyKeyRef.current = null;
  }, [convId, draft]);

  const newKey = () =>
    typeof crypto !== "undefined" && crypto.randomUUID
      ? crypto.randomUUID()
      : `${Date.now()}-${Math.random()}`;

  const submit = async (retryPayload?: FailedMediaPayload) => {
    const content = retryPayload?.content ?? text.trim();
    // 媒体消息（带 type 重发载荷）允许空文案（气泡只渲染媒体本体）；纯文本仍需非空
    if ((!content && !retryPayload?.type) || sending || uploading || !convId) return;
    setSending(true);
    setError(null);
    const idempotencyKey = retryPayload?.idempotencyKey ?? idempotencyKeyRef.current ?? newKey();
    idempotencyKeyRef.current = idempotencyKey;
    try {
      await sendMessage(convId, content, {
        replyTo: quote ? Number(quote.id) : null,
        idempotencyKey,
        mediaId: retryPayload?.mediaId,
        type: retryPayload?.type,
      });
      setText("");
      clearDraft(convId);
      setFailedPayload(null);
      idempotencyKeyRef.current = null;
      if (quote) onQuoteClear();
    } catch (e) {
      // 保留同一幂等键，用户重试不会创建重复消息。
      setFailedPayload({ content, idempotencyKey, mediaId: retryPayload?.mediaId, type: retryPayload?.type });
      setError(e instanceof Error ? e.message : "发送失败");
    } finally {
      setSending(false);
    }
  };

  /** 发送图片/视频：按 MIME 分流媒体 kind（同一入口，accept=image/*,video/*） */
  const sendMediaFile = async (file: File) => {
    if (sending || uploading || voice.recording || !convId) return;
    const { error, kind } = validateMediaFile(file);
    if (error) {
      setError(error);
      return;
    }
    setUploading(true);
    setError(null);
    setFailedFile(null);
    try {
      const uploaded = await uploadMediaFile(file, kind);
      // 媒体消息不携带占位文案（气泡只渲染媒体本体；「图片/视频」二字由
      // 会话列表/引用预览按 type 兜底显示），content 保持空串。
      await submit({ content: "", type: kind, idempotencyKey: newKey(), mediaId: uploaded.media_id });
    } catch (err) {
      setFailedFile(file);
      setError(err instanceof Error ? err.message : "媒体发送失败");
    } finally {
      setUploading(false);
    }
  };

  const sendVoice = async (rec: VoiceRecording) => {
    if (sending || uploading || !convId) return;
    setUploading(true);
    setError(null);
    setFailedVoice(null);
    try {
      const file = new File([rec.blob], "voice.webm", { type: rec.mimeType || "audio/webm" });
      const uploaded = await uploadMediaFile(file, "voice");
      // 同图片：语音消息 content 空串，「语音」二字由列表预览兜底。
      await submit({ content: "", type: "voice", idempotencyKey: newKey(), mediaId: uploaded.media_id });
    } catch (err) {
      setFailedVoice({ blob: rec.blob, mimeType: rec.mimeType, duration: rec.duration });
      setError(err instanceof Error ? err.message : "语音发送失败");
    } finally {
      setUploading(false);
    }
  };

  // 录音停止 → 直接上传发送；过短（<0.8s）视为无效丢弃
  const stopAndSend = async () => {
    const rec = await voice.stop();
    if (rec && rec.duration >= 0.8) await sendVoice(rec);
  };

  const retryVoice = async () => {
    const fv = failedVoice;
    if (!fv) return;
    setFailedVoice(null);
    setError(null);
    await sendVoice({ blob: fv.blob, mimeType: fv.mimeType, duration: fv.duration });
  };

  const MEDIA_TYPE_LABEL: Record<string, string> = {
    image: "图片",
    voice: "语音",
    file: "文件",
    emoji: "表情",
    video: "视频",
    system: "系统消息",
  };

  const quotePreview = quote
    ? quote.type === "text"
      ? quote.content || "…"
      : `[${MEDIA_TYPE_LABEL[quote.type] ?? "消息"}]`
    : null;

  return (
    <div className="composer">
      {quote && quotePreview != null && (
        <div className="quote-bar">
          <div className="quote-bar-body">
            <span className="quote-bar-label">引用回复</span>
            <span className="quote-bar-text">{quotePreview}</span>
          </div>
          <button
            type="button"
            className="quote-bar-cancel"
            onClick={onQuoteClear}
            aria-label="取消引用"
          >
            <IconClose width={14} height={14} />
          </button>
        </div>
      )}
      {uploading && <div className="composer-uploading" role="status">媒体上传中…</div>}
      {error && (
        <div className="composer-error" role="alert">
          <span>{error}</span>
          {failedPayload && (
            <button
              type="button"
              className="msg-action-btn"
              onClick={() => void submit(failedPayload ?? undefined)}
              disabled={sending}
            >
              重试
            </button>
          )}
        </div>
      )}
      {failedFile && <button type="button" className="msg-action-btn" onClick={() => {
        const file = failedFile;
        setFailedFile(null);
        setError(null);
        void sendMediaFile(file);
      }} disabled={uploading}>重试媒体</button>}
      {failedVoice && <button type="button" className="msg-action-btn" onClick={() => void retryVoice()} disabled={uploading}>重试语音</button>}
      {voice.error && !error && (
        <div className="composer-error" role="alert">
          <span>{voice.error}</span>
          <button type="button" className="msg-action-btn" onClick={voice.clearError}>关闭</button>
        </div>
      )}
      <div className="composer-row">
        {voice.recording ? (
          <>
            <span className="voice-recording-hint" role="status">
              <span className="voice-rec-dot" />
              正在录音 {formatRecDuration(voice.elapsed)}
            </span>
            <button
              type="button"
              className="composer-tool-btn composer-voice-stop"
              onClick={() => void stopAndSend()}
              aria-label="停止并发送语音"
              disabled={uploading}
            >
              <IconSend width={18} height={18} />
            </button>
            <button
              type="button"
              className="composer-tool-btn composer-voice-cancel"
              onClick={() => voice.cancel()}
              aria-label="取消录音"
              disabled={uploading}
            >
              <IconClose width={16} height={16} />
            </button>
          </>
        ) : (
          <>
            <label className="composer-tool-btn" aria-label="发送图片或视频">
              <IconImage width={18} height={18} />
              <input type="file" accept="image/*,video/*" hidden onChange={async (e) => {
                const file = e.target.files?.[0];
                e.target.value = "";
                if (!file || sending || uploading || !convId) return;
                await sendMediaFile(file);
              }} />
            </label>
            {isVoiceRecordingSupported() && (
              <button
                type="button"
                className="composer-tool-btn composer-voice-btn"
                onClick={() => void voice.start()}
                aria-label="发送语音"
                title="录制语音消息"
                disabled={sending || uploading || !convId}
              >
                <IconMic width={18} height={18} />
              </button>
            )}
          </>
        )}
        <textarea
          className="field composer-input"
          value={text}
          onChange={(e) => {
            const value = e.target.value;
             setText(value);
             setDraft(convId, value);
            onInput();
          }}
          onKeyDown={(e) => {
            if (e.key === "Enter" && !e.shiftKey) {
              e.preventDefault();
              void submit();
            }
          }}
          placeholder="输入消息，回车发送（Shift+Enter 换行）"
          rows={2}
        />
        <button
          type="button"
          className="btn btn-primary composer-send"
          onClick={() => void submit()}
          disabled={sending || uploading || !text.trim() || !convId}
        >
          <IconSend width={15} height={15} />
          {sending ? "发送中…" : "发送"}
        </button>
      </div>
    </div>
  );
}
