import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:sm_core/sm_core.dart' show Lang, tr;

import '../core/journal.dart';
import '../core/money.dart';
import '../state/pos.dart';
import 'close_shift_screen.dart';
import 'debt_payment_dialog.dart';
import 'equipment_screen.dart';
import 'kit.dart';
import 'language_dialog.dart';
import 'quick_keys_screen.dart';
import 'rejected_dialog.dart';
import 'theme.dart';
import 'widgets.dart';

/// F11 — меню смены: X-отчёт слева, действия цифрами справа.
class ShiftMenuScreen extends StatefulWidget {
  const ShiftMenuScreen({super.key});

  @override
  State<ShiftMenuScreen> createState() => _ShiftMenuScreenState();
}

class _ShiftMenuScreenState extends State<ShiftMenuScreen> {
  /// Внесение (in) или изъятие (out) — ждём сумму.
  String? _move;
  String _input = '';
  String? _error;

  PosController get pos => context.read<PosController>();

  Future<void> _confirmMove() async {
    final amount = parseMoney(_input);
    if (amount <= 0) {
      setState(() => _error = tr('Наберите сумму', 'Summani tering'));
      return;
    }
    if (_move == 'out' && amount > pos.report.expectedCash) {
      setState(() => _error = tr('В ящике меньше, чем ${fmtMoney(amount)}', 'Gʻaladonda ${fmtMoney(amount)} dan kam'));
      return;
    }
    final kind = _move!;
    await pos.cashMove(kind, amount, kind == 'in' ? tr('Размен', 'Mayda pul') : tr('Инкассация', 'Inkassatsiya'));
    setState(() {
      _move = null;
      _input = '';
      _error = null;
    });
  }

  Future<void> _close() async {
    await Navigator.of(context).pushReplacement(MaterialPageRoute<void>(builder: (_) => const CloseShiftScreen()));
  }

  Future<void> _printX() async {
    if (!pos.printer.enabled) {
      setState(() => _error = tr('Принтер не выбран — откройте «Оборудование» (6). Отчёт — слева.',
          'Printer tanlanmagan — «Uskunalar» (6) boʻlimini oching. Hisobot — chapda.'));
      return;
    }
    final ok = await pos.printX();
    if (mounted) setState(() => _error = ok ? null : pos.printError);
  }

  /// X-отчёт без закрытия смены: окно с отчётом и печатью.
  Future<void> _showX() async {
    await showDialog<void>(
      context: context,
      builder: (ctx) {
        final size = MediaQuery.sizeOf(ctx);
        return Dialog(
          backgroundColor: C.page,
          insetPadding: const EdgeInsets.all(12),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          child: SizedBox(
            width: size.width < 840 ? size.width - 24 : 800,
            height: size.height - 48 < 720 ? size.height - 48 : 720,
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Expanded(child: XReportView(report: context.read<PosController>().report)),
                const SizedBox(height: 10),
                Row(children: [
                  Expanded(
                    child: PosButton(
                      label: tr('Печать X-отчёта', 'X-hisobotni chop etish'),
                      hint: pos.printer.enabled ? pos.printer.title : tr('принтер не выбран', 'printer tanlanmagan'),
                      icon: Icons.print_outlined,
                      height: 56,
                      enabled: pos.printer.enabled,
                      onTap: _printX,
                    ),
                  ),
                  const SizedBox(width: 10),
                  SizedBox(
                    width: 200,
                    child: PosButton(label: tr('Закрыть', 'Yopish'), hint: 'Esc', height: 56, center: true, onTap: () => Navigator.of(ctx).pop()),
                  ),
                ]),
              ]),
            ),
          ),
        );
      },
    );
  }

  Future<void> _equipment() async {
    await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const EquipmentScreen()));
  }

  Future<void> _debtPayment() async {
    if (!pos.canTakeDebtPayment) return;
    await showDebtPaymentDialog(context, pos);
  }

  /// Окно выбора языка в стиле кассы (Figma Я8), не мобильная шторка.
  Future<void> _language() async {
    await showLanguageDialog(context);
    if (mounted) setState(() {});
  }

  Future<void> _quickKeys() async {
    if (!pos.canQuickKeys) return;
    await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const QuickKeysScreen()));
  }

  void _changeCashier() {
    Navigator.of(context).pop();
    pos.logout();
  }

  bool _onKey(KeyEvent e) {
    final k = e.logicalKey;
    final ch = printable(e);
    if (_move != null) {
      if (isEnter(e)) {
        _confirmMove();
      } else if (k == LogicalKeyboardKey.escape) {
        setState(() {
          _move = null;
          _input = '';
          _error = null;
        });
      } else if (k == LogicalKeyboardKey.backspace) {
        if (_input.isNotEmpty) setState(() => _input = _input.substring(0, _input.length - 1));
      } else if (ch != null && RegExp(r'^[0-9]$').hasMatch(ch) && _input.length < 10) {
        setState(() => _input += ch);
      }
      return true;
    }
    if (k == LogicalKeyboardKey.escape || k == LogicalKeyboardKey.f11) {
      Navigator.of(context).pop();
      return true;
    }
    switch (ch) {
      case '1':
        setState(() => _move = 'in');
      case '2':
        setState(() => _move = 'out');
      case '3':
        _showX();
      case '4':
        _changeCashier();
      case '5':
        _close();
      case '6':
        _equipment();
      case '7':
        _debtPayment();
      case '8':
        _quickKeys();
      case '9':
        _language();
      case '0':
        if (pos.failed == 0) return false;
        showRejectedDialog(context);
      default:
        return false;
    }
    return true;
  }

  @override
  Widget build(BuildContext context) {
    final pos = context.watch<PosController>();
    if (pos.shift == null) return const Scaffold();
    final r = pos.report;
    final sh = r.shift;
    final d = densityOf(context);
    final opened = '${sh.openedAt.toLocal().hour.toString().padLeft(2, '0')}:${sh.openedAt.toLocal().minute.toString().padLeft(2, '0')}';
    final tw = switch (d) { Density.l => 216.0, Density.m => 200.0, Density.s => 186.0 };
    final th = switch (d) { Density.l => 124.0, Density.m => 112.0, Density.s => 104.0 };
    final tiles = <_Tile>[
      _Tile(Icons.play_arrow_rounded, tr('Продажа', 'Sotuv'), 'Esc', () => Navigator.of(context).pop(), primary: true),
      _Tile(Icons.south_rounded, tr('Внесение', 'Kiritish'), tr('1 · размен', '1 · mayda pul'), () => setState(() => _move = 'in')),
      _Tile(Icons.north_rounded, tr('Изъятие', 'Olish'), tr('2 · инкассация', '2 · inkassatsiya'), () => setState(() => _move = 'out')),
      _Tile(Icons.bar_chart_rounded, tr('X-отчёт', 'X-hisobot'), tr('3 · без закрытия', '3 · yopmasdan'), _showX),
      _Tile(Icons.people_outline_rounded, tr('Сменить кассира', 'Kassirni almashtirish'), tr('4 · вход по ПИН', '4 · PIN bilan kirish'), _changeCashier),
      _Tile(Icons.power_settings_new_rounded, tr('Закрыть смену', 'Smenani yopish'), tr('5 · Z-отчёт', '5 · Z-hisobot'), _close, danger: true),
      _Tile(Icons.print_outlined, tr('Оборудование', 'Uskunalar'), tr('6 · принтер, ящик, ФМ', '6 · printer, gʻaladon, FM'), _equipment),
      if (pos.canTakeDebtPayment) _Tile(Icons.menu_book_outlined, tr('Погашение долга', 'Qarzni toʻlash'), tr('7 · наличные или карта', '7 · naqd yoki karta'), _debtPayment),
      if (pos.canQuickKeys) _Tile(Icons.bolt_rounded, tr('Быстрые кнопки', 'Tezkor tugmalar'), tr('8 · настройка', '8 · sozlash'), _quickKeys),
      _Tile(Icons.translate_rounded, 'Til · Язык', '9 · ${Lang.names[Lang.instance.code] ?? ''}', _language),
      if (pos.failed > 0)
        _Tile(Icons.sync_problem_rounded, tr('Не принято · ${pos.failed}', 'Qabul qilinmagan · ${pos.failed}'), tr('0 · причины', '0 · sabablar'),
            () => showRejectedDialog(context),
            danger: true),
    ];
    const cols = 4;
    final rows = (tiles.length / cols).ceil();

    Widget tile(_Tile x) => SizedBox(
          width: tw,
          height: th,
          child: Material(
            color: x.primary ? C.brand : C.surface,
            borderRadius: BorderRadius.circular(10),
            child: InkWell(
              borderRadius: BorderRadius.circular(10),
              onTap: x.onTap,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 10),
                decoration: x.primary ? null : BoxDecoration(borderRadius: BorderRadius.circular(10), border: Border.all(color: C.border)),
                child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                  Icon(x.icon, size: 28, color: x.primary ? Colors.white : (x.danger ? C.error : C.t2)),
                  const SizedBox(height: 8),
                  FitText(x.label, textAlign: TextAlign.center, style: t(15, w: FontWeight.w600, c: x.primary ? Colors.white : C.tp)),
                  FitText(x.hint, textAlign: TextAlign.center, style: t(12, w: FontWeight.w500, c: x.primary ? C.brandLine : C.td)),
                ]),
              ),
            ),
          ),
        );

    final grid = Column(mainAxisSize: MainAxisSize.min, children: [
      for (var rr = 0; rr < rows; rr++) ...[
        if (rr > 0) const SizedBox(height: 8),
        Row(mainAxisSize: MainAxisSize.min, children: [
          for (var c = 0; c < cols; c++) ...[
            if (c > 0) const SizedBox(width: 8),
            rr * cols + c < tiles.length ? tile(tiles[rr * cols + c]) : SizedBox(width: tw, height: th),
          ],
        ]),
      ],
    ]);

    final movePanel = _move == null
        ? null
        : Container(
            width: 420,
            padding: const EdgeInsets.all(18),
            decoration: BoxDecoration(color: C.surface, borderRadius: BorderRadius.circular(14), border: Border.all(color: C.brand, width: 2)),
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Text(_move == 'in' ? tr('Внесение · размен в ящик', 'Kiritish · gʻaladonga mayda pul') : tr('Изъятие · инкассация', 'Olish · inkassatsiya'),
                  style: t(16, w: FontWeight.w700)),
              const SizedBox(height: 6),
              Container(
                height: 56,
                alignment: Alignment.centerRight,
                padding: const EdgeInsets.symmetric(horizontal: 14),
                decoration: BoxDecoration(color: C.subtle, borderRadius: BorderRadius.circular(8)),
                child: FitText(_input.isEmpty ? '—' : fmtMoney(parseMoney(_input)), style: tb(30, c: _input.isEmpty ? C.td : C.tp)),
              ),
              const SizedBox(height: 4),
              Center(
                child: NumPad(
                  onDigit: (dg) {
                    if (_input.length < 10) setState(() => _input += dg);
                  },
                  onBackspace: () {
                    if (_input.isNotEmpty) setState(() => _input = _input.substring(0, _input.length - 1));
                  },
                ),
              ),
              const SizedBox(height: 6),
              Row(children: [
                Expanded(
                  child: PosButton(
                    label: tr('Отмена', 'Bekor qilish'),
                    hint: 'Esc',
                    center: true,
                    height: 50,
                    onTap: () => setState(() {
                      _move = null;
                      _input = '';
                      _error = null;
                    }),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: PosButton(
                    label: tr('Подтвердить', 'Tasdiqlash'),
                    hint: 'Enter',
                    center: true,
                    height: 50,
                    bg: C.brand,
                    fg: Colors.white,
                    hintColor: C.brandLine,
                    border: null,
                    onTap: _confirmMove,
                  ),
                ),
              ]),
            ]),
          );

    return Scaffold(
      body: KeyCatcher(
        onKey: _onKey,
        child: Column(children: [
          const TopBar(),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 14, 20, 14),
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(tr('Смена №${sh.number ?? '·'}', 'Smena №${sh.number ?? '·'}'), style: tb(24)),
                      FitText(
                        tr('открыта в $opened  ·  ${sh.openedByName}  ·  ${r.salesCount} чеков  ·  продажи ${fmtMoney(r.salesTotal)}',
                            '$opened da ochilgan  ·  ${sh.openedByName}  ·  ${r.salesCount} ta chek  ·  sotuv ${fmtMoney(r.salesTotal)}'),
                        style: t(13, w: FontWeight.w500, c: C.td),
                      ),
                    ]),
                  ),
                  if (_error != null)
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 420),
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                        decoration: BoxDecoration(color: C.errorSoft, borderRadius: BorderRadius.circular(8)),
                        child: FitText(_error!, maxLines: 2, style: t(13, w: FontWeight.w600, c: C.error)),
                      ),
                    ),
                ]),
                Expanded(
                  child: Center(
                    child: movePanel ??
                        Column(mainAxisSize: MainAxisSize.min, children: [
                          if (d != Density.s) ...[
                            Container(
                              width: 92,
                              height: 92,
                              alignment: Alignment.center,
                              decoration: BoxDecoration(color: C.brand, borderRadius: BorderRadius.circular(22)),
                              child: Text('Super\nMarket', textAlign: TextAlign.center, style: tb(24, c: Colors.white, h: 0.95)),
                            ),
                            const SizedBox(height: 18),
                          ],
                          grid,
                        ]),
                  ),
                ),
                Text(tr('Цифра на клавиатуре или нажмите плитку · Esc — к продаже', 'Klaviaturadagi raqam yoki plitkani bosing · Esc — sotuvga'),
                    style: t(12, c: C.td)),
              ]),
            ),
          ),
        ]),
      ),
    );
  }
}

class _Tile {
  const _Tile(this.icon, this.label, this.hint, this.onTap, {this.primary = false, this.danger = false});

  final IconData icon;
  final String label;
  final String hint;
  final VoidCallback onTap;
  final bool primary;
  final bool danger;
}

/// X-отчёт: продажи, возвраты, оплаты, движение наличных. Сколько должно
/// быть в ящике — не показываем: кассир узнает после пересчёта при закрытии.
class XReportView extends StatelessWidget {
  const XReportView({super.key, required this.report});

  final ShiftReport report;

  @override
  Widget build(BuildContext context) {
    final r = report;
    final s = r.shift;
    Widget stat(String label, String value, String note) => Expanded(
          child: Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(color: C.subtle, borderRadius: BorderRadius.circular(12)),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(label, style: t(13, c: C.ts)),
              Text(value, style: t(26, w: FontWeight.w700)),
              if (note.isNotEmpty) Text(note, style: t(12, c: C.ts)),
            ]),
          ),
        );
    Widget row(String label, String value) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Row(children: [
            Expanded(child: Text(label, style: t(15, c: C.ts))),
            Text(value, style: t(15, w: FontWeight.w500)),
          ]),
        );
    final opened = '${s.openedAt.hour.toString().padLeft(2, '0')}:${s.openedAt.minute.toString().padLeft(2, '0')}';
    return Panel(
      child: SingleChildScrollView(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(tr('Смена №${s.number ?? '·'} · с $opened · ${s.openedByName}', 'Smena №${s.number ?? '·'} · $opened dan · ${s.openedByName}'), style: t(26, w: FontWeight.w700)),
          Text(tr('X-отчёт без закрытия смены', 'Smenani yopmasdan X-hisobot'), style: t(13, c: C.ts)),
          const SizedBox(height: 16),
          Row(children: [
            stat(tr('Продажи', 'Sotuvlar'), fmtMoney(r.salesTotal), tr('${r.salesCount} чеков', '${r.salesCount} ta chek')),
            const SizedBox(width: 12),
            stat(tr('Возвраты', 'Qaytarishlar'), r.returnsTotal == 0 ? '0' : '−${fmtMoney(r.returnsTotal)}', tr('${r.returnsCount} чеков', '${r.returnsCount} ta chek')),
            const SizedBox(width: 12),
            stat(tr('Средний чек', 'Oʻrtacha chek'), fmtMoney(r.average), ''),
          ]),
          const SizedBox(height: 16),
          Text(tr('По способам оплаты', 'Toʻlov usullari boʻyicha'), style: t(15, w: FontWeight.w700)),
          for (final m in r.byMethod.values)
            row(m.name, m.returns == 0 ? fmtMoney(m.sales) : tr('${fmtMoney(m.sales)}  (возвраты −${fmtMoney(m.returns)})', '${fmtMoney(m.sales)}  (qaytarishlar −${fmtMoney(m.returns)})')),
          if (r.discounts > 0) row(tr('Скидки', 'Chegirmalar'), fmtMoney(r.discounts)),
          if (r.debtGivenCount > 0 || r.debtPaidCount > 0) ...[
            const SizedBox(height: 12),
            Text(tr('Долги покупателей', 'Xaridorlar qarzlari'), style: t(15, w: FontWeight.w700)),
            if (r.debtGivenCount > 0) row(tr('Отпущено в долг · ${r.debtGivenCount} чеков', 'Qarzga berildi · ${r.debtGivenCount} ta chek'), fmtMoney(r.debtGiven)),
            if (r.debtPaidCash > 0) row(tr('Погашено наличными', 'Naqd pulda toʻlandi'), '+${fmtMoney(r.debtPaidCash)}'),
            if (r.debtPaidOther > 0) row(tr('Погашено картой и др.', 'Karta va b. bilan toʻlandi'), '+${fmtMoney(r.debtPaidOther)}'),
          ],
          const SizedBox(height: 12),
          Text(tr('Движение наличных', 'Naqd pul harakati'), style: t(15, w: FontWeight.w700)),
          row(tr('Размен на начало', 'Boshidagi mayda pul'), fmtMoney(s.openingCash)),
          for (final m in r.moves)
            row(
              '${m.kind == 'in' ? tr('Внесение', 'Kiritish') : tr('Изъятие', 'Olish')} ${m.at.toLocal().hour.toString().padLeft(2, '0')}:${m.at.toLocal().minute.toString().padLeft(2, '0')} · ${m.reason}',
              '${m.kind == 'in' ? '+' : '−'}${fmtMoney(m.amount)}',
            ),
          const SizedBox(height: 12),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(color: C.subtle, borderRadius: BorderRadius.circular(8)),
            child: Text(
                tr('Сколько должно быть в ящике, кассир увидит только после пересчёта при закрытии смены',
                    'Gʻaladonda qancha boʻlishi kerakligini kassir faqat smenani yopishda sanab chiqqach koʻradi'),
                style: t(12, c: C.ts)),
          ),
        ]),
      ),
    );
  }
}
