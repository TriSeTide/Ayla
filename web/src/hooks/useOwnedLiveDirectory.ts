import { useCallback, useEffect, useRef, useState } from "react";
import { listLiveChannelsPage } from "../api/live";
import { useAuthStore } from "../stores/auth";
import { useLiveStore } from "../stores/live";
import { chatWS } from "../ws/chat";
import { sortLiveChannels } from "../utils/sortChannels";
import { usePagedMediaList } from "./usePagedMediaList";

/** Owner filtering happens before pagination; the global catalog is only an update hint. */
export function useOwnedLiveDirectory() {
  const owner = useAuthStore((state) => state.currentUser?.id ?? "");
  const source = useLiveStore((state) => state.channels);
  const eventRevision = useRef(0);
  const fetchPage = useCallback(async (cursor: string | null) => {
    const revision = eventRevision.current;
    const page = await listLiveChannelsPage({ owner, limit: 20, cursor });
    if (eventRevision.current !== revision) throw new Error("直播列表已更新，请刷新后继续");
    return page;
  }, [owner]);
  const list = usePagedMediaList(`owned-live:${owner}`, fetchPage, Boolean(owner));
  const [invalidated, setInvalidated] = useState(false);
  const { updateItems } = list;
  useEffect(() => { setInvalidated(false); }, [owner]);

  useEffect(() => {
    const byId = new Map(source.filter((item) => item.owner_id === owner).map((item) => [item.id, item]));
    updateItems((items) => {
      if (!items.some((item) => byId.has(item.id) && byId.get(item.id) !== item)) return items;
      return sortLiveChannels(items.map((item) => byId.get(item.id) ?? item));
    });
  }, [source, owner, updateItems]);

  useEffect(() => chatWS.onFrame((frame) => {
    if (!frame.type.startsWith("live.channel.")) return;
    // A live cursor orders activity timestamps; a changed catalog must be refreshed
    // before continuing. Loaded cards remain visible while the refresh is pending.
    eventRevision.current += 1;
    if (frame.type === "live.channel.deleted") updateItems((items) => items.filter((item) => item.id !== frame.data.channel_id));
    setInvalidated(true);
  }), [owner, updateItems]);

  const refreshPage = useCallback(async () => {
    const revision = eventRevision.current;
    const page = await list.refreshPage();
    if (page && eventRevision.current === revision) setInvalidated(false);
    return page;
  }, [list.refreshPage]);
  const refresh = useCallback(async () => { await refreshPage(); }, [refreshPage]);
  const invalidate = useCallback(() => { eventRevision.current += 1; setInvalidated(true); }, []);
  return { ...list, invalidated, refresh, refreshPage, invalidate };
}
