/**
 * GroupPage —— 群聊场景容器（F3）。
 *
 * 窄屏（≤768px）：GroupTopTabs（底栏上移到顶部，R-G1）+ 五子界面（聊天居中，滑动切换）+
 * 群头像两级点击（R-G4，单一 handler 分支）+ 下拉回主页（R-G6 手势）。
 * 宽屏（>768px）：TopNav（AppShell 提供）+ ServerRail + ChannelSidebar + 内容区 三列
 * （主页即三列群聊界面，宽屏无群卡片网格/进群动画/两级点击/下拉回主页，布局文档 §3.2/§3.3）。
 *
 * 单一状态源：activeScene 存 stores/group，route param 变化时同步（单 effect）；
 * 切换场景 = setActiveScene + navigate（URL 回显）。
 * 输入框显隐（R-G5）由子界面自带：chat 子界面含 MessageInput；voice/games 占位无输入框。
 *
 * 方案 §2.2/§2.3/§2.4（M1 动画基座与转场）：
 * - 横滑跟手（§2.2）：当前场景 motion.div `drag="x"` + dragConstraints={0} + dragElastic
 *   （跟手 + 边缘阻尼 + 松手回弹），onDragEnd 松手判定统一走 useSwipeCommit
 *   （净位移 >1/3 宽优先 + 同向甩动补充 + 方向锁让位，pointercancel 不判定）；切换用
 *   AnimatePresence(custom=direction) + variants（enter ±40%→0 / exit ∓30%→透明），
 *   direction 由 GROUP_SCENE_ORDER 索引差计算（useSceneSwipeDirection）；单场景挂载
 *   （AnimatePresence 保管退出中的旧实例，动画完即卸载，重组件不并排常挂）。
 * - 下拉协同（§2.3）：pullOffset 同时驱动顶栏与内容区（translateY 1:1 + scale 1→0.98 +
 *   opacity 1→0.6 视差），过阈值松手内容下滑出屏 + 顶栏落回底部（250ms ease-in）后 navigate。
 * - 进群编排（§2.4）：底栏上移 250ms（useEnterGroupAnimation）→ 内容自下 24px 浮入 + 淡化
 *   （180ms，延迟 80ms）→ 输入框滑入（250ms，延迟 100ms，子界面自处理）。
 */
import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { useNavigate, useParams } from "react-router-dom";
import type { CSSProperties } from "react";
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
import { ChannelSidebar } from "../layout/ChannelSidebar";
import { ServerRail } from "../layout/ServerRail";
import { useChatStore } from "../stores/chat";
import { subscribeGroupConversations } from "../ws/chat";
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

/** 进群内容入场（方案 §2.4）：180ms 延迟 80ms */
const ENTER_CONTENT_DURATION = 0.18;
const ENTER_CONTENT_DELAY = 0.08;

/** 场景横滑切换（方案 §2.2）：滑入/滑出 250ms；松手判定统一走 useSwipeCommit */
const SCENE_SLIDE_DURATION = 0.25;

/** drag 约束（钉在原点，配合 dragElastic 提供边缘阻尼 + 松手回弹） */
const SCENE_DRAG_CONSTRAINTS = { left: 0, right: 0 };
/** 跟手弹性：0.8 = 80% 跟手 + 20% 边缘阻尼（接近 1:1，避免拖过头） */
const SCENE_DRAG_ELASTIC = 0.8;

function prefersReducedMotion(): boolean {
  return (
    typeof window !== "undefined" &&
    typeof window.matchMedia === "function" &&
    window.matchMedia("(prefers-reduced-motion: reduce)").matches
  );
}

export function GroupPage() {
  const { id, scene, postId, voiceChannelId } = useParams<{
    id: string;
    scene?: string;
    postId?: string;
    voiceChannelId?: string;
  }>();
  const navigate = useNavigate();
  const isNarrow = useMediaQuery(NARROW_QUERY);

  const conversations = useChatStore((s) => s.conversations);
  const activeScene = useGroupStore((s) => s.activeScene);
  const setActiveScene = useGroupStore((s) => s.setActiveScene);
  const setCurrentGroup = useGroupStore((s) => s.setCurrentGroup);

  const { entered } = useEnterGroupAnimation();
  const sceneDirection = useSceneSwipeDirection(activeScene);

  // 惰性同步读取 reduced-motion（非 effect）：用户首帧即无位移动画，避免闪跳
  const [reducedMotion] = useState(prefersReducedMotion);

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

  const groups = useMemo(
    () => conversations.filter((c) => c.type === "group"),
    [conversations],
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
      : scene && VALID_SCENES.has(scene)
        ? (scene as GroupScene)
        : "chat";

  useEffect(() => {
    if (!id) return;
    setCurrentGroup(id);
    setActiveScene(effectiveScene);
    useHomeStore.getState().setRecentGroup(id);
    // 进入即打开群会话（GroupChat 内部也 openConversation，幂等）
    // 进入群聊仍保持滚底；未读由 MessageList 的定位标签承接，不在打开时清除。
    useChatStore.getState().openConversation(id);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [id, effectiveScene]);

  // 直接访问 /group/:id 时会话列表可能为空：补齐加载（复用 chat store）
  useEffect(() => {
    // 只要已有会话就可渲染当前群；实时变化由 WebSocket upsert 驱动，避免首屏重复请求。
    if (conversations.length > 0) return;
    let cancelled = false;
    chatApi
      .listConversations()
      .then((list) => {
        if (!cancelled) {
          useChatStore.getState().setConversations(list);
          subscribeGroupConversations(list);
          setConversationLoadError(null);
        }
      })
      .catch((e) => {
        if (!cancelled) setConversationLoadError(e instanceof Error ? e.message : "加载群列表失败");
      });
    return () => {
      cancelled = true;
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [conversationRetry]);

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
    switch (activeScene) {
      case "info":
        return <GroupInfo groupId={id ?? ""} />;
      case "chat":
        return <GroupChat groupId={id ?? ""} />;
      case "live":
        return <GroupLive groupId={id ?? ""} onExit={() => goScene("chat")} />;
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
        return <GroupScenePlaceholder scene={activeScene} />;
    }
  }, [activeScene, id, postId, voiceChannelId, goScene]);

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

  // 场景切换变体（§2.2）：direction 由索引差决定；reduced-motion 直切（仅透明度）
  const sceneVariants = useMemo(
    () =>
      reducedMotion
        ? {
            enter: { opacity: 1 },
            center: { opacity: 1 },
            exit: { opacity: 0 },
          }
        : {
            enter: (dir: number) => ({
              x: dir === 0 ? 0 : `${dir * 40}%`,
              opacity: 1,
              transition: { duration: SCENE_SLIDE_DURATION, ease: EASE_OUT },
            }),
            center: { x: 0, opacity: 1 },
            exit: (dir: number) => ({
              x: dir === 0 ? 0 : `${dir * -30}%`,
              opacity: 0,
              transition: { duration: SCENE_SLIDE_DURATION, ease: EASE_IN },
            }),
          },
    [reducedMotion],
  );

  // 进群内容入场变体（§2.4）：自下 24px 浮入 + 淡化（180ms，延迟 80ms）；reduced-motion 直切
  const enterVariants = useMemo(
    () =>
      reducedMotion
        ? {
            out: { opacity: 0 },
            in: { opacity: 1 },
          }
        : {
            out: { y: 24, opacity: 0 },
            in: {
              y: 0,
              opacity: 1,
              transition: { duration: ENTER_CONTENT_DURATION, delay: ENTER_CONTENT_DELAY, ease: EASE_OUT },
            },
          },
    [reducedMotion],
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
        {conversationLoadError && <div className="chat-notice" role="alert"><span>{conversationLoadError}</span><button type="button" className="btn btn-ghost" onClick={() => { setConversationLoadError(null); setConversationRetry((value) => value + 1); }}>重试</button></div>}
        <ServerRail
          groups={sortedGroups}
          currentGroupId={id ?? null}
          onSelectGroup={(gid) => navigate(`/group/${gid}`)}
          onCreateGroup={() => setShowGroupCreate(true)}
          onError={setActionError}
        />
        <ChannelSidebar
          groupName={currentGroup?.title ?? "群聊"}
          activeScene={activeScene}
          onSelectScene={goScene}
          onOpenInfo={openInfo}
        />
        <main className="group-content">{renderScene()}</main>
        {showGroupCreate && <GroupCreateDialog onClose={() => setShowGroupCreate(false)} />}
      </div>
    );
  }

  // ---- 窄屏 ----
  // 顶栏 transform 四态：退场（移回底部 ease-in）> 进群（未 entered 停底部）> 跟手（下拉即时）> 就位（回弹复位）
  let tabsTransform: string;
  let tabsTransition: string;
  if (leaving) {
    tabsTransform = "translateY(calc(100vh - 64px))";
    tabsTransition = reducedMotion ? "none" : `transform ${EXIT_TRANSITION_MS}ms var(--ease-in)`;
  } else if (!entered) {
    tabsTransform = "translateY(calc(100vh - 64px))";
    tabsTransition = reducedMotion ? "none" : "transform 250ms var(--ease-out)";
  } else if (pullOffset > 0) {
    tabsTransform = `translateY(${pullOffset}px)`;
    tabsTransition = "none";
  } else {
    tabsTransform = "translateY(0)";
    tabsTransition = reducedMotion ? "none" : "transform 200ms var(--ease-out)";
  }
  const tabsStyle: CSSProperties = {
    transform: tabsTransform,
    transition: tabsTransition,
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

      {/* 进群入场层（§2.4）：内容自下 24px 浮入 + 淡化（延迟 80ms） */}
      <motion.div
        className="group-scene-enter"
        initial={false}
        animate={entered ? "in" : "out"}
        variants={enterVariants}
      >
        {/* 下拉协同层（§2.3）：translateY 1:1 + scale/opacity 视差 */}
        <motion.div
          className="group-scene"
          ref={sceneRef}
          style={{ y: pullY, scale: pullScale, opacity: pullOpacity }}
        >
          {/* 五子场景横滑层（§2.2）：单场景挂载 + drag 跟手 + 方向变体切换 */}
          <AnimatePresence custom={sceneDirection} mode="sync" initial={false}>
            <motion.div
              key={activeScene}
              className="group-scene-inner"
              custom={sceneDirection}
              variants={sceneVariants}
              initial="enter"
              animate="center"
              exit="exit"
              drag={canSceneDrag ? "x" : false}
              dragConstraints={SCENE_DRAG_CONSTRAINTS}
              dragElastic={SCENE_DRAG_ELASTIC}
              dragMomentum={false}
              onDragEnd={handleSceneDragEnd}
            >
              {renderScene()}
            </motion.div>
          </AnimatePresence>
        </motion.div>
      </motion.div>
    </div>
  );
}
