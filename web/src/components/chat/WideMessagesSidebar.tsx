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
import type { ConversationSummary } from "../../api/types";

type Tab = "chat" | "friends";

export function WideMessagesSidebar({
  conversations,
  activeId,
  onSelect,
}: {
  conversations: ConversationSummary[];
  /** 当前选中的私聊会话 id（高亮） */
  activeId: string | null;
  /** 点击会话 → 选中（/chat/:id 宽屏跳转；/messages 宽屏右侧内联） */
  onSelect: (id: string) => void;
}) {
  const [tab, setTab] = useState<Tab>("chat");
  const [friendList, setFriendList] = useState<Awaited<ReturnType<typeof usersApi.listFriends>>>([]);
  const [friendRequests, setFriendRequests] = useState<FriendRequest[]>([]);
  const [invites, setInvites] = useState<GroupInvite[]>([]);
  const [joinRequests, setJoinRequests] = useState<GroupJoinRequest[]>([]);
  const [elysiaProfile, setElysiaProfile] = useState<ElysiaProfile | null>(null);
  /** 审批（同意/拒绝）失败提示（点击关闭） */
  const [actionError, setActionError] = useState<string | null>(null);

  // 会话列表为空时加载（宽屏 /chat/:id 直接进入时侧栏需有数据）
  useEffect(() => {
    if (conversations.length === 0) {
      chatApi.listConversations().then((l) => useChatStore.getState().setConversations(l)).catch(() => {});
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  // 爱莉入口（私信 tab 顶部）
  useEffect(() => {
    import("../../api/elysia")
      .then(({ getElysiaProfile }) => getElysiaProfile())
      .then((p) => setElysiaProfile(p.enabled ? p : null))
      .catch(() => {});
  }, []);

  // 打开与某用户的私聊会话（好友/爱莉点击 → 选中会话）
  const openUserChat = useCallback(
    (userId: string) => {
      chatApi.openPrivateConversation(userId).then((conv) => onSelect(conv.id)).catch(() => {});
    },
    [onSelect],
  );

  // 好友 tab 数据
  const loadFriendsTab = useCallback(() => {
    usersApi.listFriends().then(setFriendList).catch(() => {});
    usersApi.listFriendRequests().then((l) => setFriendRequests(l.filter((r) => r.status === "pending"))).catch(() => {});
    chatApi.listMyInvites().then((l) => setInvites(l.filter((i) => i.status === "pending"))).catch(() => {});
    const managed = conversations.filter((c) => c.type === "group" && (c.my_role === "owner" || c.my_role === "admin"));
    Promise.all(managed.map((g) => chatApi.listJoinRequests(g.id).catch(() => [] as GroupJoinRequest[])))
      .then((lists) => setJoinRequests(lists.flat().filter((r) => r.status === "pending")))
      .catch(() => {});
  }, [conversations]);

  useEffect(() => {
    if (tab === "friends") loadFriendsTab();
  }, [tab, loadFriendsTab]);

  const refreshBadges = () => void useBadgesStore.getState().fetch();

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
      ) : (
        <div className="messages-friends">
          {friendRequests.length > 0 && (
            <section>
              <h4 className="messages-group-title">好友申请</h4>
              {friendRequests.map((r) => (
                <RequestRow
                  key={r.id}
                  avatar={r.from_user}
                  name={r.from_user.nickname || r.from_user.username}
                  message={r.message}
                  onAccept={() => void handleFriendAction(r, "accept")}
                  onReject={() => void handleFriendAction(r, "reject")}
                />
              ))}
            </section>
          )}
          {invites.length > 0 && (
            <section>
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
            <section>
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
          {friendList.length === 0 ? (
            <div className="messages-empty">暂无好友</div>
          ) : (
            friendList.map((f) => (
              <button
                key={f.user.id}
                type="button"
                className="friend-row"
                onClick={() => openUserChat(f.user.id)}
              >
                <Avatar label={f.user.nickname || f.user.username} size={36} online={f.user.online} imageUrl={f.user.avatar || null} />
                <span className="friend-row-name">{f.user.nickname || f.user.username}</span>
              </button>
            ))
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
