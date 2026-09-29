import 'dart:js_interop';

@JS('__opentifyNote')
external JSFunction? get _noteFn;

@JS('__opentifyReport')
external JSFunction? get _reportFn;

void diagNote(String text) {
  try {
    _noteFn?.callAsFunction(null, text.toJS);
  } catch (_) {}
}

void diagReport(String kind, String detail) {
  try {
    _reportFn?.callAsFunction(null, kind.toJS, {'detail': detail}.jsify());
  } catch (_) {}
}
