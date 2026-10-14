import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sm_courier/ui/location_disclosure.dart';
import 'package:sm_core/sm_core.dart' as sm_i18n;

/// Экран «зачем геопозиция» (Figma Ц0): только «Продолжить» → true, без «Не сейчас» (Apple 5.1.1(iv)).
Future<bool?> _open(WidgetTester tester, LocationAudience audience, String button) async {
  bool? result;
  await tester.pumpWidget(MaterialApp(
    home: Builder(
      builder: (context) => Scaffold(
        body: Center(
          child: TextButton(
            onPressed: () async => result = await showLocationDisclosure(context, audience),
            child: const Text('open'),
          ),
        ),
      ),
    ),
  ));
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
  expect(find.text('Разрешите доступ к геопозиции'), findsOneWidget);
  expect(find.text('Политика конфиденциальности'), findsOneWidget);
  await tester.tap(find.text(button));
  await tester.pumpAndSettle();
  expect(find.text('Разрешите доступ к геопозиции'), findsNothing);
  return result;
}

void main() {
  // Проверки написаны на русском; язык по умолчанию в приложениях — узбекский.
  setUpAll(() => sm_i18n.Lang.instance.debugUse(sm_i18n.Lang.ru));

  testWidgets('курьер «по пути»: Продолжить', (tester) async {
    expect(await _open(tester, LocationAudience.crowd, 'Продолжить'), isTrue);
  });

  testWidgets('нет кнопки «Не сейчас» — после пояснения всегда системный запрос', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: LocationDisclosureScreen(audience: LocationAudience.crowd)));
    expect(find.text('Не сейчас'), findsNothing);
    expect(find.text('Продолжить'), findsOneWidget);
  });

  testWidgets('тексты для курьера «по пути» и штатного', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: LocationDisclosureScreen(audience: LocationAudience.crowd)));
    expect(find.textContaining('«Ищу заказы»'), findsOneWidget);
    expect(find.text('Заказы рядом'), findsOneWidget);
    await tester.pumpWidget(const MaterialApp(home: LocationDisclosureScreen(audience: LocationAudience.staff)));
    expect(find.textContaining('«Вы на смене»'), findsOneWidget);
    expect(find.text('Заказы рядом'), findsNothing);
  });
}
