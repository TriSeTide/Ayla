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

/**
 * U16 聊天历史分页与 DOM 投影边界：
 * - 首屏只请求最近 20 条，避免一进会话就把长历史全部挂进 DOM；
 * - 向上翻页仍按 50 条，和后端 before_seq 游标契约一致；
 * - MessageList 只投影至多 200 条已确认消息，store 始终保留全量缓存。
 */
export const INITIAL_HISTORY_LIMIT = 20;
export const HISTORY_PAGE_LIMIT = 50;
export const MESSAGE_RENDER_WINDOW_LIMIT = 200;

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
      // 拉历史（无 before_seq → 最近 20 条；向上翻页仍按 50 条）
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
      limit: INITIAL_HISTORY_LIMIT,
    });
    const hasMore = list.length >= INITIAL_HISTORY_LIMIT;
    if (firstLoad) {
      // 先合并权威缓存、再结束 loading：避免 UI 在「已不加载但消息尚未提交」的中间帧
      // 建立错误的初始窗口或到达动画基线。
      msg.prependHistory(convId, list, hasMore);
      // 第一条加载时若没消息，明确没有更早历史。
      if (list.length === 0) msg.prependHistory(convId, [], false);
      msg.setLoading(convId, false);
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
      limit: HISTORY_PAGE_LIMIT,
    });
    // 同一原则：先前插缓存，再结束 loading，保证滚动锚定看到的是完整 DOM 提交。
    msg.prependHistory(convId, list, list.length >= HISTORY_PAGE_LIMIT);
    msg.setLoading(convId, false);
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

/** 上传中 AbortController 注册表（按本地消息 id），供「取消」按钮中止传输 */
const uploadControllers = new Map<string, AbortController>();

/**
 * 并发上传媒体文件，聚合进度上报 store（0-99，保留 100 给发送阶段）。
 * 若 signal 已 abort，Promise.all 会因 AbortError 立即 reject。
 */
function uploadPickedWithProgress(
  convId: string,
  localId: string,
  picked: PickedMediaItem[],
  signal: AbortSignal,
): Promise<import("../api/media").UploadCompleteResult[]> {
  if (picked.length === 0) return Promise.resolve([]);
  const totals = picked.map((p) => p.file.size);
  const loadedBy = new Array(picked.length).fill(0);
  return Promise.all(
    picked.map((p, i) =>
      uploadMediaFile(p.file, p.kind, {
        signal,
        onProgress: (e) => {
          loadedBy[i] = e.loaded;
          const sumLoaded = loadedBy.reduce((a, b) => a + b, 0);
          const sumTotal = totals.reduce((a, b) => a + b, 0);
          const pct = sumTotal > 0 ? Math.min(99, Math.round((sumLoaded / sumTotal) * 100)) : 0;
          useMessageStore.getState().setMessageUploadProgress(convId, localId, pct);
        },
      }),
    ),
  );
}

/**
 * 乐观发送图文混排消息：立即插入本地 pending 气泡（左侧加载态/进度/可取消），
 * 后台并发上传全部媒体 → 调发送 API → 原地替换为服务端消息；
 * 失败标记 sendFailed（气泡左侧可重试/删除），不阻塞继续输入。
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

  // 无媒体 → 纯文本直接发送
  if (opts.picked.length === 0) {
    void (async () => {
      try {
        const serverMsg = await chatApi.sendMessage(convId, {
          type: "text",
          content: text,
          reply_to: opts.replyTo ?? null,
          idempotency_key: idempotencyKey,
        });
        useMessageStore.getState().resolvePendingMessage(convId, localId, idempotencyKey, serverMsg);
      } catch {
        useMessageStore.getState().markMessageFailed(convId, localId);
      }
    })();
    return;
  }

  // 有媒体 → 注册 AbortController + 后台上传+发送
  const controller = new AbortController();
  uploadControllers.set(localId, controller);

  void (async () => {
    try {
      const uploaded = await uploadPickedWithProgress(convId, localId, opts.picked, controller.signal);
      const segs: NonNullable<import("../api/types").CreateMessagePayload["segments"]> = [
        ...(text ? [{ type: "text" as const, text }] : []),
        ...opts.picked.map((p, i) => ({ type: p.kind, media_id: uploaded[i].media_id })),
      ];
      const serverMsg = await chatApi.sendMessage(convId, {
        type: "mixed",
        content: text,
        reply_to: opts.replyTo ?? null,
        idempotency_key: idempotencyKey,
        segments: segs,
      });
      // 本地预览 URL 由气泡组件在替换卸载时统一 revoke
      useMessageStore.getState().resolvePendingMessage(convId, localId, idempotencyKey, serverMsg);
    } catch {
      // 用户主动取消时不标记失败（消息已由 cancelOptimistic 删除）
      if (!controller.signal.aborted) {
        useMessageStore.getState().markMessageFailed(convId, localId);
      }
    } finally {
      uploadControllers.delete(localId);
    }
  })();
}

/**
 * 重试失败的乐观消息：复用原幂等键（服务端去重），重新上传本地媒体并发送。
 * 先移除失败消息再插入同键 pending（React 批处理同帧完成，不闪烁）。
 */
export function retryOptimistic(convId: string, msg: ChatMessage): void {
  const key = msg.idempotencyKey;
  if (!key) {
    useMessageStore.getState().removeMessage(convId, msg.id);
    return;
  }
  const store = useMessageStore.getState();
  store.removeMessage(convId, msg.id);
  // 旧消息卸载时其 localMedia URL 会被组件 revoke：重试必须重新生成本地预览 URL
  const refreshedLocal = msg.localMedia?.map((m) => ({
    ...m,
    url: URL.createObjectURL(m.file),
  }));

  const newLocalIdStr = newLocalId(key);
  const optimistic: ChatMessage = {
    ...msg,
    id: newLocalIdStr,
    pending: true,
    sendFailed: false,
    idempotencyKey: key,
    seq: 0,
    localMedia: refreshedLocal,
  };
  store.addPendingMessage(convId, optimistic);

  const picked: PickedMediaItem[] = (refreshedLocal ?? []).map((m) => ({
    id: m.id,
    kind: m.kind,
    mimeType: m.mimeType,
    url: m.url,
    file: m.file,
  }));
  if (picked.length === 0) {
    // 纯文本重试（无媒体）：走旧 text 契约，不构造混排段
    void (async () => {
      try {
        const serverMsg = await chatApi.sendMessage(convId, {
          type: "text",
          content: msg.content,
          reply_to: msg.reply_to != null ? Number(msg.reply_to) : null,
          idempotency_key: key,
        });
        store.resolvePendingMessage(convId, newLocalIdStr, key, serverMsg);
      } catch {
        store.markMessageFailed(convId, newLocalIdStr);
      }
    })();
    return;
  }

  const controller = new AbortController();
  uploadControllers.set(newLocalIdStr, controller);

  void (async () => {
    try {
      const uploaded = await uploadPickedWithProgress(convId, newLocalIdStr, picked, controller.signal);
      const segs: NonNullable<import("../api/types").CreateMessagePayload["segments"]> = [];
      for (const seg of msg.segments ?? []) {
        if (seg.type === "text") segs.push({ type: "text", text: seg.text });
      }
      picked.forEach((m, i) => segs.push({ type: m.kind, media_id: uploaded[i].media_id }));
      const serverMsg = await chatApi.sendMessage(convId, {
        type: "mixed",
        content: msg.content,
        reply_to: msg.reply_to != null ? Number(msg.reply_to) : null,
        idempotency_key: key,
        segments: segs,
      });
      store.resolvePendingMessage(convId, newLocalIdStr, key, serverMsg);
    } catch {
      if (!controller.signal.aborted) {
        store.markMessageFailed(convId, newLocalIdStr);
      }
    } finally {
      uploadControllers.delete(newLocalIdStr);
    }
  })();
}

/** 取消乐观发送中的消息（abort 上传 + 删除消息 + 释放本地预览 URL） */
export function cancelOptimistic(convId: string, msg: ChatMessage): void {
  const ctrl = uploadControllers.get(msg.id);
  if (ctrl) {
    uploadControllers.delete(msg.id);
    ctrl.abort();
  }
  removeOptimistic(convId, msg);
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
