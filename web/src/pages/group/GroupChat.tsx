/**
 * GroupChat —— 群内聊天子界面（F3，R-G2）。
 *
 * 复用现有聊天能力（不做侧栏/演示数据/爱莉入口）：MessageList + MessageInput +
 * loadHistory/loadMoreHistory/recallMessage 全复用 hooks/useChat 与 chat/message store。
 * 群 id 即会话 id（GroupPage 传入 groupId）。
 * 群聊已删除「对方正在输入」功能：不订阅 typing 帧、不显示指示、不声明 typing（产品要求）。
 */
import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { useNavigate } from "react-router-dom";
import { ApiError } from "../../api/client";
import { getElysiaProfile } from "../../api/elysia";
import * as chatApi from "../../api/chat";
import type { ChatMessage } from "../../api/types";
import { MessageInput, type MessageInputHandle } from "../../components/chat/MessageInput";
import { MessageList } from "../../components/chat/MessageList";
import { loadHistory, loadMoreHistory, loadHistoryUntilSeq, markConversationReadThrough, markMessageReadExact, recallMessage, retryOptimistic, removeOptimistic, cancelOptimistic } from "../../hooks/useChat";
import { useChatStore } from "../../stores/chat";
import { useHomeStore } from "../../stores/home";
import { useMessageStore } from "../../stores/message";
import { chatWS } from "../../ws/chat";

export function GroupChat({ groupId }: { groupId: string }) {
  const navigate = useNavigate();
  const conversations = useChatStore((s) => s.conversations);
  const buckets = useMessageStore((s) => s.buckets);
  const bucket = buckets[groupId];
  const messages = bucket?.messages ?? [];

  const [quote, setQuote] = useState<ChatMessage | null>(null);
  const [notice, setNotice] = useState<string | null>(null);
  const [historyError, setHistoryError] = useState<string | null>(null);
  const [elysiaUserId, setElysiaUserId] = useState<string | null>(null);
  // 长按消息头像 @ 成员 → 通过 ref 调输入框插入 @Token
  const inputRef = useRef<MessageInputHandle>(null);

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
      })
      .catch(handleHistoryError);
    return () => {
      // 离开群聊时清 activeId，避免残留导致其他会话 message.new 被误判 markRead
      useChatStore.getState().closeConversation();
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [groupId]);

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

  // 长按消息头像 → 输入框 @ 该成员
  const handleMentionUser = useCallback((userId: string, name: string) => {
    inputRef.current?.insertMention(userId, name || "群成员");
  }, []);

  // 双击头像 → 戳一戳（轻互动；WS message.poke 回帧负责渲染与置顶排序）
  const handlePoke = useCallback(async (targetUserId: string) => {
    try {
      await chatApi.sendPoke(groupId, targetUserId);
    } catch (e) {
      setNotice(e instanceof Error ? e.message : "戳一戳发送失败");
    }
  }, [groupId]);

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
        onMarkRead={(m, exact) => exact ? markMessageReadExact(groupId, m.id) : undefined}
        onMarkConversationRead={(throughSeq, excluded) => markConversationReadThrough(groupId, throughSeq, excluded)}
        onLoadUntilSeq={(targetSeq) => loadHistoryUntilSeq(groupId, targetSeq).catch(() => false)}
        onRecall={(m) => void handleRecall(m)}
        onRetry={(m) => retryOptimistic(groupId, m)}
        onRemove={(m) => removeOptimistic(groupId, m)}
        onCancel={(m) => cancelOptimistic(groupId, m)}
        onMentionSender={handleMentionUser}
        onPoke={handlePoke}
      />
      <MessageInput ref={inputRef} convId={groupId} quote={quote} onQuoteClear={() => setQuote(null)} members={activeConv?.members} />
    </div>
  );
}
