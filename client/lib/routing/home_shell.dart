import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/physics.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../theme/glass_tokens.dart';
import '../widgets/glass/glass.dart';
import '../widgets/glass/liquid_glass.dart';
import '../widgets/now_playing_sheet.dart' show HiddenUnderPlayer;
import '../widgets/player_bar.dart';
import 'branches.dart';
import '../core/app_update.dart';
import '../widgets/app_update_sheet.dart';

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
/// Jako Apple Music (iOS 26): posouvání obsahu dolů tab bar smrští do kapsle
/// s ikonou záložky vlevo od mini přehrávače. Zpátky se rozbalí až na
/// úplném začátku stránky s malým přetažením nahoru (ne hned při posunu
/// nahoru), na nové stránce, klepnutím na kapsli -- nebo podržením/tahem
/// kapsle, který lištu rozbalí a prst rovnou táhne kapku výběru.
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
  // Pružina místo pevné křivky (jako Apple Music): přechod navazuje na
  // rozjetý pohyb a při změně směru uprostřed necukne.
  late final AnimationController _collapse = AnimationController.unbounded(vsync: this);
  Animation<double> get _t => _collapse;
  static final SpringDescription _morph = SpringDescription.withDampingRatio(mass: 1, stiffness: 320, ratio: 0.9);
  // Výška mini přehrávače (kam se kapsle ve smrštěném stavu zarovná).
  final GlobalKey _playerKey = GlobalKey();
  bool _collapsed = false;
  double _travel = 0; // kolik px se posunulo jedním směrem
  GoRouterDelegate? _delegate;

  // Kolik posunu dolů stačí na smrštění (ne při každém dotyku).
  static const _collapseAfter = 56.0;
  // Přetažení za začátek stránky, které lištu rozbalí (iOS pružné přetažení
  // i Android/web overscroll).
  static const _expandOverscroll = 10.0;
  double _overscroll = 0;

  final GlobalKey<GlassTabBarState> _tabBar = GlobalKey();
  bool _pillDragging = false;

  @override
  void initState() {
    super.initState();
    // Android: nová verze na GitHubu -> nabídka (chvíli po startu, ať nebrzdí).
    if (appUpdatesSupported) {
      _updateTimer = Timer(const Duration(seconds: 4), () {
        if (mounted) offerAppUpdate(context);
      });
    }
  }

  Timer? _updateTimer;

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
    _updateTimer?.cancel();
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
    if (MediaQuery.disableAnimationsOf(context)) {
      _collapse.value = collapsed ? 1 : 0;
    } else {
      _collapse.animateWith(SpringSimulation(_morph, _collapse.value, collapsed ? 1 : 0, _collapse.velocity));
    }
  }

  bool _onScroll(ScrollNotification n) {
    if (n.metrics.axis != Axis.vertical) return false;
    // Široké okno (desktop): místa dost, lišta zůstává.
    if (MediaQuery.sizeOf(context).width >= 600) return false;
    final m = n.metrics;
    // Rozbalení: až na úplném začátku a kousek dál (Apple Music) -- posun
    // nahoru uprostřed stránky lištu nechá smrštěnou.
    if (n is OverscrollNotification) {
      if (_collapsed && n.overscroll < 0 && m.pixels <= m.minScrollExtent) {
        _overscroll -= n.overscroll;
        if (_overscroll >= _expandOverscroll) _setCollapsed(false);
      }
      return false;
    }
    if (n is ScrollEndNotification) _overscroll = 0;
    if (n is! ScrollUpdateNotification) return false;
    if (m.pixels < m.minScrollExtent - _expandOverscroll) {
      if (_collapsed) _setCollapsed(false);
      return false;
    }
    if (m.pixels <= m.minScrollExtent) return false;
    // Krátká stránka: není co odkrývat.
    if (m.maxScrollExtent - m.minScrollExtent < 240) return false;
    // Dojel na konec (pružný přetah) -- nic nepřepínat.
    if (m.pixels >= m.maxScrollExtent) return false;
    final delta = n.scrollDelta ?? 0;
    if (delta == 0) return false;
    if (delta.sign != _travel.sign) _travel = 0;
    _travel += delta;
    if (!_collapsed && _travel > _collapseAfter) _setCollapsed(true);
    return false;
  }

  // Kapsle: podržení / tah -> rozbalit a táhnout kapku výběru v liště.
  void _pillDragStart(Offset global) {
    if (_pillDragging) return;
    HapticFeedback.selectionClick();
    setState(() => _pillDragging = true);
    _setCollapsed(false);
    _tabBar.currentState?.beginExternalDrag(global);
  }

  void _pillDragUpdate(Offset global) => _tabBar.currentState?.updateExternalDrag(global);

  void _pillDragEnd(double velocityX) {
    if (!_pillDragging) return;
    _tabBar.currentState?.endExternalDrag(velocityX);
    setState(() => _pillDragging = false);
  }

  void _pillDragCancel() {
    if (!_pillDragging) return;
    _tabBar.currentState?.cancelExternalDrag();
    setState(() => _pillDragging = false);
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
                builder: (context, _) => _bars(context, _t.value.clamp(0.0, 1.0)),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// Mini přehrávač + tab bar. Smršťování je "morf" jako v Apple Music:
  /// skleněná kapsle lišty se plynule zúží a posune do kulatého tlačítka
  /// vlevo od přehrávače (obsah lišty rychle zmizí, ikona záložky se objeví
  /// až na konci), přehrávač mezitím sjede do řádku lišty.
  Widget _bars(BuildContext context, double t) {
    const pill = GlassTokens.tabBarHeight;
    const gap = 8.0;
    const margin = GlassTokens.floatingMargin;
    final safeBottom = MediaQuery.paddingOf(context).bottom;
    final bottom = safeBottom + GlassTokens.floatingBottomGap;
    final shell = widget.navigationShell;
    // Obsah lišty zmizí v první třetině, ikona kapsle se objeví v poslední.
    final barOpacity = (1 - t / 0.35).clamp(0.0, 1.0);
    final pillOpacity = ((t - 0.75) / 0.25).clamp(0.0, 1.0);
    // Tah z kapsle: lišta hned viditelná (kapka pod prstem), bez morfu.
    final morphing = !_pillDragging && t > 0.001 && t < 0.999;
    final barShown = _pillDragging ? (1 - t).clamp(0.0, 1.0) : (morphing ? 0.0 : barOpacity);
    final playerHeight = (_playerKey.currentContext?.size?.height ?? 0);
    final rowHeight = playerHeight > pill + 8 ? playerHeight : pill + 8;

    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        // Kapsle: z celé lišty (dole) do kulatého tlačítka (střed řádku
        // přehrávače ve smrštěném stavu) -- souřadnice od spodního okraje.
        final fromBottom = bottom;
        final toBottom = bottom + 8 + (rowHeight - 8 - pill) / 2;
        final capsuleBottom = fromBottom + (toBottom - fromBottom) * t;
        final capsuleWidth = (width - 2 * margin) + (pill - (width - 2 * margin)) * t;
        return Stack(
          clipBehavior: Clip.none,
          children: [
            Column(
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
                            key: _playerKey,
                            duration: Motion.sheetIn.duration,
                            curve: Motion.sheetIn,
                            alignment: Alignment.bottomCenter,
                            child: const PlayerBar(),
                          ),
                        ),
                      ),
                    ),
                    // Při tahu z kapsle zůstává ve stromu (neviditelná), jinak by
                    // gesto skončilo s jejím zmizením.
                    if (t > 0.5 || _pillDragging)
                      Positioned(
                        left: margin,
                        top: 0,
                        bottom: 8,
                        width: pill,
                        child: Center(
                          child: Opacity(
                            opacity: morphing ? 0 : pillOpacity,
                            child: _TabPill(
                              item: HomeShell.tabs[shell.currentIndex],
                              onTap: () => _setCollapsed(false),
                              onDragStart: _pillDragStart,
                              onDragUpdate: _pillDragUpdate,
                              onDragEnd: _pillDragEnd,
                              onDragCancel: _pillDragCancel,
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
                // Lišta: výška se smršťuje (přehrávač sjede dolů), obsah
                // zmizí hned na začátku -- kapsli kreslí morf nad tím.
                ClipRect(
                  clipBehavior: t > 0 ? Clip.hardEdge : Clip.none,
                  child: Align(
                    alignment: Alignment.topCenter,
                    heightFactor: 1 - t,
                    child: IgnorePointer(
                      ignoring: t > 0.5 && !_pillDragging,
                      child: Opacity(
                        opacity: barShown,
                        child: GlassTabBar(
                          key: _tabBar,
                          items: HomeShell.tabs,
                          selectedIndex: shell.currentIndex,
                          onSelected: _select,
                        ),
                      ),
                    ),
                  ),
                ),
                // Smrštěno: přehrávač sedí tam, kde byl spodní okraj tab baru.
                SizedBox(height: t * bottom),
              ],
            ),
            // Morf: jedna skleněná kapsle během přechodu (ne dvě prolínající
            // se skla). Obsah lišty v ní dozní, ikona záložky se objeví.
            if (morphing)
              Positioned(
                left: margin,
                bottom: capsuleBottom,
                width: capsuleWidth,
                height: pill,
                child: IgnorePointer(
                  child: GlassContainer(
                    borderRadius: const BorderRadius.all(Radius.circular(pill / 2)),
                    shadow: true,
                    rim: true,
                    liquid: true,
                    systemGlass: true,
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        if (barOpacity > 0)
                          ClipRect(
                            child: OverflowBox(
                              alignment: Alignment.centerLeft,
                              maxWidth: width - 2 * margin,
                              minWidth: width - 2 * margin,
                              child: Opacity(
                                opacity: barOpacity,
                                child: _TabRowGhost(selected: shell.currentIndex),
                              ),
                            ),
                          ),
                        if (pillOpacity > 0)
                          Center(
                            child: Opacity(
                              opacity: pillOpacity,
                              child: Icon(
                                HomeShell.tabs[shell.currentIndex].icon,
                                size: 26,
                                fill: 1,
                                color: Theme.of(context).colorScheme.primary,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}

/// Ikony tabů bez skla a gest -- jen obsah, který v morfující kapsli dozní.
class _TabRowGhost extends StatelessWidget {
  const _TabRowGhost({required this.selected});

  final int selected;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Row(
      children: [
        for (var i = 0; i < HomeShell.tabs.length; i++)
          Expanded(
            child: Icon(
              HomeShell.tabs[i].icon,
              size: 24,
              fill: i == selected ? 1 : 0,
              color: i == selected ? scheme.primary : scheme.onSurfaceVariant,
            ),
          ),
      ],
    );
  }
}

/// Smrštěný tab bar: skleněná kapsle s ikonou aktuální záložky. Klepnutí
/// lištu rozbalí; podržení nebo vodorovný tah ji rozbalí a předá prst kapce
/// výběru v liště (`GlassTabBarState.beginExternalDrag`).
class _TabPill extends StatelessWidget {
  const _TabPill({
    required this.item,
    required this.onTap,
    required this.onDragStart,
    required this.onDragUpdate,
    required this.onDragEnd,
    required this.onDragCancel,
  });

  final GlassTabItem item;
  final VoidCallback? onTap;
  final ValueChanged<Offset> onDragStart;
  final ValueChanged<Offset> onDragUpdate;
  final ValueChanged<double> onDragEnd;
  final VoidCallback onDragCancel;

  @override
  Widget build(BuildContext context) {
    const size = GlassTokens.tabBarHeight;
    final tap = onTap;
    return Semantics(
      button: true,
      label: 'Zobrazit navigaci (${item.label})',
      excludeSemantics: true,
      child: RawGestureDetector(
        behavior: HitTestBehavior.opaque,
        gestures: {
          TapGestureRecognizer: GestureRecognizerFactoryWithHandlers<TapGestureRecognizer>(
            TapGestureRecognizer.new,
            (r) => r.onTap = tap == null
                ? null
                : () {
                    HapticFeedback.selectionClick();
                    tap();
                  },
          ),
          // Podržení (kratší než systémových 500 ms) a pak tah.
          LongPressGestureRecognizer: GestureRecognizerFactoryWithHandlers<LongPressGestureRecognizer>(
            () => LongPressGestureRecognizer(duration: const Duration(milliseconds: 220)),
            (r) => r
              ..onLongPressStart = ((d) => onDragStart(d.globalPosition))
              ..onLongPressMoveUpdate = ((d) => onDragUpdate(d.globalPosition))
              ..onLongPressEnd = ((d) => onDragEnd(d.velocity.pixelsPerSecond.dx))
              ..onLongPressCancel = onDragCancel,
          ),
          // Rovnou tah doprava po liště.
          HorizontalDragGestureRecognizer: GestureRecognizerFactoryWithHandlers<HorizontalDragGestureRecognizer>(
            HorizontalDragGestureRecognizer.new,
            (r) => r
              ..onStart = ((d) => onDragStart(d.globalPosition))
              ..onUpdate = ((d) => onDragUpdate(d.globalPosition))
              ..onEnd = ((d) => onDragEnd(d.primaryVelocity ?? 0))
              ..onCancel = onDragCancel,
          ),
        },
        child: GlassContainer(
          borderRadius: const BorderRadius.all(Radius.circular(size / 2)),
          shadow: true,
          rim: true,
          liquid: true,
          systemGlass: true,
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
