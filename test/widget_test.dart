import 'package:flutter_test/flutter_test.dart';

import 'package:openfic_f/main.dart';

void main() {
  testWidgets('书架首屏可渲染', (WidgetTester tester) async {
    await tester.pumpWidget(const OpenFicFApp());
    expect(find.text('书架'), findsOneWidget);
  });
}