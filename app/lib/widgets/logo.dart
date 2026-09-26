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
        CustomPaint(
          size: Size.square(size + 4),
          painter: _Mark(theme.colorScheme.foreground),
        ),
        SizedBox(width: size * 0.5),
        Text(
          'OTT-AI',
          style: theme.textTheme.large.copyWith(
            fontSize: size,
            fontWeight: FontWeight.w700,
            letterSpacing: -0.4,
          ),
        ),
      ],
    );
  }
}

/// Just the mark, for the collapsed navigation rail.
class LogoMark extends StatelessWidget {
  const LogoMark({super.key, this.size = 20});
  final double size;

  @override
  Widget build(BuildContext context) => Semantics(
    label: 'OTT-AI',
    child: CustomPaint(
      size: Size.square(size),
      painter: _Mark(ShadTheme.of(context).colorScheme.foreground),
    ),
  );
}

class _Mark extends CustomPainter {
  _Mark(this.color);
  final Color color;

  @override
  void paint(Canvas canvas, Size s) {
    // Coral rounded tile with a white play triangle.
    final tile = RRect.fromRectAndRadius(
      Rect.fromLTWH(
        s.width * .04,
        s.height * .04,
        s.width * .92,
        s.height * .92,
      ),
      Radius.circular(s.width * .26),
    );
    canvas.drawRRect(tile, Paint()..color = coral);
    final tri = Path()
      ..moveTo(s.width * .40, s.height * .31)
      ..lineTo(s.width * .70, s.height * .5)
      ..lineTo(s.width * .40, s.height * .69)
      ..close();
    canvas.drawPath(tri, Paint()..color = const Color(0xFFFFFFFF));
  }

  @override
  bool shouldRepaint(_Mark old) => old.color != color;
}
