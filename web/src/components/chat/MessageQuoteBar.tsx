/**
 * MessageQuoteBar：引用条（当前正在引用的消息，文档 §4.2）。
 */
import type { ChatMessage } from "../../api/types";

export function MessageQuoteBar({
  quote,
  onCancel,
}: {
  quote: ChatMessage;
  onCancel: () => void;
}) {
  return (
    <div className="quote-bar">
      <div className="quote-preview">
        <span className="quote-label">引用回复</span>
        <span className="quote-text">
          {quote.type === "text" ? quote.content || "…" : `[${quote.type} 消息]`}
        </span>
      </div>
      <button className="quote-cancel" onClick={onCancel} title="取消引用">
        ×
      </button>
    </div>
  );
}
