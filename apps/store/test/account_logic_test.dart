import 'package:flutter_test/flutter_test.dart';
import 'package:sm_store/account/account_logic.dart';
import 'package:sm_core/sm_core.dart' as sm_i18n;

void main() {
  // Проверки написаны на русском; язык по умолчанию в приложениях — узбекский.
  setUpAll(() => sm_i18n.Lang.instance.debugUse(sm_i18n.Lang.ru));

  test('deletionReason: вариант, комментарий, не длиннее 500', () {
    expect(deletionReason(null, ''), '');
    expect(deletionReason('Магазин закрыт', '  '), 'Магазин закрыт');
    expect(deletionReason(null, ' Переезжаю '), 'Переезжаю');
    expect(deletionReason('Другое', 'Переезжаю'), 'Другое: Переезжаю');
    expect(deletionReason('Другое', 'я' * 600).runes.length, deletionReasonMax);
  });

  test('deletionAlreadySent: 201 — только что создан, 200 — прежний запрос', () {
    final now = DateTime.parse('2026-10-06T10:00:00Z');
    expect(deletionAlreadySent({'created_at': '2026-10-06T09:59:58Z'}, now), isFalse);
    expect(deletionAlreadySent({'created_at': '2026-10-01T08:00:00Z'}, now), isTrue);
    expect(deletionAlreadySent(const {}, now), isFalse);
    expect(deletionSentMessage(already: false), 'Запрос отправлен. Супер-админ свяжется с вами');
    expect(deletionSentMessage(already: true), startsWith('Запрос уже отправлен'));
  });

  test('deletionText: владельцу — про закрытие сети', () {
    expect(deletionText(isOwner: false), contains('Аккаунт сотрудника создаёт владелец сети'));
    expect(deletionText(isOwner: true), contains('закрыть сеть'));
    expect(deletionText(isOwner: true), contains('супер-админ свяжется'));
    expect(deletionReasons, hasLength(4));
  });
}
