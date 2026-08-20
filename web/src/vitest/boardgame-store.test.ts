import { describe, expect, it, beforeEach } from "vitest";
import type { GameRoom } from "../api/types";
import { useBoardgameStore } from "../stores/boardgame";

const room = (id: number): GameRoom => ({
  id, name: `房间${id}`, owner: {} as GameRoom["owner"], owner_id: "u",
  visibility: "public", group: null, group_name: null, game_type: "boardgame",
  status: "waiting", members: [], member_count: 0, is_owner: false,
  is_member: false, created_at: "2026-01-01T00:00:00Z",
});

describe("boardgame store realtime reconciliation", () => {
  beforeEach(() => useBoardgameStore.getState().reset());

  it("upsert is idempotent and does not duplicate a room", () => {
    const store = useBoardgameStore.getState();
    store.upsertRoom(room(1));
    store.upsertRoom(room(1));
    expect(useBoardgameStore.getState().rooms).toHaveLength(1);
  });

  it("REST reconciliation removes deleted or no-longer-visible rooms", () => {
    const store = useBoardgameStore.getState();
    store.setRooms([room(1), room(2)]);
    store.reconcileRooms([room(2)]);
    expect(useBoardgameStore.getState().rooms.map((r) => r.id)).toEqual([2]);
  });
});
