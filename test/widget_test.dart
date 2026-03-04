import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:silsigan/app.dart';

void main() {
  testWidgets('App renders main screen', (WidgetTester tester) async {
    await tester.pumpWidget(
      const ProviderScope(child: SilsiganApp()),
    );
    expect(find.text('Silsigan'), findsOneWidget);
  });
}
