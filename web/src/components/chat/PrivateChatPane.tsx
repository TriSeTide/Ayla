/**
 * PrivateChatPane —— 私聊聊天内容面板（宽屏消息两列 / 私聊窗口共用）。
 *
 * 含私聊头部（对端头像/昵称/在线状态 + 可选返回）+ 消息列表 + typing 指示 +
 * 输入框。复用 useChat 数据流（openConversation/loadHistory/recallMessage 等）。
 * conversationId 变化时切换会话（open bucket / 订阅 / 标已读）。
 */
import { useEffect, useMemo, useState } from "react";
import type { ChatMessage } from "../../api/types";
import { Avatar } from "../Avatar";
import { MessageInput } from "./MessageInput";
import { MessageList } from "./MessageList";
import { TypingIndicator } from "./TypingIndicator";
import { IconBack } from "../icons";
import { loadHistory, loadMoreHistory, markReadLatest, recallMessage } from "../../hooks/useChat";
import { useChatStore } from "../../stores/chat";
import { useMessageStore } from "../../stores/message";
import { chatWS } from "../../ws/chat";

export function PrivateChatPane({
  conversationId,
  onBack,
  backLabel = "返回消息中心",
}: {
  conversationId: string;
  /** 可选返回按钮（窄屏私聊窗口 → /messages；宽屏两列不渲染返回） */
  onBack?: () => void;
  backLabel?: string;
}) {
  const conversations = useChatStore((s) => s.conversations);
  const buckets = useMessageStore((s) => s.buckets);
  const bucket = buckets[conversationId];
  const messages = bucket?.messages ?? [];

  const [quote, setQuote] = useState<ChatMessage | null>(null);
  const [peerTyping, setPeerTyping] = useState<Record<string, boolean>>({});
  const [notice, setNotice] = useState<string | null>(null);
  const [historyError, setHistoryError] = useState<string | null>(null);

  const conv = useMemo(
    () => conversations.find((c) => c.id === conversationId) ?? null,
    [conversations, conversationId],
  );

  // 打开私聊会话：拉历史 + 订阅 + 标已读
  useEffect(() => {
    useChatStore.getState().openConversation(conversationId);
    useMessageStore.getState().openBucket(conversationId);
    chatWS.subscribe([conversationId]);
    loadHistory(conversationId, undefined, true)
      .then(() => setHistoryError(null))
      .catch((e) => setHistoryError(e instanceof Error ? e.message : "加载聊天记录失败"));
    markReadLatest(conversationId);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [conversationId]);

  // typing 帧
  useEffect(() => {
    const off = chatWS.onFrame((frame) => {
      if (frame.type === "typing") {
        setPeerTyping((prev) => ({ ...prev, [frame.data.user_id]: frame.data.is_typing }));
      }
    });
    return off;
  }, []);

  const typingActive = Object.values(peerTyping).some(Boolean);

  const handleRecall = async (msg: ChatMessage) => {
    if (msg.status === "recalled") return;
    try {
      await recallMessage(conversationId, msg.id);
    } catch (e) {
      setNotice(e instanceof Error ? e.message : "撤回失败");
    }
  };

  const peer = conv?.peer ?? null;
  const title = peer?.nickname || peer?.username || "私聊";

  return (
    <div className="private-chat">
      <header className="private-chat-head">
        {onBack && (
          <button type="button" className="icon-btn-40" onClick={onBack} aria-label={backLabel}>
            <IconBack width={20} height={20} />
          </button>
        )}
        <Avatar
          label={title}
          size={36}
          online={peer?.online ?? false}
          imageUrl={peer?.avatar || null}
        />
        <div className="private-chat-title">
          <span className="private-chat-name">{title}</span>
          <span className="private-chat-status">{peer?.online ? "在线" : "离线"}</span>
        </div>
      </header>

      {historyError && (
        <div className="chat-notice" role="alert">
          <span>{historyError}</span>
          <button type="button" className="btn btn-ghost" onClick={() => {
            setHistoryError(null);
            loadHistory(conversationId, undefined, true)
              .catch((e) => setHistoryError(e instanceof Error ? e.message : "加载聊天记录失败"));
          }}>重试</button>
        </div>
      )}
      {notice && (
        <div className="chat-notice" role="alert" onClick={() => setNotice(null)}>
          {notice}（点击关闭）
        </div>
      )}

      <MessageList
        messages={messages}
        conversation={conv}
        elysiaUserId={null}
        hasMore={bucket?.hasMore ?? false}
        loading={bucket?.loading ?? false}
        onLoadMore={() => {
          loadMoreHistory(conversationId).catch((e) => setHistoryError(e instanceof Error ? e.message : "加载更早消息失败"));
        }}
        onQuote={setQuote}
        onRecall={(m) => void handleRecall(m)}
      />
      <TypingIndicator typing={typingActive} />
      <MessageInput convId={conversationId} quote={quote} onQuoteClear={() => setQuote(null)} />
    </div>
  );
}
