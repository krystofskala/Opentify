import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../theme/glass_tokens.dart';
import '../widgets/glass/glass.dart';
import '../widgets/glass/liquid_glass.dart';
import '../widgets/glass_container.dart';
import '../widgets/now_playing_sheet.dart' show HiddenUnderPlayer;
import '../widgets/player_bar.dart';
import 'branches.dart';

/// Bottom-nav shell pro čtyři hlavní destinace (Domů/Hledat/Knihovna/Profil).
/// Detaily (interpret, album, playlist...) se otevírají UVNITŘ záložky
/// (`branches.dart`) -- tab bar je vidět všude a každá záložka si pamatuje
/// svou rozkliknutou cestu.
///
/// Plovoucí skleněný tab bar + mini přehrávač nad ním (HIG Tab bars: "a tab
/// bar floats above content"), `extendBody` -- obsah pod nimi pokračuje a
/// prosvítá rozmazaný. Scaffold posílá jejich výšku jako
/// `MediaQuery.padding.bottom`, kterou si seznamy přičítají (`navBottomInset`).
///
/// Jako iOS 26: posouvání obsahu dolů tab bar smrští do kapsle s ikonou
/// záložky vlevo od mini přehrávače (víc místa na obsah); posun nahoru,
/// začátek stránky, nová stránka nebo klepnutí na kapsli ho zase rozbalí.
class HomeShell extends StatefulWidget {
  const HomeShell({super.key, required this.navigationShell});

  final StatefulNavigationShell navigationShell;

  static const tabs = [
    GlassTabItem(icon: Symbols.home_rounded, label: 'Domů'),
    GlassTabItem(icon: Symbols.search_rounded, label: 'Hledat'),
    GlassTabItem(icon: Symbols.library_music_rounded, label: 'Knihovna'),
    GlassTabItem(icon: Symbols.person_rounded, label: 'Profil'),
  ];

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> with SingleTickerProviderStateMixin {
  // 0 = rozbalený tab bar, 1 = smrštěný do kapsle.
  late final AnimationController _collapse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 280),
    reverseDuration: const Duration(milliseconds: 240),
  );
  late final Animation<double> _t = CurvedAnimation(parent: _collapse, curve: Curves.easeOutCubic);
  bool _collapsed = false;
  double _travel = 0; // kolik px se posunulo jedním směrem
  GoRouterDelegate? _delegate;

  // Kolik posunu stačí: dolů schválně víc (ne při každém dotyku), nahoru
  // méně (návrat k navigaci má být po ruce).
  static const _collapseAfter = 56.0;
  static const _expandAfter = 24.0;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final delegate = GoRouter.of(context).routerDelegate;
    if (delegate != _delegate) {
      _delegate?.removeListener(_onNavigate);
      _delegate = delegate..addListener(_onNavigate);
    }
  }

  @override
  void dispose() {
    _delegate?.removeListener(_onNavigate);
    _collapse.dispose();
    super.dispose();
  }

  // Nová stránka / zpět / jiná záložka: navigace zase celá.
  void _onNavigate() => _setCollapsed(false);

  void _setCollapsed(bool collapsed) {
    _travel = 0;
    if (collapsed == _collapsed) return;
    _collapsed = collapsed;
    collapsed ? _collapse.forward() : _collapse.reverse();
  }

  bool _onScroll(ScrollNotification n) {
    if (n is! ScrollUpdateNotification || n.metrics.axis != Axis.vertical) return false;
    // Široké okno (desktop): místa dost, lišta zůstává.
    if (MediaQuery.sizeOf(context).width >= 600) return false;
    final m = n.metrics;
    if (m.pixels <= m.minScrollExtent + 24) {
      _setCollapsed(false);
      return false;
    }
    // Krátká stránka: není co odkrývat.
    if (m.maxScrollExtent - m.minScrollExtent < 240) return false;
    // Dojel na konec (pružný přetah) -- nic nepřepínat.
    if (m.pixels >= m.maxScrollExtent) return false;
    final delta = n.scrollDelta ?? 0;
    if (delta == 0) return false;
    if (delta.sign != _travel.sign) _travel = 0;
    _travel += delta;
    if (!_collapsed && _travel > _collapseAfter) {
      _setCollapsed(true);
    } else if (_collapsed && _travel < -_expandAfter) {
      _setCollapsed(false);
    }
    return false;
  }

  void _select(int index) {
    final shell = widget.navigationShell;
    // Před `goBranch`: cesta rozkliknutého detailu té záložky se nesmí
    // přepsat do záložky, ze které se odchází (`branchRedirect`).
    currentBranch = index;
    // Znovu klepnutý aktivní tab = zpět na jeho první stránku (iOS).
    shell.goBranch(index, initialLocation: index == shell.currentIndex);
    _setCollapsed(false);
  }

  @override
  Widget build(BuildContext context) {
    final shell = widget.navigationShell;
    currentBranch = shell.currentIndex;
    // `LiquidScope` + `LiquidSource.page`: obsah stránky pod lištami jde
    // zachytit pro sklo s lomem (Profil › Vzhled › "Lom skla (test)").
    return HiddenUnderPlayer(
      child: LiquidScope(
        child: Scaffold(
          extendBody: true,
          body: NotificationListener<ScrollNotification>(
            onNotification: _onScroll,
            child: LiquidSource.page(child: shell),
          ),
          // Na širokém okně plovoucí skupina (přehrávač + tab bar) uprostřed s
          // omezenou šířkou -- ne pruh přes celých 2000 px.
          bottomNavigationBar: Align(
            alignment: Alignment.bottomCenter,
            heightFactor: 1,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: kFloatingBarMaxWidth),
              child: AnimatedBuilder(
                animation: _t,
                builder: (context, _) => _bars(context, _t.value),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _bars(BuildContext context, double t) {
    const pill = GlassTokens.tabBarHeight;
    const gap = 8.0;
    final safeBottom = MediaQuery.paddingOf(context).bottom;
    final shell = widget.navigationShell;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Stack(
          children: [
            // Mini přehrávač; ve smrštěném stavu uhne kapsli záložky.
            ConstrainedBox(
              constraints: BoxConstraints(minHeight: t * (pill + 8)),
              child: Padding(
                padding: EdgeInsets.only(left: t * (pill + gap)),
                // Vlastní měkký stín i u mini přehrávače -- průhledné sklo se
                // jinak na tmavé stránce slévalo s okolím (živě nahlášeno).
                child: MediaQuery.removePadding(
                  context: context,
                  removeBottom: true,
                  // Mini přehrávač při prvním puštění vyjede, po zavření
                  // zajede -- dřív se tab bar skokem posunul.
                  child: AnimatedSize(
                    duration: Motion.sheetIn.duration,
                    curve: Motion.sheetIn,
                    alignment: Alignment.bottomCenter,
                    child: const PlayerBar(),
                  ),
                ),
              ),
            ),
            if (t > 0)
              Positioned(
                left: GlassTokens.floatingMargin,
                top: 0,
                bottom: 8,
                width: pill,
                child: Center(
                  child: Opacity(
                    opacity: t,
                    child: Transform.scale(
                      scale: 0.7 + 0.3 * t,
                      child: _TabPill(
                        item: HomeShell.tabs[shell.currentIndex],
                        onTap: t > 0.5 ? () => _setCollapsed(false) : null,
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
        // Tab bar zajede dolů a zeslábne.
        ClipRect(
          child: Align(
            alignment: Alignment.topCenter,
            heightFactor: 1 - t,
            child: IgnorePointer(
              ignoring: t > 0.5,
              child: Opacity(
                opacity: (1 - t * 1.4).clamp(0.0, 1.0),
                child: GlassTabBar(
                  items: HomeShell.tabs,
                  selectedIndex: shell.currentIndex,
                  onSelected: _select,
                ),
              ),
            ),
          ),
        ),
        // Smrštěno: přehrávač sedí tam, kde byl spodní okraj tab baru.
        SizedBox(height: t * (safeBottom + GlassTokens.floatingBottomGap)),
      ],
    );
  }
}

/// Smrštěný tab bar: skleněná kapsle s ikonou aktuální záložky.
class _TabPill extends StatelessWidget {
  const _TabPill({required this.item, required this.onTap});

  final GlassTabItem item;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    const size = GlassTokens.tabBarHeight;
    return Semantics(
      button: true,
      label: 'Zobrazit navigaci (${item.label})',
      excludeSemantics: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap == null
            ? null
            : () {
                HapticFeedback.selectionClick();
                onTap!();
              },
        child: GlassContainer(
          borderRadius: const BorderRadius.all(Radius.circular(size / 2)),
          shadow: true,
          rim: true,
          liquid: true,
          child: SizedBox(
            width: size,
            height: size,
            child: Icon(item.icon, size: 26, fill: 1, color: Theme.of(context).colorScheme.primary),
          ),
        ),
      ),
    );
  }
}

/// Spodní odsazení seznamů na hlavních tabech -- obsah pod plovoucím tab
/// barem (`HomeShell.extendBody`) se jinak na konci schová pod něj. Mimo
/// shell (detaily s vlastní lištou přehrávače) je to 0.
double navBottomInset(BuildContext context) => MediaQuery.paddingOf(context).bottom;
