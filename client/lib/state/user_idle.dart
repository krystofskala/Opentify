import 'dart:async';

import 'package:flutter/widgets.dart';

/// Nečinnost uživatele: [idleAfter] bez doteku, scrollu nebo myši. Čte ji
/// "ambientní" hlavička detailu (fotka se při přehrávání rozplyne do
/// živého pozadí, viz `detail_hero.dart`).
class UserIdle {
  const UserIdle._();

  static const idleAfter = Duration(seconds: 5);
  static final ValueNotifier<bool> idle = ValueNotifier(false);
  static Timer? _timer;

  static void poke() {
    if (idle.value) idle.value = false;
    _timer?.cancel();
    _timer = Timer(idleAfter, () => idle.value = true);
  }
}

/// Nad celou appkou -- každý ukazatel (dotek, tažení, kolečko, pohyb myši)
/// nečinnost ukončí. Události jen poslouchá, nic nepohltí.
class UserActivityListener extends StatefulWidget {
  const UserActivityListener({super.key, required this.child});

  final Widget child;

  @override
  State<UserActivityListener> createState() => _UserActivityListenerState();
}

class _UserActivityListenerState extends State<UserActivityListener> {
  @override
  void initState() {
    super.initState();
    UserIdle.poke();
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: (_) => UserIdle.poke(),
      onPointerMove: (_) => UserIdle.poke(),
      onPointerHover: (_) => UserIdle.poke(),
      onPointerSignal: (_) => UserIdle.poke(),
      child: widget.child,
    );
  }
}
