import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:opentify_client/app.dart';

void main() {
  testWidgets('OpentifyApp builds without throwing', (WidgetTester tester) async {
    await tester.pumpWidget(const ProviderScope(child: OpentifyApp()));
    await tester.pump();
    // Odpojit appku a dopustit krátké časovače (zachytávání skla, debounce).
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 2));
  });
}
