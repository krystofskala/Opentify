import 'dart:math' as math;

import 'dart:ui' show ImageFilter;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/physics.dart';

import '../../state/glass_settings.dart';
import '../../theme/glass_tokens.dart';
import '../glass_container.dart';
import '../../theme/design_tokens.dart';

class GlassTabItem {
  const GlassTabItem({required this.icon, required this.label});

  /// Obrysová varianta; vybraný tab se kreslí vyplněně (HIG Tab bars:
  /// "Prefer filled symbols" -- vyplněná = vybraná, obrys = ostatní).
  final IconData icon;

  /// Jedno slovo (HIG: "Use single words whenever possible").
  final String label;
}

/// Plovoucí skleněný tab bar jako v iOS 26 (Apple Music, živé screenshoty):
/// výběr je skleněná kapka, kterou jde chytit a táhnout. Při tažení kapka
/// povyroste nad lištu, ikony pod ní zvětší a obarví barvou akcentu,
/// podle rychlosti se natahuje ve směru pohybu; po puštění pružinou
/// doskočí na nejbližší tab a zapadne zpět do lišty. Klepnutí na tab ji
/// tam pošle s malým "hopem". Pod kapkou je vždy barevná kopie řádku, takže
/// se tab barví plynule, jak přes něj kapka jede.
/// Rozměry: `GlassTokens.tabBarHeight`, okraje `floatingMargin`, mezera
/// nad safe area `floatingBottomGap`.
class GlassTabBar extends StatefulWidget {
  const GlassTabBar({super.key, required this.items, required this.selectedIndex, required this.onSelected});

  final List<GlassTabItem> items;
  final int selectedIndex;
  final ValueChanged<int> onSelected;

  @override
  State<GlassTabBar> createState() => GlassTabBarState();
}

class GlassTabBarState extends State<GlassTabBar> with TickerProviderStateMixin {
  // Poloha kapky v jednotkách tabů (0 = první), pružinou.
  late final AnimationController _pos =
      AnimationController.unbounded(vsync: this, value: widget.selectedIndex.toDouble());
  // 0 = v liště, 1 = zvednutá nad lištu (tažení).
  late final AnimationController _lift = AnimationController.unbounded(vsync: this);
  bool _dragging = false;
  double _itemWidth = 1;

  static final SpringDescription _follow = SpringDescription.withDampingRatio(mass: 1, stiffness: 700, ratio: 0.82);
  static final SpringDescription _settle = SpringDescription.withDampingRatio(mass: 1, stiffness: 380, ratio: 0.72);
  static final SpringDescription _liftSpring = SpringDescription.withDampingRatio(mass: 1, stiffness: 520, ratio: 0.62);

  @override
  void didUpdateWidget(GlassTabBar old) {
    super.didUpdateWidget(old);
    if (!_dragging && widget.selectedIndex != old.selectedIndex && (_pos.value - widget.selectedIndex).abs() > 0.01) {
      _springPos(widget.selectedIndex.toDouble(), _settle);
    }
  }

  @override
  void dispose() {
    _pos.dispose();
    _lift.dispose();
    super.dispose();
  }

  // Omezení pohybu: kapka skočí rovnou na místo, bez pružiny a poskoku.
  bool get _reduceMotion => MediaQuery.disableAnimationsOf(context);

  void _springPos(double target, SpringDescription spring, [double? velocity]) {
    if (_reduceMotion) {
      _pos.value = target;
      return;
    }
    _pos.animateWith(SpringSimulation(spring, _pos.value, target, velocity ?? _pos.velocity));
  }

  void _springLift(double target) {
    if (_reduceMotion) {
      _lift.value = 0;
      return;
    }
    _lift.animateWith(SpringSimulation(_liftSpring, _lift.value, target, _lift.velocity));
  }

  double _slotAt(double x) => (x / _itemWidth - 0.5).clamp(0.0, widget.items.length - 1.0);

  void _select(int index) {
    _springPos(index.toDouble(), _settle);
    // I klepnutí na aktivní tab (iOS: návrat na začátek tabu).
    widget.onSelected(index);
  }

  void _onTapUp(TapUpDetails d) {
    final index = _slotAt(d.localPosition.dx).round();
    // Malý hop: kapka povyskočí a hned zapadne.
    if (!_reduceMotion) _lift.animateWith(SpringSimulation(_liftSpring, _lift.value, 0, 6));
    _select(index);
  }

  void _onDragStart(DragStartDetails d) {
    _dragging = true;
    _springLift(1);
    _springPos(_slotAt(d.localPosition.dx), _follow);
  }

  // Při tažení kapka sedí přesně pod prstem (dřív ji každý pohyb honil novou
  // pružinou -- zaostávala a cukala, živě nahlášeno); pružina až po puštění.
  void _onDragUpdate(DragUpdateDetails d) {
    final now = DateTime.now().microsecondsSinceEpoch;
    final target = _slotAt(d.localPosition.dx);
    final dt = (now - _lastDragAt) / 1e6;
    if (dt > 0 && dt < 0.1) _dragVelocity = (target - _pos.value) / dt;
    _lastDragAt = now;
    _pos.value = target;
  }

  int _lastDragAt = 0;
  double _dragVelocity = 0;

  void _onDragEnd(DragEndDetails d) {
    _dragging = false;
    // Kam kapka "doletí" podle rychlosti hodu, pak nejbližší tab.
    final fling = (d.primaryVelocity ?? 0) / _itemWidth * 0.12;
    final index = (_pos.value + fling).round().clamp(0, widget.items.length - 1);
    _springLift(0);
    // Doskok navazuje na rychlost prstu.
    _springPos(index.toDouble(), _settle, _dragVelocity);
    if (index != widget.selectedIndex) widget.onSelected(index);
    _dragVelocity = 0;
  }

  // --- Tažení zvenku (smrštěná kapsle v `HomeShell`): podržení/tah kapsle
  // lištu rozbalí a prst rovnou táhne kapku výběru, jako v Apple Music. ---
  final GlobalKey _area = GlobalKey();

  Offset _toLocal(Offset global) {
    final box = _area.currentContext?.findRenderObject() as RenderBox?;
    return box == null || !box.hasSize ? Offset.zero : box.globalToLocal(global);
  }

  void beginExternalDrag(Offset global) {
    _lastDragAt = DateTime.now().microsecondsSinceEpoch;
    _onDragStart(DragStartDetails(globalPosition: global, localPosition: _toLocal(global)));
  }

  void updateExternalDrag(Offset global) {
    if (!_dragging) return;
    _onDragUpdate(DragUpdateDetails(globalPosition: global, localPosition: _toLocal(global)));
  }

  void endExternalDrag(double velocityX) {
    if (!_dragging) return;
    _onDragEnd(DragEndDetails(velocity: Velocity(pixelsPerSecond: Offset(velocityX, 0)), primaryVelocity: velocityX));
  }

  void cancelExternalDrag() => _onDragCancel();

  // Zrušené tažení (gesto vyhrál někdo jiný, systémové přerušení) nesmí
  // přepnout tab -- kapka se jen vrátí na aktuální.
  void _onDragCancel() {
    if (!_dragging) return;
    _dragging = false;
    _springLift(0);
    _springPos(widget.selectedIndex.toDouble(), _settle, _dragVelocity);
    _dragVelocity = 0;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accent = theme.colorScheme.primary;
    final isDark = theme.brightness == Brightness.dark;
    // 12 px NAD skutečným spodním insetem (home indikátor iPhonu).
    final bottomInset = MediaQuery.paddingOf(context).bottom;
    const h = GlassTokens.tabBarHeight;
    return Padding(
      padding: EdgeInsets.only(bottom: bottomInset + GlassTokens.floatingBottomGap),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: GlassTokens.floatingMargin),
        child: SizedBox(
          key: _area,
          height: h,
          child: LayoutBuilder(
            builder: (context, constraints) {
              final width = constraints.maxWidth;
              _itemWidth = width / widget.items.length;
              return GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTapUp: _onTapUp,
                onHorizontalDragStart: _onDragStart,
                onHorizontalDragUpdate: _onDragUpdate,
                onHorizontalDragEnd: _onDragEnd,
                onHorizontalDragCancel: _onDragCancel,
                child: Stack(
                  clipBehavior: Clip.none,
                  children: [
                    GlassContainer(
                      borderRadius: const BorderRadius.all(Radius.circular(h / 2)),
                      shadow: true,
                      rim: true,
                      liquid: true,
                      systemGlass: true,
                      child: SizedBox(
                        height: h,
                        width: width,
                        // Pod zvednutou kapkou se šedý tab schová -- jinak
                        // prosvítal vedle zvětšené barevné kopie dvakrát
                        // (iPhone: zvětšení pozadí tam nesedí, živě nahlášeno).
                        child: AnimatedBuilder(
                          animation: Listenable.merge([_pos, _lift]),
                          builder: (context, _) => _row(theme, accent: null),
                        ),
                      ),
                    ),
                    // Kapka výběru nad lištou (smí přesahovat při zvednutí).
                    // Vlastní `RepaintBoundary`: bez ní se při tažení každý
                    // snímek překreslovala celá obrazovka (stránka se zrnem
                    // a obaly) -- tažení se sekalo (živě nahlášeno).
                    Positioned.fill(
                      child: RepaintBoundary(
                        child: Stack(
                          clipBehavior: Clip.none,
                          children: [
                            AnimatedBuilder(
                              animation: Listenable.merge([_pos, _lift]),
                              builder: (context, _) => _drop(theme, accent, isDark, width),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
        ),
      ),
    );
  }

  /// Řádek tabů. `accent == null` = běžné barvy (lišta), jinak barevná,
  /// vyplněná verze pro to, co je pod kapkou.
  Widget _row(ThemeData theme, {required Color? accent}) {
    final lift = _lift.value.clamp(0.0, 1.0);
    double visible(int i) =>
        accent != null || lift < 0.01 ? 1 : 1 - lift * (1 - (i - _pos.value).abs()).clamp(0.0, 1.0);
    return Row(
      children: [
        for (var i = 0; i < widget.items.length; i++)
          Expanded(
            child: Opacity(
              opacity: visible(i),
              child: Semantics(
                button: true,
                selected: i == widget.selectedIndex,
                label: widget.items[i].label,
                onTap: accent == null ? () => _select(i) : null,
                excludeSemantics: true,
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(
                      widget.items[i].icon,
                      size: 24,
                      fill: accent == null ? 0 : 1,
                      color: accent ?? theme.colorScheme.onSurfaceVariant,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      widget.items[i].label,
                      maxLines: 1,
                      overflow: TextOverflow.fade,
                      softWrap: false,
                      style: theme.textTheme.labelSmall?.copyWith(
                        fontSize: AppFontSize.tiny,
                        fontWeight: accent == null ? FontWeight.w500 : FontWeight.w700,
                        color: accent ?? theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }

  Widget _drop(ThemeData theme, Color accent, bool isDark, double width) {
    const h = GlassTokens.tabBarHeight;
    final solid = GlassSettings.solidOf(context);
    const pad = 5.0;
    final lift = _lift.value;
    // Natažení ve směru pohybu podle rychlosti (jako kapka).
    final v = _dragging ? _dragVelocity : _pos.velocity;
    final speed = (v.abs() * 0.05).clamp(0.0, 0.28);
    final baseW = _itemWidth - 2 * pad, baseH = h - 2 * pad;
    final w = baseW * (1 + 0.28 * lift) * (1 + speed);
    final hh = baseH * (1 + 0.42 * lift) * (1 - speed * 0.45);
    final cx = (_pos.value + 0.5) * _itemWidth;
    const cy = h / 2;
    final left = cx - w / 2, top = cy - hh / 2;
    // Obsah pod kapkou: barevná kopie řádku, zvětšená kolem středu kapky.
    final magnify = 1 + 0.22 * lift.clamp(0.0, 1.5);
    final radius = BorderRadius.circular(hh / 2);
    return Positioned(
      left: left,
      top: top,
      width: w,
      height: hh,
      child: IgnorePointer(
        child: DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: radius,
            boxShadow: lift > 0.05
                ? [
                    BoxShadow(
                        color: Colors.black.withValues(alpha: 0.28 * lift.clamp(0.0, 1.0)),
                        blurRadius: 18,
                        offset: const Offset(0, 6))
                  ]
                : null,
          ),
          child: ClipRRect(
            borderRadius: radius,
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                // Zvednutá kapka zvětšuje, co je skutečně pod ní (lišta
                // i obsah) -- ikony pod ní pak sedí přesně pod barevnou
                // kopií (dřív prosvítaly nezvětšené a byly dvakrát).
                // Jen na webu: v nativní appce (Impeller) bere zvětšení pozadí
                // souřadnice jinak -- posunutá kopie ("rozbitá lupa", živě).
                if (kIsWeb && magnify > 1.001 && !solid) Positioned.fill(child: _MagnifyBackdrop(scale: magnify)),
                // Sklo kapky: v klidu jemné (jako dřív), zvednuté čiré.
                Positioned.fill(
                  child: ColoredBox(
                    // "Bez skla": plná kapsle v barvě výběru (M3 indikátor).
                    color: solid
                        ? theme.colorScheme.secondaryContainer
                        : Colors.white.withValues(
                            alpha: (isDark ? 0.12 : 0.6) * (1 - lift.clamp(0.0, 1.0)) + 0.06 * lift.clamp(0.0, 1.0),
                          ),
                  ),
                ),
                Positioned(
                  left: -left,
                  top: -top,
                  width: width,
                  height: h,
                  child: Transform.scale(
                    scale: magnify,
                    origin: Offset(cx - width / 2, cy - h / 2),
                    child: ExcludeSemantics(child: _row(theme, accent: accent)),
                  ),
                ),
                // Světelný lem: nahoře jasnější, zvednutá kapka výraznější.
                if (!solid)
                  Positioned.fill(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        borderRadius: radius,
                        border: Border.all(
                          color: Colors.white.withValues(alpha: 0.18 + 0.32 * math.min(1.0, lift)),
                          width: 1,
                        ),
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.center,
                          colors: [
                            Colors.white.withValues(alpha: 0.10 + 0.12 * math.min(1.0, lift)),
                            Colors.transparent
                          ],
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Zvětšení toho, co je pod kapkou, kolem jejího středu (`BackdropFilter`
/// s maticí -- na webu jde, shader ne).
class _MagnifyBackdrop extends LeafRenderObjectWidget {
  const _MagnifyBackdrop({required this.scale});

  final double scale;

  @override
  RenderObject createRenderObject(BuildContext context) => _RenderMagnify(scale);

  @override
  void updateRenderObject(BuildContext context, _RenderMagnify renderObject) => renderObject.scale = scale;
}

class _RenderMagnify extends RenderBox {
  _RenderMagnify(this._scale);

  double _scale;
  set scale(double v) {
    if (v == _scale) return;
    _scale = v;
    markNeedsPaint();
  }

  final LayerHandle<BackdropFilterLayer> _layer = LayerHandle<BackdropFilterLayer>();

  @override
  bool get sizedByParent => true;

  @override
  bool get alwaysNeedsCompositing => true;

  @override
  Size computeDryLayout(BoxConstraints constraints) => constraints.biggest;

  @override
  void paint(PaintingContext context, Offset offset) {
    final c = (offset & size).center;
    final m = Matrix4.identity()
      ..translateByDouble(c.dx, c.dy, 0, 1)
      ..scaleByDouble(_scale, _scale, 1, 1)
      ..translateByDouble(-c.dx, -c.dy, 0, 1);
    final layer = (_layer.layer ??= BackdropFilterLayer())..filter = ImageFilter.matrix(m.storage);
    context.pushLayer(layer, (_, __) {}, Offset.zero);
  }

  @override
  void dispose() {
    _layer.layer = null;
    super.dispose();
  }
}
