/**
 * ChannelSidebar —— 宽屏频道侧栏（design.md §12.4，布局文档 §3.2）。
 *
 * 240–280px 玻璃：群名头（点击进群信息 R-G9 入口）+ 五场景项
 * （聊天/语音/直播/帖子/桌游，选中 rgba(157,191,230,0.35) 胶囊底）+ 返回主页（无，宽屏本就在主页）。
 * 状态标识（语音在麦人数/直播 LIVE/帖子未读）随 F4/F5/F6 接入，F3 不渲染。
 * 群信息入口仅群名头一处（R-G9），侧栏底部不再放重复入口。
 *
 * 子群（群聊子群功能）：
 * - 「聊天」场景项下展开子群列表（默认展开，可收起）；
 * - 子群行显示未读红点（子群独立未读）与当前选中态，点击切换子群；
 * - 群主/管理员：子群列表下方「编辑」按钮 → 编辑态变【+】【x】；
 *   编辑态每个子群行出现编辑按钮 → 弹窗改名/删除（默认组不可删）。
 */
import { useCallback, useState } from "react";
import * as chatApi from "../api/chat";
import type { SubGroup } from "../api/types";
import { ConfirmDialog } from "../components/ConfirmDialog";
import { SubGroupDialog, type SubGroupDialogState } from "../components/group/SubGroupDialog";
import { IconChat, IconClose, IconGame, IconMic, IconPlus, IconPost, IconVideo } from "../components/icons";
import type { GroupScene } from "../stores/group";
import { useGroupStore } from "../stores/group";
import { useVoiceStore } from "../stores/voice";
import { useLiveStore } from "../stores/live";
import { useChatStore } from "../stores/chat";
import { subgroupKey, useSubGroupStore } from "../stores/subgroup";

const SCENE_META: Array<{ key: GroupScene; label: string; icon: typeof IconMic }> = [
  { key: "chat", label: "聊天", icon: IconChat },
  { key: "voice", label: "语音", icon: IconMic },
  { key: "live", label: "直播", icon: IconVideo },
  { key: "posts", label: "帖子", icon: IconPost },
  { key: "games", label: "桌游", icon: IconGame },
];

export function ChannelSidebar({
  groupName,
  activeScene,
  onSelectScene,
  onOpenInfo,
  onSelectSubgroup,
}: {
  groupName: string;
  activeScene: GroupScene;
  onSelectScene: (scene: GroupScene) => void;
  onOpenInfo: () => void;
  /** 切换当前子群（宽屏侧栏点击子群行） */
  onSelectSubgroup: (subgroupId: string) => void;
}) {
  const currentGroupId = useGroupStore((state) => state.currentGroupId);
  const voiceCount = useVoiceStore((state) => state.channels
    .filter((channel) => (channel.allowed_group_ids ?? []).some((id) => String(id) === String(currentGroupId)))
    .reduce((sum, channel) => sum + (channel.member_count || 0), 0));
  const hasLive = useLiveStore((state) => state.channels
    .some((channel) => (channel.allowed_group_ids ?? []).some((id) => String(id) === String(currentGroupId)) && channel.status === "live"));
  // 群内未读帖子数（浏览与已读同源）：>0 时帖子场景项显示红点
  const postUnread = useChatStore((state) => state.conversations
    .find((c) => c.id === currentGroupId)?.post_unread_count ?? 0);

  // ---- 子群状态 ----
  const subgroups = useSubGroupStore((state) => state.byGroup[currentGroupId ?? ""] ?? []);
  const activeSubgroupId = useSubGroupStore((state) => state.activeByGroup[currentGroupId ?? ""] ?? null);
  const unreadByKey = useSubGroupStore((state) => state.unreadByKey);
  const myRole = useChatStore((state) => state.conversations
    .find((c) => c.id === currentGroupId)?.my_role ?? null);
  const canManage = myRole === "owner" || myRole === "admin";

  const [subgroupsOpen, setSubgroupsOpen] = useState(false);
  const [editing, setEditing] = useState(false);
  const [dialog, setDialog] = useState<SubGroupDialogState>(null);
  const [busy, setBusy] = useState(false);
  const [dialogError, setDialogError] = useState<string | null>(null);
  const [confirmDelete, setConfirmDelete] = useState<SubGroup | null>(null);

  const handleCreated = useCallback((sg: SubGroup) => {
    useSubGroupStore.getState().upsertSubgroup(sg.conversation_id, sg);
  }, []);

  const handleDeleted = useCallback((convId: string, subgroupId: string) => {
    useSubGroupStore.getState().removeSubgroup(convId, subgroupId);
    const active = useSubGroupStore.getState().activeByGroup[convId];
    if (active === subgroupId) {
      const list = useSubGroupStore.getState().byGroup[convId] ?? [];
      const defaultSg = list.find((sg) => sg.is_default);
      useSubGroupStore.getState().setActiveSubgroup(convId, defaultSg?.id ?? null);
    }
  }, []);

  const runDialogAction = useCallback(async (action: () => Promise<unknown>) => {
    setBusy(true);
    setDialogError(null);
    try {
      await action();
      setDialog(null);
    } catch (e) {
      setDialogError(e instanceof Error ? e.message : "操作失败");
    } finally {
      setBusy(false);
    }
  }, []);

  const confirmDeleteSubgroup = useCallback(async () => {
    if (!confirmDelete || !currentGroupId) return;
    setBusy(true);
    setDialogError(null);
    try {
      await chatApi.deleteSubgroup(currentGroupId, confirmDelete.id);
      handleDeleted(currentGroupId, confirmDelete.id);
      setConfirmDelete(null);
      setDialog(null);
    } catch (e) {
      setDialogError(e instanceof Error ? e.message : "删除失败");
    } finally {
      setBusy(false);
    }
  }, [confirmDelete, currentGroupId, handleDeleted]);

  return (
    <aside className="channel-sidebar" aria-label="群内场景">
      <button type="button" className="channel-sidebar-head" onClick={onOpenInfo}>
        <span className="channel-sidebar-title">{groupName}</span>
        <Chevron />
      </button>
      <ul className="channel-sidebar-list">
        {SCENE_META.map((s) => {
          const Icon = s.icon;
          const active = activeScene === s.key;
          if (s.key === "chat") {
            const defaultSg = subgroups.find((sg) => sg.is_default) ?? subgroups[0];
            return (
              <li key={s.key} className="channel-scene-item">
                <div className="channel-scene-row">
                  <button
                    type="button"
                    className={`channel-scene ${active ? "is-active" : ""}`}
                    onClick={() => {
                      // 点聊天按钮：进入聊天场景 + 默认选中第一个子群（不控制展开/收起）
                      onSelectScene("chat");
                      if (defaultSg) onSelectSubgroup(defaultSg.id);
                    }}
                    aria-current={active ? "true" : undefined}
                  >
                    <Icon width={20} height={20} />
                    <span>{s.label}</span>
                  </button>
                  <button
                    type="button"
                    className={`channel-scene-subgroup-toggle${subgroupsOpen ? " is-open" : ""}`}
                    onClick={() => setSubgroupsOpen((open) => !open)}
                    aria-label={subgroupsOpen ? "收起子群" : "展开子群"}
                    aria-expanded={subgroupsOpen}
                  >
                    <IconChevronDown width={14} height={14} />
                  </button>
                </div>
                {subgroupsOpen && (
                  <div className="channel-subgroups">
                    <ul className="channel-subgroup-list">
                      {subgroups.map((sg) => {
                        const unread = unreadByKey[subgroupKey(currentGroupId ?? "", sg.id)] ?? 0;
                        // 宽屏切到聊天以外的场景时不高亮子群
                        const isActive = activeScene === "chat" && sg.id === activeSubgroupId;
                        return (
                          <li key={sg.id} className="channel-subgroup-item">
                            <button
                              type="button"
                              className={`channel-subgroup${isActive ? " is-active" : ""}`}
                              onClick={() => {
                                // 从任意场景点子群行：选中该子群并切回聊天场景
                                onSelectSubgroup(sg.id);
                                onSelectScene("chat");
                              }}
                              aria-current={isActive ? "true" : undefined}
                            >
                              <span className="channel-subgroup-name">{sg.name}</span>
                              {sg.muted === true && (
                                <span className="channel-subgroup-muted" title="已禁言（仅群主/管理员可发言）">
                                  禁言
                                </span>
                              )}
                              {unread > 0 && (
                                <span
                                  className="channel-subgroup-badge"
                                  aria-label={`${unread} 条未读`}
                                  title="有未读消息"
                                >
                                  {unread > 99 ? "99+" : unread}
                                </span>
                              )}
                            </button>
                            {editing && (
                              <button
                                type="button"
                                className="channel-subgroup-edit-btn"
                                onClick={() => {
                                  setDialogError(null);
                                  setDialog({ kind: "edit", sg });
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
                    {canManage && (
                      editing ? (
                        <div className="channel-subgroup-edit-actions">
                          <button
                            type="button"
                            className="channel-subgroup-edit-action"
                            onClick={() => {
                              setDialogError(null);
                              setDialog({ kind: "add" });
                            }}
                            aria-label="添加子群"
                            title="添加子群"
                          >
                            <IconPlus width={16} height={16} />
                          </button>
                          <button
                            type="button"
                            className="channel-subgroup-edit-action"
                            onClick={() => setEditing(false)}
                            aria-label="退出编辑"
                            title="退出编辑"
                          >
                            <IconClose width={16} height={16} />
                          </button>
                        </div>
                      ) : (
                        <button
                          type="button"
                          className="channel-subgroup-edit-toggle"
                          onClick={() => setEditing(true)}
                        >
                          编辑
                        </button>
                      )
                    )}
                  </div>
                )}
              </li>
            );
          }
          return (
            <li key={s.key}>
              <button
                type="button"
                className={`channel-scene ${active ? "is-active" : ""}`}
                onClick={() => onSelectScene(s.key)}
                aria-current={active ? "true" : undefined}
              >
                <Icon width={20} height={20} />
                <span>{s.label}</span>
                {s.key === "voice" && voiceCount > 0 && <span className="channel-scene-status">{voiceCount}</span>}
                {s.key === "live" && hasLive && <span className="channel-scene-status">LIVE</span>}
                {s.key === "posts" && postUnread > 0 && (
                  <span
                    className="channel-scene-status channel-scene-posts-badge"
                    aria-label={`${postUnread} 条未读帖子`}
                    title="有未读帖子"
                  >
                    {postUnread > 99 ? "99+" : postUnread}
                  </span>
                )}
              </button>
            </li>
          );
        })}
      </ul>

      {dialog && (
        <SubGroupDialog
          state={dialog}
          busy={busy}
          error={dialogError}
          onClose={() => {
            if (busy) return;
            setDialog(null);
            setDialogError(null);
          }}
          onConfirm={async (name, muted) => {
            if (!currentGroupId) return;
            if (dialog.kind === "add") {
              await runDialogAction(async () => {
                const sg = await chatApi.createSubgroup(currentGroupId, name);
                handleCreated(sg);
              });
            } else {
              await runDialogAction(async () => {
                const sg = await chatApi.updateSubgroup(currentGroupId, dialog.sg.id, { name, muted });
                handleCreated(sg);
              });
            }
          }}
          onDelete={() => {
            if (dialog.kind === "edit") setConfirmDelete(dialog.sg);
          }}
        />
      )}

      {confirmDelete && (
        <ConfirmDialog
          title="删除子群"
          message={`确定删除子群「${confirmDelete.name}」？该子群的历史消息将归入默认组，不会丢失。`}
          confirmLabel="删除"
          onConfirm={() => void confirmDeleteSubgroup()}
          onClose={() => {
            if (busy) return;
            setConfirmDelete(null);
            setDialogError(null);
          }}
        />
      )}
    </aside>
  );
}

function Chevron() {
  return (
    <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">
      <path d="m9 6 6 6-6 6" />
    </svg>
  );
}

function IconChevronDown({ width = 14, height = 14 }: { width?: number; height?: number }) {
  return (
    <svg width={width} height={height} viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">
      <path d="m6 9 6 6 6-6" />
    </svg>
  );
}

function PencilIcon() {
  return (
    <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">
      <path d="M17 3a2.85 2.83 0 1 1 4 4L7.5 20.5 2 22l1.5-5.5Z" />
    </svg>
  );
}
