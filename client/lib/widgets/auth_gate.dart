import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../core/api_client.dart' show ApiException;
import '../core/device_token.dart';
import '../core/page_location.dart' show clearJoinFromUrl;
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
    final invite = auth.value!.inviteCode;
    return Material(
      type: MaterialType.transparency,
      child: invite != null ? _ClaimForm(code: invite) : const _LoginForm(),
    );
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
  final _code = TextEditingController();

  /// Profil bez hesla: druhý krok -- vytvořit heslo (jméno z odpovědi).
  String? _createFor;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    for (final c in [_username, _password, _newPassword, _confirm, _invite, _code]) {
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
        'device': deviceName(),
        'code': _code.text.trim(),
        if (_createFor != null) 'new_password': _newPassword.text,
      });
      if (json['needsPassword'] == true) {
        setState(() => _createFor = json['name'] as String? ?? username);
        return;
      }
      if (json['token'] case final String token) await saveDeviceToken(token);
      ref.invalidate(authProvider);
      // WS se připojoval ještě nepřihlášený a čeká v backoffu (až 30 s) --
      // Connect a živé události hned.
      ref.read(realtimeClientProvider).reconnectNow(force: true);
      // Server přihlášení přijal, ale prohlížeč si cookie nenechal (blokování
      // cookies, anonymní okno) -- dřív se jen tiše vrátil přihlašovací formulář.
      final after = await ref.read(authProvider.future);
      if (after.user == null && mounted) {
        setState(() => _error = 'Heslo sedí, ale prohlížeč si přihlášení nezapamatoval. '
            'Vypni blokování cookies pro tuhle stránku (nebo nepoužívej anonymní okno) a zkus to znovu.');
      }
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

  /// Appka pozvánkový odkaz otevřít neumí -- vloží se tady. Přímo na téhle
  /// obrazovce: leží nad navigací appky, dialog odsud otevřít nejde (živě:
  /// tlačítko „Mám pozvánku" nic nedělalo).
  bool _inviteMode = false;
  String? _claimCode;
  final _invite = TextEditingController();

  void _useInvite() {
    final text = _invite.text.trim();
    final code = Uri.tryParse(text)?.queryParameters['join'] ?? (text.contains('/') || text.isEmpty ? null : text);
    if (code == null) {
      setState(() => _error = 'Tohle nevypadá jako pozvánkový odkaz.');
      return;
    }
    setState(() {
      _error = null;
      _claimCode = code;
    });
  }

  Widget _invitePaste(ThemeData theme) => Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(32),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 360),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Icon(Symbols.mail_rounded, size: 56, color: theme.colorScheme.onSurfaceVariant),
                const SizedBox(height: 16),
                Text('Pozvánka', textAlign: TextAlign.center, style: theme.textTheme.headlineSmall),
                const SizedBox(height: 8),
                Text(
                  'Vlož odkaz z pozvánky, kterou ti poslal správce.',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodyLarge?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                ),
                const SizedBox(height: 20),
                TextField(
                  controller: _invite,
                  autofocus: true,
                  autocorrect: false,
                  enableSuggestions: false,
                  decoration: const InputDecoration(labelText: 'Odkaz z pozvánky'),
                  onSubmitted: (_) => _useInvite(),
                ),
                if (_error != null) ...[
                  const SizedBox(height: 12),
                  Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
                ],
                const SizedBox(height: 20),
                GlassButton(label: 'Pokračovat', style: GlassButtonStyle.prominent, onPressed: _useInvite),
                const SizedBox(height: 8),
                GlassButton(
                  label: 'Zpět na přihlášení',
                  style: GlassButtonStyle.plain,
                  onPressed: () => setState(() {
                    _inviteMode = false;
                    _error = null;
                  }),
                ),
              ],
            ),
          ),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final creating = _createFor != null;
    if (_claimCode != null) {
      return _ClaimForm(code: _claimCode!, onBack: () => setState(() => _claimCode = null));
    }
    if (_inviteMode) return _invitePaste(theme);
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
                    textInputAction: TextInputAction.next,
                    decoration: const InputDecoration(labelText: 'Heslo', hintText: 'poprvé nech prázdné'),
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
                // Kód zařízení: nové zařízení se přihlásí jen s ním (heslo
                // samo nestačí). Vytvoří ho správce, nebo člověk sám v Profilu
                // na zařízení, kde už je přihlášený.
                if (!creating) ...[
                  const SizedBox(height: 12),
                  TextField(
                    controller: _code,
                    autocorrect: false,
                    enableSuggestions: false,
                    textCapitalization: TextCapitalization.characters,
                    autofillHints: const [AutofillHints.oneTimeCode],
                    decoration: const InputDecoration(
                      labelText: 'Kód zařízení',
                      hintText: 'ABCD-EFGH',
                      helperText: 'Od správce, nebo z Profilu na zařízení, kde už jsi přihlášený.',
                      helperMaxLines: 2,
                    ),
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
                if (!creating) ...[
                  const SizedBox(height: 8),
                  GlassButton(
                    label: 'Mám pozvánku od správce',
                    style: GlassButtonStyle.plain,
                    onPressed: () => setState(() {
                      _inviteMode = true;
                      _error = null;
                    }),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Pozvánka od správce: člověk si sám vybere přihlašovací jméno a heslo.
class _ClaimForm extends ConsumerStatefulWidget {
  const _ClaimForm({required this.code, this.onBack});
  final String code;

  /// Vložená pozvánka (ne z adresy): zpět na přihlášení.
  final VoidCallback? onBack;

  @override
  ConsumerState<_ClaimForm> createState() => _ClaimFormState();
}

class _ClaimFormState extends ConsumerState<_ClaimForm> {
  final _username = TextEditingController();
  final _password = TextEditingController();
  final _confirm = TextEditingController();
  String? _name;
  bool _busy = true;
  bool _invalid = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _check();
  }

  @override
  void dispose() {
    for (final c in [_username, _password, _confirm]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _check() async {
    try {
      final json = await ref.read(apiClientProvider).postJson('/auth/claim', body: {'code': widget.code});
      if (!mounted) return;
      setState(() {
        _name = json['name'] as String?;
        _username.text = json['username'] as String? ?? '';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _invalid = true;
        _error = e is ApiException ? e.detail : 'Server není dostupný (zapnutý Tailscale?).';
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _submit() async {
    final username = _username.text.trim();
    if (username.length < 3 || username.contains(' ')) {
      setState(() => _error = 'Přihlašovací jméno: aspoň 3 znaky, bez mezer.');
      return;
    }
    if (_password.text.length < 6) {
      setState(() => _error = 'Heslo aspoň 6 znaků.');
      return;
    }
    if (_password.text != _confirm.text) {
      setState(() => _error = 'Hesla se neshodují.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final json = await ref.read(apiClientProvider).postJson('/auth/claim', body: {
        'code': widget.code,
        'username': username,
        'password': _password.text,
        'device': deviceName(),
      });
      if (json['token'] case final String token) await saveDeviceToken(token);
      clearJoinFromUrl();
      ref.invalidate(authProvider);
      ref.read(realtimeClientProvider).reconnectNow(force: true);
    } catch (e) {
      if (mounted) {
        setState(() => _error = e is ApiException ? (e.detail ?? 'Nepovedlo se.') : 'Server není dostupný.');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
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
                Icon(Symbols.waving_hand_rounded, size: 56, color: theme.colorScheme.onSurfaceVariant),
                const SizedBox(height: 16),
                Text(
                  _name == null ? 'Opentify' : 'Ahoj, $_name!',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.headlineSmall,
                ),
                const SizedBox(height: 8),
                Text(
                  _invalid
                      ? (_error ?? 'Pozvánka neplatí.')
                      : 'Vyber si přihlašovací jméno a heslo. Zadáš je jen na novém zařízení – '
                          'tohle si přihlášení zapamatuje.',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodyLarge?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                ),
                // Použitá pozvánka (účet už existuje) -- normální přihlášení.
                if (_invalid) ...[
                  const SizedBox(height: 20),
                  GlassButton(
                    label: 'Přihlásit se jménem a heslem',
                    style: GlassButtonStyle.prominent,
                    onPressed: () {
                      clearJoinFromUrl();
                      if (widget.onBack != null) {
                        widget.onBack!();
                      } else {
                        ref.invalidate(authProvider);
                      }
                    },
                  ),
                ],
                if (!_invalid) ...[
                  const SizedBox(height: 20),
                  TextField(
                    controller: _username,
                    autocorrect: false,
                    enableSuggestions: false,
                    autofillHints: const [AutofillHints.newUsername],
                    textInputAction: TextInputAction.next,
                    decoration: const InputDecoration(labelText: 'Přihlašovací jméno'),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _password,
                    obscureText: true,
                    autofillHints: const [AutofillHints.newPassword],
                    textInputAction: TextInputAction.next,
                    decoration: const InputDecoration(labelText: 'Heslo (aspoň 6 znaků)'),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _confirm,
                    obscureText: true,
                    autofillHints: const [AutofillHints.newPassword],
                    decoration: const InputDecoration(labelText: 'Heslo znovu'),
                    onSubmitted: (_) => _submit(),
                  ),
                  if (_error != null) ...[
                    const SizedBox(height: 12),
                    Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
                  ],
                  const SizedBox(height: 20),
                  GlassButton(
                    label: _busy ? 'Moment…' : 'Založit účet a přihlásit',
                    style: GlassButtonStyle.prominent,
                    onPressed: _busy ? null : _submit,
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
