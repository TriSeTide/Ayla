/**
 * GroupChat —— 群内聊天子界面（F3，R-G2）。
 *
 * 复用现有聊天能力（不做侧栏/演示数据/爱莉入口）：MessageList + MessageInput +
 * loadHistory/loadMoreHistory/recallMessage/打字 全复用 hooks/useChat 与 chat/message store。
 * 群 id 即会话 id（GroupPage 传入 groupId）。
 */
import { useEffect, useMemo, useState } from "react";
import type { ChatMessage } from "../../api/types";
import { MessageInput } from "../../components/chat/MessageInput";
import { MessageList } from "../../components/chat/MessageList";
import { TypingIndicator } from "../../components/chat/TypingIndicator";
import { loadHistory, loadMoreHistory, markReadLatest, recallMessage } from "../../hooks/useChat";
import { useChatStore } from "../../stores/chat";
import { useMessageStore } from "../../stores/message";
import { chatWS } from "../../ws/chat";

export function GroupChat({ groupId }: { groupId: string }) {
  const conversations = useChatStore((s) => s.conversations);
  const buckets = useMessageStore((s) => s.buckets);
  const bucket = buckets[groupId];
  const messages = bucket?.messages ?? [];

  const [quote, setQuote] = useState<ChatMessage | null>(null);
  const [peerTyping, setPeerTyping] = useState<Record<string, boolean>>({});
  const [notice, setNotice] = useState<string | null>(null);

  const activeConv = useMemo(
    () => conversations.find((c) => c.id === groupId) ?? null,
    [conversations, groupId],
  );

  // 打开群会话：拉历史 + 订阅 + 标已读（复用 useChat 数据流）
  useEffect(() => {
    useChatStore.getState().openConversation(groupId);
    useMessageStore.getState().openBucket(groupId);
    chatWS.subscribe([groupId]);
    loadHistory(groupId, undefined, true).catch(() => {});
    markReadLatest(groupId);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [groupId]);

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
      await recallMessage(groupId, msg.id);
    } catch (e) {
      setNotice(e instanceof Error ? e.message : "撤回失败");
    }
  };

  return (
    <div className="group-chat">
      {notice && (
        <div className="chat-notice" role="alert" onClick={() => setNotice(null)}>
          {notice}（点击关闭）
        </div>
      )}
      <MessageList
        messages={messages}
        conversation={activeConv}
        elysiaUserId={null}
        hasMore={bucket?.hasMore ?? false}
        loading={bucket?.loading ?? false}
        onLoadMore={() => {
          loadMoreHistory(groupId).catch(() => {});
        }}
        onQuote={setQuote}
        onRecall={(m) => void handleRecall(m)}
      />
      <TypingIndicator typing={typingActive} />
      <MessageInput convId={groupId} quote={quote} onQuoteClear={() => setQuote(null)} />
    </div>
  );
}
