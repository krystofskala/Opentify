import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';
import 'package:go_router/go_router.dart';

/// Rozbalování přehrávače jako interaktivní "sheet" (jako Apple Music):
/// tažení mini přehrávače nahoru ho vysouvá přesně pod prstem, puštění
/// dokončí pružinou podle rychlosti (nebo ho vrátí zpět), tažení dolů v
/// rozbaleném přehrávači ho stejně zasune.
///
/// Stránka `/now-playing` zůstává skutečnou trasou (hluboký odkaz, systémové
/// "zpět"), jen bez vlastní animace -- polohu řídí jediný
/// `AnimationController` tady (0 = zasunuto, 1 = rozbaleno), který sdílí
/// mini přehrávač (začátek tažení) i přehrávač (dokončení/zasunutí). Hostitel
/// sedí nad Navigatorem (`app.dart` builder), takže je dostupný z každé trasy.
class NowPlayingSheetHost extends StatefulWidget {
  const NowPlayingSheetHost({super.key, required this.child});

  final Widget child;

  @override
  State<NowPlayingSheetHost> createState() => _NowPlayingSheetHostState();
}

class _NowPlayingSheetHostState extends State<NowPlayingSheetHost> with SingleTickerProviderStateMixin {
  late final NowPlayingSheetController _controller = NowPlayingSheetController._(
    AnimationController(vsync: this, duration: const Duration(milliseconds: 380)),
  );

  @override
  void dispose() {
    _controller._anim.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => _NowPlayingSheetScope(controller: _controller, child: widget.child);
}

class _NowPlayingSheetScope extends InheritedWidget {
  const _NowPlayingSheetScope({required this.controller, required super.child});

  final NowPlayingSheetController controller;

  @override
  bool updateShouldNotify(_NowPlayingSheetScope oldWidget) => controller != oldWidget.controller;
}

class NowPlayingSheetController {
  NowPlayingSheetController._(this._anim);

  final AnimationController _anim;

  /// 0 = zasunuto, 1 = rozbaleno.
  Animation<double> get position => _anim;

  static NowPlayingSheetController of(BuildContext context) {
    final scope = context.getInheritedWidgetOfExactType<_NowPlayingSheetScope>();
    assert(scope != null, 'NowPlayingSheetHost chybí nad Navigatorem');
    return scope!.controller;
  }

  // M3 Expressive "spatial default" pružina -- lehce živá, bez překmitu.
  static const _spring = SpringDescription(mass: 1, stiffness: 380, damping: 36);

  bool _routeOpen = false;
  bool _pushing = false;
  bool dragging = false;
  VoidCallback? _popRoute;

  /// Volá `NowPlayingScreen` při připojení/odpojení -- umí zavřít svou trasu.
  void attach(VoidCallback popRoute) {
    _routeOpen = true;
    _pushing = false;
    _popRoute = popRoute;
  }

  void detach(VoidCallback popRoute) {
    if (_popRoute != popRoute) return;
    _routeOpen = false;
    _popRoute = null;
    if (!dragging) _anim.value = 0;
  }

  bool get isOpen => _routeOpen;

  void _ensureRoute(BuildContext context) {
    if (_routeOpen || _pushing) return;
    _pushing = true;
    context.push('/now-playing');
  }

  /// Klepnutí na mini přehrávač.
  void open(BuildContext context) {
    _ensureRoute(context);
    _settle(1, 0);
  }

  /// Hluboký odkaz / trasa otevřená bez tažení -- vysunout.
  void revealIfIdle() {
    if (!dragging && _anim.value < 1 && !_anim.isAnimating) _settle(1, 0);
  }

  void close() => _settle(0, 0);

  void dragStart(BuildContext context) {
    dragging = true;
    _anim.stop();
    _ensureRoute(context);
  }

  /// `dy` v logických px (kladné = dolů), `height` = výška obrazovky.
  void dragUpdate(double dy, double height) {
    if (height <= 0) return;
    _anim.value = (_anim.value - dy / height).clamp(0.0, 1.0);
  }

  /// `velocity` v px/s (kladné = dolů).
  void dragEnd(double velocity, double height) {
    dragging = false;
    final v = height <= 0 ? 0.0 : -velocity / height;
    final double target;
    if (v.abs() > 0.9) {
      target = v > 0 ? 1 : 0;
    } else {
      target = _anim.value > 0.5 ? 1 : 0;
    }
    _settle(target, v);
  }

  void _settle(double target, double velocity) {
    final sim = SpringSimulation(_spring, _anim.value, target, velocity)..tolerance = const Tolerance(distance: 0.001, velocity: 0.01);
    _anim.animateWith(sim).whenCompleteOrCancel(() {
      if (dragging || _anim.isAnimating) return;
      if (target == 0 && _anim.value <= 0.001) {
        _anim.value = 0;
        final pop = _popRoute;
        if (pop != null) pop();
      }
    });
  }
}
