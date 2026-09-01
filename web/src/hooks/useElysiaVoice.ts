/**
 * useElysiaVoice：爱莉语音通话生命周期编排（M5-3 §4.5，对齐 M4-5 §5.2）。
 *
 * - ensureCall：POST /elysia/voice-calls/ 创建/复用（reused=true 是单并发正常路径）；
 *   创建/复用成功后后端自动启动 observer WS 订阅（voice_observer），通话状态与
 *   转写投影改为**事件驱动**（elysia.voice.call.status / elysia.voice.projected 帧），
 *   本 hook 只消费事件，不再 5s/10s 轮询；
 * - 一次性对账：ensureCall 成功后 POST .../poll/ 一次（拿 projected_total 初始化
 *   「已投影 N 条」计数；poll 接口保留为断线/进程重启兜底，不再是周期请求）；
 * - 文本注入：空文本前端拦截不发；502 → "爱莉侧不可用"
 * - 结束：POST .../end/（幂等，重复点击安全）→ 停止事件订阅
 *
 * 不伪造：没有 final transcript 就没有爱莉发言；前端无本地生成"爱莉说：..."的路径。
 */
import { useCallback, useEffect, useRef, useState } from "react";
import { ApiError } from "../api/client";
import * as voiceApi from "../api/voice";
import type { ElysiaVoiceCallStatus } from "../api/types";
import { chatWS } from "../ws/chat";

/** 通话终态（停止事件订阅，允许重新创建） */
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

  const mountedRef = useRef(true);
  useEffect(() => {
    mountedRef.current = true;
    return () => {
      mountedRef.current = false;
    };
  }, []);

  /** 当前通话 id（ref 供事件回调取最新值，避免反复重建订阅） */
  const callIdRef = useRef<string | null>(null);
  useEffect(() => {
    callIdRef.current = call?.call_id ?? null;
  }, [call?.call_id]);

  /** chat WS 事件订阅句柄（elysia.voice.* 帧） */
  const offEventsRef = useRef<(() => void) | null>(null);

  const stopEvents = useCallback(() => {
    offEventsRef.current?.();
    offEventsRef.current = null;
  }, []);

  const mapError = useCallback((e: unknown, fallback: string): string => {
    if (e instanceof ApiError) {
      if (e.status === 503) return e.message || "爱莉语音未配置或已禁用";
      if (e.status === 502) return "爱莉侧不可用";
      return e.message;
    }
    return e instanceof Error ? e.message : fallback;
  }, []);

  /** 订阅通话事件帧：状态帧覆盖 call，投影帧覆盖计数 |
   * 终态帧到达后停止订阅（observer 已停止，无后续事件）。
   * callId 匹配走 callIdRef（事件回调取最新值，避免反复重建订阅）。 */
  const startEvents = useCallback(() => {
    stopEvents();
    offEventsRef.current = chatWS.onFrame((frame) => {
      if (frame.type === "elysia.voice.call.status") {
        const next = frame.data.call;
        if (callIdRef.current === null || next.call_id !== callIdRef.current) return;
        setCall(next);
        if (isTerminal(next.state)) stopEvents();
      } else if (frame.type === "elysia.voice.projected") {
        const d = frame.data;
        if (callIdRef.current === null || d.call_id !== callIdRef.current) return;
        setProjectedTotal(d.projected_total);
      }
    });
  }, [stopEvents]);

  /** 一次性对账：拉当前累计投影计数（兜底；非周期请求） */
  const reconcileProjected = useCallback(async (callId: string) => {
    try {
      const result = await voiceApi.pollElysiaVoiceCall(callId);
      if (!mountedRef.current) return;
      setProjectedTotal((prev) => Math.max(prev, result.projected_total));
    } catch {
      // 对账失败保持现状（下次事件/面板重开再对账）
    }
  }, []);

  /** 创建/复用通话（面板打开时调用） */
  const ensureCall = useCallback(async () => {
    setBusy(true);
    setErrorState(null);
    try {
      const result = await voiceApi.createElysiaVoiceCall();
      if (!mountedRef.current) return;
      setCall(result.call);
      setReused(result.reused);
      if (!isTerminal(result.call.state)) {
        startEvents();
        // 一次性对账：初始化投影计数（事件驱动前的历史投影）
        void reconcileProjected(result.call.call_id);
      }
    } catch (e) {
      if (mountedRef.current) setErrorState(mapError(e, "创建爱莉通话失败"));
    } finally {
      if (mountedRef.current) setBusy(false);
    }
  }, [mapError, reconcileProjected, startEvents]);

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
      stopEvents();
      if (mountedRef.current) {
        setCall((prev) => (prev ? { ...prev, state: "ended", connected: false } : prev));
      }
    } catch (e) {
      if (mountedRef.current) setErrorState(mapError(e, "结束通话失败"));
    } finally {
      if (mountedRef.current) setBusy(false);
    }
  }, [call?.call_id, mapError, stopEvents]);

  // active=false（面板关闭）→ 停事件订阅（不结束通话：通话生命周期由用户显式控制）
  useEffect(() => {
    if (!active) stopEvents();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [active]);

  // 卸载清理订阅
  useEffect(() => stopEvents, [stopEvents]);

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
