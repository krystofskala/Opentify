import 'package:flutter/material.dart';

import '../../theme/glass_tokens.dart';
import '../glass_container.dart';

/// Otevře sheet na kořenovém navigátoru (nad plovoucí navigací) --
/// jednotný vstup pro všechny sheety/menu v appce.
Future<T?> showGlassSheet<T>(BuildContext context, {required WidgetBuilder builder}) {
  return showModalBottomSheet<T>(
    context: context,
    useRootNavigator: true,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    elevation: 0,
    // Jedna animace pro všechny sheety (pružné vysunutí, rychlé zasunutí).
    sheetAnimationStyle: Motion.sheet,
    builder: builder,
  );
}

/// Skleněný sheet. HIG Sheets
/// (https://developer.apple.com/design/human-interface-guidelines/sheets):
/// - úchyt ("Include a grabber in a resizable sheet"),
/// - swipe dolů zavírá ("Support swiping to dismiss a sheet"),
/// - velké horní rohy (`GlassTokens.sheetRadius`), stejný materiál jako
///   ostatní plovoucí vrstva; plochy přehrávače (`tint`) jemně tónované
///   barvou skladby.
/// `expand: true` pro obsah uvnitř `DraggableScrollableSheet`.
class GlassSheet extends StatelessWidget {
  const GlassSheet({
    super.key,
    required this.child,
    this.tint,
    this.expand = false,
    this.showGrabber = true,
  });

  final Widget child;
  final Color? tint;
  final bool expand;
  final bool showGrabber;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final grabber = Padding(
      padding: const EdgeInsets.only(top: 6, bottom: 6),
      child: Center(
        child: Container(
          width: GlassTokens.grabberSize.width,
          height: GlassTokens.grabberSize.height,
          decoration: BoxDecoration(
            color: (isDark ? Colors.white : Colors.black).withValues(alpha: 0.3),
            borderRadius: BorderRadius.circular(3),
          ),
        ),
      ),
    );
    final body = Column(
      mainAxisSize: expand ? MainAxisSize.max : MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (showGrabber) grabber,
        // Obsah nad home indikátorem, pozadí sheetu až k okraji.
        if (expand)
          Expanded(child: SafeArea(top: false, child: child))
        else
          Flexible(child: SafeArea(top: false, child: child)),
      ],
    );
    const radius = BorderRadius.vertical(top: Radius.circular(GlassTokens.sheetRadius));
    // Všechny sheety stejné sklo jako lišty (i s lemem); `tint` už nic nemění.
    return GlassContainer(rim: true, borderRadius: radius, fit: expand ? StackFit.expand : StackFit.loose, child: body);
  }
}
