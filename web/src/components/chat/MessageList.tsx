/**
 * MessageList —— 消息滚动区：时间分组、窗口化历史、滚动锚定与实时跟随。
 *
 * U16 边界：message store 始终保留会话全量缓存；本组件仅将缓存投影为
 * 至多 200 条已确认消息的 DOM 窗口。向上阅读时以 50 条分页边界扩展/滑动，
 * 避免长会话的气泡、媒体与操作控件常驻在 DOM。
 */
import { useCallback, useEffect, useLayoutEffect, useMemo, useRef, useState } from "react";
import type { ChatMessage, ConversationSummary } from "../../api/types";
import {
  HISTORY_PAGE_LIMIT,
  INITIAL_HISTORY_LIMIT,
  MESSAGE_RENDER_WINDOW_LIMIT,
} from "../../hooks/useChat";
import { useAuthStore } from "../../stores/auth";
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
}: {
  messages: ChatMessage[];
  conversation: ConversationSummary | null;
  /** 爱莉 profile 的 user.id：匹配 sender_id 即爱莉专属气泡 */
  elysiaUserId?: string | null;
  hasMore: boolean;
  loading: boolean;
  /** 可返回 Promise；调用方仍拥有 API 错误展示职责。 */
  onLoadMore: () => void | Promise<void>;
  onQuote?: (msg: ChatMessage) => void;
  onRecall?: (msg: ChatMessage) => void;
  /** 乐观发送失败：重试/删除 */
  onRetry?: (msg: ChatMessage) => void;
  onRemove?: (msg: ChatMessage) => void;
  /** 乐观发送中：取消上传 */
  onCancel?: (msg: ChatMessage) => void;
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
  const jumpToMentionRef = useRef<string | null>(null);
  const [windowRange, setWindowRange] = useState<RenderWindow | null>(null);
  const [farFromBottom, setFarFromBottom] = useState(false);
  const [mentionAbove, setMentionAbove] = useState(false);
  const [mentionHighlightId, setMentionHighlightId] = useState<string | null>(null);
  const isGroup = conversation?.type === "group";

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
  // @ 我的消息（非自己发送）里 seq 最大的一条，作为「跳转到 @ 我」的定位目标
  const mentionTargetId = useMemo(() => {
    let target: ChatMessage | null = null;
    for (const m of confirmedMessages) {
      if (m.sender_id === currentUserId) continue;
      const hit = (m.segments ?? []).some(
        (s) => s.type === "mention" && s.user_id === currentUserId,
      );
      if (hit && (!target || m.seq > target.seq)) target = m;
    }
    return target?.id ?? null;
  }, [confirmedMessages, currentUserId]);
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
    lastScrollTopRef.current = 0;
    previousConfirmedIdsRef.current = [];
    pendingAnchorRef.current = null;
    loadMoreInFlightRef.current = false;
    jumpToBottomRef.current = false;
    setFarFromBottom(false);
    setWindowRange(null);
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

      if (appendedAtTail && atBottomRef.current) {
        // 贴底中的新消息：窗口保持尾部 200 条（最新永远可见）；超限从顶部裁，
        // 200 是 50 的倍数，头部起点自然对齐分页批次。
        const nextEnd = confirmedMessages.length;
        const nextStart = Math.max(0, nextEnd - MESSAGE_RENDER_WINDOW_LIMIT);
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
      const column = element.querySelector(".message-column");
      if (column) {
        observer = new ResizeObserver(stickToBottom);
        observer.observe(column);
      }
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
      // 优先从权威缓存暴露更早的一整页。窗口尽量满 200 条：头部每次前移 50，
      // 尾部相应后移（200 是 50 的倍数，两端自然对齐分页批次），用户正在向上阅读，
      // 最新消息在窗口外由「回到底部」浮钮承接，不在上滑阅读路径中被卸载。
      const nextStart = Math.max(0, bounds.start - HISTORY_PAGE_LIMIT);
      const nextEnd = Math.min(confirmedMessages.length, nextStart + MESSAGE_RENDER_WINDOW_LIMIT);
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

  // 检测 @ 我的消息是否在视口上方（被刷上去）→ 显示「@我」跳转按钮
  const refreshMentionAbove = useCallback(() => {
    if (!mentionTargetId) {
      setMentionAbove(false);
      return;
    }
    const element = scrollRef.current;
    if (!element) return;
    const node = findMessageNode(element, mentionTargetId);
    if (!node) {
      setMentionAbove(false);
      return;
    }
    const nodeRect = node.getBoundingClientRect();
    const elRect = element.getBoundingClientRect();
    setMentionAbove(nodeRect.bottom < elRect.top);
  }, [mentionTargetId]);

  // 窗口/消息变化时重算 @我 按钮可见性（新消息、扩窗、定位后）
  useLayoutEffect(() => {
    refreshMentionAbove();
  }, [refreshMentionAbove, visibleSignature]);

  // 滚动定位到目标消息（居中）+ 短暂辉光高亮（design.md §7/F10 玻璃辉光一闪）
  const scrollToMentionAndHighlight = useCallback((id: string) => {
    const element = scrollRef.current;
    if (!element) return;
    const node = findMessageNode(element, id);
    if (!node) return;
    const elRect = element.getBoundingClientRect();
    const nodeRect = node.getBoundingClientRect();
    element.scrollTop += nodeRect.top - elRect.top - element.clientHeight / 2;
    lastScrollTopRef.current = element.scrollTop;
    setMentionHighlightId(id);
    window.setTimeout(() => {
      setMentionHighlightId((cur) => (cur === id ? null : cur));
    }, 2000);
  }, []);

  const handleJumpToMention = () => {
    if (!mentionTargetId) return;
    const idx = confirmedMessages.findIndex((m) => m.id === mentionTargetId);
    if (idx < 0) return;
    // 目标已在窗口内 → 直接定位 + 高亮
    if (visibleConfirmed.some((m) => m.id === mentionTargetId)) {
      scrollToMentionAndHighlight(mentionTargetId);
      return;
    }
    // 目标在缓存但不在窗口（被窗口裁掉）→ 扩窗到包含目标，下一帧定位
    const half = Math.floor(MESSAGE_RENDER_WINDOW_LIMIT / 2);
    let start = Math.max(0, idx - half);
    let end = Math.min(confirmedMessages.length, start + MESSAGE_RENDER_WINDOW_LIMIT);
    if (end - start < MESSAGE_RENDER_WINDOW_LIMIT) {
      start = Math.max(0, end - MESSAGE_RENDER_WINDOW_LIMIT);
    }
    const nextWindow = windowForBounds(confirmedMessages, start, end);
    if (nextWindow) {
      jumpToMentionRef.current = mentionTargetId;
      setWindowRange((prev) => (sameWindow(prev, nextWindow) ? prev : nextWindow));
    }
  };

  // 扩窗提交后定位到 @ 我消息
  useLayoutEffect(() => {
    if (jumpToMentionRef.current) {
      const id = jumpToMentionRef.current;
      jumpToMentionRef.current = null;
      scrollToMentionAndHighlight(id);
    }
  }, [visibleSignature, scrollToMentionAndHighlight]);

  const handleScroll = () => {
    const element = scrollRef.current;
    if (!element) return;
    const scrollTop = element.scrollTop;
    const distanceToBottom = element.scrollHeight - element.clientHeight - scrollTop;
    const physicallyAtBottom = distanceToBottom <= BOTTOM_TOLERANCE;

    // 若窗口当前不含缓存尾部，物理滚到该窗口底部不等于回到实时消息底部。
    atBottomRef.current = physicallyAtBottom && !hasHiddenTail;
    lastScrollTopRef.current = scrollTop;
    setFarFromBottom(distanceToBottom > element.clientHeight);
    refreshMentionAbove();

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
            return (
              <div
                key={m.id ?? `${m.conversation_id}-${m.seq}`}
                data-message-id={m.id}
                data-message-seq={m.seq}
                className={m.id === mentionHighlightId ? "mention-jump-highlight" : undefined}
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
                  quoteText={m.reply_to ? (quotePreview.get(m.reply_to) ?? "引用的消息") : null}
                  onQuote={onQuote}
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
      {mentionTargetId && mentionAbove && (
        <button
          type="button"
          className="message-jump-mention"
          onClick={handleJumpToMention}
          aria-label="跳转到 @ 我的消息"
          title="有人 @ 我"
        >
          @我
        </button>
      )}
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
