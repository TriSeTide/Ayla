/**
 * 群"新内容"工具 —— 主页群卡片 / 群列表 / 宽屏服务器栏共用。
 *
 * 语义（用户多轮纠正后定稿）：
 * - 排序按"新内容"（事件性），不是"有内容"（存在性）：近期发生过新事件才排前；
 * - "新消息"不依赖已读（unread）：窗口内最新消息（含自己发的）即算，读了不掉下去；
 * - 事件种类：新消息、新开播、新语音房被创建、新桌游房被创建、新帖子。
 * - 列表布局显示最近事件的**具体描述**（替代"新内容"三字）：
 *   xx：消息内容 / xx 开播了 标题 / xx 创建了语音房 房名 /
 *   xx 创建了桌游房 房名 / xx 发了新帖 标题。
 *
 * WS 实时：live/voice/boardgame/posts 四 store 由 ChatWS 事件维护 + 登录预加载，
 * store 变化 → 订阅组件重渲染 → 排序/事件描述即时刷新。
 */
import { useBoardgameStore } from "../../stores/boardgame";
import { useLiveStore } from "../../stores/live";
import { usePostsStore } from "../../stores/posts";
import { useVoiceStore } from "../../stores/voice";
import { SHOW_GAME_STATUS } from "./badges";

/** "新"的时间窗口：窗口内的事件才视为"新内容"（可调） */
export const NEW_CONTENT_WINDOW_MS = 24 * 60 * 60 * 1000; // 24 小时

/** 事件种类 */
export type NewEventKind = "message" | "live" | "voice" | "game" | "post";

/** 一条"新内容"事件（列表预览展示用） */
export interface NewEvent {
  kind: NewEventKind;
  /** 事件时间（毫秒） */
  at: number;
  /** 展示文本，如「小樱：今晚一起吃饭吗」「阿蓝 开播了 直播间1」 */
  text: string;
}

/** 群内当前存在的直播/语音/桌游（角标语义，存在性，与排序无关） */
export interface GroupPresence {
  /** 群内有直播在播（status=live） */
  live: boolean;
  /** 群内有语音房 */
  voice: boolean;
  /** 群内有桌游房 */
  game: boolean;
}

/** 群"新内容"聚合结果（排序 + 列表标识） */
export interface GroupActivity {
  /** 最近一次"新内容"事件时间（毫秒）；无则为 0 */
  lastNewAt: number;
  /** 最近一条事件（展示用）；无则为 null */
  lastEvent: NewEvent | null;
}

const NO_ACTIVITY: GroupActivity = { lastNewAt: 0, lastEvent: null };

/** 解析后端 ISO 时间戳为毫秒（无效返回 0） */
function toMs(iso: string | null | undefined): number {
  if (!iso) return 0;
  const t = new Date(iso).getTime();
  return Number.isFinite(t) ? t : 0;
}

/** 是否在"新"窗口内（不早于 now-window 且不晚于 now+1min 时钟容差） */
function isRecent(ms: number, now: number): boolean {
  if (ms <= 0) return false;
  return ms > now - NEW_CONTENT_WINDOW_MS && ms < now + 60_000;
}

/** 内容对本群可见：群归属等于本群，或白名单 allowed_group_ids 含本群 */
function visibleInGroup(
  groupKey: string | null,
  groupId: string,
  allowed: string[] | undefined,
): boolean {
  return (
    String(groupKey) === String(groupId) ||
    (allowed ?? []).some((id) => String(id) === String(groupId))
  );
}

/** 取两个人名中可显示的一个 */
function displayName(nickname?: string | null, username?: string | null): string {
  return nickname || username || "";
}

/** 非文本消息类型 → 活跃度摘要占位（与会话列表 TYPE_PLACEHOLDER 一致） */
const MEDIA_EVENT_PLACEHOLDER: Record<string, string> = {
  image: "[图片]",
  voice: "[语音]",
  file: "[文件]",
  emoji: "[表情]",
  video: "[视频]",
  system: "[系统消息]",
};

/** 消息事件（最后一条消息，含自己的；不依赖已读） */
function messageEvent(
  lastMessage: { sender_name?: string; content?: string; type?: string; created_at?: string | null } | null | undefined,
  now: number,
): NewEvent | null {
  if (!lastMessage || !lastMessage.created_at) return null;
  const at = toMs(lastMessage.created_at);
  if (!isRecent(at, now)) return null;
  const who = lastMessage.sender_name || "";
  // 媒体消息 content 为空串（气泡不携带占位文案）→ 按类型显示占位
  const content = lastMessage.content
    || MEDIA_EVENT_PLACEHOLDER[lastMessage.type ?? ""] || "";
  return { kind: "message", at, text: `${who}：${content}` };
}

/**
 * 订阅 live/voice/boardgame store，返回 (groupId) => GroupPresence（角标/存在性）。
 */
export function useGroupPresenceMap(): (groupId: string) => GroupPresence {
  const liveChannels = useLiveStore((s) => s.channels);
  const voiceChannels = useVoiceStore((s) => s.channels);
  const gameRooms = useBoardgameStore((s) => s.rooms);

  return (groupId) => {
    let live = false;
    let voice = false;
    let game = false;
    for (const c of liveChannels) {
      if (c.status === "live" && visibleInGroup(c.group, groupId, c.allowed_group_ids)) {
        live = true;
        break;
      }
    }
    // 语音重点 =「有人」在语音房（member_count > 0），不是「有语音房」
    for (const c of voiceChannels) {
      if (
        visibleInGroup(c.group, groupId, c.allowed_group_ids) &&
        Number(c.member_count) > 0
      ) {
        voice = true;
        break;
      }
    }
    for (const r of gameRooms) {
      if (visibleInGroup(r.group, groupId, r.allowed_group_ids)) {
        game = true;
        break;
      }
    }
    return { live, voice, game };
  };
}

/**
 * 订阅 live/voice/boardgame/posts store，返回
 * (groupId, lastMessage?) => GroupActivity（含消息事件合并）。
 * 四 store 被 WS 实时更新，订阅保证调用方随变化重渲染。
 */
export function useGroupActivityMap(): (
  groupId: string,
  lastMessage?: { sender_name?: string; content?: string; type?: string; created_at?: string | null } | null,
) => GroupActivity {
  const liveChannels = useLiveStore((s) => s.channels);
  const voiceChannels = useVoiceStore((s) => s.channels);
  const gameRooms = useBoardgameStore((s) => s.rooms);
  const posts = usePostsStore((s) => s.posts);

  return (groupId, lastMessage) => {
    const now = Date.now();
    let best: NewEvent | null = messageEvent(lastMessage, now);

    // 新开播：直播 status=live 且 started_at 在窗口内
    for (const c of liveChannels) {
      if (c.status === "live" && visibleInGroup(c.group, groupId, c.allowed_group_ids)) {
        const at = toMs(c.started_at);
        if (isRecent(at, now) && (!best || at > best.at)) {
          const host = c.owner_nickname || "";
          best = { kind: "live", at, text: `${host} 开播了 ${c.title}` };
        }
      }
    }
    // 新语音房被创建：created_at 在窗口内
    for (const c of voiceChannels) {
      if (visibleInGroup(c.group, groupId, c.allowed_group_ids)) {
        const at = toMs(c.created_at);
        if (isRecent(at, now) && (!best || at > best.at)) {
          const owner = c.owner_nickname || "";
          // 显示用户填的频道名 name（room_name 是 LiveKit 内部名，如 room_fd18...）
          best = { kind: "voice", at, text: `${owner} 创建了语音房 ${c.name || c.room_name}` };
        }
      }
    }
    // 新桌游房被创建：created_at 在窗口内
    for (const r of gameRooms) {
      if (visibleInGroup(r.group, groupId, r.allowed_group_ids)) {
        const at = toMs(r.created_at);
        if (isRecent(at, now) && (!best || at > best.at)) {
          const owner = displayName(r.owner?.nickname, r.owner?.username);
          best = { kind: "game", at, text: `${owner} 创建了桌游房 ${r.name}` };
        }
      }
    }
    // 新帖子：created_at 在窗口内且白名单含本群
    for (const p of posts) {
      if (visibleInGroup(p.group, groupId, p.allowed_group_ids)) {
        const at = toMs(p.created_at);
        if (isRecent(at, now) && (!best || at > best.at)) {
          const author = displayName(p.author?.nickname, p.author?.username);
          best = { kind: "post", at, text: `${author} 发了新帖 ${p.title}` };
        }
      }
    }

    if (!best) return NO_ACTIVITY;
    return { lastNewAt: best.at, lastEvent: best };
  };
}

/** 群是否有"新内容"（窗口内有任一事件） */
export function hasGroupActivity(activity: GroupActivity): boolean {
  return activity.lastNewAt > 0;
}

/**
 * 群排序：置顶优先 → 有新内容排前（组内按最近事件时间新→旧）→
 * 无新内容保持传入顺序（稳定）。
 */
export function sortGroupsByActivity<T extends { id: string; is_pinned?: boolean }>(
  list: T[],
  keyOf: (item: T) => GroupActivity,
): T[] {
  return list
    .map((item, index) => {
      const activity = keyOf(item);
      return {
        item,
        index,
        pinned: item.is_pinned ?? false,
        ts: activity.lastNewAt,
      };
    })
    .sort((a, b) => {
      if (a.pinned !== b.pinned) return Number(b.pinned) - Number(a.pinned);
      // 置顶组内部也按新内容时间排（时间新→旧），无新内容保持稳定
      if (a.ts !== b.ts) return b.ts - a.ts;
      return a.index - b.index;
    })
    .map((x) => x.item);
}

/* ================= 群卡片状态轮播（窄屏卡片布局，需求 R-H5 扩展） ================= */

/** 语音房轮播条目：单个「有人」语音房（房间名 + 人数） */
export interface CarouselVoiceRoom {
  name: string;
  memberCount: number;
}

/** 轮播卡片：消息+语音合卡 / 直播卡（每直播间一张）/ 帖子卡（最新一帖一张）/ 桌游卡（开关关闭） */
export type GroupCarouselSlide =
  | { kind: "message-voice"; newMessageCount: number; voiceRooms: CarouselVoiceRoom[] }
  | { kind: "live"; host: string; title: string; cover: string | null }
  | { kind: "post"; title: string; body: string; image: string | null }
  | { kind: "game"; name: string; memberCount: number; cover: string | null };

/** 语音房轮播最多展示的房间数（超出按人数降序截断） */
export const MAX_VOICE_ROOMS = 3;

/**
 * 订阅 live/voice/boardgame/posts store，返回
 * (groupId, unreadCount) => GroupCarouselSlide[]（群卡片状态轮播数据）。
 *
 * 语义：
 * - 消息+语音合卡：新消息=未读数（读了清零，与排序的"有新内容"是两套逻辑）；
 *   语音=该群每个「有人」语音房一行「N人在{房间名}连麦」（人数降序，最多 3 个）；
 *   两者至少其一才生成该卡。
 * - 直播卡：每个 status=live 且对本群可见的直播间一张（封面 + 主播 + 标题）。
 * - 帖子卡：窗口内（24h）最新一帖一张（含正文，图片上描边显示；"没看"以窗口内新帖近似）。
 * - 桌游卡：SHOW_GAME_STATUS 开关强制关闭（是否有人在玩判断未实现，保留实现）。
 * 四 store 由 ChatWS 实时维护（voice member_count / live.updated / post.updated /
 * boardgame.updated 均实时推送），订阅保证调用方随变化重渲染。
 */
export function useGroupCarouselSlides(): (
  groupId: string,
  unreadCount: number,
) => GroupCarouselSlide[] {
  const liveChannels = useLiveStore((s) => s.channels);
  const voiceChannels = useVoiceStore((s) => s.channels);
  const gameRooms = useBoardgameStore((s) => s.rooms);
  const posts = usePostsStore((s) => s.posts);

  return (groupId, unreadCount) => {
    const slides: GroupCarouselSlide[] = [];

    // 1. 消息 + 语音合卡：语音按「有人」房间逐行（每房间一行，最多 3 个，人数降序）
    const voiceRooms: CarouselVoiceRoom[] = [];
    for (const c of voiceChannels) {
      if (
        visibleInGroup(c.group, groupId, c.allowed_group_ids) &&
        Number(c.member_count) > 0
      ) {
        voiceRooms.push({
          name: c.name || c.room_name || "",
          memberCount: Number(c.member_count),
        });
      }
    }
    voiceRooms.sort((a, b) => b.memberCount - a.memberCount);
    const topRooms = voiceRooms.slice(0, MAX_VOICE_ROOMS);
    const newCount = Math.max(0, unreadCount ?? 0);
    if (newCount > 0 || topRooms.length > 0) {
      slides.push({
        kind: "message-voice",
        newMessageCount: newCount,
        voiceRooms: topRooms,
      });
    }

    // 2. 直播卡：每个正在直播的直播间一张
    for (const c of liveChannels) {
      if (c.status === "live" && visibleInGroup(c.group, groupId, c.allowed_group_ids)) {
        slides.push({
          kind: "live",
          host: c.owner_nickname || "",
          title: c.title,
          cover: c.cover || null,
        });
      }
    }

    // 3. 帖子卡：窗口内最新一帖一张（含正文，供图片上描边显示）
    const now = Date.now();
    let latest: { at: number; title: string; body: string; image: string | null } | null = null;
    for (const p of posts) {
      if (!visibleInGroup(p.group, groupId, p.allowed_group_ids)) continue;
      const at = toMs(p.created_at);
      if (!isRecent(at, now)) continue;
      if (!latest || at > latest.at) {
        const img = p.images.find((i) => i.media?.thumbnail);
        latest = {
          at,
          title: p.title,
          body: p.body,
          image: img?.media?.thumbnail ?? null,
        };
      }
    }
    if (latest) {
      slides.push({
        kind: "post",
        title: latest.title,
        body: latest.body,
        image: latest.image,
      });
    }

    // 4. 桌游卡：开关强制关闭（保留实现，实现"是否有人在玩"判断后置 true）
    if (SHOW_GAME_STATUS) {
      for (const r of gameRooms) {
        if (
          visibleInGroup(r.group, groupId, r.allowed_group_ids) &&
          r.status === "playing"
        ) {
          slides.push({
            kind: "game",
            name: r.name,
            memberCount: Number(r.member_count),
            cover: null,
          });
        }
      }
    }

    return slides;
  };
}