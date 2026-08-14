/**
 * MessagesPage —— 消息中心（路由 /messages，F8，R-M1~M5）。
 *
 * 双选项卡：私信（private 会话列表）/ 好友列表（好友 + 待处理申请置顶）。
 * 申请条目：好友申请 + 群邀请 + 待审批入群申请（我作为 owner/admin），分组置顶，
 * 同意/拒绝即时反馈（处理后灰显）。宽屏双栏（左 300px 列表 + 右聊天/详情）。
 */
import { useCallback, useEffect, useMemo, useState } from "react";
import { useNavigate } from "react-router-dom";
import * as chatApi from "../api/chat";
import { getElysiaProfile } from "../api/elysia";
import * as usersApi from "../api/users";
import type { ElysiaProfile, FriendRequest, GroupInvite, GroupJoinRequest } from "../api/types";
import { Avatar } from "../components/Avatar";
import { ConversationList } from "../components/chat/ConversationList";
import { ElysiaEntry } from "../components/chat/ElysiaEntry";
import { NARROW_QUERY, useMediaQuery } from "../hooks/useMediaQuery";
import { NarrowTopBar } from "../layout/NarrowTopBar";
import { useBadgesStore } from "../stores/badges";
import { useChatStore } from "../stores/chat";

type Tab = "chat" | "friends";

export function MessagesPage() {
  const isNarrow = useMediaQuery(NARROW_QUERY);
  const navigate = useNavigate();
  const [tab, setTab] = useState<Tab>("chat");
  const conversations = useChatStore((s) => s.conversations);
  const [friendList, setFriendList] = useState<Awaited<ReturnType<typeof usersApi.listFriends>>>([]);
  const [friendRequests, setFriendRequests] = useState<FriendRequest[]>([]);
  const [invites, setInvites] = useState<GroupInvite[]>([]);
  const [joinRequests, setJoinRequests] = useState<GroupJoinRequest[]>([]);
  const [elysiaProfile, setElysiaProfile] = useState<ElysiaProfile | null>(null);

  // 爱莉入口（私信 tab 顶部）
  useEffect(() => {
    getElysiaProfile()
      .then((p) => setElysiaProfile(p.enabled ? p : null))
      .catch(() => {});
  }, []);

  // 加载会话列表（私信 tab 复用）
  useEffect(() => {
    if (conversations.length === 0) {
      chatApi.listConversations().then((l) => useChatStore.getState().setConversations(l)).catch(() => {});
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  // 好友 tab 数据
  const loadFriendsTab = useCallback(() => {
    usersApi.listFriends().then(setFriendList).catch(() => {});
    usersApi.listFriendRequests().then((l) => setFriendRequests(l.filter((r) => r.status === "pending"))).catch(() => {});
    chatApi.listMyInvites().then((l) => setInvites(l.filter((i) => i.status === "pending"))).catch(() => {});
    // 我管理的群 → 待审批入群申请
    const managed = conversations.filter((c) => c.type === "group" && (c.my_role === "owner" || c.my_role === "admin"));
    Promise.all(managed.map((g) => chatApi.listJoinRequests(g.id).catch(() => [] as GroupJoinRequest[])))
      .then((lists) => setJoinRequests(lists.flat().filter((r) => r.status === "pending")))
      .catch(() => {});
  }, [conversations]);

  useEffect(() => {
    if (tab === "friends") loadFriendsTab();
  }, [tab, loadFriendsTab]);

  const refreshBadges = () => void useBadgesStore.getState().fetch();

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

  const privateConvs = useMemo(() => conversations.filter((c) => c.type === "private"), [conversations]);

  return (
    <div className="messages-page">
      {isNarrow && <NarrowTopBar />}
      <div className="messages-tabs" role="tablist" aria-label="消息中心">
        <button
          type="button"
          role="tab"
          aria-selected={tab === "chat"}
          className={`messages-tab ${tab === "chat" ? "is-active" : ""}`}
          onClick={() => setTab("chat")}
        >
          私信
        </button>
        <button
          type="button"
          role="tab"
          aria-selected={tab === "friends"}
          className={`messages-tab ${tab === "friends" ? "is-active" : ""}`}
          onClick={() => setTab("friends")}
        >
          好友列表
        </button>
      </div>

      {tab === "chat" ? (
        <div className="messages-private">
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
            conversations={privateConvs}
            activeId={null}
            elysiaUserId={elysiaProfile?.user.id ?? null}
            onSelect={(id) => navigate(`/chat/${id}`)}
          />
        </div>
      ) : (
        <div className="messages-friends">
          {friendRequests.length > 0 && (
            <section className="messages-group">
              <h3 className="messages-group-title">好友申请（{friendRequests.length}）</h3>
              {friendRequests.map((r) => (
                <RequestRow
                  key={r.id}
                  avatar={r.from_user}
                  name={r.from_user.nickname || r.from_user.username}
                  message={r.message}
                  onAccept={() => handleFriendAction(r, "accept")}
                  onReject={() => handleFriendAction(r, "reject")}
                />
              ))}
            </section>
          )}
          {invites.length > 0 && (
            <section className="messages-group">
              <h3 className="messages-group-title">群邀请（{invites.length}）</h3>
              {invites.map((i) => (
                <RequestRow
                  key={i.id}
                  avatar={i.inviter}
                  name={`${i.conversation_title}（来自 ${i.inviter.nickname || i.inviter.username}）`}
                  message="邀请你加入群聊"
                  onAccept={() => handleInviteAction(i, "accept")}
                  onReject={() => handleInviteAction(i, "reject")}
                />
              ))}
            </section>
          )}
          {joinRequests.length > 0 && (
            <section className="messages-group">
              <h3 className="messages-group-title">入群申请（{joinRequests.length}）</h3>
              {joinRequests.map((r) => (
                <RequestRow
                  key={r.id}
                  avatar={r.applicant}
                  name={`${r.applicant.nickname || r.applicant.username} → ${r.conversation_title}`}
                  message={r.message}
                  onAccept={() => handleJoinRequestAction(r, "accept")}
                  onReject={() => handleJoinRequestAction(r, "reject")}
                />
              ))}
            </section>
          )}
          <section className="messages-group">
            <h3 className="messages-group-title">我的好友（{friendList.length}）</h3>
            {friendList.map((f) => (
              <button
                key={f.user.id}
                type="button"
                className="friend-row"
                onClick={() => navigate(`/chat/${f.user.id}`)}
              >
                <Avatar label={f.user.nickname || f.user.username} size={40} online={f.user.online} imageUrl={f.user.avatar || null} />
                <span className="friend-row-name">{f.user.nickname || f.user.username}</span>
              </button>
            ))}
            {friendList.length === 0 && friendRequests.length === 0 && invites.length === 0 && joinRequests.length === 0 && (
              <p className="messages-empty">还没有好友，去搜索添加吧</p>
            )}
          </section>
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
