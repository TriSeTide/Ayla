/**
 * ChatConversationRoute —— /chat/:conversationId 路由适配（F1 兼容重定向）。
 *
 * - 群聊会话 → 重定向 /group/:id（聚合主页路由体系，开发文档 §2.1）；
 * - 私聊会话 → 渲染现有 ChatPage（旧路径保留兼容）；
 * - 类型未知时先查会话详情，加载期骨架屏；查询失败回退 ChatPage 自理
 *   （其内部有失败空态 / 演示数据逻辑，不额外制造死路）。
 *   会话列表 store 命中时优先（省一次详情请求）；demo 群会话同样走重定向。
 */
import { useEffect, useMemo, useState } from "react";
import { Navigate, useParams } from "react-router-dom";
import * as chatApi from "../api/chat";
import type { ConversationType } from "../api/types";
import { useChatStore } from "../stores/chat";
import { ChatPage } from "./ChatPage";

export function ChatConversationRoute() {
  const { conversationId } = useParams<{ conversationId: string }>();
  const conversations = useChatStore((s) => s.conversations);

  const cachedType = useMemo(
    () => conversations.find((c) => c.id === conversationId)?.type ?? null,
    [conversations, conversationId],
  );

  const [fetchedType, setFetchedType] = useState<ConversationType | null>(null);
  const [failed, setFailed] = useState(false);

  useEffect(() => {
    setFetchedType(null);
    setFailed(false);
    if (!conversationId || cachedType) return;
    let cancelled = false;
    chatApi
      .getConversation(conversationId)
      .then((c) => {
        if (!cancelled) setFetchedType(c.type);
      })
      .catch(() => {
        if (!cancelled) setFailed(true);
      });
    return () => {
      cancelled = true;
    };
  }, [conversationId, cachedType]);

  const type = cachedType ?? fetchedType;

  if (type === "group" && conversationId) {
    return <Navigate to={`/group/${conversationId}`} replace />;
  }
  if (type === "private" || failed) {
    return <ChatPage />;
  }
  return (
    <div className="route-loading" role="status" aria-label="加载会话中">
      <div className="skeleton" style={{ height: 56, width: "60%" }} />
      <div className="skeleton" style={{ height: 56, width: "80%" }} />
      <div className="skeleton" style={{ height: 56, width: "70%" }} />
    </div>
  );
}
