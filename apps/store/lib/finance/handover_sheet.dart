import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:sm_core/sm_core.dart';

import '../ui/theme.dart';
import '../ui/widgets.dart';
import 'finance_logic.dart';

/// Ф2 / Ф3 · Сдать кассу: в ящике по смене → сколько оставить на размен и
/// сколько забираете. Меньше, чем должно быть, — недостача видна сразу.
/// [drawer] — ответ /store/pos/drawer, [leave] — размен по умолчанию.
/// Возвращает true, если деньги сданы.
Future<bool?> showHandoverSheet(BuildContext context, Map<String, dynamic> drawer, {num leave = 0}) {
  return showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    backgroundColor: AppColors.white,
    builder: (_) => _HandoverSheet(drawer: drawer, leave: leave),
  );
}

class _HandoverSheet extends StatefulWidget {
  const _HandoverSheet({required this.drawer, required this.leave});

  final Map<String, dynamic> drawer;
  final num leave;

  @override
  State<_HandoverSheet> createState() => _HandoverSheetState();
}

class _HandoverSheetState extends State<_HandoverSheet> {
  late final _leave = TextEditingController(text: _fmt(_leaveStart));
  late final _take = TextEditingController(text: _fmt(_drawer - _leaveStart));
  // Забираемую сумму меняли руками — размен её больше не пересчитывает.
  bool _takeEdited = false;
  String? _error;
  bool _busy = false;

  num get _drawer => n(widget.drawer['amount']);
  num get _leaveStart => widget.leave > _drawer ? 0 : widget.leave;

  static String _fmt(num v) => money(v < 0 ? 0 : v, suffix: false).replaceAll(' ', ' ');

  @override
  void dispose() {
    _leave.dispose();
    _take.dispose();
    super.dispose();
  }

  void _setLeave(num v) {
    _leave.text = _fmt(v);
    _onLeave();
  }

  void _onLeave() {
    setState(() {
      _error = null;
      if (!_takeEdited) _take.text = _fmt(_drawer - n(plainAmount(_leave.text)));
    });
  }

  Future<void> _submit() async {
    final take = n(plainAmount(_take.text));
    final leave = n(plainAmount(_leave.text));
    if (take <= 0) {
      setState(() => _error = tr('Сколько забираете? Сумма больше нуля', 'Qancha olasiz? Summa noldan katta boʻlsin'));
      return;
    }
    if (leave < 0) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    final api = context.read<Api>();
    try {
      await api.post('/store/finance/handovers', {
        'from_id': widget.drawer['cashbox_id'],
        'amount': plainAmount(_take.text),
        'leave': plainAmount(_leave.text).isEmpty ? '0' : plainAmount(_leave.text),
      });
      if (!mounted) return;
      final messenger = ScaffoldMessenger.of(context);
      Navigator.of(context).pop(true);
      messenger.showSnackBar(SnackBar(
          content: Text(leave > 0
              ? tr('Касса сдана · на размен осталось ${money(leave)}', 'Kassa topshirildi · maydalikka ${money(leave)} qoldi')
              : tr('Касса сдана в главную кассу', 'Kassa asosiy kassaga topshirildi'))));
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final d = widget.drawer;
    final shifts = ((d['shifts'] as List?) ?? const []).cast<Map<String, dynamic>>();
    final shortage = handoverShortage(d['amount'], _take.text, _leave.text);
    final leave = n(plainAmount(_leave.text));
    final take = n(plainAmount(_take.text));
    final sub = shifts.length == 1
        ? tr('${d['cashbox_name']} · смена №${shifts.first['number']} · ${shifts.first['opened_by_name']}',
            '${d['cashbox_name']} · smena №${shifts.first['number']} · ${shifts.first['opened_by_name']}')
        : '${d['cashbox_name']}';
    final opening = shifts.length == 1 ? n(shifts.first['opening_cash']) : null;
    final cashSales = shifts.length == 1 ? n((shifts.first['report'] as Map?)?['cash_sales']) : null;
    return Padding(
      padding: EdgeInsets.fromLTRB(16, 0, 16, 16 + MediaQuery.of(context).viewInsets.bottom),
      child: SafeArea(
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text(tr('Сдать кассу', 'Kassani topshirish'), style: AppText.h3),
            Text(sub, style: AppText.small),
            const SizedBox(height: 14),
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(color: AppColors.soft, borderRadius: BorderRadius.circular(14)),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(tr('Должно быть в ящике', 'Gʻaladonda boʻlishi kerak'), style: AppText.small),
                Text(money(d['amount']), style: AppText.h2),
                if (opening != null && cashSales != null)
                  Text(tr('размен ${money(opening, suffix: false)} + наличные ${money(cashSales, suffix: false)}…',
                          'maydalik ${money(opening, suffix: false)} + naqd ${money(cashSales, suffix: false)}…'),
                      style: AppText.small.copyWith(fontSize: 12)),
              ]),
            ),
            const SizedBox(height: 14),
            TextField(
              controller: _leave,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.,\s]'))],
              style: AppText.title,
              onChanged: (_) => _onLeave(),
              decoration: InputDecoration(
                labelText: tr('Оставить в ящике на размен', 'Gʻaladonda maydalikka qoldirish'),
                suffixText: tr('сум', 'soʻm'),
                helperText: tr('Подставится размену следующей смены — кассиру вводить не нужно',
                    'Keyingi smena maydaligiga oʻzi qoʻyiladi — kassir kiritmaydi'),
                helperMaxLines: 2,
              ),
            ),
            const SizedBox(height: 8),
            Wrap(spacing: 6, runSpacing: 6, children: [
              for (final v in leaveChips)
                ChoiceChip(
                  label: Text(money(v, suffix: false)),
                  selected: leave == v,
                  showCheckmark: false,
                  selectedColor: AppColors.ink,
                  labelStyle: AppText.bodyStrong.copyWith(color: leave == v ? AppColors.white : AppColors.ink),
                  onSelected: v > _drawer ? null : (_) => _setLeave(v),
                ),
            ]),
            const SizedBox(height: 14),
            TextField(
              controller: _take,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.,\s]'))],
              style: AppText.title,
              onChanged: (_) => setState(() {
                _takeEdited = true;
                _error = null;
              }),
              decoration: InputDecoration(
                labelText: tr('Забираете (пересчитали)', 'Olasiz (sanab chiqdingiz)'),
                suffixText: tr('сум', 'soʻm'),
                errorText: _error,
              ),
            ),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: shortage == 0 ? AppColors.successSoft : AppColors.warningSoft,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Icon(shortage == 0 ? Icons.check_circle_rounded : Icons.warning_amber_rounded,
                    size: 20, color: shortage == 0 ? AppColors.successInk : AppColors.warningInk),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    shortage == 0
                        ? tr('${money(take, suffix: false)} + ${money(leave, suffix: false)} = ${money(d['amount'], suffix: false)} — всё сходится',
                            '${money(take, suffix: false)} + ${money(leave, suffix: false)} = ${money(d['amount'], suffix: false)} — hammasi mos')
                        : shortage > 0
                            ? tr(
                                'Недостача ${money(shortage)}: ${money(take, suffix: false)} + ${money(leave, suffix: false)} = ${money(take + leave, suffix: false)}, а должно быть ${money(d['amount'], suffix: false)}. Запишем недостачу на смену',
                                'Kamomad ${money(shortage)}: ${money(take, suffix: false)} + ${money(leave, suffix: false)} = ${money(take + leave, suffix: false)}, boʻlishi kerak ${money(d['amount'], suffix: false)}. Kamomadni smenaga yozamiz')
                            : tr('Излишек ${money(-shortage)} — запишем на смену', 'Ortiqcha ${money(-shortage)} — smenaga yozamiz'),
                    style: AppText.small.copyWith(color: shortage == 0 ? AppColors.successInk : AppColors.warningInk, fontWeight: FontWeight.w600),
                  ),
                ),
              ]),
            ),
            const SizedBox(height: 16),
            BigButton(
              label: shortage > 0
                  ? tr('Сдать с недостачей ${money(shortage, suffix: false)}', '${money(shortage, suffix: false)} kamomad bilan topshirish')
                  : tr('Сдать ${money(take, suffix: false)}', '${money(take, suffix: false)} topshirish'),
              icon: Icons.outbox_rounded,
              busy: _busy,
              onPressed: take > 0 ? _submit : null,
            ),
            if (shortage != 0) ...[
              const SizedBox(height: 8),
              TextButton.icon(
                onPressed: () => setState(() {
                  _takeEdited = false;
                  _take.text = _fmt(_drawer - leave);
                }),
                icon: const Icon(Icons.refresh_rounded),
                label: Text(tr('Пересчитать', 'Qayta hisoblash')),
              ),
            ],
          ]),
        ),
      ),
    );
  }
}
