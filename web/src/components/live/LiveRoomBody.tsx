/**
 * LiveRoomBody —— 直播间核心（F4，供一级直播 tab LiveRoomPage 与群内直播 GroupLive 复用）。
 *
 * 职责：播放器三态渲染 + 弹幕（列表/输入）+ 频道侧栏（封面列切换）；
 * 主播面板只由开播控制台显式开启。
 *
 * 频道切换（需求）：
 * - 宽屏：左侧频道封面列（LiveChannelRail）点击切换；
 * - 窄屏普通观看：**上下滑切换**（方案 §2.5 G3）——视频 + 弹幕区整体跟手滑动
 *   （旧滑出新滑入 250ms ease-out），顶栏与输入框固定不动、切换后顶栏内容再变；
 *   不使用封面预览卡。
 *
 * 切换范围由外层传入的有序频道列表决定（一级 = 全部可见；群内 = 仅该群）。
 * 切换 = 变更 channelId（onSelect）；useLiveRoom 依赖 channelId 自动销毁旧 HLS/断 WS
 * 重进房，播放组件始终单实例（滑动单元内仅当前槽一个真实播放器）。
 */
import { useCallback, useMemo, useRef, useState } from "react";
import { AnimatePresence, motion, useDragControls } from "framer-motion";
import type { PanHandler, PanInfo } from "framer-motion";
import type { LiveChannelDescriptor } from "../../api/types";
import { FavoriteButton } from "../FavoriteButton";
import { DanmakuInput } from "./DanmakuInput";
import { DanmakuList } from "./DanmakuList";
import { LiveChannelRail } from "./LiveChannelRail";
import { LiveOwnerPanel } from "./LiveOwnerPanel";
import { LiveHostAvatar } from "./LiveHostAvatar";
import { LivePlayer } from "./LivePlayer";
import { LiveStreamAddresses } from "./LiveStreamAddresses";
import { useDanmaku } from "../../hooks/useDanmaku";
import { useLiveRoom } from "../../hooks/useLiveRoom";
import { resolveSwipeCommit } from "../../hooks/useSwipeCommit";
import { usePagerTouchRouter } from "../../hooks/usePagerTouchRouter";
import { IconList } from "../icons";
import { useLiveStore } from "../../stores/live";
import { getVisibilityLabels } from "../../utils/visibility";

/** 直播间上下滑切换（方案 §2.5）：等价 tokens.css --ease-out / --ease-in（framer-motion ease 需 cubic-bezier 元组） */
const EASE_OUT: [number, number, number, number] = [0.22, 0.61, 0.36, 1];
const EASE_IN: [number, number, number, number] = [0.4, 0, 1, 1];
/** 切换滑入/滑出 250ms（design.md §7：150–300ms）；松手判定统一走 useSwipeCommit */
const LIVE_SLIDE_DURATION = 0.25;
/** drag 约束（钉在原点，配合 dragElastic 提供边缘阻尼 + 松手回弹） */
const LIVE_DRAG_CONSTRAINTS = { top: 0, bottom: 0 };
/** 跟手弹性：0.8 = 80% 跟手 + 20% 边缘阻尼 */
const LIVE_DRAG_ELASTIC = 0.8;

function prefersReducedMotion(): boolean {
  return (
    typeof window !== "undefined" &&
    typeof window.matchMedia === "function" &&
    window.matchMedia("(prefers-reduced-motion: reduce)").matches
  );
}

export function LiveRoomBody({
  channelId,
  channel,
  isNarrow,
  channels,
  onSelect,
  onBack,
  inputEntered,
  showOwnerPanel = false,
  activityRoute,
  keepLiveActivity = false,
  onDeleteChannel,
  onCreateNewChannel,
  deletingChannelId = null,
}: {
  channelId: number;
  channel: LiveChannelDescriptor | null;
  isNarrow: boolean;
  /** 有序频道列表（切换范围；一级 = 全部可见，群内 = 仅该群） */
  channels: LiveChannelDescriptor[];
  /** 点击封面切换直播间 */
  onSelect: (channelId: number) => void;
  onBack: () => void;
  inputEntered: boolean;
  /** 仅开播控制台显示主播面板，普通直播间保持观看 + 弹幕。 */
  showOwnerPanel?: boolean;
  /** 跨页面返回入口的目标路由。 */
  activityRoute?: string;
  /** 主播控制台离开页面后，直播中仍保留活动态入口。 */
  keepLiveActivity?: boolean;
  /** 侧栏每项删除直播间（仅开播控制台提供）。 */
  onDeleteChannel?: (channelId: number) => void;
  /** 侧栏底部加号：新建直播间并进入控制台。 */
  onCreateNewChannel?: () => void;
  /** 正在删除的频道 id（侧栏该项禁用）。 */
  deletingChannelId?: number | null;
}) {
  const { loading, error, playerError, retryPlayer, videoRef } = useLiveRoom(channelId, {
    activityRoute,
    keepLiveActivity,
  });
  const { sending, sendError, send, listRef, hasNewBelow, scrollToBottom, handleListScroll } =
    useDanmaku(channelId);
  const danmaku = useLiveStore((s) => s.current.danmaku);
  const srsStatus = useLiveStore((s) => s.current.srsStatus);
  const wsConnection = useLiveStore((s) => s.wsConnection);

  // 宽屏侧栏：默认展开，可收起（窄条）；窄屏侧栏：默认关闭（覆盖层）
  const [railCollapsed, setRailCollapsed] = useState(false);
  const [railOpen, setRailOpen] = useState(false);

  // ---- 直播间上下滑切换（§2.5，窄屏普通观看；宽屏走侧栏点击） ----
  const swipeRef = useRef<HTMLDivElement | null>(null);
  const [reducedMotion] = useState(prefersReducedMotion);
  // 手动 drag：触摸路由器（视频区直切 / 弹幕区滚动优先+边界接力）按需启动
  const dragControls = useDragControls();
  usePagerTouchRouter({
    containerRef: swipeRef,
    getListEl: () => listRef.current,
    controls: dragControls,
    enabled: isNarrow && !showOwnerPanel && !reducedMotion,
  });

  // 相邻直播间（切换范围 = 外层传入的有序 channels；端头无相邻项 → 边缘阻尼 + 不切换）
  const currentIdx = channels.findIndex((c) => c.id === channelId);
  const prevChannel = currentIdx > 0 ? channels[currentIdx - 1] : null;
  const nextChannel =
    currentIdx >= 0 && currentIdx < channels.length - 1 ? channels[currentIdx + 1] : null;

  // 切换方向追踪（render 阶段 ref 模式，与 ImageViewer 同款）：侧栏点击与上下滑共用，
  // 由新旧 index 差决定 1=切下一场（向下翻）/ -1=切上一场（向上翻）/ 0=无方向（淡入）
  const prevChannelIdRef = useRef(channelId);
  const directionRef = useRef<1 | -1 | 0>(0);
  if (prevChannelIdRef.current !== channelId) {
    const prevIdx = channels.findIndex((c) => c.id === prevChannelIdRef.current);
    if (prevIdx >= 0 && currentIdx >= 0) {
      directionRef.current = currentIdx > prevIdx ? 1 : -1;
    }
    prevChannelIdRef.current = channelId;
  }
  const swipeDirection = directionRef.current;

  const swipeVariants = useMemo(
    () =>
      reducedMotion
        ? { enter: { opacity: 1 }, center: { opacity: 1 }, exit: { opacity: 0 } }
        : {
            enter: (dir: number) => ({
              y: dir === 0 ? 0 : `${dir * 100}%`,
              opacity: 1,
              transition: { duration: LIVE_SLIDE_DURATION, ease: EASE_OUT },
            }),
            center: { y: 0, opacity: 1 },
            exit: (dir: number) => ({
              y: dir === 0 ? 0 : `${dir * -30}%`,
              opacity: 0,
              transition: { duration: LIVE_SLIDE_DURATION, ease: EASE_IN },
            }),
          },
    [reducedMotion],
  );

  // 松手判定（§2.5，useSwipeCommit 公共层）：净位移(>1/3 高)优先 + 同向甩动补充 +
  // 方向锁让位；pointercancel（系统取消，手指未松开）不算松手决策，否则回弹
  const handleSwipeDragEnd: PanHandler = useCallback(
    (event, info: PanInfo) => {
      if (event.type === "pointercancel") return;
      const height = swipeRef.current?.clientHeight ?? 600;
      const commit = resolveSwipeCommit({
        net: info.offset.y,
        cross: info.offset.x,
        velocity: info.velocity.y,
        size: height,
      });
      if (commit === 1 && nextChannel) onSelect(nextChannel.id);
      else if (commit === -1 && prevChannel) onSelect(prevChannel.id);
    },
    [nextChannel, prevChannel, onSelect],
  );

  const player = (
    <LivePlayer
      srsStatus={srsStatus}
      optimisticStatus={channel?.status ?? null}
      playerError={playerError}
      videoRef={videoRef}
      onRetry={retryPlayer}
    />
  );
  const visibilityLabels = channel ? getVisibilityLabels(channel) : [];

  const narrowHead = (
    <>
      <button type="button" className="msg-action-btn" onClick={onBack} aria-label="返回">
        ← 返回
      </button>
      {!showOwnerPanel && channel && (
        <>
          <LiveHostAvatar
            ownerId={channel.owner_id}
            ownerNickname={channel.owner_nickname}
            size={32}
          />
          <span className="live-room-title" title={channel.title}>
            {loading ? "加载中…" : (channel.title || "直播间")}
          </span>
        </>
      )}
      {!showOwnerPanel && visibilityLabels.length > 0 && (
        <div className="post-card-tags live-room-source-tags" title={visibilityLabels.join("、")}>
          {visibilityLabels.map((label, idx) => (
            <span key={idx} className="post-card-tag">{label}</span>
          ))}
        </div>
      )}
      {!showOwnerPanel && channel && <FavoriteButton targetType="live" targetId={channel.id} compact />}
      <button
        type="button"
        className="live-room-rail-toggle"
        onClick={() => setRailOpen(true)}
        aria-label="打开直播间列表"
        aria-expanded={railOpen}
      >
        <IconList width={20} height={20} />
      </button>
    </>
  );

  const wideHead = (
    <>
      {channel && (
        <LiveHostAvatar
          ownerId={channel.owner_id}
          ownerNickname={channel.owner_nickname}
          size={32}
        />
      )}
      <span className="live-room-title" title={channel?.title ?? "直播间"}>
        {loading ? "加载中…" : (channel?.title ?? "直播间")}
      </span>
      {visibilityLabels.length > 0 && (
        <div className="post-card-tags live-room-source-tags" title={visibilityLabels.join("、")}>
          {visibilityLabels.map((label, idx) => (
            <span key={idx} className="post-card-tag">{label}</span>
          ))}
        </div>
      )}
      {channel && <FavoriteButton targetType="live" targetId={channel.id} compact />}
      <span className={`live-ws-state live-ws-${wsConnection}`}>
        {wsConnection === "online"
          ? "弹幕已连接"
          : wsConnection === "connecting"
            ? "弹幕连接中…"
            : "弹幕已断开"}
      </span>
    </>
  );

  // 粘性 listRef 代理：沉浸式 AnimatePresence(mode="sync") 切直播间时 exit 实例仍
  // 渲染 DanmakuList，其卸载会 detach 共享 ref（React 把 current 置 null），此后
  // 自动滚底/跳底全部静默失效。代理忽略 detach（null 写入），只接受元素挂载。
  const stickyListRef = useMemo(
    () => ({
      get current(): HTMLDivElement | null {
        return listRef.current;
      },
      set current(v: HTMLDivElement | null) {
        if (v !== null) listRef.current = v;
      },
    }),
    [listRef],
  );

  const danmakuList = (
    <DanmakuList
      danmaku={danmaku}
      listRef={stickyListRef}
      hasNewBelow={hasNewBelow}
      onScrollToBottom={scrollToBottom}
      onUserScroll={handleListScroll}
    />
  );

  const danmakuInput = (
    <div
      className="live-room-input"
      style={{
        transform: inputEntered ? "translateY(0)" : "translateY(100%)",
        transition: "transform 250ms var(--ease-out)",
      }}
    >
      <DanmakuInput sending={sending} error={sendError} onSend={send} />
    </div>
  );

  const railOverlay = isNarrow && railOpen && (
    <div className="live-room-rail-overlay">
      <div className="live-room-rail-mask" onClick={() => setRailOpen(false)} aria-hidden="true" />
      <LiveChannelRail
        channels={channels}
        currentId={channelId}
        onSelect={(id) => {
          onSelect(id);
          setRailOpen(false);
        }}
        collapsed={false}
        onToggle={() => setRailOpen(false)}
        onBack={() => setRailOpen(false)}
        showBack={false}
        onDeleteChannel={showOwnerPanel ? onDeleteChannel : undefined}
        onCreateNewChannel={onCreateNewChannel}
        deletingChannelId={deletingChannelId}
      />
    </div>
  );

  if (error) {
    return (
      <div className={`live-room live-room-body ${showOwnerPanel ? "is-studio" : ""} ${isNarrow ? "is-narrow" : "is-wide"}`}>
        {/* 出错时仍保留侧栏与弹幕区，主区显示错误，避免用户卡在"只有返回键"的死页面 */}
        {!isNarrow && (
          <LiveChannelRail
            channels={channels}
            currentId={channelId}
            onSelect={onSelect}
            collapsed={railCollapsed}
            onToggle={() => setRailCollapsed((v) => !v)}
            onBack={onBack}
            showBack
            onDeleteChannel={showOwnerPanel ? onDeleteChannel : undefined}
            onCreateNewChannel={onCreateNewChannel}
            deletingChannelId={deletingChannelId}
          />
        )}
        <main className="live-room-main">
          <div className="live-room-error">
            <p>{error}</p>
            <button type="button" className="btn btn-glow" onClick={onBack}>
              返回
            </button>
          </div>
        </main>
        <aside className="live-room-side">{danmakuList}</aside>
      </div>
    );
  }

  // 沉浸式观看（窄屏 + 非控制台）：顶栏/输入框固定，视频 + 弹幕区整体上下滑切换。
  // 触摸路由（usePagerTouchRouter）：视频区直切；弹幕区列表滚动优先、到底/顶后接力切台；
  // dragListener={false} + 显式 touch-action:pan-y——framer-motion 只在自身监听时才写
  // touch-action（会写成 pan-x 禁掉弹幕列表滚动），手动模式下交由本组件声明语义。
  if (isNarrow && !showOwnerPanel) {
    return (
      <div className="live-room live-room-body is-narrow">
        <div className="live-room-head">{narrowHead}</div>
        <motion.div
          className="live-room-swipe"
          ref={swipeRef}
          drag={reducedMotion ? false : "y"}
          dragListener={false}
          dragControls={dragControls}
          style={{ touchAction: "pan-y" }}
          dragConstraints={LIVE_DRAG_CONSTRAINTS}
          dragElastic={LIVE_DRAG_ELASTIC}
          dragMomentum={false}
          onDragEnd={handleSwipeDragEnd}
        >
          <AnimatePresence custom={swipeDirection} mode="sync" initial={false}>
            <motion.div
              key={channelId}
              custom={swipeDirection}
              variants={swipeVariants}
              initial="enter"
              animate="center"
              exit="exit"
              className="live-room-swipe-item"
            >
              <div className="live-room-stage">{player}</div>
              {danmakuList}
            </motion.div>
          </AnimatePresence>
        </motion.div>
        {danmakuInput}
        {railOverlay}
      </div>
    );
  }

  // 宽屏观看 + 开播控制台（窄屏整页滚动）：保持三栏 / 纵向分区结构，不上下滑
  return (
    <div className={`live-room live-room-body ${showOwnerPanel ? "is-studio" : ""} ${isNarrow ? "is-narrow" : "is-wide"}`}>
      {/* 宽屏：频道封面侧栏（返回键在侧栏内 + 收起/展开） */}
      {!isNarrow && (
        <LiveChannelRail
          channels={channels}
          currentId={channelId}
          onSelect={onSelect}
          collapsed={railCollapsed}
          onToggle={() => setRailCollapsed((v) => !v)}
          onBack={onBack}
          showBack
          onDeleteChannel={showOwnerPanel ? onDeleteChannel : undefined}
          onCreateNewChannel={onCreateNewChannel}
          deletingChannelId={deletingChannelId}
        />
      )}

      <main className="live-room-main">
        {/* 开播控制台：宽屏头部整行隐藏（侧栏已有返回/标题），窄屏只留返回 + 列表按钮 */}
        {(isNarrow || !showOwnerPanel) && (
          <div className="live-room-head">{isNarrow ? narrowHead : wideHead}</div>
        )}

        {showOwnerPanel && channel?.is_owner && (
          <div className="live-studio-owner-panel">
            <LiveOwnerPanel channel={channel} />
          </div>
        )}

        {/* 中间：直播视频 */}
        <div className="live-room-stage">
          <div className="live-room-player-wrap">{player}</div>
        </div>

        {/* 下面：推流密钥（服务器 / 串流密钥 / FLV） */}
        {showOwnerPanel && channel?.is_owner && (
          <LiveStreamAddresses channel={channel} />
        )}
      </main>

      <aside className="live-room-side">
        {danmakuList}
        {danmakuInput}
      </aside>

      {railOverlay}
    </div>
  );
}
