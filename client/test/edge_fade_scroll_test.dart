import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opentify_client/widgets/edge_fade_scroll.dart';

void main() {
  Future<void> pump(WidgetTester tester, double contentWidth) => tester.pumpWidget(MaterialApp(
        home: Center(
          child: SizedBox(
            width: 200,
            child: EdgeFadeScroll(child: SizedBox(width: contentWidth, height: 40)),
          ),
        ),
      ));

  testWidgets('vejde se -> bez rozplynutí', (tester) async {
    await pump(tester, 150);
    await tester.pump();
    expect(find.byType(ShaderMask), findsNothing);
  });

  testWidgets('nevejde se -> rozplynutý okraj, posouvá se prstem', (tester) async {
    await pump(tester, 400);
    await tester.pump();
    expect(find.byType(ShaderMask), findsOneWidget);
    await tester.drag(find.byType(SingleChildScrollView), const Offset(-300, 0));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
