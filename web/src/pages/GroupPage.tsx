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
import { useCallback, useEffect, useMemo } from "react";
import { useNavigate, useParams } from "react-router-dom";
import type { CSSProperties } from "react";
import * as chatApi from "../api/chat";
import { GroupTopTabs } from "../components/group/GroupTopTabs";
import { NARROW_QUERY, useMediaQuery } from "../hooks/useMediaQuery";
import { useEnterGroupAnimation } from "../hooks/useEnterGroupAnimation";
import { useSwipe } from "../hooks/useSwipe";
import { ChannelSidebar } from "../layout/ChannelSidebar";
import { ServerRail } from "../layout/ServerRail";
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

const VALID_SCENES = new Set<string>(GROUP_SCENE_ORDER);

export function GroupPage() {
  const { id, scene } = useParams<{ id: string; scene?: string }>();
  const navigate = useNavigate();
  const isNarrow = useMediaQuery(NARROW_QUERY);

  const conversations = useChatStore((s) => s.conversations);
  const activeScene = useGroupStore((s) => s.activeScene);
  const setActiveScene = useGroupStore((s) => s.setActiveScene);
  const setCurrentGroup = useGroupStore((s) => s.setCurrentGroup);

  const { entered } = useEnterGroupAnimation();

  const groups = useMemo(
    () => conversations.filter((c) => c.type === "group"),
    [conversations],
  );
  const currentGroup = useMemo(
    () => conversations.find((c) => c.id === id) ?? null,
    [conversations, id],
  );

  // 单一状态源：route param → store（scene 无效回退 chat）
  const effectiveScene: GroupScene = scene && VALID_SCENES.has(scene) ? (scene as GroupScene) : "chat";

  useEffect(() => {
    if (!id) return;
    setCurrentGroup(id);
    setActiveScene(effectiveScene);
    useHomeStore.getState().setRecentGroup(id);
    // 进入即打开群会话（GroupChat 内部也 openConversation，幂等）
    useChatStore.getState().openConversation(id);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [id, effectiveScene]);

  // 直接访问 /group/:id 时会话列表可能为空：补齐加载（复用 chat store）
  useEffect(() => {
    if (conversations.length > 0) return;
    let cancelled = false;
    chatApi
      .listConversations()
      .then((list) => {
        if (!cancelled) useChatStore.getState().setConversations(list);
      })
      .catch(() => {});
    return () => {
      cancelled = true;
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

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
        return <GroupVoice groupId={id ?? ""} onExit={() => goScene("chat")} />;
      case "posts":
        return <GroupPosts groupId={id ?? ""} onExit={() => goScene("chat")} />;
      case "games":
        return <GroupGames groupId={id ?? ""} onExit={() => goScene("chat")} />;
      default:
        return <GroupScenePlaceholder scene={activeScene} />;
    }
  }, [activeScene, id, goScene]);

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
        <ServerRail
          groups={groups}
          currentGroupId={id ?? null}
          onSelectGroup={(gid) => navigate(`/group/${gid}`)}
        />
        <ChannelSidebar
          group={{ id: id ?? "" }}
          groupName={currentGroup?.title ?? "群聊"}
          activeScene={activeScene}
          onSelectScene={goScene}
          onOpenInfo={openInfo}
        />
        <main className="group-content">{renderScene()}</main>
      </div>
    );
  }

  // ---- 窄屏 ----
  const tabsStyle: CSSProperties = {
    transform: entered ? "translateY(0)" : "translateY(calc(100vh - 64px))",
    transition: "transform 250ms var(--ease-out)",
  };

  return (
    <div className="group-page group-page-narrow">
      <GroupTopTabs
        groupName={currentGroup?.title ?? "群聊"}
        activeScene={activeScene}
        onSelectScene={goScene}
        onAvatarClick={handleAvatarClick}
        style={tabsStyle}
      />

      {/* 五子界面滑动容器（横向手势；内容单页渲染 + key 切换淡入） */}
      <div className="group-scene" {...swipe.handlers}>
        <div className="group-scene-inner" key={activeScene}>{renderScene()}</div>
      </div>
    </div>
  );
}
