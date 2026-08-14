/**
 * PrivateChatPage —— 私聊聊天界面（路由 /chat/:conversationId，替代原 ChatPage 的私聊窗口）。
 *
 * 只处理 private 会话：头部（对端头像/昵称/在线状态 + 返回消息中心）+ 消息列表 + 输入框 +
 * typing 指示。复用 useChat 数据流（loadHistory/sendMessage/recallMessage 等）与 chat/message store。
 * 群聊会话由 ChatConversationRoute 重定向到 /group/:id（GroupPage），本页不承载群聊。
 */
import { useEffect, useMemo, useState } from "react";
import { useNavigate, useParams } from "react-router-dom";
import type { ChatMessage } from "../api/types";
import { Avatar } from "../components/Avatar";
import { MessageInput } from "../components/chat/MessageInput";
import { MessageList } from "../components/chat/MessageList";
import { TypingIndicator } from "../components/chat/TypingIndicator";
import { IconBack } from "../components/icons";
import { loadHistory, loadMoreHistory, markReadLatest, recallMessage } from "../hooks/useChat";
import { useChatStore } from "../stores/chat";
import { useMessageStore } from "../stores/message";
import { chatWS } from "../ws/chat";

export function PrivateChatPage() {
  const { conversationId } = useParams<{ conversationId: string }>();
  const navigate = useNavigate();
  const conversations = useChatStore((s) => s.conversations);
  const buckets = useMessageStore((s) => s.buckets);

  const bucket = conversationId ? buckets[conversationId] : undefined;
  const messages = bucket?.messages ?? [];

  const [quote, setQuote] = useState<ChatMessage | null>(null);
  const [peerTyping, setPeerTyping] = useState<Record<string, boolean>>({});
  const [notice, setNotice] = useState<string | null>(null);

  const conv = useMemo(
    () => conversations.find((c) => c.id === conversationId) ?? null,
    [conversations, conversationId],
  );

  // 打开私聊会话：拉历史 + 订阅 + 标已读
  useEffect(() => {
    if (!conversationId) return;
    useChatStore.getState().openConversation(conversationId);
    useMessageStore.getState().openBucket(conversationId);
    chatWS.subscribe([conversationId]);
    loadHistory(conversationId, undefined, true).catch(() => {});
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
      await recallMessage(conversationId!, msg.id);
    } catch (e) {
      setNotice(e instanceof Error ? e.message : "撤回失败");
    }
  };

  const peer = conv?.peer ?? null;
  const title = peer?.nickname || peer?.username || "私聊";

  return (
    <div className="private-chat">
      <header className="private-chat-head">
        <button type="button" className="icon-btn-40" onClick={() => navigate("/messages")} aria-label="返回消息中心">
          <IconBack width={20} height={20} />
        </button>
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
          if (conversationId) loadMoreHistory(conversationId).catch(() => {});
        }}
        onQuote={setQuote}
        onRecall={(m) => void handleRecall(m)}
      />
      <TypingIndicator typing={typingActive} />
      <MessageInput convId={conversationId ?? ""} quote={quote} onQuoteClear={() => setQuote(null)} />
    </div>
  );
}
