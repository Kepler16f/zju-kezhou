/// widgets/boat_icon.dart — 课舟品牌帆形矢量图标（诉求：AI 悬浮入口图标重绘）。
///
/// 呼应 App 图标（圆角方形渐变帆船）：一条帆船剪影，主色描船身与帆，
/// CustomPainter 零图片依赖、任意尺寸清晰、随主题色。
library;

import 'package:flutter/material.dart';

class BoatIcon extends StatelessWidget {
  final double size;
  final Color? color;
  const BoatIcon({super.key, this.size = 24, this.color});

  @override
  Widget build(BuildContext context) {
    final c = color ?? Theme.of(context).colorScheme.onPrimaryContainer;
    return CustomPaint(
      size: Size.square(size),
      painter: _BoatPainter(c),
    );
  }
}

class _BoatPainter extends CustomPainter {
  final Color color;
  _BoatPainter(this.color);

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width, h = size.height;
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = (w / 24) * 1.8
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    final fill = Paint()..color = color;

    // 桅杆
    canvas.drawLine(Offset(w * .42, h * .14), Offset(w * .42, h * .70), paint);
    // 主帆（右侧弧面三角）
    final main = Path()
      ..moveTo(w * .45, h * .17)
      ..quadraticBezierTo(w * .80, h * .40, w * .50, h * .62)
      ..lineTo(w * .45, h * .62)
      ..close();
    canvas.drawPath(main, fill);
    // 前帆（左侧小三角）
    final jib = Path()
      ..moveTo(w * .39, h * .28)
      ..lineTo(w * .17, h * .60)
      ..lineTo(w * .39, h * .60)
      ..close();
    canvas.drawPath(jib, fill);
    // 船身：上沿直线 + 下弧（V 形底），填满成实心船体
    final body = Path()
      ..moveTo(w * .12, h * .70)
      ..lineTo(w * .88, h * .70)
      ..quadraticBezierTo(w * .78, h * .90, w * .50, h * .90)
      ..quadraticBezierTo(w * .22, h * .90, w * .12, h * .70)
      ..close();
    canvas.drawPath(body, fill);
    // 水波纹
    final wave = Path()
      ..moveTo(w * .08, h * .95)
      ..quadraticBezierTo(w * .25, h * .88, w * .42, h * .95)
      ..quadraticBezierTo(w * .58, h * 1.01, w * .75, h * .95);
    canvas.drawPath(wave, paint);
  }

  @override
  bool shouldRepaint(covariant _BoatPainter old) => old.color != color;
}
