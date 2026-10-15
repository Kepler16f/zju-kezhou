/// widgets/line_chart.dart — 学期走势折线图（CustomPainter，零依赖）。
/// 双系列：每学期 GPA（浅色）+ 累计 GPA（主色）；y 轴自适应 0–5。
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

class TrendPoint {
  final String label;
  final double term;
  final double cumulative;
  const TrendPoint(this.label, this.term, this.cumulative);
}

class TrendChart extends StatelessWidget {
  final List<TrendPoint> points;
  const TrendChart({super.key, required this.points});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 220,
      child: CustomPaint(painter: _TrendPainter(points, Theme.of(context).colorScheme),
          size: Size.infinite),
    );
  }
}

class _TrendPainter extends CustomPainter {
  final List<TrendPoint> pts;
  final ColorScheme scheme;
  _TrendPainter(this.pts, this.scheme);

  @override
  void paint(Canvas canvas, Size size) {
    const padL = 34.0, padR = 10.0, padT = 14.0, padB = 26.0;
    final w = size.width - padL - padR, h = size.height - padT - padB;
    if (w <= 0 || h <= 0 || pts.isEmpty) return;

    final grid = Paint()
      ..color = scheme.outlineVariant.withValues(alpha: 0.5)
      ..strokeWidth = 0.8;
    final labelStyle = TextStyle(fontSize: 9, color: scheme.onSurfaceVariant);
    // 网格 + y 轴刻度（0–5）
    for (var v = 0.0; v <= 5.0; v += 1.0) {
      final y = padT + h - (v / 5.0) * h;
      canvas.drawLine(Offset(padL, y), Offset(padL + w, y), grid);
      _text(canvas, v.toStringAsFixed(0), Offset(4, y - 5), labelStyle);
    }

    Offset pos(int i, double v) =>
        Offset(padL + (pts.length == 1 ? w / 2 : i / (pts.length - 1) * w),
            padT + h - (v.clamp(0.0, 5.0) / 5.0) * h);

    // x 轴标签（学期，最多 10 个防挤）
    final step = math.max(1, (pts.length / 10).ceil());
    for (var i = 0; i < pts.length; i += step) {
      final p = pos(i, 0);
      _text(canvas, pts[i].label, Offset(p.dx - 12, padT + h + 6), labelStyle);
    }

    void drawSeries(double Function(TrendPoint) get, Color color, double width) {
      if (pts.length == 1) {
        final c = pos(0, get(pts[0]));
        canvas.drawCircle(c, 3.5, Paint()..color = color);
        return;
      }
      final path = Path()..moveTo(pos(0, get(pts[0])).dx, pos(0, get(pts[0])).dy);
      for (var i = 1; i < pts.length; i++) {
        path.lineTo(pos(i, get(pts[i])).dx, pos(i, get(pts[i])).dy);
      }
      canvas.drawPath(
          path,
          Paint()
            ..color = color
            ..strokeWidth = width
            ..style = PaintingStyle.stroke
            ..strokeCap = StrokeCap.round
            ..strokeJoin = StrokeJoin.round);
      for (var i = 0; i < pts.length; i++) {
        canvas.drawCircle(pos(i, get(pts[i])), 2.5, Paint()..color = color);
      }
    }

    drawSeries((p) => p.term, scheme.tertiary.withValues(alpha: 0.75), 1.8);
    drawSeries((p) => p.cumulative, scheme.primary, 2.6);
  }

  void _text(Canvas canvas, String s, Offset at, TextStyle style) {
    final tp = TextPainter(text: TextSpan(text: s, style: style))
      ..textDirection = TextDirection.ltr
      ..layout();
    tp.paint(canvas, at);
  }

  @override
  bool shouldRepaint(covariant _TrendPainter old) =>
      old.pts.length != pts.length || old.scheme != scheme;
}
