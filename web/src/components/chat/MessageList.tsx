/**
 * MessageList —— 消息滚动区：时间分组、上拉加载、新消息自动滚底。
 */
import { useEffect, useMemo, useRef } from "react";
import type { ChatMessage, ConversationSummary } from "../../api/types";
import { useAuthStore } from "../../stores/auth";
import { canRecall, MessageBubble } from "./MessageBubble";

const GROUP_GAP_MS = 5 * 60 * 1000;

function formatTime(iso: string): string {
  const d = new Date(iso);
  if (Number.isNaN(d.getTime())) return "";
  const pad = (n: number) => n.toString().padStart(2, "0");
  return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())} ${pad(d.getHours())}:${pad(d.getMinutes())}`;
}

function shouldGroup(prev: ChatMessage | undefined, curr: ChatMessage): boolean {
  if (!prev) return true;
  const a = new Date(prev.created_at).getTime();
  const b = new Date(curr.created_at).getTime();
  if (Number.isNaN(a) || Number.isNaN(b)) return false;
  return b - a > GROUP_GAP_MS;
}

export function MessageList({
  messages,
  conversation,
  elysiaUserId,
  hasMore,
  loading,
  onLoadMore,
  onQuote,
  onRecall,
}: {
  messages: ChatMessage[];
  conversation: ConversationSummary | null;
  /** 爱莉 profile 的 user.id：匹配 sender_id 即爱莉专属气泡 */
  elysiaUserId?: string | null;
  hasMore: boolean;
  loading: boolean;
  onLoadMore: () => void;
  onQuote?: (msg: ChatMessage) => void;
  onRecall?: (msg: ChatMessage) => void;
}) {
  const currentUserId = useAuthStore((s) => s.currentUser?.id ?? null);
  const scrollRef = useRef<HTMLDivElement>(null);
  const atBottomRef = useRef(true);
  const isGroup = conversation?.type === "group";

  // 发送者 id → 展示名（群聊发送者名 + 爱莉判定辅助）
  const memberNames = useMemo(() => {
    const map = new Map<string, string>();
    for (const m of conversation?.members ?? []) {
      map.set(m.user.id, m.user.nickname || m.user.username);
    }
    return map;
  }, [conversation]);

  // 消息 id → 引用预览文本
  const quotePreview = useMemo(() => {
    const map = new Map<string, string>();
    for (const m of messages) {
      map.set(
        m.id,
        m.type === "text" ? m.content || "…" : `[${m.type === "image" ? "图片" : m.type === "voice" ? "语音" : m.type === "file" ? "文件" : m.type === "emoji" ? "表情" : "消息"}]`,
      );
    }
    return map;
  }, [messages]);

  useEffect(() => {
    const el = scrollRef.current;
    if (el && atBottomRef.current) {
      el.scrollTop = el.scrollHeight;
    }
  }, [messages.length]);

  const handleScroll = () => {
    const el = scrollRef.current;
    if (!el) return;
    atBottomRef.current = el.scrollTop + el.clientHeight >= el.scrollHeight - 40;
    if (el.scrollTop < 30 && hasMore && !loading) {
      onLoadMore();
    }
  };

  return (
    <div className="message-scroll" ref={scrollRef} onScroll={handleScroll}>
      <div className="message-column">
        {hasMore && (
          <button
            type="button"
            className="load-more-btn"
            onClick={onLoadMore}
            disabled={loading}
          >
            {loading ? "加载中…" : "加载更早消息"}
          </button>
        )}
        {messages.map((m, i) => {
          const grouped = shouldGroup(messages[i - 1], m);
          const isSelf = m.sender_id === currentUserId;
          return (
            <div key={m.id ?? `${m.conversation_id}-${m.seq}`}>
              {grouped && (
                <div className="time-divider">
                  <span>{formatTime(m.created_at)}</span>
                </div>
              )}
              <MessageBubble
                message={m}
                isSelf={isSelf}
                isElysia={elysiaUserId != null && m.sender_id === elysiaUserId}
                senderName={isGroup && !isSelf ? (memberNames.get(m.sender_id) ?? null) : null}
                quoteText={m.reply_to ? (quotePreview.get(m.reply_to) ?? "引用的消息") : null}
                onQuote={onQuote}
                onRecall={onRecall && canRecall(m, currentUserId) ? onRecall : undefined}
              />
            </div>
          );
        })}
        {messages.length === 0 && !loading && (
          <div className="empty-chat">还没有消息，说点什么吧</div>
        )}
      </div>
    </div>
  );
}
