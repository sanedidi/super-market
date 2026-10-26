import 'package:flutter_test/flutter_test.dart';
import 'package:sm_store/assistant/assistant_logic.dart';

// Шахзод (Figma «SM Магазин · таб «Помощник»»): разбор блоков ответа сервера.
void main() {
  test('кнопки: текст, ref, действие, камера', () {
    final b = parseButtons([
      {'label': 'Coca-Cola 1,5 л', 'send': 'Coca-Cola 1,5 л', 'ref': 'p-1'},
      {'label': 'Прикрепить накладную', 'attach': true, 'primary': true},
      {'label': 'Сфотографировать товар', 'attach': 'product'},
      {'label': '12 блоков по 6', 'action': {'type': 'scan_line', 'scan_id': 's', 'line': 2, 'pack': '6'}},
      {'label': '   '},
    ]);
    expect(b, hasLength(4));
    expect(b[0].ref, 'p-1');
    expect(b[0].attach, AssistAttach.none);
    expect(b[1].attach, AssistAttach.invoice);
    expect(b[1].primary, isTrue);
    expect(b[2].attach, AssistAttach.product);
    expect(b[3].labeledAction, {'type': 'scan_line', 'scan_id': 's', 'line': 2, 'pack': '6', 'label': '12 блоков по 6'});
  });

  test('блоки: карточка, таблица, ссылка, подтверждение; неизвестные — пропуск', () {
    final blocks = parseBlocks([
      {'type': 'card', 'title': 'Окорочка', 'sum': '365 400', 'status': 'Не нашёл', 'status_kind': 'error', 'buttons': [{'label': 'Пропустить', 'action': {'type': 'scan_line'}}]},
      {'type': 'table', 'columns': ['Товар', 'Остаток'], 'rows': [['Coca-Cola', '12 шт']]},
      {'type': 'table', 'columns': [], 'rows': []},
      {'type': 'link', 'label': 'Остатки', 'href': '/stock/balance'},
      {'type': 'link', 'label': 'Чужая', 'href': 'https://example.com'},
      {'type': 'confirm', 'label': 'Провести приход · 308 000', 'action': {'type': 'api', 'method': 'POST', 'path': '/store/inventory/documents/d/post'}, 'enabled': true},
      {'type': 'video'},
      'мусор',
    ]);
    expect(blocks, hasLength(4));
    final card = blocks[0] as CardBlock;
    expect(card.statusKind, 'error');
    expect(card.buttons.single.label, 'Пропустить');
    expect((blocks[1] as TableBlock).rows.single, ['Coca-Cola', '12 шт']);
    expect((blocks[2] as LinkBlock).href, '/stock/balance');
    final c = blocks[3] as ConfirmBlock;
    expect(c.enabled, isTrue);
    expect(c.labeledAction['label'], 'Провести приход · 308 000');
  });

  test('ссылки панели → экраны приложения', () {
    expect(placeFor('/'), AppPlace.home);
    expect(placeFor('/orders'), AppPlace.orders);
    expect(placeFor('/stock/balance?status=low'), AppPlace.stock);
    expect(placeFor('/purchases/income/123'), isNull);
    expect(panelUrl('/sales/pos'), 'https://store.super-market.uz/sales/pos');
  });
}
