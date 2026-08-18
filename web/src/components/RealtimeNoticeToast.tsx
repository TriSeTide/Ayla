import { useEffect } from "react";
import { useNoticeStore } from "../stores/notices";

export function RealtimeNoticeToast() {
  const notices = useNoticeStore((state) => state.notices);
  const dismiss = useNoticeStore((state) => state.dismiss);

  useEffect(() => {
    const timers = notices.map((notice) => window.setTimeout(() => dismiss(notice.id), 7000));
    return () => timers.forEach((timer) => window.clearTimeout(timer));
  }, [notices, dismiss]);

  if (notices.length === 0) return null;
  return (
    <div className="realtime-notice-stack" aria-live="polite">
      {notices.map((notice) => (
        <div className="realtime-notice" key={notice.id} role="status">
          <div className="realtime-notice-copy">
            <strong>{notice.title}</strong>
            <span>{notice.detail}</span>
          </div>
          <button type="button" className="realtime-notice-close" aria-label="关闭通知" onClick={() => dismiss(notice.id)}>×</button>
        </div>
      ))}
    </div>
  );
}
