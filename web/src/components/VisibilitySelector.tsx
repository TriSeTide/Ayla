import { useState } from "react";
import { useChatStore } from "../stores/chat";
import { useSocialPage } from "../hooks/useSocialPage";
import { DirectoryLoadMore } from "./DirectoryLoadMore";

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
  const [query, setQuery] = useState("");

  // 锁定群可见（群内创建）时，群复选框恒为选中；公开/好友仍可切换，但与本群共存。
  const groupChecked = lockGroup ? true : value.group;
  const groupsPage = useSocialPage("conversations", { type: "group", q: query }, groupChecked);
  const filtered = groupsPage.items;

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
          {selectedGroupIds.length > 0 && <div className="group-create-chips" aria-label="已选群">
            {selectedGroupIds.map((id) => <span className="group-create-chip" key={id}>
              {conversations.find((group) => group.id === id)?.title || `群 ${id}`}
              {!(lockGroup && id === initialGroupId) && <button type="button" className="group-create-chip-x"
                aria-label={`取消选择群 ${id}`} onClick={() => onSelectedGroupIdsChange(selectedGroupIds.filter((item) => item !== id))}>×</button>}
            </span>)}
          </div>}
          {!groupsPage.loading && !groupsPage.error && filtered.length === 0 ? (
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
          <DirectoryLoadMore {...groupsPage} retainCompletedSpace={false} />
        </div>
      )}
    </fieldset>
  );
}

export default VisibilitySelector;
