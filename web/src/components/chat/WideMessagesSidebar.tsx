/**
 * WideMessagesSidebar —— 宽屏消息左列（需求：与主页侧栏 ChannelSidebar 宽度一致）。
 *
 * 260px 玻璃侧栏（同 .channel-sidebar width）：私信 / 好友 双 tab。
 * - 私信 tab：会话列表（ConversationList，点击 onSelect）
 * - 好友 tab：好友列表 + 待处理申请置顶（复用 MessagesPage 的好友数据处理）
 * 用于宽屏 /messages（两列：本侧栏 + 右侧聊天内容区）与 /chat/:id（两列同构）。
 */
import { useCallback, useEffect, useState } from "react";
import * as chatApi from "../../api/chat";
import * as usersApi from "../../api/users";
import type { ElysiaProfile, FriendRequest, GroupInvite, GroupJoinRequest } from "../../api/types";
import { Avatar } from "../Avatar";
import { ConversationList } from "./ConversationList";
import { ElysiaEntry } from "./ElysiaEntry";
import { useBadgesStore } from "../../stores/badges";
import { useChatStore } from "../../stores/chat";
import { useAuthStore } from "../../stores/auth";
import { useNoticeStore } from "../../stores/notices";
import { goUserProfile } from "../../utils/navigation";
import type { ConversationSummary } from "../../api/types";

type Tab = "chat" | "friends" | "requests";

export function WideMessagesSidebar({
  conversations: propConversations,
  activeId,
  onSelect,
}: {
  /** 可选兼容属性；实时真源始终来自 store */
  conversations?: ConversationSummary[];
  /** 当前选中的私聊会话 id（高亮） */
  activeId: string | null;
  /** 点击会话 → 选中（/chat/:id 宽屏跳转；/messages 宽屏右侧内联） */
  onSelect: (id: string) => void;
}) {
  // 直接订阅 store；保留 prop 仅兼容旧调用方，不使用其作为实时真源
  const storeConversations = useChatStore((s) => s.conversations);
  const conversations = storeConversations.length > 0 ? storeConversations : (propConversations ?? []);
  const lastFetched = useChatStore((s) => s.lastFetched);
  
  const [tab, setTab] = useState<Tab>("chat");
  const currentUser = useAuthStore((state) => state.currentUser);
  const realtimeNotices = useNoticeStore((state) => state.notices);
  const dismissNotice = useNoticeStore((state) => state.dismiss);
  const realtimeLeaveNotices = realtimeNotices.filter((notice) => notice.kind === "group.member.left");
  const [leaveNotices, setLeaveNotices] = useState<import("../../api/types").GroupMemberLeaveNotice[]>([]);
  const [friendList, setFriendList] = useState<Awaited<ReturnType<typeof usersApi.listFriends>>>([]);
  const [friendRequests, setFriendRequests] = useState<FriendRequest[]>([]);
  const [invites, setInvites] = useState<GroupInvite[]>([]);
  const [joinRequests, setJoinRequests] = useState<GroupJoinRequest[]>([]);
  const [elysiaProfile, setElysiaProfile] = useState<ElysiaProfile | null>(null);
  /** 审批（同意/拒绝）失败提示（点击关闭） */
  const [actionError, setActionError] = useState<string | null>(null);
  const [loadError, setLoadError] = useState<string | null>(null);
  const [openError, setOpenError] = useState<string | null>(null);
  const [friendsError, setFriendsError] = useState<string | null>(null);
  const [removingFriendId, setRemovingFriendId] = useState<string | null>(null);

  // ✅ 会话列表为空或过期时加载（宽屏 /chat/:id 直接进入时侧栏需有数据）
  useEffect(() => {
    const now = Date.now();
    const stale = !lastFetched || now - lastFetched > 60_000; // 60s 过期
    
    if (conversations.length === 0 || stale) {
      chatApi.listConversations()
        .then((l) => useChatStore.getState().setConversations(l))
        .catch((e) => setLoadError(e instanceof Error ? e.message : "加载会话失败"));
    }
  }, [conversations.length, lastFetched]);

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
  const loadFriendsTab = useCallback(() => {
    setFriendsError(null);
    usersApi.listFriends().then(setFriendList).catch((e) => setFriendsError(e instanceof Error ? e.message : "加载好友失败"));
    usersApi.listFriendRequests().then(setFriendRequests).catch((e) => setFriendsError(e instanceof Error ? e.message : "加载好友申请失败"));
    chatApi.listMyInvites().then((l) => setInvites(l.filter((i) => i.status === "pending"))).catch((e) => setFriendsError(e instanceof Error ? e.message : "加载群邀请失败"));
    chatApi.listLeaveNotices().then(setLeaveNotices).catch((e) => setFriendsError(e instanceof Error ? e.message : "加载退群通知失败"));
    const managed = conversations.filter((c) => c.type === "group" && (c.my_role === "owner" || c.my_role === "admin"));
    Promise.all(managed.map((g) => chatApi.listJoinRequests(g.id)))
      .then((lists) => setJoinRequests(lists.flat().filter((r) => r.status === "pending")))
      .catch((e) => setFriendsError(e instanceof Error ? e.message : "加载入群申请失败"));
  }, [conversations]);

  useEffect(() => {
    if (tab === "friends" || tab === "requests") loadFriendsTab();
  }, [tab, loadFriendsTab]);

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
    <aside className="wide-messages-sidebar" aria-label="消息列表">
      {loadError && <div className="chat-notice" role="alert">{loadError}</div>}
      {openError && <div className="chat-notice" role="alert">{openError}</div>}
      {friendsError && <div className="chat-notice" role="alert">{friendsError}</div>}
      {actionError && (
        <div className="messages-action-error" role="alert" onClick={() => setActionError(null)}>
          {actionError}（点击关闭）
        </div>
      )}
      <div className="messages-tabs">
        <button
          type="button"
          className={`messages-tab ${tab === "chat" ? "is-active" : ""}`}
          onClick={() => setTab("chat")}
        >
          私信
        </button>
        <button
          type="button"
          className={`messages-tab ${tab === "friends" ? "is-active" : ""}`}
          onClick={() => setTab("friends")}
        >
          好友
        </button>
        <button
          type="button"
          className={`messages-tab messages-tab-requests ${tab === "requests" ? "is-active" : ""}`}
          onClick={() => setTab("requests")}
        >
          认证消息
          {(friendRequests.filter((r) => r.to_user.id === currentUser?.id && r.status === "pending").length + invites.length + joinRequests.length) > 0 && (
            <span className="messages-tab-badge">{friendRequests.filter((r) => r.to_user.id === currentUser?.id && r.status === "pending").length + invites.length + joinRequests.length}</span>
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
            conversations={conversations.filter((c) => c.type === "private")}
            activeId={activeId}
            elysiaUserId={elysiaProfile?.user?.id}
            onSelect={onSelect}
          />
        </div>
      ) : tab === "friends" ? (
        <div className="messages-friends">
          {friendList.length === 0 ? (
            <div className="messages-empty">暂无好友</div>
          ) : (
            friendList.map((f) => (
              <div key={f.user.id} className="friend-row">
                <button type="button" className="friend-row-main" onClick={() => openUserChat(f.user.id)}>
                  <Avatar
                    label={f.user.nickname || f.user.username}
                    size={36}
                    online={f.user.online}
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
        </div>
      ) : (
        <div className="messages-friends messages-requests">
          <p className="messages-section-hint">好友申请、群邀请和入群申请</p>
          {(leaveNotices.length > 0 || realtimeLeaveNotices.length > 0) && (
            <section className="messages-group">
              <h4 className="messages-group-title">退群通知</h4>
              {leaveNotices.map((notice) => (
                <div key={`persisted-${notice.id}`} className="request-row notice-row">
                  <div className="request-body"><span className="request-name">群成员已离开</span><span className="request-msg">{notice.conversation_title}：{notice.member_name} 已离开</span></div>
                  <button type="button" className="btn btn-ghost request-btn" onClick={() => { void chatApi.readLeaveNotice(notice.id); setLeaveNotices((items) => items.filter((item) => item.id !== notice.id)); }}>知道了</button>
                </div>
              ))}
              {realtimeLeaveNotices.map((notice) => (
                <div key={notice.id} className="request-row notice-row">
                  <div className="request-body"><span className="request-name">{notice.title}</span><span className="request-msg">{notice.detail}</span></div>
                  <button type="button" className="btn btn-ghost request-btn" onClick={() => dismissNotice(notice.id)}>知道了</button>
                </div>
              ))}
            </section>
          )}
          {friendRequests.filter((r) => r.to_user.id === currentUser?.id && r.status === "pending").length > 0 && (
            <section className="messages-group">
              <h4 className="messages-group-title">好友申请</h4>
              {friendRequests.filter((r) => r.to_user.id === currentUser?.id && r.status === "pending").map((r) => (
                <RequestRow key={r.id} avatar={r.from_user} name={r.from_user.nickname || r.from_user.username} message={r.message} onAccept={() => void handleFriendAction(r, "accept")} onReject={() => void handleFriendAction(r, "reject")} />
              ))}
            </section>
          )}
          {invites.length > 0 && (
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
            </section>
          )}
          {joinRequests.length > 0 && (
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
            </section>
          )}
          {friendRequests.filter((r) => r.to_user.id === currentUser?.id && r.status === "pending").length === 0 && invites.length === 0 && joinRequests.length === 0 && leaveNotices.length === 0 && realtimeLeaveNotices.length === 0 && (
            <p className="messages-empty">暂无待处理认证消息</p>
          )}
        </div>
      )}
    </aside>
  );
}

function RequestRow({
  avatar,
  name,
  message,
  onAccept,
  onReject,
}: {
  avatar: { nickname: string; username: string; avatar: string; online: boolean };
  name: string;
  message: string;
  onAccept: () => void;
  onReject: () => void;
}) {
  return (
    <div className="request-row">
      <Avatar label={avatar.nickname || avatar.username} size={36} online={avatar.online} imageUrl={avatar.avatar || null} />
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
