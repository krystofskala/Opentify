import 'package:flutter/widgets.dart';

import 'safe_area_insets_stub.dart' if (dart.library.js_interop) 'safe_area_insets_web.dart' as impl;

/// Flutter web na iPhonu nehlásí výřez/home indikátor do `MediaQuery`
/// (`padding` je nula) -- appka pak buď kreslí pod hodiny, nebo se musí
/// celá odsadit a pod status barem/home indikátorem zůstane prázdný pruh.
/// Tohle přečte skutečné `env(safe-area-inset-*)` z prohlížeče a doplní je
/// do `MediaQuery`, takže pozadí jde přes celou obrazovku (i pod hodiny),
/// ale `SafeArea`/`Scaffold`/navigace obsah správně odsadí.
class WebSafeAreaInsets extends StatefulWidget {
  const WebSafeAreaInsets({super.key, required this.child});

  final Widget child;

  @override
  State<WebSafeAreaInsets> createState() => _WebSafeAreaInsetsState();
}

class _WebSafeAreaInsetsState extends State<WebSafeAreaInsets> with WidgetsBindingObserver {
  EdgeInsets _insets = impl.readSafeAreaInsets();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeMetrics() {
    // Otočení telefonu / změna velikosti okna.
    final next = impl.readSafeAreaInsets();
    if (next != _insets) setState(() => _insets = next);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    if (_insets == EdgeInsets.zero) return widget.child;
    EdgeInsets merge(EdgeInsets base) => EdgeInsets.fromLTRB(
          base.left > _insets.left ? base.left : _insets.left,
          base.top > _insets.top ? base.top : _insets.top,
          base.right > _insets.right ? base.right : _insets.right,
          base.bottom > _insets.bottom ? base.bottom : _insets.bottom,
        );
    return MediaQuery(
      data: media.copyWith(padding: merge(media.padding), viewPadding: merge(media.viewPadding)),
      child: widget.child,
    );
  }
}
