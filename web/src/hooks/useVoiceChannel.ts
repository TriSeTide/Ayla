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
import { useCallback, useEffect, useLayoutEffect, useRef, useState } from "react";
import { ApiError } from "../api/client";
import * as voiceApi from "../api/voice";
import { ensureUsers } from "../api/users";
import { voiceLiveKit } from "../livekit/client";
import { voiceDirectWsUrl, voiceMediaTransport } from "../livekit/wsRelayRoom";
import { useAuthStore } from "../stores/auth";
import { useVoiceStore } from "../stores/voice";
import { voiceWS } from "../ws/voice";
import { chatWS } from "../ws/chat";
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
  /** Explicit media recovery; ordinary navigation reuses an established session. */
  force?: boolean;
}

export function useVoiceChannel(selectedChannelId?: string | null) {
  const currentChannelId = useVoiceStore((s) => s.currentChannelId);
  const livekit = useVoiceStore((s) => s.livekit);
  const micEnabled = useVoiceStore((s) => s.micEnabled);
  const [joining, setJoining] = useState(false);
  const [error, setErrorState] = useState<string | null>(null);

  /** 防止卸载后异步回写 */
  const mountedRef = useRef(true);
  const selectionOwnerRef = useRef<object>({});
  // Local UI updates follow the newest call; session ownership lives in the shared runtime.
  const joinGenerationRef = useRef(0);
  const selectChannel = useCallback((channelId: string | null) => {
    voiceSessionRuntime.selectChannel(selectionOwnerRef.current, channelId);
    const mediaChannel = voiceSessionRuntime.mediaChannel();
    // Cancel a provisional media connection immediately. Established sessions remain
    // available until the next authorized join succeeds or the user explicitly leaves.
    if (mediaChannel && mediaChannel !== channelId && useVoiceStore.getState().currentChannelId !== mediaChannel) {
      voiceSessionRuntime.setMediaChannel(null);
      void voiceLiveKit.disconnect();
    }
  }, []);
  useLayoutEffect(() => {
    if (selectedChannelId !== undefined) selectChannel(selectedChannelId);
  }, [selectedChannelId, selectChannel]);
  useEffect(() => {
    mountedRef.current = true;
    return () => {
      mountedRef.current = false;
    };
  }, []);

  const stopHeartbeat = useCallback(() => {
    voiceSessionRuntime.stopHeartbeat();
  }, []);

  /** 本地重置到未加入态（心跳 403 / 被踢 / 房间删除后的统一收尾） */
  const resetLocal = useCallback((expectedChannelId?: string, preserveSelection = false) => {
    const channelId = expectedChannelId ?? useVoiceStore.getState().currentChannelId ?? voiceSessionRuntime.mediaChannel();
    if (!preserveSelection) {
      voiceSessionRuntime.cancelSelection();
      joinGenerationRef.current += 1;
      if (mountedRef.current) setJoining(false);
    }
    if (channelId && voiceSessionRuntime.isHeartbeating(channelId)) stopHeartbeat();
    if (channelId) voiceWS.unsubscribe(channelId);
    if (channelId && voiceSessionRuntime.ownsMedia(channelId)) {
      voiceSessionRuntime.setMediaChannel(null);
      void voiceLiveKit.disconnect();
    }
    if (channelId === useVoiceStore.getState().currentChannelId) useVoiceStore.getState().leaveChannelLocal();
    if (channelId === useSessionActivityStore.getState().voiceSession?.sessionId) {
      useAuthStore.getState().setMediaActivity({ kind: "voice", active: false });
      useSessionActivityStore.getState().clear("voice");
    }
  }, [stopHeartbeat]);

  const startHeartbeat = useCallback(
    (channelId: string) => {
      voiceSessionRuntime.startHeartbeat(channelId, (reason) => {
        const nextChannel = voiceSessionRuntime.selectedChannelId();
        const switchingAway = nextChannel != null && nextChannel !== channelId;
        resetLocal(channelId, switchingAway);
        if (!switchingAway && mountedRef.current) {
          setErrorState(reason === "deleted" ? "语音房已被删除" : "你已被移出语音频道（心跳超时）");
        }
      });
    },
    [resetLocal],
  );

  /** 成员对账：GET members/ 全量替换（join 后铺底 / WS 重连后补偿） */
  const reconcile = useCallback(async (channelId: string) => {
    const revision = voiceSessionRuntime.currentRevision();
    const list = await voiceApi.listVoiceChannelMembers(channelId);
    if (useVoiceStore.getState().currentChannelId !== channelId || !voiceSessionRuntime.isRevisionCurrent(revision)) return;
    useVoiceStore.getState().reconcileMembers(list);
    // Visible VoiceMemberRow instances fetch their own profiles; runtime facts
    // must not fan out a profile request for every member in the channel.
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

  // 被移出（踢出/超时清理）或房间删除 → 强制本地退出（后端已删成员，这里只收本地资源）。
  // 被踢：kick_member 广播 voice.state left（被踢者自己），自己仍订阅着该频道故能收到；
  // 删除：broadcast_channel_deleted 走 chat WS 目录组，房内成员据此退出。
  useEffect(() => {
    const offVoiceState = voiceWS.onFrame((frame) => {
      if (frame.type !== "voice.state") return;
      const d = frame.data;
      const me = useAuthStore.getState().currentUser?.id;
      const channelId = useVoiceStore.getState().currentChannelId;
      if (d.state === "left" && me && channelId === d.channel_id && String(d.user_id) === String(me)) {
        const nextChannel = voiceSessionRuntime.selectedChannelId();
        const switchingAway = nextChannel != null && nextChannel !== channelId;
        resetLocal(channelId, switchingAway);
        if (!switchingAway && mountedRef.current) setErrorState("你已被移出语音频道");
      }
    });
    const offChat = chatWS.onFrame((frame) => {
      if (frame.type !== "voice.channel.deleted") return;
      const deletedId = String(frame.data.channel_id);
      const selected = voiceSessionRuntime.selectedChannelId();
      if (selected === deletedId) voiceSessionRuntime.cancelSelection();
      const channelId = useVoiceStore.getState().currentChannelId;
      if (channelId === deletedId) {
        resetLocal(channelId, selected != null && selected !== channelId);
        if (mountedRef.current) setErrorState("语音房已被删除");
      }
    });
    return () => {
      offVoiceState();
      offChat();
    };
  }, [resetLocal]);

  // heartbeat 归 runtime owner；页面卸载不停止，明确 leave 才释放。


  /** 加入频道（重复 join 同频道幂等安全） */
  const join = useCallback(
    async (channelId: string, options: JoinOptions = {}) => {
      selectChannel(channelId);
      const generation = ++joinGenerationRef.current;
      setJoining(true);
      setErrorState(null);
      try {
        await voiceSessionRuntime.runJoin(selectionOwnerRef.current, channelId, async (ownsSelection) => {
          const auth = useAuthStore.getState();
          const accountId = auth.currentUser?.id ?? null;
          const accessToken = auth.accessToken;
          const sameAccount = () => (useAuthStore.getState().currentUser?.id ?? null) === accountId
            && useAuthStore.getState().accessToken != null;
          const isCurrent = () => mountedRef.current && ownsSelection() && sameAccount();
          if (!isCurrent()) return;
          const initial = useVoiceStore.getState();
          if (!options.force && initial.currentChannelId === channelId && initial.livekit !== "failed") return;
          const previousChannelId = initial.currentChannelId;
          let joined = false;
          let committed = false;
          let failure: unknown;
          const clearProjection = (id: string) => {
            if (!sameAccount()) return;
            if (useVoiceStore.getState().currentChannelId === id) useVoiceStore.getState().leaveChannelLocal();
            useVoiceStore.getState().patchChannel(id, { mine: false });
            if (sameAccount() && useSessionActivityStore.getState().voiceSession?.sessionId === id) {
              useAuthStore.getState().setMediaActivity({ kind: "voice", active: false });
              useSessionActivityStore.getState().clear("voice", "idle");
            }
          };
          const releaseMedia = async (id: string) => {
            if (!voiceSessionRuntime.ownsMedia(id)) return;
            voiceSessionRuntime.setMediaChannel(null);
            await voiceLiveKit.disconnect();
          };
          try {
            // REST changes membership. Wait for its receipt even if superseded, then
            // compensate that exact channel before the next queued selection can join.
            const joinResult = await voiceApi.joinVoiceChannel(channelId);
            joined = true;
            if (!isCurrent()) return;
            if (previousChannelId && previousChannelId !== channelId) {
              if (voiceSessionRuntime.isHeartbeating(previousChannelId)) stopHeartbeat();
              voiceWS.unsubscribe(previousChannelId);
              await voiceApi.leaveVoiceChannel(previousChannelId, accessToken ?? undefined);
              await releaseMedia(previousChannelId);
              clearProjection(previousChannelId);
              if (!isCurrent()) return;
            }
            useAuthStore.getState().setMediaActivity({ kind: "voice", active: true, roomId: Number(channelId) });
            useSessionActivityStore.getState().upsert({
              kind: "voice", sessionId: channelId,
              sourceRoute: typeof window !== "undefined" && window.location.pathname.startsWith("/group/")
                ? window.location.pathname : `/voice/${encodeURIComponent(channelId)}`,
              owner: accountId,
              title: useVoiceStore.getState().channels.find((channel) => channel.id === channelId)?.name ?? "语音房",
              status: "connecting", lastError: null,
            });
            useVoiceStore.getState().setLivekit("connecting");
            voiceSessionRuntime.setMediaChannel(channelId);
            // 传输方式二选一：WS 音频中继（默认）传直连地址（房间内部自动以
            // CF Tunnel 为回退候选）；livekit（回滚开关）用 join 返回的媒体参数。
            if (voiceMediaTransport() === "livekit") {
              await voiceLiveKit.connect(joinResult.ws_url, joinResult.token);
            } else {
              const mediaToken = useAuthStore.getState().accessToken;
              if (!mediaToken) throw new Error("登录状态失效，请重新登录");
              await voiceLiveKit.connect(voiceDirectWsUrl(channelId), mediaToken);
            }
            if (!isCurrent()) return;
            await voiceLiveKit.startAudio().catch(() => {});
            if (!isCurrent()) return;
            const wantMic = !(options.joinMuted ?? true);
            try {
              await voiceLiveKit.setMicrophoneEnabled(wantMic);
              if (!isCurrent()) return;
              useVoiceStore.getState().setMicEnabled(wantMic);
            } catch (error) {
              if (!isCurrent()) return;
              if (error instanceof Error && error.name === "AbortError") throw error;
              useVoiceStore.getState().setMicEnabled(false);
              if (wantMic) setErrorState("需要麦克风权限，已在静音状态加入");
            }
            const members = await voiceApi.listVoiceChannelMembers(channelId);
            if (!isCurrent()) return;
            const retained = useVoiceStore.getState().currentChannelId === channelId ? useVoiceStore.getState().members : {};
            useVoiceStore.getState().enterChannel(channelId, members.map((member) => ({
              ...member, muted: retained[member.user_id]?.muted ?? false,
              volume: retained[member.user_id]?.volume ?? 100,
              locallyMuted: retained[member.user_id]?.locallyMuted ?? false,
              audioLevel: retained[member.user_id]?.audioLevel ?? 0,
            })));
            useVoiceStore.getState().patchChannel(channelId, { mine: true });
            useSessionActivityStore.getState().setStatus("voice", "connected");
            startHeartbeat(channelId);
            voiceWS.subscribe([channelId]);
            const me = useAuthStore.getState().currentUser;
            if (me) ensureUsers([me.id]);
            committed = true;
          } catch (error) {
            failure = error;
          } finally {
            if (joined && !committed) {
              try { await voiceApi.leaveVoiceChannel(channelId, accessToken ?? undefined); }
              catch (error) { failure ??= error; }
              try { await releaseMedia(channelId); }
              catch (error) { failure ??= error; }
              clearProjection(channelId);
            }
            if (failure && isCurrent()) {
              useVoiceStore.getState().setLivekit(joined ? "failed" : initial.livekit);
              setErrorState(failure instanceof ApiError && failure.status === 503 ? "语音服务未配置，暂不可用"
                : failure instanceof ApiError && failure.status === 404 ? "频道不存在"
                  : failure instanceof Error ? failure.message : "加入频道失败");
            }
          }
        });
      } finally {
        if (mountedRef.current && generation === joinGenerationRef.current) setJoining(false);
      }
    },
    [selectChannel, startHeartbeat, stopHeartbeat],
  );

  /** 离开频道（幂等）。
   *
   * 服务端先裁决：房主必须先转让（403）等拒绝在此抛出，本地状态
   * （心跳/媒体/成员）保持原样，由调用方展示错误并留在房间；只有
   * 服务端确认离开后才断开媒体并清理本地状态。
   */
  const leave = useCallback(async () => {
    const channelId = useVoiceStore.getState().currentChannelId;
    const auth = useAuthStore.getState();
    voiceSessionRuntime.cancelSelection();
    joinGenerationRef.current += 1;
    if (mountedRef.current) setJoining(false);
    await voiceSessionRuntime.runExclusive(async () => {
      if (!channelId) return;
      await voiceApi.leaveVoiceChannel(channelId, auth.accessToken ?? undefined);
      if (voiceSessionRuntime.isHeartbeating(channelId)) stopHeartbeat();
      voiceWS.unsubscribe(channelId);
      if (voiceSessionRuntime.ownsMedia(channelId)) {
        voiceSessionRuntime.setMediaChannel(null);
        await voiceLiveKit.disconnect();
      }
      if (useVoiceStore.getState().currentChannelId === channelId) useVoiceStore.getState().leaveChannelLocal();
      if ((useAuthStore.getState().currentUser?.id ?? null) !== (auth.currentUser?.id ?? null)) return;
      if (useSessionActivityStore.getState().voiceSession?.sessionId === channelId) {
        useAuthStore.getState().setMediaActivity({ kind: "voice", active: false });
        useSessionActivityStore.getState().clear("voice", "idle");
      }
      useVoiceStore.getState().patchChannel(channelId, { mine: false });
    });
  }, [stopHeartbeat]);

  /** 静音切换：乐观 UI + SDK 失败回滚（M5-3 §4.3） */
  const toggleMic = useCallback(async () => {
    const store = useVoiceStore.getState();
    const channelId = store.currentChannelId;
    const revision = voiceSessionRuntime.currentRevision();
    if (!channelId || (voiceSessionRuntime.selectedChannelId() != null && voiceSessionRuntime.selectedChannelId() !== channelId)) return;
    const next = !store.micEnabled;
    store.setMicEnabled(next); // 乐观
    try {
      await voiceLiveKit.setMicrophoneEnabled(next);
    } catch (e) {
      if (useVoiceStore.getState().currentChannelId !== channelId || !voiceSessionRuntime.isRevisionCurrent(revision)) return;
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
    if (channelId) await join(channelId, { joinMuted: !useVoiceStore.getState().micEnabled, force: true });
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
    /** 本地重置到未加入态（被踢/心跳超时/房间删除后的统一收尾；幂等） */
    resetLocal,
  };
}
