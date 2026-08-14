/**
 * BottomTabs —— 窄屏底部五 tab（design.md §12.1）。
 *
 * 玻璃 64px + safe-area；五等分：语音 / 直播 / 主页（居中凸起）/ 帖子 / 桌游。
 * 主页 tab：圆形背板 48px 上浮 8px（底 --surface），选中时附 --glow-shadow
 * （全屏主 CTA 级辉光之一，≤3 处纪律）；未读徽标 --pink-500 实底白字。
 * badges prop 为 F8 全站未读聚合预留（F1 恒空）。
 */
import { Link } from "react-router-dom";
import type { CSSProperties, SVGProps } from "react";
import { IconGame, IconHome, IconMic, IconPost, IconVideo } from "../components/icons";
import type { ModuleKey } from "./shellConfig";
import { PRIMARY_MODULES } from "./shellConfig";

/** 视觉顺序：主页居中（需求文档 §3.1） */
const TAB_ORDER: ModuleKey[] = ["voice", "live", "home", "posts", "games"];

const TAB_ICONS: Record<ModuleKey, (p: SVGProps<SVGSVGElement>) => JSX.Element> = {
  voice: IconMic,
  live: IconVideo,
  home: IconHome,
  posts: IconPost,
  games: IconGame,
};

function formatBadge(count: number): string {
  return count > 99 ? "99+" : String(count);
}

export function BottomTabs({
  moduleKey,
  badges = {},
  style,
  dataFixed = false,
}: {
  /** 当前一级模块（resolveModule 输出），决定选中态 */
  moduleKey: ModuleKey | null;
  /** 各 tab 未读数（F8 接线；F1 恒空） */
  badges?: Partial<Record<ModuleKey, number>>;
  /** 进房动画（F4）：底栏下滑走 transform + transition 由 AppShell 注入 */
  style?: CSSProperties;
  /** 直播间窄屏：脱离 flex 流（fixed），下滑走后内容区全高（沉浸视频，F4） */
  dataFixed?: boolean;
}) {
  return (
    <nav
      className="bottom-tabs"
      aria-label="主导航"
      style={style}
      data-fixed={dataFixed ? "true" : undefined}
    >
      <ul className="bottom-tabs-list">
        {TAB_ORDER.map((key) => {
          const meta = PRIMARY_MODULES.find((m) => m.key === key)!;
          const Icon = TAB_ICONS[key];
          const active = moduleKey === key;
          const count = badges[key] ?? 0;
          return (
            <li key={key} className={`bottom-tab ${key === "home" ? "bottom-tab-home" : ""}`}>
              <Link
                to={meta.path}
                className={`bottom-tab-link ${active ? "is-active" : ""}`}
                aria-current={active ? "page" : undefined}
              >
                {key === "home" ? (
                  <span className="bottom-tab-home-disc">
                    <Icon width={24} height={24} />
                  </span>
                ) : (
                  <span className="bottom-tab-icon">
                    <Icon width={24} height={24} />
                    {count > 0 && (
                      <span className="tab-badge" aria-label={`${count} 条未读`}>
                        {formatBadge(count)}
                      </span>
                    )}
                  </span>
                )}
                <span className="bottom-tab-label">{meta.label}</span>
              </Link>
            </li>
          );
        })}
      </ul>
    </nav>
  );
}
