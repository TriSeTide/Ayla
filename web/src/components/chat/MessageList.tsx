/**
 * MessageList：消息列表 + 时间分组 + 上拉加载（文档 §4.5）。
 *
 * - 上拉加载更早消息（滚动到顶部触发 loadMoreHistory）；
 * - 时间分组：相邻两条消息间隔 > 5 分钟插入时间分隔条；
 * - 自动滚动到底部（新消息到达时）。
 */
import { useEffect, useRef } from "react";
import type { ChatMessage } from "../../api/types";
import { MessageBubble } from "./MessageBubble";

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
  currentUserId,
  hasMore,
  loading,
  onLoadMore,
  onQuote,
}: {
  messages: ChatMessage[];
  currentUserId: string | null;
  hasMore: boolean;
  loading: boolean;
  onLoadMore: () => void;
  onQuote?: (msg: ChatMessage) => void;
}) {
  const scrollRef = useRef<HTMLDivElement>(null);
  const atBottomRef = useRef(true);
  const prevLenRef = useRef(0);

  // 滚动到底部（新消息）
  useEffect(() => {
    const el = scrollRef.current;
    if (el && atBottomRef.current) {
      el.scrollTop = el.scrollHeight;
    }
    prevLenRef.current = messages.length;
  }, [messages.length]);

  // 上拉加载
  const handleScroll = () => {
    const el = scrollRef.current;
    if (!el) return;
    atBottomRef.current = el.scrollTop + el.clientHeight >= el.scrollHeight - 40;
    if (el.scrollTop < 30 && hasMore && !loading) {
      onLoadMore();
    }
  };

  return (
    <div className="message-list" ref={scrollRef} onScroll={handleScroll}>
      {hasMore && (
        <button className="load-more" onClick={onLoadMore} disabled={loading}>
          {loading ? "加载中…" : "加载更早消息"}
        </button>
      )}
      {messages.map((m, i) => {
        const grouped = shouldGroup(messages[i - 1], m);
        return (
          <div key={m.id ?? `${m.conversation_id}-${m.seq}`}>
            {grouped && (
              <div className="time-divider">
                <span>{formatTime(m.created_at)}</span>
              </div>
            )}
            <MessageBubble
              message={m}
              isSelf={m.sender_id === currentUserId}
              onQuote={onQuote}
            />
          </div>
        );
      })}
      {messages.length === 0 && !loading && (
        <div className="empty-chat">还没有消息，说点什么吧</div>
      )}
    </div>
  );
}
