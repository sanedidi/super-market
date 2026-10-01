import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../core/journal.dart';
import '../core/money.dart';
import '../state/pos.dart';
import 'close_shift_screen.dart';
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
      setState(() => _error = 'Наберите сумму');
      return;
    }
    if (_move == 'out' && amount > pos.report.expectedCash) {
      setState(() => _error = 'В ящике меньше, чем ${fmtMoney(amount)}');
      return;
    }
    final kind = _move!;
    await pos.cashMove(kind, amount, kind == 'in' ? 'Размен' : 'Инкассация');
    setState(() {
      _move = null;
      _input = '';
      _error = null;
    });
  }

  Future<void> _close() async {
    await Navigator.of(context).pushReplacement(MaterialPageRoute<void>(builder: (_) => const CloseShiftScreen()));
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
        setState(() => _error = 'Печать X-отчёта — после подключения принтера (этап 3). Отчёт — слева.');
      case '4':
        _changeCashier();
      case '5':
        _close();
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
                  child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                    Text('Меню смены', style: t(22, w: FontWeight.w700)),
                    const SizedBox(height: 12),
                    KeyCard(
                      keyLabel: '1',
                      title: 'Внесение',
                      subtitle: 'добавить размен в ящик',
                      style: _move == 'in' ? KeyCardStyle.active : KeyCardStyle.normal,
                      onTap: () => setState(() => _move = 'in'),
                    ),
                    const SizedBox(height: 10),
                    KeyCard(
                      keyLabel: '2',
                      title: 'Изъятие',
                      subtitle: 'инкассация, выдача из ящика',
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
                            Expanded(child: Text('${_move == 'in' ? 'Внесение' : 'Изъятие'} · сумма', style: t(14, c: C.ts))),
                            Text(_input.isEmpty ? '—' : fmtMoney(parseMoney(_input)), style: t(32, w: FontWeight.w700)),
                          ]),
                          const SizedBox(height: 6),
                          Text(
                            'Причина: ${_move == 'in' ? 'Размен' : 'Инкассация'} · Enter — подтвердить · Esc — отмена',
                            style: t(12, c: C.ts),
                          ),
                        ]),
                      ),
                    ],
                    const SizedBox(height: 10),
                    const KeyCard(keyLabel: '3', title: 'Печать X-отчёта', subtitle: 'после подключения принтера', style: KeyCardStyle.dim),
                    const SizedBox(height: 10),
                    KeyCard(keyLabel: '4', title: 'Сменить кассира', subtitle: 'вход по ПИНу', onTap: _changeCashier),
                    const SizedBox(height: 10),
                    KeyCard(keyLabel: '5', title: 'Закрыть смену', subtitle: 'пересчёт наличных и Z-отчёт', onTap: _close),
                    const SizedBox(height: 10),
                    KeyCard(keyLabel: 'Esc', title: 'Назад к продаже', onTap: () => Navigator.of(context).pop()),
                    if (_error != null) ...[
                      const SizedBox(height: 12),
                      Text(_error!, style: t(14, c: C.error)),
                    ],
                  ]),
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
          Text('Смена №${s.number ?? '·'} · с $opened · ${s.openedByName}', style: t(26, w: FontWeight.w700)),
          Text('X-отчёт без закрытия смены', style: t(13, c: C.ts)),
          const SizedBox(height: 16),
          Row(children: [
            stat('Продажи', fmtMoney(r.salesTotal), '${r.salesCount} чеков'),
            const SizedBox(width: 12),
            stat('Возвраты', r.returnsTotal == 0 ? '0' : '−${fmtMoney(r.returnsTotal)}', '${r.returnsCount} чеков'),
            const SizedBox(width: 12),
            stat('Средний чек', fmtMoney(r.average), ''),
          ]),
          const SizedBox(height: 16),
          Text('По способам оплаты', style: t(15, w: FontWeight.w700)),
          for (final m in r.byMethod.values)
            row(m.name, m.returns == 0 ? fmtMoney(m.sales) : '${fmtMoney(m.sales)}  (возвраты −${fmtMoney(m.returns)})'),
          if (r.discounts > 0) row('Скидки', fmtMoney(r.discounts)),
          const SizedBox(height: 12),
          Text('Движение наличных', style: t(15, w: FontWeight.w700)),
          row('Размен на начало', fmtMoney(s.openingCash)),
          for (final m in r.moves)
            row(
              '${m.kind == 'in' ? 'Внесение' : 'Изъятие'} ${m.at.toLocal().hour.toString().padLeft(2, '0')}:${m.at.toLocal().minute.toString().padLeft(2, '0')} · ${m.reason}',
              '${m.kind == 'in' ? '+' : '−'}${fmtMoney(m.amount)}',
            ),
          const SizedBox(height: 12),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(color: C.subtle, borderRadius: BorderRadius.circular(8)),
            child: Text('Сколько должно быть в ящике, кассир увидит только после пересчёта при закрытии смены',
                style: t(12, c: C.ts)),
          ),
        ]),
      ),
    );
  }
}
