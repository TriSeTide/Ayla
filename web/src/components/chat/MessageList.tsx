/**
 * MessageList —— 消息滚动区：时间分组、上拉加载、新消息自动滚底。
 */
import { useEffect, useMemo, useRef } from "react";
import type { ChatMessage, ConversationSummary } from "../../api/types";
import { useAuthStore } from "../../stores/auth";
import { goUserProfile } from "../../utils/navigation";
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
  const lastScrollTopRef = useRef(0);
  const isGroup = conversation?.type === "group";

  // 发送者 id → 展示名 + 头像（群聊发送者名 + 头像显示，design.md §4 Chat Bubbles）
  const memberNames = useMemo(() => {
    const map = new Map<string, string>();
    for (const m of conversation?.members ?? []) {
      map.set(m.user.id, m.user.nickname || m.user.username);
    }
    return map;
  }, [conversation]);

  const memberAvatars = useMemo(() => {
    const map = new Map<string, { avatar: string | null; label: string }>();
    for (const m of conversation?.members ?? []) {
      map.set(m.user.id, {
        avatar: m.user.avatar ?? null,
        label: m.user.nickname || m.user.username,
      });
    }
    return map;
  }, [conversation]);

  // 消息 id → 引用预览文本
  const MEDIA_TYPE_LABEL: Record<string, string> = {
    image: "图片",
    voice: "语音",
    file: "文件",
    emoji: "表情",
    video: "视频",
  };
  const quotePreview = useMemo(() => {
    const map = new Map<string, string>();
    for (const m of messages) {
      map.set(
        m.id,
        m.type === "text" ? m.content || "…" : `[${MEDIA_TYPE_LABEL[m.type] ?? "消息"}]`,
      );
    }
    return map;
  }, [messages]);

  // 切换会话（宽屏侧栏点其他群/会话时组件复用不重挂载，scrollRef/atBottomRef 会
  // 保留上一个会话的滚动位置）→ 重置滚动位置贴底，避免沿用上个会话的相对高度。
  useEffect(() => {
    atBottomRef.current = true;
    lastScrollTopRef.current = 0;
    const el = scrollRef.current;
    if (el) {
      el.scrollTop = el.scrollHeight;
    }
  }, [conversation?.id]);

  useEffect(() => {
    const el = scrollRef.current;
    if (el && atBottomRef.current) {
      el.scrollTop = el.scrollHeight;
    }
  }, [messages.length]);

  // 图片等媒体异步加载会撑高内容，导致滚动条偏离底部；双保险跟随滚底：
  // - ResizeObserver 监听内容高度变化（图片/语音/文件加载后的布局变化）；
  // - img load 捕获监听（load 不冒泡）+ rAF，图片解码完成、布局稳定后滚底。
  useEffect(() => {
    const el = scrollRef.current;
    if (!el) return;

    const stickToBottom = () => {
      if (atBottomRef.current) {
        el.scrollTop = el.scrollHeight;
      }
    };

    let observer: ResizeObserver | null = null;
    if (typeof ResizeObserver !== "undefined") {
      const column = el.querySelector(".message-column");
      if (column) {
        observer = new ResizeObserver(stickToBottom);
        observer.observe(column);
      }
    }

    const onLoad = (e: Event) => {
      if (e.target instanceof HTMLImageElement) {
        requestAnimationFrame(stickToBottom);
      }
    };
    el.addEventListener("load", onLoad, true);

    return () => {
      observer?.disconnect();
      el.removeEventListener("load", onLoad, true);
    };
  }, []);

  const handleScroll = () => {
    const el = scrollRef.current;
    if (!el) return;
    const scrollTop = el.scrollTop;
    // 图片等媒体加载只改变 scrollHeight、不改变 scrollTop，会触发一次被动 scroll；
    // 此时若按"是否到底"更新 atBottomRef 会被误判为离开底部。只有 scrollTop
    // 真正变化（用户主动滚动）才更新 atBottomRef，保持"贴底跟随"语义。
    if (scrollTop !== lastScrollTopRef.current) {
      atBottomRef.current = scrollTop + el.clientHeight >= el.scrollHeight - 40;
    }
    lastScrollTopRef.current = scrollTop;
    if (scrollTop < 30 && hasMore && !loading) {
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
                senderAvatar={memberAvatars.get(m.sender_id)?.avatar ?? null}
                senderAvatarLabel={memberAvatars.get(m.sender_id)?.label ?? null}
                onSenderClick={() => goUserProfile(currentUserId, m.sender_id)}
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
