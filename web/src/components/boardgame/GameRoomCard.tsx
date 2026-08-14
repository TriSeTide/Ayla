/**
 * GameRoomCard —— 桌游室卡片（design.md §12.11，R-B1）。
 *
 * 2 列网格：封面占位图（--ice-100 底 + 游戏线性图标）+ 房间名 + 状态 tag
 * （等待中 --ice-300 底 / 对局中 --sakura-300 底）+ 人数 + 来源标识。
 * 点击进入房间（onEnter，父级 navigate 到占位界面）。
 */
import type { GameRoom } from "../../api/types";
import { IconGame } from "../icons";

function sourceLabel(room: GameRoom): string {
  if (room.visibility === "group" && room.group_name) return room.group_name;
  if (room.visibility === "friends") return "好友";
  return "公开";
}

export function GameRoomCard({ room, onEnter }: { room: GameRoom; onEnter: () => void }) {
  const playing = room.status === "playing";
  return (
    <button type="button" className="game-room-card" onClick={onEnter}>
      <div className="game-room-cover">
        <IconGame width={48} height={48} />
      </div>
      <div className="game-room-info">
        <span className="game-room-name">{room.name}</span>
        <span className={`game-room-status ${playing ? "is-playing" : "is-waiting"}`}>
          {room.status === "playing" ? "对局中" : room.status === "ended" ? "已结束" : "等待中"}
        </span>
        <span className="game-room-meta">
          {room.member_count} 人
          <span className="game-room-source">{sourceLabel(room)}</span>
        </span>
      </div>
    </button>
  );
}
