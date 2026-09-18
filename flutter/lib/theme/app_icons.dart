/// Ayla 线性图标体系（web `components/icons.tsx` 的 Flutter 等价）。
///
/// 事实源:web 端 47 个 Lucide 风格线性图标 —— **2px 描边、圆角端点
/// (strokeLinecap/join: round)、viewBox 0 0 24 24、默认 18×18**。
/// 数据在 `app_icons_data.dart`(由 icons.tsx 自动生成,勿手改);
/// 实心特例(IconPlay/IconPause/IconPinFilled)按 fill/stroke 属性还原。
///
/// 纪律(05 §4 / d:§8):图标用线性 SVG 风格,**禁止 emoji 当功能图标**;
/// 图标色一律显式传参,不裸色值。
library;

import 'package:flutter/material.dart';
import 'package:flutter/widget_previews.dart';

import 'app_icons_data.dart';
export 'app_icons_data.dart';
import 'app_theme.dart';
import 'preview_theme.dart';
import 'tokens.dart';

/// 按名取图标(web 名小驼峰,如 `iconSend`);找不到返回 null。
AylaIconData? aylaIconByName(String name) {
  for (final AylaIconData icon in kAylaIcons) {
    if (icon.name == name) return icon;
  }
  return null;
}

/// 线性图标绘制（stroke: 2px / round cap+join；默认 size 18）。
class AylaIcon extends StatelessWidget {
  const AylaIcon(
    this.icon, {
    super.key,
    this.size = 18,
    this.color,
    this.semanticLabel,
  });

  /// 图标数据（自动生成表）。
  final AylaIconData icon;

  /// 边长（web base 默认 18px；24 为图标原始 viewBox 尺寸）。
  final double size;

  /// 颜色（默认 [AylaColors.textPrimary]；爱莉/激活态由调用方传）。
  final Color? color;

  /// 可访问性标签。
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: semanticLabel,
      excludeSemantics: semanticLabel == null,
      child: CustomPaint(
        size: Size.square(size),
        painter: _AylaIconPainter(
          icon,
          color ?? AylaColors.textPrimary,
        ),
      ),
    );
  }
}

/// 图标 painter：viewBox 24 缩放到 [size]，逐元素按渲染模式绘制。
class _AylaIconPainter extends CustomPainter {
  const _AylaIconPainter(this.icon, this.color);

  final AylaIconData icon;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final double s = size.width / 24;
    canvas.save();
    canvas.scale(s, s);

    for (final AylaIconElement el in icon.elements) {
      final Paint stroke = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = el.strokeWidth ?? 2
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..color = color;
      final Paint fill = Paint()..color = color;

      switch (el.kind) {
        case AylaIconKind.circle:
          final Offset c = Offset(el.cx!, el.cy!);
          if (el.filled) {
            canvas.drawCircle(c, el.r!, fill);
          } else {
            canvas.drawCircle(c, el.r!, stroke);
          }
        case AylaIconKind.line:
          canvas.drawLine(
            Offset(el.x1!, el.y1!),
            Offset(el.x2!, el.y2!),
            stroke,
          );
        case AylaIconKind.path:
          final Path p = _parseSvgPath(el.d!);
          canvas.drawPath(p, el.filled ? fill : stroke);
        case AylaIconKind.polygon:
          final Path p = _pointsPath(el.points!);
          p.close();
          canvas.drawPath(p, el.filled ? fill : stroke);
        case AylaIconKind.polyline:
          final Path p = _pointsPath(el.points!);
          canvas.drawPath(p, stroke);
        case AylaIconKind.rect:
          final RRect rr = RRect.fromRectAndRadius(
            Rect.fromLTWH(
              el.x ?? 0,
              el.y ?? 0,
              el.width ?? 0,
              el.height ?? 0,
            ),
            Radius.circular(el.rx ?? el.ry ?? 0),
          );
          if (el.filled) {
            canvas.drawRRect(rr, fill);
          } else {
            canvas.drawRRect(rr, stroke);
          }
      }
    }

    canvas.restore();
  }

  static Path _pointsPath(String points) {
    final List<double> nums =
        points.trim().split(RegExp(r'[\s,]+')).map(double.parse).toList();
    final Path p = Path();
    for (int i = 0; i + 1 < nums.length; i += 2) {
      if (i == 0) {
        p.moveTo(nums[i], nums[i + 1]);
      } else {
        p.lineTo(nums[i], nums[i + 1]);
      }
    }
    return p;
  }

  /// SVG path d 解析（Flutter 3.47 无 Path.parse；支持 web icons.tsx 用到的
  /// M/L/H/V/C/S/Q/T/A 与对应相对命令、Z 闭合、隐式命令重复）。
  static Path _parseSvgPath(String d) {
    final Path p = Path();
    final RegExp numRe = RegExp(
      r'[-+]?(?:\d*\.\d+|\d+\.?)(?:[eE][-+]?\d+)?',
    );
    int i = 0;
    double curX = 0, curY = 0;
    double? startX, startY;
    double? lastCtrlX, lastCtrlY; // 上一命令的终点控制点（S/T 反射用）

    double? readNum() {
      // 必须先跳过空白与逗号：否则 "M20 6" 读完 20 后停在空格上，
      // matchAsPrefix 直接失败 → 参数不足 → 整条命令被丢弃，
      // 后续命令基准点全错（实测现象：图标只剩开头一两笔）。
      while (i < d.length) {
        final int ch = d.codeUnitAt(i);
        if (ch == 0x20 || ch == 0x2C || ch == 0x09 || ch == 0x0A ||
            ch == 0x0D) {
          i++;
        } else {
          break;
        }
      }
      final Match? m = numRe.matchAsPrefix(d, i);
      if (m == null) return null;
      i = m.end;
      return double.parse(m.group(0)!);
    }

    void moveToAbs(double x, double y) {
      curX = x;
      curY = y;
      startX ??= x;
      startY ??= y;
      p.moveTo(x, y);
    }

    while (i < d.length) {
      final int c = d.codeUnitAt(i);
      final String cmd = String.fromCharCode(c);
      if (cmd == ' ' || cmd == ',' || cmd == '\n' || cmd == '\t' ||
          cmd == '\r') {
        i++;
        continue;
      }
      final bool recognized = 'MmLlHhVvCcSsQqTtAaZz'.contains(cmd);
      if (!recognized) {
        i++;
        continue;
      }
      final bool isRel = cmd == cmd.toLowerCase();
      final String upper = cmd.toUpperCase();

      if (upper == 'Z') {
        // z / Z：闭合（无参数）
        p.close();
        curX = startX ?? 0;
        curY = startY ?? 0;
        lastCtrlX = null;
        lastCtrlY = null;
        i++;
        continue;
      }

      // 消费命令字母（必须：否则 readNum 在字母处失败后外层循环
      // 重读同一字母 → 死循环，测试实测挂死）。
      i++;

      // 参数需求表
      final int need;
      switch (upper) {
        case 'M':
        case 'L':
        case 'T':
          need = 2;
        case 'H':
        case 'V':
          need = 1;
        case 'C':
          need = 6;
        case 'S':
        case 'Q':
          need = 4;
        case 'A':
          need = 7;
        default:
          need = 0;
      }

      bool hasArgs = true;
      bool firstGroup = true;
      while (hasArgs) {
        final List<double> args = <double>[];
        for (int k = 0; k < need; k++) {
          final double? n = readNum();
          if (n == null) break;
          args.add(n);
        }
        if (args.length < need) {
          // 参数不足：本命令结束。i 停留在下一个命令字母/结束处，
          // 由外层循环自然消费——**不能 i++**，否则会吞掉命令字母
          // （如 "3 4L5 6" 参数不足处若 i++ 会跳过 L）。
          hasArgs = false;
        } else {
          // SVG 规范：M/m 之后的隐式重复参数是 L/l（连线），不是再次
          // moveTo——"M18 6 6 18" 必须画 (18,6)→(6,18) 的线，否则
          // 形状缺线/错乱（实测：iconClose 斜线消失、iconSend 全乱）。
          final String execCmd =
              (upper == 'M' && !firstGroup) ? (isRel ? 'l' : 'L') : cmd;
          final bool execRel = execCmd == execCmd.toLowerCase();
          final String execUpper = execCmd.toUpperCase();
          firstGroup = false;
          double rx, ry; // 计算后的目标点
          switch (execUpper) {
            case 'M':
              final double x = args[0], y = args[1];
              if (execRel) {
                moveToAbs(curX + x, curY + y);
              } else {
                moveToAbs(x, y);
              }
              lastCtrlX = null;
              lastCtrlY = null;
            case 'L':
              rx = execRel ? curX + args[0] : args[0];
              ry = execRel ? curY + args[1] : args[1];
              p.lineTo(rx, ry);
              curX = rx;
              curY = ry;
              lastCtrlX = null;
              lastCtrlY = null;
            case 'H':
              rx = execRel ? curX + args[0] : args[0];
              p.lineTo(rx, curY);
              curX = rx;
              lastCtrlX = null;
              lastCtrlY = null;
            case 'V':
              ry = execRel ? curY + args[0] : args[0];
              p.lineTo(curX, ry);
              curY = ry;
              lastCtrlX = null;
              lastCtrlY = null;
            case 'C':
              final double x1 = execRel ? curX + args[0] : args[0];
              final double y1 = execRel ? curY + args[1] : args[1];
              final double x2 = execRel ? curX + args[2] : args[2];
              final double y2 = execRel ? curY + args[3] : args[3];
              rx = execRel ? curX + args[4] : args[4];
              ry = execRel ? curY + args[5] : args[5];
              p.cubicTo(x1, y1, x2, y2, rx, ry);
              curX = rx;
              curY = ry;
              lastCtrlX = x2;
              lastCtrlY = y2;
            case 'S':
              final double x1 =
                  lastCtrlX != null ? curX + (curX - lastCtrlX) : curX;
              final double y1 =
                  lastCtrlY != null ? curY + (curY - lastCtrlY) : curY;
              final double x2 = execRel ? curX + args[0] : args[0];
              final double y2 = execRel ? curY + args[1] : args[1];
              rx = execRel ? curX + args[2] : args[2];
              ry = execRel ? curY + args[3] : args[3];
              p.cubicTo(x1, y1, x2, y2, rx, ry);
              curX = rx;
              curY = ry;
              lastCtrlX = x2;
              lastCtrlY = y2;
            case 'Q':
              final double x1 = execRel ? curX + args[0] : args[0];
              final double y1 = execRel ? curY + args[1] : args[1];
              rx = execRel ? curX + args[2] : args[2];
              ry = execRel ? curY + args[3] : args[3];
              p.quadraticBezierTo(x1, y1, rx, ry);
              curX = rx;
              curY = ry;
              lastCtrlX = x1;
              lastCtrlY = y1;
            case 'T':
              final double x1 =
                  lastCtrlX != null ? curX + (curX - lastCtrlX) : curX;
              final double y1 =
                  lastCtrlY != null ? curY + (curY - lastCtrlY) : curY;
              rx = execRel ? curX + args[0] : args[0];
              ry = execRel ? curY + args[1] : args[1];
              p.quadraticBezierTo(x1, y1, rx, ry);
              curX = rx;
              curY = ry;
              lastCtrlX = x1;
              lastCtrlY = y1;
            case 'A':
              final double rxAxis = args[0], ryAxis = args[1];
              final double rot = args[2];
              final bool largeArc = args[3] != 0;
              final bool sweep = args[4] != 0;
              rx = execRel ? curX + args[5] : args[5];
              ry = execRel ? curY + args[6] : args[6];
              p.arcToPoint(
                Offset(rx, ry),
                radius: Radius.elliptical(rxAxis, ryAxis),
                rotation: rot * 3.141592653589793 / 180,
                largeArc: largeArc,
                clockwise: sweep,
              );
              curX = rx;
              curY = ry;
              lastCtrlX = null;
              lastCtrlY = null;
          }
        }
      }
      // 参数不足：命令字母由下一轮循环消费，无需移动 i。
    }
    return p;
  }

  @override
  bool shouldRepaint(covariant _AylaIconPainter oldDelegate) =>
      oldDelegate.icon != icon || oldDelegate.color != color;
}

// ======================= 预览 =======================

/// 全量图标平铺（18px 真实尺寸 + 名称）。
@Preview(
  group: 'Icons',
  name: '图标库全量（47 个）',
  size: Size(900, 900),
  wrapper: previewTheme,
)
Widget aylaIconsPreview() {
  return Padding(
    padding: const EdgeInsets.all(AylaSpacing.sp6),
    child: Wrap(
      spacing: AylaSpacing.sp4,
      runSpacing: AylaSpacing.sp6,
      crossAxisAlignment: WrapCrossAlignment.start,
      children: <Widget>[
        for (final AylaIconData icon in kAylaIcons)
          Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              AylaIcon(icon, size: 18, color: AylaColors.indigo700),
              const SizedBox(height: AylaSpacing.sp1),
              SizedBox(
                width: 110,
                child: Text(
                  icon.name,
                  textAlign: TextAlign.center,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AylaTextStyles.light.timestamp
                      .copyWith(color: AylaColors.textSecondary),
                ),
              ),
            ],
          ),
      ],
    ),
  );
}
