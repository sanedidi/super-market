import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:sm_core/sm_core.dart';

import '../state.dart';
import '../ui/theme.dart';
import '../ui/widgets.dart';
import 'finance_logic.dart';

// Касса не копит деньги (Figma «SM Магазин · Касса: норма размена, «К сдаче»
// → «Принято», разовый пересчёт ящика», М1–М6): кассир закрыл день — в ящике
// осталась норма размена, остальное в конверте «К сдаче»; владелец нажимает
// «Принял». Норму размена и пересчёт магазин задаёт сам.

String _closedText(Map<String, dynamic> p) {
  final who = '${p['closed_by_name'] ?? ''}'.trim();
  final when = dateTime(p['closed_at'] ?? p['created_at']);
  final checks = tr('${p['sales_count'] ?? 0} чек.', '${p['sales_count'] ?? 0} chek');
  return who.isEmpty
      ? tr('закрыт сам $when · $checks', 'oʻzi yopildi $when · $checks')
      : tr('закрыл $who $when · $checks', '$who yopdi $when · $checks');
}

/// М1 · «Ожидает сдачи»: конверты по дням, старые — красным; нажали строку —
/// «Принять деньги», внизу «Принял всё».
class PendingCard extends StatelessWidget {
  const PendingCard({super.key, required this.items, required this.onAccept, required this.onAcceptAll, this.busy = false});

  final List<Map<String, dynamic>> items;
  final ValueChanged<Map<String, dynamic>> onAccept;
  final VoidCallback onAcceptAll;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    num total = 0;
    for (final p in items) {
      total += n(p['amount']);
    }
    return AppCard(
      border: const Color(0xFFFECDD3),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const IconBox(Icons.move_to_inbox_rounded, bg: AppColors.primarySoft, fg: AppColors.primary, size: 38, iconSize: 22, radius: 10),
          const SizedBox(width: 10),
          Expanded(child: Text(tr('Ожидает сдачи', 'Topshirish kutilmoqda'), style: AppText.title)),
          Text(money(total), style: AppText.title),
        ]),
        const SizedBox(height: 6),
        Text(
            tr('Кассир закрыл день и отложил деньги в конверт. Забрали — нажмите «Принял».',
                'Kassir kunni yopdi va pulni konvertga ajratdi. Olgan boʻlsangiz — «Qabul qildim»ni bosing.'),
            style: AppText.small),
        const SizedBox(height: 6),
        for (final p in items) _PendingRow(item: p, now: now, onTap: busy ? null : () => onAccept(p)),
        const SizedBox(height: 10),
        BigButton(
          label: items.length == 1
              ? tr('Принял · ${money(total, suffix: false)}', 'Qabul qildim · ${money(total, suffix: false)}')
              : tr('Принял всё · ${money(total, suffix: false)}', 'Hammasini qabul qildim · ${money(total, suffix: false)}'),
          icon: Icons.done_all_rounded,
          height: 52,
          busy: busy,
          onPressed: onAcceptAll,
        ),
      ]),
    );
  }
}

class _PendingRow extends StatelessWidget {
  const _PendingRow({required this.item, required this.now, required this.onTap});

  final Map<String, dynamic> item;
  final DateTime now;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final old = pendingOld(item['created_at'], now);
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Material(
        color: old ? const Color(0xFFFFF5F6) : Colors.transparent,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: onTap,
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: old ? 8 : 0, vertical: 8),
            child: Row(children: [
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(tr('Смена №${item['shift_number']} · ${item['device_name']}', 'Smena №${item['shift_number']} · ${item['device_name']}'),
                      style: AppText.bodyStrong),
                  Text(_closedText(item), style: AppText.small.copyWith(fontSize: 12)),
                ]),
              ),
              const SizedBox(width: 8),
              Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                Text(money(item['amount'], suffix: false), style: AppText.bodyStrong.copyWith(color: old ? AppColors.primary : AppColors.ink)),
                const SizedBox(height: 2),
                StatusChip(pendingAge(item['created_at'], now), tone: old ? ChipTone.red : ChipTone.amber),
              ]),
              const SizedBox(width: 4),
              const Icon(Icons.chevron_right_rounded, color: AppColors.muted),
            ]),
          ),
        ),
      ),
    );
  }
}

/// М1 · «Принято»: последние принятые конверты, недостача — жёлтым.
class AcceptedCard extends StatelessWidget {
  const AcceptedCard({super.key, required this.items});

  final List<Map<String, dynamic>> items;

  @override
  Widget build(BuildContext context) => AppCard(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(tr('ПРИНЯТО', 'QABUL QILINDI'), style: AppText.caption),
          const SizedBox(height: 4),
          for (final p in items)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Row(children: [
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(tr('Смена №${p['shift_number']} · ${p['device_name']}', 'Smena №${p['shift_number']} · ${p['device_name']}'),
                        style: AppText.bodyStrong),
                    Text(
                      [
                        tr('принял ${p['accepted_by_name'] ?? ''} ${dateTime(p['accepted_at'])}', '${p['accepted_by_name'] ?? ''} qabul qildi ${dateTime(p['accepted_at'])}'),
                        if (n(p['shortage']) > 0) tr('недостача ${money(p['shortage'], suffix: false)}', 'kamomad ${money(p['shortage'], suffix: false)}'),
                        if (n(p['shortage']) < 0) tr('излишек ${money(-n(p['shortage']), suffix: false)}', 'ortiqcha ${money(-n(p['shortage']), suffix: false)}'),
                      ].join(' · '),
                      style: AppText.small.copyWith(fontSize: 12, color: n(p['shortage']) != 0 ? AppColors.warningInk : AppColors.text2),
                    ),
                  ]),
                ),
                const SizedBox(width: 8),
                Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                  Text(money(p['received'], suffix: false), style: AppText.bodyStrong),
                  StatusChip(tr('Принято', 'Qabul qilindi'), tone: ChipTone.green),
                ]),
              ]),
            ),
        ]),
      );
}

/// М4 · Деньги копятся в ящике: «Задать норму размена» (если не задана) и
/// «Пересчитать ящик».
class FloatWarning extends StatelessWidget {
  const FloatWarning({super.key, required this.noFloat, required this.onSettings, required this.onRecount});

  final bool noFloat;
  final VoidCallback onSettings;
  final VoidCallback onRecount;

  @override
  Widget build(BuildContext context) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(color: AppColors.warningSoft, borderRadius: BorderRadius.circular(12)),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Icon(Icons.warning_amber_rounded, size: 20, color: AppColors.warningInk),
            const SizedBox(width: 8),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(tr('Деньги копятся в ящике', 'Pul gʻaladonda yigʻilib qolyapti'), style: AppText.bodyStrong.copyWith(color: AppColors.warningInk)),
                const SizedBox(height: 2),
                Text(
                    noFloat
                        ? tr('Похоже, деньги забирали без отметки. Задайте норму размена и пересчитайте ящик один раз — дальше при «Закрыть день» в ящике будет оставаться только размен.',
                            'Pul belgilanmasdan olinganga oʻxshaydi. Maydalik meʼyorini belgilang va gʻaladonni bir marta sanang — keyin «Kunni yopish»da gʻaladonda faqat maydalik qoladi.')
                        : tr('Похоже, деньги забирали без отметки. Пересчитайте ящик один раз — дальше при «Закрыть день» в ящике будет оставаться только размен.',
                            'Pul belgilanmasdan olinganga oʻxshaydi. Gʻaladonni bir marta sanang — keyin «Kunni yopish»da gʻaladonda faqat maydalik qoladi.'),
                    style: AppText.small.copyWith(color: AppColors.warningInk)),
              ]),
            ),
          ]),
        ),
        const SizedBox(height: 10),
        if (noFloat) ...[
          SmallButton(label: tr('Задать норму размена', 'Maydalik meʼyorini belgilash'), icon: Icons.tune_rounded, onPressed: onSettings),
          const SizedBox(height: 8),
        ],
        BigButton(label: tr('Пересчитать ящик', 'Gʻaladonni sanash'), icon: Icons.calculate_rounded, height: 52, onPressed: onRecount),
      ]);
}

InputDecoration _sumField(String label, {String? error, String? helper}) => InputDecoration(
      labelText: label,
      suffixText: tr('сум', 'soʻm'),
      errorText: error,
      helperText: helper,
      helperMaxLines: 3,
    );

final _digits = [FilteringTextInputFormatter.allow(RegExp(r'[0-9\s]'))];

String _fmt(num v) => money(v < 0 ? 0 : v, suffix: false).replaceAll(' ', ' ');

Widget _note(bool ok, String text) => Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(color: ok ? AppColors.successSoft : AppColors.warningSoft, borderRadius: BorderRadius.circular(12)),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(ok ? Icons.check_circle_rounded : Icons.warning_amber_rounded, size: 20, color: ok ? AppColors.successInk : AppColors.warningInk),
        const SizedBox(width: 10),
        Expanded(
          child: Text(text, style: AppText.small.copyWith(color: ok ? AppColors.successInk : AppColors.warningInk, fontWeight: FontWeight.w600)),
        ),
      ]),
    );

Future<T?> _sheet<T>(BuildContext context, Widget child) => showModalBottomSheet<T>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      backgroundColor: AppColors.white,
      builder: (_) => child,
    );

/// М2 / М3 · «Принять деньги»: сумма подставлена — «Принял»; другая сумма —
/// недостача смены. Возвращает true, если принято.
Future<bool?> showAcceptSheet(BuildContext context, Map<String, dynamic> item) => _sheet<bool>(context, _AcceptSheet(item: item));

class _AcceptSheet extends StatefulWidget {
  const _AcceptSheet({required this.item});

  final Map<String, dynamic> item;

  @override
  State<_AcceptSheet> createState() => _AcceptSheetState();
}

class _AcceptSheetState extends State<_AcceptSheet> {
  late final _got = TextEditingController(text: _fmt(n(widget.item['amount'])));
  String? _error;
  bool _busy = false;

  @override
  void dispose() {
    _got.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final got = plainAmount(_got.text);
    if (got.isEmpty) {
      setState(() => _error = tr('Сколько получили?', 'Qancha oldingiz?'));
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await context.read<Api>().post('/store/finance/pending-handovers/${widget.item['id']}/accept', {'received': got});
      if (!mounted) return;
      final messenger = ScaffoldMessenger.of(context);
      Navigator.of(context).pop(true);
      messenger.showSnackBar(SnackBar(content: Text(tr('Принято ${money(n(got))}', '${money(n(got))} qabul qilindi'))));
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.item;
    final shortage = acceptShortage(p['amount'], _got.text);
    final got = n(plainAmount(_got.text));
    final was = n(p['amount']) + n(p['left_amount']);
    return Padding(
      padding: EdgeInsets.fromLTRB(16, 0, 16, 16 + MediaQuery.of(context).viewInsets.bottom),
      child: SafeArea(
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text(tr('Принять деньги', 'Pulni qabul qilish'), style: AppText.h3),
            Text(tr('Смена №${p['shift_number']} · ${p['device_name']} · ${_closedText(p)}', 'Smena №${p['shift_number']} · ${p['device_name']} · ${_closedText(p)}'),
                style: AppText.small),
            const SizedBox(height: 14),
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(color: AppColors.soft, borderRadius: BorderRadius.circular(14)),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(tr('К сдаче', 'Topshirish kerak'), style: AppText.small),
                Text(money(p['amount']), style: AppText.h2),
                Text(
                    tr('в ящике было ${money(was, suffix: false)} · оставлен размен ${money(p['left_amount'], suffix: false)}',
                        'gʻaladonda ${money(was, suffix: false)} edi · maydalikka ${money(p['left_amount'], suffix: false)} qoldirildi'),
                    style: AppText.small.copyWith(fontSize: 12)),
              ]),
            ),
            const SizedBox(height: 14),
            TextField(
              controller: _got,
              keyboardType: TextInputType.number,
              inputFormatters: _digits,
              style: AppText.title,
              onChanged: (_) => setState(() => _error = null),
              decoration: _sumField(tr('Получил', 'Oldim'), error: _error),
            ),
            const SizedBox(height: 12),
            if (shortage == 0)
              _note(true, tr('Сходится — смена №${p['shift_number']} сдана', 'Mos keldi — №${p['shift_number']} smena topshirildi'))
            else if (shortage > 0)
              _note(
                  false,
                  tr('Недостача ${money(shortage)}: в конверте меньше, чем по расчёту. Запишем недостачу на смену №${p['shift_number']}${p['closed_by_name'] == null ? '' : ' (${p['closed_by_name']})'} — видно в «Контроле кассиров».',
                      'Kamomad ${money(shortage)}: konvertda hisobdagidan kam. Kamomadni №${p['shift_number']} smenaga yozamiz${p['closed_by_name'] == null ? '' : ' (${p['closed_by_name']})'} — «Kassirlar nazorati»da koʻrinadi.'))
            else
              _note(false, tr('Излишек ${money(-shortage)} — запишем на смену', 'Ortiqcha ${money(-shortage)} — smenaga yozamiz')),
            const SizedBox(height: 16),
            BigButton(
              label: shortage > 0
                  ? tr('Принял ${money(got, suffix: false)} · недостача ${money(shortage, suffix: false)}',
                      '${money(got, suffix: false)} qabul qildim · kamomad ${money(shortage, suffix: false)}')
                  : tr('Принял ${money(got, suffix: false)}', '${money(got, suffix: false)} qabul qildim'),
              icon: Icons.done_rounded,
              busy: _busy,
              onPressed: _submit,
            ),
            if (shortage != 0) ...[
              const SizedBox(height: 8),
              TextButton.icon(
                onPressed: () => setState(() => _got.text = _fmt(n(p['amount']))),
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

/// М5 · Пересчитать ящик один раз: разница — «Забирал я, не отмечал» (по
/// умолчанию, не недостача кассира) или «Денег не хватает». Возвращает true,
/// если записано.
Future<bool?> showRecountSheet(BuildContext context, Map<String, dynamic> drawer) => _sheet<bool>(context, _RecountSheet(drawer: drawer));

class _RecountSheet extends StatefulWidget {
  const _RecountSheet({required this.drawer});

  final Map<String, dynamic> drawer;

  @override
  State<_RecountSheet> createState() => _RecountSheetState();
}

class _RecountSheetState extends State<_RecountSheet> {
  final _counted = TextEditingController();
  String _kind = 'taken';
  String? _error;
  bool _busy = false;

  @override
  void dispose() {
    _counted.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final c = plainAmount(_counted.text);
    if (c.isEmpty) {
      setState(() => _error = tr('Сколько посчитали в ящике?', 'Gʻaladonda qancha sanadingiz?'));
      return;
    }
    final st = context.read<StoreState>();
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await context.read<Api>().post('/store/finance/drawer/recount', {'store_id': st.storeId, 'counted': c, 'kind': _kind});
      if (!mounted) return;
      final messenger = ScaffoldMessenger.of(context);
      Navigator.of(context).pop(true);
      messenger.showSnackBar(SnackBar(content: Text(tr('Записано: в ящике ${money(n(c))}', 'Yozildi: gʻaladonda ${money(n(c))}'))));
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Widget _radio(String kind, String title, String sub) {
    final on = _kind == kind;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: AppColors.white,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: () => setState(() => _kind = kind),
          child: Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: on ? AppColors.ink : AppColors.line, width: on ? 2 : 1),
            ),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Icon(on ? Icons.radio_button_checked_rounded : Icons.radio_button_unchecked_rounded, color: on ? AppColors.primary : AppColors.muted),
              const SizedBox(width: 10),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(title, style: AppText.bodyStrong),
                  Text(sub, style: AppText.small.copyWith(fontSize: 12)),
                ]),
              ),
            ]),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final d = widget.drawer;
    final shifts = ((d['shifts'] as List?) ?? const []).cast<Map<String, dynamic>>();
    final counted = plainAmount(_counted.text);
    final diff = recountDiff(d['amount'], _counted.text);
    final float = d['cash_float'];
    final no = shifts.length == 1 ? tr(' · смена №${shifts.first['number']}', ' · smena №${shifts.first['number']}') : '';
    return Padding(
      padding: EdgeInsets.fromLTRB(16, 0, 16, 16 + MediaQuery.of(context).viewInsets.bottom),
      child: SafeArea(
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text(tr('Пересчитать ящик', 'Gʻaladonni sanash'), style: AppText.h3),
            Text(tr('${d['cashbox_name']}$no · один раз, чтобы начать с правильной суммы', '${d['cashbox_name']}$no · toʻgʻri summadan boshlash uchun bir marta'),
                style: AppText.small),
            const SizedBox(height: 14),
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(color: AppColors.soft, borderRadius: BorderRadius.circular(14)),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(tr('По расчёту в ящике', 'Hisob boʻyicha gʻaladonda'), style: AppText.small),
                Text(money(d['amount']), style: AppText.h2),
              ]),
            ),
            const SizedBox(height: 14),
            TextField(
              controller: _counted,
              autofocus: true,
              keyboardType: TextInputType.number,
              inputFormatters: _digits,
              style: AppText.title,
              onChanged: (_) => setState(() => _error = null),
              decoration: _sumField(tr('Посчитали в ящике', 'Gʻaladonda sanaldi'), error: _error),
            ),
            if (counted.isNotEmpty && diff != 0) ...[
              const SizedBox(height: 14),
              if (diff > 0) ...[
                Text(tr('Разница ${money(diff)} — что это?', 'Farq ${money(diff)} — bu nima?'), style: AppText.bodyStrong),
                const SizedBox(height: 8),
                _radio('taken', tr('Забирал я, не отмечал', 'Oʻzim olganman, belgilamaganman'),
                    tr('Запишем «Сдачи прошлых дней без отметки» — это не недостача кассира', '«Oldingi kunlarda belgilanmagan topshirishlar» deb yozamiz — bu kassir kamomadi emas')),
                _radio('shortage', tr('Денег не хватает', 'Pul yetishmayapti'),
                    shifts.length == 1
                        ? tr('Запишем недостачу на смену №${shifts.first['number']}', '№${shifts.first['number']} smenaga kamomad yozamiz')
                        : tr('Запишем недостачу', 'Kamomad yozamiz')),
              ] else
                _note(false, tr('В ящике больше на ${money(-diff)} — запишем излишек', 'Gʻaladonda ${money(-diff)} koʻp — ortiqcha deb yozamiz')),
            ],
            const SizedBox(height: 8),
            if (counted.isNotEmpty)
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(color: AppColors.soft, borderRadius: BorderRadius.circular(12)),
                child: Text(
                    float == null
                        ? tr('В ящике станет ${money(n(counted))}. Задайте норму размена — тогда при «Закрыть день» в ящике будет оставаться только размен.',
                            'Gʻaladonda ${money(n(counted))} boʻladi. Maydalik meʼyorini belgilang — shunda «Kunni yopish»da gʻaladonda faqat maydalik qoladi.')
                        : tr('В ящике станет ${money(n(counted))}. При «Закрыть день» останется размен ${money(float, suffix: false)}, остальное — «К сдаче».',
                            'Gʻaladonda ${money(n(counted))} boʻladi. «Kunni yopish»da ${money(float, suffix: false)} maydalik qoladi, qolgani — «Topshirish».'),
                    style: AppText.small),
              ),
            const SizedBox(height: 16),
            BigButton(
              label: counted.isEmpty
                  ? tr('Записать', 'Yozish')
                  : tr('Записать: в ящике ${money(n(counted), suffix: false)}', 'Yozish: gʻaladonda ${money(n(counted), suffix: false)}'),
              icon: Icons.done_rounded,
              busy: _busy,
              onPressed: counted.isEmpty ? null : _submit,
            ),
          ]),
        ),
      ),
    );
  }
}

/// М6 · Касса магазина: норма размена, напоминание о сдаче, пересчёт ящика.
/// Магазин задаёт сам — Super Market ничего не подставляет.
class CashSettingsScreen extends StatefulWidget {
  const CashSettingsScreen({super.key});

  @override
  State<CashSettingsScreen> createState() => _CashSettingsScreenState();
}

class _CashSettingsScreenState extends State<CashSettingsScreen> {
  final _float = TextEditingController();
  int? _recount;
  bool _remind = true;
  bool _loaded = false;
  bool _busy = false;
  Object? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  @override
  void dispose() {
    _float.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final st = context.read<StoreState>();
    try {
      final s = await context.read<Api>().get('/store/pos/cash-settings', {'store_id': st.storeId}) as Map<String, dynamic>;
      if (!mounted) return;
      setState(() {
        _float.text = s['cash_float'] == null ? '' : _fmt(n(s['cash_float']));
        _recount = (s['recount_every_days'] as num?)?.toInt();
        _remind = s['handover_remind'] != false;
        _loaded = true;
        _error = null;
      });
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  Future<void> _save() async {
    final st = context.read<StoreState>();
    final f = plainAmount(_float.text);
    setState(() => _busy = true);
    try {
      await context.read<Api>().put('/store/pos/cash-settings', {
        'store_id': st.storeId,
        'cash_float': f.isEmpty ? null : f,
        'recount_every_days': _recount,
        'handover_remind': _remind,
      });
      if (!mounted) return;
      final messenger = ScaffoldMessenger.of(context);
      Navigator.of(context).pop(true);
      messenger.showSnackBar(SnackBar(content: Text(tr('Сохранено — кассы узнают через минуту', 'Saqlandi — kassalar bir daqiqada bilib oladi'))));
    } on ApiError catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final st = context.watch<StoreState>();
    final float = plainAmount(_float.text);
    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(
        backgroundColor: AppColors.bg,
        title: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(tr('Касса магазина', 'Doʻkon kassasi'), style: AppText.title),
          Text('${st.store?['name'] ?? ''}', style: AppText.small),
        ]),
      ),
      body: !_loaded
          ? Center(
              child: _error != null
                  ? Padding(padding: const EdgeInsets.all(24), child: Text(tr('Не удалось загрузить: $_error', 'Yuklab boʻlmadi: $_error'), style: AppText.small))
                  : const CircularProgressIndicator())
          : SafeArea(
              child: ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 24), children: [
                AppCard(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(tr('Норма размена', 'Maydalik meʼyori'), style: AppText.title),
                    const SizedBox(height: 10),
                    TextField(
                      controller: _float,
                      keyboardType: TextInputType.number,
                      inputFormatters: _digits,
                      style: AppText.title,
                      onChanged: (_) => setState(() {}),
                      decoration: InputDecoration(
                        labelText: tr('Оставлять в ящике после «Закрыть день»', '«Kunni yopish»dan keyin gʻaladonda qoldirish'),
                        hintText: tr('Введите сумму', 'Summani kiriting'),
                        suffixText: tr('сум', 'soʻm'),
                        helperText: tr('Магазин задаёт сам. Всё сверх нормы — «К сдаче» владельцу. Пока не задана — в ящике остаётся всё, как раньше.',
                            'Doʻkon oʻzi belgilaydi. Meʼyordan ortigʻi — egasiga «Topshirish». Belgilanmaguncha — gʻaladonda hammasi qoladi, avvalgidek.'),
                        helperMaxLines: 3,
                        suffixIcon: float.isEmpty
                            ? null
                            : IconButton(icon: const Icon(Icons.close_rounded), onPressed: () => setState(() => _float.clear())),
                      ),
                    ),
                    const SizedBox(height: 10),
                    Wrap(spacing: 6, runSpacing: 6, children: [
                      for (final v in floatChips)
                        ChoiceChip(
                          label: Text(money(v, suffix: false)),
                          selected: float.isNotEmpty && n(float) == v,
                          showCheckmark: false,
                          selectedColor: AppColors.ink,
                          labelStyle: AppText.bodyStrong.copyWith(color: float.isNotEmpty && n(float) == v ? AppColors.white : AppColors.ink),
                          onSelected: (_) => setState(() => _float.text = _fmt(v)),
                        ),
                    ]),
                  ]),
                ),
                const SizedBox(height: 12),
                AppCard(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      value: _remind,
                      activeColor: AppColors.primary,
                      onChanged: (v) => setState(() => _remind = v),
                      title: Text(tr('Напоминать о сдаче', 'Topshirish haqida eslatish'), style: AppText.bodyStrong),
                      subtitle: Text(
                          tr('Если есть «К сдаче» — уведомление в 21:00. Не принято больше суток — красным.',
                              '«Topshirish» boʻlsa — soat 21:00 da bildirishnoma. Bir kundan ortiq qabul qilinmasa — qizil.'),
                          style: AppText.small),
                    ),
                    const Divider(height: 20),
                    Text(tr('Пересчёт ящика при «Закрыть день»', '«Kunni yopish»da gʻaladonni sanash'), style: AppText.bodyStrong),
                    const SizedBox(height: 8),
                    SizedBox(
                      width: double.infinity,
                      child: SegmentedButton<int>(
                        showSelectedIcon: false,
                        segments: [
                          ButtonSegment(value: 0, label: Text(tr('Не требовать', 'Talab qilinmaydi'))),
                          ButtonSegment(value: 7, label: Text(tr('Раз в 7 дней', '7 kunda bir'))),
                          ButtonSegment(value: 1, label: Text(tr('Каждый день', 'Har kuni'))),
                        ],
                        selected: {_recount ?? 0},
                        onSelectionChanged: (v) => setState(() => _recount = v.first == 0 ? null : v.first),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                        tr('Магазин выбирает сам. В день пересчёта Enter на кассе сначала откроет пересчёт.',
                            'Doʻkon oʻzi tanlaydi. Sanash kuni kassada Enter avval sanashni ochadi.'),
                        style: AppText.small),
                  ]),
                ),
                const SizedBox(height: 12),
                Text(
                    tr('Настройки — у каждого магазина свои. То же в панели: Касса → Настройки.',
                        'Sozlamalar har bir doʻkonda oʻziga xos. Panelda ham shunday: Kassa → Sozlamalar.'),
                    style: AppText.small),
                const SizedBox(height: 16),
                BigButton(label: tr('Сохранить', 'Saqlash'), icon: Icons.check_rounded, busy: _busy, onPressed: _save),
              ]),
            ),
    );
  }
}
