import 'package:flutter/material.dart';

/// Jedno upozornění pro celou appku (audit UI): stejná délka všude, nové
/// nahradí předchozí místo čekání ve frontě, s akcí (Zpět, Otevřít...) zůstane
/// déle. Odhodit jde prstem do strany (`snackBarTheme`).
const toastDuration = Duration(milliseconds: 2500);
const toastWithActionDuration = Duration(seconds: 5);

void showToast(
  ScaffoldMessengerState? messenger,
  String text, {
  SnackBarAction? action,
  Duration? duration,
}) {
  if (messenger == null) return;
  messenger
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(
      content: Text(text),
      action: action,
      persist: false,
      duration: duration ?? (action != null ? toastWithActionDuration : toastDuration),
    ));
}

/// Zkratka, když je po ruce jen `context`.
void toast(BuildContext context, String text, {SnackBarAction? action, Duration? duration}) =>
    showToast(ScaffoldMessenger.maybeOf(context), text, action: action, duration: duration);
