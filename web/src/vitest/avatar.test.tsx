import { fireEvent, render, screen } from "@testing-library/react";
import { describe, expect, it } from "vitest";
import { Avatar } from "../components/Avatar";

describe("Avatar 容错", () => {
  it("缺失 label 不崩并显示占位符", () => {
    render(<Avatar label={undefined} />);
    expect(screen.getByText("?")).toBeTruthy();
  });

  it("头像图片失败后回退首字符", () => {
    const { container } = render(<Avatar label="爱莉" imageUrl="/missing.png" />);
    fireEvent.error(container.querySelector("img")!);
    expect(screen.getByText("爱")).toBeTruthy();
  });
});
