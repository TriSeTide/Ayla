/**
 * UserProfileCard —— 用户资料卡（R-S4，搜索结果/好友/成员点击弹出）。
 *
 * 头像、昵称、签名、在线状态 + 动作：加好友（发起申请）、发消息（进私聊）。
 * 好友关系判断（已是好友/待验证）本期只做"加好友发起申请"与"发消息"两个动作
 * （好友关系状态展示依赖后端补充，见步骤 §7）。
 */
import { useState } from "react";
import { useNavigate } from "react-router-dom";
import { openPrivateConversation } from "../api/chat";
import { createFriendRequest } from "../api/users";
import type { UserPublic } from "../api/types";
import { Avatar } from "./Avatar";

export function UserProfileCard({ user, onClose }: { user: UserPublic; onClose?: () => void }) {
  const navigate = useNavigate();
  const [busy, setBusy] = useState<"friend" | "chat" | null>(null);
  const [error, setError] = useState<string | null>(null);

  const addFriend = async () => {
    setBusy("friend");
    setError(null);
    try {
      await createFriendRequest({ to_user_id: user.id });
      // 申请已发出（后端 pending）
    } catch (e) {
      setError(e instanceof Error ? e.message : "发起申请失败");
    } finally {
      setBusy(null);
    }
  };

  const sendMessage = async () => {
    setBusy("chat");
    setError(null);
    try {
      const conv = await openPrivateConversation(user.id);
      navigate(`/chat/${conv.id}`);
    } catch (e) {
      setError(e instanceof Error ? e.message : "进入私聊失败");
    } finally {
      setBusy(null);
    }
  };

  return (
    <div className="user-profile-card glass-card">
      <div className="user-profile-body">
        <Avatar label={user.nickname || user.username} size={56} online={user.online} imageUrl={user.avatar || null} />
        <span className="user-profile-nick">{user.nickname || user.username}</span>
        <span className="user-profile-status">{user.online ? "在线" : "离线"}</span>
        {user.signature && <span className="user-profile-signature">{user.signature}</span>}
        {error && <span className="user-profile-error">{error}</span>}
      </div>
      <div className="user-profile-actions">
        <button type="button" className="btn btn-primary" onClick={() => void addFriend()} disabled={busy === "friend"}>
          {busy === "friend" ? "申请中…" : "加好友"}
        </button>
        <button type="button" className="btn btn-ghost" onClick={() => void sendMessage()} disabled={busy === "chat"}>
          {busy === "chat" ? "进入中…" : "发消息"}
        </button>
        {onClose && (
          <button type="button" className="msg-action-btn" onClick={onClose}>
            关闭
          </button>
        )}
      </div>
    </div>
  );
}
