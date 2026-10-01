import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../core/api_client.dart' show ApiException;
import '../core/device_token.dart';
import '../state/auth_controller.dart';
import '../state/providers.dart';
import 'glass/glass.dart';

/// Nepřihlášené zařízení: jméno + heslo (profil zakládá admin; heslo si
/// člověk vytvoří při prvním přihlášení). Přihlášení si zařízení pamatuje
/// (nativně klíč v zařízení, web cookie). Jinak -- i během načítání a
/// offline -- rovnou appka.
class AuthGate extends ConsumerWidget {
  const AuthGate({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final auth = ref.watch(authProvider);
    final signedOut = auth.hasValue && auth.value!.user == null;
    if (!signedOut) return child;
    return const Material(type: MaterialType.transparency, child: _LoginForm());
  }
}

class _LoginForm extends ConsumerStatefulWidget {
  const _LoginForm();

  @override
  ConsumerState<_LoginForm> createState() => _LoginFormState();
}

class _LoginFormState extends ConsumerState<_LoginForm> {
  final _username = TextEditingController();
  final _password = TextEditingController();
  final _newPassword = TextEditingController();
  final _confirm = TextEditingController();

  /// Profil bez hesla: druhý krok -- vytvořit heslo (jméno z odpovědi).
  String? _createFor;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    for (final c in [_username, _password, _newPassword, _confirm]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _submit() async {
    final username = _username.text.trim();
    if (username.isEmpty) {
      setState(() => _error = 'Zadej přihlašovací jméno.');
      return;
    }
    if (_createFor != null) {
      if (_newPassword.text.length < 6) {
        setState(() => _error = 'Heslo aspoň 6 znaků.');
        return;
      }
      if (_newPassword.text != _confirm.text) {
        setState(() => _error = 'Hesla se neshodují.');
        return;
      }
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final json = await ref.read(apiClientProvider).postJson('/auth/login', body: {
        'username': username,
        'password': _password.text,
        if (_createFor != null) 'new_password': _newPassword.text,
      });
      if (json['needsPassword'] == true) {
        setState(() => _createFor = json['name'] as String? ?? username);
        return;
      }
      if (json['token'] case final String token) await saveDeviceToken(token);
      ref.invalidate(authProvider);
    } catch (e) {
      if (mounted) {
        setState(() => _error = e is ApiException
            ? (e.detail ?? 'Přihlášení se nepovedlo.')
            : 'Server není dostupný (zapnutý Tailscale?).');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final creating = _createFor != null;
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(32),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 360),
          child: AutofillGroup(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Icon(Symbols.lock_person_rounded, size: 56, color: theme.colorScheme.onSurfaceVariant),
                const SizedBox(height: 16),
                Text('Opentify', textAlign: TextAlign.center, style: theme.textTheme.headlineSmall),
                const SizedBox(height: 8),
                Text(
                  creating
                      ? 'Ahoj $_createFor! Vytvoř si heslo – budeš ho zadávat jen na novém zařízení.'
                      : 'Přihlas se jménem, které ti dal správce. Poprvé si vytvoříš heslo.',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodyLarge?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                ),
                const SizedBox(height: 20),
                TextField(
                  controller: _username,
                  enabled: !creating,
                  autocorrect: false,
                  enableSuggestions: false,
                  autofillHints: const [AutofillHints.username],
                  textInputAction: TextInputAction.next,
                  decoration: const InputDecoration(labelText: 'Přihlašovací jméno'),
                ),
                const SizedBox(height: 12),
                if (!creating)
                  TextField(
                    controller: _password,
                    obscureText: true,
                    autofillHints: const [AutofillHints.password],
                    decoration: const InputDecoration(labelText: 'Heslo', hintText: 'poprvé nech prázdné'),
                    onSubmitted: (_) => _submit(),
                  )
                else ...[
                  TextField(
                    controller: _newPassword,
                    obscureText: true,
                    autofocus: true,
                    autofillHints: const [AutofillHints.newPassword],
                    textInputAction: TextInputAction.next,
                    decoration: const InputDecoration(labelText: 'Nové heslo (aspoň 6 znaků)'),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _confirm,
                    obscureText: true,
                    autofillHints: const [AutofillHints.newPassword],
                    decoration: const InputDecoration(labelText: 'Heslo znovu'),
                    onSubmitted: (_) => _submit(),
                  ),
                ],
                if (_error != null) ...[
                  const SizedBox(height: 12),
                  Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
                ],
                const SizedBox(height: 20),
                GlassButton(
                  label: _busy ? 'Moment…' : (creating ? 'Vytvořit heslo a přihlásit' : 'Přihlásit'),
                  style: GlassButtonStyle.prominent,
                  onPressed: _busy ? null : _submit,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
