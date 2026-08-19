/**
 * HomePage —— 窄屏主页（群聊集合，F2）+ 宽屏 /home 重定向。
 *
 * 窄屏：NarrowTopBar（头像/搜索/更多）+ 布局开关 + 群卡片（轮播 + 状态角标）/
 * 群列表 双布局；空态 / 骨架屏 / 失败重试（R-H9）；增量加载更多（R-H6）。
 * 宽屏：主页 = 三列群聊界面（无群卡片网格中间层，定稿决策）——重定向到
 *   /group/<最近群>（localStorage，无历史取第一个群；无群空态引导）。
 *
 * 数据：群会话列表（chat store）+ 群动态 highlights（S6 批量接口）。
 * 状态角标 live/voice/game 数据源由 F4/F5/F7 接入（badges.ts 已定义契约）。
 */
import { useCallback, useEffect, useMemo, useState } from "react";
import { Navigate, useNavigate } from "react-router-dom";
import * as chatApi from "../api/chat";
import type { ConversationHighlightsMap } from "../api/types";
import { GroupCard } from "../components/home/GroupCard";
import { GroupListItem } from "../components/home/GroupListItem";
import { LayoutSwitch } from "../components/home/LayoutSwitch";
import { GroupCreateDialog } from "../components/GroupCreateDialog";
import { NARROW_QUERY, useMediaQuery } from "../hooks/useMediaQuery";
import { NarrowTopBar } from "../layout/NarrowTopBar";
import { useChatStore, isChatStale } from "../stores/chat";
import { useHomeStore } from "../stores/home";

/** 卡片布局每批渲染数（增量加载更多，R-H6） */
const PAGE_SIZE = 12;

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
  const isNarrow = useMediaQuery(NARROW_QUERY);
  const navigate = useNavigate();
  const conversations = useChatStore((s) => s.conversations);
  const listLoading = useChatStore((s) => s.loading);
  const { layout, setLayout, recentGroupId } = useHomeStore((s) => s);

  const [highlights, setHighlights] = useState<ConversationHighlightsMap>({});
  const [listError, setListError] = useState<string | null>(null);
  const [visibleCount, setVisibleCount] = useState(PAGE_SIZE);
  const [creatingGroup, setCreatingGroup] = useState(false);

  const groups = useMemo(
    () => conversations.filter((c) => c.type === "group"),
    [conversations],
  );

  // 加载会话列表（直接访问 /home 时 chat store 可能为空）
  useEffect(() => {
    let cancelled = false;
    const { setLoading, setConversations, setError } = useChatStore.getState();
    if (conversations.length > 0 && !isChatStale()) return; // 已有数据且未过期
    setLoading(true);
    setError(null);
    chatApi
      .listConversations()
      .then((list) => {
        if (!cancelled) setConversations(list);
      })
      .catch((e) => {
        if (!cancelled) {
          setLoading(false);
          setListError(e instanceof Error ? e.message : "加载失败");
        }
      })
      .finally(() => {
        if (!cancelled) setLoading(false);
      });
    return () => {
      cancelled = true;
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  // 群动态 highlights 批量拉取（失败降级：无动态回退群头像）
  useEffect(() => {
    const ids = groups.map((g) => g.id);
    if (ids.length === 0) {
      setHighlights({});
      return;
    }
    let cancelled = false;
    chatApi
      .fetchHighlights(ids)
      .then((map) => {
        if (!cancelled) setHighlights(map);
      })
      .catch(() => {
        if (!cancelled) setHighlights({});
      });
    return () => {
      cancelled = true;
    };
  }, [groups]);

  // 增量加载更多：滚到底补一批
  const handleScroll = useCallback(
    (el: HTMLElement) => {
      if (visibleCount >= groups.length) return;
      if (el.scrollHeight - el.scrollTop - el.clientHeight < 240) {
        setVisibleCount((n) => Math.min(n + PAGE_SIZE, groups.length));
      }
    },
    [visibleCount, groups.length],
  );

  const openGroup = useCallback(
    (id: string) => {
      useHomeStore.getState().setRecentGroup(id);
      navigate(`/group/${id}`);
    },
    [navigate],
  );

  // 点击轮播封面 → 打开动态（后端给的相对 target_url）
  const openHighlight = useCallback(
    (h: { target_url: string }) => {
      navigate(h.target_url);
    },
    [navigate],
  );

  // ---- 宽屏：重定向到最近群（无群空态引导） ----
  if (!isNarrow) {
    const recentValid = recentGroupId != null && groups.some((g) => g.id === recentGroupId);
    const target = recentValid ? recentGroupId : groups[0]?.id;
    if (target) {
      return <Navigate to={`/group/${target}`} replace />;
    }
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
  const visibleGroups = groups.slice(0, visibleCount);
  const loading = listLoading && groups.length === 0;

  return (
    <div
      className="home-page"
      onScroll={(e) => handleScroll(e.currentTarget)}
    >
      <NarrowTopBar />
      <div className="home-toolbar">
        <h1 className="home-title">群聊</h1>
        <LayoutSwitch layout={layout} onChange={setLayout} />
      </div>

      {loading ? (
        <SkeletonCards />
      ) : listError ? (
        <div className="home-state" role="alert">
          <p className="placeholder-desc">{listError}</p>
          <button
            type="button"
            className="btn btn-ghost"
            onClick={() => {
              setListError(null);
              useChatStore.getState().setLoading(true);
              chatApi
                .listConversations()
                .then((l) => useChatStore.getState().setConversations(l))
                .catch((e) =>
                  setListError(e instanceof Error ? e.message : "加载失败"),
                );
            }}
          >
            重试
          </button>
        </div>
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
      ) : layout === "card" ? (
        <>
          <div className="home-grid">
            {visibleGroups.map((g) => (
              <GroupCard
                key={g.id}
                group={{ id: g.id, title: g.title, avatar: g.avatar, memberCount: g.member_count }}
                highlights={highlights[g.id] ?? []}
                status={{ unread: g.unread_count }}
                onOpen={() => openGroup(g.id)}
                onOpenHighlight={openHighlight}
              />
            ))}
          </div>
          {visibleCount < groups.length && (
            <div className="home-load-more" aria-label="加载更多">
              <span className="home-load-dot" />
              <span className="home-load-dot" />
              <span className="home-load-dot" />
            </div>
          )}
        </>
      ) : (
        <div className="home-list">
          {visibleGroups.map((g) => (
            <GroupListItem
              key={g.id}
              group={{ id: g.id, title: g.title, avatar: g.avatar, memberCount: g.member_count }}
              status={{ unread: g.unread_count }}
              onOpen={() => openGroup(g.id)}
            />
          ))}
          {visibleCount < groups.length && (
            <div className="home-load-more" aria-label="加载更多">
              <span className="home-load-dot" />
              <span className="home-load-dot" />
              <span className="home-load-dot" />
            </div>
          )}
        </div>
      )}
      {creatingGroup && <GroupCreateDialog onClose={() => setCreatingGroup(false)} />}
    </div>
  );
}
