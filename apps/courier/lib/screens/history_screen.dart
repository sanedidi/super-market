import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:sm_core/sm_core.dart';

import '../logic.dart';
import '../state.dart';
import '../ui/theme.dart';
import '../ui/widgets.dart';

/// История доставок: сегодня, вчера, неделя (Figma К7).
class HistoryScreen extends StatefulWidget {
  const HistoryScreen({super.key});

  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen> {
  static List<(String, String)> get _periods =>
      [('today', tr('Сегодня', 'Bugun')), ('yesterday', tr('Вчера', 'Kecha')), ('week', tr('Неделя', 'Hafta'))];
  String _period = 'today';
  Map<String, dynamic>? _data;
  Map<String, dynamic>? _cash;
  Object? _error;
  bool _loading = false;
  int? _lastDone;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    if (!mounted) return;
    final period = _period;
    setState(() => _loading = true);
    try {
      final st = context.read<CourierState>();
      final r = await Future.wait([st.history(period), st.cash().catchError((_) => <String, dynamic>{})]);
      if (mounted && period == _period) {
        setState(() {
          _data = r[0];
          _cash = r[1].isEmpty ? _cash : r[1];
          _error = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = e);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    // Доставили заказ на вкладке «Заказы» — обновить историю.
    final done = context.select<CourierState, int>((s) => groupOrders(s.orders).done.length);
    if (_lastDone != null && done != _lastDone) WidgetsBinding.instance.addPostFrameCallback((_) => _load());
    _lastDone = done;
    final d = _data;
    final items = ((d?['items'] as List?) ?? const []).whereType<Map>().map((m) => m.cast<String, dynamic>()).toList();
    final cash = num.tryParse('${d?['cash_total'] ?? 0}') ?? 0;
    final onHand = num.tryParse('${_cash?['on_hand'] ?? 0}') ?? 0;
    final pending = num.tryParse('${_cash?['pending'] ?? 0}') ?? 0;
    final recent = _recentHandovers();
    final top = MediaQuery.paddingOf(context).top;
    return Scaffold(
      backgroundColor: AppColors.bg,
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(padding: EdgeInsets.fromLTRB(20, top + 12, 20, 24), children: [
          Text(tr('История', 'Tarix'), style: AppText.h1),
          const SizedBox(height: 16),
          Container(
            padding: const EdgeInsets.all(4),
            decoration: BoxDecoration(color: AppColors.white, borderRadius: BorderRadius.circular(14)),
            child: Row(children: [
              for (final p in _periods)
                Expanded(
                  child: Material(
                    color: _period == p.$1 ? AppColors.ink : Colors.transparent,
                    borderRadius: BorderRadius.circular(10),
                    child: InkWell(
                      borderRadius: BorderRadius.circular(10),
                      onTap: () {
                        if (_period == p.$1) return;
                        setState(() {
                          _period = p.$1;
                          _data = null;
                        });
                        _load();
                      },
                      child: SizedBox(
                        height: 36,
                        child: Center(
                          child: Text(p.$2, style: AppText.bodyStrong.copyWith(fontSize: 14, color: _period == p.$1 ? AppColors.white : AppColors.text2)),
                        ),
                      ),
                    ),
                  ),
                ),
            ]),
          ),
          const SizedBox(height: 14),
          if (d == null && _error != null)
            EmptyState(
              icon: Icons.wifi_off_rounded,
              title: tr('Не удалось загрузить', 'Yuklab boʻlmadi'),
              text: '$_error',
              action: tr('Повторить', 'Qayta urinish'),
              onAction: _load,
            )
          else if (d == null)
            const Padding(padding: EdgeInsets.all(48), child: Center(child: CircularProgressIndicator()))
          else ...[
            // Три плитки одной высоты: по самой высокой (подпись в две строки).
            IntrinsicHeight(child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              _Stat(icon: Icons.task_alt_rounded, fg: AppColors.successInk, bg: AppColors.successSoft, value: '${d['delivered'] ?? 0}', label: tr('доставлено', 'yetkazildi')),
              const SizedBox(width: 12),
              _Stat(icon: Icons.payments_rounded, fg: AppColors.warningInk, bg: AppColors.warningSoft, value: money(cash, suffix: false), label: tr('сум наличными', 'soʻm naqd')),
              const SizedBox(width: 12),
              _Stat(
                icon: Icons.timer_rounded,
                fg: AppColors.blue,
                bg: AppColors.blueSoft,
                value: (d['avg_minutes'] as num? ?? 0) > 0 ? tr('${d['avg_minutes']} мин', '${d['avg_minutes']} daq.') : '—',
                label: tr('в пути в среднем', 'oʻrtacha yoʻlda'),
              ),
            ])),
            // К10 · «Сдать в кассу» — пока на руках есть наличные, которые ещё не сданы.
            if (onHand - pending > 0) ...[
              const SizedBox(height: 14),
              Material(
                color: AppColors.ink,
                borderRadius: BorderRadius.circular(20),
                child: InkWell(
                  borderRadius: BorderRadius.circular(20),
                  onTap: _handOver,
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Row(children: [
                      Container(
                        width: 44,
                        height: 44,
                        decoration: BoxDecoration(color: AppColors.white.withValues(alpha: 0.14), borderRadius: BorderRadius.circular(12)),
                        child: const Icon(Icons.account_balance_wallet_rounded, color: AppColors.white, size: 24),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Text(tr('Сдать в кассу магазина', 'Doʻkon kassasiga topshirish'), style: AppText.bodyStrong.copyWith(color: AppColors.white)),
                          Text(tr('На руках ${money(onHand - pending)} наличными', 'Qoʻlingizda ${money(onHand - pending)} naqd'),
                              style: AppText.small.copyWith(color: const Color(0xFFD1D1D6))),
                        ]),
                      ),
                      const Icon(Icons.chevron_right_rounded, color: AppColors.white),
                    ]),
                  ),
                ),
              ),
            ] else if (cash > 0 && _cash == null) ...[
              const SizedBox(height: 14),
              Text(_cashText(cash), style: AppText.small),
            ],
            // К11 · сдачи: ждёт кассира, сдано, расхождение.
            for (final h in recent) ...[const SizedBox(height: 10), _HandoverTile(h: h)],
            const SizedBox(height: 14),
            if (items.isEmpty)
              EmptyState(
                icon: Icons.history_rounded,
                title: tr('Доставок нет', 'Yetkazishlar yoʻq'),
                text: tr('Здесь будут доставленные заказы', 'Yetkazilgan buyurtmalar shu yerda chiqadi'),
              )
            else
              Container(
                decoration: BoxDecoration(color: AppColors.white, borderRadius: BorderRadius.circular(20)),
                child: Column(children: [
                  for (var i = 0; i < items.length; i++) _Row(item: items[i], last: i == items.length - 1, showDate: _period == 'week'),
                ]),
              ),
            if (_loading) const Padding(padding: EdgeInsets.only(top: 12), child: Center(child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)))),
          ],
        ]),
      ),
    );
  }

  /// Сдачи, которые ждут кассира, и подтверждённые за последние 2 дня (до 3).
  List<Map<String, dynamic>> _recentHandovers() {
    final all = ((_cash?['handovers'] as List?) ?? const []).whereType<Map>().map((m) => m.cast<String, dynamic>());
    final since = DateTime.now().subtract(const Duration(days: 2));
    return all
        .where((h) => h['status'] == 'pending' || (DateTime.tryParse('${h['answered_at'] ?? ''}')?.isAfter(since) ?? false))
        .take(3)
        .toList();
  }

  Future<void> _handOver() async {
    final stores = ((_cash?['stores'] as List?) ?? const []).whereType<Map>().map((m) => m.cast<String, dynamic>()).toList();
    if (stores.isEmpty) return;
    final done = await showSheet<bool>(context, (_) => _HandoverSheet(stores: stores));
    if (done == true && mounted) _load();
  }

  String _periodText() => switch (_period) { 'yesterday' => 'вчера', 'week' => 'неделю', _ => 'сегодня' };

  /// «125 000 сум наличными за сегодня».
  String _cashText(num cash) => tr(
        '${money(cash)} наличными за ${_periodText()}',
        switch (_period) {
          'yesterday' => 'Kechagi naqd pul: ${money(cash)}',
          'week' => 'Haftalik naqd pul: ${money(cash)}',
          _ => 'Bugungi naqd pul: ${money(cash)}',
        },
      );
}

class _Stat extends StatelessWidget {
  const _Stat({required this.icon, required this.fg, required this.bg, required this.value, required this.label});
  final IconData icon;
  final Color fg, bg;
  final String value, label;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(color: AppColors.white, borderRadius: BorderRadius.circular(18)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Container(
            width: 32,
            height: 32,
            decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(10)),
            child: Icon(icon, size: 18, color: fg),
          ),
          const SizedBox(height: 8),
          FittedBox(fit: BoxFit.scaleDown, alignment: Alignment.centerLeft, child: Text(value, style: AppText.title)),
          Text(label, style: AppText.small.copyWith(fontSize: 12), maxLines: 2, overflow: TextOverflow.ellipsis),
        ]),
      ),
    );
  }
}

class _Row extends StatelessWidget {
  const _Row({required this.item, required this.last, required this.showDate});
  final Map<String, dynamic> item;
  final bool last;
  final bool showDate;

  @override
  Widget build(BuildContext context) {
    final t = DateTime.tryParse('${item['delivered_at']}')?.toLocal();
    final when = t == null ? '' : (showDate ? '${t.day.toString().padLeft(2, '0')}.${t.month.toString().padLeft(2, '0')} ${hm(t)}' : hm(t));
    final cash = item['cash'] == true;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(border: last ? null : const Border(bottom: BorderSide(color: AppColors.line))),
      child: Row(children: [
        Container(
          width: 40,
          height: 40,
          decoration: const BoxDecoration(color: AppColors.successSoft, shape: BoxShape.circle),
          child: const Icon(Icons.check_rounded, color: AppColors.successInk, size: 20),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('№ ${item['number']} · $when', style: AppText.bodyStrong),
            Text('${item['address'] ?? ''}', style: AppText.small, maxLines: 1, overflow: TextOverflow.ellipsis),
          ]),
        ),
        const SizedBox(width: 8),
        Text(cash ? '+${money(item['total'], suffix: false)}' : tr('оплачен', 'toʻlandi'),
            style: AppText.bodyStrong.copyWith(fontSize: 14, color: cash ? AppColors.warningInk : AppColors.text2)),
      ]),
    );
  }
}

/// К10 · Сдать в кассу: сумма (можно часть) и магазин → «Сдал».
class _HandoverSheet extends StatefulWidget {
  const _HandoverSheet({required this.stores});
  final List<Map<String, dynamic>> stores;

  @override
  State<_HandoverSheet> createState() => _HandoverSheetState();
}

class _HandoverSheetState extends State<_HandoverSheet> {
  late Map<String, dynamic> _store = widget.stores.firstWhere((s) => _free(s) > 0, orElse: () => widget.stores.first);
  late final _amount = TextEditingController(text: _plain(_free(_store)));
  bool _busy = false;

  static num _free(Map<String, dynamic> s) => (num.tryParse('${s['on_hand']}') ?? 0) - (num.tryParse('${s['pending']}') ?? 0);
  static String _plain(num v) => v == v.roundToDouble() ? '${v.round()}' : v.toStringAsFixed(2);
  num get _value => num.tryParse(_amount.text.replaceAll(RegExp(r'\s'), '').replaceAll(',', '.')) ?? 0;

  @override
  void dispose() {
    _amount.dispose();
    super.dispose();
  }

  Future<void> _pickStore() async {
    final s = await showSheet<Map<String, dynamic>>(
      context,
      (ctx) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text(tr('Магазин', 'Doʻkon'), style: AppText.h3),
        const SizedBox(height: 8),
        for (final s in widget.stores)
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.storefront_rounded, color: AppColors.blue),
            title: Text('${s['store_name']}', style: AppText.bodyStrong),
            subtitle: Text(tr('на руках ${money(_free(s))}', 'qoʻlda ${money(_free(s))}'), style: AppText.small),
            onTap: _free(s) > 0 ? () => Navigator.of(ctx).pop(s) : null,
          ),
      ]),
    );
    if (s != null && mounted) {
      setState(() {
        _store = s;
        _amount.text = _plain(_free(s));
      });
    }
  }

  Future<void> _send() async {
    final v = _value;
    if (v <= 0 || v > _free(_store)) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(tr('Можно сдать от 1 до ${money(_free(_store))}', '1 dan ${money(_free(_store))} gacha topshirish mumkin'))));
      return;
    }
    setState(() => _busy = true);
    try {
      await context.read<CourierState>().handOver('${_store['store_id']}', _plain(v));
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final free = _free(_store);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Text(tr('Сдать в кассу магазина', 'Doʻkon kassasiga topshirish'), style: AppText.h3),
      const SizedBox(height: 4),
      Text(tr('Кассир увидит сумму в «SM Магазин» и нажмёт «Получил»', 'Kassir summani «SM Doʻkon»da koʻrib, «Oldim»ni bosadi'), style: AppText.small),
      const SizedBox(height: 16),
      TextField(
        controller: _amount,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]'))],
        style: AppText.h2,
        onChanged: (_) => setState(() {}),
        decoration: InputDecoration(labelText: tr('Сумма', 'Summa'), suffixText: tr('сум', 'soʻm')),
      ),
      const SizedBox(height: 4),
      Text(tr('На руках ${money(free)} — можно сдать часть', 'Qoʻlda ${money(free)} — bir qismini topshirsa boʻladi'), style: AppText.small.copyWith(fontSize: 12)),
      const SizedBox(height: 12),
      Material(
        color: AppColors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16), side: const BorderSide(color: AppColors.line)),
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: widget.stores.length > 1 ? _pickStore : null,
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Row(children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(color: AppColors.blueSoft, borderRadius: BorderRadius.circular(12)),
                child: const Icon(Icons.storefront_rounded, color: AppColors.blue, size: 20),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(tr('Магазин', 'Doʻkon'), style: AppText.small.copyWith(fontSize: 12)),
                  Text('${_store['store_name']}', style: AppText.bodyStrong),
                ]),
              ),
              if (widget.stores.length > 1) const Icon(Icons.expand_more_rounded, color: AppColors.muted),
            ]),
          ),
        ),
      ),
      const SizedBox(height: 12),
      Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Icon(Icons.info_outline_rounded, size: 16, color: AppColors.text2),
        const SizedBox(width: 8),
        Expanded(
          child: Text(tr('Пока кассир не подтвердит — сумма остаётся на вас.', 'Kassir tasdiqlamaguncha summa sizda qoladi.'),
              style: AppText.small.copyWith(fontSize: 12)),
        ),
      ]),
      const SizedBox(height: 16),
      SheetButton(
        label: tr('Сдал ${money(_value)}', '${money(_value)} topshirdim'),
        busy: _busy,
        onPressed: _value > 0 ? _send : null,
      ),
    ]);
  }
}

/// К11 · сдача: ждёт кассира (жёлтая), сдано (зелёная), получили меньше (красная).
class _HandoverTile extends StatelessWidget {
  const _HandoverTile({required this.h});
  final Map<String, dynamic> h;

  @override
  Widget build(BuildContext context) {
    final amount = num.tryParse('${h['amount']}') ?? 0;
    final received = num.tryParse('${h['received'] ?? ''}');
    final at = DateTime.tryParse('${h['answered_at'] ?? h['created_at']}')?.toLocal();
    final time = at == null ? '' : '${at.hour.toString().padLeft(2, '0')}:${at.minute.toString().padLeft(2, '0')}';
    final (IconData icon, Color bg, Color fg, String title, String text) = switch (h['status']) {
      'pending' => (
          Icons.hourglass_top_rounded,
          AppColors.warningSoft,
          AppColors.warningInk,
          tr('Ждёт подтверждения магазина', 'Doʻkon tasdigʻini kutmoqda'),
          tr('Сдали ${money(amount)} · ${h['store_name']} · $time', '${money(amount)} topshirildi · ${h['store_name']} · $time'),
        ),
      _ when received != null && received < amount => (
          Icons.error_outline_rounded,
          AppColors.errorSoft,
          AppColors.error,
          tr('Магазин получил ${money(received)} из ${money(amount)}', 'Doʻkon ${money(amount)} dan ${money(received)} oldi'),
          tr('На вас осталось ${money(amount - received)} · сдайте или свяжитесь с кассиром',
              'Sizda ${money(amount - received)} qoldi · topshiring yoki kassir bilan bogʻlaning'),
        ),
      _ => (
          Icons.verified_rounded,
          AppColors.successSoft,
          AppColors.successInk,
          tr('Сдано ${money(received ?? amount)}', '${money(received ?? amount)} topshirildi'),
          [
            '${h['store_name']}',
            if ('${h['answered_by_name'] ?? ''}'.isNotEmpty) tr('подтвердил(а) ${h['answered_by_name']}', '${h['answered_by_name']} tasdiqladi'),
            time,
          ].join(' · '),
        ),
    };
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(20)),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Container(
          width: 44,
          height: 44,
          decoration: BoxDecoration(color: AppColors.white, borderRadius: BorderRadius.circular(12)),
          child: Icon(icon, color: fg, size: 24),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title, style: AppText.bodyStrong.copyWith(color: fg)),
            Text(text, style: AppText.small.copyWith(color: fg)),
          ]),
        ),
      ]),
    );
  }
}
