import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:sm_core/sm_core.dart' show tr;

import '../core/catalog.dart';
import '../core/debts.dart';
import '../core/money.dart';
import '../data/api.dart';
import '../state/pos.dart';
import 'theme.dart';
import 'widgets.dart';

/// Меню смены → 7 «Погашение долга» (Figma Д5): номер покупателя → долг →
/// сумма (по умолчанию весь долг) → наличные или карта → квитанция.
/// Работает и без связи: долг из каталога кассы и чеков смены.
Future<void> showDebtPaymentDialog(BuildContext context, PosController pos) =>
    showDialog<void>(context: context, builder: (_) => _DebtPaymentDialog(pos: pos));

class _DebtPaymentDialog extends StatefulWidget {
  const _DebtPaymentDialog({required this.pos});

  final PosController pos;

  @override
  State<_DebtPaymentDialog> createState() => _DebtPaymentDialogState();
}

class _DebtPaymentDialogState extends State<_DebtPaymentDialog> {
  String _phone = '';
  String _amount = '';
  DebtorView? _who;
  String _kind = 'cash';
  bool _busy = false;
  String? _error;
  String? _done;

  PosController get pos => widget.pos;

  int get _sum => _amount.isEmpty ? (_who?.debt ?? 0) : parseMoney(_amount);

  PayMethod? get _method => pos.catalog.method(_kind);

  Future<void> _lookup() async {
    final phone = uzPhone(_phone);
    if (phone == null) {
      setState(() => _error = tr('Наберите 9 цифр номера: 90 123 45 67', 'Raqamning 9 ta raqamini tering: 90 123 45 67'));
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final w = await pos.lookupDebtor(phone);
      if (!mounted) return;
      setState(() {
        _busy = false;
        _who = w;
        if (w.debt <= 0) _error = tr('У покупателя нет долга в этом магазине', 'Xaridorning bu doʻkonda qarzi yoʻq');
        if (pos.catalog.method('cash') == null) _kind = 'card';
      });
    } on ApiError catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = e.message;
      });
    }
  }

  Future<void> _pay() async {
    final w = _who;
    final m = _method;
    if (w == null || _busy) return;
    if (m == null) {
      setState(() => _error = tr('В магазине нет такого способа оплаты', 'Doʻkonda bunday toʻlov usuli yoʻq'));
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final r = await pos.recordDebtPayment(who: w, amount: _sum, method: m);
      if (!mounted) return;
      setState(() {
        _busy = false;
        _done = r.balance > 0
            ? tr('Принято ${fmtMoney(r.amount)} · остаток долга ${fmtMoney(r.balance)}', 'Qabul qilindi ${fmtMoney(r.amount)} · qarz qoldigʻi ${fmtMoney(r.balance)}')
            : tr('Принято ${fmtMoney(r.amount)} · долг погашен полностью', 'Qabul qilindi ${fmtMoney(r.amount)} · qarz toʻliq toʻlandi');
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = '$e';
      });
    }
  }

  void _key(String k) {
    setState(() => _error = null);
    if (_who == null) {
      if (k == '⌫') {
        if (_phone.isNotEmpty) setState(() => _phone = _phone.substring(0, _phone.length - 1));
      } else if (RegExp(r'^[0-9]$').hasMatch(k) && _phone.length < 9) {
        setState(() => _phone += k);
      }
      return;
    }
    if (k == '⌫') {
      if (_amount.isNotEmpty) setState(() => _amount = _amount.substring(0, _amount.length - 1));
    } else if (RegExp(r'^[0-9]+$').hasMatch(k) && _amount.length + k.length <= 10 && !(_amount.isEmpty && k.length > 1)) {
      setState(() => _amount += k);
    }
  }

  void _enter() {
    if (_done != null) {
      Navigator.of(context).pop();
    } else if (_who == null) {
      _lookup();
    } else {
      _pay();
    }
  }

  void _back() {
    if (_who == null || _done != null) {
      Navigator.of(context).pop();
      return;
    }
    setState(() {
      _who = null;
      _amount = '';
      _error = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final w = _who;
    return Focus(
      autofocus: true,
      onKeyEvent: (_, e) {
        if (e is KeyUpEvent) return KeyEventResult.ignored;
        final k = e.logicalKey;
        if (isEnter(e)) {
          _enter();
        } else if (k == LogicalKeyboardKey.escape) {
          _back();
        } else if (k == LogicalKeyboardKey.backspace) {
          _key('⌫');
        } else if (w != null && (k == LogicalKeyboardKey.f1 || k == LogicalKeyboardKey.f2)) {
          setState(() => _kind = k == LogicalKeyboardKey.f1 ? 'cash' : 'card');
        } else {
          final ch = printable(e);
          if (ch == null) return KeyEventResult.ignored;
          _key(ch);
        }
        return KeyEventResult.handled;
      },
      child: Dialog(
        backgroundColor: C.page,
        insetPadding: const EdgeInsets.all(16),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 620),
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(32, 28, 32, 28),
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Text(tr('Погашение долга', 'Qarzni toʻlash'), style: t(26, w: FontWeight.w700)),
              const SizedBox(height: 4),
              Text(w == null ? tr('Номер телефона покупателя', 'Xaridorning telefon raqami') : '${w.name.isEmpty ? tr('Покупатель', 'Xaridor') : w.name} · ${fmtUzPhone(w.phone)}',
                  style: t(13, c: C.ts)),
              const SizedBox(height: 20),
              if (_done != null) ..._doneView() else if (w == null) ..._phoneView() else ..._payView(w),
            ]),
          ),
        ),
      ),
    );
  }

  Widget _box(String label, String value, {bool dim = false}) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
        decoration: BoxDecoration(color: C.surface, borderRadius: BorderRadius.circular(16), border: Border.all(color: C.brand, width: 2)),
        child: Row(children: [
          Expanded(child: Text(label, style: t(16, w: FontWeight.w500, c: C.ts))),
          Text(value, style: t(36, w: FontWeight.w800, c: dim ? C.td : C.tp)),
        ]),
      );

  Widget _hint() => Padding(
        padding: const EdgeInsets.only(top: 10),
        child: Text(_error ?? (_busy ? tr('Подождите…', 'Kuting…') : tr('Enter — дальше · Esc — назад', 'Enter — keyingi · Esc — orqaga')), style: t(12, c: _error != null ? C.error : C.ts)),
      );

  List<Widget> _phoneView() => [
        _box('+998', _phone.isEmpty ? '90 123 45 67' : fmtLocalDigits(_phone), dim: _phone.isEmpty),
        const SizedBox(height: 12),
        _NumPad(onKey: _key),
        const SizedBox(height: 12),
        _Primary(label: _busy ? tr('Ищем…', 'Qidirilmoqda…') : tr('Найти · Enter', 'Topish · Enter'), onTap: _phone.length == 9 && !_busy ? _lookup : null),
        _hint(),
      ];

  List<Widget> _payView(DebtorView w) {
    Widget kind(String k, String key, String label) {
      final on = _kind == k;
      final ok = pos.catalog.method(k) != null;
      return Expanded(
        child: Opacity(
          opacity: ok ? 1 : 0.4,
          child: Material(
            color: on ? C.brandSoft : C.surface,
            borderRadius: BorderRadius.circular(14),
            child: InkWell(
              borderRadius: BorderRadius.circular(14),
              onTap: ok ? () => setState(() => _kind = k) : null,
              child: Container(
                padding: const EdgeInsets.symmetric(vertical: 12),
                decoration: BoxDecoration(borderRadius: BorderRadius.circular(14), border: Border.all(color: on ? C.brand : C.border)),
                child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                  KeyBadge(key, size: 32),
                  const SizedBox(width: 8),
                  Text(label, style: t(16, w: FontWeight.w600, c: on ? C.brand : C.tp)),
                ]),
              ),
            ),
          ),
        ),
      );
    }

    final sum = _sum;
    final valid = sum > 0 && sum <= w.debt;
    return [
      Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(color: C.surface, borderRadius: BorderRadius.circular(12)),
        child: Row(children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(tr('Долг в магазине', 'Doʻkondagi qarz'), style: t(12, c: C.ts)),
              Text(fmtMoney(w.debt), style: t(26, w: FontWeight.w800, c: w.debt > 0 ? C.brand : C.tp)),
            ]),
          ),
          if (w.overdueDays > 0) Text(tr('просрочка ${w.overdueDays} дн.', '${w.overdueDays} kun kechikkan'), style: t(13, w: FontWeight.w600, c: C.warning)),
          if (w.dueDate != null && w.overdueDays == 0) Text(tr('срок ${w.dueDate}', 'muddat ${w.dueDate}'), style: t(13, c: C.ts)),
        ]),
      ),
      if (!w.online) ...[
        const SizedBox(height: 6),
        Text(tr('Нет связи: долг из каталога кассы и чеков этой смены', 'Aloqa yoʻq: qarz kassa katalogi va shu smena cheklaridan olindi'), style: t(12, c: C.warning)),
      ],
      const SizedBox(height: 12),
      _box(_amount.isEmpty ? tr('Принять · весь долг', 'Qabul qilish · butun qarz') : tr('Принять', 'Qabul qilish'), sum > 0 ? fmtMoney(sum) : '—'),
      if (valid && sum < w.debt)
        Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Text(tr('Останется долг ${fmtMoney(w.debt - sum)}', 'Qarz qoladi: ${fmtMoney(w.debt - sum)}'), style: t(13, c: C.ts)),
        ),
      const SizedBox(height: 12),
      Row(children: [kind('cash', 'F1', tr('Наличные', 'Naqd pul')), const SizedBox(width: 10), kind('card', 'F2', tr('Карта', 'Karta'))]),
      const SizedBox(height: 12),
      _NumPad(onKey: _key, extra: '000'),
      const SizedBox(height: 12),
      _Primary(label: _busy ? tr('Сохраняем…', 'Saqlanmoqda…') : tr('Принять ${fmtMoney(sum)} · Enter', '${fmtMoney(sum)} qabul qilish · Enter'), onTap: valid && !_busy ? _pay : null),
      _hint(),
    ];
  }

  List<Widget> _doneView() => [
        Container(
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(color: C.successSoft, borderRadius: BorderRadius.circular(16)),
          child: Text(_done!, style: t(20, w: FontWeight.w700, c: C.success)),
        ),
        const SizedBox(height: 8),
        Text(tr('Квитанция печатается. Покупатель увидит оплату в приложении после отправки на сервер.', 'Kvitansiya chop etilmoqda. Xaridor toʻlovni serverga yuborilgach ilovada koʻradi.'), style: t(12, c: C.ts)),
        const SizedBox(height: 12),
        _Primary(label: tr('Готово · Enter', 'Tayyor · Enter'), onTap: () => Navigator.of(context).pop()),
      ];
}

class _Primary extends StatelessWidget {
  const _Primary({required this.label, this.onTap});

  final String label;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => Opacity(
        opacity: onTap == null ? 0.35 : 1,
        child: Material(
          color: C.brand,
          borderRadius: BorderRadius.circular(14),
          child: InkWell(
            borderRadius: BorderRadius.circular(14),
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 18),
              child: Center(child: Text(label, style: t(19, w: FontWeight.w700, c: Colors.white))),
            ),
          ),
        ),
      );
}

class _NumPad extends StatelessWidget {
  const _NumPad({required this.onKey, this.extra = ''});

  final void Function(String key) onKey;
  final String extra;

  @override
  Widget build(BuildContext context) {
    Widget key(String k) => Expanded(
          child: Padding(
            padding: const EdgeInsets.all(5),
            child: Material(
              color: C.surface,
              borderRadius: BorderRadius.circular(14),
              child: InkWell(
                borderRadius: BorderRadius.circular(14),
                onTap: k.isEmpty ? null : () => onKey(k),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: Center(
                    child: k == '⌫' ? const Icon(Icons.backspace_outlined, size: 24, color: C.tp) : Text(k, style: t(24, w: FontWeight.w500)),
                  ),
                ),
              ),
            ),
          ),
        );
    return Column(children: [
      for (final row in [
        ['1', '2', '3'],
        ['4', '5', '6'],
        ['7', '8', '9'],
        [extra, '0', '⌫'],
      ])
        Row(children: [for (final k in row) key(k)]),
    ]);
  }
}
