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
import { Link, useNavigate } from "react-router-dom";
import * as chatApi from "../../api/chat";
import { mediaContentUrl, uploadMediaFile, validateImageFile } from "../../api/media";
import type { ConversationMember, ConversationSummary } from "../../api/types";
import { Avatar } from "../../components/Avatar";
import { IconBack, IconClose, IconSearch } from "../../components/icons";
import { useAuthStore } from "../../stores/auth";
import { useChatStore } from "../../stores/chat";
import { useHomeStore } from "../../stores/home";
import { goUserProfile } from "../../utils/navigation";

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
  const navigate = useNavigate();
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
  const [joinRequests, setJoinRequests] = useState<import("../../api/types").GroupJoinRequest[]>([]);
  const [managementError, setManagementError] = useState<string | null>(null);
  const [busyAction, setBusyAction] = useState<string | null>(null);
  // 转让群主对话框（Bug #5：不再用 window.prompt 手输成员 ID）
  const [transferOpen, setTransferOpen] = useState(false);

  // 群头像上传（M5-2.1）：选择 → 本地校验 → 预览 → 保存时三步上传 + PATCH，失败保留可重试
  const [groupAvatarFile, setGroupAvatarFile] = useState<File | null>(null);
  const [groupAvatarPreview, setGroupAvatarPreview] = useState<string | null>(null);
  const [groupAvatarError, setGroupAvatarError] = useState<string | null>(null);
  const [groupAvatarSaving, setGroupAvatarSaving] = useState(false);

  // 释放头像 objectURL（卸载时）
  useEffect(() => {
    return () => {
      if (groupAvatarPreview) URL.revokeObjectURL(groupAvatarPreview);
    };
  }, [groupAvatarPreview]);

  const chooseGroupAvatar = (file: File | undefined) => {
    if (!file) return;
    const invalid = validateImageFile(file);
    if (invalid) {
      setGroupAvatarError(invalid);
      return;
    }
    setGroupAvatarError(null);
    if (groupAvatarPreview) URL.revokeObjectURL(groupAvatarPreview);
    setGroupAvatarFile(file);
    setGroupAvatarPreview(URL.createObjectURL(file));
  };

  const saveGroupAvatar = async () => {
    if (!groupAvatarFile) return;
    setGroupAvatarSaving(true);
    setGroupAvatarError(null);
    try {
      const uploaded = await uploadMediaFile(groupAvatarFile, "image");
      const c = await chatApi.patchConversation(groupId, {
        avatar: mediaContentUrl(uploaded.media_id),
      });
      useChatStore.getState().upsertConversation(c);
      if (groupAvatarPreview) URL.revokeObjectURL(groupAvatarPreview);
      setGroupAvatarFile(null);
      setGroupAvatarPreview(null);
    } catch (e) {
      setGroupAvatarError(e instanceof Error ? e.message : "头像保存失败");
    } finally {
      setGroupAvatarSaving(false);
    }
  };

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

  const reloadGroup = async () => {
    const fresh = await chatApi.getConversation(groupId);
    useChatStore.getState().upsertConversation(fresh);
    setGroupDetail({ ...fresh, peer: null });
    return fresh;
  };

  useEffect(() => {
    if (!canManage || typeof chatApi.listJoinRequests !== "function") return;
    chatApi.listJoinRequests(groupId)
      .then((items) => setJoinRequests(items.filter((item) => item.status === "pending")))
      .catch((e) => setManagementError(e instanceof Error ? e.message : "加载入群申请失败"));
  }, [canManage, groupId]);

  const runManagementAction = async (key: string, action: () => Promise<unknown>) => {
    setBusyAction(key);
    setManagementError(null);
    try { await action(); await reloadGroup(); }
    catch (e) { setManagementError(e instanceof Error ? e.message : "操作失败"); }
    finally { setBusyAction(null); }
  };

  // 解散群聊：成功后从会话列表移除并清掉最近群记录，再回主页；不触发 reloadGroup（群已删除）
  const handleDissolve = async () => {
    if (!window.confirm("确定解散群聊？此操作不可撤销")) return;
    setBusyAction("dissolve");
    setManagementError(null);
    try {
      await chatApi.dissolveGroup(groupId);
      useChatStore.getState().removeConversation(groupId);
      if (useHomeStore.getState().recentGroupId === groupId) {
        useHomeStore.getState().setRecentGroup(null);
      }
      navigate("/group", { replace: true });
    } catch (e) {
      setManagementError(e instanceof Error ? e.message : "解散群聊失败");
    } finally {
      setBusyAction(null);
    }
  };

  // 退出群聊：成功后从会话列表移除并清掉最近群记录，再回主页
  const handleLeave = async () => {
    if (!window.confirm("确定退出群聊？")) return;
    setBusyAction("leave");
    setManagementError(null);
    try {
      await chatApi.leaveGroup(groupId);
      useChatStore.getState().removeConversation(groupId);
      if (useHomeStore.getState().recentGroupId === groupId) {
        useHomeStore.getState().setRecentGroup(null);
      }
      navigate("/group", { replace: true });
    } catch (e) {
      setManagementError(e instanceof Error ? e.message : "退出群聊失败");
    } finally {
      setBusyAction(null);
    }
  };

  // 可转让候选：排除群主自己（m.role === "owner" 与 m.user.id === currentUser.id 双条件最稳）
  const transferCandidates = useMemo(
    () => members.filter((m) => m.user.id !== currentUser?.id && m.role !== "owner"),
    [members, currentUser?.id],
  );

  const confirmTransfer = async (m: ConversationMember) => {
    const name = m.user.nickname || m.user.username;
    if (!window.confirm(`确定将群主转让给 ${name}？转让后你将成为普通成员`)) return;
    await runManagementAction("transfer", async () => {
      await chatApi.transferGroupOwner(groupId, m.user.id);
      setTransferOpen(false);
    });
  };

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
        <div className="group-info-avatar-block">
          <Avatar
            label={conv.title}
            size={72}
            online
            imageUrl={groupAvatarPreview ?? (conv.avatar || null)}
          />
          {canManage && (
            <label className="btn btn-ghost group-info-avatar-btn">
              {groupAvatarSaving ? "上传中…" : "更换群头像"}
              <input
                type="file"
                accept="image/*"
                hidden
                disabled={groupAvatarSaving}
                onChange={(e) => {
                  chooseGroupAvatar(e.target.files?.[0]);
                  e.target.value = "";
                }}
              />
            </label>
          )}
          {groupAvatarPreview && (
            <>
              <span className="group-info-avatar-hint">新头像将在保存后生效</span>
              <button
                type="button"
                className="btn btn-primary"
                onClick={() => void saveGroupAvatar()}
                disabled={groupAvatarSaving}
              >
                {groupAvatarSaving ? "保存中…" : "保存群头像"}
              </button>
            </>
          )}
          {groupAvatarError && (
            <p className="group-info-avatar-error" role="alert">{groupAvatarError}</p>
          )}
        </div>
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
                onClick={() => goUserProfile(currentUser?.id, m.user.id)}
                ariaLabel={`查看 ${m.user.nickname || m.user.username} 的个人主页`}
              />
              <span className="group-info-member-name">{m.user.nickname || m.user.username}</span>
              {m.user.id === currentUser?.id && <span className="group-info-me">我</span>}
              {m.role !== "member" && (
                <span className={`group-info-role group-info-role-${m.role}`}>
                  {ROLE_LABEL[m.role]}
                </span>
              )}
              {canManage && m.user.id !== currentUser?.id && m.role !== "owner" && (
                <div className="group-info-member-actions">
                  {isOwner && (
                    <button type="button" className="btn btn-ghost" disabled={busyAction !== null} onClick={() => void runManagementAction(`role-${m.user.id}`, () => chatApi.setMemberRole(groupId, m.user.id, m.role === "admin" ? "member" : "admin"))}>
                      {m.role === "admin" ? "撤销管理员" : "设为管理员"}
                    </button>
                  )}
                  <button type="button" className="btn btn-ghost" disabled={busyAction !== null} onClick={() => void runManagementAction(`remove-${m.user.id}`, () => chatApi.removeMember(groupId, m.user.id))}>
                    {busyAction === `remove-${m.user.id}` ? "移除中…" : "移除"}
                  </button>
                </div>
              )}
            </li>
          ))}
        </ul>
      </section>

      <section className="group-info-actions">
        <h3 className="group-info-section-title">管理</h3>
        {managementError && <p className="group-info-error" role="alert">{managementError}</p>}
        {canManage && (
          <>
            <div className="group-info-policy">
              <span>加入方式：{conv.join_policy === "public" ? "公开加入" : "申请加入"}</span>
              {isOwner && <select value={conv.join_policy ?? "application"} onChange={(e) => void runManagementAction("join-policy", () => chatApi.patchConversation(groupId, { join_policy: e.target.value as "public" | "application" }))}>
                <option value="public">公开加入</option>
                <option value="application">申请加入</option>
              </select>}
            </div>
            {joinRequests.length > 0 ? <div className="group-info-requests">
              <h4>入群申请审批 · 待处理（{joinRequests.length}）</h4>
              {joinRequests.map((request) => <div key={request.id} className="group-info-request">
                <span>{request.applicant.nickname || request.applicant.username}{request.message ? `：${request.message}` : ""}</span>
                <button type="button" className="btn btn-primary" disabled={busyAction !== null} onClick={() => void runManagementAction(`join-${request.id}`, async () => { await chatApi.actionJoinRequest(request.id, "accept"); setJoinRequests((items) => items.filter((item) => item.id !== request.id)); })}>同意</button>
                <button type="button" className="btn btn-ghost" disabled={busyAction !== null} onClick={() => void runManagementAction(`join-${request.id}`, async () => { await chatApi.actionJoinRequest(request.id, "reject"); setJoinRequests((items) => items.filter((item) => item.id !== request.id)); })}>拒绝</button>
              </div>)}
            </div> : <p className="group-info-placeholder">入群申请审批：暂无待处理申请</p>}
            {isOwner && <>
              <button type="button" className="btn btn-ghost" onClick={() => setTransferOpen(true)}>转让群主</button>
              <button type="button" className="btn btn-danger" onClick={() => void handleDissolve()}>{busyAction === "dissolve" ? "解散中…" : "解散群聊"}</button>
            </>}
          </>
        )}
        {!isOwner && <button type="button" className="btn btn-ghost" disabled={busyAction !== null} onClick={() => void handleLeave()}>{busyAction === "leave" ? "退出中…" : "退出群聊"}</button>}
      </section>

      {transferOpen && (
        <TransferOwnerDialog
          members={transferCandidates}
          busy={busyAction === "transfer"}
          error={managementError}
          onConfirm={(m) => void confirmTransfer(m)}
          onClose={() => setTransferOpen(false)}
        />
      )}
    </div>
  );
}

/**
 * TransferOwnerDialog —— 转让群主选择对话框（Bug #5）。
 *
 * 弹层结构参照 GroupCreateDialog（overlay + glass-card），成员行沿用群成员列表
 * （Avatar + 昵称 + 角色标签）。候选列表已由父组件过滤（排除群主自己）。
 * - 搜索框按昵称/用户名过滤；
 * - 单选：点成员行选中（aria-pressed），再点「确认转让」二次 confirm 后执行；
 * - 无候选时显示空态并禁用确认（防止转让给自己/群主）。
 * 无障碍：role="dialog" + aria-label；搜索框带 label；关闭按钮可聚焦。
 */
function TransferOwnerDialog({
  members,
  busy,
  error,
  onConfirm,
  onClose,
}: {
  /** 可转让候选（已排除群主自己） */
  members: ConversationMember[];
  busy: boolean;
  error: string | null;
  onConfirm: (m: ConversationMember) => void;
  onClose: () => void;
}) {
  const [query, setQuery] = useState("");
  const [selected, setSelected] = useState<ConversationMember | null>(null);

  const filtered = useMemo(() => {
    const q = query.trim().toLowerCase();
    if (!q) return members;
    return members.filter((m) => {
      const nickname = (m.user.nickname || m.user.username).toLowerCase();
      const username = m.user.username.toLowerCase();
      return nickname.includes(q) || username.includes(q);
    });
  }, [members, query]);

  return (
    <div className="group-transfer-overlay" onClick={busy ? undefined : onClose}>
      <div
        className="group-transfer-dialog glass-card"
        onClick={(e) => e.stopPropagation()}
        role="dialog"
        aria-label="转让群主"
      >
        <header className="group-transfer-head">
          <span className="group-transfer-title">转让群主</span>
          <button type="button" className="icon-btn-40" onClick={onClose} aria-label="关闭" disabled={busy}>
            <IconClose width={18} height={18} />
          </button>
        </header>

        <p className="group-transfer-desc">
          选择一位群成员接任群主。转让后你将成为普通成员。
        </p>

        {members.length === 0 ? (
          <p className="group-transfer-empty">暂无其他成员可转让</p>
        ) : (
          <>
            <div className="group-transfer-search">
              <IconSearch width={15} height={15} className="group-transfer-search-icon" />
              <input
                className="field"
                value={query}
                onChange={(e) => setQuery(e.target.value)}
                placeholder="搜索成员昵称/用户名"
                aria-label="搜索成员"
              />
            </div>
            <ul className="group-transfer-list">
              {filtered.map((m) => {
                const name = m.user.nickname || m.user.username;
                const isSelected = selected?.id === m.id;
                return (
                  <li key={m.id}>
                    <button
                      type="button"
                      className={`group-transfer-row${isSelected ? " is-selected" : ""}`}
                      onClick={() => setSelected(m)}
                      aria-pressed={isSelected}
                      aria-label={`转让给 ${name}`}
                    >
                      <Avatar
                        label={name}
                        size={36}
                        online={m.user.online}
                        imageUrl={m.user.avatar || null}
                      />
                      <span className="group-transfer-name">{name}</span>
                      {m.role !== "member" && (
                        <span className={`group-info-role group-info-role-${m.role}`}>
                          {ROLE_LABEL[m.role]}
                        </span>
                      )}
                    </button>
                  </li>
                );
              })}
              {filtered.length === 0 && <li className="search-empty">没有匹配的成员</li>}
            </ul>
          </>
        )}

        {error && <p className="group-info-error" role="alert">{error}</p>}

        <div className="group-transfer-actions">
          <button type="button" className="btn btn-ghost" onClick={onClose} disabled={busy}>
            取消
          </button>
          <button
            type="button"
            className="btn btn-primary"
            onClick={() => selected && onConfirm(selected)}
            disabled={!selected || busy || members.length === 0}
          >
            {busy ? "转让中…" : "确认转让"}
          </button>
        </div>
      </div>
    </div>
  );
}
