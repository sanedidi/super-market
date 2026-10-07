import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:sm_core/sm_core.dart' show tr;

import '../core/catalog.dart';
import '../core/codes.dart';
import '../core/money.dart';
import '../data/api.dart';
import '../state/pos.dart';
import 'theme.dart';
import 'widgets.dart';

/// F9 — возврат по чеку. Скан QR с чека или номер + Enter; ↑↓ строка,
/// пробел — вернуть всё, цифры — сколько вернуть; Enter — наличными, * — на карту.
class ReturnScreen extends StatefulWidget {
  const ReturnScreen({super.key});

  @override
  State<ReturnScreen> createState() => _ReturnScreenState();
}

const _reasonKeys = ['F2', 'F3', 'F4'];
List<String> get _reasonText => [tr('Брак', 'Nuqsonli'), tr('Не подошло', 'Mos kelmadi'), tr('Ошибка кассира', 'Kassir xatosi')];

class _ReturnScreenState extends State<ReturnScreen> {
  String _input = '';
  Map<String, dynamic>? _sale;
  List<int> _ret = []; // сколько вернуть по строкам, в тысячных
  int _row = 0;
  int _reason = 1;
  String _pin = '';
  bool _pinMode = false;
  bool _busy = false;
  String? _error;
  String? _done;

  PosController get pos => context.read<PosController>();

  List<Map<String, dynamic>> get _items => ((_sale?['items'] as List?) ?? const []).cast<Map<String, dynamic>>();

  int _left(Map<String, dynamic> it) => parseQty(it['qty']) - parseQty(it['returned_qty']);

  int _lineReturn(int i) {
    final it = _items[i];
    final q = parseQty(it['qty']);
    if (q == 0) return 0;
    return parseMoney(it['total']) * _ret[i] ~/ q;
  }

  int get _total {
    var s = 0;
    for (var i = 0; i < _items.length; i++) {
      s += _lineReturn(i);
    }
    return s;
  }

  bool get _needSenior => !(pos.cashier?.can(Perm.returns) ?? false);

  Future<void> _find() async {
    final q = fixLayout(_input.trim());
    if (q.isEmpty) return;
    setState(() {
      _busy = true;
      _error = null;
      _done = null;
    });
    try {
      final sale = await pos.findSale(q);
      setState(() {
        _sale = sale;
        _ret = List.filled(_items.length, 0);
        _row = 0;
        _input = '';
      });
    } on ApiError catch (e) {
      setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _submit(String kind) async {
    if (_total <= 0) {
      setState(() => _error = tr('Отметьте, что вернуть: пробел — всю строку, цифры — количество', 'Nimani qaytarishni belgilang: probel — butun qator, raqamlar — miqdor'));
      return;
    }
    Cashier? by = pos.cashier;
    if (_needSenior) {
      if (_pin.isEmpty) {
        setState(() {
          _pinMode = true;
          _error = tr('Нужен ПИН старшего кассира', 'Katta kassirning PIN-kodi kerak');
        });
        return;
      }
      by = pos.confirm(Perm.returns, _pin);
      if (by == null) {
        setState(() {
          _pin = '';
          _error = tr('Неверный ПИН или нет права на возврат', 'PIN-kod notoʻgʻri yoki qaytarish huquqi yoʻq');
        });
        return;
      }
    }
    final method = pos.catalog.method(kind);
    if (method == null) {
      setState(() => _error = tr('В магазине нет способа оплаты «${kind == 'cash' ? 'Наличные' : 'Карта'}»', 'Doʻkonda «${kind == 'cash' ? 'Naqd pul' : 'Karta'}» toʻlov usuli yoʻq'));
      return;
    }
    setState(() => _busy = true);
    try {
      final rec = await pos.createReturn(
        sale: _sale!,
        method: method,
        items: [
          for (var i = 0; i < _items.length; i++)
            if (_ret[i] > 0) {'sale_line': _items[i]['line'], 'qty': qtyApi(_ret[i])},
        ],
        reason: _reasonText[_reason],
        by: by!,
      );
      setState(() {
        _done = tr('Возврат проведён: ${fmtMoney(rec.total)} · ${method.name}', 'Qaytarish bajarildi: ${fmtMoney(rec.total)} · ${method.name}');
        _sale = null;
        _pin = '';
        _pinMode = false;
      });
    } on ApiError catch (e) {
      setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  bool _onKey(KeyEvent e) {
    if (_busy) return true;
    final k = e.logicalKey;
    final ch = printable(e);
    if (k == LogicalKeyboardKey.escape) {
      if (_pinMode) {
        setState(() {
          _pinMode = false;
          _pin = '';
        });
      } else if (_input.isNotEmpty) {
        setState(() => _input = '');
      } else {
        Navigator.of(context).pop();
      }
      return true;
    }
    if (_sale == null) {
      if (isEnter(e)) {
        _find();
      } else if (k == LogicalKeyboardKey.backspace) {
        if (_input.isNotEmpty) setState(() => _input = _input.substring(0, _input.length - 1));
      } else if (ch != null) {
        setState(() => _input += ch);
      }
      return true;
    }
    if (_pinMode) {
      if (isEnter(e)) {
        _submit('cash');
      } else if (ch == '*' || k == LogicalKeyboardKey.numpadMultiply) {
        _submit('card');
      } else if (k == LogicalKeyboardKey.backspace) {
        if (_pin.isNotEmpty) setState(() => _pin = _pin.substring(0, _pin.length - 1));
      } else if (ch != null && RegExp(r'^[0-9]$').hasMatch(ch) && _pin.length < 6) {
        setState(() => _pin += ch);
      }
      return true;
    }
    for (var i = 0; i < 3; i++) {
      if (k == [LogicalKeyboardKey.f2, LogicalKeyboardKey.f3, LogicalKeyboardKey.f4][i]) {
        setState(() => _reason = i);
        return true;
      }
    }
    if (k == LogicalKeyboardKey.arrowDown) {
      setState(() => _row = (_row + 1).clamp(0, _items.length - 1));
    } else if (k == LogicalKeyboardKey.arrowUp) {
      setState(() => _row = (_row - 1).clamp(0, _items.length - 1));
    } else if (isEnter(e)) {
      if (_input.isNotEmpty) {
        _setQty(parseQty(_input));
      } else {
        _submit('cash');
      }
    } else if (ch == '*' || k == LogicalKeyboardKey.numpadMultiply) {
      _submit('card');
    } else if (ch == ' ') {
      final it = _items[_row];
      setState(() => _ret[_row] = _ret[_row] == 0 ? _left(it) : 0);
    } else if (k == LogicalKeyboardKey.backspace) {
      if (_input.isNotEmpty) setState(() => _input = _input.substring(0, _input.length - 1));
    } else if (ch != null && RegExp(r'^[0-9.,]$').hasMatch(ch)) {
      setState(() => _input += ch);
    } else {
      return false;
    }
    return true;
  }

  void _setQty(int q) {
    final left = _left(_items[_row]);
    setState(() {
      _input = '';
      if (q > left) {
        _error = tr('Можно вернуть не больше ${fmtQty(left)}', 'Koʻpi bilan ${fmtQty(left)} qaytarish mumkin');
      } else {
        _ret[_row] = q;
        _error = null;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final sale = _sale;
    return Scaffold(
      body: KeyCatcher(
        onKey: _onKey,
        child: Column(children: [
          const TopBar(),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                    Container(
                      height: 96,
                      padding: const EdgeInsets.symmetric(horizontal: 24),
                      decoration: BoxDecoration(
                        color: C.surface,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: C.brand, width: 2),
                      ),
                      child: Row(children: [
                        Expanded(
                          child: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.start, children: [
                            Text(tr('Возврат · отсканируйте QR с чека или наберите номер и Enter', 'Qaytarish · chekdagi QR kodni skanerlang yoki raqamni tering va Enter'), style: t(13, c: C.brand)),
                            const SizedBox(height: 4),
                            Text(
                              sale == null
                                  ? (_input.isEmpty ? (_busy ? tr('Ищем чек…', 'Chek qidirilmoqda…') : tr('Чек №…', 'Chek №…')) : _input)
                                  : tr('Чек №${sale['number']} · ${sale['cashier'] ?? ''}', 'Chek №${sale['number']} · ${sale['cashier'] ?? ''}'),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: t(26, w: FontWeight.w700),
                            ),
                          ]),
                        ),
                        if (sale != null)
                          Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.end, children: [
                            Text(tr('итог чека', 'chek jami'), style: t(14, c: C.ts)),
                            Text(fmtMoney(parseMoney(sale['total'])), style: t(30, w: FontWeight.w700)),
                          ]),
                      ]),
                    ),
                    const SizedBox(height: 12),
                    Expanded(
                      child: Container(
                        decoration: BoxDecoration(color: C.surface, borderRadius: BorderRadius.circular(12)),
                        clipBehavior: Clip.antiAlias,
                        child: sale == null
                            ? Center(
                                child: Text(_done ?? tr('Возврат проводится только онлайн: касса берёт чек с сервера', 'Qaytarish faqat onlayn: kassa chekni serverdan oladi'),
                                    style: t(16, c: _done != null ? C.success : C.td)))
                            : ListView(children: [
                                Container(
                                  color: C.subtle,
                                  padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
                                  child: Text(tr('↑↓ строка · пробел — вернуть всё · цифры + Enter — сколько вернуть', '↑↓ qator · probel — hammasini qaytarish · raqamlar + Enter — qanchasini qaytarish'),
                                      style: t(12, c: C.ts)),
                                ),
                                for (var i = 0; i < _items.length; i++) _line(i, _row == i),
                              ]),
                      ),
                    ),
                    const SizedBox(height: 12),
                    Panel(
                      padding: const EdgeInsets.all(14),
                      child: Text(
                        _input.isNotEmpty && sale != null
                            ? tr('Количество: $_input · Enter — применить к строке', 'Miqdor: $_input · Enter — qatorga qoʻllash')
                            : tr('Вернуть можно только то, что есть в чеке, и не больше купленного. Товар вернётся на склад.', 'Faqat chekdagi mahsulotni va sotib olingandan koʻp boʻlmagan miqdorda qaytarish mumkin. Mahsulot omborga qaytadi.'),
                        style: t(13, c: C.ts),
                      ),
                    ),
                  ]),
                ),
                const SizedBox(width: 16),
                SizedBox(width: 480, child: _right()),
              ]),
            ),
          ),
        ]),
      ),
    );
  }

  Widget _line(int i, bool selected) {
    final it = _items[i];
    final left = _left(it);
    final r = _ret[i];
    return Container(
      height: 52,
      padding: const EdgeInsets.symmetric(horizontal: 20),
      decoration: BoxDecoration(
        color: selected ? C.subtle : null,
        border: Border(
          bottom: const BorderSide(color: C.border),
          left: BorderSide(color: selected ? C.brand : Colors.transparent, width: 3),
        ),
      ),
      child: Row(children: [
        SizedBox(width: 36, child: Text('${it['line']}', style: t(14, c: C.td))),
        Expanded(
          child: Text('${it['product_name']}', maxLines: 1, overflow: TextOverflow.ellipsis,
              style: t(17, w: FontWeight.w500, c: left == 0 ? C.td : C.tp)),
        ),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          decoration: BoxDecoration(color: r > 0 ? C.brandSoft : C.keyBg, borderRadius: BorderRadius.circular(6)),
          child: Text(left == 0 ? tr('уже возвращено', 'allaqachon qaytarilgan') : tr('вернуть ${fmtQty(r)} из ${fmtQty(left)}', '${fmtQty(left)} dan ${fmtQty(r)} qaytarish'),
              style: t(13, w: FontWeight.w600, c: r > 0 ? C.brand : C.ts)),
        ),
        SizedBox(width: 110, child: Text(fmtMoney(parseMoney(it['price'])), textAlign: TextAlign.right, style: t(15, c: C.ts))),
        SizedBox(
          width: 120,
          child: Text(r > 0 ? fmtMoney(_lineReturn(i)) : '—', textAlign: TextAlign.right, style: t(18, w: FontWeight.w700)),
        ),
      ]),
    );
  }

  Widget _right() {
    final ready = _sale != null && !_busy;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Panel(
        color: C.dark,
        padding: const EdgeInsets.all(24),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(tr('Вернуть покупателю', 'Xaridorga qaytarish'), style: t(15, c: Colors.white70)),
          Text(fmtMoney(_sale == null ? 0 : _total), style: t(64, w: FontWeight.w800, c: Colors.white)),
          Text(tr('точную сумму посчитает сервер по оплаченному', 'aniq summani server toʻlangan summa boʻyicha hisoblaydi'), style: t(12, c: Colors.white60)),
        ]),
      ),
      const SizedBox(height: 12),
      if (_sale != null && _needSenior)
        Panel(
          color: C.warningSoft,
          padding: const EdgeInsets.all(16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(tr('Подтверждение старшего: ПИН кассира с правом на возврат', 'Katta kassir tasdigʻi: qaytarish huquqiga ega kassir PIN-kodi'), style: t(14, w: FontWeight.w600, c: C.warning)),
            const SizedBox(height: 8),
            Row(children: [
              for (var i = 0; i < 4 || i < _pin.length; i++)
                Container(
                  width: 12,
                  height: 12,
                  margin: const EdgeInsets.only(right: 8),
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: i < _pin.length ? C.tp : Colors.transparent,
                    border: Border.all(color: C.tp, width: 1.5),
                  ),
                ),
            ]),
            const SizedBox(height: 6),
            Text(_pinMode ? tr('Наберите ПИН, затем Enter (наличными) или * (на карту)', 'PIN-kodni tering, keyin Enter (naqd) yoki * (kartaga)') : tr('Касса попросит ПИН при подтверждении', 'Tasdiqlashda kassa PIN-kod soʻraydi'),
                style: t(12, c: C.warning)),
          ]),
        ),
      const SizedBox(height: 12),
      KeyCard(
        keyLabel: 'Enter',
        title: tr('Наличными', 'Naqd pulda'),
        subtitle: tr('выдать из ящика', 'gʻaladondan berish'),
        style: ready ? KeyCardStyle.primary : KeyCardStyle.dim,
        onTap: ready ? () => _submit('cash') : null,
      ),
      const SizedBox(height: 10),
      KeyCard(
        keyLabel: '*',
        title: tr('На карту', 'Kartaga'),
        subtitle: tr('деньги вернутся на карту покупателя', 'pul xaridorning kartasiga qaytadi'),
        style: ready ? KeyCardStyle.normal : KeyCardStyle.dim,
        onTap: ready ? () => _submit('card') : null,
      ),
      const SizedBox(height: 10),
      KeyCard(keyLabel: 'Esc', title: tr('Назад к продаже', 'Sotuvga qaytish'), onTap: () => Navigator.of(context).pop()),
      if (_error != null) ...[
        const SizedBox(height: 12),
        Text(_error!, style: t(14, c: C.error)),
      ],
      const Spacer(),
      Text(
        '${tr('Причина', 'Sabab')}: ${[for (var i = 0; i < 3; i++) '${_reasonKeys[i]} — ${_reasonText[i]}${i == _reason ? ' ✓' : ''}'].join(' · ')}',
        style: t(12, c: C.ts),
      ),
    ]);
  }
}
