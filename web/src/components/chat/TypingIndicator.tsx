/**
 * TypingIndicator —— 对方正在输入。
 */
export function TypingIndicator({ typing }: { typing: boolean }) {
  if (!typing) return null;
  return (
    <div className="typing-indicator" role="status">
      <span className="typing-dots">
        <i />
        <i />
        <i />
      </span>
      <span>对方正在输入…</span>
    </div>
  );
}
