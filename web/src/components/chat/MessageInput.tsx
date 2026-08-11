/**
 * MessageInput：输入框 + 发送 + typing 声明 + 引用条（文档 §4.2 / §4.7）。
 *
 * - 回车发送（Shift+Enter 换行）；
 * - typing 节流声明；
 * - 引用条（当前引用消息）与取消；
 * - 发送失败提示（409 幂等冲突等按用户可见处理）。
 */
import { useState } from "react";
import type { ChatMessage } from "../../api/types";
import { sendMessage } from "../../hooks/useChat";
import { useTyping } from "../../hooks/useTyping";
import { MessageQuoteBar } from "./MessageQuoteBar";

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
  const { onInput } = useTyping(convId);

  const submit = async () => {
    const content = text.trim();
    if (!content || sending) return;
    setSending(true);
    setError(null);
    try {
      await sendMessage(convId, content, { replyTo: quote ? Number(quote.id) : null });
      setText("");
      if (quote) onQuoteClear();
    } catch (e) {
      const detail = e instanceof Error ? e.message : "发送失败";
      // 409 幂等冲突：用户可见提示，不静默丢弃
      setError(detail);
    } finally {
      setSending(false);
    }
  };

  const handleKeyDown = (e: React.KeyboardEvent<HTMLTextAreaElement>) => {
    if (e.key === "Enter" && !e.shiftKey) {
      e.preventDefault();
      void submit();
    }
  };

  return (
    <div className="message-input">
      {quote && <MessageQuoteBar quote={quote} onCancel={onQuoteClear} />}
      {error && <div className="send-error">{error}</div>}
      <div className="input-row">
        <textarea
          value={text}
          onChange={(e) => {
            setText(e.target.value);
            onInput();
          }}
          onKeyDown={handleKeyDown}
          placeholder="输入消息，回车发送（Shift+Enter 换行）"
          rows={2}
        />
        <button className="send-btn" onClick={() => void submit()} disabled={sending || !text.trim()}>
          {sending ? "发送中…" : "发送"}
        </button>
      </div>
    </div>
  );
}
