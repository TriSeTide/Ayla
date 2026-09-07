/**
 * useDanmaku：弹幕发送/接收/滚动编排（M5-4，文档 §4.4）。
 *
 * - 发送：前端拦截空文本与 >200 字符；POST 成功后**不乐观插入**，等 WS 回帧渲染
 *   （单一数据流，避免双份）；400 显示后端 detail；
 * - 接收：WS 帧由 liveSessionRuntime 进入实时 store；本 hook 独立读取分页历史，
 *   历史不写回 overlay 队列。可见窗口最多 500 条，向上续读保持锚点；
 *   上翻期间新弹幕只提示返回最新，成功读取后再替换窗口，失败保留原页。
 * - 渲染纯文本（React 默认转义），禁止 dangerouslySetInnerHTML。
 */
import { useCallback, useEffect, useRef, useState } from "react";
import * as liveApi from "../api/live";
import { useLiveStore } from "../stores/live";
import { useAuthStore } from "../stores/auth";
import { useCursorHistory } from "./useCursorHistory";
import type { HistoryControlsProps } from "../components/HistoryControls";
import { liveSessionRuntime } from "../runtime/liveSessionRuntime";

export const DANMAKU_MAX_LENGTH = 200;

export interface UseDanmakuResult {
  danmaku: ReturnType<typeof useLiveStore.getState>["current"]["danmaku"];
  sending: boolean;
  sendOwner: string;
  sendError: string | null;
  send: (content: string, mediaId?: string | null) => Promise<boolean>;
  listRef: React.MutableRefObject<HTMLDivElement | null>;
  /** 有未读新弹幕（用户上翻时） */
  hasNewBelow: boolean;
  scrollToBottom: () => void;
  /** 列表滚动上报（由 DanmakuList 的 onScroll 调用；勿在 hook 内自挂 DOM 监听） */
  handleListScroll: () => void;
  history: HistoryControlsProps;
}

export function useDanmaku(channelId: number): UseDanmakuResult {
  const realtime = useLiveStore((s) => s.current.danmaku);
  const currentChannelId = useLiveStore((s) => s.current.channel?.id);
  const userId = useAuthStore((s) => s.currentUser?.id ?? "");
  const owner = `live-history:${userId}:${channelId}`;
  const ownerRef = useRef(owner);
  ownerRef.current = owner;
  const fetchHistory = useCallback((cursor: string | null, beforeId?: string) =>
    liveApi.listDanmakuPage(channelId, { cursor, beforeId }), [channelId]);
  const history = useCursorHistory(owner, fetchHistory);
  const danmaku = history.items;
  const [sending, setSending] = useState(false);
  const [sendError, setSendError] = useState<string | null>(null);
  const hasNewBelow = history.hasNewer;
  const listRef = history.listRef;
  const lastBatch = useRef(new Set<string>());
  useEffect(() => { lastBatch.current.clear(); setSending(false); setSendError(null); }, [owner]);
  useEffect(() => liveSessionRuntime.onHistoryInvalidated((changedChannelId) => {
    if (changedChannelId === channelId) history.invalidate();
  }), [channelId, history.invalidate]);
  useEffect(() => {
    if (currentChannelId !== channelId) return;
    for (const item of realtime) if (!lastBatch.current.has(item.id)) history.append(item);
    lastBatch.current = new Set(realtime.map((item) => item.id));
  }, [realtime, channelId, currentChannelId, history.append]);

  const scrollToBottom = useCallback(() => {
    if (history.hasNewer) { void history.returnLatest(); return; }
    const el = listRef.current;
    if (el) el.scrollTop = el.scrollHeight;
    history.handleScroll();
  }, [history.hasNewer, history.returnLatest, history.handleScroll, listRef]);

  // 用户滚动上报：离开底部则不再自动跟随。
  // （2026-08-26 修复：此前在本 hook 用空依赖 effect 自挂 listener，而窄屏沉浸式
  // AnimatePresence sync 下切直播间会重建 .danmaku-list 且 exit 实例卸载时把共享
  // listRef.current 置 null，listener 挂死元素 + ref 失效 → 自动滚底静默失效。
  // 现改为由 DanmakuList 元素自身 onScroll 上报，listRef 由 present 实例独占绑定。）
  const handleListScroll = history.handleScroll;

  const send = useCallback(
    async (content: string, mediaId?: string | null): Promise<boolean> => {
      if (ownerRef.current !== owner) return false;
      const trimmed = content.trim();
      if (!trimmed && !mediaId) {
        setSendError("弹幕不能为空");
        return false;
      }
      if (trimmed.length > DANMAKU_MAX_LENGTH) {
        setSendError(`弹幕长度不能超过 ${DANMAKU_MAX_LENGTH} 字`);
        return false;
      }
      setSending(true);
      setSendError(null);
      try {
        // 成功不乐观插入：等服务端广播的 WS 回帧（单一数据流）
        await liveApi.sendDanmaku(channelId, trimmed || "图片", mediaId);
        return ownerRef.current === owner;
      } catch (e) {
        if (ownerRef.current === owner) setSendError(e instanceof Error ? e.message : "发送失败");
        return false;
      } finally {
        if (ownerRef.current === owner) setSending(false);
      }
    },
    [channelId, owner],
  );

  return { danmaku, sending, sendOwner: owner, sendError, send, listRef, hasNewBelow, scrollToBottom, handleListScroll, history };
}
