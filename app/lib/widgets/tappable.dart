import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

/// A tappable surface (card, list row) with shadcn hover styling, a click cursor,
/// keyboard focus (Enter/Space activate) and a focus ring. Replaces Material InkWell.
class Tappable extends StatefulWidget {
  const Tappable({
    super.key,
    required this.child,
    required this.onTap,
    this.selected = false,
    this.radius = 12,
    this.padding = EdgeInsets.zero,
    this.semanticLabel,
  });

  final Widget child;
  final VoidCallback? onTap;
  final bool selected;
  final double radius;
  final EdgeInsetsGeometry padding;
  final String? semanticLabel;

  @override
  State<Tappable> createState() => _TappableState();
}

class _TappableState extends State<Tappable> {
  bool _hover = false;
  bool _focus = false;

  @override
  Widget build(BuildContext context) {
    final cs = ShadTheme.of(context).colorScheme;
    final enabled = widget.onTap != null;
    final bg = widget.selected
        ? cs.accent
        : (_hover && enabled ? cs.accent.withValues(alpha: .6) : null);
    return Semantics(
      button: enabled,
      selected: widget.selected,
      label: widget.semanticLabel,
      child: FocusableActionDetector(
        enabled: enabled,
        onShowFocusHighlight: (v) => setState(() => _focus = v),
        actions: {
          ActivateIntent: CallbackAction<ActivateIntent>(
            onInvoke: (_) {
              widget.onTap?.call();
              return null;
            },
          ),
        },
        child: ShadGestureDetector(
          cursor: enabled ? SystemMouseCursors.click : MouseCursor.defer,
          onHoverChange: (v) => setState(() => _hover = v),
          onTap: widget.onTap,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            padding: widget.padding,
            decoration: BoxDecoration(
              color: bg,
              borderRadius: BorderRadius.circular(widget.radius),
              border: Border.all(
                color: _focus ? cs.ring : const Color(0x00000000),
                width: 1.5,
              ),
            ),
            child: widget.child,
          ),
        ),
      ),
    );
  }
}

/// A secondary action (e.g. delete) shown only while its row is hovered.
///
/// Hidden means untappable too, so a tap on the row can't hit an invisible
/// button; without a mouse (touch screens) there is no hover, so it is always shown.
class HoverReveal extends StatefulWidget {
  const HoverReveal({super.key, required this.hovered, required this.child});
  final bool hovered;
  final Widget child;

  @override
  State<HoverReveal> createState() => _HoverRevealState();
}

class _HoverRevealState extends State<HoverReveal> {
  MouseTracker get _mouse => RendererBinding.instance.mouseTracker;

  @override
  void initState() {
    super.initState();
    _mouse.addListener(_changed);
  }

  @override
  void dispose() {
    _mouse.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final show = widget.hovered || !_mouse.mouseIsConnected;
    return IgnorePointer(
      ignoring: !show,
      child: Opacity(opacity: show ? 1 : 0, child: widget.child),
    );
  }
}
