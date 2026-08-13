/**
 * useElysiaVoice：爱莉语音通话生命周期编排（M5-3 §4.5，对齐 M4-5 §5.2）。
 *
 * - ensureCall：POST /elysia/voice-calls/ 创建/复用（reused=true 是单并发正常路径）
 * - 状态轮询：面板打开期间每 5s GET <call_id>/；ended/failed 停止并允许重建
 * - 文本注入：空文本前端拦截不发；502 → "爱莉侧不可用"
 * - 转写投影：面板打开期间每 10s POST .../poll/；语音页只显示"已投影 N 条"中性计数，
 *   爱莉发言渲染在聊天链（M5-2 爱莉会话），本 hook 不产生任何爱莉内容
 * - 结束：POST .../end/（幂等，重复点击安全）
 *
 * 不伪造：没有 final transcript 就没有爱莉发言；前端无本地生成"爱莉说：..."的路径。
 */
import { useCallback, useEffect, useRef, useState } from "react";
import { ApiError } from "../api/client";
import * as voiceApi from "../api/voice";
import type { ElysiaVoiceCallStatus } from "../api/types";

const STATUS_POLL_MS = 5_000;
const TRANSCRIPT_POLL_MS = 10_000;

/** 通话终态（停止轮询，允许重新创建） */
function isTerminal(state: string): boolean {
  return state === "ended" || state === "failed";
}

export function useElysiaVoice(active: boolean) {
  const [call, setCall] = useState<ElysiaVoiceCallStatus | null>(null);
  const [busy, setBusy] = useState(false);
  const [error, setErrorState] = useState<string | null>(null);
  /** 累计投影计数（中性展示，不含内容） */
  const [projectedTotal, setProjectedTotal] = useState(0);
  /** reused 标记：上次创建是否复用了活跃通话 */
  const [reused, setReused] = useState(false);

  const statusTimerRef = useRef<ReturnType<typeof setInterval> | null>(null);
  const pollTimerRef = useRef<ReturnType<typeof setInterval> | null>(null);
  const mountedRef = useRef(true);
  useEffect(() => {
    mountedRef.current = true;
    return () => {
      mountedRef.current = false;
    };
  }, []);

  const stopTimers = useCallback(() => {
    if (statusTimerRef.current) {
      clearInterval(statusTimerRef.current);
      statusTimerRef.current = null;
    }
    if (pollTimerRef.current) {
      clearInterval(pollTimerRef.current);
      pollTimerRef.current = null;
    }
  }, []);

  const mapError = useCallback((e: unknown, fallback: string): string => {
    if (e instanceof ApiError) {
      if (e.status === 503) return e.message || "爱莉语音未配置或已禁用";
      if (e.status === 502) return "爱莉侧不可用";
      return e.message;
    }
    return e instanceof Error ? e.message : fallback;
  }, []);

  const refreshStatus = useCallback(
    async (callId: string) => {
      try {
        const { call: next } = await voiceApi.getElysiaVoiceCall(callId);
        if (!mountedRef.current) return;
        setCall(next);
        if (isTerminal(next.state)) stopTimers();
      } catch {
        // 状态轮询失败（网络抖动）保持现状，下一轮再试
      }
    },
    [stopTimers],
  );

  const pollTranscripts = useCallback(async (callId: string) => {
    try {
      const result = await voiceApi.pollElysiaVoiceCall(callId);
      if (!mountedRef.current) return;
      setProjectedTotal((prev) => Math.max(prev, result.total));
    } catch {
      // poll 失败保持现状，下一轮再试
    }
  }, []);

  const startTimers = useCallback(
    (callId: string) => {
      stopTimers();
      statusTimerRef.current = setInterval(() => void refreshStatus(callId), STATUS_POLL_MS);
      pollTimerRef.current = setInterval(() => void pollTranscripts(callId), TRANSCRIPT_POLL_MS);
    },
    [pollTranscripts, refreshStatus, stopTimers],
  );

  /** 创建/复用通话（面板打开时调用） */
  const ensureCall = useCallback(async () => {
    setBusy(true);
    setErrorState(null);
    try {
      const result = await voiceApi.createElysiaVoiceCall();
      if (!mountedRef.current) return;
      setCall(result.call);
      setReused(result.reused);
      if (!isTerminal(result.call.state)) startTimers(result.call.call_id);
    } catch (e) {
      if (mountedRef.current) setErrorState(mapError(e, "创建爱莉通话失败"));
    } finally {
      if (mountedRef.current) setBusy(false);
    }
  }, [mapError, startTimers]);

  /** 文本注入（空文本前端拦截） */
  const sendText = useCallback(
    async (text: string): Promise<boolean> => {
      const trimmed = text.trim();
      if (!trimmed) {
        setErrorState("内容不能为空");
        return false;
      }
      const callId = call?.call_id;
      if (!callId) {
        setErrorState("通话未建立");
        return false;
      }
      setErrorState(null);
      try {
        await voiceApi.sendElysiaVoiceText(callId, trimmed);
        return true;
      } catch (e) {
        if (mountedRef.current) setErrorState(mapError(e, "发送失败"));
        return false;
      }
    },
    [call?.call_id, mapError],
  );

  /** 结束通话（幂等，重复点击安全） */
  const endCall = useCallback(async () => {
    const callId = call?.call_id;
    if (!callId) return;
    setBusy(true);
    try {
      await voiceApi.endElysiaVoiceCall(callId);
      stopTimers();
      if (mountedRef.current) {
        setCall((prev) => (prev ? { ...prev, state: "ended", connected: false } : prev));
      }
    } catch (e) {
      if (mountedRef.current) setErrorState(mapError(e, "结束通话失败"));
    } finally {
      if (mountedRef.current) setBusy(false);
    }
  }, [call?.call_id, mapError, stopTimers]);

  // active=false（面板关闭）→ 停轮询（不结束通话：通话生命周期由用户显式控制）
  useEffect(() => {
    if (!active) stopTimers();
    if (active && call && !isTerminal(call.state)) startTimers(call.call_id);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [active]);

  // 卸载清理定时器
  useEffect(() => stopTimers, [stopTimers]);

  return {
    call,
    busy,
    error,
    reused,
    projectedTotal,
    clearError: () => setErrorState(null),
    ensureCall,
    sendText,
    endCall,
    isTerminal: call ? isTerminal(call.state) : false,
  };
}
