/**
 * LiveViewerStrip —— 直播间视频下方的「在看观众条」（需求）。
 *
 * 一排圆形：[人数（小人图标 + 数字）][头像][头像]…[三个点]，整排是一个按钮，
 * 点击任意位置打开在看名单弹层（宽屏居中 / 窄屏 60% 上滑，见 LiveViewerSheet）。
 *
 * **高度恒占位（禁止跳变）**：本组件从第一帧起就渲染在布局里，未知时也不塌陷——
 * 宽屏主区的播放器按容器高度定尺寸（`100cqh`），如果这一排晚一步才出现，播放器会
 * 先按"没有它"的高度算好、数据到达再被挤一次，画面出现一次缩放跳变。因此：
 * - 已知人数 → 正常展示；`count === 0` 是真实读数，照常显示 `0`；
 * - 未知（`count === null`：presence 存储不可用 / 尚未读到）→ 人数位显示 `–`，
 *   不写 0 冒充"没人看"，也不先占位后又消失；
 * - 入场由 `LiveRoomBody` 的分区动画统一负责（video 与这一排同从下方 20px 滑入，
 *   transform 不改变布局高度，画面不会被挤）。本组件不自带入场动画，避免两个 owner。
 *
 * 纯展示：人数与预览由调用方给出（`liveSessionRuntime` 的进房快照 + 弹幕 WS 的
 * `viewers` 帧写进 live store）。本组件不自取数据——进房快照必须晚于频道描述符
 * 落地才写 store（`setViewers` 只认当前直播间），放在这里会和进房时序赛跑。
 */
import { useState } from "react";
import type { LiveViewerItem } from "../../api/types";
import { Avatar } from "../Avatar";
import { IconDots, IconUsers } from "../icons";
import { LiveViewerSheet } from "./LiveViewerSheet";

/** 头像条最多渲染几位（与后端 WS 预览上限一致；完整名单在弹层里） */
const MAX_PREVIEW = 12;

export function LiveViewerStrip({
  channelId,
  count,
  viewers,
  className,
}: {
  channelId: number;
  /** 当前在看人数；null = 未知（人数位显示 `–`，不冒充 0） */
  count: number | null;
  /** 预览名单（最近活跃优先） */
  viewers: LiveViewerItem[];
  /** 追加类名（窄屏与宽屏的落位不同，材料一致） */
  className?: string;
}) {
  const [open, setOpen] = useState(false);
  const known = count !== null;
  const shown = viewers.slice(0, MAX_PREVIEW);

  return (
    <>
      <button
        type="button"
        className={`live-viewer-strip${known ? "" : " is-unknown"}${className ? ` ${className}` : ""}`}
        onClick={() => setOpen(true)}
        aria-label={known ? `正在观看 ${count} 人，查看完整名单` : "正在观看人数未知，查看名单"}
        title={known ? "查看正在观看的人" : "正在读取在看人数"}
      >
        <span className="live-viewer-strip-count">
          <IconUsers width={14} height={14} aria-hidden="true" />
          <span className="live-viewer-strip-num">{known ? count : "–"}</span>
        </span>
        <span className="live-viewer-strip-avatars">
          {shown.map((viewer) => (
            <Avatar
              key={viewer.user_id}
              label={viewer.nickname}
              size={26}
              online
              imageUrl={viewer.avatar || null}
            />
          ))}
        </span>
        {/* 经典「更多」三圆点：排尾固定可见（中间头像区放不下先裁头像） */}
        <span className="live-viewer-strip-more" aria-hidden="true">
          <IconDots width={14} height={14} />
        </span>
      </button>
      {open && (
        <LiveViewerSheet
          channelId={channelId}
          preview={viewers}
          onClose={() => setOpen(false)}
        />
      )}
    </>
  );
}
