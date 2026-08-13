/**
 * useVoiceChannel：加入/离开/心跳/成员同步编排（M5-3 §4.2 / §4.4）。
 *
 * 加入流程：
 *   1. POST join/ → {token, ws_url}；503 → "语音服务未配置"终止（不进媒体连接）
 *   2. LiveKit 连接房间；connected 后：按选项开/关麦、启动 presence 心跳、
 *      Voice WS subscribe（WS 单例未连则先连）
 *   3. 成员铺底：GET members/ 对账 + 懒拉用户资料
 * 离开流程：POST leave/ → 断开 LiveKit → 停止心跳 → WS 本地退订 → store 清空
 * 异常路径：
 *   - join 成功但 LiveKit 连接失败 → 调 leave/ 回滚成员状态
 *   - 心跳 403（被超时清理）→ 视为已被移出，本地重置到未加入态
 * 断线恢复（双层）：
 *   - 应用 WS：VoiceWSClient 指数退避自动重连 + 重 subscribe + onReconnected 对账
 *   - LiveKit 媒体：SDK 自连；Reconnecting → "媒体重连中"（成员面板不清空）；
 *     Disconnected → livekit="failed"，UI 给"重新加入"（不自动 leave/）
 */
import { useCallback, useEffect, useRef, useState } from "react";
import { ApiError } from "../api/client";
import * as voiceApi from "../api/voice";
import { ensureUsers } from "../api/users";
import { voiceLiveKit } from "../livekit/client";
import { useAuthStore } from "../stores/auth";
import { useVoiceStore } from "../stores/voice";
import { voiceWS } from "../ws/voice";

/**
 * presence 心跳间隔（毫秒）。
 * 后端 VOICE_MEMBER_TIMEOUT_SECONDS 默认 120s，取其 1/3 量级 → 40s；
 * 读不到后端配置时用此前端常量（M5-3 §4.2）。
 */
export const VOICE_HEARTBEAT_INTERVAL_MS = 40_000;

export interface JoinOptions {
  /** 加入时静音（默认 true：进频道默认关麦，避免误入即广播环境音，M5-3 §9） */
  joinMuted?: boolean;
}

export function useVoiceChannel() {
  const currentChannelId = useVoiceStore((s) => s.currentChannelId);
  const livekit = useVoiceStore((s) => s.livekit);
  const micEnabled = useVoiceStore((s) => s.micEnabled);
  const [joining, setJoining] = useState(false);
  const [error, setErrorState] = useState<string | null>(null);

  const heartbeatRef = useRef<ReturnType<typeof setInterval> | null>(null);
  /** 防止卸载后异步回写 */
  const mountedRef = useRef(true);
  useEffect(() => {
    mountedRef.current = true;
    return () => {
      mountedRef.current = false;
    };
  }, []);

  const stopHeartbeat = useCallback(() => {
    if (heartbeatRef.current) {
      clearInterval(heartbeatRef.current);
      heartbeatRef.current = null;
    }
  }, []);

  /** 本地重置到未加入态（心跳 403 / 离开后的统一收尾） */
  const resetLocal = useCallback(() => {
    stopHeartbeat();
    const channelId = useVoiceStore.getState().currentChannelId;
    if (channelId) voiceWS.unsubscribe(channelId);
    useVoiceStore.getState().leaveChannelLocal();
  }, [stopHeartbeat]);

  const startHeartbeat = useCallback(
    (channelId: string) => {
      stopHeartbeat(); // 重复加入不叠加定时器
      heartbeatRef.current = setInterval(() => {
        voiceApi.heartbeatVoiceChannel(channelId).catch((e) => {
          if (e instanceof ApiError && e.status === 403) {
            // 非成员（被超时清理）→ 视为已被移出，本地重置
            resetLocal();
            if (mountedRef.current) setErrorState("你已被移出语音频道（心跳超时）");
          }
          // 其他错误（网络抖动）下一轮再试，不打断
        });
      }, VOICE_HEARTBEAT_INTERVAL_MS);
    },
    [resetLocal, stopHeartbeat],
  );

  /** 成员对账：GET members/ 全量替换（join 后铺底 / WS 重连后补偿） */
  const reconcile = useCallback(async (channelId: string) => {
    const list = await voiceApi.listVoiceChannelMembers(channelId);
    useVoiceStore.getState().reconcileMembers(list);
    ensureUsers(list.map((m) => m.user_id));
  }, []);

  // LiveKit 事件 → store（挂载一次；voiceLiveKit 是单例）
  useEffect(() => {
    voiceLiveKit.setEvents({
      onStateChange: (state) => {
        useVoiceStore.getState().setLivekit(state);
        if (state === "connected") {
          useVoiceStore.getState().setMicEnabled(voiceLiveKit.isMicrophoneEnabled());
        }
      },
      // 远端参与者的应用层成员事实以 voice.state 为准；LiveKit 事件只做媒体层提示，
      // 成员表不动（断线窗口由 members/ 对账补偿）。
      onTrackMuted: (identity, muted) => {
        const s = useVoiceStore.getState();
        const existing = s.members[identity];
        if (existing) {
          s.applyVoiceState(
            s.currentChannelId ?? "",
            identity,
            muted ? "muted" : "unmuted",
            new Date().toISOString(),
          );
        }
      },
    });
  }, []);

  // WS 重连后对账（voice.state 无补发语义）
  useEffect(() => {
    const off = voiceWS.onReconnected(() => {
      const channelId = useVoiceStore.getState().currentChannelId;
      if (channelId) void reconcile(channelId).catch(() => {});
    });
    return off;
  }, [reconcile]);

  // 组件卸载：停心跳（不主动 leave/——页面切换不等于离开频道由路由设计决定；
  // 本页面是唯一语音入口，卸载即离开在 VoicePage 层显式处理）
  useEffect(() => stopHeartbeat, [stopHeartbeat]);

  /** 加入频道（重复 join 同频道幂等安全） */
  const join = useCallback(
    async (channelId: string, options: JoinOptions = {}) => {
      const joinMuted = options.joinMuted ?? true;
      setJoining(true);
      setErrorState(null);
      const store = useVoiceStore.getState();
      try {
        // 1. REST join（拿媒体凭据；503 = LiveKit 未配置，终止不进媒体连接）
        const joinResult = await voiceApi.joinVoiceChannel(channelId);
        // 2. 切频道：若已在其他频道，先本地清掉（leave/ 由后端 join 广播驱动他人视图；
        //    自己旧频道的 leave 显式调一次保证幂等）
        const prevChannelId = store.currentChannelId;
        if (prevChannelId && prevChannelId !== channelId) {
          stopHeartbeat();
          voiceWS.unsubscribe(prevChannelId);
          await voiceApi.leaveVoiceChannel(prevChannelId).catch(() => {});
          await voiceLiveKit.disconnect();
          useVoiceStore.getState().leaveChannelLocal();
        }
        // 3. LiveKit 连接
        useVoiceStore.getState().setLivekit("connecting");
        try {
          await voiceLiveKit.connect(joinResult.ws_url, joinResult.token);
        } catch (mediaErr) {
          // join 成功但媒体连接失败 → 回滚成员状态
          await voiceApi.leaveVoiceChannel(channelId).catch(() => {});
          useVoiceStore.getState().setLivekit("failed");
          throw mediaErr;
        }
        // 4. 默认关麦加入（用户勾选则开麦）
        const wantMic = !joinMuted;
        try {
          await voiceLiveKit.setMicrophoneEnabled(wantMic);
          useVoiceStore.getState().setMicEnabled(wantMic);
        } catch {
          // 麦克风权限被拒：保持关麦，不阻断加入
          useVoiceStore.getState().setMicEnabled(false);
          if (wantMic && mountedRef.current) {
            setErrorState("需要麦克风权限，已在静音状态加入");
          }
        }
        // 5. 成员铺底 + 心跳 + WS 订阅
        await reconcile(channelId);
        useVoiceStore.getState().enterChannel(
          channelId,
          Object.values(useVoiceStore.getState().members),
        );
        useVoiceStore.getState().patchChannel(channelId, { mine: true });
        startHeartbeat(channelId);
        voiceWS.subscribe([channelId]);
        // 自己的资料预热
        const me = useAuthStore.getState().currentUser;
        if (me) ensureUsers([me.id]);
      } catch (e) {
        if (!mountedRef.current) return;
        if (e instanceof ApiError && e.status === 503) {
          setErrorState("语音服务未配置，暂不可用");
        } else if (e instanceof ApiError && e.status === 404) {
          setErrorState("频道不存在");
        } else {
          setErrorState(e instanceof Error ? e.message : "加入频道失败");
        }
      } finally {
        if (mountedRef.current) setJoining(false);
      }
    },
    [reconcile, startHeartbeat, stopHeartbeat],
  );

  /** 离开频道（幂等） */
  const leave = useCallback(async () => {
    const channelId = useVoiceStore.getState().currentChannelId;
    if (!channelId) return;
    stopHeartbeat();
    voiceWS.unsubscribe(channelId);
    await voiceLiveKit.disconnect();
    useVoiceStore.getState().leaveChannelLocal();
    try {
      await voiceApi.leaveVoiceChannel(channelId);
      useVoiceStore.getState().patchChannel(channelId, { mine: false });
    } catch {
      // leave 失败（如频道已不存在）不阻塞本地状态——成员身份以服务端正本为准，
      // 心跳已停，超时后服务端自动清理
    }
  }, [stopHeartbeat]);

  /** 静音切换：乐观 UI + SDK 失败回滚（M5-3 §4.3） */
  const toggleMic = useCallback(async () => {
    const store = useVoiceStore.getState();
    const next = !store.micEnabled;
    store.setMicEnabled(next); // 乐观
    try {
      await voiceLiveKit.setMicrophoneEnabled(next);
    } catch (e) {
      store.setMicEnabled(!next); // 回滚
      if (mountedRef.current) {
        setErrorState(
          e instanceof Error ? `切换麦克风失败：${e.message}` : "切换麦克风失败",
        );
      }
    }
  }, []);

  /** 远端成员音量（本地播放偏好，不落库） */
  const setMemberVolume = useCallback((userId: string, volume: number) => {
    useVoiceStore.getState().setMemberVolume(userId, volume);
    voiceLiveKit.setRemoteVolume(userId, volume / 100);
  }, []);

  /** 媒体最终断线后的"重新加入"（走 join 幂等路径） */
  const rejoin = useCallback(async () => {
    const channelId = useVoiceStore.getState().currentChannelId;
    if (channelId) await join(channelId, { joinMuted: !useVoiceStore.getState().micEnabled });
  }, [join]);

  return {
    currentChannelId,
    livekit,
    micEnabled,
    joining,
    error,
    clearError: () => setErrorState(null),
    join,
    leave,
    toggleMic,
    setMemberVolume,
    rejoin,
    reconcile,
  };
}
