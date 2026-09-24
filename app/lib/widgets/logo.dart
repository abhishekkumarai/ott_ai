import 'package:flutter/widgets.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

import '../theme.dart';

class Logo extends StatelessWidget {
  const Logo({super.key, this.size = 16});
  final double size;

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        CustomPaint(size: Size.square(size + 4), painter: _Mark(theme.colorScheme.foreground)),
        SizedBox(width: size * 0.5),
        Text(
          'Reel',
          style: theme.textTheme.large.copyWith(fontSize: size, fontWeight: FontWeight.w600, letterSpacing: -0.3),
        ),
      ],
    );
  }
}

class _Mark extends CustomPainter {
  _Mark(this.color);
  final Color color;

  @override
  void paint(Canvas canvas, Size s) {
    final frame = RRect.fromRectAndRadius(
      Rect.fromLTWH(s.width * .08, s.height * .17, s.width * .84, s.height * .66),
      Radius.circular(s.width * .13),
    );
    canvas.drawRRect(frame, Paint()..color = color);
    final tri = Path()
      ..moveTo(s.width * .42, s.height * .37)
      ..lineTo(s.width * .64, s.height * .5)
      ..lineTo(s.width * .42, s.height * .63)
      ..close();
    canvas.drawPath(tri, Paint()..color = accent);
  }

  @override
  bool shouldRepaint(_Mark old) => old.color != color;
}
