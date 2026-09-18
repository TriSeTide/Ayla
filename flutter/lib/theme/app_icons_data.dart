/// 图标数据 —— 从 `Ayla/web/src/components/icons.tsx` 自动生成。
///
/// 事实源:web 端 46 个 Lucide 风格线性图标(2px 描边、圆角端点、
/// viewBox 0 0 24 24);元素级渲染模式(实心/描边)已按 fill/stroke
/// 属性还原(如 IconPlay/IconPause/IconPinFilled 为实心)。
/// 来源:https://lucide.dev 线性图标风格,d 数据为 web 源码逐字导入,
/// 禁止手改;新增图标=改 web 端 icons.tsx 后重新生成。
library;


/// 元素类型(SVG 元素 → Flutter 绘制)。
enum AylaIconKind { circle, line, path, polygon, polyline, rect }

/// 单个图标元素(数值属性见 web 源码,单位 = viewBox 24 坐标)。
class AylaIconElement {
  const AylaIconElement(
    this.kind,
    {this.cx, this.cy, this.r,
     this.x1, this.y1, this.x2, this.y2,
     this.x, this.y, this.width, this.height, this.rx, this.ry,
     this.d, this.points,
     this.filled = false, this.strokeWidth});

  final AylaIconKind kind;
  final double? cx, cy, r, x1, y1, x2, y2, x, y, width, height, rx, ry;
  /// SVG path d(Path.parse 直接消费)。
  final String? d;
  /// polygon/polyline 的点串("x y x y …")。
  final String? points;
  /// true = 实心渲染(fill=currentColor stroke=none)。
  final bool filled;
  /// 描边宽覆盖(默认 2,仅 IconPinFilled 顶针等特例)。
  final double? strokeWidth;
}

/// 一个图标(名称 + 元素列表)。
class AylaIconData {
  const AylaIconData(this.name, this.elements);
  final String name;
  final List<AylaIconElement> elements;
}

/// 全量图标(顺序与 web icons.tsx 一致)。
const List<AylaIconData> kAylaIcons = <AylaIconData>[
  AylaIconData('iconEmoji', <AylaIconElement>[
    AylaIconElement(AylaIconKind.circle, cx: 12, cy: 12, r: 10),
    AylaIconElement(AylaIconKind.path, d: "M8 14s1.5 2 4 2 4-2 4-2"),
    AylaIconElement(AylaIconKind.line, x1: 9, y1: 9, x2: 9.01, y2: 9),
    AylaIconElement(AylaIconKind.line, x1: 15, y1: 9, x2: 15.01, y2: 9),
  ]),
  AylaIconData('iconSend', <AylaIconElement>[
    AylaIconElement(AylaIconKind.path, d: "m22 2-7 20-4-9-9-4Z"),
    AylaIconElement(AylaIconKind.path, d: "M22 2 11 13"),
  ]),
  AylaIconData('iconShare', <AylaIconElement>[
    AylaIconElement(AylaIconKind.circle, cx: 18, cy: 5, r: 3),
    AylaIconElement(AylaIconKind.circle, cx: 6, cy: 12, r: 3),
    AylaIconElement(AylaIconKind.circle, cx: 18, cy: 19, r: 3),
    AylaIconElement(AylaIconKind.path, d: "m8.6 13.5 6.8 4M15.4 6.5l-6.8 4"),
  ]),
  AylaIconData('iconUserPlus', <AylaIconElement>[
    AylaIconElement(AylaIconKind.path, d: "M16 21v-2a4 4 0 0 0-4-4H6a4 4 0 0 0-4 4v2"),
    AylaIconElement(AylaIconKind.circle, cx: 9, cy: 7, r: 4),
    AylaIconElement(AylaIconKind.path, d: "M19 8v6M22 11h-6"),
  ]),
  AylaIconData('iconPlus', <AylaIconElement>[
    AylaIconElement(AylaIconKind.path, d: "M12 5v14M5 12h14"),
  ]),
  AylaIconData('iconClose', <AylaIconElement>[
    AylaIconElement(AylaIconKind.path, d: "M18 6 6 18M6 6l12 12"),
  ]),
  AylaIconData('iconSearch', <AylaIconElement>[
    AylaIconElement(AylaIconKind.circle, cx: 11, cy: 11, r: 8),
    AylaIconElement(AylaIconKind.path, d: "m21 21-4.3-4.3"),
  ]),
  AylaIconData('iconDownload', <AylaIconElement>[
    AylaIconElement(AylaIconKind.path, d: "M21 15v4a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-4"),
    AylaIconElement(AylaIconKind.path, d: "m7 10 5 5 5-5"),
    AylaIconElement(AylaIconKind.path, d: "M12 15V3"),
  ]),
  AylaIconData('iconFile', <AylaIconElement>[
    AylaIconElement(AylaIconKind.path, d: "M15 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V7Z"),
    AylaIconElement(AylaIconKind.path, d: "M14 2v4a2 2 0 0 0 2 2h4"),
  ]),
  AylaIconData('iconImage', <AylaIconElement>[
    AylaIconElement(AylaIconKind.rect, x: 3, y: 3, width: 18, height: 18, rx: 2, ry: 2),
    AylaIconElement(AylaIconKind.circle, cx: 9, cy: 9, r: 2),
    AylaIconElement(AylaIconKind.path, d: "m21 15-3.086-3.086a2 2 0 0 0-2.828 0L6 21"),
  ]),
  AylaIconData('iconMic', <AylaIconElement>[
    AylaIconElement(AylaIconKind.path, d: "M12 2a3 3 0 0 0-3 3v7a3 3 0 0 0 6 0V5a3 3 0 0 0-3-3Z"),
    AylaIconElement(AylaIconKind.path, d: "M19 10v2a7 7 0 0 1-14 0v-2"),
    AylaIconElement(AylaIconKind.path, d: "M12 19v3"),
  ]),
  AylaIconData('iconMicOff', <AylaIconElement>[
    AylaIconElement(AylaIconKind.path, d: "M12 2a3 3 0 0 0-3 3v4a3 3 0 0 0 5.12 2.12"),
    AylaIconElement(AylaIconKind.path, d: "M12 19v3"),
    AylaIconElement(AylaIconKind.path, d: "M19 10v2a7 7 0 0 1-5 6.66"),
    AylaIconElement(AylaIconKind.path, d: "M3 3l18 18"),
  ]),
  AylaIconData('iconSpeaker', <AylaIconElement>[
    AylaIconElement(AylaIconKind.path, d: "M11 5 6 9H2v6h4l5 4V5Z"),
    AylaIconElement(AylaIconKind.path, d: "M15.54 8.46a5 5 0 0 1 0 7.07"),
    AylaIconElement(AylaIconKind.path, d: "M19.07 4.93a10 10 0 0 1 0 14.14"),
  ]),
  AylaIconData('iconSpeakerOff', <AylaIconElement>[
    AylaIconElement(AylaIconKind.path, d: "M11 5 6 9H2v6h4l5 4V5Z"),
    AylaIconElement(AylaIconKind.line, x1: 22, y1: 9, x2: 16, y2: 15),
    AylaIconElement(AylaIconKind.line, x1: 16, y1: 9, x2: 22, y2: 15),
  ]),
  AylaIconData('iconPlay', <AylaIconElement>[
    AylaIconElement(AylaIconKind.polygon, points: "6 3 20 12 6 21 6 3", filled: true),
  ]),
  AylaIconData('iconPause', <AylaIconElement>[
    AylaIconElement(AylaIconKind.rect, x: 6, y: 4, width: 4, height: 16, rx: 1, filled: true),
    AylaIconElement(AylaIconKind.rect, x: 14, y: 4, width: 4, height: 16, rx: 1, filled: true),
  ]),
  AylaIconData('iconQuote', <AylaIconElement>[
    AylaIconElement(AylaIconKind.path, d: "M3 21c3 0 7-1 7-8V5c0-1.25-.756-2.017-2-2H4c-1.25 0-2 .75-2 1.972V11c0 1.25.75 2 2 2 1 0 1 0 1 1v1c0 1-1 2-2 2s-1 .008-1 1.031V20c0 1 0 1 1 1z"),
    AylaIconElement(AylaIconKind.path, d: "M15 21c3 0 7-1 7-8V5c0-1.25-.757-2.017-2-2h-4c-1.25 0-2 .75-2 1.972V11c0 1.25.75 2 2 2h.75c0 2.25.25 4-2.75 4v3c0 1 0 1 1 1z"),
  ]),
  AylaIconData('iconUndo', <AylaIconElement>[
    AylaIconElement(AylaIconKind.path, d: "M3 7v6h6"),
    AylaIconElement(AylaIconKind.path, d: "M21 17a9 9 0 0 0-9-9 9 9 0 0 0-6 2.3L3 13"),
  ]),
  AylaIconData('iconMenu', <AylaIconElement>[
    AylaIconElement(AylaIconKind.path, d: "M4 6h16M4 12h16M4 18h16"),
  ]),
  AylaIconData('iconBack', <AylaIconElement>[
    AylaIconElement(AylaIconKind.path, d: "M19 12H5m7-7-7 7 7 7"),
  ]),
  AylaIconData('iconLogout', <AylaIconElement>[
    AylaIconElement(AylaIconKind.path, d: "M9 21H5a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h4"),
    AylaIconElement(AylaIconKind.path, d: "m16 17 5-5-5-5"),
    AylaIconElement(AylaIconKind.path, d: "M21 12H9"),
  ]),
  AylaIconData('iconRetry', <AylaIconElement>[
    AylaIconElement(AylaIconKind.path, d: "M21 12a9 9 0 1 1-9-9c2.52 0 4.93 1 6.74 2.74L21 8"),
    AylaIconElement(AylaIconKind.path, d: "M21 3v5h-5"),
  ]),
  AylaIconData('iconUser', <AylaIconElement>[
    AylaIconElement(AylaIconKind.path, d: "M19 21v-2a4 4 0 0 0-4-4H9a4 4 0 0 0-4 4v2"),
    AylaIconElement(AylaIconKind.circle, cx: 12, cy: 7, r: 4),
  ]),
  AylaIconData('iconHome', <AylaIconElement>[
    AylaIconElement(AylaIconKind.path, d: "m3 9 9-7 9 7v11a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2Z"),
    AylaIconElement(AylaIconKind.path, d: "M9 22V12h6v10"),
  ]),
  AylaIconData('iconVideo', <AylaIconElement>[
    AylaIconElement(AylaIconKind.path, d: "m22 8-6 4 6 4V8Z"),
    AylaIconElement(AylaIconKind.rect, x: 2, y: 6, width: 14, height: 12, rx: 2, ry: 2),
  ]),
  AylaIconData('iconPost', <AylaIconElement>[
    AylaIconElement(AylaIconKind.path, d: "M15 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V7Z"),
    AylaIconElement(AylaIconKind.path, d: "M14 2v4a2 2 0 0 0 2 2h4"),
    AylaIconElement(AylaIconKind.path, d: "M16 13H8"),
    AylaIconElement(AylaIconKind.path, d: "M16 17H8"),
  ]),
  AylaIconData('iconGame', <AylaIconElement>[
    AylaIconElement(AylaIconKind.rect, x: 3, y: 3, width: 18, height: 18, rx: 2, ry: 2),
    AylaIconElement(AylaIconKind.path, d: "M8 8h.01"),
    AylaIconElement(AylaIconKind.path, d: "M16 8h.01"),
    AylaIconElement(AylaIconKind.path, d: "M12 12h.01"),
    AylaIconElement(AylaIconKind.path, d: "M8 16h.01"),
    AylaIconElement(AylaIconKind.path, d: "M16 16h.01"),
  ]),
  AylaIconData('iconMessage', <AylaIconElement>[
    AylaIconElement(AylaIconKind.path, d: "M7.9 20A9 9 0 1 0 4 16.1L2 22Z"),
  ]),
  AylaIconData('iconEye', <AylaIconElement>[
    AylaIconElement(AylaIconKind.path, d: "M2 12s3.5-7 10-7 10 7 10 7-3.5 7-10 7-10-7-10-7Z"),
    AylaIconElement(AylaIconKind.circle, cx: 12, cy: 12, r: 3),
  ]),
  AylaIconData('iconChat', <AylaIconElement>[
    AylaIconElement(AylaIconKind.path, d: "M7.9 20A9 9 0 1 0 4 16.1L2 22Z"),
    AylaIconElement(AylaIconKind.path, d: "M8 12h.01M12 12h.01M16 12h.01"),
  ]),
  AylaIconData('iconDots', <AylaIconElement>[
    AylaIconElement(AylaIconKind.circle, cx: 12, cy: 12, r: 1),
    AylaIconElement(AylaIconKind.circle, cx: 19, cy: 12, r: 1),
    AylaIconElement(AylaIconKind.circle, cx: 5, cy: 12, r: 1),
  ]),
  AylaIconData('iconPin', <AylaIconElement>[
    AylaIconElement(AylaIconKind.path, d: "M12 17v5"),
    AylaIconElement(AylaIconKind.path, d: "M9 10.76a2 2 0 0 1-1.11 1.79l-1.78.9A2 2 0 0 0 5 15.24V16a1 1 0 0 0 1 1h12a1 1 0 0 0 1-1v-.76a2 2 0 0 0-1.11-1.79l-1.78-.9A2 2 0 0 1 15 10.76V6h1a2 2 0 0 0 0-4H8a2 2 0 0 0 0 4h1z"),
  ]),
  AylaIconData('iconPinFilled', <AylaIconElement>[
    AylaIconElement(AylaIconKind.path, d: "M12 17v5", strokeWidth: 2),
    AylaIconElement(AylaIconKind.path, d: "M9 10.76a2 2 0 0 1-1.11 1.79l-1.78.9A2 2 0 0 0 5 15.24V16a1 1 0 0 0 1 1h12a1 1 0 0 0 1-1v-.76a2 2 0 0 0-1.11-1.79l-1.78-.9A2 2 0 0 1 15 10.76V6h1a2 2 0 0 0 0-4H8a2 2 0 0 0 0 4h1z"),
  ]),
  AylaIconData('iconUsers', <AylaIconElement>[
    AylaIconElement(AylaIconKind.path, d: "M16 21v-2a4 4 0 0 0-4-4H6a4 4 0 0 0-4 4v2"),
    AylaIconElement(AylaIconKind.circle, cx: 9, cy: 7, r: 4),
    AylaIconElement(AylaIconKind.path, d: "M22 21v-2a4 4 0 0 0-3-3.87"),
    AylaIconElement(AylaIconKind.path, d: "M16 3.13a4 4 0 0 1 0 7.75"),
  ]),
  AylaIconData('iconGrid', <AylaIconElement>[
    AylaIconElement(AylaIconKind.rect, x: 3, y: 3, width: 7, height: 7, rx: 1),
    AylaIconElement(AylaIconKind.rect, x: 14, y: 3, width: 7, height: 7, rx: 1),
    AylaIconElement(AylaIconKind.rect, x: 3, y: 14, width: 7, height: 7, rx: 1),
    AylaIconElement(AylaIconKind.rect, x: 14, y: 14, width: 7, height: 7, rx: 1),
  ]),
  AylaIconData('iconList', <AylaIconElement>[
    AylaIconElement(AylaIconKind.path, d: "M8 6h13M8 12h13M8 18h13"),
    AylaIconElement(AylaIconKind.circle, cx: 4, cy: 6, r: 1),
    AylaIconElement(AylaIconKind.circle, cx: 4, cy: 12, r: 1),
    AylaIconElement(AylaIconKind.circle, cx: 4, cy: 18, r: 1),
  ]),
  AylaIconData('iconHeart', <AylaIconElement>[
    AylaIconElement(AylaIconKind.path, d: "M19 14c1.49-1.46 3-3.21 3-5.5A5.5 5.5 0 0 0 16.5 3c-1.76 0-3 .5-4.5 2-1.5-1.5-2.74-2-4.5-2A5.5 5.5 0 0 0 2 8.5c0 2.3 1.5 4.05 3 5.5l7 7Z"),
  ]),
  AylaIconData('iconChevronUp', <AylaIconElement>[
    AylaIconElement(AylaIconKind.polyline, points: "18 15 12 9 6 15"),
  ]),
  AylaIconData('iconCheck', <AylaIconElement>[
    AylaIconElement(AylaIconKind.path, d: "M20 6 9 17l-5-5"),
  ]),
  AylaIconData('iconChevronDown', <AylaIconElement>[
    AylaIconElement(AylaIconKind.polyline, points: "6 9 12 15 18 9"),
  ]),
  AylaIconData('iconChevronLeft', <AylaIconElement>[
    AylaIconElement(AylaIconKind.polyline, points: "15 18 9 12 15 6"),
  ]),
  AylaIconData('iconChevronRight', <AylaIconElement>[
    AylaIconElement(AylaIconKind.polyline, points: "9 18 15 12 9 6"),
  ]),
  AylaIconData('iconArrowRight', <AylaIconElement>[
    AylaIconElement(AylaIconKind.path, d: "M5 12h14"),
    AylaIconElement(AylaIconKind.path, d: "m12 5 7 7-7 7"),
  ]),
  AylaIconData('iconArrowUp', <AylaIconElement>[
    AylaIconElement(AylaIconKind.path, d: "M12 19V5"),
    AylaIconElement(AylaIconKind.path, d: "m5 12 7-7 7 7"),
  ]),
  AylaIconData('iconRefresh', <AylaIconElement>[
    AylaIconElement(AylaIconKind.path, d: "M21 12a9 9 0 1 1-9-9c2.52 0 4.93 1 6.74 2.74L21 8"),
    AylaIconElement(AylaIconKind.path, d: "M21 3v5h-5"),
  ]),
  AylaIconData('iconPip', <AylaIconElement>[
    AylaIconElement(AylaIconKind.path, d: "M21 9V6a2 2 0 0 0-2-2H4a2 2 0 0 0-2 2v10c0 1.1.9 2 2 2h4"),
    AylaIconElement(AylaIconKind.rect, x: 12, y: 13, width: 10, height: 7, rx: 2),
  ]),
  AylaIconData('iconFullscreen', <AylaIconElement>[
    AylaIconElement(AylaIconKind.path, d: "M8 3H5a2 2 0 0 0-2 2v3"),
    AylaIconElement(AylaIconKind.path, d: "M21 8V5a2 2 0 0 0-2-2h-3"),
    AylaIconElement(AylaIconKind.path, d: "M3 16v3a2 2 0 0 0 2 2h3"),
    AylaIconElement(AylaIconKind.path, d: "M16 21h3a2 2 0 0 0 2-2v-3"),
  ]),
];
