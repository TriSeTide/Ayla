/**
 * WideMessagesSidebar —— 宽屏消息左列（需求：与主页侧栏 ChannelSidebar 宽度一致）。
 *
 * 260px 玻璃侧栏（同 .channel-sidebar width）：私信 / 好友 双 tab。
 * - 私信 tab：会话列表（ConversationList，点击 onSelect）
 * - 好友 tab：好友列表 + 待处理申请置顶（复用 MessagesPage 的好友数据处理）
 * 用于宽屏 /messages（两列：本侧栏 + 右侧聊天内容区）与 /chat/:id（两列同构）。
 */
import { useTabPanelMotion } from "../../hooks/useTabPanelMotion";
import { AuroraquaNavHighlight } from "../motion/AuroraquaNavHighlight";
import { useCallback, useEffect, useId, useMemo, useState } from "react";
import { motion } from "framer-motion";
import { panelVariants } from "../motion/auroraquaMotion";
import { usePrefersReducedMotion } from "../../hooks/usePrefersReducedMotion";
import * as chatApi from "../../api/chat";
import { useSocialPage } from "../../hooks/useSocialPage";
import { DirectoryLoadMore } from "../../components/DirectoryLoadMore";
import * as usersApi from "../../api/users";
import type { ElysiaProfile, FriendRequest, GroupInvite, GroupJoinRequest } from "../../api/types";
import { Avatar } from "../Avatar";
import { ConversationList } from "./ConversationList";
import { ElysiaEntry } from "./ElysiaEntry";
import { useBadgesStore } from "../../stores/badges";
import { useChatStore, sortPrivateByActivity } from "../../stores/chat";
import { useAuthStore } from "../../stores/auth";
import { usePresenceStore } from "../../stores/presence";
import { useNoticeStore } from "../../stores/notices";
import { presenceOnline, withLiveStatus } from "../../utils/displayStatus";
import { goUserProfile } from "../../utils/navigation";
import { chatWS } from "../../ws/chat";
import type { ConversationSummary } from "../../api/types";

type Tab = "chat" | "friends" | "requests";

export function WideMessagesSidebar({
  activeId,
  onSelect,
  revealNonce = 0,
}: {
  /** 可选兼容属性；实时真源始终来自 store */
  conversations?: ConversationSummary[];
  /** 当前选中的私聊会话 id（高亮） */
  activeId: string | null;
  /** 点击会话 → 选中（/chat/:id 宽屏跳转；/messages 宽屏右侧内联） */
  onSelect: (id: string) => void;
  /** §3.4 刷新动画：刷新完成后的重挂载计数，key 变化触发会话列表 reveal 重播 */
  revealNonce?: number;
}) {
  // 直接订阅 store；保留 prop 仅兼容旧调用方，不使用其作为实时真源
  const selectionId = useId();
  const reduced = usePrefersReducedMotion();
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

  // 私信列表按「最近活跃」排序（戳一戳/新消息 bump 后往前排；置顶优先）
  const conversationActivityAt = useChatStore((s) => s.conversationActivityAt);
  const privateConversations = useMemo(
    () => sortPrivateByActivity(
      conversations.filter((c) => c.type === "private"),
      conversationActivityAt,
    ),
    [conversations, conversationActivityAt],
  );
  const loading = privatePage.loading;
  
  const tabPanelRef = useTabPanelMotion<HTMLElement>(tab, ":scope > .messages-private, :scope > .messages-friends");
  const currentUser = useAuthStore((state) => state.currentUser);
  const onlineUsers = usePresenceStore((state) => state.users);
  const onlineStatuses = usePresenceStore((state) => state.statuses);
  const realtimeNotices = useNoticeStore((state) => state.notices);
  const dismissNotice = useNoticeStore((state) => state.dismiss);
  const realtimeLeaveNotices = realtimeNotices.filter((notice) => notice.kind === "group.member.left");
  const [elysiaProfile, setElysiaProfile] = useState<ElysiaProfile | null>(null);
  /** 审批（同意/拒绝）失败提示（点击关闭） */
  const [actionError, setActionError] = useState<string | null>(null);
  const [loadError, setLoadError] = useState<string | null>(null);
  const [openError, setOpenError] = useState<string | null>(null);
  const [removingFriendId, setRemovingFriendId] = useState<string | null>(null);

  // 爱莉入口（私信 tab 顶部）
  useEffect(() => {
    import("../../api/elysia")
      .then(({ getElysiaProfile }) => getElysiaProfile())
      .then((p) => setElysiaProfile(p.enabled ? p : null))
      .catch((e) => setLoadError(e instanceof Error ? e.message : "加载爱莉资料失败"));
  }, []);

  // 打开与某用户的私聊会话（好友/爱莉点击 → 选中会话）
  const openUserChat = useCallback(
    (userId: string) => {
      setOpenError(null);
      chatApi.openPrivateConversation(userId)
        .then((conv) => onSelect(conv.id))
        .catch((e) => setOpenError(e instanceof Error ? e.message : "打开私聊失败"));
    },
    [onSelect],
  );

  // 好友 tab 数据
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

  // 收到认证相关 WS 事件 → 实时刷新认证消息列表
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
    setActionError(null);
    setRemovingFriendId(userId);
    try {
      await usersApi.deleteFriend(userId);
      setFriendList((prev) => prev.filter((item) => item.user.id !== userId));
      refreshBadges();
    } catch (e) {
      setActionError(e instanceof Error ? e.message : "解除好友失败");
    } finally {
      setRemovingFriendId(null);
    }
  }, [removingFriendId]);

  const handleFriendAction = useCallback((req: FriendRequest, action: "accept" | "reject") => {
    usersApi.actionFriendRequest(req.id, action).then(() => {
      setFriendRequests((prev) => prev.filter((r) => r.id !== req.id));
      refreshBadges();
    }).catch((e) => {
      setActionError(e instanceof Error ? e.message : "操作失败，请稍后重试");
    });
  }, []);

  const handleInviteAction = useCallback((inv: GroupInvite, action: "accept" | "reject") => {
    chatApi.actionGroupInvite(inv.id, action).then(() => {
      setInvites((prev) => prev.filter((i) => i.id !== inv.id));
      refreshBadges();
    }).catch((e) => {
      setActionError(e instanceof Error ? e.message : "操作失败，请稍后重试");
    });
  }, []);

  const handleJoinRequestAction = useCallback((req: GroupJoinRequest, action: "accept" | "reject") => {
    chatApi.actionJoinRequest(req.id, action).then(() => {
      setJoinRequests((prev) => prev.filter((r) => r.id !== req.id));
      refreshBadges();
    }).catch((e) => {
      setActionError(e instanceof Error ? e.message : "操作失败，请稍后重试");
    });
  }, []);

  return (
    <motion.aside
      className="wide-messages-sidebar"
      aria-label="消息列表"
      ref={tabPanelRef}
      data-motion-panel="private-list"
      inherit={false}
      initial={reduced ? false : "enter"}
      animate="center"
      variants={panelVariants(reduced, "left")}
    >
      {loadError && <div className="chat-notice" role="alert">{loadError}</div>}
      {openError && <div className="chat-notice" role="alert">{openError}</div>}
      {actionError && (
        <div className="messages-action-error" role="alert" onClick={() => setActionError(null)}>
          {actionError}（点击关闭）
        </div>
      )}
      <div className="messages-tabs">
        <button
          type="button"
          className={`messages-tab has-auroraqua-highlight ${tab === "chat" ? "is-active" : ""}`}
          onClick={() => setTab("chat")}
        >
          {tab === "chat" && <AuroraquaNavHighlight id={selectionId} />}
          <span className="auroraqua-nav-label">私信</span>
        </button>
        <button
          type="button"
          className={`messages-tab has-auroraqua-highlight ${tab === "friends" ? "is-active" : ""}`}
          onClick={() => setTab("friends")}
        >
          {tab === "friends" && <AuroraquaNavHighlight id={selectionId} />}
          <span className="auroraqua-nav-label">好友</span>
        </button>
        <button
          type="button"
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

      {tab === "chat" ? (
        <div className="messages-private">
          {elysiaProfile && (
            <ElysiaEntry
              profile={elysiaProfile}
              onEnter={() => openUserChat(elysiaProfile.user.id)}
            />
          )}
          <ConversationList
            key={revealNonce}
            conversations={privateConversations}
            activeId={activeId}
            elysiaUserId={elysiaProfile?.user?.id}
            onSelect={onSelect}
            onError={setActionError}
            revealItems={!loading}
          />
          <DirectoryLoadMore {...privatePage} retainCompletedSpace={false} />
        </div>
      ) : tab === "friends" ? (
        <div className="messages-friends">
          {friendList.length === 0 && !friendsPage.loading && !friendsPage.error ? (
            <div className="messages-empty">暂无好友</div>
          ) : (
            friendList.map((f) => (
              <div key={f.user.id} className="friend-row">
                <button type="button" className="friend-row-main" onClick={() => openUserChat(f.user.id)}>
                  <Avatar
                    label={f.user.nickname || f.user.username}
                    size={36}
                    online={presenceOnline(onlineUsers, withLiveStatus(onlineStatuses, f.user))}
                    imageUrl={f.user.avatar || null}
                    onClick={(e) => {
                      e.stopPropagation();
                      goUserProfile(currentUser?.id, f.user.id);
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
            ))
          )}
          <DirectoryLoadMore {...friendsPage} retainCompletedSpace={false} />
        </div>
      ) : (
        <div className="messages-friends messages-requests">
          <p className="messages-section-hint">好友申请、群邀请和入群申请</p>
          {(leaveNotices.length > 0 || realtimeLeaveNotices.length > 0 || leavePage.loading || !!leavePage.error || leavePage.hasMore) && (
            <section className="messages-group">
              <h4 className="messages-group-title">退群通知</h4>
              {leaveNotices.map((notice) => (
                <div key={`persisted-${notice.id}`} className="request-row notice-row">
                  <div className="request-body"><span className="request-name">群成员已离开</span><span className="request-msg">{notice.conversation_title}：{notice.member_name} 已离开</span></div>
                  <button type="button" className="btn btn-ghost request-btn" onClick={() => { void chatApi.readLeaveNotice(notice.id).then(() => setLeaveNotices((items) => items.filter((item) => item.id !== notice.id))).catch((e) => setActionError(e instanceof Error ? e.message : "标记通知失败")); }}>知道了</button>
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
              <h4 className="messages-group-title">好友申请</h4>
              {friendRequests.filter((r) => r.to_user.id === currentUser?.id && r.status === "pending").map((r) => (
                <RequestRow key={r.id} avatar={r.from_user} name={r.from_user.nickname || r.from_user.username} message={r.message} onAccept={() => void handleFriendAction(r, "accept")} onReject={() => void handleFriendAction(r, "reject")} />
              ))}
            <DirectoryLoadMore {...friendRequestPage} retainCompletedSpace={false} />
            </section>
          )}
          {(invites.length > 0 || invitePage.loading || !!invitePage.error || invitePage.hasMore) && (
            <section className="messages-group">
              <h4 className="messages-group-title">群邀请</h4>
              {invites.map((inv) => (
                <RequestRow
                  key={inv.id}
                  avatar={inv.inviter}
                  name={`${inv.conversation_title}（来自 ${inv.inviter.nickname || inv.inviter.username}）`}
                  message="邀请你加入群聊"
                  onAccept={() => void handleInviteAction(inv, "accept")}
                  onReject={() => void handleInviteAction(inv, "reject")}
                />
              ))}
            <DirectoryLoadMore {...invitePage} retainCompletedSpace={false} />
            </section>
          )}
          {(joinRequests.length > 0 || joinPage.loading || !!joinPage.error || joinPage.hasMore) && (
            <section className="messages-group">
              <h4 className="messages-group-title">入群申请</h4>
              {joinRequests.map((r) => (
                <RequestRow
                  key={r.id}
                  avatar={r.applicant}
                  name={`${r.applicant.nickname || r.applicant.username} → ${r.conversation_title}`}
                  message={r.message}
                  onAccept={() => void handleJoinRequestAction(r, "accept")}
                  onReject={() => void handleJoinRequestAction(r, "reject")}
                />
              ))}
            <DirectoryLoadMore {...joinPage} retainCompletedSpace={false} />
            </section>
          )}
          {friendRequests.filter((r) => r.to_user.id === currentUser?.id && r.status === "pending").length === 0 && invites.length === 0 && joinRequests.length === 0 && leaveNotices.length === 0 && realtimeLeaveNotices.length === 0 && ![leavePage, invitePage, joinPage, friendRequestPage].some((page) => page.loading || page.error || page.hasMore) && (
            <p className="messages-empty">暂无待处理认证消息</p>
          )}
        </div>
      )}
    </motion.aside>
  );
}

function RequestRow({
  avatar,
  name,
  message,
  onAccept,
  onReject,
}: {
  avatar: Pick<import("../../api/types").UserPublic, "id" | "status" | "nickname" | "username" | "avatar" | "online">;
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
