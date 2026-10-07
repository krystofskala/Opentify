import 'package:flutter/material.dart';

/// Jedno upozornění pro celou appku (audit UI): stejná délka všude, nové
/// nahradí předchozí místo čekání ve frontě, s akcí (Zpět, Otevřít...) zůstane
/// déle. Odhodit jde prstem do strany (`snackBarTheme`).
const toastDuration = Duration(milliseconds: 2500);
const toastWithActionDuration = Duration(seconds: 5);

/// Delší text potřebuje víc času na přečtení (UX audit 7. 10.: dlouhé
/// hlášky zmizely dřív, než se daly dočíst) -- ~15 znaků za sekundu, max 7 s.
Duration toastDurationFor(String text, {bool hasAction = false}) {
  final base = hasAction ? toastWithActionDuration : toastDuration;
  final reading = Duration(milliseconds: 1000 + text.length * 65);
  final d = reading > base ? reading : base;
  const max = Duration(seconds: 7);
  return d > max ? max : d;
}

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
      duration: duration ?? toastDurationFor(text, hasAction: action != null),
    ));
}

/// Zkratka, když je po ruce jen `context`.
void toast(BuildContext context, String text, {SnackBarAction? action, Duration? duration}) =>
    showToast(ScaffoldMessenger.maybeOf(context), text, action: action, duration: duration);
