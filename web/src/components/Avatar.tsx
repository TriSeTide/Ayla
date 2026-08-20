/**
 * Avatar —— 签名元素「在线光环 Presence Halo」（design.md §6）。
 *
 * - 在线：2.5px 锥形渐变环（--ring-online）；
 * - 爱莉：光环额外带 3.2s 呼吸辉光（唯一常驻动画，prefers-reduced-motion 降级）；
 * - 离线：褪为 --ice-100 灰环；
 * - 色彩不作唯一信息载体：在线状态由调用方同时给文字标签（design.md §10）。
 *
 * 可点击：传入 onClick 时渲染为可交互按钮（用于"所有头像可点进个人主页"），
 * 加 role="button"/aria-label 保证可访问性（design.md §10 可点目标 ≥44px）。
 */
import type { CSSProperties, MouseEventHandler } from "react";
import { ResourceImage } from "./ResourceImage";

export function Avatar({
  label,
  size = 40,
  online = false,
  isElysia = false,
  imageUrl,
  style,
  onClick,
  ariaLabel,
}: {
  /** 首字符/缩写（无头像图时展示） */
  label?: string;
  size?: number;
  online?: boolean;
  /** 爱莉专属光环（呼吸辉光），不可复用于普通用户（design.md §8 Don't） */
  isElysia?: boolean;
  imageUrl?: string | null;
  style?: CSSProperties;
  /** 可点击：跳转个人主页等（"所有头像都能点进个人页面"） */
  onClick?: MouseEventHandler<HTMLElement>;
  ariaLabel?: string;
}) {
  const safeLabel = label?.trim() || "?";
  const fontSize = Math.round(size * 0.42);
  const haloStyle = { width: size + 5, height: size + 5, ...style } as CSSProperties;
  const inner = (
    <>
      <span
        className={`avatar-core ${isElysia ? "avatar-core-elysia" : "avatar-core-user"}`}
        style={{ fontSize }}
      >
        {imageUrl ? (
          <ResourceImage
            src={imageUrl}
            alt=""
            width={size}
            height={size}
            style={{ objectFit: "cover" }}
            fallback={safeLabel.slice(0, 1)}
          />
        ) : (
          safeLabel.slice(0, 1)
        )}
      </span>
    </>
  );

  if (onClick) {
    return (
      <button
        type="button"
        className={`avatar-halo avatar-halo-btn ${online ? "" : "is-offline"} ${isElysia && online ? "is-elysia" : ""}`}
        style={haloStyle}
        onClick={onClick}
        aria-label={ariaLabel ?? `${safeLabel} 个人主页`}
        title={ariaLabel ?? safeLabel}
      >
        {inner}
      </button>
    );
  }

  return (
    <span
      className={`avatar-halo ${online ? "" : "is-offline"} ${isElysia && online ? "is-elysia" : ""}`}
      style={haloStyle}
      aria-hidden="true"
    >
      {inner}
    </span>
  );
}