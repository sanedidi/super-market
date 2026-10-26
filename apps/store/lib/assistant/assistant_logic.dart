// Шахзод — помощник в «SM Магазин» (Figma «Super Market · Помощник», страница
// «SM Магазин · таб «Помощник»», М1–М7). Чистая логика без виджетов: разбор
// блоков ответа (кнопки, карточки, таблицы, ссылки, подтверждение) — тесты в
// test/assistant_logic_test.dart.
import 'package:flutter/foundation.dart';

/// Что за кнопкой: отправить текст, выполнить действие или открыть камеру.
enum AssistAttach { none, invoice, product }

/// Кнопка в ответе Шахзода (блок buttons или кнопки карточки).
@immutable
class AssistButton {
  const AssistButton({required this.label, this.send, this.ref, this.action, this.attach = AssistAttach.none, this.primary = false});

  final String label;

  /// Текст, который уйдёт сообщением владельца (по умолчанию — [label]).
  final String? send;

  /// Что стоит за выбором (id товара): в чате — только текст, Шахзоду — и ref.
  final String? ref;

  /// Действие без модели: строка накладной, поставщик, «Провести», подтверждённый запрос.
  final Map<String, dynamic>? action;
  final AssistAttach attach;
  final bool primary;

  static AssistButton fromJson(Map<String, dynamic> m) {
    final a = m['attach'];
    final attach = a == 'product'
        ? AssistAttach.product
        : (a == true || a == 'invoice' || a == 'true')
            ? AssistAttach.invoice
            : AssistAttach.none;
    final action = m['action'];
    return AssistButton(
      label: '${m['label'] ?? ''}',
      send: m['send'] is String ? m['send'] as String : null,
      ref: m['ref'] is String && (m['ref'] as String).isNotEmpty ? m['ref'] as String : null,
      action: action is Map ? Map<String, dynamic>.from(action) : null,
      attach: attach,
      primary: m['primary'] == true,
    );
  }

  /// Действие с подписью для чата («Провести приход»).
  Map<String, dynamic>? get labeledAction {
    final a = action;
    if (a == null) return null;
    final label = a['label'];
    return {...a, 'label': label is String && label.isNotEmpty ? label : this.label};
  }
}

List<AssistButton> parseButtons(Object? items) {
  if (items is! List) return const [];
  return [
    for (final x in items)
      if (x is Map && '${x['label'] ?? ''}'.trim().isNotEmpty) AssistButton.fromJson(Map<String, dynamic>.from(x)),
  ];
}

/// Блок ответа: что показать кроме текста.
sealed class AssistBlock {
  const AssistBlock();

  static AssistBlock? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final m = Map<String, dynamic>.from(raw);
    switch (m['type']) {
      case 'buttons':
        final b = parseButtons(m['items']);
        return b.isEmpty ? null : ButtonsBlock(b);
      case 'card':
        return CardBlock(
          title: '${m['title'] ?? ''}',
          sum: m['sum'] is String ? m['sum'] as String : null,
          note: m['note'] is String && (m['note'] as String).isNotEmpty ? m['note'] as String : null,
          status: m['status'] is String && (m['status'] as String).isNotEmpty ? m['status'] as String : null,
          statusKind: '${m['status_kind'] ?? 'warn'}',
          buttons: parseButtons(m['buttons']),
        );
      case 'table':
        final cols = [for (final c in (m['columns'] as List? ?? const [])) '$c'];
        final rows = [
          for (final r in (m['rows'] as List? ?? const []))
            if (r is List) [for (final c in r) '$c'],
        ];
        return cols.isEmpty || rows.isEmpty ? null : TableBlock(cols, rows);
      case 'link':
        final href = '${m['href'] ?? ''}';
        return href.startsWith('/') ? LinkBlock('${m['label'] ?? ''}', href) : null;
      case 'confirm':
        final a = m['action'];
        if (a is! Map) return null;
        return ConfirmBlock(
          label: '${m['label'] ?? ''}',
          action: Map<String, dynamic>.from(a),
          enabled: m['enabled'] != false,
          hint: m['hint'] is String && (m['hint'] as String).isNotEmpty ? m['hint'] as String : null,
        );
    }
    return null;
  }
}

class ButtonsBlock extends AssistBlock {
  const ButtonsBlock(this.items);
  final List<AssistButton> items;
}

class CardBlock extends AssistBlock {
  const CardBlock({required this.title, this.sum, this.note, this.status, this.statusKind = 'warn', this.buttons = const []});
  final String title;
  final String? sum;
  final String? note;
  final String? status;

  /// warn, error, ok.
  final String statusKind;
  final List<AssistButton> buttons;
}

class TableBlock extends AssistBlock {
  const TableBlock(this.columns, this.rows);
  final List<String> columns;
  final List<List<String>> rows;
}

class LinkBlock extends AssistBlock {
  const LinkBlock(this.label, this.href);
  final String label;
  final String href;
}

class ConfirmBlock extends AssistBlock {
  const ConfirmBlock({required this.label, required this.action, required this.enabled, this.hint});
  final String label;
  final Map<String, dynamic> action;
  final bool enabled;
  final String? hint;

  Map<String, dynamic> get labeledAction {
    final l = action['label'];
    return {...action, 'label': l is String && l.isNotEmpty ? l : label};
  }
}

List<AssistBlock> parseBlocks(Object? raw) {
  if (raw is! List) return const [];
  final out = <AssistBlock>[];
  for (final b in raw) {
    final x = AssistBlock.fromJson(b);
    if (x != null) out.add(x);
  }
  return out;
}

/// Куда в приложении ведёт ссылка из панели (null — в приложении такого экрана нет).
enum AppPlace { home, orders, stock }

AppPlace? placeFor(String href) {
  final h = href.split('?').first;
  if (h == '/') return AppPlace.home;
  if (h == '/orders' || h.startsWith('/orders/')) return AppPlace.orders;
  if (h.startsWith('/stock') || h.startsWith('/dirs/products')) return AppPlace.stock;
  return null;
}

/// Голосовое: сколько секунд можно записывать и короче чего не отправлять.
const maxVoiceSeconds = 60;
const minVoiceMillis = 700;

/// Сдвиг пальца влево (px), после которого запись отменяется.
const cancelSwipe = 80.0;

/// Подсказка Шахзода на главной — пока владелец не открыл чат столько раз.
const hintOpens = 3;
