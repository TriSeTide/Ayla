/**
 * useChat：会话编排（文档 §4）。
 *
 * - openConversation：打开会话 → 拉历史 → 订阅 WS → 标已读；
 * - loadMoreHistory：上拉加载更早消息（before_seq = 缓存最小 seq）；
 * - sendMessage：生成 idempotency_key 发送；失败重试复用同一 key；
 * - recallMessage：撤回（仅自己 + 窗口内）；
 * - markRead：把当前会话中"对方发且我未读"的消息批量标已读。
 */
import { useCallback } from "react";
import { useNavigate } from "react-router-dom";
import { v4 as uuid } from "uuid";
import * as chatApi from "../api/chat";
import type { ChatMessage, MessageType } from "../api/types";
import { useAuthStore } from "../stores/auth";
import { useChatStore } from "../stores/chat";
import { useMessageStore } from "../stores/message";
import { chatWS } from "../ws/chat";

/** 撤回时限（秒），与 backend settings MESSAGE_RECALL_SECONDS=120 对齐 */
export const RECALL_SECONDS = 120;

function newIdempotencyKey() {
  // 浏览器原生 crypto.randomUUID；测试环境可用 uuid 兜底
  if (typeof crypto !== "undefined" && typeof crypto.randomUUID === "function") {
    return crypto.randomUUID();
  }
  return uuid();
}

export function useChat() {
  const navigate = useNavigate();
  const conversations = useChatStore((s) => s.conversations);
  const activeConversationId = useChatStore((s) => s.activeConversationId);

  const openConversation = useCallback(
    async (convId: string) => {
      useChatStore.getState().openConversation(convId);
      useMessageStore.getState().openBucket(convId);
      // 订阅 WS（增量）
      chatWS.subscribe([convId]);
      // 拉历史（无 before_seq → 最新 50 条）
      await loadHistory(convId, undefined, true);
      // 打开即标已读（对方发且我未读的最新一条）
      markReadLatest(convId);
      navigate(`/chat/${convId}`);
    },
    [navigate],
  );

  return { conversations, activeConversationId, openConversation };
}

/** 拉历史：before_seq 缺省取缓存最小 seq；firstLoad 置 loading */
export async function loadHistory(convId: string, beforeSeq?: number, firstLoad = false) {
  const msg = useMessageStore.getState();
  const bucket = msg.buckets[convId];
  if (firstLoad) msg.setLoading(convId, true);
  let seq = beforeSeq;
  if (seq === undefined && bucket && bucket.messages.length > 0) {
    seq = bucket.messages[0].seq; // 最小 seq
  }
  try {
    const list = await chatApi.listMessages(convId, {
      before_seq: seq,
      limit: 50,
    });
    const hasMore = list.length >= 50;
    if (firstLoad) {
      msg.setLoading(convId, false);
      msg.prependHistory(convId, list, hasMore);
      // 第一条加载时若没消息，保持 hasMore=true 以便继续
      if (list.length === 0) msg.prependHistory(convId, [], false);
    } else {
      msg.prependHistory(convId, list, hasMore);
    }
  } catch (e) {
    if (firstLoad) msg.setLoading(convId, false);
    throw e;
  }
}

/** 上拉加载更早历史 */
export async function loadMoreHistory(convId: string) {
  const msg = useMessageStore.getState();
  const bucket = msg.buckets[convId];
  if (!bucket || bucket.loading || !bucket.hasMore) return;
  msg.setLoading(convId, true);
  const minSeq = bucket.messages[0]?.seq;
  try {
    const list = await chatApi.listMessages(convId, {
      before_seq: minSeq,
      limit: 50,
    });
    msg.setLoading(convId, false);
    msg.prependHistory(convId, list, list.length >= 50);
  } catch (e) {
    msg.setLoading(convId, false);
    throw e;
  }
}

/** 发消息：生成 idempotency_key；失败抛错（调用方重试复用同一 key 由服务端幂等） */
export async function sendMessage(
  convId: string,
  content: string,
  options: { type?: MessageType; replyTo?: number | null; idempotencyKey?: string } = {},
): Promise<ChatMessage> {
  const idempotencyKey = options.idempotencyKey ?? newIdempotencyKey();
  const msg = await chatApi.sendMessage(convId, {
    type: options.type ?? "text",
    content,
    reply_to: options.replyTo ?? null,
    idempotency_key: idempotencyKey,
  });
  // 本地乐观插入（WS message.new 到达时按 seq 去重，不会重复）
  useMessageStore.getState().upsertMessage(convId, msg);
  return msg;
}

/** 撤回（仅自己 + 窗口内；后端 403/400 会抛错，由调用方提示） */
export async function recallMessage(convId: string, messageId: string) {
  const msg = await chatApi.recallMessage(convId, messageId);
  useMessageStore.getState().setRecalled(convId, messageId);
  return msg;
}

/** 标已读：把当前会话中"对方发、我未读"的最新一条标已读（服务端 mark_read 幂等） */
export async function markReadLatest(convId: string) {
  const msg = useMessageStore.getState();
  const bucket = msg.buckets[convId];
  const currentUser = useAuthStore.getState().currentUser;
  if (!bucket || !currentUser) return;
  const target = [...bucket.messages]
    .reverse()
    .find((m) => m.sender_id !== currentUser.id && m.status !== "recalled");
  if (!target) return;
  try {
    await chatApi.markMessageRead(convId, target.id);
  } catch {
    // 标已读失败不阻塞会话
  }
}
