import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:sm_core/sm_core.dart';

import '../finance/finance_logic.dart';
import '../ui/theme.dart';
import '../ui/widgets.dart';
import 'cashiers_screen.dart';

/// М17 · Смена кассира: сверка наличных, показатели, события смены.
class ShiftScreen extends StatefulWidget {
  const ShiftScreen({super.key, required this.id});

  final String id;

  @override
  State<ShiftScreen> createState() => _ShiftScreenState();
}

class _ShiftScreenState extends State<ShiftScreen> {
  Map<String, dynamic>? _sh;
  List<Map<String, dynamic>> _events = const [];
  Object? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final api = context.read<Api>();
    try {
      final res = await Future.wait<Object?>([
        api.get('/store/pos/shifts/${widget.id}'),
        api.list('/store/pos/shifts/${widget.id}/events'),
      ]);
      if (!mounted) return;
      setState(() {
        _sh = res[0] as Map<String, dynamic>;
        _events = res[1] as List<Map<String, dynamic>>;
        _error = null;
      });
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final sh = _sh;
    return Scaffold(
      appBar: AppBar(
        title: sh == null
            ? Text(tr('Смена', 'Smena'))
            : Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('${sh['opened_by_name']}'),
                Text('${tr('Смена', 'Smena')} № ${sh['number']} · ${shiftLine(sh)}', style: AppText.small, maxLines: 1, overflow: TextOverflow.ellipsis),
              ]),
      ),
      body: sh == null
          ? Center(
              child: _error == null
                  ? const CircularProgressIndicator()
                  : EmptyState(
                      icon: Icons.wifi_off_rounded,
                      title: tr('Не удалось загрузить смену', 'Smenani yuklab boʻlmadi'),
                      text: '$_error',
                      action: tr('Повторить', 'Qayta urinish'),
                      onAction: _load),
            )
          : RefreshIndicator(onRefresh: _load, child: ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 24), children: _body(sh))),
    );
  }

  List<Widget> _body(Map<String, dynamic> sh) {
    final r = (sh['report'] as Map?)?.cast<String, dynamic>() ?? const {};
    final closed = sh['closed_at'] != null;
    final diff = n(sh['diff']);
    final cashOut = n(r['cash_out']);
    final cashIn = n(r['cash_in']);
    final salesTotal = n(r['sales_total']);
    final card = salesTotal - n(r['cash_sales']);
    String sum(num v) => money(v, suffix: false);
    final (chipText, chipTone) = !closed
        ? (tr('Смена идёт', 'Smena davom etmoqda'), ChipTone.blue)
        : diff < 0
            ? (tr('Недостача', 'Kamomad'), ChipTone.red)
            : diff > 0
                ? (tr('Излишек', 'Ortiqcha'), ChipTone.amber)
                : (tr('Сходится', 'Mos keladi'), ChipTone.green);
    return [
      AppCard(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(child: Text(tr('Наличные в кассе', 'Kassadagi naqd pul'), style: AppText.title)),
            StatusChip(chipText, icon: chipTone == ChipTone.red ? Icons.error_outline_rounded : null, tone: chipTone),
          ]),
          const SizedBox(height: 10),
          _Kv(tr('На начало смены', 'Smena boshida'), sum(n(sh['opening_cash']))),
          _Kv(tr('Продажи наличными', 'Naqd pulga sotuvlar'), '+ ${sum(n(r['cash_sales']))}'),
          if (n(r['cash_returns']) > 0) _Kv(tr('Возвраты наличными', 'Naqd pul bilan qaytarishlar'), '− ${sum(n(r['cash_returns']))}'),
          if (cashIn > 0) _Kv(tr('Внесено', 'Kiritildi'), '+ ${sum(cashIn)}'),
          if (cashOut > 0) _Kv(tr('Изъято из кассы', 'Kassadan olindi'), '− ${sum(cashOut)}'),
          const Divider(height: 20),
          _Kv(closed ? tr('Должно быть', 'Boʻlishi kerak') : tr('Должно быть сейчас', 'Hozir boʻlishi kerak'), sum(n(sh['expected_cash'] ?? r['expected_cash'])), strong: true),
          if (closed) _Kv(tr('Посчитал кассир', 'Kassir sanadi'), sum(n(sh['counted_cash'])), strong: true),
          if (closed && diff != 0) ...[
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              decoration: BoxDecoration(color: diff < 0 ? AppColors.primarySoft : AppColors.warningSoft, borderRadius: BorderRadius.circular(14)),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  Expanded(child: Text(tr('Разница', 'Farq'), style: AppText.bodyStrong.copyWith(color: diff < 0 ? AppColors.primary : AppColors.warningInk))),
                  Text('${diff < 0 ? '−' : '+'} ${money(diff.abs())}',
                      style: AppText.title.copyWith(color: diff < 0 ? AppColors.primary : AppColors.warningInk)),
                ]),
                if ('${sh['diff_reason'] ?? ''}'.isNotEmpty) Text(tr('Кассир: «${sh['diff_reason']}»', 'Kassir: «${sh['diff_reason']}»'), style: AppText.small),
              ]),
            ),
          ],
        ]),
      ),
      const SizedBox(height: 16),
      AppCard(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
        child: Column(children: [
          _Line(
              Icons.receipt_long_rounded,
              tr('Чеков', 'Cheklar'),
              n(r['sales_count']) > 0
                  ? tr('средний чек ${sum(salesTotal / n(r['sales_count']))}', 'oʻrtacha chek ${sum(salesTotal / n(r['sales_count']))}')
                  : tr('продаж не было', 'sotuv boʻlmagan'),
              '${r['sales_count'] ?? 0}'),
          _Line(Icons.payments_outlined, tr('Выручка', 'Tushum'), card > 0 ? tr('из них картой ${sum(card)}', 'shundan karta bilan ${sum(card)}') : tr('всё наличными', 'hammasi naqd pulda'),
              sum(salesTotal)),
          _Line(Icons.sell_outlined, tr('Скидки', 'Chegirmalar'), tr('сумма скидок за смену', 'smenadagi chegirmalar summasi'), sum(n(r['discounts'])),
              bg: n(r['discounts']) > 0 ? AppColors.warningSoft : null, fg: n(r['discounts']) > 0 ? AppColors.warningInk : null),
          _Line(Icons.replay_rounded, tr('Возвраты', 'Qaytarishlar'),
              '${r['returns_count'] ?? 0} ${tr(plural((r['returns_count'] as num? ?? 0).toInt(), 'возврат', 'возврата', 'возвратов'), 'ta qaytarish')}',
              sum(n(r['returns_total']))),
          _Line(Icons.cloud_off_rounded, tr('Непробитые чеки', 'Urilmagan cheklar'),
              n(r['fiscal_pending']) > 0 ? tr('ждут отправки в ОФД', 'OFDga yuborilishi kutilmoqda') : tr('все чеки отправлены в ОФД', 'barcha cheklar OFDga yuborilgan'),
              '${r['fiscal_pending'] ?? 0}',
              bg: n(r['fiscal_pending']) > 0 ? AppColors.warningSoft : AppColors.successSoft,
              fg: n(r['fiscal_pending']) > 0 ? AppColors.warningInk : AppColors.successInk),
        ]),
      ),
      if (_events.isNotEmpty) ...[
        const SizedBox(height: 16),
        AppCard(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(tr('События смены', 'Smena hodisalari'), style: AppText.title),
            const SizedBox(height: 10),
            for (final e in _events)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 5),
                child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  SizedBox(width: 48, child: Text(dateTime(e['at']).split(' ').last, style: AppText.caption)),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text('${e['title']}', style: AppText.bodyStrong.copyWith(fontWeight: FontWeight.w500, color: _eventColor(e))),
                      if ('${e['note'] ?? ''}'.isNotEmpty) Text('${e['note']}', style: AppText.small),
                    ]),
                  ),
                ]),
              ),
          ]),
        ),
      ],
    ];
  }

  Color _eventColor(Map<String, dynamic> e) {
    switch (e['kind']) {
      case 'discount':
        return AppColors.warningInk;
      case 'close':
        final a = n(e['amount']);
        return a < 0 ? AppColors.primary : (a > 0 ? AppColors.warningInk : AppColors.ink);
    }
    return AppColors.ink;
  }
}

class _Kv extends StatelessWidget {
  const _Kv(this.k, this.v, {this.strong = false});

  final String k;
  final String v;
  final bool strong;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(children: [
        Expanded(child: Text(k, style: strong ? AppText.bodyStrong : AppText.body.copyWith(color: AppColors.text2))),
        Text(v, style: AppText.bodyStrong),
      ]),
    );
  }
}

class _Line extends StatelessWidget {
  const _Line(this.icon, this.label, this.sub, this.value, {this.bg, this.fg});

  final IconData icon;
  final String label;
  final String sub;
  final String value;
  final Color? bg;
  final Color? fg;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(children: [
        IconBox(icon, bg: bg ?? AppColors.bg, fg: fg ?? AppColors.ink, size: 40, iconSize: 20, radius: 12),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(label, style: AppText.bodyStrong.copyWith(fontWeight: FontWeight.w500)),
            Text(sub, style: AppText.small, maxLines: 1, overflow: TextOverflow.ellipsis),
          ]),
        ),
        Text(value, style: AppText.bodyStrong.copyWith(color: fg == AppColors.ink ? null : fg)),
      ]),
    );
  }
}
