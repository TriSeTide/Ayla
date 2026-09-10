/**
 * MessagesPage —— 消息中心（路由 /messages，F8，R-M1~M5）。
 *
 * 窄屏（≤768px）：NarrowTopBar + 双选项卡（私信/好友列表），点会话跳 /chat/:id。
 * 宽屏（>768px）：两列——左 260px 会话列表侧栏（WideMessagesSidebar，宽度与主页
 *  ChannelSidebar 一致）+ 右侧聊天内容区（选中会话内联 PrivateChatPane，不跳转 URL）。
 * 申请条目：好友申请 + 群邀请 + 待审批入群申请，同意/拒绝即时反馈。
 */
import { useTabPanelMotion } from "../hooks/useTabPanelMotion";
import { AuroraquaNavHighlight } from "../components/motion/AuroraquaNavHighlight";
import { useCallback, useEffect, useId, useMemo, useRef, useState } from "react";
import { useNavigate } from "react-router-dom";
import * as chatApi from "../api/chat";
import { useSocialPage } from "../hooks/useSocialPage";
import { DirectoryLoadMore } from "../components/DirectoryLoadMore";
import { getElysiaProfile } from "../api/elysia";
import * as usersApi from "../api/users";
import type { ElysiaProfile, FriendRequest, GroupInvite, GroupJoinRequest, UserPublic } from "../api/types";
import { Avatar } from "../components/Avatar";
import { PrivateChatPane } from "../components/chat/PrivateChatPane";
import { WideMessagesSidebar } from "../components/chat/WideMessagesSidebar";
import { ConversationList } from "../components/chat/ConversationList";
import { ElysiaEntry } from "../components/chat/ElysiaEntry";
import { PullToRefresh } from "../components/motion/PullToRefresh";
import { ConversationTransition } from "../components/motion/ConversationTransition";
import { NARROW_QUERY, useMediaQuery } from "../hooks/useMediaQuery";
import { useBadgesStore } from "../stores/badges";
import { useChatStore, sortPrivateByActivity } from "../stores/chat";
import { useAuthStore } from "../stores/auth";
import { usePresenceStore } from "../stores/presence";
import { useNoticeStore } from "../stores/notices";
import { useShellStore } from "../stores/shell";
import { presenceOnline, withLiveStatus } from "../utils/displayStatus";
import { goUserProfile } from "../utils/navigation";
import { chatWS } from "../ws/chat";

type Tab = "chat" | "friends" | "requests";

export function MessagesPage() {
  const selectionId = useId();
  const isNarrow = useMediaQuery(NARROW_QUERY);
  const navigate = useNavigate();
  const currentUser = useAuthStore((state) => state.currentUser);
  const onlineUsers = usePresenceStore((state) => state.users);
  const onlineStatuses = usePresenceStore((state) => state.statuses);
  const realtimeNotices = useNoticeStore((state) => state.notices);
  const dismissNotice = useNoticeStore((state) => state.dismiss);
  const realtimeLeaveNotices = realtimeNotices.filter((notice) => notice.kind === "group.member.left");
  const [tab, setTab] = useState<Tab>("chat");
  const privatePage = useSocialPage("conversations", { type: "private" });
  const conversations = privatePage.items;
  const friendsPage = useSocialPage("friends", {}, tab === "friends");
  const { items: friendList, setItems: setFriendList } = friendsPage;
  const friendRequestPage = useSocialPage("friendRequests", {}, tab === "requests");
  const { items: friendRequests, setItems: setFriendRequests } = friendRequestPage;
  const invitePage = useSocialPage("invites", {}, tab === "requests");
  const { items: invites, setItems: setInvites } = invitePage;
  const joinPage = useSocialPage("joinRequests", {}, tab === "requests");
  const { items: joinRequests, setItems: setJoinRequests } = joinPage;
  const leavePage = useSocialPage("leaveNotices", {}, tab === "requests");
  const { items: leaveNotices, setItems: setLeaveNotices } = leavePage;

  const tabPanelRef = useTabPanelMotion<HTMLDivElement>(tab, ":scope > .messages-private, :scope > .messages-friends");
  // 宽屏右侧选中的私聊会话 id（内联聊天）
  const [activeChatId, setActiveChatId] = useState<string | null>(null);
  const conversationsLoading = privatePage.loading;
  // 私信列表按「最近活跃」排序（戳一戳/新消息 bump 后往前排；置顶优先）
  const conversationActivityAt = useChatStore((s) => s.conversationActivityAt);
  const privateRef = useRef<HTMLDivElement>(null);
  // §3.4 刷新动画：刷新完成后递增，key 变化强制会话列表重挂载 → reveal 重播
  const [revealNonce, setRevealNonce] = useState(0);
  const [elysiaProfile, setElysiaProfile] = useState<ElysiaProfile | null>(null);
  const [removingFriendId, setRemovingFriendId] = useState<string | null>(null);

  // 爱莉入口（私信 tab 顶部）
  useEffect(() => {
    getElysiaProfile()
      .then((p) => setElysiaProfile(p.enabled ? p : null))
      .catch(() => {});
  }, []);

  // 好友 tab 数据（窄屏用；宽屏由 WideMessagesSidebar 自理）
  const refreshSocial0 = friendsPage.refresh;
  const refreshSocial1 = friendRequestPage.refresh;
  const refreshSocial2 = invitePage.refresh;
  const refreshSocial3 = joinPage.refresh;
  const refreshSocial4 = leavePage.refresh;
  const loadFriendsTab = useCallback(() => {
    void refreshSocial0(); void refreshSocial1(); void refreshSocial2(); void refreshSocial3(); void refreshSocial4();
  }, [refreshSocial0, refreshSocial1, refreshSocial2, refreshSocial3, refreshSocial4]);

  // 认证消息红点：以 badges store 为权威（WS 事件驱动 fetch，实时刷新）
  const badges = useBadgesStore((s) => s.badges);
  const requestBadgeCount = badges ? useBadgesStore.getState().requestBadge() : 0;

  // 收到认证相关 WS 事件 → 实时刷新认证消息列表（好友申请/群邀请/入群申请）
  useEffect(() => {
    const off = chatWS.onFrame((frame) => {
      if (
        frame.type === "friend.request.new" ||
        frame.type === "friend.request.resolved" ||
        frame.type === "group.invite.new" ||
        frame.type === "group.request.new" ||
        frame.type === "group.request.resolved"
      ) {
        loadFriendsTab();
      }
    });
    return off;
  }, [loadFriendsTab]);

  const refreshBadges = () => void useBadgesStore.getState().fetch();

  const handleRemoveFriend = useCallback(async (userId: string) => {
    if (removingFriendId) return;
    setRemovingFriendId(userId);
    try {
      await usersApi.deleteFriend(userId);
      setFriendList((prev) => prev.filter((item) => item.user.id !== userId));
      refreshBadges();
    } catch {
      // 解除好友失败静默
    } finally {
      setRemovingFriendId(null);
    }
  }, [removingFriendId]);

  // 好友申请处理
  const handleFriendAction = useCallback((req: FriendRequest, action: "accept" | "reject") => {
    usersApi.actionFriendRequest(req.id, action).then(() => {
      setFriendRequests((prev) => prev.filter((r) => r.id !== req.id));
      refreshBadges();
    }).catch(() => {});
  }, []);

  // 群邀请处理
  const handleInviteAction = useCallback((inv: GroupInvite, action: "accept" | "reject") => {
    chatApi.actionGroupInvite(inv.id, action).then(() => {
      setInvites((prev) => prev.filter((i) => i.id !== inv.id));
      refreshBadges();
    }).catch(() => {});
  }, []);

  // 入群申请审批
  const handleJoinRequestAction = useCallback((req: GroupJoinRequest, action: "accept" | "reject") => {
    chatApi.actionJoinRequest(req.id, action).then(() => {
      setJoinRequests((prev) => prev.filter((r) => r.id !== req.id));
      refreshBadges();
    }).catch(() => {});
  }, []);

  const privateConvs = useMemo(
    () => sortPrivateByActivity(
      conversations.filter((c) => c.type === "private"),
      conversationActivityAt,
    ),
    [conversations, conversationActivityAt],
  );

  // 下拉刷新/刷新键共用：强制重拉会话列表（绕过 isChatStale 缓存）。
  const refreshPrivate = privatePage.refresh;
  const refreshConversations = useCallback(async () => {
    await refreshPrivate();
    setRevealNonce((n) => n + 1);
  }, [refreshPrivate]);

  // §3.4 RefreshFAB：注册当前页刷新回调（复用下拉刷新通道；引用守卫见 HomePage）
  useEffect(() => {
    useShellStore.getState().registerRefresh(refreshConversations);
    return () => {
      if (useShellStore.getState().refreshCallback === refreshConversations) {
        useShellStore.getState().registerRefresh(null);
      }
    };
  }, [refreshConversations]);

  // 下拉刷新仅当私信列表滚动容器（.messages-private）已在顶部时响应
  const isPrivateAtTop = useCallback(() => (privateRef.current?.scrollTop ?? 0) <= 0, []);

  // 宽屏两列：左会话列表侧栏 + 右聊天内容区
  if (!isNarrow) {
    return (
      <div className="messages-page messages-page-wide">
        <WideMessagesSidebar
          activeId={activeChatId}
          onSelect={(id) => setActiveChatId(id)}
          revealNonce={revealNonce}
        />
        <div className="wide-messages-pane">
          <ConversationTransition identity={`private:${activeChatId ?? "empty"}`} panels={activeChatId != null}>
          {activeChatId ? (
            <PrivateChatPane conversationId={activeChatId} panelMotion />
          ) : (
            <div className="wide-messages-empty">
              <h3 className="placeholder-title">选择一个会话开始聊天</h3>
              <p className="placeholder-desc">左侧会话列表，点击进入私聊</p>
            </div>
          )}
          </ConversationTransition>
        </div>
      </div>
    );
  }

  // 窄屏：双选项卡 + 列表，点会话跳 /chat/:id
  return (
    <div className="messages-page" ref={tabPanelRef}>
      <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', padding: '0 16px' }}>
        <div className="messages-tabs" role="tablist" aria-label="消息中心" style={{ flex: 1 }}>
          <button
            type="button"
            role="tab"
            aria-selected={tab === "chat"}
            className={`messages-tab has-auroraqua-highlight ${tab === "chat" ? "is-active" : ""}`}
            onClick={() => setTab("chat")}
          >
            {tab === "chat" && <AuroraquaNavHighlight id={selectionId} />}
            <span className="auroraqua-nav-label">私信</span>
          </button>
          <button
            type="button"
            role="tab"
            aria-selected={tab === "friends"}
            className={`messages-tab has-auroraqua-highlight ${tab === "friends" ? "is-active" : ""}`}
            onClick={() => setTab("friends")}
          >
            {tab === "friends" && <AuroraquaNavHighlight id={selectionId} />}
            <span className="auroraqua-nav-label">好友列表</span>
          </button>
          <button
            type="button"
            role="tab"
            aria-selected={tab === "requests"}
            className={`messages-tab has-auroraqua-highlight messages-tab-requests ${tab === "requests" ? "is-active" : ""}`}
            onClick={() => setTab("requests")}
          >
            {tab === "requests" && <AuroraquaNavHighlight id={selectionId} />}
            <span className="auroraqua-nav-label">认证消息</span>
            {requestBadgeCount > 0 && (
              <span className="messages-tab-badge">{requestBadgeCount}</span>
            )}
          </button>
        </div>
      </div>

      {tab === "chat" ? (
        <div className="messages-private" ref={privateRef}>
          <PullToRefresh isAtTop={isPrivateAtTop} onRefresh={refreshConversations}>
            {elysiaProfile && (
              <ElysiaEntry
                profile={elysiaProfile}
                onEnter={() => {
                  chatApi
                    .openPrivateConversation(elysiaProfile.user.id)
                    .then((conv) => navigate(`/chat/${conv.id}`))
                    .catch(() => {});
                }}
              />
            )}
            <ConversationList
              key={revealNonce}
              conversations={privateConvs}
              activeId={null}
              elysiaUserId={elysiaProfile?.user.id ?? null}
              onSelect={(id) => navigate(`/chat/${id}`)}
              revealItems={!conversationsLoading}
            />
          <DirectoryLoadMore {...privatePage} retainCompletedSpace={false} />
          </PullToRefresh>
        </div>
      ) : tab === "friends" ? (
        <div className="messages-friends">
          <section className="messages-group">
            <h3 className="messages-group-title">我的好友（{friendsPage.total}）</h3>
            {friendList.map((f) => (
              <div key={f.user.id} className="friend-row">
                <button
                  type="button"
                  className="friend-row-main"
                  onClick={() => {
                    chatApi.openPrivateConversation(f.user.id)
                      .then((conv) => navigate(`/chat/${conv.id}`))
                      .catch(() => {});
                  }}
                >
                  <Avatar
                    label={f.user.nickname || f.user.username}
                    size={40}
                    online={presenceOnline(onlineUsers, withLiveStatus(onlineStatuses, f.user))}
                    imageUrl={f.user.avatar || null}
                    onClick={(e) => {
                      e.stopPropagation();
                      goUserProfile(useAuthStore.getState().currentUser?.id, f.user.id);
                    }}
                    ariaLabel={`查看 ${f.user.nickname || f.user.username} 的个人主页`}
                  />
                  <span className="friend-row-name">{f.user.nickname || f.user.username}</span>
                </button>
                <button
                  type="button"
                  className="btn btn-ghost friend-remove-btn"
                  disabled={removingFriendId === f.user.id}
                  onClick={() => void handleRemoveFriend(f.user.id)}
                >
                  {removingFriendId === f.user.id ? "解除中…" : "解除好友"}
                </button>
              </div>
            ))}
            {friendList.length === 0 && !friendsPage.loading && !friendsPage.error && (
              <p className="messages-empty">还没有好友，去搜索添加吧</p>
            )}
          </section>
        <DirectoryLoadMore {...friendsPage} retainCompletedSpace={false} />
          </div>
      ) : (
        <div className="messages-friends messages-requests" aria-label="认证消息">
          <section className="messages-group">
            <h3 className="messages-group-title">认证消息</h3>
            <p className="messages-section-hint">好友申请、群邀请和入群申请都会集中显示在这里。</p>
          </section>
          {(leaveNotices.length > 0 || realtimeLeaveNotices.length > 0 || leavePage.loading || !!leavePage.error || leavePage.hasMore) && (
            <section className="messages-group">
              <h3 className="messages-group-title">退群通知</h3>
              {leaveNotices.map((notice) => (
                <div key={`persisted-${notice.id}`} className="request-row notice-row">
                  <div className="request-body"><span className="request-name">群成员已离开</span><span className="request-msg">{notice.conversation_title}：{notice.member_name} 已离开</span></div>
                  <button type="button" className="btn btn-ghost request-btn" onClick={() => { void chatApi.readLeaveNotice(notice.id).then(() => setLeaveNotices((items) => items.filter((item) => item.id !== notice.id))).catch(() => {}); }}>知道了</button>
                </div>
              ))}
              {realtimeLeaveNotices.map((notice) => (
                <div key={notice.id} className="request-row notice-row">
                  <div className="request-body"><span className="request-name">{notice.title}</span><span className="request-msg">{notice.detail}</span></div>
                  <button type="button" className="btn btn-ghost request-btn" onClick={() => dismissNotice(notice.id)}>知道了</button>
                </div>
              ))}
            <DirectoryLoadMore {...leavePage} retainCompletedSpace={false} />
            </section>
          )}
          {(friendRequests.length > 0 || friendRequestPage.loading || !!friendRequestPage.error || friendRequestPage.hasMore) && (
            <section className="messages-group">
              <h3 className="messages-group-title">好友申请</h3>
              {friendRequests.filter((r) => r.to_user.id === currentUser?.id && r.status === "pending").map((r) => (
                <RequestRow key={r.id} avatar={r.from_user} name={r.from_user.nickname || r.from_user.username} message={r.message} onAccept={() => handleFriendAction(r, "accept")} onReject={() => handleFriendAction(r, "reject")} />
              ))}
            <DirectoryLoadMore {...friendRequestPage} retainCompletedSpace={false} />
            </section>
          )}
          {(invites.length > 0 || invitePage.loading || !!invitePage.error || invitePage.hasMore) && (
            <section className="messages-group">
              <h3 className="messages-group-title">群邀请</h3>
              {invites.map((i) => <RequestRow key={i.id} avatar={i.inviter} name={i.conversation_title} message="邀请你加入群聊" onAccept={() => handleInviteAction(i, "accept")} onReject={() => handleInviteAction(i, "reject")} />)}
            <DirectoryLoadMore {...invitePage} retainCompletedSpace={false} />
            </section>
          )}
          {(joinRequests.length > 0 || joinPage.loading || !!joinPage.error || joinPage.hasMore) && (
            <section className="messages-group">
              <h3 className="messages-group-title">入群申请（群主/管理员）</h3>
              {joinRequests.map((r) => <RequestRow key={r.id} avatar={r.applicant} name={r.applicant.nickname || r.applicant.username} message={r.message ? r.conversation_title + "：" + r.message : r.conversation_title} onAccept={() => handleJoinRequestAction(r, "accept")} onReject={() => handleJoinRequestAction(r, "reject")} />)}
            <DirectoryLoadMore {...joinPage} retainCompletedSpace={false} />
            </section>
          )}
          {friendRequests.filter((r) => r.to_user.id === currentUser?.id && r.status === "pending").length === 0 && invites.length === 0 && joinRequests.length === 0 && leaveNotices.length === 0 && realtimeLeaveNotices.length === 0 && ![leavePage, invitePage, joinPage, friendRequestPage].some((page) => page.loading || page.error || page.hasMore) && <p className="messages-empty">暂无待处理认证消息</p>}
        </div>
      )}
    </div>
  );
}

function RequestRow({
  avatar,
  name,
  message,
  onAccept,
  onReject,
}: {
  avatar: Pick<UserPublic, "id" | "status" | "nickname" | "username" | "avatar" | "online">;
  name: string;
  message: string;
  onAccept: () => void;
  onReject: () => void;
}) {
  const onlineUsers = usePresenceStore((s) => s.users);
  const onlineStatuses = usePresenceStore((s) => s.statuses);
  return (
    <div className="request-row">
      <Avatar label={avatar.nickname || avatar.username} size={36} online={presenceOnline(onlineUsers, withLiveStatus(onlineStatuses, avatar))} imageUrl={avatar.avatar || null} />
      <div className="request-body">
        <span className="request-name">{name}</span>
        {message && <span className="request-msg">{message}</span>}
      </div>
      <div className="request-actions">
        <button type="button" className="btn btn-primary request-btn" onClick={onAccept}>
          同意
        </button>
        <button type="button" className="btn btn-ghost request-btn" onClick={onReject}>
          拒绝
        </button>
      </div>
    </div>
  );
}
