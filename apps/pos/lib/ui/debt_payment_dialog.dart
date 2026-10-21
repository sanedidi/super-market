import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:sm_core/sm_core.dart' show parseClientQr, tr;

import '../core/catalog.dart';
import '../core/debts.dart';
import '../core/money.dart';
import '../data/api.dart';
import '../state/pos.dart';
import 'theme.dart';
import 'widgets.dart';

/// Меню смены → 7 «Погашение долга» (Figma «Касса · Погашение долга по QR
/// покупателя», ДП1–ДП4): окно сразу ждёт QR покупателя из приложения (сканер
/// читает его как штрихкод), F2 — номер телефона, как раньше. Дальше — долг →
/// сумма (по умолчанию весь долг) → наличные или карта → квитанция.
/// Работает и без связи: долг из каталога кассы и чеков смены.
/// [qr] — QR покупателя, отсканированный на экране продажи с пустым чеком.
Future<void> showDebtPaymentDialog(BuildContext context, PosController pos, {String? qr}) =>
    showDialog<void>(context: context, builder: (_) => _DebtPaymentDialog(pos: pos, qr: qr));

class _DebtPaymentDialog extends StatefulWidget {
  const _DebtPaymentDialog({required this.pos, this.qr});

  final PosController pos;
  final String? qr;

  @override
  State<_DebtPaymentDialog> createState() => _DebtPaymentDialogState();
}

class _DebtPaymentDialogState extends State<_DebtPaymentDialog> {
  /// false — ждём QR (ДП1), true — набираем номер (ДП4, F2).
  bool _byPhone = false;
  String _phone = '';
  String _amount = '';
  DebtorView? _who;
  bool _viaQr = false;
  String _kind = 'cash';
  bool _busy = false;
  String? _error;

  /// QR не подошёл (ДП3) — рамка карточки «Отсканируйте QR» красная.
  bool _qrBad = false;
  String? _done;

  /// Что напечатал сканер с прошлого Enter; QR покупателя — только цифры
  /// «99…», поэтому цифры, попавшие в номер или сумму, откатываем.
  String _burst = '';
  String _phoneBefore = '';
  String _amountBefore = '';
  Duration? _burstAt;
  Duration? _burstStart;

  /// Пачку напечатал сканер, а не человек: 8+ символов, в среднем быстрее 50 мс.
  bool get _burstScanned {
    final a = _burstStart, b = _burstAt;
    final n = _burst.trim().length;
    if (a == null || b == null || n < 8) return false;
    return (b - a).inMilliseconds < (n - 1) * 50;
  }

  PosController get pos => widget.pos;

  int get _sum => _amount.isEmpty ? (_who?.debt ?? 0) : parseMoney(_amount);

  PayMethod? get _method => pos.catalog.method(_kind);

  @override
  void initState() {
    super.initState();
    final qr = widget.qr;
    if (qr != null) WidgetsBinding.instance.addPostFrameCallback((_) => _lookupQr(qr));
  }

  void _found(DebtorView w, {required bool qr}) {
    setState(() {
      _busy = false;
      _who = w;
      _viaQr = qr;
      _qrBad = false;
      _amount = '';
      _error = w.debt <= 0 ? tr('У покупателя нет долга в этом магазине', 'Xaridorning bu doʻkonda qarzi yoʻq') : null;
      if (pos.catalog.method('cash') == null) _kind = 'card';
    });
  }

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
      _found(w, qr: false);
    } on ApiError catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = e.message;
      });
    }
  }

  /// QR покупателя (ДП2); не подошёл — ДП3 и снова ждём QR.
  Future<void> _lookupQr(String code) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final w = await pos.lookupDebtorQr(code);
      if (!mounted) return;
      _found(w, qr: true);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        // Уже выбранного покупателя не теряем — только сообщение.
        if (_who == null) _qrBad = true;
        _error = '$e';
      });
    }
  }

  void _notQr() => setState(() {
        if (_who == null) _qrBad = true;
        _error = tr('Это не QR покупателя Super Market — попросите открыть «Мой QR-код» в приложении или введите номер (F2)',
            'Bu Super Market xaridorining QR kodi emas — ilovada «Mening QR kodim»ni ochishni soʻrang yoki raqamni kiriting (F2)');
      });

  Future<void> _pay() async {
    final w = _who;
    final m = _method;
    if (w == null || _busy || _sum <= 0 || _sum > w.debt) return;
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
    if (_done != null) return;
    setState(() => _error = null);
    if (_who == null) {
      if (!_byPhone) return; // ждём QR: цифры руками не набираются (номер — F2)
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

  /// Символ с клавиатуры или сканера: копим «пачку» до Enter.
  void _char(String ch, Duration at) {
    final last = _burstAt;
    if (last != null && at - last > const Duration(milliseconds: 500)) _burst = '';
    _burstAt = at;
    if (_burst.isEmpty) {
      _phoneBefore = _phone;
      _amountBefore = _amount;
      _burstStart = at;
    }
    _burst += ch;
    _key(ch);
  }

  /// Enter: если с прошлого Enter сканер напечатал QR покупателя — ищем по нему.
  bool _scannedQr() {
    final raw = _burst.trim();
    _burst = '';
    final qr = parseClientQr(raw);
    if (qr == null) return false;
    setState(() {
      _phone = _phoneBefore;
      _amount = _amountBefore;
    });
    _lookupQr(qr.payload);
    return true;
  }

  void _enter() {
    if (_done != null) {
      Navigator.of(context).pop();
      return;
    }
    final raw = _burst.trim();
    final scanned = _burstScanned;
    if (_scannedQr() || _busy) return;
    // Сканер напечатал не QR покупателя (штрихкод товара и т. п.) — откатываем цифры.
    if (scanned && (_who != null || _byPhone)) {
      setState(() {
        _phone = _phoneBefore;
        _amount = _amountBefore;
      });
      _notQr();
      return;
    }
    if (_who != null) {
      _pay();
    } else if (_byPhone) {
      _lookup();
    } else if (raw.isNotEmpty) {
      _notQr();
    }
  }

  void _back() {
    if (_busy) return;
    if (_done != null || (_who == null && !_byPhone)) {
      Navigator.of(context).pop();
      return;
    }
    setState(() {
      if (_who != null) {
        _who = null;
        _amount = '';
      } else {
        _byPhone = false;
        _phone = '';
      }
      _error = null;
      _qrBad = false;
    });
  }

  void _toPhone() => setState(() {
        _byPhone = true;
        _qrBad = false;
        _error = null;
      });

  @override
  Widget build(BuildContext context) {
    final w = _who;
    final String sub;
    if (w != null) {
      sub = '${w.name.isEmpty ? tr('Покупатель', 'Xaridor') : w.name} · ${fmtUzPhone(w.phone)}';
    } else if (_byPhone) {
      sub = tr('Номер телефона покупателя · QR — просто отсканируйте', 'Xaridorning telefon raqami · QR — shunchaki skanerlang');
    } else {
      sub = tr('QR покупателя — сканером · F2 — по номеру телефона · Esc — назад', 'Xaridor QR kodi — skaner bilan · F2 — telefon raqami boʻyicha · Esc — orqaga');
    }
    return Focus(
      autofocus: true,
      onKeyEvent: (_, e) {
        if (e is KeyUpEvent) return KeyEventResult.ignored;
        final k = e.logicalKey;
        if (isEnter(e)) {
          // Удержанный Enter не принимает оплату и не закрывает окно сам.
          if (e is! KeyRepeatEvent) _enter();
        } else if (k == LogicalKeyboardKey.escape) {
          _back();
        } else if (k == LogicalKeyboardKey.backspace) {
          _burst = '';
          _key('⌫');
        } else if (w != null && (k == LogicalKeyboardKey.f1 || k == LogicalKeyboardKey.f2)) {
          setState(() => _kind = k == LogicalKeyboardKey.f1 ? 'cash' : 'card');
        } else if (w == null && !_byPhone && k == LogicalKeyboardKey.f2) {
          _toPhone();
        } else {
          final ch = printable(e);
          if (ch == null) return KeyEventResult.ignored;
          _char(ch, e.timeStamp);
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
              Text(sub, style: t(13, c: C.ts)),
              const SizedBox(height: 20),
              if (_done != null)
                ..._doneView()
              else if (w != null)
                ..._payView(w)
              else if (_byPhone)
                ..._phoneView()
              else
                ..._qrView(),
            ]),
          ),
        ),
      ),
    );
  }

  /// ДП1 / ДП3: ждём QR покупателя.
  List<Widget> _qrView() => [
        Container(
          padding: const EdgeInsets.all(18),
          decoration: BoxDecoration(
            color: C.surface,
            borderRadius: BorderRadius.circular(14),
            border: _qrBad ? Border.all(color: C.error, width: 2) : null,
          ),
          child: Row(children: [
            Container(
              width: 92,
              height: 92,
              decoration: BoxDecoration(color: const Color(0xFFEFF4FF), borderRadius: BorderRadius.circular(16)),
              child: const Icon(Icons.qr_code_2_rounded, size: 56, color: Color(0xFF155EEF)),
            ),
            const SizedBox(width: 18),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(tr('Отсканируйте QR покупателя', 'Xaridor QR kodini skanerlang'), style: t(22, w: FontWeight.w700)),
                const SizedBox(height: 6),
                Text(
                    tr('Покупатель открывает приложение Super Market → Профиль → «Мой QR-код». Сканер читает его как штрихкод.',
                        'Xaridor Super Market ilovasini ochadi → Profil → «Mening QR kodim». Skaner uni shtrix-kod kabi oʻqiydi.'),
                    style: t(13, c: C.ts, h: 1.35)),
                const SizedBox(height: 8),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(color: _qrBad ? C.errorSoft : const Color(0xFFEFF4FF), borderRadius: BorderRadius.circular(999)),
                  child: Text(
                    _busy
                        ? tr('Ищем покупателя…', 'Xaridor qidirilmoqda…')
                        : _qrBad
                            ? tr('QR не подошёл — ждём снова', 'QR mos kelmadi — yana kutyapmiz')
                            : tr('● Ждём QR…', '● QR kutilmoqda…'),
                    style: t(12, w: FontWeight.w600, c: _qrBad ? C.error : const Color(0xFF155EEF)),
                  ),
                ),
              ]),
            ),
          ]),
        ),
        if (_error != null) ...[
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(color: C.errorSoft, borderRadius: BorderRadius.circular(10)),
            child: Text(_error!, style: t(13, w: FontWeight.w600, c: C.error)),
          ),
        ],
        const SizedBox(height: 12),
        Material(
          color: C.surface,
          borderRadius: BorderRadius.circular(12),
          child: InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: _busy ? null : _toPhone,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              child: Row(children: [
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(tr('Нет приложения — ввести номер телефона', 'Ilova yoʻq — telefon raqamini kiritish'), style: t(15, w: FontWeight.w600)),
                    Text(tr('как раньше: 9 цифр номера', 'avvalgidek: raqamning 9 ta raqami'), style: t(12, c: C.ts)),
                  ]),
                ),
                const KeyBadge('F2', size: 40),
              ]),
            ),
          ),
        ),
        const SizedBox(height: 10),
        Text(tr('Esc — назад', 'Esc — orqaga'), style: t(12, c: C.ts)),
      ];

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

  /// ДП4: номер телефона, как раньше. Отсканированный QR тоже срабатывает.
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
      if (_viaQr) ...[
        Align(
          alignment: Alignment.centerLeft,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(color: C.successSoft, borderRadius: BorderRadius.circular(999)),
            child: Text(tr('✓ найден по QR — номер подтверждён в приложении', '✓ QR orqali topildi — raqam ilovada tasdiqlangan'),
                style: t(12, w: FontWeight.w600, c: C.success)),
          ),
        ),
        const SizedBox(height: 10),
      ],
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
