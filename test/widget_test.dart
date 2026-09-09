import 'package:flutter_test/flutter_test.dart';
import 'package:accessai/main.dart';

void main() {
  testWidgets('AccessAI uygulaması açılıyor', (WidgetTester tester) async {
    await tester.pumpWidget(const AccessAIApp());
    // Şu an sadece uygulamanın çökmeden açıldığını doğruluyoruz.
    expect(find.byType(AccessAIApp), findsOneWidget);
  });
}