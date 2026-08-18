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
 */
import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { useNavigate, useParams } from "react-router-dom";
import type { CSSProperties } from "react";
import * as chatApi from "../api/chat";
import { GroupCreateDialog } from "../components/GroupCreateDialog";
import { GroupTopTabs } from "../components/group/GroupTopTabs";
import { NARROW_QUERY, useMediaQuery } from "../hooks/useMediaQuery";
import { useEnterGroupAnimation } from "../hooks/useEnterGroupAnimation";
import { useSwipe } from "../hooks/useSwipe";
import { ChannelSidebar } from "../layout/ChannelSidebar";
import { ServerRail } from "../layout/ServerRail";
import { markConversationRead } from "../hooks/useChat";
import { useChatStore } from "../stores/chat";
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

  // 宽屏 ServerRail 底部加号：创建群聊（需求：左下角头像键改加号）
  const [showGroupCreate, setShowGroupCreate] = useState(false);
  const [conversationLoadError, setConversationLoadError] = useState<string | null>(null);
  const [conversationRetry, setConversationRetry] = useState(0);

  // ---- 下拉回主页（R-G6）：跟手位移 + 阈值 80px + 退场后 navigate(/home) ----
  const [pullOffset, setPullOffset] = useState(0);
  const [leaving, setLeaving] = useState(false);
  const leavingTimerRef = useRef<ReturnType<typeof setTimeout> | null>(null);

  const pullToHome = useCallback(() => {
    setPullOffset(0);
    setLeaving(true);
    useGroupStore.getState().reset();
    // 退场动画（顶栏下移回底部，250ms）结束回落 /home
    leavingTimerRef.current = setTimeout(() => navigate("/home"), 250);
  }, [navigate]);

  useEffect(() => {
    return () => {
      if (leavingTimerRef.current) clearTimeout(leavingTimerRef.current);
    };
  }, []);

  const pullSwipe = useSwipe(
    {
      onMove: (e) => {
        // 只在垂直方向锁定时跟手；下拉（dy > 0）才位移，上推回弹
        if (e.axis === "y" && e.dy > 0 && !leaving) setPullOffset(e.dy);
      },
      onEnd: (e) => {
        if (e.direction === "down" && e.dy >= PULL_DOWN_EXIT_THRESHOLD) {
          pullToHome();
        } else {
          setPullOffset(0); // 回弹
        }
      },
      onCancel: () => setPullOffset(0),
    },
    { threshold: PULL_DOWN_EXIT_THRESHOLD, lockSlop: 12 },
  );

  const groups = useMemo(
    () => conversations.filter((c) => c.type === "group"),
    [conversations],
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
    useChatStore.getState().openConversation(id);
    useChatStore.getState().clearUnread(id);
    void markConversationRead(id);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [id, effectiveScene]);

  // 直接访问 /group/:id 时会话列表可能为空：补齐加载（复用 chat store）
  useEffect(() => {
    if (conversations.length > 0) return;
    let cancelled = false;
    chatApi
      .listConversations()
      .then((list) => {
        if (!cancelled) {
          useChatStore.getState().setConversations(list);
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
  }, [activeScene, id, postId, goScene]);

  // 五子界面左右滑动切换（窄屏；宽屏由 ChannelSidebar 点击）
  const baseIdx = effectiveScene === "info" ? GROUP_SCENE_ORDER.indexOf("chat") : GROUP_SCENE_ORDER.indexOf(effectiveScene);
  const swipe = useSwipe(
    {
      onEnd: (e) => {
        if (e.direction === "left") {
          goScene(GROUP_SCENE_ORDER[(baseIdx + 1) % GROUP_SCENE_ORDER.length]);
        } else if (e.direction === "right") {
          goScene(
            GROUP_SCENE_ORDER[(baseIdx - 1 + GROUP_SCENE_ORDER.length) % GROUP_SCENE_ORDER.length],
          );
        }
      },
    },
    { threshold: 48 },
  );

  // ---- 宽屏：三列（ServerRail + ChannelSidebar + 内容区） ----
  if (!isNarrow) {
    return (
      <div className="group-page group-page-wide">
        {conversationLoadError && <div className="chat-notice" role="alert"><span>{conversationLoadError}</span><button type="button" className="btn btn-ghost" onClick={() => { setConversationLoadError(null); setConversationRetry((value) => value + 1); }}>重试</button></div>}
        <ServerRail
          groups={groups}
          currentGroupId={id ?? null}
          onSelectGroup={(gid) => navigate(`/group/${gid}`)}
          onCreateGroup={() => setShowGroupCreate(true)}
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
    tabsTransition = `transform ${EXIT_TRANSITION_MS}ms var(--ease-in)`;
  } else if (!entered) {
    tabsTransform = "translateY(calc(100vh - 64px))";
    tabsTransition = "transform 250ms var(--ease-out)";
  } else if (pullOffset > 0) {
    tabsTransform = `translateY(${pullOffset}px)`;
    tabsTransition = "none";
  } else {
    tabsTransform = "translateY(0)";
    tabsTransition = "transform 200ms var(--ease-out)";
  }
  const tabsStyle: CSSProperties = {
    transform: tabsTransform,
    transition: tabsTransition,
  };

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

      {/* 五子界面滑动容器（横向手势；内容单页渲染 + key 切换淡入） */}
      <div className="group-scene" {...swipe.handlers}>
        <div className="group-scene-inner" key={activeScene}>{renderScene()}</div>
      </div>
    </div>
  );
}
