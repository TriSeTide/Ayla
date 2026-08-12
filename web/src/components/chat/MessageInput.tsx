/**
 * MessageInput —— 输入区：回车发送、typing 节流、引用条、失败可见。
 */
import { useState } from "react";
import type { ChatMessage } from "../../api/types";
import { sendMessage } from "../../hooks/useChat";
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
  const [text, setText] = useState("");
  const [sending, setSending] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const { onInput } = useTyping(convId || null);

  const submit = async () => {
    const content = text.trim();
    if (!content || sending || !convId) return;
    setSending(true);
    setError(null);
    try {
      await sendMessage(convId, content, { replyTo: quote ? Number(quote.id) : null });
      setText("");
      if (quote) onQuoteClear();
    } catch (e) {
      // 409 幂等冲突等：用户可见提示，不静默丢弃
      setError(e instanceof Error ? e.message : "发送失败");
    } finally {
      setSending(false);
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
      {error && <div className="composer-error">{error}</div>}
      <div className="composer-row">
        <textarea
          className="field composer-input"
          value={text}
          onChange={(e) => {
            setText(e.target.value);
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
          disabled={sending || !text.trim() || !convId}
        >
          <IconSend width={15} height={15} />
          {sending ? "发送中…" : "发送"}
        </button>
      </div>
    </div>
  );
}
