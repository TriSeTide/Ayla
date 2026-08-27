/**
 * GroupChat —— 群内聊天子界面（F3，R-G2）。
 *
 * 复用现有聊天能力（不做侧栏/演示数据/爱莉入口）：MessageList + MessageInput +
 * loadHistory/loadMoreHistory/recallMessage/打字 全复用 hooks/useChat 与 chat/message store。
 * 群 id 即会话 id（GroupPage 传入 groupId）。
 */
import { useCallback, useEffect, useMemo, useState } from "react";
import { useNavigate } from "react-router-dom";
import { ApiError } from "../../api/client";
import { getElysiaProfile } from "../../api/elysia";
import type { ChatMessage } from "../../api/types";
import { MessageInput } from "../../components/chat/MessageInput";
import { MessageList } from "../../components/chat/MessageList";
import { TypingIndicator } from "../../components/chat/TypingIndicator";
import { loadHistory, loadMoreHistory, markReadLatest, recallMessage, retryOptimistic, removeOptimistic, cancelOptimistic } from "../../hooks/useChat";
import { useChatStore } from "../../stores/chat";
import { useHomeStore } from "../../stores/home";
import { useMessageStore } from "../../stores/message";
import { useAuthStore } from "../../stores/auth";
import { chatWS } from "../../ws/chat";

export function GroupChat({ groupId }: { groupId: string }) {
  const navigate = useNavigate();
  const conversations = useChatStore((s) => s.conversations);
  const buckets = useMessageStore((s) => s.buckets);
  const bucket = buckets[groupId];
  const messages = bucket?.messages ?? [];

  const [quote, setQuote] = useState<ChatMessage | null>(null);
  const [peerTyping, setPeerTyping] = useState<Record<string, boolean>>({});
  const [notice, setNotice] = useState<string | null>(null);
  const [historyError, setHistoryError] = useState<string | null>(null);
  const [elysiaUserId, setElysiaUserId] = useState<string | null>(null);

  // 爱莉身份（U1：群聊爱莉消息专属气泡判定，与 PrivateChatPane/MessagesPage 同数据源）
  useEffect(() => {
    let cancelled = false;
    getElysiaProfile()
      .then((p) => {
        if (!cancelled) setElysiaUserId(p.user?.id ?? null);
      })
      .catch(() => {
        // profile 未初始化/加载失败 → elysiaUserId 保持 null（无爱莉气泡判定）
      });
    return () => {
      cancelled = true;
    };
  }, []);

  const activeConv = useMemo(
    () => conversations.find((c) => c.id === groupId) ?? null,
    [conversations, groupId],
  );

  // 打开群会话：拉历史 + 订阅 + 标已读（复用 useChat 数据流）
  useEffect(() => {
    useChatStore.getState().openConversation(groupId);
    useMessageStore.getState().openBucket(groupId);
    chatWS.subscribe([groupId]);
    loadHistory(groupId, undefined, true)
      .then(async () => {
        setHistoryError(null);
        await markReadLatest(groupId);
      })
      .catch(handleHistoryError);
    return () => {
      // 离开群聊时清 activeId，避免残留导致其他会话 message.new 被误判 markRead
      useChatStore.getState().closeConversation();
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [groupId]);

  // typing 帧：只处理当前群、忽略自己（自己输入不显示「对方正在输入」）
  useEffect(() => {
    setPeerTyping({}); // 切换会话清空上一会话的输入状态
    const off = chatWS.onFrame((frame) => {
      if (frame.type !== "typing") return;
      if (frame.data.conversation_id !== groupId) return;
      const me = useAuthStore.getState().currentUser;
      if (me && String(frame.data.user_id) === String(me.id)) return;
      setPeerTyping((prev) => ({ ...prev, [frame.data.user_id]: frame.data.is_typing }));
    });
    return off;
  }, [groupId]);

  const typingActive = Object.values(peerTyping).some(Boolean);

  const handleHistoryError = useCallback((error: unknown) => {
    if (error instanceof ApiError && (error.status === 403 || error.status === 404)) {
      useChatStore.getState().removeConversation(groupId);
      useMessageStore.getState().reset();
      if (useHomeStore.getState().recentGroupId === groupId) {
        useHomeStore.getState().setRecentGroup(null);
      }
      navigate("/group", { replace: true });
      return;
    }
    setHistoryError(error instanceof Error ? error.message : "加载聊天记录失败");
  }, [groupId, navigate]);

  const handleRecall = async (msg: ChatMessage) => {
    if (msg.status === "recalled") return;
    try {
      await recallMessage(groupId, msg.id);
    } catch (e) {
      setNotice(e instanceof Error ? e.message : "撤回失败");
    }
  };

  return (
    <div className="group-chat">
      {historyError && (
        <div className="chat-notice" role="alert">
          <span>{historyError}</span>
          <button type="button" className="btn btn-ghost" onClick={() => {
            setHistoryError(null);
            loadHistory(groupId, undefined, true)
              .catch(handleHistoryError);
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
        conversation={activeConv}
        elysiaUserId={elysiaUserId}
        hasMore={bucket?.hasMore ?? false}
        loading={bucket?.loading ?? false}
        onLoadMore={() =>
          loadMoreHistory(groupId).catch((error) => {
            handleHistoryError(error);
            throw error;
          })
        }
        onQuote={setQuote}
        onRecall={(m) => void handleRecall(m)}
        onRetry={(m) => retryOptimistic(groupId, m)}
        onRemove={(m) => removeOptimistic(groupId, m)}
        onCancel={(m) => cancelOptimistic(groupId, m)}
      />
      <TypingIndicator typing={typingActive} />
      <MessageInput convId={groupId} quote={quote} onQuoteClear={() => setQuote(null)} members={activeConv?.members} />
    </div>
  );
}
