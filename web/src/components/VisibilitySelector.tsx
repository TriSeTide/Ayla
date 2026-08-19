import { useMemo, useState } from "react";
import { useChatStore } from "../stores/chat";

/** 可见性多选模式：public 互斥，friends 和 group 可以同时勾选 */
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
}: {
  value: VisibilitySelection;
  onChange: (value: VisibilitySelection) => void;
  selectedGroupIds: string[];
  onSelectedGroupIdsChange: (ids: string[]) => void;
  initialGroupId?: string | null;
}) {
  const groups = useChatStore((state) => state.conversations.filter((item) => item.type === "group"));
  const [query, setQuery] = useState("");
  const filtered = useMemo(() => {
    const needle = query.trim().toLowerCase();
    return groups.filter((group) => !needle || group.title.toLowerCase().includes(needle));
  }, [groups, query]);

  const togglePublic = (checked: boolean) => {
    // 公开互斥：勾选公开时取消其他选项
    if (checked) {
      onChange({ public: true, friends: false, group: false });
      onSelectedGroupIdsChange([]);
    } else {
      onChange({ ...value, public: false });
    }
  };

  const toggleFriends = (checked: boolean) => {
    // 勾选好友时自动取消公开
    onChange({ ...value, friends: checked, public: false });
  };

  const toggleGroup = (checked: boolean) => {
    // 勾选群时自动取消公开；群内创建时默认勾选当前群
    onChange({ ...value, group: checked, public: false });
    if (checked && initialGroupId && !selectedGroupIds.includes(initialGroupId)) {
      onSelectedGroupIdsChange([...selectedGroupIds, initialGroupId]);
    }
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
          <input type="checkbox" checked={value.friends} disabled={value.public} onChange={(e) => toggleFriends(e.target.checked)} />
          好友可见
        </label>
        <label>
          <input type="checkbox" checked={value.group} disabled={value.public} onChange={(e) => toggleGroup(e.target.checked)} />
          指定群可见
        </label>
      </div>
      {value.group && (
        <div className="visibility-selector-groups">
          <input className="field" value={query} onChange={(event) => setQuery(event.target.value)} placeholder="搜索群" aria-label="搜索群" />
          {filtered.length === 0 ? <span className="placeholder-desc">没有匹配的群</span> : filtered.map((group) => {
            const checked = selectedGroupIds.includes(group.id);
            return <label key={group.id} className="visibility-group-option">
              <input type="checkbox" checked={checked} onChange={() => onSelectedGroupIdsChange(checked ? selectedGroupIds.filter((id) => id !== group.id) : [...selectedGroupIds, group.id])} />
              <span>{group.title}</span>
            </label>;
          })}
        </div>
      )}
    </fieldset>
  );
}

export default VisibilitySelector;
