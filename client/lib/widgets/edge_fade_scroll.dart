import 'package:flutter/material.dart';

/// Vodorovně posuvný řádek, který se u okraje jemně rozplyne, když je za ním
/// ještě něco schované (vpravo) nebo už odjeté (vlevo) -- na úzkém telefonu
/// je tak vidět, že jde lištu posunout prstem. Když se všechno vejde, nic
/// se nezprůhlední.
class EdgeFadeScroll extends StatefulWidget {
  const EdgeFadeScroll({super.key, required this.child, this.fade = 24});

  final Widget child;
  final double fade;

  @override
  State<EdgeFadeScroll> createState() => _EdgeFadeScrollState();
}

class _EdgeFadeScrollState extends State<EdgeFadeScroll> {
  final _controller = ScrollController();
  bool _left = false;
  bool _right = false;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_update);
    WidgetsBinding.instance.addPostFrameCallback((_) => _update());
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _update() {
    if (!mounted || !_controller.hasClients) return;
    final p = _controller.position;
    final left = p.pixels > 1;
    final right = p.pixels < p.maxScrollExtent - 1;
    if (left != _left || right != _right) {
      setState(() {
        _left = left;
        _right = right;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final scroll = NotificationListener<ScrollMetricsNotification>(
      // Změna obsahu (jiné řazení = jiná šířka kapsle) -- přepočítat.
      onNotification: (_) {
        WidgetsBinding.instance.addPostFrameCallback((_) => _update());
        return false;
      },
      child: SingleChildScrollView(controller: _controller, scrollDirection: Axis.horizontal, child: widget.child),
    );
    if (!_left && !_right) return scroll;
    return LayoutBuilder(
      builder: (context, constraints) {
        final stop = (widget.fade / constraints.maxWidth).clamp(0.0, 0.5);
        return ShaderMask(
          blendMode: BlendMode.dstIn,
          shaderCallback: (rect) => LinearGradient(
            colors: [
              _left ? Colors.transparent : Colors.black,
              Colors.black,
              Colors.black,
              _right ? Colors.transparent : Colors.black,
            ],
            stops: [0, stop, 1 - stop, 1],
          ).createShader(rect),
          child: scroll,
        );
      },
    );
  }
}
