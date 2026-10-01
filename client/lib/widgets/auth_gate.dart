import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../core/device_token.dart';
import '../state/auth_controller.dart';
import '../state/providers.dart';
import 'glass/glass.dart';

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
                kIsWeb
                    ? 'Tohle zařízení ještě není přihlášené. Otevři pozvánkový odkaz, '
                        'který ti poslal správce – stačí jednou.'
                    : 'Tohle zařízení ještě není přihlášené. Vlož sem pozvánkový odkaz, '
                        'který ti poslal správce – stačí jednou.',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyLarge?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
              // Nativní appka: odkaz se v ní otevřít nedá (web ho čte z adresy).
              if (!kIsWeb) ...[const SizedBox(height: 20), const _PasteInvite()],
            ],
          ),
        ),
      ),
    );
  }
}

class _PasteInvite extends ConsumerStatefulWidget {
  const _PasteInvite();

  @override
  ConsumerState<_PasteInvite> createState() => _PasteInviteState();
}

class _PasteInviteState extends ConsumerState<_PasteInvite> {
  final _controller = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  /// Celý odkaz (`…/?join=KÓD`) i samotný kód.
  String? _code(String text) {
    final t = text.trim();
    if (t.isEmpty) return null;
    final uri = Uri.tryParse(t);
    return uri?.queryParameters['join'] ?? (t.contains('/') ? null : t);
  }

  Future<void> _join() async {
    final code = _code(_controller.text);
    if (code == null) {
      setState(() => _error = 'Tohle nevypadá jako pozvánkový odkaz.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final joined = await ref.read(apiClientProvider).postJson('/auth/join', body: {'code': code});
      if (joined['token'] case final String token) await saveDeviceToken(token);
      ref.invalidate(authProvider);
    } catch (_) {
      if (mounted) setState(() => _error = 'Pozvánka neplatí nebo server není dostupný (zapnutý Tailscale?).');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          controller: _controller,
          autocorrect: false,
          enableSuggestions: false,
          decoration: InputDecoration(hintText: 'Pozvánkový odkaz', errorText: _error),
          onSubmitted: (_) => _join(),
        ),
        const SizedBox(height: 12),
        GlassButton(
          label: _busy ? 'Přihlašuji…' : 'Přihlásit',
          style: GlassButtonStyle.prominent,
          onPressed: _busy ? null : _join,
        ),
      ],
    );
  }
}
