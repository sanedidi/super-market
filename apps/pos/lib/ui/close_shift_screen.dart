import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:sm_core/sm_core.dart' show tr;

import '../core/journal.dart';
import '../core/money.dart';
import '../state/pos.dart';
import 'kit.dart';
import 'theme.dart';
import 'widgets.dart';

/// Закрыть день (Figma «Касса · Закрыть день — одной кнопкой, пересчёт по
/// желанию»):
/// - ЗД1 — итоги дня и сумма в ящике по расчёту; Enter — день закрывается по
///   расчёту и печатается отчёт, считать деньги не нужно;
/// - ЗД2 — F2 «Пересчитать ящик»: слепой ввод суммы, Enter — сверить, потом
///   Enter — закрыть; расхождение не блокирует, причина F2/F3/F4 по желанию;
/// - ЗД4 — владелец включил «Требовать пересчёт»: сразу пересчёт, быстрого
///   закрытия нет; то же, когда подошёл срок пересчёта по настройке магазина
///   (каждый день / раз в 7 дней);
/// - ЗД6 — норма размена магазина: в ящике остаётся размен, остальное — «К
///   сдаче» владельцу; F3 — поменять размен на этот раз.
class CloseShiftScreen extends StatefulWidget {
  const CloseShiftScreen({super.key});

  @override
  State<CloseShiftScreen> createState() => _CloseShiftScreenState();
}

Map<LogicalKeyboardKey, String> get _reasons => {
      LogicalKeyboardKey.f2: tr('Сдача без мелочи', 'Qaytim mayda pulsiz berildi'),
      LogicalKeyboardKey.f3: tr('Ошибка в чеке', 'Chekdagi xato'),
      LogicalKeyboardKey.f4: tr('Другое', 'Boshqa'),
    };

class _CloseShiftScreenState extends State<CloseShiftScreen> {
  /// Пересчёт ящика (ЗД2 / ЗД4).
  bool _counting = false;

  /// Сумма в ящике цифрами, без пробелов (сумы).
  String _input = '';

  /// Сверено с расчётом: видно, сколько должно быть.
  bool _revealed = false;
  String? _reason;

  /// F3 — сколько оставить в ящике на размен на этот раз (ЗД6). null — по
  /// норме магазина.
  int? _leave;
  bool _editingLeave = false;
  String _leaveInput = '';
  bool _busy = false;
  String? _error;

  /// Сканер на этом экране: штрихкод не становится суммой в ящике, а его
  /// Enter не сверяет и не закрывает день.
  late final _scan = ScanGuard(
    snapshot: () {
      final input = _input, counting = _counting, revealed = _revealed;
      return () {
        _input = input;
        _counting = counting;
        _revealed = revealed;
      };
    },
    onScan: (_) {
      if (!mounted) return;
      SystemSound.play(SystemSoundType.alert);
      setState(() => _error = scanRejected);
    },
  );

  int get _counted => parseMoney(_input);

  bool get _required => context.read<PosController>().recountDue;

  @override
  void initState() {
    super.initState();
    _counting = context.read<PosController>().recountDue;
  }

  @override
  void dispose() {
    _scan.dispose();
    super.dispose();
  }

  void _typeLeave(String d) {
    if (_leaveInput.length + d.length > 11) return;
    if ((_leaveInput.isEmpty || _leaveInput == '0') && d.startsWith('0')) {
      if (d == '0' && _leaveInput.isEmpty) setState(() => _leaveInput = '0');
      return;
    }
    setState(() => _leaveInput = _leaveInput == '0' ? d : _leaveInput + d);
  }

  void _startLeave() => setState(() {
        _editingLeave = true;
        _leaveInput = '';
        _error = null;
      });

  void _eraseLeave() {
    if (_leaveInput.isNotEmpty) setState(() => _leaveInput = _leaveInput.substring(0, _leaveInput.length - 1));
  }

  /// Enter — размен на этот раз записан; Esc — оставить по норме.
  void _confirmLeave() => setState(() {
        _leave = parseMoney(_leaveInput);
        _editingLeave = false;
      });

  void _cancelLeave() => setState(() {
        _leave = null;
        _editingLeave = false;
      });

  void _type(String d) {
    if (_input.length + d.length > 11) return;
    if ((_input.isEmpty || _input == '0') && d.startsWith('0')) {
      if (d == '0' && _input.isEmpty) _edited(() => _input = '0');
      return;
    }
    _edited(() => _input = _input == '0' ? d : _input + d);
  }

  void _erase() {
    if (_input.isNotEmpty) _edited(() => _input = _input.substring(0, _input.length - 1));
  }

  void _edited(VoidCallback change) => setState(() {
        change();
        _error = null;
      });

  void _startCount() => setState(() {
        _counting = true;
        _error = null;
      });

  /// Esc в пересчёте по желанию — обратно к ЗД1, день открыт.
  void _back() {
    if (_counting && !_required) {
      setState(() {
        _counting = false;
        _revealed = false;
        _input = '';
        _reason = null;
        _error = null;
      });
      return;
    }
    Navigator.of(context).pop();
  }

  void _enter() {
    if (!_counting) {
      _close();
      return;
    }
    if (!_revealed) {
      if (_input.isEmpty) {
        setState(() => _error = tr('Наберите, сколько наличных в ящике (пусто — 0)', 'Gʻaladonda qancha naqd pul borligini tering (boʻsh — 0)'));
        return;
      }
      setState(() {
        _revealed = true;
        _error = null;
      });
      return;
    }
    _close();
  }

  Future<void> _close() async {
    if (_busy) return;
    final pos = context.read<PosController>();
    final counted = _counting ? _counted : null;
    final reason = counted != null && counted != pos.report.expectedCash ? (_reason ?? '') : '';
    setState(() => _busy = true);
    try {
      await pos.closeShift(counted, reason, leave: _leave);
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = '$e';
        });
      }
      return;
    }
    if (mounted) Navigator.of(context).popUntil((r) => r.isFirst);
  }

  bool _onKey(KeyEvent e) {
    if (_busy) return true;
    if (_scan.key(e)) return true;
    final k = e.logicalKey;
    final ch = printable(e);
    if (_editingLeave && k == LogicalKeyboardKey.escape) {
      _cancelLeave();
      return true;
    }
    if (_editingLeave && isEnter(e)) {
      if (e is KeyDownEvent) _confirmLeave();
      return true;
    }
    if (k == LogicalKeyboardKey.escape) {
      _back();
      return true;
    }
    if (isEnter(e)) {
      // Только нажатие: удержанный Enter с прошлого экрана не закрывает день.
      if (e is KeyDownEvent) _enter();
      return true;
    }
    final digit = ch != null && RegExp(r'^[0-9]$').hasMatch(ch);
    if (_editingLeave) {
      if (digit) {
        _typeLeave(ch);
      } else if (k == LogicalKeyboardKey.backspace) {
        _eraseLeave();
      }
      return true;
    }
    if (!_counting) {
      if (k == LogicalKeyboardKey.f3) {
        _startLeave();
        return true;
      }
      if (k == LogicalKeyboardKey.f2) {
        _startCount();
        return true;
      }
      // Начали набирать цифры — это пересчёт.
      if (digit) {
        _startCount();
        _type(ch);
        return true;
      }
      return false;
    }
    if (_revealed && _reasons.containsKey(k)) {
      setState(() {
        _reason = _reason == _reasons[k] ? null : _reasons[k];
        _error = null;
      });
      return true;
    }
    if (k == LogicalKeyboardKey.backspace) {
      _erase();
      return true;
    }
    if (digit) {
      _type(ch);
      return true;
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    final pos = context.watch<PosController>();
    final shift = pos.shift;
    if (shift == null) return const Scaffold();
    final rep = pos.report;
    final expected = rep.expectedCash;
    final no = shift.number ?? '·';
    final mustCount = pos.recountDue;
    final diff = _counted - expected;
    final printed = pos.printer.enabled;

    final String title;
    final String subtitle;
    if (!_counting) {
      title = tr('Закрыть день  ·  смена №$no', 'Kunni yopish  ·  smena №$no');
      subtitle = pos.catalog.settings.cashFloat == null
          ? tr('Enter — день закроется и напечатается отчёт. Считать деньги в ящике не обязательно.',
              'Enter — kun yopiladi va hisobot chop etiladi. Gʻaladondagi pulni sanash shart emas.')
          : tr('Enter — день закроется, в ящике останется размен по норме магазина, остальное — «К сдаче» владельцу. Считать деньги не обязательно.',
              'Enter — kun yopiladi, gʻaladonda doʻkon meʼyori boʻyicha maydalik qoladi, qolgani — egasiga «Topshirish». Pulni sanash shart emas.');
    } else if (mustCount) {
      title = tr('Закрыть день  ·  смена №$no', 'Kunni yopish  ·  smena №$no');
      subtitle = tr('Сегодня нужен пересчёт ящика — так настроил владелец: пересчитайте наличные в ящике и наберите сумму.',
          'Bugun gʻaladonni sanash kerak — egasi shunday sozlagan: gʻaladondagi naqd pulni sanang va summani tering.');
    } else {
      title = tr('Пересчёт ящика  ·  смена №$no', 'Gʻaladonni sanash  ·  smena №$no');
      subtitle = tr('Наберите, сколько наличных в ящике. Сходится или нет — день всё равно закроется.',
          'Gʻaladonda qancha naqd pul borligini tering. Mos keladimi yoki yoʻqmi — kun baribir yopiladi.');
    }

    // Подпись под «Закрыть день»: с недостачей / с излишком / отчёт.
    final report = printed ? tr('напечатаем отчёт', 'hisobotni chop etamiz') : tr('отчёт — когда подключите принтер', 'hisobot — printer ulanganda');
    // ЗД6: сколько остаётся на размен и сколько «К сдаче». При слепом
    // пересчёте не показываем — иначе видно, сколько должно быть.
    final showHand = !_counting || _revealed;
    final inDrawer = _counting ? _counted : expected;
    final keep = _leave == null ? pos.floatFor(inDrawer) : (_leave! < inDrawer ? _leave! : inDrawer);
    final String closeSub;
    if (showHand && keep != null) {
      closeSub = tr('в ящике ${fmtMoney(keep)} · к сдаче ${fmtMoney(inDrawer - keep)} · $report',
          'gʻaladonda ${fmtMoney(keep)} · topshirish ${fmtMoney(inDrawer - keep)} · $report');
    } else if (_counting && _revealed && diff < 0) {
      closeSub = tr('с недостачей ${fmtMoney(diff)} — $report', 'kamomad ${fmtMoney(diff)} bilan — $report');
    } else if (_counting && _revealed && diff > 0) {
      closeSub = tr('с излишком +${fmtMoney(diff)} — $report', 'ortiqcha +${fmtMoney(diff)} bilan — $report');
    } else {
      closeSub = printed ? tr('напечатаем отчёт за день', 'kunlik hisobotni chop etamiz') : report;
    }

    final right = <Widget>[
      if (!_counting)
        _DarkCard(
          label: tr('В ящике по расчёту', 'Hisob boʻyicha gʻaladonda'),
          amount: expected,
          note: tr('размен ${fmtMoney(shift.openingCash)} + наличными ${fmtMoney(expected - shift.openingCash)}',
              'maydalik ${fmtMoney(shift.openingCash)} + naqd ${fmtMoney(expected - shift.openingCash)}'),
        )
      else
        _DarkCard(
          label: tr('Посчитано в ящике', 'Gʻaladonda sanaldi'),
          amount: _counted,
          note: _revealed ? tr('сверено с кассой — результат ниже', 'kassa bilan solishtirildi — natija pastda') : tr('Enter — сверить с расчётом', 'Enter — hisob bilan solishtirish'),
        ),
      const SizedBox(height: 12),
      if (_counting && _revealed) ...[
        _Result(expected: expected, diff: diff, reason: _reason),
        const SizedBox(height: 12),
      ],
      if (showHand && keep != null) ...[
        GestureDetector(
          onTap: _counting || _editingLeave ? null : _startLeave,
          child: _HandBox(keep: keep, toHand: inDrawer - keep, changed: _leave != null, editable: !_counting),
        ),
        const SizedBox(height: 12),
      ],
      _QueueNote(queue: pos.queue, failed: pos.failed),
      const Spacer(),
      if (_error != null) Padding(padding: const EdgeInsets.only(bottom: 8), child: Text(_error!, style: t(14, c: C.error))),
      if (_editingLeave) ...[
        KeyCard(
          keyLabel: 'Enter',
          title: tr('Готово', 'Tayyor'),
          subtitle: tr('оставить ${fmtMoney(parseMoney(_leaveInput))} на размен', '${fmtMoney(parseMoney(_leaveInput))} maydalikka qoldirish'),
          style: KeyCardStyle.primary,
          onTap: _confirmLeave,
        ),
        const SizedBox(height: 12),
        KeyCard(
          keyLabel: 'Esc',
          title: tr('По норме', 'Meʼyor boʻyicha'),
          subtitle: tr('оставить размен по норме магазина', 'doʻkon meʼyori boʻyicha maydalik qoldirish'),
          onTap: _cancelLeave,
        ),
      ] else ...[
      if (_counting && !_revealed)
        KeyCard(
          keyLabel: 'Enter',
          title: tr('Сверить с расчётом', 'Hisob bilan solishtirish'),
          subtitle: tr('покажем, сколько должно быть, и закроем день', 'qancha boʻlishi kerakligini koʻrsatamiz va kunni yopamiz'),
          style: KeyCardStyle.primary,
          onTap: _enter,
        )
      else
        KeyCard(
          keyLabel: 'Enter',
          title: _busy ? tr('Закрываем…', 'Yopilmoqda…') : tr('Закрыть день', 'Kunni yopish'),
          subtitle: closeSub,
          style: KeyCardStyle.primary,
          onTap: _busy ? null : _enter,
        ),
      const SizedBox(height: 12),
      if (!_counting) ...[
        KeyCard(
          keyLabel: 'F2',
          title: tr('Пересчитать ящик', 'Gʻaladonni sanash'),
          subtitle: tr('по желанию — сверить наличные с расчётом', 'xohlasangiz — naqd pulni hisob bilan solishtirish'),
          onTap: _startCount,
        ),
        const SizedBox(height: 12),
      ],
      KeyCard(
        keyLabel: 'Esc',
        title: tr('Назад', 'Orqaga'),
        subtitle: tr('день останется открытым', 'kun ochiq qoladi'),
        onTap: _back,
      ),
      ],
    ];

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
                  child: Panel(
                    padding: const EdgeInsets.fromLTRB(28, 24, 28, 24),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                      FitText(title, style: tb(24)),
                      const SizedBox(height: 10),
                      Text(subtitle, style: t(14, c: C.ts)),
                      const SizedBox(height: 14),
                      if (_editingLeave)
                        ..._leaveBody()
                      else if (_counting)
                        ..._countBody()
                      else
                        ..._summaryBody(rep, expected),
                    ]),
                  ),
                ),
                const SizedBox(width: 16),
                SizedBox(width: 480, child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: right)),
              ]),
            ),
          ),
        ]),
      ),
    );
  }

  /// ЗД1: сумма по расчёту и итоги дня.
  List<Widget> _summaryBody(ShiftReport rep, int expected) {
    final shift = rep.shift;
    final opened = shift.openedAt.toLocal();
    final hm = '${opened.hour.toString().padLeft(2, '0')}:${opened.minute.toString().padLeft(2, '0')}';
    var nonCash = 0;
    for (final m in rep.byMethod.values) {
      if (m.kind != 'cash') nonCash += m.sales;
    }
    final rows = <(String, String)>[
      (tr('Открыта', 'Ochilgan'), '$hm  ·  ${shift.openedByName}'),
      (tr('Чеков', 'Cheklar'), '${rep.salesCount}'),
      (tr('Выручка за день', 'Kunlik tushum'), fmtMoney(rep.salesTotal)),
      (tr('Наличными', 'Naqd'), fmtMoney(rep.cashSales)),
      (tr('Картой и QR', 'Karta va QR'), fmtMoney(nonCash)),
      // Ниже — только если было: иначе «в ящике по расчёту» не сойдётся с итогами.
      if (rep.debtGiven != 0) (tr('В долг', 'Qarzga'), fmtMoney(rep.debtGiven)),
      (tr('Возвраты', 'Qaytarishlar'), fmtMoney(rep.returnsTotal)),
      if (rep.debtPaidCash != 0) (tr('Погашено долгов наличными', 'Naqd toʻlangan qarzlar'), fmtMoney(rep.debtPaidCash)),
      if (rep.cashIn != 0) (tr('Внесения', 'Kiritildi'), fmtMoney(rep.cashIn)),
      if (rep.cashOut != 0) (tr('Изъятия', 'Olindi'), fmtMoney(rep.cashOut)),
      (tr('Размен на начало дня', 'Kun boshidagi maydalik'), fmtMoney(shift.openingCash)),
    ];
    return [
      _AmountBox(label: tr('В ящике по расчёту', 'Hisob boʻyicha gʻaladonda'), text: fmtMoney(expected)),
      const SizedBox(height: 14),
      Text(
          tr('Хотите сверить наличные? F2 — пересчитать ящик. Расхождение закрытие не задержит.',
              'Naqd pulni solishtirmoqchimisiz? F2 — gʻaladonni sanash. Farq yopishga xalaqit bermaydi.'),
          style: t(13, c: C.ts)),
      const SizedBox(height: 12),
      Flexible(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 4),
          decoration: BoxDecoration(color: C.surface, borderRadius: BorderRadius.circular(14), border: Border.all(color: C.border)),
          child: ListView.separated(
            shrinkWrap: true,
            padding: EdgeInsets.zero,
            itemCount: rows.length,
            separatorBuilder: (_, __) => const Divider(height: 1, color: C.border),
            itemBuilder: (_, i) => Padding(
              padding: const EdgeInsets.symmetric(vertical: 13),
              child: Row(children: [
                Expanded(child: Text(rows[i].$1, style: t(15, c: C.t2))),
                Text(rows[i].$2, style: t(16, w: FontWeight.w700)),
              ]),
            ),
          ),
        ),
      ),
    ];
  }

  /// ЗД6, F3: сколько оставить в ящике на размен на этот раз.
  List<Widget> _leaveBody() => [
        _AmountBox(
          label: tr('Оставить на размен', 'Maydalikka qoldirish'),
          text: _leaveInput.isEmpty ? '0' : fmtMoney(parseMoney(_leaveInput)),
          empty: _leaveInput.isEmpty,
          active: true,
        ),
        const SizedBox(height: 14),
        Text(
            tr('Сколько оставить в ящике на завтра. Остальное — «К сдаче» владельцу. Enter — готово · Esc — по норме',
                'Ertaga uchun gʻaladonda qancha qoldirish. Qolgani — egasiga «Topshirish». Enter — tayyor · Esc — meʼyor boʻyicha'),
            style: t(13, c: C.ts)),
        const SizedBox(height: 14),
        Center(child: _Keypad(onKey: (k) => k == '⌫' ? _eraseLeave() : _typeLeave(k))),
      ];

  /// ЗД2 / ЗД4: одна сумма и клавиатура.
  List<Widget> _countBody() => [
        _AmountBox(
          label: tr('Наличных в ящике', 'Gʻaladondagi naqd pul'),
          text: _input.isEmpty ? '0' : fmtMoney(_counted),
          empty: _input.isEmpty,
          active: !_revealed,
        ),
        const SizedBox(height: 14),
        Text(
            _revealed
                ? tr('Сумму можно поправить: цифры и ⌫ — сверка обновится', 'Summani tuzatish mumkin: raqamlar va ⌫ — solishtirish yangilanadi')
                : tr('Цифры — сумма · ⌫ — стереть · 000 — три нуля · Enter — сверить с расчётом',
                    'Raqamlar — summa · ⌫ — oʻchirish · 000 — uchta nol · Enter — hisob bilan solishtirish'),
            style: t(13, c: C.ts)),
        const SizedBox(height: 14),
        Center(child: _Keypad(onKey: (k) => k == '⌫' ? _erase() : _type(k))),
      ];
}

/// ЗД6: «Оставить на размен» (F3 — изменить) и «К сдаче владельцу».
class _HandBox extends StatelessWidget {
  const _HandBox({required this.keep, required this.toHand, required this.changed, required this.editable});

  final int keep;
  final int toHand;

  /// Размен поменяли на этот раз (F3), а не по норме магазина.
  final bool changed;
  final bool editable;

  @override
  Widget build(BuildContext context) => Panel(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(tr('Оставить на размен', 'Maydalikka qoldirish'), style: t(16, w: FontWeight.w600)),
                Text(
                    changed
                        ? (editable ? tr('на этот раз · изменить — F3', 'shu safar · oʻzgartirish — F3') : tr('на этот раз', 'shu safar'))
                        : (editable ? tr('норма магазина · изменить — F3', 'doʻkon meʼyori · oʻzgartirish — F3') : tr('норма магазина', 'doʻkon meʼyori')),
                    style: t(12, c: C.ts)),
              ]),
            ),
            if (editable) ...[const KeyBadge('F3', size: 40), const SizedBox(width: 12)],
            Text(fmtMoney(keep), style: t(20, w: FontWeight.w700)),
          ]),
          const Padding(padding: EdgeInsets.symmetric(vertical: 10), child: Divider(height: 1, color: C.border)),
          Row(children: [
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(tr('К сдаче владельцу', 'Egasiga topshirish'), style: t(16, w: FontWeight.w600)),
                Text(tr('положите в конверт — владелец примет в SM Магазин', 'konvertga soling — egasi SM Magazinda qabul qiladi'),
                    style: t(12, c: C.ts)),
              ]),
            ),
            const SizedBox(width: 12),
            Text(fmtMoney(toHand), style: t(30, w: FontWeight.w800, c: C.brand)),
          ]),
        ]),
      );
}

/// Рамка с суммой: «В ящике по расчёту» (ЗД1) или «Наличных в ящике» (ЗД2/ЗД4).
class _AmountBox extends StatelessWidget {
  const _AmountBox({required this.label, required this.text, this.empty = false, this.active = false});

  final String label;
  final String text;
  final bool empty;

  /// Ждём ввод — красная рамка (ЗД4).
  final bool active;

  @override
  Widget build(BuildContext context) => Container(
        height: 94,
        padding: const EdgeInsets.symmetric(horizontal: 22),
        decoration: BoxDecoration(
          color: C.surface,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: active ? C.brand : C.borderStrong, width: active ? 2 : 1),
        ),
        child: Row(children: [
          Expanded(child: Text(label, style: t(16, w: FontWeight.w500, c: C.ts))),
          Flexible(flex: 2, child: FitText(text, textAlign: TextAlign.right, style: tb(46, c: empty ? C.td : C.tp))),
        ]),
      );
}

/// Тёмная карточка справа: «В ящике по расчёту» или «Посчитано в ящике».
class _DarkCard extends StatelessWidget {
  const _DarkCard({required this.label, required this.amount, required this.note});

  final String label;
  final int amount;
  final String note;

  @override
  Widget build(BuildContext context) => Panel(
        color: C.dark,
        padding: const EdgeInsets.all(24),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(label, style: t(15, c: Colors.white70)),
          const SizedBox(height: 4),
          FitText(fmtMoney(amount), style: t(52, w: FontWeight.w800, c: Colors.white)),
          const SizedBox(height: 4),
          Text(note, style: t(13, c: Colors.white60)),
        ]),
      );
}

/// Клавиатура пересчёта (Figma: 7 8 9 сверху, 000 0 ⌫ снизу; клавиши 120×58).
class _Keypad extends StatelessWidget {
  const _Keypad({required this.onKey});

  final ValueChanged<String> onKey;

  static const _rows = [
    ['7', '8', '9'],
    ['4', '5', '6'],
    ['1', '2', '3'],
    ['000', '0', '⌫'],
  ];

  @override
  Widget build(BuildContext context) => Column(mainAxisSize: MainAxisSize.min, children: [
        for (var r = 0; r < _rows.length; r++) ...[
          if (r > 0) const SizedBox(height: 8),
          Row(mainAxisSize: MainAxisSize.min, children: [
            for (var c = 0; c < 3; c++) ...[
              if (c > 0) const SizedBox(width: 8),
              SizedBox(
                width: 120,
                height: 58,
                child: Material(
                  color: C.surface,
                  borderRadius: BorderRadius.circular(10),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(10),
                    onTap: () => onKey(_rows[r][c]),
                    child: Container(
                      alignment: Alignment.center,
                      decoration: BoxDecoration(borderRadius: BorderRadius.circular(10), border: Border.all(color: C.border)),
                      child: _rows[r][c] == '⌫'
                          ? const Icon(Icons.backspace_outlined, size: 22, color: C.tp)
                          : Text(_rows[r][c], style: t(22, w: FontWeight.w500)),
                    ),
                  ),
                ),
              ),
            ],
          ]),
        ],
      ]);
}

/// ЗД2: итог пересчёта — сходится или расхождение; причина по желанию.
class _Result extends StatelessWidget {
  const _Result({required this.expected, required this.diff, required this.reason});

  final int expected;
  final int diff;
  final String? reason;

  @override
  Widget build(BuildContext context) {
    if (diff == 0) {
      return Panel(
        color: C.successSoft,
        padding: const EdgeInsets.all(18),
        child: Text(tr('✓ Должно быть ${fmtMoney(expected)} — сходится', '✓ Boʻlishi kerak: ${fmtMoney(expected)} — mos keldi'),
            style: t(16, w: FontWeight.w600, c: C.success)),
      );
    }
    final short = diff < 0;
    final amount = short ? fmtMoney(diff) : '+${fmtMoney(diff)}';
    return Panel(
      color: C.errorSoft,
      padding: const EdgeInsets.all(20),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(child: Text(tr('Должно быть ${fmtMoney(expected)}', 'Boʻlishi kerak: ${fmtMoney(expected)}'), style: t(15, c: C.error))),
          Text(amount, style: t(32, w: FontWeight.w800, c: C.error)),
        ]),
        const SizedBox(height: 6),
        Text(
          short
              ? tr('Недостача $amount запишется в день — владелец увидит её в Финансах. Причина по желанию: F2 — сдача без мелочи · F3 — ошибка в чеке · F4 — другое',
                  'Kamomad $amount kunga yoziladi — egasi uni Moliyada koʻradi. Sabab ixtiyoriy: F2 — qaytim mayda pulsiz · F3 — chekdagi xato · F4 — boshqa')
              : tr('Излишек $amount запишется в день — владелец увидит его в Финансах. Причина по желанию: F2 — сдача без мелочи · F3 — ошибка в чеке · F4 — другое',
                  'Ortiqcha $amount kunga yoziladi — egasi uni Moliyada koʻradi. Sabab ixtiyoriy: F2 — qaytim mayda pulsiz · F3 — chekdagi xato · F4 — boshqa'),
          style: t(13, c: C.error, h: 1.3),
        ),
        const SizedBox(height: 8),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          decoration: BoxDecoration(color: C.keyBg, borderRadius: BorderRadius.circular(6)),
          child: Text(reason == null ? tr('Без причины — можно и так', 'Sababsiz — shunday ham boʻladi') : tr('Причина: $reason', 'Sabab: $reason'),
              style: t(12, w: FontWeight.w600, c: C.t2)),
        ),
      ]),
    );
  }
}

class _QueueNote extends StatelessWidget {
  const _QueueNote({required this.queue, required this.failed});

  final int queue;
  final int failed;

  @override
  Widget build(BuildContext context) {
    final ok = queue == 0 && failed == 0;
    return Panel(
      color: ok ? C.successSoft : C.warningSoft,
      padding: const EdgeInsets.all(14),
      child: Text(
        ok
            ? tr('✓ Все чеки отправлены — неотправленных нет', '✓ Barcha cheklar yuborildi — yuborilmagan chek yoʻq')
            : tr('В очереди $queue${failed > 0 ? ', не принято сервером $failed' : ''} — отправятся сами, когда будет связь',
                'Navbatda $queue${failed > 0 ? ', server qabul qilmagan: $failed' : ''} — aloqa paydo boʻlganda oʻzi yuboriladi'),
        style: t(13, c: ok ? C.success : C.warning),
      ),
    );
  }
}
