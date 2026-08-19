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
import { useSessionActivityStore } from "../stores/sessionActivity";
import { voiceSessionRuntime, VOICE_HEARTBEAT_INTERVAL_MS } from "../runtime/voiceSessionRuntime";

export { VOICE_HEARTBEAT_INTERVAL_MS };

/**
 * presence 心跳间隔（毫秒）。
 * 后端 VOICE_MEMBER_TIMEOUT_SECONDS 默认 120s，取其 1/3 量级 → 40s；
 * 读不到后端配置时用此前端常量（M5-3 §4.2）。
 */
export interface JoinOptions {
  /** 加入时静音（默认 true：进频道默认关麦，避免误入即广播环境音，M5-3 §9） */
  joinMuted?: boolean;
}

export function useVoiceChannel() {
  const currentChannelId = useVoiceStore((s) => s.currentChannelId);
  const livekit = useVoiceStore((s) => s.livekit);
  const channels = useVoiceStore((s) => s.channels);
  const micEnabled = useVoiceStore((s) => s.micEnabled);
  const [joining, setJoining] = useState(false);
  const [error, setErrorState] = useState<string | null>(null);

  /** 防止卸载后异步回写 */
  const mountedRef = useRef(true);
  useEffect(() => {
    mountedRef.current = true;
    return () => {
      mountedRef.current = false;
    };
  }, []);

  const stopHeartbeat = useCallback(() => {
    voiceSessionRuntime.stopHeartbeat();
  }, []);

  /** 本地重置到未加入态（心跳 403 / 离开后的统一收尾） */
  const resetLocal = useCallback(() => {
    stopHeartbeat();
    const channelId = useVoiceStore.getState().currentChannelId;
    if (channelId) voiceWS.unsubscribe(channelId);
    useVoiceStore.getState().leaveChannelLocal();
    useAuthStore.getState().setMediaActivity({ kind: "voice", active: false });
    useSessionActivityStore.getState().clear("voice");
  }, [stopHeartbeat]);

  const startHeartbeat = useCallback(
    (channelId: string) => {
      voiceSessionRuntime.startHeartbeat(channelId, () => {
        resetLocal();
        if (mountedRef.current) setErrorState("你已被移出语音频道（心跳超时）");
      });
    },
    [resetLocal],
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
      // 本地麦克风实时音量 → store（自己的成员卡片显示音量跳动；未开麦回调 0）
      onLocalAudioLevel: (level) => {
        useVoiceStore.getState().setLocalAudioLevel(level);
      },
      // 远端成员实时音量快照 → store（成员行显示"谁在说话"的音量跳动）
      onRemoteAudioLevels: (levels) => {
        useVoiceStore.getState().setRemoteAudioLevels(levels);
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

  // heartbeat 归 runtime owner；页面卸载不停止，明确 leave 才释放。


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
          useAuthStore.getState().setMediaActivity({ kind: "voice", active: false });
        }
        // 3. LiveKit 连接
        useAuthStore.getState().setMediaActivity({ kind: "voice", active: true, roomId: Number(channelId) });
        useSessionActivityStore.getState().upsert({
          kind: "voice",
          sessionId: channelId,
          sourceRoute:
            typeof window !== "undefined" && window.location.pathname.startsWith("/group/")
              ? window.location.pathname
              : `/voice/${encodeURIComponent(channelId)}`,
          owner: useAuthStore.getState().currentUser?.id ?? null,
          title: channels.find((c) => c.id === channelId)?.name ?? "语音房",
          status: "connecting",
          lastError: null,
        });
        useVoiceStore.getState().setLivekit("connecting");
        try {
          await voiceLiveKit.connect(joinResult.ws_url, joinResult.token);
          // 在用户手势链内恢复远端音频播放（浏览器 autoplay 政策）
          await voiceLiveKit.startAudio().catch(() => {});
        } catch (mediaErr) {
          // join 成功但媒体连接失败 → 回滚成员状态
          await voiceApi.leaveVoiceChannel(channelId).catch(() => {});
          useAuthStore.getState().setMediaActivity({ kind: "voice", active: false });
          useVoiceStore.getState().setLivekit("failed");
          useSessionActivityStore.getState().setStatus("voice", "failed", "媒体连接失败");
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
        useSessionActivityStore.getState().setStatus("voice", "connected");
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
    [channels, reconcile, startHeartbeat, stopHeartbeat],
  );

  /** 离开频道（幂等）。
   *
   * 服务端先裁决：房主必须先转让（403）等拒绝在此抛出，本地状态
   * （心跳/媒体/成员）保持原样，由调用方展示错误并留在房间；只有
   * 服务端确认离开后才断开媒体并清理本地状态。
   */
  const leave = useCallback(async () => {
    const channelId = useVoiceStore.getState().currentChannelId;
    if (!channelId) return;
    await voiceApi.leaveVoiceChannel(channelId);
    stopHeartbeat();
    voiceWS.unsubscribe(channelId);
    await voiceLiveKit.disconnect();
    useVoiceStore.getState().leaveChannelLocal();
    useAuthStore.getState().setMediaActivity({ kind: "voice", active: false });
    useSessionActivityStore.getState().clear("voice", "idle");
    useVoiceStore.getState().patchChannel(channelId, { mine: false });
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

  /** 远端成员本地播放静音（喇叭按钮：一键静音/一键恢复；不改变 volume 设定值） */
  const setMemberLocallyMuted = useCallback((userId: string, muted: boolean) => {
    useVoiceStore.getState().setMemberLocallyMuted(userId, muted);
    const m = useVoiceStore.getState().members[userId];
    if (m) voiceLiveKit.setRemoteVolume(userId, muted ? 0 : m.volume / 100);
  }, []);

  /** 本地麦克风音量（0~100，100 = 原始）：拖滑块实时改自己说话的响度（本地偏好，不落库） */
  const setLocalVolume = useCallback((volume: number) => {
    useVoiceStore.getState().setLocalVolume(volume);
    void voiceLiveKit.setLocalVolume(volume / 50).catch(() => {
      // 媒体层失败静默（未连接时只记录 store 值，开麦后由监测懒挂载）
    });
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
    setMemberLocallyMuted,
    setLocalVolume,
    rejoin,
    reconcile,
  };
}
