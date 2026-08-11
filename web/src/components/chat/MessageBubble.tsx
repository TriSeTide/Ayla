/**
 * MessageBubble：单条消息气泡（文档 §2 components/chat/MessageBubble.tsx）。
 *
 * - 类型分派：text 渲染文本；image/voice/file/emoji 渲染占位（M4-3 未做，只渲染）；
 * - 自己/他人区分（sender_id vs 当前用户）；
 * - 已读状态（自己发的最新消息显示"已读/未读"）；撤回态（显示"已撤回"）；
 * - 引用条（点击消息 → 引用 → 发送）。
 */
import type { ChatMessage, MessageType } from "../../api/types";
import { RECALL_SECONDS } from "../../hooks/useChat";

const TYPE_LABEL: Record<MessageType, string> = {
  text: "文本",
  image: "图片",
  voice: "语音",
  file: "文件",
  emoji: "表情",
  system: "系统",
};

function timeAgo(iso: string): string {
  const d = new Date(iso);
  if (Number.isNaN(d.getTime())) return "";
  const now = Date.now();
  const diff = (now - d.getTime()) / 1000;
  if (diff < 60) return "刚刚";
  if (diff < 3600) return `${Math.floor(diff / 60)} 分钟前`;
  const h = d.getHours().toString().padStart(2, "0");
  const m = d.getMinutes().toString().padStart(2, "0");
  return `${h}:${m}`;
}

export function MessageBubble({
  message,
  isSelf,
  onQuote,
}: {
  message: ChatMessage;
  isSelf: boolean;
  onQuote?: (msg: ChatMessage) => void;
}) {
  const recalled = message.status === "recalled";

  return (
    <div className={`message-row ${isSelf ? "self" : "peer"}`}>
      <div className={`bubble ${recalled ? "recalled" : ""} type-${message.type}`}>
        {message.type === "text" ? (
          <p className="bubble-text">{message.content || " "}</p>
        ) : (
          <div className="media-placeholder">
            <span className="media-icon">
              {message.type === "image" && "🖼"}
              {message.type === "voice" && "🎙"}
              {message.type === "file" && "📎"}
              {message.type === "emoji" && "😀"}
              {message.type === "system" && "ℹ"}
            </span>
            <span className="media-label">{TYPE_LABEL[message.type]}消息（占位）</span>
            {message.content && <span className="media-desc">{message.content}</span>}
          </div>
        )}
        <div className="bubble-meta">
          <span className="bubble-time">{timeAgo(message.created_at)}</span>
          {isSelf && !recalled && (
            <span className={`read-mark ${message.status === "read" ? "read" : ""}`}>
              {message.status === "read" ? "已读" : "未读"}
            </span>
          )}
        </div>
      </div>
      {!recalled && message.type !== "system" && onQuote && (
        <button className="quote-btn" onClick={() => onQuote(message)} title="引用回复">
          引用
        </button>
      )}
      {recalled && <span className="recalled-label">已撤回</span>}
    </div>
  );
}

/** 撤回窗口判断（仅自己、未撤回、created_at 在 120s 内） */
export function canRecall(
  message: ChatMessage,
  currentUserId: string | null | undefined,
): boolean {
  if (message.sender_id !== currentUserId) return false;
  if (message.status === "recalled") return false;
  const created = new Date(message.created_at).getTime();
  if (Number.isNaN(created)) return false;
  return (Date.now() - created) / 1000 <= RECALL_SECONDS;
}
