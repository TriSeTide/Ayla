/**
 * useDanmaku：弹幕发送/接收/滚动编排（M5-4，文档 §4.4）。
 *
 * - 发送：前端拦截空文本与 >200 字符；POST 成功后**不乐观插入**，等 WS 回帧渲染
 *   （单一数据流，避免双份）；400 显示后端 detail；
 * - 接收：WS 帧由 useLiveRoom 统一进 store，本 hook 只负责滚动策略：
 *   用户在底部 → 新弹幕自动滚到底；上翻查看历史 → 不强制滚动，显示"有新弹幕"提示，点击跳底；
 * - 渲染纯文本（React 默认转义），禁止 dangerouslySetInnerHTML。
 */
import { useCallback, useEffect, useRef, useState } from "react";
import * as liveApi from "../api/live";
import { useLiveStore } from "../stores/live";

export const DANMAKU_MAX_LENGTH = 200;

export interface UseDanmakuResult {
  danmaku: ReturnType<typeof useLiveStore.getState>["current"]["danmaku"];
  sending: boolean;
  sendError: string | null;
  send: (content: string) => Promise<boolean>;
  listRef: React.MutableRefObject<HTMLDivElement | null>;
  /** 有未读新弹幕（用户上翻时） */
  hasNewBelow: boolean;
  scrollToBottom: () => void;
}

export function useDanmaku(channelId: number): UseDanmakuResult {
  const danmaku = useLiveStore((s) => s.current.danmaku);
  const [sending, setSending] = useState(false);
  const [sendError, setSendError] = useState<string | null>(null);
  const [hasNewBelow, setHasNewBelow] = useState(false);
  const listRef = useRef<HTMLDivElement | null>(null);
  /** 用户是否停留在底部（决定是否自动跟随滚动） */
  const stickToBottomRef = useRef(true);

  const scrollToBottom = useCallback(() => {
    const el = listRef.current;
    if (el) el.scrollTop = el.scrollHeight;
    stickToBottomRef.current = true;
    setHasNewBelow(false);
  }, []);

  // 监听用户滚动：离开底部则不再自动跟随
  useEffect(() => {
    const el = listRef.current;
    if (!el) return;
    const onScroll = () => {
      const nearBottom = el.scrollHeight - el.scrollTop - el.clientHeight < 40;
      stickToBottomRef.current = nearBottom;
      if (nearBottom) setHasNewBelow(false);
    };
    el.addEventListener("scroll", onScroll);
    return () => el.removeEventListener("scroll", onScroll);
  }, []);

  // 新弹幕到达：底部跟随或显示"有新弹幕"
  useEffect(() => {
    if (danmaku.length === 0) return;
    if (stickToBottomRef.current) {
      const el = listRef.current;
      if (el) el.scrollTop = el.scrollHeight;
    } else {
      setHasNewBelow(true);
    }
  }, [danmaku.length]);

  const send = useCallback(
    async (content: string): Promise<boolean> => {
      const trimmed = content.trim();
      if (!trimmed) {
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
        await liveApi.sendDanmaku(channelId, trimmed);
        return true;
      } catch (e) {
        setSendError(e instanceof Error ? e.message : "发送失败");
        return false;
      } finally {
        setSending(false);
      }
    },
    [channelId],
  );

  return { danmaku, sending, sendError, send, listRef, hasNewBelow, scrollToBottom };
}
