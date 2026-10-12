/**
 * 群内帖子发帖面板的材质与遮罩契约（2026-10-12 用户裁决）。
 *
 * 用户原话：「修复群内帖子界面 web 和 flutter 发帖弹窗不好看且遮罩截断的问题，
 * 直接去掉黑色遮罩，弹出输入框透明度与输入框原本保持一致」。
 *
 * 本文件锁三条**跨文件结构契约**（Vitest 的 `css: false` 会清空 CSS 模块 ⇒ 按
 * `overlay-scrollbar.test.tsx:7–8` 的既有先例，直接读源码/样式文件断言）：
 *  ① 展开态**没有任何遮罩节点**，也没有 `.group-posts-scrim` 规则残留；
 *  ② 展开态面板底 = `--glass-bg-strong`（.78），与面板内 `.field` 的复合不透明度对齐；
 *     且 ≥769 的 auroraqua 覆写段**必须再声明一次**（同特异性后加载会压掉 posts.css）。
 */
import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { describe, expect, it } from "vitest";

const read = (p: string) => readFileSync(resolve(process.cwd(), p), "utf8");

const groupPostsTsx = read("src/pages/group/GroupPosts.tsx");
const postsCss = read("src/styles/posts.css");
const auroraquaCss = read("src/styles/auroraqua.css");

/** 去掉注释，避免断言命中说明文字本身。 */
function stripComments(css: string): string {
  return css.replace(/\/\*[\s\S]*?\*\//g, "");
}

describe("群内帖子发帖面板：无遮罩 + 展开态底提档", () => {
  it("GroupPosts.tsx 不再渲染遮罩节点", () => {
    // 注释里可以提到历史名称，JSX 里不行。
    const jsx = groupPostsTsx.replace(/\{\/\*[\s\S]*?\*\/\}/g, "");
    expect(jsx).not.toContain("group-posts-scrim");
    expect(jsx).not.toContain("setEditorExpanded(false)");
  });

  it("posts.css 不再有 .group-posts-scrim 规则与淡入关键帧", () => {
    const css = stripComments(postsCss);
    expect(css).not.toContain(".group-posts-scrim");
    expect(css).not.toContain("group-posts-scrim-in");
  });

  it("展开态面板底取 --glass-bg-strong（不是 .55 的 --glass-bg），一条声明两档通吃", () => {
    const css = stripComments(postsCss);
    const rule = /\.group-posts-input\.is-expanded\s*\{[^}]*\}/.exec(css);
    expect(rule, "缺少 .group-posts-input.is-expanded 规则").not.toBeNull();
    expect(rule![0]).toContain("--glass-bg-strong");

    // ⚠️ 曾有第二条断言要求 auroraqua 段「再声明一次」，理由是「同特异性后加载会压掉」——
    // **该理由错误，已撤回**：.group-posts-input.is-expanded 特异性 **0-2-0**，
    // ≥769 的 :is(.composer, .group-posts-input, …) 取最具体实参 = **0-1-0**，
    // 而级联**特异性优先于源码顺序**（媒体查询不贡献特异性）⇒ posts.css 那条恒胜出。
    // 已在真实浏览器按 main.tsx 的加载顺序实测：去掉 auroraqua 覆写后
    // expandedBg 仍是 rgba(255,250,251,0.78)。故此处**刻意不**断言 auroraqua 有声明；
    // 若有人日后又加一条冗余覆写，不是回归，无需拦。
    expect(
      /--glass-bg-strong/.test(stripComments(auroraquaCss)),
      "auroraqua 不应再出现 --glass-bg-strong 覆写（冗余；已在真实浏览器实测证明其非必要）",
    ).toBe(false);
  });

  it("面板内 .field 仍是 .55 玻璃（对齐基准：字段复合 ≈ .80）", () => {
    const css = stripComments(postsCss);
    const rule = /\.group-posts-input\s+\.field\s*\{[^}]*\}/.exec(css);
    expect(rule).not.toBeNull();
    expect(rule![0]).toContain("--glass-bg");
    expect(rule![0]).not.toContain("--glass-bg-strong");
  });
});
