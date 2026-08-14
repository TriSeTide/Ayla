/**
 * usePostDetailTransition —— 帖子详情转场（窄屏，R-P3）独立封装。
 *
 * 语义（开发文档 §2.2 动画方向纪律）：帖子详情 = 底栏**原位替换**为评论输入框
 * （交叉淡化 200ms，**无位移**）——既不是进群（底栏上移）也不是进房（底栏下滑走），
 * 不得与那两个动画共用。
 *
 * 返回 entered：评论输入框淡入标志；壳层底栏由 AppShell 在帖子详情窄屏路由下
 * 原位让位（不渲染 BottomTabs，交叉淡化由 CSS opacity 过渡承载）。
 */
import { useEffect, useState } from "react";

export function usePostDetailTransition() {
  const [entered, setEntered] = useState(false);

  useEffect(() => {
    if (
      typeof window.matchMedia === "function" &&
      window.matchMedia("(prefers-reduced-motion: reduce)").matches
    ) {
      setEntered(true);
      return;
    }
    const raf = requestAnimationFrame(() => setEntered(true));
    return () => cancelAnimationFrame(raf);
  }, []);

  return { entered };
}
