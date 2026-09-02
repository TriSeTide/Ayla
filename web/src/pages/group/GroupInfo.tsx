/**
 * GroupInfo —— 群信息界面（F3，R-G9 角色化）。
 *
 * 展示：群资料（头像/群名/公告/创建时间/统计）+ 成员列表（角色标签 owner/admin/member）+
 * 子群列表 + 管理（入群申请审批 / 加入方式 / 表情包上传权限 / 转让 / 解散 / 退出）。
 *
 * 布局（2026-09 优化）：
 * - 宽屏（>768px）：左栏 sticky（资料卡 + 管理卡）+ 右栏（成员卡 + 子群卡）两栏网格；
 * - 窄屏（≤768px）：单列卡片流（资料 → 管理 → 成员 → 子群），头部玻璃卡吸顶。
 *
 * 角色化操作：
 * - owner/admin：编辑群名/公告（patchConversation）+ 管理项入口（入群申请/加人/移除/
 *   转让/解散——按后端落地边界占位标注）；
 * - 普通成员：退出群 / 邀请好友（后端 leave 未实现 + 邀请属 F8，占位标注）。
 *
 * 主体性边界：本页只管理工程性群资料与成员结构，不生产任何第一人称/主体语义。
 */
import { useEffect, useMemo, useRef, useState } from "react";
import { Link, useNavigate } from "react-router-dom";
import * as chatApi from "../../api/chat";
import { getGroupEmojiPack, setGroupEmojiUploadPolicy } from "../../api/emoji";
import { mediaContentUrl, uploadMediaFile, validateImageFile } from "../../api/media";
import type { ConversationMember, ConversationSummary, SubGroup } from "../../api/types";
import { Avatar } from "../../components/Avatar";
import { ConfirmDialog } from "../../components/ConfirmDialog";
import { SubGroupDialog, type SubGroupDialogState } from "../../components/group/SubGroupDialog";
import {
  IconBack,
  IconCheck,
  IconChevronDown,
  IconClose,
  IconGrid,
  IconMenu,
  IconPlus,
  IconSearch,
  IconUsers,
} from "../../components/icons";
import { NARROW_QUERY, useMediaQuery } from "../../hooks/useMediaQuery";
import { useAuthStore } from "../../stores/auth";
import { useChatStore } from "../../stores/chat";
import { usePresenceStore } from "../../stores/presence";
import { useHomeStore } from "../../stores/home";
import { subgroupKey, useSubGroupStore } from "../../stores/subgroup";
import { presenceOnline, withLiveStatus } from "../../utils/displayStatus";
import { goUserProfile } from "../../utils/navigation";

const ROLE_LABEL: Record<string, string> = {
  owner: "群主",
  admin: "管理员",
  member: "成员",
};

/** 子群卡默认展示条数，超出部分由「查看更多」展开（用户反馈 2026-09） */
const SUBGROUP_PREVIEW_COUNT = 3;

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
  const onlineUsers = usePresenceStore((s) => s.users);
  const onlineStatuses = usePresenceStore((s) => s.statuses);
  const isNarrow = useMediaQuery(NARROW_QUERY);

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
  // 加入方式自定义下拉（用户反馈：原生 select 太原始；完全自绘按钮 + 玻璃选项浮层）
  const [policyOpen, setPolicyOpen] = useState(false);
  const policyWrapRef = useRef<HTMLSpanElement>(null);
  useEffect(() => {
    if (!policyOpen) return;
    const onPointerDown = (e: PointerEvent) => {
      if (policyWrapRef.current && !policyWrapRef.current.contains(e.target as Node)) {
        setPolicyOpen(false);
      }
    };
    document.addEventListener("pointerdown", onPointerDown);
    return () => document.removeEventListener("pointerdown", onPointerDown);
  }, [policyOpen]);
  // 转让群主对话框（Bug #5：不再用 window.prompt 手输成员 ID）
  const [transferOpen, setTransferOpen] = useState(false);
  // 危险操作确认（解散/退群/转让）——用自研 ConfirmDialog 替代 window.confirm
  const [confirmAction, setConfirmAction] = useState<
    { kind: "dissolve" } | { kind: "leave" } | { kind: "transfer"; member: ConversationMember } | null
  >(null);

  // ---- 子群管理（窄屏编辑入口；宽屏在 ChannelSidebar） ----
  const subgroups = useSubGroupStore((s) => s.byGroup[groupId] ?? []);
  const unreadByKey = useSubGroupStore((s) => s.unreadByKey);
  // 子群是否展开全部（默认只展示前 SUBGROUP_PREVIEW_COUNT 个）
  const [showAllSubgroups, setShowAllSubgroups] = useState(false);
  const visibleSubgroups = showAllSubgroups
    ? subgroups
    : subgroups.slice(0, SUBGROUP_PREVIEW_COUNT);
  const [subgroupEditing, setSubgroupEditing] = useState(false);
  const [subgroupDialog, setSubgroupDialog] = useState<SubGroupDialogState>(null);
  const [subgroupBusy, setSubgroupBusy] = useState(false);
  const [subgroupError, setSubgroupError] = useState<string | null>(null);
  const [subgroupDelete, setSubgroupDelete] = useState<SubGroup | null>(null);

  // 群表情包上传权限（任务 03）：仅群主可见可改；包未创建（404）时按默认 false
  const [allowMemberUpload, setAllowMemberUpload] = useState(false);
  const [emojiPolicyLoaded, setEmojiPolicyLoaded] = useState(false);

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
  const memberCount = conv?.member_count ?? members.length;

  // 在线成员数（光环 + 文字双通道，design.md §10）
  const onlineCount = useMemo(
    () =>
      members.filter((m) =>
        presenceOnline(onlineUsers, withLiveStatus(onlineStatuses, m.user)),
      ).length,
    [members, onlineUsers, onlineStatuses],
  );

  const reloadGroup = async () => {
    const fresh = await chatApi.getConversation(groupId);
    useChatStore.getState().upsertConversation(fresh);
    setGroupDetail({ ...fresh, peer: null });
    return fresh;
  };

  useEffect(() => {
    if (!isOwner) return;
    getGroupEmojiPack(groupId)
      .then((d) => {
        setAllowMemberUpload(d.allow_member_upload);
        setEmojiPolicyLoaded(true);
      })
      .catch(() => {
        // 包未创建（404）→ 默认关闭
        setAllowMemberUpload(false);
        setEmojiPolicyLoaded(true);
      });
  }, [isOwner, groupId]);

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

  const toggleEmojiUploadPolicy = async (value: boolean) => {
    setBusyAction("emoji-policy");
    setManagementError(null);
    try {
      const d = await setGroupEmojiUploadPolicy(groupId, value);
      setAllowMemberUpload(d.allow_member_upload);
    } catch (e) {
      setManagementError(e instanceof Error ? e.message : "设置失败");
    } finally {
      setBusyAction(null);
    }
  };

  // 解散群聊：成功后从会话列表移除并清掉最近群记录，再回主页；不触发 reloadGroup（群已删除）
  const handleDissolve = async () => {
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

  // ---- 子群管理操作（窄屏群信息内编辑；与宽屏侧栏同交互） ----
  const runSubgroupAction = async (action: () => Promise<unknown>) => {
    setSubgroupBusy(true);
    setSubgroupError(null);
    try {
      await action();
      setSubgroupDialog(null);
    } catch (e) {
      setSubgroupError(e instanceof Error ? e.message : "操作失败");
    } finally {
      setSubgroupBusy(false);
    }
  };

  const handleSubgroupCreated = (sg: SubGroup) => {
    useSubGroupStore.getState().upsertSubgroup(sg.conversation_id, sg);
  };

  const handleSubgroupDeleted = (convId: string, subgroupId: string) => {
    useSubGroupStore.getState().removeSubgroup(convId, subgroupId);
    const active = useSubGroupStore.getState().activeByGroup[convId];
    if (active === subgroupId) {
      const list = useSubGroupStore.getState().byGroup[convId] ?? [];
      const defaultSg = list.find((sg) => sg.is_default);
      useSubGroupStore.getState().setActiveSubgroup(convId, defaultSg?.id ?? null);
    }
  };

  const confirmDeleteSubgroup = async () => {
    if (!subgroupDelete) return;
    setSubgroupBusy(true);
    setSubgroupError(null);
    try {
      await chatApi.deleteSubgroup(groupId, subgroupDelete.id);
      handleSubgroupDeleted(groupId, subgroupDelete.id);
      setSubgroupDelete(null);
      setSubgroupDialog(null);
    } catch (e) {
      setSubgroupError(e instanceof Error ? e.message : "删除失败");
    } finally {
      setSubgroupBusy(false);
    }
  };

  const confirmTransfer = async (m: ConversationMember) => {
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
      <div className="group-info-layout">
        {/* ---- 左列（宽屏独立滚动）：资料卡 + 管理卡 ---- */}
        <aside className="group-info-side">
          <section className="group-info-profile glass-card">
            <div className="group-info-profile-top">
              <Link to={`/group/${groupId}`} className="icon-btn-40 group-info-back" aria-label="返回群聊">
                <IconBack width={22} height={22} />
              </Link>
            </div>
            <div className="group-info-avatar-block">
              <Avatar
                label={conv.title}
                size={isNarrow ? 76 : 92}
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
                  placeholder="群简介"
                  rows={3}
                  aria-label="群简介"
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
                <div className="group-info-about">
                  <span className="group-info-about-label">群简介</span>
                  <p className="group-info-announcement">{conv.announcement || "暂无简介"}</p>
                </div>
                <p className="group-info-created">创建于 {formatDate(conv.created_at)}</p>
                <div className="group-info-stats">
                  <div className="group-info-stat">
                    <span className="group-info-stat-num">{memberCount}</span>
                    <span className="group-info-stat-label">成员</span>
                  </div>
                  <div className="group-info-stat">
                    <span className="group-info-stat-num">{onlineCount}</span>
                    <span className="group-info-stat-label">在线</span>
                  </div>
                  <div className="group-info-stat">
                    <span className="group-info-stat-num">{subgroups.length}</span>
                    <span className="group-info-stat-label">子群</span>
                  </div>
                </div>
                {canManage && (
                  <button type="button" className="btn btn-ghost" onClick={startEdit}>
                    编辑群资料
                  </button>
                )}
              </>
            )}
          </section>

          {/* 管理/更多卡：设置 + 入群申请审批 + 危险操作（或成员退出） */}
          <section className="group-info-manage solid-card">
            <h3 className="group-info-section-title">
              <IconMenu width={18} height={18} />
              {canManage ? "管理" : "更多"}
            </h3>
            {managementError && <p className="group-info-error" role="alert">{managementError}</p>}

            {canManage && (
              <>
                <div className="group-info-settings">
                  <div className="group-info-setting-row">
                    <span className="group-info-setting-label">加入方式</span>
                    {isOwner ? (
                      <span className="group-info-select-wrap" ref={policyWrapRef}>
                        <button
                          type="button"
                          className="group-info-select-btn"
                          disabled={busyAction !== null}
                          aria-haspopup="listbox"
                          aria-expanded={policyOpen}
                          onClick={() => setPolicyOpen((v) => !v)}
                          onKeyDown={(e) => {
                            if (e.key === "Escape") setPolicyOpen(false);
                          }}
                        >
                          <span>{conv.join_policy === "public" ? "公开加入" : "申请加入"}</span>
                          <IconChevronDown
                            width={14}
                            height={14}
                            className={`group-info-select-btn-arrow${policyOpen ? " is-open" : ""}`}
                          />
                        </button>
                        {policyOpen && (
                          <div className="group-info-select-menu" role="listbox" aria-label="加入方式">
                            {(["public", "application"] as const).map((v) => {
                              const selected = (conv.join_policy ?? "application") === v;
                              return (
                                <button
                                  key={v}
                                  type="button"
                                  role="option"
                                  aria-selected={selected}
                                  className={`group-info-select-option${selected ? " is-selected" : ""}`}
                                  onClick={() => {
                                    setPolicyOpen(false);
                                    void runManagementAction("join-policy", () => chatApi.patchConversation(groupId, { join_policy: v }));
                                  }}
                                >
                                  <IconCheck width={14} height={14} className="group-info-select-check" />
                                  <span>{v === "public" ? "公开加入" : "申请加入"}</span>
                                </button>
                              );
                            })}
                          </div>
                        )}
                      </span>
                    ) : (
                      <span className="group-info-setting-value">
                        {conv.join_policy === "public" ? "公开加入" : "申请加入"}
                      </span>
                    )}
                  </div>
                  {isOwner && emojiPolicyLoaded && (
                    <label className="group-info-setting-row group-info-switch">
                      <span className="group-info-setting-label">成员可上传表情包</span>
                      <span className="group-info-switch-ui">
                        <input
                          type="checkbox"
                          checked={allowMemberUpload}
                          disabled={busyAction !== null}
                          onChange={(e) => void toggleEmojiUploadPolicy(e.target.checked)}
                        />
                        <span className="group-info-switch-track">
                          <span className="group-info-switch-thumb" />
                        </span>
                      </span>
                    </label>
                  )}
                </div>

                <div className="group-info-requests">
                  <h4 className="group-info-requests-title">
                    入群申请审批 · 待处理（{joinRequests.length}）
                  </h4>
                  {joinRequests.length > 0 ? (
                    joinRequests.map((request) => (
                      <div key={request.id} className="group-info-request">
                        <div className="group-info-request-main">
                          <span className="group-info-request-name">
                            {request.applicant.nickname || request.applicant.username}
                          </span>
                          {request.message && (
                            <span className="group-info-request-msg">{request.message}</span>
                          )}
                        </div>
                        <button type="button" className="btn btn-primary" disabled={busyAction !== null} onClick={() => void runManagementAction(`join-${request.id}`, async () => { await chatApi.actionJoinRequest(request.id, "accept"); setJoinRequests((items) => items.filter((item) => item.id !== request.id)); })}>同意</button>
                        <button type="button" className="btn btn-ghost" disabled={busyAction !== null} onClick={() => void runManagementAction(`join-${request.id}`, async () => { await chatApi.actionJoinRequest(request.id, "reject"); setJoinRequests((items) => items.filter((item) => item.id !== request.id)); })}>拒绝</button>
                      </div>
                    ))
                  ) : (
                    <p className="group-info-placeholder">暂无待处理申请</p>
                  )}
                </div>

                {isOwner && (
                  <div className="group-info-danger">
                    <button type="button" className="btn btn-ghost group-info-action-row" onClick={() => setTransferOpen(true)}>
                      转让群主
                    </button>
                    <button type="button" className="btn btn-destructive group-info-action-row" onClick={() => setConfirmAction({ kind: "dissolve" })}>
                      {busyAction === "dissolve" ? "解散中…" : "解散群聊"}
                    </button>
                  </div>
                )}
              </>
            )}

            {!isOwner && (
              <button type="button" className="btn btn-destructive group-info-action-row" disabled={busyAction !== null} onClick={() => setConfirmAction({ kind: "leave" })}>
                {busyAction === "leave" ? "退出中…" : "退出群聊"}
              </button>
            )}
          </section>
        </aside>

        {/* ---- 右列（独立滚动）：子群卡（上） + 成员卡（下） ---- */}
        <div className="group-info-main">
          <section className="group-info-subgroups solid-card">
            <header className="group-info-card-head">
              <IconGrid width={18} height={18} className="group-info-card-icon" />
              <h3 className="group-info-card-title">子群</h3>
              <span className="group-info-count">{subgroups.length}</span>
              {canManage && !subgroupEditing && (
                <button
                  type="button"
                  className="btn btn-ghost group-info-head-action"
                  onClick={() => {
                    setSubgroupError(null);
                    setSubgroupEditing(true);
                  }}
                  aria-label="编辑子群"
                >
                  编辑子群
                </button>
              )}
            </header>
            {subgroupError && <p className="group-info-error" role="alert">{subgroupError}</p>}
            {subgroups.length === 0 ? (
              <p className="group-info-placeholder">暂无子群</p>
            ) : (
              <>
                <ul className="group-info-subgroup-list">
                  {visibleSubgroups.map((sg) => {
                    const unread = unreadByKey[subgroupKey(groupId, sg.id)] ?? 0;
                    return (
                      <li key={sg.id} className="group-info-subgroup">
                        <span className="group-info-subgroup-name">{sg.name}</span>
                        {sg.is_default && <span className="group-info-role group-info-role-owner">默认组</span>}
                        {sg.muted === true && (
                          <span className="group-info-subgroup-muted" title="已禁言（仅群主/管理员可发言）">
                            禁言
                          </span>
                        )}
                        {unread > 0 && (
                          <span className="group-info-subgroup-badge" aria-label={`${unread} 条未读`}>
                            {unread > 99 ? "99+" : unread}
                          </span>
                        )}
                        {subgroupEditing && canManage && (
                          <button
                            type="button"
                            className="group-info-subgroup-edit-btn"
                            onClick={() => {
                              setSubgroupError(null);
                              setSubgroupDialog({ kind: "edit", sg });
                            }}
                            aria-label={`编辑子群 ${sg.name}`}
                            title="编辑子群"
                          >
                            <PencilIcon />
                          </button>
                        )}
                      </li>
                    );
                  })}
                </ul>
                {subgroups.length > SUBGROUP_PREVIEW_COUNT && (
                  <button
                    type="button"
                    className="btn btn-ghost group-info-expand-btn"
                    aria-expanded={showAllSubgroups}
                    onClick={() => setShowAllSubgroups((v) => !v)}
                  >
                    {showAllSubgroups ? "收起" : `查看更多（${subgroups.length - SUBGROUP_PREVIEW_COUNT}）`}
                  </button>
                )}
              </>
            )}
            {canManage && subgroupEditing && (
              <div className="group-info-subgroup-edit-actions">
                <button
                  type="button"
                  className="btn btn-primary"
                  onClick={() => {
                    setSubgroupError(null);
                    setSubgroupDialog({ kind: "add" });
                  }}
                  aria-label="添加子群"
                >
                  <IconPlus width={16} height={16} /> 添加子群
                </button>
                <button
                  type="button"
                  className="btn btn-ghost"
                  onClick={() => setSubgroupEditing(false)}
                  aria-label="完成子群编辑"
                >
                  完成
                </button>
              </div>
            )}
          </section>

          <section className="group-info-members solid-card">
            <header className="group-info-card-head">
              <IconUsers width={18} height={18} className="group-info-card-icon" />
              <h3 className="group-info-card-title">成员</h3>
              <span className="group-info-count">{members.length}</span>
              <span className="group-info-online">在线 {onlineCount}</span>
            </header>
            {members.length === 0 ? (
              <p className="group-info-placeholder">暂无成员</p>
            ) : (
              <ul className="group-info-member-list">
                {members.map((m) => (
                  <li key={m.id} className="group-info-member">
                    <Avatar
                      label={m.user.nickname || m.user.username}
                      size={isNarrow ? 36 : 40}
                      online={presenceOnline(onlineUsers, withLiveStatus(onlineStatuses, m.user))}
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
            )}
          </section>
        </div>
      </div>

      {transferOpen && (
        <TransferOwnerDialog
          members={transferCandidates}
          busy={busyAction === "transfer"}
          error={managementError}
          onConfirm={(m) => setConfirmAction({ kind: "transfer", member: m })}
          onClose={() => setTransferOpen(false)}
        />
      )}

      {subgroupDialog && (
        <SubGroupDialog
          state={subgroupDialog}
          busy={subgroupBusy}
          error={subgroupError}
          onClose={() => {
            if (subgroupBusy) return;
            setSubgroupDialog(null);
            setSubgroupError(null);
          }}
          onConfirm={async (name, muted) => {
            if (subgroupDialog.kind === "add") {
              await runSubgroupAction(async () => {
                const sg = await chatApi.createSubgroup(groupId, name);
                handleSubgroupCreated(sg);
              });
            } else {
              await runSubgroupAction(async () => {
                const sg = await chatApi.updateSubgroup(groupId, subgroupDialog.sg.id, { name, muted });
                handleSubgroupCreated(sg);
              });
            }
          }}
          onDelete={() => {
            if (subgroupDialog.kind === "edit") setSubgroupDelete(subgroupDialog.sg);
          }}
        />
      )}

      {subgroupDelete && (
        <ConfirmDialog
          title="删除子群"
          message={`确定删除子群「${subgroupDelete.name}」？该子群的历史消息将归入默认组，不会丢失。`}
          confirmLabel="删除"
          onConfirm={() => void confirmDeleteSubgroup()}
          onClose={() => {
            if (subgroupBusy) return;
            setSubgroupDelete(null);
            setSubgroupError(null);
          }}
        />
      )}

      {confirmAction?.kind === "dissolve" && (
        <ConfirmDialog
          title="解散群聊"
          message={`确定解散群聊「${conv?.title ?? ""}」？此操作不可撤销，所有成员都会被移出。`}
          confirmLabel="解散"
          onConfirm={() => {
            setConfirmAction(null);
            void handleDissolve();
          }}
          onClose={() => setConfirmAction(null)}
        />
      )}
      {confirmAction?.kind === "leave" && (
        <ConfirmDialog
          title="退出群聊"
          message={`确定退出群聊「${conv?.title ?? ""}」？`}
          confirmLabel="退出"
          onConfirm={() => {
            setConfirmAction(null);
            void handleLeave();
          }}
          onClose={() => setConfirmAction(null)}
        />
      )}
      {confirmAction?.kind === "transfer" && (
        <ConfirmDialog
          title="转让群主"
          message={`确定将群主转让给 ${
            confirmAction.member.user.nickname || confirmAction.member.user.username
          }？转让后你将成为普通成员`}
          confirmLabel="转让"
          onConfirm={() => {
            const m = confirmAction.member;
            setConfirmAction(null);
            void confirmTransfer(m);
          }}
          onClose={() => setConfirmAction(null)}
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
  const onlineUsers = usePresenceStore((s) => s.users);
  const onlineStatuses = usePresenceStore((s) => s.statuses);

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
                        online={presenceOnline(onlineUsers, withLiveStatus(onlineStatuses, m.user))}
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

function PencilIcon() {
  return (
    <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">
      <path d="M17 3a2.85 2.83 0 1 1 4 4L7.5 20.5 2 22l1.5-5.5Z" />
    </svg>
  );
}
