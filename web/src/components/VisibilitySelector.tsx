import { useEffect, useMemo, useRef, useState } from "react";
import { useChatStore, isChatStale } from "../stores/chat";
import * as chatApi from "../api/chat";

/** 可见性多选模式：public/friends 互斥，group（群白名单）独立可与二者叠加 */
export interface VisibilitySelection {
  public: boolean;
  friends: boolean;
  group: boolean;
}

export function VisibilitySelector({
  value,
  onChange,
  selectedGroupIds,
  onSelectedGroupIdsChange,
  initialGroupId,
  lockGroup = false,
}: {
  value: VisibilitySelection;
  onChange: (value: VisibilitySelection) => void;
  selectedGroupIds: string[];
  onSelectedGroupIdsChange: (ids: string[]) => void;
  initialGroupId?: string | null;
  /** 锁定群可见（群内创建）：本群强制勾选且不可取消；公开/好友可与本群共存 */
  lockGroup?: boolean;
}) {
  const conversations = useChatStore((state) => state.conversations);
  const groups = useMemo(() => conversations.filter((item) => item.type === "group"), [conversations]);
  const [query, setQuery] = useState("");
  const [groupsLoading, setGroupsLoading] = useState(false);
  // 本次挂载最多尝试一次加载：空列表场景（后端确实没有群）无法区分「从未加载」与
  // 「已加载完毕」，若每次都重试，resolve 后 setConversations 更新 lastFetched 会再次
  // 触发 effect → 无限循环。加载成功或失败都置位，不再重试。
  const loadAttempted = useRef(false);

  // ✅ 按需加载兜底：组件挂载时检查群列表是否为空或过期（60s），空或过期则主动加载
  useEffect(() => {
    if (loadAttempted.current) return;
    const stale = isChatStale(60_000);
    if ((conversations.length === 0 || stale) && !groupsLoading) {
      loadAttempted.current = true;
      setGroupsLoading(true);
      chatApi
        .listConversations()
        .then((list) => {
          useChatStore.getState().setConversations(list);
        })
        .catch((err) => {
          console.error("加载群列表失败", err);
        })
        .finally(() => {
          setGroupsLoading(false);
        });
    }
  }, [conversations.length, groupsLoading]);
  const filtered = useMemo(() => {
    const needle = query.trim().toLowerCase();
    return groups.filter((group) => !needle || group.title.toLowerCase().includes(needle));
  }, [groups, query]);

  // 锁定群可见（群内创建）时，群复选框恒为选中；公开/好友仍可切换，但与本群共存。
  const groupChecked = lockGroup ? true : value.group;

  const togglePublic = (checked: boolean) => {
    // 公开与好友互斥；群可见独立保留（"公开+群""好友+群"均合法）
    onChange({ ...value, public: checked, friends: checked ? false : value.friends });
  };

  const toggleFriends = (checked: boolean) => {
    // 好友与公开互斥；群可见独立保留
    onChange({ ...value, friends: checked, public: checked ? false : value.public });
  };

  const toggleGroup = (checked: boolean) => {
    if (lockGroup) return; // 锁定大类不可取消（复选框 disabled，此处双保险）
    // 群可见独立：只切换 group，不影响公开/好友
    onChange({ ...value, group: checked });
    if (!checked) {
      onSelectedGroupIdsChange([]);
    }
  };

  return (
    <fieldset className="visibility-selector">
      <legend>可见范围</legend>
      <div className="visibility-selector-options">
        <label>
          <input type="checkbox" checked={value.public} onChange={(e) => togglePublic(e.target.checked)} />
          公开
        </label>
        <label>
          <input type="checkbox" checked={value.friends} onChange={(e) => toggleFriends(e.target.checked)} />
          好友可见
        </label>
        <label className={lockGroup ? "is-locked" : undefined}>
          <input
            type="checkbox"
            checked={groupChecked}
            disabled={lockGroup}
            onChange={(e) => toggleGroup(e.target.checked)}
          />
          指定群可见
        </label>
      </div>
      {groupChecked && (
        <div className="visibility-selector-groups">
          <input className="field" value={query} onChange={(event) => setQuery(event.target.value)} placeholder="搜索群" aria-label="搜索群" />
          {groupsLoading ? (
            <div className="visibility-groups-skeleton" style={{ height: 40, background: "rgba(249, 176, 255, 0.15)", borderRadius: "12px", margin: "8px 0" }} />
          ) : filtered.length === 0 ? (
            <span className="placeholder-desc">没有匹配的群</span>
          ) : (
            filtered.map((group) => {
              // 群内创建锁定本群：该群条目恒勾选且不可取消，其他群仍可多选
              const isLockedGroup = lockGroup && initialGroupId != null && group.id === initialGroupId;
              const checked = isLockedGroup || selectedGroupIds.includes(group.id);
              return (
                <label key={group.id} className={`visibility-group-option${isLockedGroup ? " is-locked" : ""}`}>
                  <input
                    type="checkbox"
                    checked={checked}
                    disabled={isLockedGroup}
                    onChange={() => {
                      const isSelected = selectedGroupIds.includes(group.id);
                      onSelectedGroupIdsChange(
                        isSelected
                          ? selectedGroupIds.filter((id) => id !== group.id)
                          : [...selectedGroupIds, group.id],
                      );
                    }}
                  />
                  <span>{group.title}</span>
                </label>
              );
            })
          )}
        </div>
      )}
    </fieldset>
  );
}

export default VisibilitySelector;
