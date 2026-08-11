/**
 * useTyping：typing 节流声明（文档 §4.7）。
 *
 * - 输入时以节流（2s 一次）POST /typing/ {is_typing:true}；
 * - 停止输入 3s 后 {is_typing:false}；
 * - 对端 typing 帧由调用方监听 chatWS.onFrame 更新 TypingIndicator。
 */
import { useEffect, useRef, useState } from "react";
import { declareTyping } from "../api/chat";

const DECLARE_INTERVAL_MS = 2_000;
const STOP_DELAY_MS = 3_000;

export function useTyping(convId: string | null) {
  const lastSentRef = useRef(0);
  const stopTimerRef = useRef<ReturnType<typeof setTimeout> | null>(null);
  const [peerTyping, setPeerTyping] = useState<Record<string, boolean>>({});

  const notifyTyping = (isTyping: boolean) => {
    if (!convId) return;
    const now = Date.now();
    if (isTyping && now - lastSentRef.current < DECLARE_INTERVAL_MS) return;
    lastSentRef.current = now;
    declareTyping(convId, isTyping).catch(() => {
      // 声明失败不影响输入；退避交给服务端广播（失败可忽略）
    });
  };

  /** 输入回调：节流声明 typing=true，并重置停止计时 */
  const onInput = () => {
    notifyTyping(true);
    if (stopTimerRef.current) clearTimeout(stopTimerRef.current);
    stopTimerRef.current = setTimeout(() => notifyTyping(false), STOP_DELAY_MS);
  };

  useEffect(() => {
    // 切换会话时清空对端 typing 状态与定时器
    setPeerTyping({});
    return () => {
      if (stopTimerRef.current) clearTimeout(stopTimerRef.current);
      notifyTyping(false);
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [convId]);

  return { peerTyping, setPeerTyping, onInput };
}
