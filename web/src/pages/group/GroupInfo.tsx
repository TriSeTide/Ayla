/**
 * GroupInfo —— 群信息界面（F3，R-G9 角色化）。
 *
 * 展示：群资料（头像/群名/公告/创建时间/成员数）+ 成员列表（角色标签 owner/admin/member）。
 * 角色化操作：
 * - owner/admin：编辑群名/公告（真功能，patchConversation）+ 管理项入口（入群申请/加人/移除/
 *   转让/解散——按后端落地边界占位标注）；
 * - 普通成员：退出群 / 邀请好友（后端 leave 未实现 + 邀请属 F8，占位标注）。
 *
 * 主体性边界：本页只管理工程性群资料与成员结构，不生产任何第一人称/主体语义。
 */
import { useEffect, useMemo, useState } from "react";
import { Link } from "react-router-dom";
import * as chatApi from "../../api/chat";
import type { ConversationSummary } from "../../api/types";
import { Avatar } from "../../components/Avatar";
import { IconBack } from "../../components/icons";
import { useAuthStore } from "../../stores/auth";
import { useChatStore } from "../../stores/chat";

const ROLE_LABEL: Record<string, string> = {
  owner: "群主",
  admin: "管理员",
  member: "成员",
};

function formatDate(iso: string | undefined): string {
  if (!iso) return "—";
  try {
    return new Date(iso).toLocaleDateString("zh-CN");
  } catch {
    return "—";
  }
}

export function GroupInfo({ groupId }: { groupId: string }) {
  const conversations = useChatStore((s) => s.conversations);
  const currentUser = useAuthStore((s) => s.currentUser);

  const group = useMemo(
    () => conversations.find((c) => c.id === groupId) ?? null,
    [conversations, groupId],
  );

  const [groupDetail, setGroupDetail] = useState<ConversationSummary | null>(null);
  const [editing, setEditing] = useState(false);
  const [title, setTitle] = useState("");
  const [announcement, setAnnouncement] = useState("");
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [loadError, setLoadError] = useState<string | null>(null);
  const [loadRetry, setLoadRetry] = useState(0);

  // store 未命中时拉详情（直接访问 /group/:id/info）
  useEffect(() => {
    if (group) return;
    let cancelled = false;
    chatApi
      .getConversation(groupId)
      .then((c) => {
        if (!cancelled) setGroupDetail({ ...c, peer: null });
      })
      .catch((e) => {
        if (!cancelled) setLoadError(e instanceof Error ? e.message : "加载群信息失败");
      });
    return () => {
      cancelled = true;
    };
  }, [group, groupId, loadRetry]);

  const conv = group ?? groupDetail;
  const isOwner = conv?.my_role === "owner";
  const isAdmin = conv?.my_role === "admin";
  const canManage = isOwner || isAdmin;
  const members = conv?.members ?? [];

  const startEdit = () => {
    setTitle(conv?.title ?? "");
    setAnnouncement(conv?.announcement ?? "");
    setError(null);
    setEditing(true);
  };

  const saveEdit = async () => {
    if (!title.trim()) {
      setError("群名不能为空");
      return;
    }
    setSaving(true);
    setError(null);
    try {
      await chatApi.patchConversation(groupId, {
        title: title.trim(),
        announcement,
      });
      const c = await chatApi.getConversation(groupId);
      useChatStore.getState().upsertConversation(c);
      setEditing(false);
    } catch (e) {
      setError(e instanceof Error ? e.message : "保存失败");
    } finally {
      setSaving(false);
    }
  };

  if (!conv) {
    return (
      <div className="group-info">
        {loadError ? (
          <div className="group-scene-placeholder" role="alert">
            <h3 className="placeholder-title">群信息加载失败</h3>
            <p className="placeholder-desc">{loadError}</p>
            <button type="button" className="btn btn-ghost" onClick={() => { setLoadError(null); setLoadRetry((value) => value + 1); }}>重试</button>
          </div>
        ) : <div className="group-info-loading" role="status">
          <div className="skeleton" style={{ height: 64, marginBottom: 8 }} />
          <div className="skeleton" style={{ height: 64, marginBottom: 8 }} />
          <div className="skeleton" style={{ height: 64 }} />
        </div>}
      </div>
    );
  }

  return (
    <div className="group-info">
      <header className="group-info-head">
        <Link to={`/group/${groupId}`} className="icon-btn-40" aria-label="返回群聊">
          <IconBack width={22} height={22} />
        </Link>
        <h2 className="group-info-title">群信息</h2>
      </header>

      <section className="group-info-profile glass-card">
        <Avatar label={conv.title} size={72} online />
        {editing ? (
          <div className="group-info-edit">
            <input
              className="field"
              value={title}
              onChange={(e) => setTitle(e.target.value)}
              placeholder="群名"
              aria-label="群名"
            />
            <textarea
              className="field"
              value={announcement}
              onChange={(e) => setAnnouncement(e.target.value)}
              placeholder="群公告"
              rows={3}
              aria-label="群公告"
            />
            {error && <p className="group-info-error">{error}</p>}
            <div className="group-info-edit-actions">
              <button type="button" className="btn btn-primary" onClick={() => void saveEdit()} disabled={saving}>
                {saving ? "保存中…" : "保存"}
              </button>
              <button type="button" className="btn btn-ghost" onClick={() => setEditing(false)}>
                取消
              </button>
            </div>
          </div>
        ) : (
          <>
            <h3 className="group-info-name">{conv.title}</h3>
            <p className="group-info-announcement">{conv.announcement || "暂无公告"}</p>
            <div className="group-info-meta">
              <span>{conv.member_count} 人</span>
              <span>创建于 {formatDate(conv.created_at)}</span>
            </div>
            {canManage && (
              <button type="button" className="btn btn-ghost" onClick={startEdit}>
                编辑群资料
              </button>
            )}
          </>
        )}
      </section>

      <section className="group-info-members">
        <h3 className="group-info-section-title">成员（{members.length}）</h3>
        <ul className="group-info-member-list">
          {members.map((m) => (
            <li key={m.id} className="group-info-member">
              <Avatar
                label={m.user.nickname || m.user.username}
                size={36}
                online={m.user.online}
                imageUrl={m.user.avatar || null}
              />
              <span className="group-info-member-name">{m.user.nickname || m.user.username}</span>
              {m.user.id === currentUser?.id && <span className="group-info-me">我</span>}
              {m.role !== "member" && (
                <span className={`group-info-role group-info-role-${m.role}`}>
                  {ROLE_LABEL[m.role]}
                </span>
              )}
            </li>
          ))}
        </ul>
      </section>

      <section className="group-info-actions">
        <h3 className="group-info-section-title">管理</h3>
        {canManage ? (
          <>
            <p className="group-info-placeholder">入群申请审批 — 随 F8 消息中心落地</p>
            <p className="group-info-placeholder">移除成员 / 转让群主 / 解散群 — 后端暂未提供端点</p>
          </>
        ) : (
          <p className="group-info-placeholder">退出群 / 邀请好友 — 退出后端暂未提供，邀请随 F8 落地</p>
        )}
      </section>
    </div>
  );
}
