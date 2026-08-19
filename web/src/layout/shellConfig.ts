/**
 * AppShell 路由配置（纯函数，组件与测试共用同一事实源）。
 *
 * - resolveModule：当前路径归属的一级模块（TopNav 指示条 / BottomTabs 选中态）。
 * - resolveFabAction：CreateFAB 动作随场景切换的匹配表（需求文档 §3.5、R-F1/R-F2）。
 * - isLiveRoomRoute：直播间路由（窄屏进房动画=底栏下滑走，宽屏 TopNav 常驻）。
 * - isGroupScene：群聊场景路由（窄屏 GroupPage 自渲染顶部导航条，壳层不出底栏）。
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
  // /group/* 群聊场景归"主页"模块（宽屏主页 = 三列群聊界面）；私聊窗口 /chat/:id 无模块高亮
  ["home", ["/home", "/group/*"]],
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

/**
 * 消息路由（宽屏 TopNav 消息项选中态）：消息中心 / 私聊窗口。
 * 群聊 /group/:id 归"主页"模块（resolveModule 已覆盖），消息项不抢高亮。
 */
export function isMessagesRoute(pathname: string): boolean {
  return (
    matchPath({ path: "/messages", end: true }, pathname) != null ||
    matchPath({ path: "/chat/:conversationId", end: true }, pathname) != null
  );
}

/**
 * 私聊聊天路由（窄屏 /chat/:conversationId）：底部有输入框，壳层不渲染
 * BottomTabs / MessageFAB（需求：下方有输入框时不能有导航栏）。
 */
export function isPrivateChatRoute(pathname: string): boolean {
  return matchPath({ path: "/chat/:conversationId", end: true }, pathname) != null;
}

/**
 * 直播间路由（/live/:channelId）。
 * 窄屏：进房动画 = 底栏下滑走（shell store 驱动），终态底栏在视口外；
 * 宽屏：TopNav 常驻 + 视频主区 + 弹幕侧列（非整屏遮挡顶栏，布局文档 §3.4）。
 */
export function isLiveRoomRoute(pathname: string): boolean {
  return (
    matchPath({ path: "/live/:channelId", end: true }, pathname) != null ||
    matchPath({ path: "/live/start/:channelId", end: true }, pathname) != null
  );
}

/**
 * 群聊场景路由（窄屏）：GroupPage 自渲染顶部导航条（进群动画 = 底栏上移到顶部），
 * 壳层不渲染 BottomTabs / MessageFAB（R-G1/R-G6）。宽屏仍走 AppShell TopNav + 左侧栏。
 */
export function isGroupScene(pathname: string): boolean {
  return (
    matchPath({ path: "/group/:id", end: true }, pathname) != null ||
    matchPath({ path: "/group/:id/:scene", end: true }, pathname) != null ||
    matchPath({ path: "/group/:id/posts/:postId", end: true }, pathname) != null
  );
}

/**
 * 帖子详情路由（窄屏）：底栏原位替换为评论输入框（R-P3，交叉淡化无位移），
 * 壳层不渲染 BottomTabs / MessageFAB（让位给 PostDetailPage 的评论输入框）。
 */
export function isPostDetailRoute(pathname: string): boolean {
  return matchPath({ path: "/posts/:postId", end: true }, pathname) != null;
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
  /** 已接线的真表单处理（F4-F8 起：直播/语音/发帖/桌游已落地；F10 后建群也落地）；undefined = 仍提示落步骤 */
  handler?: "live" | "voice" | "post" | "game" | "group";
}

/**
 * CreateFAB 路由匹配表（需求文档 §3.5）。
 * 群聊场景内跟随子界面；群内直播入口在直播侧栏，群内帖子使用底部编辑器，
 * 聊天 / 群信息子界面与直播间、消息、搜索、个人页无 FAB。
 */
export function resolveFabAction(pathname: string): FabAction | null {
  if (isLiveRoomRoute(pathname)) return null;

  const groupScene = matchPath({ path: "/group/:id/:scene", end: true }, pathname);
  if (groupScene?.params.id && groupScene.params.scene) {
    const groupId = groupScene.params.id;
    switch (groupScene.params.scene) {
      case "voice":
        return { key: "group-voice", label: "创建群内语音房", groupId, plannedStep: "F5", handler: "voice" };
      case "live":
        return null; // 群内直播创建入口放在直播侧栏左下角
      case "posts":
        return null; // 群内帖子发帖走底部输入框（R-P2 关键差异），FAB 隐藏
      case "games":
        return { key: "group-game", label: "创建群内桌游室", groupId, plannedStep: "F7", handler: "game" };
      default:
        return null; // info 等无创建语义
    }
  }
  // 群聊聊天子界面 FAB 隐藏（需求 §3.5）
  if (matchPath({ path: "/group/:id", end: true }, pathname)) return null;

  if (matchPath({ path: "/home", end: true }, pathname)) {
    return { key: "create-group", label: "创建群聊", groupId: null, plannedStep: "F2", handler: "group" };
  }
  if (matchPath({ path: "/voice", end: true }, pathname)) {
    return { key: "create-voice", label: "创建语音房", groupId: null, plannedStep: "F5", handler: "voice" };
  }
  if (matchPath({ path: "/live", end: true }, pathname)) {
    return { key: "create-live", label: "创建直播间", groupId: null, plannedStep: "F4", handler: "live" };
  }
  if (matchPath({ path: "/posts", end: true }, pathname)) {
    return { key: "create-post", label: "发帖", groupId: null, plannedStep: "F6", handler: "post" };
  }
  if (matchPath({ path: "/games", end: true }, pathname)) {
    return { key: "create-game", label: "创建桌游室", groupId: null, plannedStep: "F7", handler: "game" };
  }
  return null;
}
