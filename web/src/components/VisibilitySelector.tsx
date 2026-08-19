import { useEffect, useMemo, useRef, useState } from "react";
import { useChatStore, isChatStale } from "../stores/chat";
import * as chatApi from "../api/chat";

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
          {groupsLoading ? (
            <div className="visibility-groups-skeleton" style={{ height: 40, background: "rgba(157, 191, 230, 0.15)", borderRadius: "12px", margin: "8px 0" }} />
          ) : filtered.length === 0 ? (
            <span className="placeholder-desc">没有匹配的群</span>
          ) : (
            filtered.map((group) => {
              const checked = selectedGroupIds.includes(group.id);
              return (
                <label key={group.id} className="visibility-group-option">
                  <input type="checkbox" checked={checked} onChange={() => onSelectedGroupIdsChange(checked ? selectedGroupIds.filter((id) => id !== group.id) : [...selectedGroupIds, group.id])} />
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
