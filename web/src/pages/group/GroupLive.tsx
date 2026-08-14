/**
 * GroupLive —— 群内直播子界面（F4，R-G7）。
 *
 * 直接进入该群第一个直播间（无卡片列表）；上下滑切换范围 = **仅该群**（与一级直播
 * tab 的"全部可见"不同，R-G7/R-L3 明确区分）。无直播 → 空态 + 发起引导。
 *
 * 群内直播是 GroupPage 的 live 子界面（底栏已在顶部，无"底栏下滑走"进房动画，
 * 输入框直接显示）；宽屏同 ChannelSidebar 内容区。
 */
import { useCallback, useEffect, useState } from "react";
import * as liveApi from "../../api/live";
import type { LiveChannelDescriptor } from "../../api/types";
import { LiveRoomBody } from "../../components/live/LiveRoomBody";
import { NARROW_QUERY, useMediaQuery } from "../../hooks/useMediaQuery";
import { useLiveStore } from "../../stores/live";

export function GroupLive({ groupId, onExit }: { groupId: string; onExit: () => void }) {
  const isNarrow = useMediaQuery(NARROW_QUERY);
  const channel = useLiveStore((s) => s.current.channel);
  const [channels, setChannels] = useState<LiveChannelDescriptor[]>([]);
  const [currentId, setCurrentId] = useState<number | null>(null);
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    let cancelled = false;
    setLoading(true);
    liveApi
      .listLiveChannels()
      .then((list) => {
        if (cancelled) return;
        const mine = list.filter((c) => c.group === groupId);
        setChannels(mine);
        setCurrentId(mine[0]?.id ?? null);
        setLoading(false);
      })
      .catch(() => {
        if (!cancelled) {
          setChannels([]);
          setCurrentId(null);
          setLoading(false);
        }
      });
    return () => {
      cancelled = true;
    };
  }, [groupId]);

  const index = channels.findIndex((c) => c.id === currentId);
  const goPrev = useCallback(() => {
    if (index > 0) setCurrentId(channels[index - 1].id);
  }, [index, channels]);
  const goNext = useCallback(() => {
    if (index >= 0 && index < channels.length - 1) setCurrentId(channels[index + 1].id);
  }, [index, channels]);

  if (loading) {
    return (
      <div className="group-scene-placeholder">
        <div className="skeleton" style={{ height: 160, width: "80%" }} />
      </div>
    );
  }

  if (channels.length === 0 || currentId == null) {
    return (
      <div className="group-scene-placeholder">
        <h3 className="placeholder-title">群内还没有直播</h3>
        <p className="placeholder-desc">发起本群的第一场直播吧</p>
        <button type="button" className="btn btn-ghost" onClick={onExit}>
          返回聊天
        </button>
      </div>
    );
  }

  return (
    <LiveRoomBody
      channelId={currentId}
      channel={channel}
      isNarrow={isNarrow}
      hasPrev={index > 0}
      hasNext={index >= 0 && index < channels.length - 1}
      onPrev={goPrev}
      onNext={goNext}
      onBack={onExit}
      onDeleted={onExit}
      inputEntered // 群内子界面无底栏下滑动画，输入框直接显示
    />
  );
}
