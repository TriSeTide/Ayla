/**
 * LiveRoomPage —— 直播间（路由 /live/:channelId，M5-4 基础上 F4 扩展）。
 *
 * F4 增量：
 * - 进房动画：底栏下滑走（shell store）+ 输入框滑入（useEnterRoomAnimation）；
 * - 切换直播间：窄屏上下滑 / 宽屏按钮 + 键盘 ↑↓，范围 = **全部可见直播间**
 *   （公开 + 好友 + 已加入群，与群内直播"仅该群"不同，R-L3）；
 * - 切换时 HLS 重连（useLiveRoom 依赖 channelId 变化自动重进房）+ 弹幕输入框保持。
 *
 * 核心渲染复用 LiveRoomBody（播放器三态 + 弹幕 + 切换控件）。
 */
import { useEffect, useMemo, useRef, useState } from "react";
import { useNavigate, useParams } from "react-router-dom";
import * as liveApi from "../api/live";
import type { LiveChannelDescriptor } from "../api/types";
import { LiveRoomBody } from "../components/live/LiveRoomBody";
import { NARROW_QUERY, useMediaQuery } from "../hooks/useMediaQuery";
import { useEnterRoomAnimation } from "../hooks/useEnterRoomAnimation";
import { useLiveStore } from "../stores/live";
import { useShellStore } from "../stores/shell";

export function LiveRoomPage() {
  const navigate = useNavigate();
  const params = useParams<{ channelId: string }>();
  const channelId = Number(params.channelId);
  const validId = Number.isInteger(channelId) && channelId > 0;
  const isNarrow = useMediaQuery(NARROW_QUERY);
  const { inputEntered } = useEnterRoomAnimation();

  const channel = useLiveStore((s) => s.current.channel);
  const [ordered, setOrdered] = useState<LiveChannelDescriptor[]>([]);
  const loadedRef = useRef(false);

  // 非法 id 回大厅
  useEffect(() => {
    if (!validId) navigate("/live", { replace: true });
  }, [validId, navigate]);

  // 进房动画：底栏下滑走（R-L2 方向纪律，与进群"上移"相反）；退房复位
  useEffect(() => {
    if (!validId) return;
    useShellStore.getState().setBottomTabsLeaving(true);
    return () => useShellStore.getState().setBottomTabsLeaving(false);
  }, [validId]);

  // 切换范围 = 全部可见直播间（一次性拉列表作为有序上下文；失败则无切换能力）
  useEffect(() => {
    if (!validId || loadedRef.current) return;
    loadedRef.current = true;
    liveApi
      .listLiveChannels()
      .then((list) => setOrdered(list))
      .catch(() => setOrdered([]));
  }, [validId]);

  const index = useMemo(() => ordered.findIndex((c) => c.id === channelId), [ordered, channelId]);
  const hasPrev = index > 0;
  const hasNext = index >= 0 && index < ordered.length - 1;

  const goPrev = () => {
    if (index > 0) navigate(`/live/${ordered[index - 1].id}`, { replace: true });
  };
  const goNext = () => {
    if (index >= 0 && index < ordered.length - 1) navigate(`/live/${ordered[index + 1].id}`, { replace: true });
  };

  if (!validId) return null;

  return (
    <LiveRoomBody
      channelId={channelId}
      channel={channel}
      isNarrow={isNarrow}
      hasPrev={hasPrev}
      hasNext={hasNext}
      onPrev={goPrev}
      onNext={goNext}
      onBack={() => navigate("/live")}
      onDeleted={() => navigate("/live")}
      inputEntered={inputEntered}
    />
  );
}
