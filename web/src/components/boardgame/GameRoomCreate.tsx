/**
 * GameRoomCreate —— 创建桌游室（R-F3：房间名必填）。group 归属由调用方传入。
 */
import { useState } from "react";
import * as boardgameApi from "../../api/boardgame";
import type { GameRoom } from "../../api/types";

export function GameRoomCreate({
  group,
  onCreated,
}: {
  group?: string | null;
  onCreated: (room: GameRoom) => void;
}) {
  const [name, setName] = useState("");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const submit = async () => {
    const trimmed = name.trim();
    if (!trimmed) {
      setError("房间名不能为空");
      return;
    }
    setBusy(true);
    setError(null);
    try {
      const room = await boardgameApi.createGameRoom({ name: trimmed, group });
      setName("");
      onCreated(room);
    } catch (e) {
      setError(e instanceof Error ? e.message : "创建失败");
    } finally {
      setBusy(false);
    }
  };

  return (
    <div className="game-room-create">
      <input
        className="field"
        placeholder="桌游室名称"
        value={name}
        maxLength={64}
        onChange={(e) => setName(e.target.value)}
        onKeyDown={(e) => {
          if (e.key === "Enter") void submit();
        }}
      />
      {error && <p className="post-editor-error">{error}</p>}
      <button
        type="button"
        className="btn btn-primary"
        disabled={busy || !name.trim()}
        onClick={() => void submit()}
      >
        {busy ? "创建中…" : "创建"}
      </button>
    </div>
  );
}
