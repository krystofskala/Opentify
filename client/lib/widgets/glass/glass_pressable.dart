import 'package:flutter/material.dart';

import '../../theme/glass_tokens.dart';

/// Společné chování stisku pro všechny ovládací prvky v `widgets/glass/`:
/// - dotyková plocha min. 44×44 (HIG Buttons: "a button needs a hit region
///   of at least 44x44 pt"),
/// - stisk: zmenšení na `GlassTokens.pressedScale` + světlý závoj
///   (HIG Buttons: "Always include a press state for a custom button"),
/// - nedostupný stav: `GlassTokens.disabledOpacity`,
/// - fokus z klávesnice: 2px kroužek v barvě akcentu,
/// - sémantika tlačítka (čtečky obrazovky).
class GlassPressable extends StatefulWidget {
  const GlassPressable({
    super.key,
    this.child,
    this.builder,
    required this.onPressed,
    this.onLongPress,
    this.shape = const StadiumBorder(),
    this.semanticLabel,
    this.selected,
    this.tooltip,
    this.minSize = const Size(GlassTokens.minHitTarget, GlassTokens.minHitTarget),
    this.highlightColor,
    this.squish = false,
  });

  final Widget? child;

  /// Alternativa k `child`, dostává stav stisku -- pro M3 Expressive
  /// morfologii tvaru (tlačítko při stisku zmáčkne rohy).
  final Widget Function(BuildContext context, bool pressed)? builder;
  final VoidCallback? onPressed;
  final VoidCallback? onLongPress;
  final OutlinedBorder shape;
  final String? semanticLabel;
  final bool? selected;
  final String? tooltip;
  final Size minSize;
  final Color? highlightColor;

  /// M3 Expressive morfologie stisku pro libovolného potomka: při stisku se
  /// kapsle ořízne na rohy `Expressive.pressedCornerFraction` × výška
  /// (pružina `Motion.press`) a po puštění se vrátí. Opt-in -- prvky, které
  /// si tvar morfují samy (`GlassButton`), ho nepotřebují.
  final bool squish;

  @override
  State<GlassPressable> createState() => _GlassPressableState();
}

class _GlassPressableState extends State<GlassPressable> {
  bool _pressed = false;
  bool _focused = false;

  bool get _enabled => widget.onPressed != null;

  void _setPressed(bool value) {
    if (_pressed != value && mounted) setState(() => _pressed = value);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final highlight = widget.highlightColor ??
        (theme.brightness == Brightness.dark ? Colors.white : Colors.black)
            .withValues(alpha: GlassTokens.pressedHighlight);

    Widget pressedChild = widget.builder?.call(context, _pressed) ?? widget.child!;
    if (widget.squish) pressedChild = _SquishClip(pressed: _pressed, child: pressedChild);

    Widget content = AnimatedScale(
      scale: _pressed ? GlassTokens.pressedScale : 1,
      duration: Motion.press.duration,
      curve: Motion.press,
      child: Stack(
        alignment: Alignment.center,
        children: [
          pressedChild,
          Positioned.fill(
            child: IgnorePointer(
              child: AnimatedOpacity(
                opacity: _pressed ? 1 : 0,
                duration: GlassTokens.stateDuration,
                child: DecoratedBox(decoration: ShapeDecoration(shape: widget.shape, color: highlight)),
              ),
            ),
          ),
          if (_focused)
            Positioned.fill(
              child: IgnorePointer(
                child: DecoratedBox(
                  decoration: ShapeDecoration(
                    shape: widget.shape.copyWith(side: BorderSide(color: theme.colorScheme.primary, width: 2)),
                  ),
                ),
              ),
            ),
        ],
      ),
    );

    content = AnimatedOpacity(
      opacity: _enabled ? 1 : GlassTokens.disabledOpacity,
      duration: GlassTokens.stateDuration,
      child: content,
    );

    content = FocusableActionDetector(
      enabled: _enabled,
      mouseCursor: _enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
      onShowFocusHighlight: (value) => setState(() => _focused = value),
      actions: {
        ActivateIntent: CallbackAction<ActivateIntent>(onInvoke: (_) {
          widget.onPressed?.call();
          return null;
        }),
      },
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: _enabled ? (_) => _setPressed(true) : null,
        onTapUp: _enabled ? (_) => _setPressed(false) : null,
        onTapCancel: _enabled ? () => _setPressed(false) : null,
        onTap: widget.onPressed,
        onLongPress: widget.onLongPress,
        child: ConstrainedBox(
          constraints: BoxConstraints(minWidth: widget.minSize.width, minHeight: widget.minSize.height),
          child: Center(widthFactor: 1, heightFactor: 1, child: content),
        ),
      ),
    );

    content = Semantics(
      button: true,
      enabled: _enabled,
      selected: widget.selected,
      label: widget.semanticLabel,
      child: content,
    );

    if (widget.tooltip != null) content = Tooltip(message: widget.tooltip!, child: content);
    return content;
  }
}

/// Ořez potomka tvarem, který při stisku zmáčkne rohy z kapsle na
/// `Expressive.pressedCornerFraction` výšky -- pružinou `Motion.press`.
/// Poloměr se počítá ze skutečné velikosti potomka (clipper), ne z omezení.
class _SquishClip extends StatelessWidget {
  const _SquishClip({required this.pressed, required this.child});

  final bool pressed;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween(end: pressed ? 1 : 0),
      duration: Motion.press.duration,
      curve: Motion.press,
      child: child,
      builder: (context, t, child) => ClipRRect(clipper: _SquishClipper(t), child: child),
    );
  }
}

class _SquishClipper extends CustomClipper<RRect> {
  const _SquishClipper(this.t);

  final double t;

  @override
  RRect getClip(Size size) {
    final capsule = size.shortestSide / 2;
    final pressed = size.height * Expressive.pressedCornerFraction;
    final radius = (capsule + (pressed - capsule) * t).clamp(0.0, capsule);
    return RRect.fromRectAndRadius(Offset.zero & size, Radius.circular(radius));
  }

  @override
  bool shouldReclip(_SquishClipper oldClipper) => oldClipper.t != t;
}
