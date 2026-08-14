/**
 * ChatConversationRoute —— /chat/:conversationId 路由适配。
 *
 * - 群聊会话 → 重定向 /group/:id（聚合主页路由体系）；
 * - 私聊会话 → 渲染 PrivateChatPage（独立私聊窗口）；
 * - 类型未知时先查会话详情，加载期骨架屏；查询失败渲染私聊窗口自理（会话无类型信息时
 *   按私聊处理，由消息流自愈）。
 */
import { useEffect, useMemo, useState } from "react";
import { Navigate, useParams } from "react-router-dom";
import * as chatApi from "../api/chat";
import type { ConversationType } from "../api/types";
import { useChatStore } from "../stores/chat";
import { PrivateChatPage } from "./PrivateChatPage";

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
    return <PrivateChatPage />;
  }
  return (
    <div className="route-loading" role="status" aria-label="加载会话中">
      <div className="skeleton" style={{ height: 56, width: "60%" }} />
      <div className="skeleton" style={{ height: 56, width: "80%" }} />
      <div className="skeleton" style={{ height: 56, width: "70%" }} />
    </div>
  );
}
