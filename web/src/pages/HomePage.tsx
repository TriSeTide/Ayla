/**
 * HomePage —— 窄屏主页（群聊集合，F2）+ 宽屏 /group 重定向。
 *
 * 窄屏：NarrowTopBar（头像/搜索/更多）+ 布局开关 + 群卡片（轮播 + 状态角标）/
 * 群列表 双布局；空态 / 骨架屏 / 失败重试（R-H9）；增量加载更多（R-H6）。
 * 宽屏：主页 = 三列群聊界面（无群卡片网格中间层，定稿决策）——重定向到
 *   /group/<最近群>（localStorage，无历史取第一个群；无群空态引导）。
 *
 * 数据：群会话列表（chat store）+ 群动态 highlights（S6 批量接口）。
 * 状态角标 live/voice/game 数据源由 F4/F5/F7 接入（badges.ts 已定义契约）。
 */
import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { useIsPresent } from "framer-motion";
import { Navigate, useNavigate } from "react-router-dom";
import * as chatApi from "../api/chat";
import { useSocialPage } from "../hooks/useSocialPage";
import { DirectoryLoadMore } from "../components/DirectoryLoadMore";
import { GroupCard } from "../components/home/GroupCard";
import { GroupListItem } from "../components/home/GroupListItem";
import { LayoutSwitch } from "../components/home/LayoutSwitch";
import {
  sortGroupsByActivity,
  useGroupActivityMap,
  useGroupCarouselSlides,
  useGroupPresenceMap,
} from "../components/home/groupActivity";
import { GroupCreateDialog } from "../components/GroupCreateDialog";
import { PullToRefresh } from "../components/motion/PullToRefresh";
import { NARROW_QUERY, useMediaQuery } from "../hooks/useMediaQuery";
import { staggerDelay } from "../hooks/useRevealOnEnter";
import { useChatStore } from "../stores/chat";
import { useHomeStore } from "../stores/home";
import { useShellStore } from "../stores/shell";

function SkeletonCards() {
  return (
    <div className="home-grid" aria-hidden="true">
      {Array.from({ length: 6 }).map((_, i) => (
        <div key={i} className="group-card is-skeleton">
          <div className="skeleton" style={{ height: 120, margin: 8, borderRadius: 12 }} />
          <div className="skeleton" style={{ height: 20, margin: "8px 12px 12px", width: "60%" }} />
        </div>
      ))}
    </div>
  );
}

export function HomePage() {
  const present = useIsPresent();
  const isNarrow = useMediaQuery(NARROW_QUERY);
  const navigate = useNavigate();
  const groupPage = useSocialPage("conversations", { type: "group" }, present);
  const conversations = groupPage.items;
  const listLoading = groupPage.loading;
  const { layout, setLayout, recentGroupId } = useHomeStore((s) => s);

  const listError = groupPage.error;
  const [actionError, setActionError] = useState<string | null>(null);
  const [resolvedRecent, setResolvedRecent] = useState<string | null | undefined>(undefined);
  const [creatingGroup, setCreatingGroup] = useState(false);
  // §3.4 刷新动画：刷新完成后递增，key 变化强制群列表重挂载 → reveal 重播
  const [revealNonce, setRevealNonce] = useState(0);
  const homeRef = useRef<HTMLDivElement>(null);

  const groups = useMemo(
    () => conversations.filter((c) => c.type === "group"),
    [conversations],
  );

  // 群"新内容"（排序/事件描述）与"存在内容"（角标）分开：
  // - 排序：近期新事件（新消息/新开播/新语音房/新桌游房/新帖），WS 实时刷新
  // - 角标：当前有直播在播/语音房/桌游房（存在性）
  // - 状态轮播：消息(未读)+语音(有人)/直播(在播)/帖子(窗口内最新)，WS 实时刷新
  const activityFor = useGroupActivityMap();
  const presenceFor = useGroupPresenceMap();
  const carouselFor = useGroupCarouselSlides();

  // 排序：置顶 > 有新内容（按最近事件时间新→旧）> 其余，无新内容保持稳定
  const sortedGroups = sortGroupsByActivity(groups, (g) =>
    activityFor(g.id, g.last_message),
  );

  // A saved group can be outside the first visible page; validate it directly.
  useEffect(() => {
    if (isNarrow || !recentGroupId || !present) return;
    let active = true;
    setResolvedRecent(undefined);
    void chatApi.getConversationSummary(recentGroupId).then((conversation) => {
      if (!active) return;
      useChatStore.getState().upsertConversation(conversation);
      setResolvedRecent(conversation.type === "group" ? conversation.id : null);
    }).catch(() => { if (active) setResolvedRecent(null); });
    return () => { active = false; };
  }, [isNarrow, recentGroupId, present]);

  const openGroup = useCallback(
    (id: string) => {
      useHomeStore.getState().setRecentGroup(id);
      navigate(`/group/${id}`);
    },
    [navigate],
  );

  // 下拉刷新/刷新键共用：强制重拉群会话列表（绕过 isChatStale 缓存）；群动态由 WS 实时维护。
  const refreshGroups = useCallback(async () => {
    await groupPage.refresh();
    setRevealNonce((n) => n + 1);
  }, [groupPage.refresh]);
  const retryGroups = groupPage.refresh;

  // §3.4 RefreshFAB：注册当前页刷新回调（复用下拉刷新通道；cleanup 引用守卫，
  // 避免 AnimatePresence sync 转场期间旧页 cleanup 覆盖后注册的新页回调）
  useEffect(() => {
    useShellStore.getState().registerRefresh(refreshGroups);
    return () => {
      if (useShellStore.getState().refreshCallback === refreshGroups) {
        useShellStore.getState().registerRefresh(null);
      }
    };
  }, [refreshGroups]);

  // 下拉刷新仅当滚动容器（.home-page）已在顶部时响应
  const isAtTop = useCallback(() => (homeRef.current?.scrollTop ?? 0) <= 0, []);

  const listFailure = listError ? (
    <div className="home-state" role="alert">
      <p className="placeholder-desc">{listError}</p>
      <button type="button" className="btn btn-ghost" onClick={() => void retryGroups()}>
        重试
      </button>
    </div>
  ) : null;

  // ---- 宽屏：重定向到最近群（无群空态引导） ----
  if (!isNarrow) {
    // AnimatePresence retains the exiting page; its Navigate must not redirect a newer route.
    if (!present) return null;
    const recentValid = recentGroupId != null && groups.some((g) => g.id === recentGroupId);
    const target = recentValid ? recentGroupId : resolvedRecent ?? (recentGroupId && resolvedRecent === undefined ? null : groups[0]?.id);
    if (target) {
      return <Navigate to={`/group/${target}`} replace />;
    }
    if (listLoading || (recentGroupId && resolvedRecent === undefined)) {
      return (
        <div className="home-page" role="status" aria-label="正在加载群聊">
          <SkeletonCards />
        </div>
      );
    }
    if (listFailure) return <div className="home-page">{listFailure}</div>;
    return (
      <div className="home-wide-empty">
        <h2 className="placeholder-title">还没有加入群聊</h2>
        <p className="placeholder-desc">创建或加入一个群聊，这里是你的「家」</p>
        <button type="button" className="btn btn-glow" onClick={() => setCreatingGroup(true)}>
          创建你的第一个群
        </button>
        {creatingGroup && <GroupCreateDialog onClose={() => setCreatingGroup(false)} />}
      </div>
    );
  }

  // ---- 窄屏主页 ----
  const visibleGroups = sortedGroups;
  const loading = listLoading && groups.length === 0;

  return (
    <div
      className="home-page"
      ref={homeRef}
      onScroll={(e) => groupPage.onScroll(e.currentTarget)}
    >
      <div className="home-toolbar">
        <h1 className="home-title">群聊</h1>
        <LayoutSwitch layout={layout} onChange={setLayout} />
      </div>
      {actionError && (
        <div
          className="messages-action-error"
          role="alert"
          onClick={() => setActionError(null)}
        >
          {actionError}（点击关闭）
        </div>
      )}

      {loading ? (
        <SkeletonCards />
      ) : listError && groups.length === 0 ? (
        listFailure
      ) : groups.length === 0 ? (
        <div className="home-state">
          <h2 className="placeholder-title">创建你的第一个群</h2>
          <p className="placeholder-desc">和朋友们聚在一起，从这里开始</p>
          <button type="button" className="btn btn-glow" onClick={() => setCreatingGroup(true)}>
            创建群聊
          </button>
          <button type="button" className="btn btn-ghost" onClick={() => navigate("/search")}>
            搜索发现群
          </button>
        </div>
      ) : (
        <PullToRefresh isAtTop={isAtTop} onRefresh={refreshGroups}>
          {layout === "card" ? (
            <>
              <div className="home-grid" key={revealNonce}>
                {visibleGroups.map((g, idx) => (
                  <GroupCard
                    key={g.id}
                    group={{ id: g.id, title: g.title, avatar: g.avatar, memberCount: g.member_count }}
                    slides={carouselFor(g.id, g.unread_count)}
                    unread={g.unread_count + (g.post_unread_count ?? 0)}
                    isPinned={g.is_pinned}
                    onOpen={() => openGroup(g.id)}
                    onError={setActionError}
                    revealDelay={staggerDelay(idx)}
                  />
                ))}
              </div>
            </>
          ) : (
            <div className="home-list" key={revealNonce}>
              {visibleGroups.map((g, idx) => {
                const act = activityFor(g.id, g.last_message);
                return (
                  <GroupListItem
                    key={g.id}
                    group={{ id: g.id, title: g.title, avatar: g.avatar, memberCount: g.member_count }}
                    status={{ unread: g.unread_count + (g.post_unread_count ?? 0), ...presenceFor(g.id) }}
                    newEventText={act.lastEvent?.text}
                    isPinned={g.is_pinned}
                    onOpen={() => openGroup(g.id)}
                    onError={setActionError}
                    revealDelay={staggerDelay(idx)}
                  />
                );
              })}
            </div>
          )}
          <DirectoryLoadMore {...groupPage} />
        </PullToRefresh>
      )}
      {creatingGroup && <GroupCreateDialog onClose={() => setCreatingGroup(false)} />}
    </div>
  );
}
