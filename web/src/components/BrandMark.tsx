/**
 * Ayla 图形标识（mark-5 body）。
 *
 * 事实源：`design/brand/logo-max.svg`（1390.6 最大裁剪、透明底、直角方图），
 * web 副本在 `web/public/brand/logo-max.svg`，构建后即 `/brand/logo-max.svg`。
 * 规范见 `docs/design.md` §6.1：默认统一用透明底，仅明确要求时才用粉底
 * `logo-on-pink.svg`（iOS 图标等不接受透明的场景）。
 *
 * ## 用法
 * - **页内标识**：`<BrandMark size={22} />` 放在 `Ayla` 字标**前面**横向并排；
 * - **加载界面**：字标**居中上方**单独一行（见 FullScreenLoader）；
 * - 不要加 `border-radius`、不要改色或叠 `filter`——方形是刻意的，
 *   由系统/容器决定蒙版；最小可视尺寸 32px（更小时互锁缝隙会糊成一团）。
 */
export function BrandMark({
  size = 24,
  className,
}: {
  /** 边长（px）。同时作为宽高，保证正方形不被拉伸。 */
  size?: number;
  className?: string;
}) {
  return (
    <img
      className={className}
      src={`${import.meta.env.BASE_URL}brand/logo-max.svg`}
      width={size}
      height={size}
      /* 与紧邻的 Ayla 字标重复表达同一品牌，读屏跳过，避免念两遍 */
      alt=""
      aria-hidden="true"
      draggable={false}
    />
  );
}
