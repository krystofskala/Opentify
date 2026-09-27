import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:opentify_client/app.dart';

void main() {
  testWidgets('OpentifyApp builds without throwing', (WidgetTester tester) async {
    await tester.pumpWidget(const ProviderScope(child: OpentifyApp()));
    await tester.pump();
  });
}
