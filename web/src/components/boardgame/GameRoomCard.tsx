/**
 * GameRoomCard —— 桌游室卡片（design.md §12.11，R-B1）。
 *
 * 2 列网格：封面占位图（--ice-100 底 + 游戏线性图标）+ 房间名 + 状态 tag
 * （等待中 --ice-300 底 / 对局中 --sakura-300 底）+ 人数 + 来源标识。
 * 点击进入房间（onEnter，父级 navigate 到占位界面）。
 */
import type { CSSProperties } from "react";
import type { GameRoom } from "../../api/types";
import { FavoriteButton } from "../FavoriteButton";
import { ScrollingText } from "../ScrollingText";
import { ScrollingTags } from "../ScrollingTags";
import { IconGame } from "../icons";
import { getVisibilityLabels } from "../../utils/visibility";

export function GameRoomCard({
  room,
  onEnter,
  revealDelay,
}: {
  room: GameRoom;
  onEnter: () => void;
  /** 逐条浮入延迟（ms）；undefined 则不挂 reveal-item（A2 扩展至桌游列表） */
  revealDelay?: number;
}) {
  const playing = room.status === "playing";
  const labels = getVisibilityLabels(room);
  return (
    <div
      className={`game-room-card-wrap${revealDelay != null ? " reveal-item" : ""}`}
      style={revealDelay != null ? ({ ["--reveal-delay" as string]: `${revealDelay}ms` } as CSSProperties) : undefined}
    >
      <button type="button" className="game-room-card" onClick={onEnter}>
        <div className="game-room-cover">
          <IconGame width={48} height={48} />
        </div>
        <div className="game-room-info">
          <ScrollingText text={room.name} className="game-room-name" />
          <span className={`game-room-status ${playing ? "is-playing" : "is-waiting"}`}>
            {room.status === "playing" ? "对局中" : room.status === "ended" ? "已结束" : "等待中"}
          </span>
          <span className="game-room-meta">
            <span className="game-room-count">{room.member_count} 人</span>
            <ScrollingTags labels={labels} tagClassName="game-room-source" className="game-room-source-tags" />
          </span>
        </div>
      </button>
      <FavoriteButton targetType="game" targetId={room.id} compact />
    </div>
  );
}
