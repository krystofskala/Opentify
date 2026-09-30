import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../state/auth_controller.dart';

/// Zařízení bez přihlášení (a server v uzamčeném režimu): prosba o
/// pozvánkový odkaz. Jinak -- i během načítání a offline -- rovnou appka.
class AuthGate extends ConsumerWidget {
  const AuthGate({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final auth = ref.watch(authProvider);
    final signedOut = auth.hasValue && auth.value!.user == null;
    if (!signedOut) return child;
    final theme = Theme.of(context);
    return Material(
      type: MaterialType.transparency,
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Symbols.lock_person_rounded, size: 56, color: theme.colorScheme.onSurfaceVariant),
              const SizedBox(height: 16),
              Text('Opentify', style: theme.textTheme.headlineSmall),
              const SizedBox(height: 8),
              Text(
                'Tohle zařízení ještě není přihlášené. Otevři pozvánkový odkaz, '
                'který ti poslal správce – stačí jednou.',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyLarge?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
