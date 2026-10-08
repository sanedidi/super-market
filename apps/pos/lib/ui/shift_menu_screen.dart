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
import 'language_dialog.dart';
import 'quick_keys_screen.dart';
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
        _printX();
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
    return Scaffold(
      body: KeyCatcher(
        onKey: _onKey,
        child: Column(children: [
          const TopBar(),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Expanded(child: XReportView(report: r)),
                const SizedBox(width: 16),
                SizedBox(
                  width: 480,
                  child: SingleChildScrollView(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                    Text(tr('Меню смены', 'Smena menyusi'), style: t(22, w: FontWeight.w700)),
                    const SizedBox(height: 12),
                    KeyCard(
                      keyLabel: '1',
                      title: tr('Внесение', 'Kiritish'),
                      subtitle: tr('добавить размен в ящик', 'gʻaladonga mayda pul qoʻshish'),
                      style: _move == 'in' ? KeyCardStyle.active : KeyCardStyle.normal,
                      onTap: () => setState(() => _move = 'in'),
                    ),
                    const SizedBox(height: 10),
                    KeyCard(
                      keyLabel: '2',
                      title: tr('Изъятие', 'Olish'),
                      subtitle: tr('инкассация, выдача из ящика', 'inkassatsiya, gʻaladondan berish'),
                      style: _move == 'out' ? KeyCardStyle.active : KeyCardStyle.normal,
                      onTap: () => setState(() => _move = 'out'),
                    ),
                    if (_move != null) ...[
                      const SizedBox(height: 10),
                      Container(
                        padding: const EdgeInsets.all(20),
                        decoration: BoxDecoration(
                          color: C.surface,
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(color: C.brand, width: 2),
                        ),
                        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                          Row(children: [
                            Expanded(child: Text(tr('${_move == 'in' ? 'Внесение' : 'Изъятие'} · сумма', '${_move == 'in' ? 'Kiritish' : 'Olish'} · summa'), style: t(14, c: C.ts))),
                            Text(_input.isEmpty ? '—' : fmtMoney(parseMoney(_input)), style: t(32, w: FontWeight.w700)),
                          ]),
                          const SizedBox(height: 6),
                          Text(
                            tr('Причина: ${_move == 'in' ? 'Размен' : 'Инкассация'} · Enter — подтвердить · Esc — отмена',
                                'Sabab: ${_move == 'in' ? 'Mayda pul' : 'Inkassatsiya'} · Enter — tasdiqlash · Esc — bekor qilish'),
                            style: t(12, c: C.ts),
                          ),
                        ]),
                      ),
                    ],
                    const SizedBox(height: 10),
                    KeyCard(
                      keyLabel: '3',
                      title: tr('Печать X-отчёта', 'X-hisobotni chop etish'),
                      subtitle: pos.printer.enabled ? pos.printer.title : tr('принтер не выбран', 'printer tanlanmagan'),
                      style: pos.printer.enabled ? KeyCardStyle.normal : KeyCardStyle.dim,
                      onTap: _printX,
                    ),
                    const SizedBox(height: 10),
                    KeyCard(keyLabel: '4', title: tr('Сменить кассира', 'Kassirni almashtirish'), subtitle: tr('вход по ПИНу', 'PIN-kod bilan kirish'), onTap: _changeCashier),
                    const SizedBox(height: 10),
                    KeyCard(keyLabel: '5', title: tr('Закрыть смену', 'Smenani yopish'), subtitle: tr('пересчёт наличных и Z-отчёт', 'naqd pulni sanash va Z-hisobot'), onTap: _close),
                    const SizedBox(height: 10),
                    KeyCard(keyLabel: '6', title: tr('Оборудование', 'Uskunalar'), subtitle: tr('принтер, ящик, фискальный модуль', 'printer, gʻaladon, fiskal modul'), onTap: _equipment),
                    if (pos.canTakeDebtPayment) ...[
                      const SizedBox(height: 10),
                      KeyCard(keyLabel: '7', title: tr('Погашение долга', 'Qarzni toʻlash'), subtitle: tr('покупатель по номеру · наличные или карта', 'xaridor raqami boʻyicha · naqd yoki karta'), onTap: _debtPayment),
                    ],
                    if (pos.canQuickKeys) ...[
                      const SizedBox(height: 10),
                      KeyCard(keyLabel: '8', title: tr('Быстрые кнопки', 'Tezkor tugmalar'), subtitle: tr('товары на плитках экрана продажи', 'sotuv ekranidagi mahsulot tugmalari'), onTap: _quickKeys),
                    ],
                    const SizedBox(height: 10),
                    KeyCard(keyLabel: '9', title: 'Til · Язык', subtitle: Lang.names[Lang.instance.code]!, onTap: _language),
                    const SizedBox(height: 10),
                    KeyCard(keyLabel: 'Esc', title: tr('Назад к продаже', 'Sotuvga qaytish'), onTap: () => Navigator.of(context).pop()),
                    if (_error != null) ...[
                      const SizedBox(height: 12),
                      Text(_error!, style: t(14, c: C.error)),
                    ],
                  ]),
                  ),
                ),
              ]),
            ),
          ),
        ]),
      ),
    );
  }
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
