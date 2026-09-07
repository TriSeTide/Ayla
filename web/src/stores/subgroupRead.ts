/** 群聊已读回执统一应用：REST/WS 重复确认仅按明确序号消除，不清空整个子群。 */
import { useChatStore } from "./chat";
import { useMessageStore } from "./message";
import { useSubGroupStore } from "./subgroup";

export function applySubgroupReadReceipt(convId: string, subgroupId: string, markedSeqs: number[]): void {
  const confirmed = markedSeqs.filter((seq) => Number.isSafeInteger(seq) && seq > 0);
  if (confirmed.length === 0) return;
  const removed = useSubGroupStore.getState().markSubgroupReadSeqs(convId, subgroupId, confirmed);
  const conversation = useChatStore.getState().conversations.find((item) => item.id === convId);
  if (conversation?.unread_seqs != null) {
    useChatStore.getState().markReadSeqs(convId, confirmed);
  } else if (removed > 0) {
    // 旧会话响应缺少序号时只减去已知确实移除的未读，禁止将未知剩余量归零。
    useChatStore.getState().decrementUnread(convId, removed, confirmed);
  }
  const read = new Set(confirmed);
  for (const message of useMessageStore.getState().buckets[convId]?.messages ?? []) {
    if (read.has(message.seq)) useMessageStore.getState().markReadByMe(convId, message.id);
  }
}
