/**
 * MessageList —— 消息滚动区：时间分组、窗口化历史、滚动锚定与实时跟随。
 *
 * U16 边界：message store 始终保留会话全量缓存；本组件仅将缓存投影为
 * 至多 200 条已确认消息的 DOM 窗口。向上阅读时以 50 条分页边界扩展/滑动，
 * 避免长会话的气泡、媒体与操作控件常驻在 DOM。
 */
import { useCallback, useEffect, useLayoutEffect, useMemo, useRef, useState } from "react";
import { AnimatePresence, motion, useReducedMotion } from "framer-motion";
import type { ChatMessage, ConversationSummary } from "../../api/types";
import {
  HISTORY_PAGE_LIMIT,
  INITIAL_HISTORY_LIMIT,
  MESSAGE_RENDER_WINDOW_LIMIT,
} from "../../hooks/useChat";
import { useAuthStore } from "../../stores/auth";
import { useMessageStore } from "../../stores/message";
import { goUserProfile } from "../../utils/navigation";
import { IconChevronDown } from "../icons";
import { canRecall, MessageBubble } from "./MessageBubble";
import { segmentPreview } from "../../utils/segment";

const GROUP_GAP_MS = 5 * 60 * 1000;
const HISTORY_PRELOAD_THRESHOLD = 400;
const BOTTOM_TOLERANCE = 40;

type RenderWindow = {
  /** 已确认消息窗口的首/尾身份；id 比索引能穿过 before_seq 前插保持稳定。 */
  startId: string;
  endId: string;
};

type RenderBounds = { start: number; end: number };

type PendingPrependAnchor = {
  /** 插入前仍在视口/窗口中的稳定消息身份。 */
  anchorId: string | null;
  previousVisibleFirstId: string | null;
  previousVisibleLastId: string | null;
  scrollTop: number;
  scrollHeight: number;
  relativeTop: number | null;
  /** 等待 API 前插，或等待窗口范围 state 提交。 */
  phase: "awaiting-history" | "awaiting-window";
  targetStartId?: string;
};

function formatTime(iso: string): string {
  const d = new Date(iso);
  if (Number.isNaN(d.getTime())) return "";
  const pad = (n: number) => n.toString().padStart(2, "0");
  return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())} ${pad(d.getHours())}:${pad(d.getMinutes())}`;
}

function shouldGroup(prev: ChatMessage | undefined, curr: ChatMessage): boolean {
  if (!prev) return true;
  const a = new Date(prev.created_at).getTime();
  const b = new Date(curr.created_at).getTime();
  if (Number.isNaN(a) || Number.isNaN(b)) return false;
  return b - a > GROUP_GAP_MS;
}

/** 戳一戳居中提示文案：「A戳了戳B」（自己归一为「我」；content 存目标用户 id）。 */
function pokeLabel(
  message: ChatMessage,
  memberNames: Map<string, string>,
  currentUserId: string | null,
  peerName: string,
): string {
  const senderSelf = currentUserId != null && String(message.sender_id) === String(currentUserId);
  const senderName = senderSelf ? "我" : memberNames.get(message.sender_id) ?? "";
  const targetSelf = currentUserId != null && String(message.content) === String(currentUserId);
  const targetName = targetSelf ? "我" : memberNames.get(message.content) ?? peerName;
  return `${senderName || "有人"}戳了戳${targetName || "对方"}`;
}

/** 未设置显式窗口时，首屏只投影末尾 20 条确认消息。 */
function resolveBounds(messages: ChatMessage[], window: RenderWindow | null): RenderBounds {
  const fallbackEnd = messages.length;
  const fallbackStart = Math.max(0, fallbackEnd - INITIAL_HISTORY_LIMIT);
  if (!window) return { start: fallbackStart, end: fallbackEnd };

  const start = messages.findIndex((m) => m.id === window.startId);
  const endInclusive = messages.findIndex((m) => m.id === window.endId);
  if (start < 0 || endInclusive < start) {
    return { start: fallbackStart, end: fallbackEnd };
  }
  return { start, end: endInclusive + 1 };
}

function windowForBounds(messages: ChatMessage[], start: number, end: number): RenderWindow | null {
  if (start < 0 || end <= start || end > messages.length) return null;
  return { startId: messages[start].id, endId: messages[end - 1].id };
}

function sameWindow(a: RenderWindow | null, b: RenderWindow | null): boolean {
  return a?.startId === b?.startId && a?.endId === b?.endId;
}

function findMessageNode(container: HTMLElement, messageId: string | null): HTMLElement | null {
  if (!messageId) return null;
  return (
    Array.from(container.querySelectorAll<HTMLElement>("[data-message-id]")).find(
      (node) => node.dataset.messageId === messageId,
    ) ?? null
  );
}

function relativeTop(container: HTMLElement, node: HTMLElement | null): number | null {
  if (!node) return null;
  return node.getBoundingClientRect().top - container.getBoundingClientRect().top;
}

function scrollToBottom(element: HTMLElement) {
  // 聊天回底是实时跟随动作，不做长距离平滑动画；避免数百条窗口切换时占用主线程。
  element.scrollTop = element.scrollHeight;
}

export function MessageList({
  messages,
  conversation,
  elysiaUserId,
  hasMore,
  loading,
  onLoadMore,
  onQuote,
  onRecall,
  onRetry,
  onRemove,
  onCancel,
  onMarkRead,
  onMarkConversationRead,
  onLoadUntilSeq,
  onMentionSender,
  onPoke,
}: {
  messages: ChatMessage[];
  conversation: ConversationSummary | null;
  /** 爱莉 profile 的 user.id：匹配 sender_id 即爱莉专属气泡 */
  elysiaUserId?: string | null;
  hasMore: boolean;
  loading: boolean;
  /** 可返回 Promise；调用方仍拥有 API 错误展示职责。 */
  onLoadMore: () => void | Promise<unknown>;
  onQuote?: (msg: ChatMessage) => void;
  /** 点击引用块后，将目标消息精确标记为已读。 */
  onMarkRead?: (msg: ChatMessage, exact?: boolean) => void | Promise<void>;
  /** 普通未读标签点击：批量标记到指定序号，排除特殊未读消息。 */
  onMarkConversationRead?: (throughSeq: number, excludeMessageIds: string[]) => void | Promise<void>;
  /** 目标不在缓存时按 seq 加载到缓存。 */
  onLoadUntilSeq?: (targetSeq: number) => Promise<boolean>;
  onRecall?: (msg: ChatMessage) => void;
  /** 乐观发送失败：重试/删除 */
  onRetry?: (msg: ChatMessage) => void;
  onRemove?: (msg: ChatMessage) => void;
  /** 乐观发送中：取消上传 */
  onCancel?: (msg: ChatMessage) => void;
  /** 长按发送者头像 → 在输入框 @ 该用户（群聊成员 @，由调用方插入到输入框） */
  onMentionSender?: (userId: string, name: string) => void;
  /** 双击头像 → 戳一戳：传目标用户 id（群聊=被双击成员；私聊=对端） */
  onPoke?: (targetUserId: string) => void;
}) {
  const currentUserId = useAuthStore((s) => s.currentUser?.id ?? null);
  const scrollRef = useRef<HTMLDivElement>(null);
  const atBottomRef = useRef(true);
  const lastScrollTopRef = useRef(0);
  const previousConfirmedIdsRef = useRef<string[]>([]);
  const conversationIdRef = useRef<string | null>(null);
  const pendingAnchorRef = useRef<PendingPrependAnchor | null>(null);
  const loadMoreInFlightRef = useRef(false);
  const jumpToBottomRef = useRef(false);
  const jumpTargetRef = useRef<{
    id: string;
    kind: "unread" | "mention" | "reply";
  } | null>(null);
  const jumpSeqRef = useRef<{ seq: number; kind: "unread" | "mention" | "reply" } | null>(null);
  const pendingReadIdsRef = useRef(new Set<string>());
  const [windowRange, setWindowRange] = useState<RenderWindow | null>(null);
  const [farFromBottom, setFarFromBottom] = useState(false);
  const [scrollTick, setScrollTick] = useState(0);
  const [jumpHighlightId, setJumpHighlightId] = useState<string | null>(null);
  // 触屏点行展开工具栏：单选（同时只展开一行；点同一行收起、点其他行切换）。
  const [activeActionsId, setActiveActionsId] = useState<string | null>(null);
  const toggleActions = useCallback((id: string) => {
    setActiveActionsId((prev) => (prev === id ? null : id));
  }, []);
  const highlightTimerRef = useRef<ReturnType<typeof setTimeout> | null>(null);
  const jumpLoadRef = useRef<Promise<boolean> | null>(null);
  const reducedMotion = useReducedMotion();
  const isGroup = conversation?.type === "group";
  // 私聊对端显示名（poke 文案 target 兜底；群聊用成员 map）
  const peerName = conversation?.peer?.nickname || conversation?.peer?.username || "";

  // pending / 发送失败的本地消息不计入 200 条服务端窗口，始终留在尾部让用户可取消、重试或删除。
  const confirmedMessages = useMemo(
    () => messages.filter((m) => !m.pending && !m.sendFailed && m.seq > 0),
    [messages],
  );
  const localMessages = useMemo(
    () => messages.filter((m) => m.pending || m.sendFailed || m.seq <= 0),
    [messages],
  );
  const confirmedSignature = useMemo(
    () => confirmedMessages.map((m) => m.id).join("\u0001"),
    [confirmedMessages],
  );
  const bounds = useMemo(
    () => resolveBounds(confirmedMessages, windowRange),
    [confirmedMessages, windowRange],
  );
  const visibleConfirmed = useMemo(
    () => confirmedMessages.slice(bounds.start, bounds.end),
    [bounds.end, bounds.start, confirmedMessages],
  );
  const visibleMessages = useMemo(
    () => [...visibleConfirmed, ...localMessages],
    [localMessages, visibleConfirmed],
  );
  const visibleSignature = useMemo(
    () => visibleMessages.map((m) => m.id).join("\u0001"),
    [visibleMessages],
  );
  const unreadMessages = useMemo(
    () => confirmedMessages.filter(
      (m) => m.sender_id !== currentUserId && !m.read_by_me && m.type !== "poke",
    ),
    [confirmedMessages, currentUserId],
  );
  const specialUnread = useMemo(() => {
    const mention = unreadMessages.filter((m) =>
      (m.segments ?? []).some((s) => s.type === "mention" && s.user_id === currentUserId),
    );
    const reply = unreadMessages.filter((m) => {
      if (m.reply_to == null) return false;
      const target = confirmedMessages.find((item) => item.id === m.reply_to);
      return target?.sender_id === currentUserId;
    });
    return { mention, reply };
  }, [confirmedMessages, currentUserId, unreadMessages]);
  const ordinaryUnreadSeqsFromMessages = useMemo(
    () => unreadMessages.filter(
      (m) => !m.reply_to && !(m.segments ?? []).some((s) => s.type === "mention" && s.user_id === currentUserId),
    ).map((message) => message.seq),
    [currentUserId, unreadMessages],
  );
  // 普通未读以会话接口的 unread_count/unread_seqs 为权威；旧响应没有字段时，
  // 不从当前历史窗口臆测普通未读（否则刷新后的历史会被误当成新消息）。
  const unreadSeqs = conversation?.unread_seqs ?? (
    (conversation?.unread_count ?? 0) > 0 ? ordinaryUnreadSeqsFromMessages : []
  );
  const mentionSeqs = conversation?.mention_unread_seqs ?? specialUnread.mention.map((message) => message.seq);
  const replySeqs = conversation?.reply_unread_seqs ?? specialUnread.reply.map((message) => message.seq);
  const specialSeqs = useMemo(() => new Set([...mentionSeqs, ...replySeqs]), [mentionSeqs, replySeqs]);
  const ordinaryUnreadSeqs = useMemo(
    () => (conversation?.unread_seqs ? unreadSeqs.filter((seq) => !specialSeqs.has(seq)) : ordinaryUnreadSeqsFromMessages),
    [conversation?.unread_seqs, ordinaryUnreadSeqsFromMessages, specialSeqs, unreadSeqs],
  );
  const hasCachedEarlier = bounds.start > 0;
  const hasHiddenTail = bounds.end < confirmedMessages.length;
  const canLoadEarlier = hasCachedEarlier || hasMore;
  // 首次加载（消息尚未进入）不显示顶部历史控制；只有会话已有内容后才提供上拉入口。
  const showHistoryControl = (canLoadEarlier || loading) && confirmedMessages.length > 0;
  const showBackToBottom = farFromBottom || hasHiddenTail;

  // A1：消息到达动画——区分「初始历史加载」与「新到达」（乐观发送 / WS 实时）。
  // prevIdsRef 记录上一帧消息 id 序列；首次历史加载完成（loading true→false 翻转）
  // 建立基线（当前全部消息视为初始，不动画）；之后仅「数组尾部新增的 id」挂到达动画——
  // 尾部追加 = 新到达（乐观追加 / WS 追加）；头部前插 = 向上翻页历史（不动画）；
  // 同长度替换 = 乐观消息 resolve（local id → 服务端 id，不动画）。
  const prevIdsRef = useRef<string[]>([]);
  const baselinedRef = useRef(false);
  const animationConversationRef = useRef<string | null>(null);
  const prevLoadingRef = useRef<boolean | null>(null);

  const justArrivedIds = useMemo(() => {
    if (animationConversationRef.current !== conversation?.id || !baselinedRef.current) {
      return new Set<string>();
    }
    const prev = prevIdsRef.current;
    const prevLen = prev.length;
    const prevSet = new Set(prev);
    const curIds = messages.map((m) => m.id);
    const arrived = new Set<string>();
    for (let i = prevLen; i < curIds.length; i++) {
      const id = curIds[i];
      if (!prevSet.has(id)) arrived.add(id);
    }
    return arrived;
  }, [messages, conversation?.id]);

  useEffect(() => {
    const convId = conversation?.id ?? "__none__";
    if (animationConversationRef.current !== convId) {
      animationConversationRef.current = convId;
      baselinedRef.current = false;
      prevIdsRef.current = [];
      prevLoadingRef.current = null;
    }
    const prevLoading = prevLoadingRef.current;
    prevLoadingRef.current = loading;
    // 预热缓存（如宽屏侧栏）可能没有经历 loading=true；首次可见的缓存同样属于历史，
    // 但空桶首帧不能提前建基线，否则随后首批历史会被误判为实时到达。
    if (!baselinedRef.current) {
      if (
        (prevLoading === true && loading === false) ||
        (prevLoading === null && loading === false && messages.length > 0)
      ) {
        baselinedRef.current = true;
        prevIdsRef.current = messages.map((m) => m.id);
      }
      return;
    }
    prevIdsRef.current = messages.map((m) => m.id);
  }, [messages, conversation?.id, loading]);

  // 发送者 id → 展示名 + 头像（群聊发送者名 + 头像显示，design.md §4 Chat Bubbles）
  const memberNames = useMemo(() => {
    const map = new Map<string, string>();
    for (const m of conversation?.members ?? []) {
      map.set(m.user.id, m.user.nickname || m.user.username);
    }
    return map;
  }, [conversation]);

  const memberAvatars = useMemo(() => {
    const map = new Map<string, { avatar: string | null; label: string }>();
    for (const m of conversation?.members ?? []) {
      map.set(m.user.id, {
        avatar: m.user.avatar ?? null,
        label: m.user.nickname || m.user.username,
      });
    }
    return map;
  }, [conversation]);

  // 消息 id → 引用预览文本（混排消息按段生成「文本[视频]文本[图片]」）
  const MEDIA_TYPE_LABEL: Record<string, string> = {
    image: "图片",
    voice: "语音",
    file: "文件",
    emoji: "表情",
    video: "视频",
  };
  const quotePreview = useMemo(() => {
    const map = new Map<string, string>();
    for (const m of messages) {
      const fromSegments = segmentPreview(m.segments);
      map.set(
        m.id,
        m.type === "text"
          ? m.content || "…"
          : fromSegments ?? `[${MEDIA_TYPE_LABEL[m.type] ?? "消息"}]`,
      );
    }
    return map;
  }, [messages]);

  // 切换会话（宽屏侧栏点其他群/会话时组件复用不重挂载）→ 每个会话拥有独立的瞬态 DOM 窗口。
  useLayoutEffect(() => {
    const conversationId = conversation?.id ?? "__none__";
    if (conversationIdRef.current === conversationId) return;
    conversationIdRef.current = conversationId;
    atBottomRef.current = true;
    if (conversation?.id) {
      useMessageStore.getState().setViewerAtBottom(conversation.id, true);
    }
    lastScrollTopRef.current = 0;
    previousConfirmedIdsRef.current = [];
    pendingAnchorRef.current = null;
    loadMoreInFlightRef.current = false;
    jumpToBottomRef.current = false;
    setFarFromBottom(false);
    setWindowRange(null);
    setActiveActionsId(null);
    const element = scrollRef.current;
    if (element) scrollToBottom(element);
  }, [conversation?.id]);

  // 消息进入后，将首屏固定为最近 20 条；之后显式范围负责在实时尾部增长到 200 条。
  useLayoutEffect(() => {
    if (windowRange || confirmedMessages.length === 0) return;
    const end = confirmedMessages.length;
    const start = Math.max(0, end - INITIAL_HISTORY_LIMIT);
    const nextWindow = windowForBounds(confirmedMessages, start, end);
    if (nextWindow) setWindowRange(nextWindow);
  }, [confirmedMessages, confirmedSignature, windowRange]);

  // 历史前插与实时尾部追加分别处理：
  // - before_seq 前插：等待新批次进入 store 后，按完整分页边界扩大/滑动 DOM 窗口；
  // - 尾部追加：仅用户本来就在底部时，窗口才随实时消息增长/从顶部收缩。
  useLayoutEffect(() => {
    const pendingAnchor = pendingAnchorRef.current;
    if (pendingAnchor?.phase === "awaiting-history") {
      const firstVisibleIndex = pendingAnchor.previousVisibleFirstId
        ? confirmedMessages.findIndex((m) => m.id === pendingAnchor.previousVisibleFirstId)
        : -1;
      const lastVisibleIndex = pendingAnchor.previousVisibleLastId
        ? confirmedMessages.findIndex((m) => m.id === pendingAnchor.previousVisibleLastId)
        : -1;
      if (firstVisibleIndex > 0 && lastVisibleIndex >= firstVisibleIndex) {
        // 网络前插后：previousLast 是用户视口底部锚点，窗口以它为尾（尽量满 200，
        // 但绝不裁掉视口内容）；头部在缓存变长后自然露出新加载的批次。
        const end = Math.min(confirmedMessages.length, lastVisibleIndex + 1);
        const start = Math.max(0, end - MESSAGE_RENDER_WINDOW_LIMIT);
        const nextWindow = windowForBounds(confirmedMessages, start, end);
        if (nextWindow) {
          pendingAnchor.phase = "awaiting-window";
          pendingAnchor.targetStartId = nextWindow.startId;
          setWindowRange((previous) => (sameWindow(previous, nextWindow) ? previous : nextWindow));
        }
      }
    } else {
      const previousIds = previousConfirmedIdsRef.current;
      const previousLastId = previousIds[previousIds.length - 1] ?? null;
      const currentLastId = confirmedMessages[confirmedMessages.length - 1]?.id ?? null;
      const appendedAtTail =
        previousLastId != null &&
        currentLastId != null &&
        previousLastId !== currentLastId &&
        confirmedMessages.some((m) => m.id === previousLastId);

      if (appendedAtTail) {
        // 新消息直接送进窗口：end 锚定尾部，start 保持用户阅读位置，
        // DOM 高度与滚动条实时变化，向下滚即可看到，不靠回底才刷出。
        const nextEnd = confirmedMessages.length;
        const nextStart = bounds.start;
        const nextWindow = windowForBounds(confirmedMessages, nextStart, nextEnd);
        if (nextWindow) {
          setWindowRange((previous) => (sameWindow(previous, nextWindow) ? previous : nextWindow));
        }
      }
    }

    previousConfirmedIdsRef.current = confirmedMessages.map((m) => m.id);
  }, [bounds.start, confirmedMessages, confirmedSignature, conversation?.id]);

  // 到达历史起点时后端可合法返回空页；这时没有 DOM 提交可触发锚定补偿，
  // 在 loading 完成后释放本次请求状态，避免顶部入口永久失效。
  useEffect(() => {
    const pendingAnchor = pendingAnchorRef.current;
    if (pendingAnchor?.phase === "awaiting-history" && !loading) {
      pendingAnchorRef.current = null;
    }
  }, [loading]);

  // 窗口范围提交后，在绘制前恢复「插入前同一条消息」的相对位置。
  // 正常浏览器优先 identity 锚点；JSDOM/罕见不可量布局退回 scrollHeight 差，严格遵循方案 §4.1。
  useLayoutEffect(() => {
    const pendingAnchor = pendingAnchorRef.current;
    if (
      !pendingAnchor ||
      pendingAnchor.phase !== "awaiting-window" ||
      pendingAnchor.targetStartId !== visibleConfirmed[0]?.id
    ) {
      return;
    }

    const element = scrollRef.current;
    if (!element) return;
    const anchorNode = findMessageNode(element, pendingAnchor.anchorId);
    const nextRelativeTop = relativeTop(element, anchorNode);
    const heightDelta = element.scrollHeight - pendingAnchor.scrollHeight;
    const identityDelta =
      pendingAnchor.relativeTop != null && nextRelativeTop != null
        ? nextRelativeTop - pendingAnchor.relativeTop
        : null;
    const delta = identityDelta != null && Math.abs(identityDelta) > 0.5 ? identityDelta : heightDelta;
    // 基于当前 scrollTop 补偿：加载期间用户可能仍在滚动，用绝对差值叠加更稳。
    element.scrollTop = element.scrollTop + delta;
    lastScrollTopRef.current = element.scrollTop;
    pendingAnchorRef.current = null;
  }, [visibleConfirmed, visibleSignature]);

  // 新消息、乐观消息、窗口回底后的统一贴底路径。历史前插由上方锚定 effect 独占，不能竞争。
  useLayoutEffect(() => {
    const element = scrollRef.current;
    if (!element) return;

    if (jumpToBottomRef.current) {
      if (!hasHiddenTail) {
        scrollToBottom(element);
        atBottomRef.current = true;
        lastScrollTopRef.current = element.scrollTop;
        jumpToBottomRef.current = false;
        setFarFromBottom(false);
      }
      return;
    }

    if (!pendingAnchorRef.current && atBottomRef.current && !hasHiddenTail) {
      scrollToBottom(element);
      lastScrollTopRef.current = element.scrollTop;
      setFarFromBottom(false);
      return;
    }

    const distanceToBottom = element.scrollHeight - element.clientHeight - element.scrollTop;
    setFarFromBottom(distanceToBottom > element.clientHeight);
  }, [hasHiddenTail, visibleSignature]);

  // 图片等媒体异步加载会撑高内容，导致滚动条偏离底部；仅逻辑贴底时持续跟随。
  const hasHiddenTailRef = useRef(hasHiddenTail);
  hasHiddenTailRef.current = hasHiddenTail;
  useEffect(() => {
    const element = scrollRef.current;
    if (!element) return;

    const stickToBottom = () => {
      if (atBottomRef.current && !hasHiddenTailRef.current) {
        scrollToBottom(element);
        lastScrollTopRef.current = element.scrollTop;
      }
    };

    let observer: ResizeObserver | null = null;
    if (typeof ResizeObserver !== "undefined") {
      // 监听滚动容器本身：发送消息清空输入框会改变可视高度，贴底时同步补偿
      // scrollTop，避免聊天记录在发送瞬间上下跳变。
      observer = new ResizeObserver(stickToBottom);
      observer.observe(element);
    }

    const onLoad = (event: Event) => {
      if (event.target instanceof HTMLImageElement) {
        requestAnimationFrame(stickToBottom);
      }
    };
    element.addEventListener("load", onLoad, true);

    return () => {
      observer?.disconnect();
      element.removeEventListener("load", onLoad, true);
    };
  }, []);

  const requestOlder = useCallback(() => {
    // 缓存窗口状态是单个聊天容器的瞬态投影；同一次上拉只允许一个扩展/请求在途。
    if (loading || loadMoreInFlightRef.current) return;
    if (pendingAnchorRef.current) return;
    if (bounds.start <= 0 && !hasMore) return;

    const element = scrollRef.current;
    if (!element) return;
    const previousFirst = visibleConfirmed[0]?.id ?? null;
    const previousLast = visibleConfirmed[visibleConfirmed.length - 1]?.id ?? null;
    const anchorNode = findMessageNode(element, previousFirst);
    pendingAnchorRef.current = {
      anchorId: previousFirst,
      previousVisibleFirstId: previousFirst,
      previousVisibleLastId: previousLast,
      scrollTop: element.scrollTop,
      scrollHeight: element.scrollHeight,
      relativeTop: relativeTop(element, anchorNode),
      phase: "awaiting-window",
    };
    atBottomRef.current = false;

    if (bounds.start > 0) {
      // 向上扩展：start 前移一页（50 条）露出更早消息；end 锚定尾部不动，
      // 新消息永远留在窗口内，向下滚即可看到。
      const nextStart = Math.max(0, bounds.start - HISTORY_PAGE_LIMIT);
      const nextEnd = confirmedMessages.length;
      const nextWindow = windowForBounds(confirmedMessages, nextStart, nextEnd);
      if (nextWindow) {
        pendingAnchorRef.current.targetStartId = nextWindow.startId;
        setWindowRange((previous) => (sameWindow(previous, nextWindow) ? previous : nextWindow));
      }
      return;
    }

    // 已触及缓存最早端，才走既有 before_seq API；store 仍负责全量前插与 hasMore。
    pendingAnchorRef.current.phase = "awaiting-history";
    loadMoreInFlightRef.current = true;
    void Promise.resolve()
      .then(onLoadMore)
      // 页面父级负责把 API 错误显示为 chat-notice；这里仅避免滚动事件产生未处理 rejection。
      .catch(() => {
        // API 失败没有新的 store 提交可触发锚定 effect，必须释放本次锚点，允许用户重试。
        pendingAnchorRef.current = null;
      })
      .finally(() => {
        loadMoreInFlightRef.current = false;
      });
  }, [bounds.end, bounds.start, confirmedMessages, hasMore, loading, onLoadMore, visibleConfirmed]);

  const isSpecial = useCallback(
    (message: ChatMessage) =>
      specialSeqs.has(message.seq) ||
      (message.segments ?? []).some((s) => s.type === "mention" && s.user_id === currentUserId),
    [currentUserId, specialSeqs],
  );

  const tagTarget = useMemo(() => {
    const candidates: Array<{ kind: "unread" | "mention" | "reply"; seq: number; count: number }> = [];
    // 标签计数覆盖全部未读；批量已读动作仍只处理普通消息，特殊消息由各自标签承接。
    if (ordinaryUnreadSeqs.length > 0 && unreadSeqs[0] != null) {
      candidates.push({ kind: "unread", seq: unreadSeqs[0], count: unreadSeqs.length });
    }
    if (mentionSeqs[mentionSeqs.length - 1] != null) {
      candidates.push({ kind: "mention", seq: mentionSeqs[mentionSeqs.length - 1], count: mentionSeqs.length });
    }
    if (replySeqs[replySeqs.length - 1] != null) {
      candidates.push({ kind: "reply", seq: replySeqs[replySeqs.length - 1], count: replySeqs.length });
    }
    return candidates;
  }, [mentionSeqs, ordinaryUnreadSeqs, replySeqs]);

  const clearHighlight = useCallback(() => {
    if (highlightTimerRef.current) clearTimeout(highlightTimerRef.current);
    highlightTimerRef.current = null;
    setJumpHighlightId(null);
  }, []);

  useEffect(() => clearHighlight, [clearHighlight]);

  const scrollToMessageAndHighlight = useCallback((id: string) => {
    const element = scrollRef.current;
    const node = element ? findMessageNode(element, id) : null;
    if (!element || !node) return false;
    const elRect = element.getBoundingClientRect();
    const nodeRect = node.getBoundingClientRect();
    element.scrollTop += nodeRect.top - elRect.top - element.clientHeight / 2;
    lastScrollTopRef.current = element.scrollTop;
    setJumpHighlightId(id);
    if (highlightTimerRef.current) clearTimeout(highlightTimerRef.current);
    highlightTimerRef.current = setTimeout(() => {
      setJumpHighlightId((current) => (current === id ? null : current));
      highlightTimerRef.current = null;
    }, 1600);
    return true;
  }, []);

  // 正常聊天（活跃会话）中被 @/回复的新消息：WS 已直接标已读，这里只补泛光圈，
  // 不弹未读/@/回复标签。滚底由下方统一贴底 effect 承接。
  useLayoutEffect(() => {
    if (!baselinedRef.current) return;
    for (const m of confirmedMessages) {
      if (!justArrivedIds.has(m.id)) continue;
      if (m.sender_id === currentUserId) continue;
      if (!m.read_by_me) continue;
      const isSpecialArrival =
        (m.segments ?? []).some((s) => s.type === "mention" && s.user_id === currentUserId) ||
        m.reply_to != null;
      if (!isSpecialArrival) continue;
      setJumpHighlightId(m.id);
      if (highlightTimerRef.current) clearTimeout(highlightTimerRef.current);
      highlightTimerRef.current = setTimeout(() => {
        setJumpHighlightId((current) => (current === m.id ? null : current));
        highlightTimerRef.current = null;
      }, 1600);
      break;
    }
  }, [confirmedMessages, currentUserId, justArrivedIds]);

  // 自己发送消息（乐观 pending 插入）→ 回底，即使此前向上翻阅过历史。
  // 只标记回底意图，滚底统一交给下方贴底 effect，避免双路径 scrollTop 竞争造成跳变。
  const prevSelfPendingIdsRef = useRef<string[]>([]);
  useLayoutEffect(() => {
    const selfPendingIds = localMessages
      .filter((m) => m.pending && m.sender_id === currentUserId)
      .map((m) => m.id);
    const prev = prevSelfPendingIdsRef.current;
    const hasNew = selfPendingIds.some((id) => !prev.includes(id));
    prevSelfPendingIdsRef.current = selfPendingIds;
    if (!hasNew) return;

    // 窗口尾部已锚定最新消息，只需标记回底意图，滚底统一交给贴底 effect。
    atBottomRef.current = true;
    setFarFromBottom(false);
    jumpToBottomRef.current = true;
  }, [localMessages, currentUserId]);

  const setWindowAround = useCallback((id: string, kind: "unread" | "mention" | "reply") => {
    const index = confirmedMessages.findIndex((message) => message.id === id);
    if (index < 0) return false;
    const half = Math.floor(MESSAGE_RENDER_WINDOW_LIMIT / 2);
    let start = Math.max(0, index - half);
    let end = Math.min(confirmedMessages.length, start + MESSAGE_RENDER_WINDOW_LIMIT);
    if (end - start < MESSAGE_RENDER_WINDOW_LIMIT) start = Math.max(0, end - MESSAGE_RENDER_WINDOW_LIMIT);
    const nextWindow = windowForBounds(confirmedMessages, start, end);
    if (!nextWindow) return false;
    jumpTargetRef.current = { id, kind };
    setWindowRange((previous) => (sameWindow(previous, nextWindow) ? previous : nextWindow));
    return true;
  }, [confirmedMessages]);

  const findBySeq = useCallback(
    (seq: number) => {
      const liveMessages = conversation?.id
        ? useMessageStore.getState().buckets[conversation.id]?.messages ?? []
        : [];
      const source = liveMessages.length > 0 ? liveMessages : confirmedMessages;
      return source.find((item) => item.seq === seq && item.seq > 0) ?? null;
    },
    [conversation?.id, confirmedMessages],
  );

  const jumpToMessage = useCallback(async (message: ChatMessage, kind: "unread" | "mention" | "reply") => {
    const targetId = message.id;
    jumpSeqRef.current = { seq: message.seq, kind };
    jumpTargetRef.current = { id: targetId, kind };
    if (!visibleConfirmed.some((item) => item.id === targetId)) {
      if (confirmedMessages.some((item) => item.id === targetId)) {
        setWindowAround(targetId, kind);
      } else if (findBySeq(message.seq)) {
        // 历史页已经写入 store，但父组件尚未把新数组传入本轮闭包；
        // 保留 seq 意图，由后续 layout effect 在新窗口提交后完成定位。
        return;
      } else if (message.seq > 0 && onLoadUntilSeq) {
        const loaded = jumpLoadRef.current ?? onLoadUntilSeq(message.seq);
        jumpLoadRef.current = loaded;
        try {
          if (!(await loaded)) return;
        } finally {
          if (jumpLoadRef.current === loaded) jumpLoadRef.current = null;
        }
        // store 已经写入，但本轮闭包可能尚未拿到新 props；交给下一次
        // confirmedMessages 提交后的 layout effect 按 seq 完成窗口化与定位。
        jumpSeqRef.current = { seq: message.seq, kind };
      }
      return;
    }
    if (scrollToMessageAndHighlight(targetId) && onMarkRead && kind !== "unread") {
      await onMarkRead(message, true);
    }
  }, [confirmedMessages, findBySeq, onLoadUntilSeq, onMarkRead, scrollToMessageAndHighlight, setWindowAround, visibleConfirmed]);

  const handleQuoteJump = useCallback((reply: ChatMessage) => {
    const target = reply.reply_to ? messages.find((item) => item.id === reply.reply_to) : null;
    if (target) {
      void jumpToMessage(target, "reply");
      return;
    }
    if (reply.reply_to_seq != null) {
      const targetBySeq = findBySeq(reply.reply_to_seq);
      if (targetBySeq) void jumpToMessage(targetBySeq, "reply");
      else if (onLoadUntilSeq) {
        void onLoadUntilSeq(reply.reply_to_seq).then((loaded) => {
          const loadedTarget = findBySeq(reply.reply_to_seq!);
          if (loaded && loadedTarget) void jumpToMessage(loadedTarget, "reply");
        });
      }
    }
  }, [findBySeq, jumpToMessage, messages, onLoadUntilSeq]);

  const tagDirection = useCallback((seq: number): "above" | "below" | null => {
    const element = scrollRef.current;
    if (!element) return null; // 滚动容器未挂载，暂不渲染标签
    const target = findBySeq(seq);
    if (!target) return null; // 目标不在缓存，暂不渲染
    const node = findMessageNode(element, target.id);
    if (node) {
      const nodeRect = node.getBoundingClientRect();
      const elRect = element.getBoundingClientRect();
      if (nodeRect.bottom < elRect.top) return "above";
      if (nodeRect.top > elRect.bottom) return "below";
      // 目标仍在可视区：标签位置取目标中心相对视口中心。
      const targetCenter = (nodeRect.top + nodeRect.bottom) / 2;
      const viewportCenter = (elRect.top + elRect.bottom) / 2;
      return targetCenter <= viewportCenter ? "above" : "below";
    }
    // 目标在缓存但不在窗口：按 seq 相对当前窗口判断上下。
    const firstSeq = visibleConfirmed[0]?.seq;
    const lastSeq = visibleConfirmed[visibleConfirmed.length - 1]?.seq;
    if (firstSeq != null && seq < firstSeq) return "above";
    if (lastSeq != null && seq > lastSeq) return "below";
    return null;
  }, [findBySeq, scrollTick, visibleConfirmed]);

  const handleJumpTag = useCallback(async (tag: { kind: "unread" | "mention" | "reply"; seq: number }) => {
    const target = findBySeq(tag.seq);
    if (!target) {
      if (onLoadUntilSeq) await onLoadUntilSeq(tag.seq);
      const loaded = findBySeq(tag.seq);
      if (!loaded) return;
      await jumpToMessage(loaded, tag.kind);
    } else {
      await jumpToMessage(target, tag.kind);
    }
    if (tag.kind === "unread" && onMarkConversationRead && ordinaryUnreadSeqs.length > 0) {
      const throughSeq = ordinaryUnreadSeqs[ordinaryUnreadSeqs.length - 1];
      const excluded = unreadMessages.filter(isSpecial).map((message) => message.id);
      await onMarkConversationRead(throughSeq, excluded);
    }
  }, [findBySeq, isSpecial, onLoadUntilSeq, onMarkConversationRead, ordinaryUnreadSeqs, unreadMessages, jumpToMessage]);

  useLayoutEffect(() => {
    const pendingSeq = jumpSeqRef.current;
    if (pendingSeq) {
      const target = confirmedMessages.find((item) => item.seq === pendingSeq.seq);
      if (target && !visibleConfirmed.some((item) => item.id === target.id)) {
        const index = confirmedMessages.findIndex((item) => item.id === target.id);
        const half = Math.floor(MESSAGE_RENDER_WINDOW_LIMIT / 2);
        let start = Math.max(0, index - half);
        let end = Math.min(confirmedMessages.length, start + MESSAGE_RENDER_WINDOW_LIMIT);
        if (end - start < MESSAGE_RENDER_WINDOW_LIMIT) start = Math.max(0, end - MESSAGE_RENDER_WINDOW_LIMIT);
        const nextWindow = windowForBounds(confirmedMessages, start, end);
        if (nextWindow) {
          setWindowRange((previous) => (sameWindow(previous, nextWindow) ? previous : nextWindow));
          return;
        }
      }
      if (target && visibleConfirmed.some((item) => item.id === target.id)) {
        jumpSeqRef.current = null;
        jumpTargetRef.current = null;
        if (scrollToMessageAndHighlight(target.id) && onMarkRead && pendingSeq.kind !== "unread") {
          void Promise.resolve(onMarkRead(target, true)).catch(() => undefined);
        }
        return;
      }
    }
    const pending = jumpTargetRef.current;
    if (!pending || !visibleConfirmed.some((item) => item.id === pending.id)) return;
    jumpTargetRef.current = null;
    const target = confirmedMessages.find((item) => item.id === pending.id);
    if (!target) return;
    if (scrollToMessageAndHighlight(target.id) && onMarkRead && pending.kind !== "unread") {
      void Promise.resolve(onMarkRead(target, true)).catch(() => undefined);
    }
  }, [confirmedMessages, onMarkRead, scrollToMessageAndHighlight, visibleConfirmed]);

  // 未读消息（普通 + @我 + 回复）只有真正进入视口才自动标已读；跳转按钮也走同一精确路径。
  // 进入会话滚底只标视口内可见的未读，视口外的保留标签，供用户跳转后逐条已读。
  useEffect(() => {
    const element = scrollRef.current;
    if (!element || !onMarkRead) return;
    const observer = typeof IntersectionObserver === "undefined" ? null : new IntersectionObserver(
      (entries) => {
        for (const entry of entries) {
          if (!entry.isIntersecting || entry.intersectionRatio < 0.6) continue;
          const id = (entry.target as HTMLElement).dataset.messageId;
          const target = id ? confirmedMessages.find((item) => item.id === id) : null;
          if (!target || target.read_by_me || target.sender_id === currentUserId || pendingReadIdsRef.current.has(target.id)) continue;
          pendingReadIdsRef.current.add(target.id);
          void Promise.resolve(onMarkRead(target, true)).finally(() => pendingReadIdsRef.current.delete(target.id));
        }
      },
      { root: element, threshold: 0.6 },
    );
    if (!observer) return;
    for (const message of visibleConfirmed) {
      if (!message.read_by_me && message.sender_id !== currentUserId && message.type !== "poke") {
        const node = findMessageNode(element, message.id);
        if (node) observer.observe(node);
      }
    }
    return () => observer.disconnect();
  }, [confirmedMessages, currentUserId, onMarkRead, visibleConfirmed]);

  const handleScroll = () => {
    const element = scrollRef.current;
    if (!element) return;
    const scrollTop = element.scrollTop;
    const distanceToBottom = element.scrollHeight - element.clientHeight - scrollTop;
    const physicallyAtBottom = distanceToBottom <= BOTTOM_TOLERANCE;

    // 若窗口当前不含缓存尾部，物理滚到该窗口底部不等于回到实时消息底部。
    atBottomRef.current = physicallyAtBottom && !hasHiddenTail;
    if (conversation?.id) {
      useMessageStore.getState().setViewerAtBottom(conversation.id, atBottomRef.current);
    }
    lastScrollTopRef.current = scrollTop;
    setFarFromBottom(distanceToBottom > element.clientHeight);
    setScrollTick((value) => value + 1);

    // 跳转定位把窗口移向历史段（不含尾部）后，滚到窗口底部 → 自动回实时尾部。
    if (physicallyAtBottom && hasHiddenTail) {
      handleJumpToBottom();
      return;
    }

    if (scrollTop < HISTORY_PRELOAD_THRESHOLD) requestOlder();
  };

  const handleJumpToBottom = () => {
    const end = confirmedMessages.length;
    const start = Math.max(0, end - MESSAGE_RENDER_WINDOW_LIMIT);
    const nextWindow = windowForBounds(confirmedMessages, start, end);
    pendingAnchorRef.current = null;
    atBottomRef.current = true;
    setFarFromBottom(false);

    // 当前窗口本已覆盖尾部时不会产生 React state 变更，故直接滚回底部；
    // 窗口在旧历史时则先切换投影，下一次 layout commit 再贴底。
    if (sameWindow(windowRange, nextWindow)) {
      const element = scrollRef.current;
      if (element) {
        scrollToBottom(element);
        lastScrollTopRef.current = element.scrollTop;
      }
      jumpToBottomRef.current = false;
      return;
    }

    jumpToBottomRef.current = true;
    setWindowRange(nextWindow);
  };

  type JumpTag = { kind: "unread" | "mention" | "reply"; seq: number; count: number };

  const tagLabel = (tag: JumpTag) =>
    tag.kind === "unread"
      ? `${tag.count} 条新消息`
      : tag.kind === "mention"
        ? `@我${tag.count > 1 ? ` ${tag.count}` : ""}`
        : `回复${tag.count > 1 ? ` ${tag.count}` : ""}`;

  const tagAriaLabel = (tag: JumpTag) =>
    tag.kind === "unread"
      ? `跳转到 ${tag.count} 条未读消息`
      : tag.kind === "mention"
        ? `跳转到 ${tag.count} 条 @我的消息`
        : `跳转到 ${tag.count} 条回复消息`;

  const renderJumpTag = (tag: JumpTag, direction: "above" | "below") => (
    <motion.button
      key={tag.kind}
      type="button"
      className="message-jump-mention"
      initial={reducedMotion ? { opacity: 0 } : { opacity: 0, y: direction === "above" ? -8 : 8 }}
      animate={{ opacity: 1, y: 0 }}
      exit={reducedMotion ? { opacity: 0 } : { opacity: 0, y: direction === "above" ? -8 : 8 }}
      transition={reducedMotion ? { duration: 0.1 } : { duration: 0.18, ease: "easeOut" }}
      onClick={() => void handleJumpTag(tag)}
      aria-label={tagAriaLabel(tag)}
      title={tag.kind === "unread" ? "未读消息" : tag.kind === "mention" ? "有人 @ 我" : "有人回复了你"}
    >
      {tagLabel(tag)}
    </motion.button>
  );

  return (
    <div className="message-list">
      <div className="message-scroll" ref={scrollRef} onScroll={handleScroll}>
        <div className="message-column">
          {showHistoryControl && (
            <div className="message-history-control" aria-live="polite">
              {loading ? (
                <div className="message-history-spinner" role="status">
                  <span className="message-history-spinner-glyph" aria-hidden="true" />
                  <span>正在加载更早消息</span>
                </div>
              ) : (
                <button type="button" className="load-more-btn" onClick={requestOlder}>
                  加载更早消息
                </button>
              )}
            </div>
          )}
          {visibleMessages.map((m, index) => {
            const grouped = shouldGroup(visibleMessages[index - 1], m);
            const isSelf = m.sender_id === currentUserId;
            // 戳一戳：居中提示（非气泡），历史与实时同一渲染路径。
            if (m.type === "poke") {
              return (
                <div
                  key={m.id ?? `${m.conversation_id}-${m.seq}`}
                  data-message-id={m.id}
                  data-message-seq={m.seq}
                  className={m.id === jumpHighlightId ? "mention-jump-highlight" : undefined}
                >
                  {grouped && (
                    <div className="time-divider">
                      <span>{formatTime(m.created_at)}</span>
                    </div>
                  )}
                  <div className={`msg-poke${justArrivedIds.has(m.id) ? " msg-poke-arrive" : ""}`} role="status">
                    <span className="msg-poke-pill">{pokeLabel(m, memberNames, currentUserId, peerName)}</span>
                  </div>
                </div>
              );
            }
            return (
              <div
                key={m.id ?? `${m.conversation_id}-${m.seq}`}
                data-message-id={m.id}
                data-message-seq={m.seq}
                className={m.id === jumpHighlightId ? "mention-jump-highlight" : undefined}
              >
                {grouped && (
                  <div className="time-divider">
                    <span>{formatTime(m.created_at)}</span>
                  </div>
                )}
                <MessageBubble
                  message={m}
                  isSelf={isSelf}
                  isElysia={elysiaUserId != null && m.sender_id === elysiaUserId}
                  justArrived={justArrivedIds.has(m.id)}
                  senderName={isGroup && !isSelf ? (memberNames.get(m.sender_id) ?? null) : null}
                  senderAvatar={memberAvatars.get(m.sender_id)?.avatar ?? null}
                  senderAvatarLabel={memberAvatars.get(m.sender_id)?.label ?? null}
                  onSenderClick={() => goUserProfile(currentUserId, m.sender_id)}
                  onMentionSender={onMentionSender}
                  onPokeSender={
                    onPoke
                      ? (senderId) => {
                          // 群聊：戳被双击的成员；私聊：双击任意头像都戳向对端
                          if (isGroup) onPoke(senderId);
                          else if (conversation?.peer) onPoke(conversation.peer.id);
                        }
                      : undefined
                  }
                  actionsOpen={activeActionsId === m.id}
                  onToggleActions={() => toggleActions(m.id)}
                  quoteText={m.reply_to ? (quotePreview.get(m.reply_to) ?? "引用的消息") : null}
                  onQuote={onQuote}
                  onQuoteJump={m.reply_to ? handleQuoteJump : undefined}
                  jumpedRecalled={m.id === jumpHighlightId && m.status === "recalled"}
                  onRecall={onRecall && canRecall(m, currentUserId) ? onRecall : undefined}
                  onRetry={onRetry && m.sendFailed ? onRetry : undefined}
                  onRemove={onRemove && m.sendFailed ? onRemove : undefined}
                  onCancel={onCancel && m.pending && m.uploadProgress != null ? onCancel : undefined}
                />
              </div>
            );
          })}
          {messages.length === 0 && !loading && (
            <div className="empty-chat">还没有消息，说点什么吧</div>
          )}
        </div>
      </div>
      <div className="message-jump-tags message-jump-tags-above" aria-live="polite">
        <AnimatePresence>
          {tagTarget
            .filter((tag) => tagDirection(tag.seq) === "above")
            .map((tag) => renderJumpTag(tag, "above"))}
        </AnimatePresence>
      </div>
      <div className="message-jump-tags message-jump-tags-below" aria-live="polite">
        <AnimatePresence>
          {tagTarget
            .filter((tag) => tagDirection(tag.seq) === "below")
            .map((tag) => renderJumpTag(tag, "below"))}
        </AnimatePresence>
      </div>
      <button
        type="button"
        className={`message-jump-bottom${showBackToBottom ? " is-visible" : ""}`}
        onClick={handleJumpToBottom}
        aria-label="回到底部并恢复实时消息跟随"
        title="回到底部"
        aria-hidden={!showBackToBottom}
        tabIndex={showBackToBottom ? 0 : -1}
      >
        <IconChevronDown width={20} height={20} />
      </button>
    </div>
  );
}
