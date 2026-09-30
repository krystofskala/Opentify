import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../../theme/glass_tokens.dart';
import '../glass_container.dart';
import 'glass_button.dart';
import 'glass_pressable.dart';

/// Vyhledávací pole (kapsle 44). HIG Search fields
/// (https://developer.apple.com/design/human-interface-guidelines/search-fields):
/// - zástupný text říká, CO lze hledat ("Use placeholder text to help people
///   know what they can search for"),
/// - hledat hned při psaní ("start search immediately when a person types"),
/// - nabízet nedávná hledání / návrhy ([GlassSuggestionsPanel]),
/// - lupa vlevo v barvě sekundárního popisku, mazací tlačítko jen když je
///   text, "Zrušit" (cancel) při fokusu vymaže a zavře klávesnici.
/// `glass: true` jen v plovoucí liště (HIG Materials); inline filtr v obsahu
/// je plochá kapsle (`glass: false`).
class GlassSearchField extends StatefulWidget {
  const GlassSearchField({
    super.key,
    this.controller,
    required this.hintText,
    this.focusNode,
    this.onChanged,
    this.onSubmitted,
    this.onCleared,
    this.autofocus = false,
    this.glass = true,
    this.showCancel = true,
    this.compact = false,
    this.leadingIcon = Symbols.search_rounded,
  });

  final TextEditingController? controller;
  final String hintText;
  final FocusNode? focusNode;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmitted;

  /// Po mazacím tlačítku i po "Zrušit".
  final VoidCallback? onCleared;
  final bool autofocus;
  final bool glass;
  final bool showCancel;

  /// Výška 36 místo 44 (inline filtr nad seznamem; dotyková plocha zůstává
  /// dost velká díky šířce pole).
  final bool compact;
  final IconData leadingIcon;

  @override
  State<GlassSearchField> createState() => _GlassSearchFieldState();
}

class _GlassSearchFieldState extends State<GlassSearchField> {
  FocusNode? _ownFocus;
  FocusNode get _focus => widget.focusNode ?? (_ownFocus ??= FocusNode());
  TextEditingController? _ownController;
  TextEditingController get _controller => widget.controller ?? (_ownController ??= TextEditingController());

  @override
  void initState() {
    super.initState();
    _focus.addListener(_rebuild);
    _controller.addListener(_rebuild);
  }

  @override
  void dispose() {
    _focus.removeListener(_rebuild);
    _controller.removeListener(_rebuild);
    _ownFocus?.dispose();
    _ownController?.dispose();
    super.dispose();
  }

  void _rebuild() {
    if (mounted) setState(() {});
  }

  void _clear() {
    _controller.clear();
    widget.onChanged?.call('');
    widget.onCleared?.call();
  }

  void _cancel() {
    _clear();
    _focus.unfocus();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final secondary = theme.colorScheme.onSurfaceVariant;
    final height = widget.compact ? GlassTokens.compactControlHeight : GlassTokens.controlHeight;
    final radius = BorderRadius.circular(height / 2);
    final hasText = _controller.text.isNotEmpty;

    final field = SizedBox(
      height: height,
      child: Row(
        children: [
          const SizedBox(width: 12),
          Icon(widget.leadingIcon, size: 20, color: secondary),
          const SizedBox(width: 8),
          Expanded(
            child: TextField(
              controller: _controller,
              focusNode: _focus,
              autofocus: widget.autofocus,
              onChanged: widget.onChanged,
              onSubmitted: widget.onSubmitted,
              textInputAction: TextInputAction.search,
              style: theme.textTheme.bodyLarge,
              decoration: InputDecoration(
                hintText: widget.hintText,
                hintStyle: theme.textTheme.bodyLarge?.copyWith(color: secondary),
                isCollapsed: true,
                filled: false,
                border: InputBorder.none,
                enabledBorder: InputBorder.none,
                focusedBorder: InputBorder.none,
              ),
            ),
          ),
          AnimatedSwitcher(
            duration: GlassTokens.stateDuration,
            child: hasText
                ? GlassPressable(
                    key: const ValueKey('clear'),
                    onPressed: _clear,
                    tooltip: 'Vymazat',
                    shape: const CircleBorder(),
                    semanticLabel: 'Vymazat',
                    child: Icon(Symbols.cancel_rounded, size: 18, color: secondary),
                  )
                : const SizedBox(width: 12),
          ),
        ],
      ),
    );

    final capsule = widget.glass
        ? GlassContainer(borderRadius: radius, liquid: true, child: field)
        : DecoratedBox(decoration: ShapeDecoration(shape: glassShape(radius), color: tonalFill(context)), child: field);

    return Row(
      children: [
        Expanded(child: capsule),
        AnimatedSize(
          duration: Motion.enter.duration,
          curve: Motion.enter,
          child: widget.showCancel && _focus.hasFocus
              ? Padding(
                  padding: const EdgeInsets.only(left: 4),
                  child: GlassButton(label: 'Zrušit', style: GlassButtonStyle.plain, compact: true, onPressed: _cancel),
                )
              : const SizedBox.shrink(),
        ),
      ],
    );
  }
}

/// Panel návrhů pod vyhledávacím polem (plovoucí -- sklo + stín).
/// Poloměr `GlassTokens.panelRadius`.
class GlassSuggestionsPanel extends StatelessWidget {
  const GlassSuggestionsPanel({super.key, required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Material(
      type: MaterialType.transparency,
      child: GlassContainer(
        borderRadius: const BorderRadius.all(Radius.circular(GlassTokens.panelRadius)),
        shadow: true,
        liquid: true,
        child: ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.symmetric(vertical: 4),
          children: children,
        ),
      ),
    );
  }
}
