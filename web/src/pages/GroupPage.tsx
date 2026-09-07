/**
 * GroupPage —— 群聊场景容器（F3）。
 *
 * 窄屏（≤768px）：GroupTopTabs（从底栏位置连续升至顶部）+ 五子界面（聊天居中，滑动切换）+
 * 群头像两级点击（R-G4，单一 handler 分支）+ 下拉回主页（R-G6 手势）。
 * 宽屏（>768px）：TopNav（AppShell 提供）+ ServerRail + ChannelSidebar + 内容区 三列
 * （主页即三列群聊界面；侧栏与内容分别进入，切群保留服务器栏，频道面板依次退出/进入）。
 *
 * 场景选择统一经 setActiveScene + navigate；route param 变化时同步 stores/group。
 * 宽屏新群首帧按当前路由渲染，避免 effect 同步前把旧群场景挂到新群。
 * 输入框显隐（R-G5）由聊天、语音、直播和帖子各自的子界面拥有。
 *
 * 方案 §2.2/§2.3/§2.4（M1 动画基座与转场）：
 * - 横滑跟手（§2.2）：当前场景 motion.div `drag="x"` + dragConstraints={0} + dragElastic
 *   （跟手 + 边缘阻尼 + 松手回弹），onDragEnd 松手判定统一走 useSwipeCommit
 *   （净位移 >1/3 宽优先 + 同向甩动补充 + 方向锁让位，pointercancel 不判定）；切换用
 *   AnimatePresence 保留退出中的旧场景和当帧拖动位移，外壳原位淡出、各新分区独立进入；
 *   场景路由顺序仍由 GROUP_SCENE_ORDER 决定；单场景挂载
 *   （AnimatePresence 保管退出中的旧实例，动画完即卸载，重组件不并排常挂）。
 * - 下拉协同（§2.3）：pullOffset 同时驱动顶栏与内容区（translateY 1:1 + scale 1→0.98 +
 *   opacity 1→0.6 视差），过阈值松手内容下滑出屏 + 顶栏落回底部（250ms ease-in）后 navigate。
 * - 自动进入由分区拥有：导航条从原底栏位置升至顶部，输入框从下方 20px 进入；
 *   内容外壳不叠加整体缩放/位移，真实下拉和横滑仍由各自手势层拥有。
 */
import { useCallback, useEffect, useLayoutEffect, useMemo, useRef, useState } from "react";
import { useNavigate, useParams } from "react-router-dom";
import type { CSSProperties, ReactNode } from "react";
import { AnimatePresence, animate, motion, useMotionValue, useTransform } from "framer-motion";
import type { PanHandler, PanInfo } from "framer-motion";
import * as chatApi from "../api/chat";
import { GroupCreateDialog } from "../components/GroupCreateDialog";
import { GroupTopTabs } from "../components/group/GroupTopTabs";
import { sortGroupsByActivity, useGroupActivityMap } from "../components/home/groupActivity";
import { NARROW_QUERY, useMediaQuery } from "../hooks/useMediaQuery";
import { useEnterGroupAnimation } from "../hooks/useEnterGroupAnimation";
import { useSceneSwipeDirection } from "../hooks/useSceneSwipeDirection";
import { resolveSwipeCommit } from "../hooks/useSwipeCommit";
import { useSwipe } from "../hooks/useSwipe";
import { useTouchAxisGuard } from "../hooks/useTouchAxisGuard";
import { usePrefersReducedMotion } from "../hooks/usePrefersReducedMotion";
import { useMotionDrag } from "../hooks/useMotionDrag";
import { auroraquaRouteTransition } from "../components/motion/auroraquaMotion";
import { ConversationTransition } from "../components/motion/ConversationTransition";
import { ChannelSidebar } from "../layout/ChannelSidebar";
import { ServerRail } from "../layout/ServerRail";
import { useChatStore } from "../stores/chat";
import { useSubGroupStore } from "../stores/subgroup";
import { useSocialPage } from "../hooks/useSocialPage";
import { GROUP_SCENE_ORDER, useGroupStore } from "../stores/group";
import type { GroupScene } from "../stores/group";
import { useHomeStore } from "../stores/home";
import { GroupChat } from "./group/GroupChat";
import { GroupInfo } from "./group/GroupInfo";
import { GroupLive } from "./group/GroupLive";
import { GroupVoice } from "./group/GroupVoice";
import { GroupPosts } from "./group/GroupPosts";
import { GroupGames } from "./group/GroupGames";
import { GroupScenePlaceholder } from "./group/GroupScenePlaceholder";

const VALID_SCENES = new Set<string>([...GROUP_SCENE_ORDER, "info"]);

/** 下拉返回主页手势阈值与退场时长（R-G6 / design.md §12.12：阈值 80px，回弹 200ms） */
const PULL_DOWN_EXIT_THRESHOLD = 80;
const EXIT_TRANSITION_MS = 250;

/** 等价 tokens.css --ease-out / --ease-in（framer-motion ease 需 cubic-bezier 元组） */
const EASE_OUT: [number, number, number, number] = [0.22, 0.61, 0.36, 1];
const EASE_IN: [number, number, number, number] = [0.4, 0, 1, 1];

/** drag 约束（钉在原点，配合 dragElastic 提供边缘阻尼 + 松手回弹） */
const SCENE_DRAG_CONSTRAINTS = { left: 0, right: 0 };
/** 跟手弹性：0.8 = 80% 跟手 + 20% 边缘阻尼（接近 1:1，避免拖过头） */
const SCENE_DRAG_ELASTIC = 0.8;

export function GroupPage() {
  const { id, scene, postId, voiceChannelId, liveChannelId } = useParams<{
    id: string;
    scene?: string;
    postId?: string;
    voiceChannelId?: string;
    liveChannelId?: string;
  }>();
  const navigate = useNavigate();
  const isNarrow = useMediaQuery(NARROW_QUERY);

  const conversations = useChatStore((s) => s.conversations);
  const groupPage = useSocialPage("conversations", { type: "group" });
  const subgroupPage = useSocialPage("subgroups", { groupId: id }, !!id);
  const selectedSubgroup = useSubGroupStore((state) => id ? state.activeByGroup[id] : null);
  const activeScene = useGroupStore((s) => s.activeScene);
  const setActiveScene = useGroupStore((s) => s.setActiveScene);
  const setCurrentGroup = useGroupStore((s) => s.setCurrentGroup);

  const { entered } = useEnterGroupAnimation();
  const sceneDirection = useSceneSwipeDirection(activeScene);

  const reducedMotion = usePrefersReducedMotion();

  // 宽屏 ServerRail 底部加号：创建群聊（需求：左下角头像键改加号）
  const [showGroupCreate, setShowGroupCreate] = useState(false);
  const [conversationLoadError, setConversationLoadError] = useState<string | null>(null);
  const [conversationRetry, setConversationRetry] = useState(0);
  const [actionError, setActionError] = useState<string | null>(null);

  // ---- 下拉回主页（R-G6 / §2.3）：顶栏跟手 + 内容区协同（translateY/scale/opacity 视差） ----
  const [pullOffset, setPullOffset] = useState(0);
  const [leaving, setLeaving] = useState(false);
  const leavingTimerRef = useRef<ReturnType<typeof setTimeout> | null>(null);
  // 内容区（中层）下拉/退场位移：跟手 set、回弹 animate、退场 animate
  const sceneRef = useRef<HTMLDivElement>(null);
  // 横滑轴守卫：起步 slop 内横轴占优时压制浏览器垂直滚动接管（否则 pointercancel
  // 会让 drag 提前死亡——touch-action: pan-y 下真机斜向起手必触发，见 useTouchAxisGuard）
  useTouchAxisGuard(sceneRef, "x");
  const pullY = useMotionValue(0);
  const pullScale = useTransform(pullY, [0, PULL_DOWN_EXIT_THRESHOLD], [1, 0.98]);
  const pullOpacity = useMotionValue(1);

  const pullToHome = useCallback(() => {
    setPullOffset(0);
    setLeaving(true);
    useGroupStore.getState().reset();
    const sceneHeight = sceneRef.current?.clientHeight ?? 0;
    if (!reducedMotion && sceneHeight > 0) {
      // 内容下滑出屏 + 整体淡出（250ms ease-in，与顶栏落底同步）
      animate(pullY, sceneHeight, { duration: EXIT_TRANSITION_MS / 1000, ease: EASE_IN });
      animate(pullOpacity, 0, { duration: EXIT_TRANSITION_MS / 1000, ease: EASE_IN });
    } else {
      pullY.set(sceneHeight);
      pullOpacity.set(0);
    }
    // 退场动画结束回到 /group（reduced-motion 下无动画，仍等固定时长保证顶栏直切完成）
    leavingTimerRef.current = setTimeout(() => navigate("/group"), EXIT_TRANSITION_MS);
  }, [navigate, pullY, pullOpacity, reducedMotion]);

  useEffect(() => {
    return () => {
      if (leavingTimerRef.current) clearTimeout(leavingTimerRef.current);
    };
  }, []);

  const pullSwipe = useSwipe(
    {
      onMove: (e) => {
        // 只在垂直方向锁定时跟手；下拉（dy > 0）才位移，上推回弹；reduced-motion 不跟手
        if (e.axis !== "y" || e.dy <= 0 || leaving || reducedMotion) return;
        setPullOffset(e.dy);
        pullY.set(e.dy);
        const progress = Math.min(e.dy / PULL_DOWN_EXIT_THRESHOLD, 1);
        pullOpacity.set(1 - 0.4 * progress);
      },
      onEnd: (e) => {
        // Reduced motion removes visual movement, not the user's new navigation gesture.
        // A preference change cancels the old tracker below, so its later touchend is ignored.
        if (leaving) return;
        if (e.direction === "down" && e.dy >= PULL_DOWN_EXIT_THRESHOLD) {
          pullToHome();
        } else {
          setPullOffset(0);
          if (!reducedMotion) {
            animate(pullY, 0, { duration: 0.2, ease: EASE_OUT });
            animate(pullOpacity, 1, { duration: 0.2, ease: EASE_OUT });
          } else {
            pullY.set(0);
            pullOpacity.set(1);
          }
        }
      },
      onCancel: () => {
        setPullOffset(0);
        if (!reducedMotion) {
          animate(pullY, 0, { duration: 0.2, ease: EASE_OUT });
          animate(pullOpacity, 1, { duration: 0.2, ease: EASE_OUT });
        } else {
          pullY.set(0);
          pullOpacity.set(1);
        }
      },
    },
    { threshold: PULL_DOWN_EXIT_THRESHOLD, lockSlop: 12 },
  );

  useLayoutEffect(() => {
    if (!reducedMotion) return;
    pullSwipe.tracker.cancel();
    pullY.stop();
    pullY.set(0);
    setPullOffset(0);
    if (!leaving) {
      pullOpacity.stop();
      pullOpacity.set(1);
    }
  }, [reducedMotion, pullSwipe.tracker, pullY, pullOpacity, leaving]);

  const groups = useMemo(
    () => {
      const loaded = groupPage.items;
      const selected = conversations.find((conversation) => conversation.id === id && conversation.type === "group");
      return selected && !loaded.some((conversation) => conversation.id === selected.id) ? [...loaded, selected] : loaded;
    },
    [conversations, groupPage.items, id],
  );

  // 群"新内容"活跃度：WS 实时维护 live/voice/boardgame/posts store → 排序即时刷新
  const activityFor = useGroupActivityMap();
  const sortedGroups = sortGroupsByActivity(groups, (g) =>
    activityFor(g.id, g.last_message),
  );
  const currentGroup = useMemo(
    () => conversations.find((c) => c.id === id) ?? null,
    [conversations, id],
  );

  // 单一状态源：route param → store（scene 无效回退 chat）
  const effectiveScene: GroupScene = postId
    ? "posts"
    : voiceChannelId
      ? "voice"
      : liveChannelId
        ? "live"
        : scene && VALID_SCENES.has(scene)
          ? (scene as GroupScene)
          : "chat";
  // The persistent wide shell renders the new route immediately; it must not
  // briefly mount the previous group's scene before the store effect catches up.
  const contentScene = isNarrow ? activeScene : effectiveScene;

  useEffect(() => {
    if (!id) return;
    setCurrentGroup(id);
    setActiveScene(effectiveScene);
    useHomeStore.getState().setRecentGroup(id);
    // 只在聊天场景持有 activeConversationId：进入群（任意子场景）不自动打开会话。
    // 非 chat 子场景（posts/live/voice/games/info）显式关闭，否则 GroupChat 卸载后
    // activeId 仍残留为当前群 → WS 新消息被误判为「正在看」而自动已读（F7 语义：
    // 只有真的在聊天窗口里才自动已读）。
    // 进入群聊仍保持滚底；未读由 MessageList 的定位标签承接，不在打开时清除。
    // 只有实际挂载且仍在场的 GroupChat 可以打开会话；
    // 路由先行不能把仍在等待入场的目标群标成正在阅读。
    if (effectiveScene !== "chat" && useChatStore.getState().activeConversationId === id) {
      useChatStore.getState().closeConversation();
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [id, effectiveScene]);

  // Direct routes resolve their own descriptor, even outside the first group page.
  useEffect(() => {
    if (!id || currentGroup) return;
    let cancelled = false;
    chatApi
      .getConversationSummary(id)
      .then((conversation) => {
        if (!cancelled) {
          useChatStore.getState().upsertConversation(conversation);
          setConversationLoadError(null);
        }
      })
      .catch((e) => {
        if (!cancelled) setConversationLoadError(e instanceof Error ? e.message : "加载群列表失败");
      });
    return () => {
      cancelled = true;
    };
  }, [id, currentGroup, conversationRetry]);

  // Default and selected identities are independent of the visible page boundary.
  useEffect(() => {
    if (!id) return;
    if (selectedSubgroup == null) {
      const defaultGroup = subgroupPage.items.find((item) => item.is_default);
      if (defaultGroup) useSubGroupStore.getState().setActiveSubgroup(id, defaultGroup.id);
      return;
    }
    if (useSubGroupStore.getState().byGroup[id]?.some((item) => item.id === selectedSubgroup)) return;
    let cancelled = false;
    void chatApi.getSubgroup(id, selectedSubgroup)
      .then((subgroup) => {
        if (cancelled) return;
        useSubGroupStore.getState().upsertSubgroup(id, subgroup);
      })
      .catch((error) => {
        if (!cancelled) setConversationLoadError(error instanceof Error ? error.message : "加载选中子群失败");
      });
    return () => {
      cancelled = true;
    };
  }, [id, selectedSubgroup, subgroupPage.items]);

  // 切换场景：store（单一事实）+ URL 回显
  const goScene = useCallback(
    (next: GroupScene) => {
      setActiveScene(next);
      navigate(next === "chat" ? `/group/${id}` : `/group/${id}/${next}`);
    },
    [id, navigate, setActiveScene],
  );

  const openInfo = useCallback(() => {
    setActiveScene("info");
    navigate(`/group/${id}/info`);
  }, [id, navigate, setActiveScene]);

  // 宽屏侧栏点击语音房行：进入指定语音房（URL 带 voiceChannelId）
  const openVoiceChannel = useCallback(
    (channelId: string) => {
      setActiveScene("voice");
      navigate(`/group/${id}/voice/${channelId}`);
    },
    [id, navigate, setActiveScene],
  );

  // 宽屏侧栏点击直播间行：进入指定直播间（URL 带 liveChannelId）
  const openLiveChannel = useCallback(
    (channelId: number) => {
      setActiveScene("live");
      navigate(`/group/${id}/live/${channelId}`);
    },
    [id, navigate, setActiveScene],
  );

  // 群头像两级点击（R-G4，单一 handler 分支，读 activeScene 单一状态）
  const handleAvatarClick = useCallback(() => {
    if (activeScene === "chat") {
      openInfo();
    } else {
      goScene("chat");
    }
  }, [activeScene, openInfo, goScene]);

  // 群内子场景渲染（live F4 / voice F5 / posts F6 已落地；games 仍占位）
  const renderScene = useCallback(() => {
    switch (contentScene) {
      case "info":
        return <GroupInfo groupId={id ?? ""} />;
      case "chat":
        return <GroupChat groupId={id ?? ""} panelMotion />;
      case "live":
        return <GroupLive groupId={id ?? ""} routeChannelId={liveChannelId} onExit={() => goScene("chat")} />;
      case "voice":
        return (
          <GroupVoice
            groupId={id ?? ""}
            routeChannelId={voiceChannelId}
            onExit={() => goScene("chat")}
          />
        );
      case "posts":
        return <GroupPosts groupId={id ?? ""} postId={postId} onExit={() => goScene("chat")} />;
      case "games":
        return <GroupGames groupId={id ?? ""} onExit={() => goScene("chat")} />;
      default:
        return <GroupScenePlaceholder scene={contentScene} />;
    }
  }, [contentScene, id, postId, voiceChannelId, liveChannelId, goScene, isNarrow]);

  // ---- 场景横滑（§2.2）：松手判定——净位移(>1/3 宽)优先 + 同向甩动补充 + 方向锁让位。
  // pointercancel（浏览器滚动接管等系统取消，手指未松开）不算松手决策，回弹不判定；
  // framer-motion velocity 单位是 px/s（详见 useSwipeCommit docstring）。
  const handleSceneDragEnd: PanHandler = useCallback(
    (event, info: PanInfo) => {
      if (event.type === "pointercancel") return;
      const width = sceneRef.current?.clientWidth ?? 375;
      const baseIdx = GROUP_SCENE_ORDER.indexOf(activeScene === "info" ? "chat" : activeScene);
      if (baseIdx < 0) return;
      const commit = resolveSwipeCommit({
        net: info.offset.x,
        cross: info.offset.y,
        velocity: info.velocity.x,
        size: width,
      });
      // 否则：dragConstraints={0} 的 elastic 自动回弹到 0
      if (commit === 0) return;
      goScene(GROUP_SCENE_ORDER[(baseIdx + commit + GROUP_SCENE_ORDER.length) % GROUP_SCENE_ORDER.length]);
    },
    [activeScene, goScene],
  );

  // ---- 宽屏：三列（ServerRail + ChannelSidebar + 内容区） ----
  if (!isNarrow) {
    return (
      <div className="group-page group-page-wide">
        {actionError && (
          <div className="messages-action-error" role="alert" onClick={() => setActionError(null)}>
            {actionError}（点击关闭）
          </div>
        )}
        {(conversationLoadError || groupPage.error) && <div className="chat-notice" role="alert"><span>{conversationLoadError || groupPage.error}</span><button type="button" className="btn btn-ghost" onClick={() => { setConversationLoadError(null); setConversationRetry((value) => value + 1); void groupPage.refresh(); }}>重试</button></div>}
        <ServerRail
          groups={sortedGroups}
          currentGroupId={id ?? null}
          onSelectGroup={(gid) => navigate(`/group/${gid}`)}
          onCreateGroup={() => setShowGroupCreate(true)}
          onError={setActionError}
        />
        <ChannelSidebar
          groupId={id ?? null}
          groupName={currentGroup?.title ?? "群聊"}
          activeScene={contentScene}
          onSelectScene={goScene}
          onOpenInfo={openInfo}
          onSelectSubgroup={(sgId) => useSubGroupStore.getState().setActiveSubgroup(id ?? "", sgId)}
          onSelectVoiceChannel={openVoiceChannel}
          activeVoiceChannelId={voiceChannelId}
          onSelectLiveChannel={openLiveChannel}
          activeLiveChannelId={liveChannelId}
          onNavigateLiveStart={(channelId) => navigate(`/live/start/${channelId}`)}
        />
        <main className="group-content">
          <ConversationTransition identity={`group:${id ?? ""}`}>
            {renderScene()}
          </ConversationTransition>
        </main>
        {showGroupCreate && <GroupCreateDialog onClose={() => setShowGroupCreate(false)} />}
      </div>
    );
  }

  // ---- 窄屏 ----
  // transform 仅拥有手势跟手/退场；独立 translate 将原底栏位置连续移至顶部。
  // shell 高度为 100dvh，底栏本体为 64px + 底部安全区；首帧保持可见。
  let tabsTransform: string;
  let tabsTransition: string;
  if (leaving) {
    tabsTransform = "translateY(calc(100vh - 64px))";
    tabsTransition = reducedMotion ? "none" : `transform ${EXIT_TRANSITION_MS}ms var(--ease-in)`;
  } else if (pullOffset > 0) {
    tabsTransform = `translateY(${pullOffset}px)`;
    tabsTransition = "none";
  } else {
    tabsTransform = "translateY(0)";
    tabsTransition = reducedMotion ? "none" : "transform 200ms var(--ease-out)";
  }
  const tabsStyle: CSSProperties = {
    transform: tabsTransform,
    translate: reducedMotion ? "none" : entered ? "0 0" : "0 calc(100dvh - 64px - env(safe-area-inset-bottom, 0px))",
    opacity: 1,
    transition: reducedMotion ? "none" : `${tabsTransition}, translate 300ms var(--auroraqua-ease-out)`,
  };

  const canSceneDrag = !reducedMotion && !leaving;

  return (
    <div className="group-page group-page-narrow">
      <GroupTopTabs
        groupName={currentGroup?.title ?? "群聊"}
        avatar={currentGroup?.avatar}
        activeScene={activeScene}
        onSelectScene={goScene}
        onAvatarClick={handleAvatarClick}
        style={tabsStyle}
        pullHandlers={pullSwipe.handlers}
      />

      {/* 内容分区各自入场；此层只保留布局，不向顶栏或输入框叠加位移。 */}
      <div className="group-scene-enter">
        {/* 下拉协同层（§2.3）：translateY 1:1 + scale/opacity 视差 */}
        <motion.div
          className="group-scene"
          ref={sceneRef}
          style={{ y: reducedMotion ? 0 : pullY, scale: reducedMotion ? 1 : pullScale, opacity: pullOpacity }}
        >
          {/* 五子场景横滑层（§2.2）：单场景挂载 + drag 跟手 + 方向变体切换 */}
          <AnimatePresence custom={sceneDirection} mode="sync" propagate>
            <GroupSceneSurface
              key={activeScene}
              direction={sceneDirection}
              enabled={canSceneDrag}
              onDragEnd={handleSceneDragEnd}
            >
              {renderScene()}
            </GroupSceneSurface>
          </AnimatePresence>
        </motion.div>
      </div>
    </div>
  );
}

/** Panels enter from their own edges; the drag layer retains the held offset throughout exit. */
function GroupSceneSurface({ direction, enabled, onDragEnd, children }: {
  direction: 1 | -1 | 0;
  enabled: boolean;
  onDragEnd: PanHandler;
  children: ReactNode;
}) {
  const drag = useMotionDrag(enabled, onDragEnd);
  const variants = useMemo(() => ({
    enter: { x: 0, opacity: 1 },
    center: { x: 0, opacity: 1 },
    exit: { x: 0, opacity: 0, transition: drag.reduced ? { duration: 0 } : auroraquaRouteTransition },
  }), [drag.reduced]);
  return (
    <motion.div
      className="group-scene-inner"
      custom={direction}
      variants={variants}
      initial="enter"
      animate="center"
      exit="exit"
      style={{ pointerEvents: drag.present ? undefined : "none" }}
    >
      <motion.div
        className="group-scene-drag"
        inherit={false}
        drag={drag.allowed ? "x" : false}
        dragControls={drag.controls}
        style={{ x: drag.offset }}
        dragConstraints={SCENE_DRAG_CONSTRAINTS}
        dragSnapToOrigin
        dragElastic={SCENE_DRAG_ELASTIC}
        dragMomentum={false}
        onDragStart={drag.onDragStart}
        onDragEnd={drag.onDragEnd}
      >
        {children}
      </motion.div>
    </motion.div>
  );
}
