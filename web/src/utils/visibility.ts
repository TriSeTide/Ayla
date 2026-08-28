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
 * - public → ["公开"]；friends → ["好友"]（二者互斥，最多一个）
 * - allowed_group_names → 白名单群名，可与公开/好友叠加显示（"公开+群""好友+群"共存）
 * - group 可见且无白名单群名 → 回退 group_name（旧数据兼容）
 */
export function getVisibilityLabels(item: VisibilityItem): string[] {
  const labels: string[] = [];

  // 基础可见性标签（公开 / 好友 互斥）
  if (item.visibility === "public") {
    labels.push("公开");
  } else if (item.visibility === "friends") {
    labels.push("好友");
  }

  // 群可见：白名单群名（可与公开/好友叠加）
  if (item.allowed_group_names && item.allowed_group_names.length > 0) {
    labels.push(...item.allowed_group_names);
  } else if (item.visibility === "group" && item.group_name) {
    // 兼容旧数据：visibility=group 但无白名单群名时回退归属群名
    labels.push(item.group_name);
  }

  // 没有任何标签（异常数据），按 visibility 兜底
  if (labels.length === 0) {
    if (item.visibility === "friends") return ["好友"];
    if (item.visibility === "public") return ["公开"];
    return ["群可见"];
  }

  return labels;
}
