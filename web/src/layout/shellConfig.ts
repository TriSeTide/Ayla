/**
 * AppShell 路由配置（纯函数，组件与测试共用同一事实源）。
 *
 * - resolveModule：当前路径归属的一级模块（TopNav 指示条 / BottomTabs 选中态）。
 * - resolveFabAction：CreateFAB 动作随场景切换的匹配表（需求文档 §3.5、R-F1/R-F2）。
 * - isImmersiveRoute：沉浸式路由（直播间整页）不渲染任何壳层 chrome；
 *   F4 进房动画（底栏下滑走）的终态即此形态，动画过程由 useEnterRoomAnimation 提供。
 */
import { matchPath } from "react-router-dom";

export type ModuleKey = "home" | "voice" | "live" | "posts" | "games";

export interface ModuleMeta {
  key: ModuleKey;
  label: string;
  path: string;
}

/** 一级模块表（文案 + 路由）；视觉顺序见 BottomTabs 的 TAB_ORDER（主页居中） */
export const PRIMARY_MODULES: ModuleMeta[] = [
  { key: "home", label: "主页", path: "/home" },
  { key: "voice", label: "语音", path: "/voice" },
  { key: "live", label: "直播", path: "/live" },
  { key: "posts", label: "帖子", path: "/posts" },
  { key: "games", label: "桌游", path: "/games" },
];

const MODULE_RULES: Array<[ModuleKey, string[]]> = [
  // /group/* 群聊场景与旧 /chat 兼容页都归"主页"模块（宽屏主页 = 三列群聊界面）
  ["home", ["/home", "/group/*", "/chat", "/chat/*"]],
  ["voice", ["/voice", "/voice/*"]],
  ["live", ["/live", "/live/*"]],
  ["posts", ["/posts", "/posts/*"]],
  ["games", ["/games", "/games/*"]],
];

/** 当前路径归属的一级模块；/messages /search /profile 等无归属返回 null（无高亮） */
export function resolveModule(pathname: string): ModuleKey | null {
  for (const [key, patterns] of MODULE_RULES) {
    if (patterns.some((p) => matchPath({ path: p, end: true }, pathname))) return key;
  }
  return null;
}

/** 沉浸式路由（直播间）：壳层 chrome 全隐 */
export function isImmersiveRoute(pathname: string): boolean {
  return matchPath({ path: "/live/:channelId", end: true }, pathname) != null;
}

export interface FabAction {
  /** 动作标识（测试锚点） */
  key: string;
  /** 面板主动作文案 */
  label: string;
  /** 群内创建时归属的群 id；一级 tab 创建为 null（R-F2） */
  groupId: string | null;
  /** 该创建表单预计落地的步骤标识（F1 阶段点击动作项仅提示，不打开表单） */
  plannedStep: string;
}

/**
 * CreateFAB 路由匹配表（需求文档 §3.5）。
 * 群聊场景内跟随子界面；聊天 / 群信息子界面与直播间、消息、搜索、个人页无 FAB。
 */
export function resolveFabAction(pathname: string): FabAction | null {
  if (isImmersiveRoute(pathname)) return null;

  const groupScene = matchPath({ path: "/group/:id/:scene", end: true }, pathname);
  if (groupScene?.params.id && groupScene.params.scene) {
    const groupId = groupScene.params.id;
    switch (groupScene.params.scene) {
      case "voice":
        return { key: "group-voice", label: "创建群内语音房", groupId, plannedStep: "F5" };
      case "live":
        return { key: "group-live", label: "群内开播", groupId, plannedStep: "F4" };
      case "posts":
        return { key: "group-post", label: "群内发帖", groupId, plannedStep: "F6" };
      case "games":
        return { key: "group-game", label: "创建群内桌游室", groupId, plannedStep: "F7" };
      default:
        return null; // info 等无创建语义
    }
  }
  // 群聊聊天子界面 FAB 隐藏（需求 §3.5）
  if (matchPath({ path: "/group/:id", end: true }, pathname)) return null;

  if (matchPath({ path: "/home", end: true }, pathname)) {
    return { key: "create-group", label: "创建群聊", groupId: null, plannedStep: "F2" };
  }
  if (matchPath({ path: "/voice", end: true }, pathname)) {
    return { key: "create-voice", label: "创建语音房", groupId: null, plannedStep: "F5" };
  }
  if (matchPath({ path: "/live", end: true }, pathname)) {
    return { key: "create-live", label: "创建直播间", groupId: null, plannedStep: "F4" };
  }
  if (matchPath({ path: "/posts", end: true }, pathname)) {
    return { key: "create-post", label: "发帖", groupId: null, plannedStep: "F6" };
  }
  if (matchPath({ path: "/games", end: true }, pathname)) {
    return { key: "create-game", label: "创建桌游室", groupId: null, plannedStep: "F7" };
  }
  return null;
}
