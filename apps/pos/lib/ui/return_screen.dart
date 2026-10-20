import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:sm_core/sm_core.dart' show tr;

import '../core/catalog.dart';
import '../core/codes.dart';
import '../core/money.dart';
import '../data/api.dart';
import '../state/pos.dart';
import 'kit.dart';
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
    final d = densityOf(context);
    final g = d == Density.l ? 8.0 : 6.0;
    final side = switch (d) { Density.l => 300.0, Density.m => 272.0, Density.s => 248.0 };
    final hint = _input.isNotEmpty && sale != null
        ? tr('Количество: $_input · Enter — применить к строке', 'Miqdor: $_input · Enter — qatorga qoʻllash')
        : sale == null
            ? tr('Возврат проводится только онлайн: касса берёт чек с сервера', 'Qaytarish faqat onlayn: kassa chekni serverdan oladi')
            : tr('↑↓ строка · пробел — вернуть всё · цифры + Enter — сколько вернуть. Вернуть можно только то, что есть в чеке.',
                '↑↓ qator · probel — hammasini qaytarish · raqamlar + Enter — qanchasini qaytarish. Faqat chekdagi mahsulotni qaytarish mumkin.');
    final doc = Container(
      decoration: BoxDecoration(color: C.surface, borderRadius: BorderRadius.circular(10), border: Border.all(color: C.border)),
      clipBehavior: Clip.antiAlias,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Container(
          height: 32,
          padding: const EdgeInsets.symmetric(horizontal: 14),
          color: C.errorSoft,
          child: Row(children: [
            Text(tr('ВОЗВРАТ', 'QAYTARISH'), style: t(12.5, w: FontWeight.w700, c: C.error)),
            const SizedBox(width: 8),
            Expanded(
              child: FitText(
                sale == null
                    ? tr('·  отсканируйте QR с чека или наберите номер и Enter', '·  chekdagi QR kodni skanerlang yoki raqamni tering va Enter')
                    : tr('·  ПО ЧЕКУ №${sale['number']}  ·  ${sale['cashier'] ?? ''}', '·  CHEK №${sale['number']} BOʻYICHA  ·  ${sale['cashier'] ?? ''}'),
                style: t(12.5, w: FontWeight.w600, c: C.t2),
              ),
            ),
          ]),
        ),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(children: [
              Expanded(
                child: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.start, children: [
                  FitText(
                    sale == null
                        ? (_input.isEmpty ? (_busy ? tr('Ищем чек…', 'Chek qidirilmoqda…') : tr('Чек №…', 'Chek №…')) : _input)
                        : tr('Итог чека ${fmtMoney(parseMoney(sale['total']))}', 'Chek jami ${fmtMoney(parseMoney(sale['total']))}'),
                    style: t(d == Density.s ? 20 : 24, w: FontWeight.w700),
                  ),
                  if (_done != null) FitText(_done!, maxLines: 2, style: t(14, w: FontWeight.w600, c: C.success)),
                ]),
              ),
              const SizedBox(width: 12),
              Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.end, children: [
                Text(tr('К возврату:', 'Qaytarishga:'), style: t(14, w: FontWeight.w600, c: C.error)),
                Text(fmtMoney(sale == null ? 0 : _total), style: tb(d == Density.s ? 40 : 48, c: C.brandDark, h: 1.05)),
              ]),
            ]),
          ),
        ),
      ]),
    );
    final table = Container(
      decoration: BoxDecoration(color: C.surface, borderRadius: BorderRadius.circular(10), border: Border.all(color: C.border)),
      clipBehavior: Clip.antiAlias,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Container(
          height: 30,
          padding: const EdgeInsets.symmetric(horizontal: 14),
          decoration: const BoxDecoration(color: C.subtle, border: Border(bottom: BorderSide(color: C.border))),
          child: Row(children: [
            SizedBox(width: 36, child: Text('#', style: t(11, w: FontWeight.w700, c: C.td))),
            Expanded(child: Text(tr('НАИМЕНОВАНИЕ', 'NOMI'), style: t(11, w: FontWeight.w700, c: C.td))),
            SizedBox(width: d == Density.s ? 150 : 190, child: Text(tr('ВЕРНУТЬ', 'QAYTARISH'), textAlign: TextAlign.center, style: t(11, w: FontWeight.w700, c: C.td))),
            if (d != Density.s) SizedBox(width: 100, child: Text(tr('ЦЕНА', 'NARX'), textAlign: TextAlign.right, style: t(11, w: FontWeight.w700, c: C.td))),
            SizedBox(width: 110, child: Text(tr('СУММА', 'SUMMA'), textAlign: TextAlign.right, style: t(11, w: FontWeight.w700, c: C.td))),
          ]),
        ),
        Expanded(
          child: sale == null
              ? Center(child: Padding(padding: const EdgeInsets.all(24), child: Text(hint, textAlign: TextAlign.center, style: t(15, c: C.td))))
              : SnapList(
                  count: _items.length,
                  extent: 52,
                  focus: _row,
                  itemBuilder: (_, i) => _line(i, _row == i, d),
                  above: (n) => tr('Ещё $n выше', 'Yana $n yuqorida'),
                  below: (n) => tr('Ещё $n ниже', 'Yana $n pastda'),
                  startLabel: tr('Начало чека', 'Chek boshi'),
                  endLabel: tr('Конец чека', 'Chek oxiri'),
                ),
        ),
        if (sale != null)
          Container(
            padding: const EdgeInsets.fromLTRB(14, 8, 14, 8),
            decoration: const BoxDecoration(color: C.subtle, border: Border(top: BorderSide(color: C.border))),
            child: FitText(hint, maxLines: 2, style: t(12.5, c: C.ts)),
          ),
      ]),
    );
    return Scaffold(
      body: KeyCatcher(
        onKey: _onKey,
        child: Column(children: [
          const TopBar(),
          Expanded(
            child: Padding(
              padding: EdgeInsets.all(g),
              child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                    SizedBox(height: d == Density.s ? 112 : 132, child: doc),
                    SizedBox(height: g),
                    Expanded(child: table),
                  ]),
                ),
                SizedBox(width: g),
                SizedBox(width: side, child: _right(d, g)),
              ]),
            ),
          ),
        ]),
      ),
    );
  }

  Widget _line(int i, bool selected, Density d) {
    final it = _items[i];
    final left = _left(it);
    final r = _ret[i];
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => setState(() => _row = i),
      child: Container(
        padding: EdgeInsets.only(left: selected ? 10 : 14, right: 14),
        decoration: BoxDecoration(
          color: selected ? C.errorSoft : C.surface,
          border: Border(
            bottom: const BorderSide(color: C.border),
            left: selected ? const BorderSide(color: C.error, width: 4) : BorderSide.none,
          ),
        ),
        child: Row(children: [
          SizedBox(width: 36, child: Text('${it['line']}', style: t(14, c: C.td))),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(right: 8),
              child: FitText('${it['product_name']}', maxLines: 2, style: t(15, w: FontWeight.w500, c: left == 0 ? C.td : C.tp)),
            ),
          ),
          SizedBox(
            width: d == Density.s ? 150 : 190,
            child: Center(
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(color: r > 0 ? C.brandSoft : C.keyBg, borderRadius: BorderRadius.circular(6)),
                child: FitText(
                  left == 0 ? tr('уже возвращено', 'allaqachon qaytarilgan') : tr('${fmtQty(r)} из ${fmtQty(left)}', '${fmtQty(left)} dan ${fmtQty(r)}'),
                  textAlign: TextAlign.center,
                  style: t(13, w: FontWeight.w600, c: r > 0 ? C.brand : C.ts),
                ),
              ),
            ),
          ),
          if (d != Density.s) SizedBox(width: 100, child: Text(fmtMoney(parseMoney(it['price'])), textAlign: TextAlign.right, style: t(15, c: C.ts))),
          SizedBox(
            width: 110,
            child: Text(r > 0 ? fmtMoney(_lineReturn(i)) : '—', textAlign: TextAlign.right, style: t(16, w: FontWeight.w700)),
          ),
        ]),
      ),
    );
  }

  Widget _right(Density d, double g) {
    final ready = _sale != null && !_busy;
    Widget big(String label, String hint, IconData icon, Color bg, Color fg, VoidCallback? onTap, {Color? border}) => Opacity(
          opacity: onTap == null ? 0.45 : 1,
          child: Material(
            color: bg,
            borderRadius: BorderRadius.circular(10),
            child: InkWell(
              borderRadius: BorderRadius.circular(10),
              onTap: onTap,
              child: Container(
                height: d == Density.l ? 72 : 62,
                padding: const EdgeInsets.symmetric(horizontal: 14),
                decoration: border == null ? null : BoxDecoration(borderRadius: BorderRadius.circular(10), border: Border.all(color: border)),
                child: Row(children: [
                  Icon(icon, color: fg, size: 26),
                  const SizedBox(width: 12),
                  Expanded(child: FitText(label, style: tb(d == Density.l ? 22 : 19, c: fg))),
                  Text(hint, style: t(13, w: FontWeight.w700, c: fg.withValues(alpha: 0.7))),
                ]),
              ),
            ),
          ),
        );
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      big(tr('Вернуть наличными', 'Naqd qaytarish'), 'Enter', Icons.payments_outlined, C.brandDark, Colors.white, ready ? () => _submit('cash') : null),
      SizedBox(height: g),
      big(tr('На карту', 'Kartaga'), '*', Icons.credit_card_rounded, C.surface, C.tp, ready ? () => _submit('card') : null, border: C.borderStrong),
      if (_sale != null && _needSenior) ...[
        SizedBox(height: g),
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(color: C.warningSoft, borderRadius: BorderRadius.circular(10)),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            FitText(tr('ПИН старшего с правом на возврат', 'Qaytarish huquqiga ega katta kassir PIN-kodi'), maxLines: 2, style: t(13, w: FontWeight.w600, c: C.warning)),
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
            FitText(
              _pinMode ? tr('Наберите ПИН, затем Enter или *', 'PIN-kodni tering, keyin Enter yoki *') : tr('Касса попросит ПИН при подтверждении', 'Tasdiqlashda kassa PIN-kod soʻraydi'),
              maxLines: 2,
              style: t(12, c: C.warning),
            ),
          ]),
        ),
      ],
      SizedBox(height: g),
      Text(tr('ПРИЧИНА', 'SABAB'), style: t(11.5, w: FontWeight.w700, c: C.td)),
      const SizedBox(height: 4),
      for (var i = 0; i < 3; i++)
        Padding(
          padding: EdgeInsets.only(bottom: g),
          child: PosButton(
            label: _reasonText[i],
            hint: _reasonKeys[i],
            height: 46,
            bg: i == _reason ? C.brandSoft : C.surface,
            fg: i == _reason ? C.brand : C.tp,
            border: i == _reason ? C.brand : C.borderStrong,
            onTap: () => setState(() => _reason = i),
          ),
        ),
      if (_error != null)
        Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(color: C.errorSoft, borderRadius: BorderRadius.circular(8)),
          child: FitText(_error!, maxLines: 3, style: t(13, w: FontWeight.w600, c: C.error)),
        ),
      const Spacer(),
      PosButton(
        label: tr('К продаже', 'Sotuvga'),
        hint: 'Esc',
        icon: Icons.undo_rounded,
        height: 56,
        onTap: () => Navigator.of(context).pop(),
      ),
    ]);
  }
}
