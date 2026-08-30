/**
 * boardgame 全局状态（S4 桌游域）。
 *
 * - rooms：房间列表（可见性过滤 + 可选我在局）；
 * - 实时更新：WS 推送 boardgame.room.created/deleted 自动同步列表；
 * - 新房间插入到列表头部。
 */
import { create } from "zustand";
import type { GameRoom } from "../api/types";

interface BoardgameState {
  rooms: GameRoom[];
  roomsLoading: boolean;
  error: string | null;
  lastFetched: number | null;

  setRooms: (list: GameRoom[]) => void;
  setRoomsLoading: (loading: boolean) => void;
  setError: (err: string | null) => void;
  /** WS 推送：插入或更新房间（新房间在列表头部） */
  upsertRoom: (room: GameRoom) => void;
  /** REST 对账：仅接受当前可见列表，避免 WS 越权插入。 */
  reconcileRooms: (list: GameRoom[]) => void;
  /** WS 推送：从列表移除 */
  removeRoom: (roomId: number) => void;

  reset: () => void;
}

const INITIAL = {
  rooms: [] as GameRoom[],
  roomsLoading: false,
  error: null as string | null,
  lastFetched: null as number | null,
};

function normalizeRoom(room: GameRoom): GameRoom {
  return {
    ...room,
    id: Number(room.id),
    owner_id: String(room.owner_id),
    group: room.group == null ? null : String(room.group),
  };
}

export const useBoardgameStore = create<BoardgameState>((set) => ({
  ...INITIAL,

  setRooms: (rooms) =>
    set({
      rooms: rooms.map(normalizeRoom).sort((a, b) => b.created_at.localeCompare(a.created_at)),
      roomsLoading: false,
      error: null,
      lastFetched: Date.now(),
    }),

  setRoomsLoading: (roomsLoading) => set({ roomsLoading }),

  reconcileRooms: (rooms) =>
    set(() => {
      const normalized = rooms
        .map(normalizeRoom)
        .sort((a, b) => b.created_at.localeCompare(a.created_at));
      return {
        rooms: normalized,
        roomsLoading: false,
        error: null,
        lastFetched: Date.now(),
      };
    }),

  setError: (error) => set({ error }),

  upsertRoom: (room) =>
    set((state) => {
      const normalized = normalizeRoom(room);
      const idx = state.rooms.findIndex((r) => r.id === normalized.id);
      // 已存在则更新，否则插入到头部
      const rooms =
        idx >= 0
          ? state.rooms.map((r) => (r.id === normalized.id ? normalized : r))
          : [normalized, ...state.rooms];
      return { rooms };
    }),

  removeRoom: (roomId) =>
    set((state) => ({
      rooms: state.rooms.filter((r) => r.id !== roomId),
    })),

  reset: () => set({ ...INITIAL }),
}));

/** 判断 boardgame store 数据是否过期（默认 60 秒） */
export function isBoardgameStale(maxAgeMs = 60_000): boolean {
  const { lastFetched } = useBoardgameStore.getState();
  if (!lastFetched) return true;
  return Date.now() - lastFetched > maxAgeMs;
}
