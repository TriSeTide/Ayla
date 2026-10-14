/**
 * 弹层遮罩「无模糊」统一锁（2026-10-14 用户裁决）。
 *
 * ── 用户原话：「群内页面添加子群的弹窗有模糊，与语音直播没有模糊不统一的问题，
 *    统一成没有模糊」；
 * ── 事实源：`web/src/styles/group.css` 的 `.subgroup-dialog-overlay` 原带
 *    `backdrop-filter: blur(3px)`，是本仓**唯一**带模糊的遮罩；其余弹层
 *    （create-sheet / group-apply / privacy-sheet / share-sheet /
 *    quick-messages / user-profile / group-transfer）全无 backdrop-filter；
 * ── 修法：删除该声明，与全站弹层统一为无模糊（Flutter 侧 `maskBlur: 3` 同步删除）。
 *
 * ⚠️ 本文件用**源码扫描**而非渲染断言：CSS 的 backdrop-filter 在 jsdom 里
 *    不做真实合成，渲染断言测不出「有没有糊」；而「某个 overlay 类是否声明了
 *    backdrop-filter」是**纯源码事实**，扫描即精确。像素级效果由 Flutter 侧
 *    `test/subgroup_dialog_backdrop_density_test.dart` 的反向锁覆盖
 *    （无模糊实测 ~82%，带 blur(3px) 仅 7.2%）。
 */
import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { describe, expect, it } from "vitest";

const SRC = resolve(__dirname, "..");
const read = (rel: string) => readFileSync(resolve(SRC, rel), "utf8");

/** 取出某个选择器块的正文本体（从 { 到配对的 }）。 */
function block(css: string, selector: string): string {
  const i = css.indexOf(selector);
  if (i < 0) throw new Error("选择器未找到：" + selector);
  const open = css.indexOf("{", i);
  const close = css.indexOf("}", open);
  return css.slice(open + 1, close);
}

/** 去掉 CSS 注释，避免行内说明里的历史文字被当成声明。 */
const strip = (css: string) => css.replace(/\/\*[\s\S]*?\*\//g, "");

describe("弹层遮罩统一无模糊（2026-10-14 用户裁决）", () => {
  it("子群弹窗遮罩：rgba(70,91,146,.18)，且没有 backdrop-filter", () => {
    const body = strip(block(read("styles/group.css"), ".subgroup-dialog-overlay"));
    expect(body).toContain("rgba(70, 91, 146, 0.18)");
    expect(body.includes("backdrop-filter"), "遮罩不得有任何 backdrop-filter（含 -webkit- 前缀）").toBe(false);
  });

  it("子群弹窗卡片本体仍保留玻璃：只去遮罩模糊，不动卡片", () => {
    const body = strip(block(read("styles/group.css"), ".subgroup-dialog {"));
    expect(body).toContain("var(--glass-filter)");
    expect(body).toContain("var(--glass-bg-strong)");
  });

  it("语音/直播创建浮层（CreateSheet）遮罩无模糊 —— 用户对比的基准档", () => {
    const body = strip(block(read("styles/private.css"), ".create-sheet-overlay"));
    expect(body).toContain("rgba(70, 91, 146, 0.25)");
    expect(body.includes("backdrop-filter")).toBe(false);
  });

  it("全站弹层遮罩一律无 backdrop-filter（子群曾是唯一例外）", () => {
    const overlays: Array<[string, string]> = [
      [".subgroup-dialog-overlay", "styles/group.css"],
      [".create-sheet-overlay", "styles/private.css"],
      [".group-create-overlay", "styles/private.css"],
      [".group-apply-overlay", "styles/search.css"],
      [".user-profile-overlay", "styles/search.css"],
      [".privacy-sheet-overlay", "styles/profile.css"],
      [".share-sheet-overlay", "styles/share.css"],
      [".quick-messages-overlay", "styles/messages.css"],
      [".group-transfer-overlay", "styles/app.css"],
    ];
    const cache = new Map<string, string>();
    const cssOf = (file: string): string => {
      const hit = cache.get(file);
      if (hit !== undefined) return hit;
      const txt = read(file);
      cache.set(file, txt);
      return txt;
    };
    const offenders: string[] = [];
    for (const [sel, file] of overlays) {
      if (strip(block(cssOf(file), sel)).includes("backdrop-filter")) {
        offenders.push(sel + " (" + file + ")");
      }
    }
    expect(offenders).toEqual([]);
  });
});
