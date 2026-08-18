import { useId, useMemo, useState } from "react";
import { useChatStore } from "../stores/chat";

export type VisibilityValue = "public" | "friends" | "group";

export function VisibilitySelector({
  value,
  onChange,
  selectedGroupIds,
  onSelectedGroupIdsChange,
  initialGroupId,
}: {
  value: VisibilityValue;
  onChange: (value: VisibilityValue) => void;
  selectedGroupIds: string[];
  onSelectedGroupIdsChange: (ids: string[]) => void;
  initialGroupId?: string | null;
}) {
  const groupName = `visibility-${useId()}`;
  const groups = useChatStore((state) => state.conversations.filter((item) => item.type === "group"));
  const [query, setQuery] = useState("");
  const filtered = useMemo(() => {
    const needle = query.trim().toLowerCase();
    return groups.filter((group) => !needle || group.title.toLowerCase().includes(needle));
  }, [groups, query]);

  const selectVisibility = (next: VisibilityValue) => {
    onChange(next);
    if (next === "group" && initialGroupId && !selectedGroupIds.includes(initialGroupId)) {
      onSelectedGroupIdsChange([...selectedGroupIds, initialGroupId]);
    }
  };

  return (
    <fieldset className="visibility-selector">
      <legend>可见范围</legend>
      <div className="visibility-selector-options">
        <label><input type="radio" name={groupName} checked={value === "public"} onChange={() => selectVisibility("public")} /> 公开</label>
        <label><input type="radio" name="visibility" checked={value === "friends"} onChange={() => selectVisibility("friends")} /> 好友可见</label>
        <label><input type="radio" name="visibility" checked={value === "group"} onChange={() => selectVisibility("group")} /> 指定群可见</label>
      </div>
      {value === "group" && (
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
