/**
 * 可见性标签工具函数
 * 根据 visibility、allowed_group_names 和 group_name 生成标签数组
 */

interface VisibilityItem {
  visibility: "public" | "friends" | "group";
  allowed_group_names?: string[];
  group_name?: string | null;
}

/**
 * 生成可见性标签数组
 * - public: ["公开"]（单选，不与其他组合）
 * - friends: ["好友"] + allowed_group_names（可与群组合）
 * - group: allowed_group_names 或 group_name（仅群）
 */
export function getVisibilityLabels(item: VisibilityItem): string[] {
  // 公开：单选，不与其他组合
  if (item.visibility === "public") {
    return ["公开"];
  }

  const labels: string[] = [];

  // 好友可见：显示"好友"标签
  if (item.visibility === "friends") {
    labels.push("好友");
  }

  // 添加所有指定群的标签
  if (item.allowed_group_names && item.allowed_group_names.length > 0) {
    labels.push(...item.allowed_group_names);
  } else if (item.visibility === "group" && item.group_name) {
    // 如果是群可见但没有 allowed_groups，回退到 group_name
    labels.push(item.group_name);
  }

  // 如果没有任何标签（理论上不应该发生），返回默认标签
  if (labels.length === 0) {
    return item.visibility === "friends" ? ["好友"] : ["群可见"];
  }

  return labels;
}
