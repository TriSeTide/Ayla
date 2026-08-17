/**
 * MessageInput —— 输入区：回车发送、typing 节流、引用条、失败可见。
 */
import { useEffect, useRef, useState } from "react";
import type { ChatMessage } from "../../api/types";
import { useChatDraftsStore } from "../../stores/chatDrafts";
import { sendMessage } from "../../hooks/useChat";
import { uploadMediaFile } from "../../api/media";
import { IconImage } from "../icons";
import { useTyping } from "../../hooks/useTyping";
import { IconClose, IconSend } from "../icons";

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
  const [failedPayload, setFailedPayload] = useState<{ content: string; idempotencyKey: string; mediaId?: string; type?: "text" | "image" } | null>(null);
  const [uploading, setUploading] = useState(false);
  const [failedFile, setFailedFile] = useState<File | null>(null);
  const idempotencyKeyRef = useRef<string | null>(null);
  const { onInput } = useTyping(convId || null);

  useEffect(() => {
    setText(draft);
    setError(null);
    setFailedPayload(null);
    idempotencyKeyRef.current = null;
  }, [convId, draft]);

  const submit = async (retryPayload?: { content: string; idempotencyKey: string; mediaId?: string; type?: "text" | "image" }) => {
    const content = retryPayload?.content ?? text.trim();
    if (!content || sending || !convId) return;
    setSending(true);
    setError(null);
    const idempotencyKey = retryPayload?.idempotencyKey ?? idempotencyKeyRef.current ?? (typeof crypto !== "undefined" && crypto.randomUUID ? crypto.randomUUID() : `${Date.now()}-${Math.random()}`);
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

  const sendImageFile = async (file: File) => {
    if (sending || uploading || !convId) return;
    setUploading(true);
    setError(null);
    setFailedFile(null);
    try {
      const uploaded = await uploadMediaFile(file, "image");
      await submit({ content: "图片", type: "image", idempotencyKey: typeof crypto !== "undefined" && crypto.randomUUID ? crypto.randomUUID() : `${Date.now()}-${Math.random()}`, mediaId: uploaded.media_id });
    } catch (err) {
      setFailedFile(file);
      setError(err instanceof Error ? err.message : "图片发送失败");
    } finally {
      setUploading(false);
    }
  };

  const quotePreview = quote
    ? quote.type === "text"
      ? quote.content || "…"
      : `[${quote.type} 消息]`
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
      {uploading && <div className="composer-uploading" role="status">图片上传中…</div>}
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
        void sendImageFile(file);
      }} disabled={uploading}>重试图片</button>}
      <div className="composer-row">
        <label className="composer-tool-btn" aria-label="发送图片">
          <IconImage width={18} height={18} />
          <input type="file" accept="image/*" hidden onChange={async (e) => {
            const file = e.target.files?.[0];
            e.target.value = "";
            if (!file || sending || uploading || !convId) return;
            await sendImageFile(file);
            return;

          }} />
        </label>
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
