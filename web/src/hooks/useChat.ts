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
import { uploadMediaFile } from "../api/media";
import { useAuthStore } from "../stores/auth";
import { useChatStore } from "../stores/chat";
import { useMessageStore } from "../stores/message";
import { useBadgesStore } from "../stores/badges";
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
  options: { type?: MessageType; replyTo?: number | null; idempotencyKey?: string; mediaId?: string } = {},
): Promise<ChatMessage> {
  const idempotencyKey = options.idempotencyKey ?? newIdempotencyKey();
  const msg = await chatApi.sendMessage(convId, {
    type: options.type ?? "text",
    content,
    reply_to: options.replyTo ?? null,
    idempotency_key: idempotencyKey,
    media_id: options.mediaId,
  });
  // 本地乐观插入（WS message.new 到达时按 seq 去重，不会重复）
  useMessageStore.getState().upsertMessage(convId, msg);
  return msg;
}

/* ---------- 乐观发送（M7：不阻塞输入，气泡左上角加载/失败态） ---------- */

/** 待发送媒体（本地选择/粘贴，尚未上传） */
export interface PickedMediaItem {
  id: string;
  kind: "image" | "video";
  mimeType: string;
  /** objectURL（缩略图条与乐观气泡预览用） */
  url: string;
  file: File;
}

export interface OptimisticSendOptions {
  text: string;
  picked: PickedMediaItem[];
  replyTo?: number | null;
}

function newLocalId(key: string) {
  return `local-${key}`;
}

/**
 * 乐观发送图文混排消息：立即插入本地 pending 气泡（左上角加载态），
 * 后台并发上传全部媒体 → 调发送 API → 原地替换为服务端消息；
 * 失败标记 sendFailed（气泡左上角可重试/删除），不阻塞继续输入。
 */
export function sendOptimistic(convId: string, opts: OptimisticSendOptions): void {
  const idempotencyKey = newIdempotencyKey();
  const localId = newLocalId(idempotencyKey);
  const currentUser = useAuthStore.getState().currentUser;
  const nowIso = new Date().toISOString();
  const text = opts.text.trim();

  // 无媒体 = 纯文本乐观消息（旧 text 契约，不构造混排段）；有媒体 = type=mixed + segments
  const segments: NonNullable<import("../api/types").ChatMessage["segments"]> | null =
    opts.picked.length === 0
      ? null
      : [
          ...(text ? [{ type: "text" as const, text }] : []),
          ...opts.picked.map((p) => ({ type: p.kind, media_id: "", media: null })),
        ];
  const localMedia = opts.picked.map((p) => ({
    id: p.id,
    kind: p.kind,
    mimeType: p.mimeType,
    url: p.url,
    file: p.file,
  }));

  const optimistic: ChatMessage = {
    id: localId,
    conversation_id: convId,
    sender_id: currentUser?.id ?? "me",
    type: opts.picked.length === 0 ? "text" : "mixed",
    content: text,
    media_id: null,
    segments,
    localMedia,
    reply_to: opts.replyTo != null ? String(opts.replyTo) : null,
    status: "sent",
    seq: 0,
    created_at: nowIso,
    pending: true,
    idempotencyKey,
  };
  useMessageStore.getState().addPendingMessage(convId, optimistic);

  // 后台发送（不阻塞调用方；失败在气泡左上角呈现）
  void (async () => {
    try {
      let serverMsg: ChatMessage;
      if (opts.picked.length === 0) {
        serverMsg = await chatApi.sendMessage(convId, {
          type: "text",
          content: text,
          reply_to: opts.replyTo ?? null,
          idempotency_key: idempotencyKey,
        });
      } else {
        // 先并发上传全部媒体，再组装 segments 发消息
        const uploaded = await Promise.all(
          opts.picked.map((p) => uploadMediaFile(p.file, p.kind)),
        );
        const segs: NonNullable<import("../api/types").CreateMessagePayload["segments"]> = [
          ...(text ? [{ type: "text" as const, text }] : []),
          ...opts.picked.map((p, i) => ({ type: p.kind, media_id: uploaded[i].media_id })),
        ];
        serverMsg = await chatApi.sendMessage(convId, {
          type: "mixed",
          content: text,
          reply_to: opts.replyTo ?? null,
          idempotency_key: idempotencyKey,
          segments: segs,
        });
      }
      // 替换完成后本地预览不再需要
      for (const p of opts.picked) URL.revokeObjectURL(p.url);
      useMessageStore
        .getState()
        .resolvePendingMessage(convId, localId, idempotencyKey, serverMsg);
    } catch {
      // 上传/发送失败：保留气泡与本地预览，左上角显示失败态（可重试/删除）
      useMessageStore.getState().markMessageFailed(convId, localId);
    }
  })();
}

/**
 * 重试失败的乐观消息：复用原幂等键（服务端去重），重新上传本地媒体并发送。
 * 先移除失败消息再插入同键 pending（React 批处理同帧完成，不闪烁）。
 */
export function retryOptimistic(convId: string, msg: ChatMessage): void {
  const key = msg.idempotencyKey;
  const localMedia = msg.localMedia ?? [];
  if (!key) {
    useMessageStore.getState().removeMessage(convId, msg.id);
    return;
  }
  const store = useMessageStore.getState();
  store.removeMessage(convId, msg.id);

  const newLocalIdStr = newLocalId(key);
  const optimistic: ChatMessage = {
    ...msg,
    id: newLocalIdStr,
    pending: true,
    sendFailed: false,
    idempotencyKey: key,
    seq: 0,
  };
  store.addPendingMessage(convId, optimistic);

  void (async () => {
    try {
      const uploaded = await Promise.all(
        localMedia.map((m) => uploadMediaFile(m.file, m.kind)),
      );
      const segs: NonNullable<import("../api/types").CreateMessagePayload["segments"]> = [];
      for (const seg of msg.segments ?? []) {
        if (seg.type === "text") segs.push({ type: "text", text: seg.text });
      }
      localMedia.forEach((m, i) => segs.push({ type: m.kind, media_id: uploaded[i].media_id }));
      const serverMsg = await chatApi.sendMessage(convId, {
        type: "mixed",
        content: msg.content,
        reply_to: msg.reply_to != null ? Number(msg.reply_to) : null,
        idempotency_key: key,
        segments: segs,
      });
      for (const m of localMedia) URL.revokeObjectURL(m.url);
      store.resolvePendingMessage(convId, newLocalIdStr, key, serverMsg);
    } catch {
      store.markMessageFailed(convId, newLocalIdStr);
    }
  })();
}

/** 删除本地消息（乐观失败丢弃；同时释放本地预览 URL） */
export function removeOptimistic(convId: string, msg: ChatMessage): void {
  for (const m of msg.localMedia ?? []) URL.revokeObjectURL(m.url);
  useMessageStore.getState().removeMessage(convId, msg.id);
}

/** 撤回（仅自己 + 窗口内；后端 403/400 会抛错，由调用方提示） */
export async function recallMessage(convId: string, messageId: string) {
  const msg = await chatApi.recallMessage(convId, messageId);
  useMessageStore.getState().setRecalled(convId, messageId);
  return msg;
}

/** 标已读：把当前会话中"对方发、我未读"的最新一条标已读（服务端 mark_read 幂等） */
export async function markConversationRead(convId: string) {
  try {
    await chatApi.markConversationRead(convId);
    useChatStore.getState().clearUnread(convId);
    void useBadgesStore.getState().fetch();
  } catch {
    // 服务端失败保留红点，下一次进入会话时重试。
  }
}

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
    useChatStore.getState().clearUnread(convId);
    // 服务端红点按 MessageRead 聚合，成功后立即同步全局消息入口。
    void useBadgesStore.getState().fetch();
  } catch {
    // 已读失败保留未读红点，调用方可在下一次打开时重试。
  }
}
