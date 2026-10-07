import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:sm_core/sm_core.dart' hide LoginScreen;

import '../logic.dart';
import '../ui/theme.dart';
import '../ui/widgets.dart';
import 'crowd_logic.dart';
import 'crowd_state.dart';

/// Заработок курьера «по пути»: баланс к выплате и журнал (Figma Ц6).
class EarningsScreen extends StatefulWidget {
  const EarningsScreen({super.key});

  @override
  State<EarningsScreen> createState() => _EarningsScreenState();
}

class _EarningsScreenState extends State<EarningsScreen> {
  Map<String, dynamic>? _data;
  Object? _error;
  int? _lastDelivered;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    try {
      final d = await context.read<CrowdState>().earnings();
      if (mounted) {
        setState(() {
          _data = d;
          _error = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  @override
  Widget build(BuildContext context) {
    // Вручили заказ — обновить журнал.
    final delivered = context.select<CrowdState, int>((s) => ((s.me?['stats'] as Map?)?['delivered'] as num?)?.toInt() ?? 0);
    if (_lastDelivered != null && delivered != _lastDelivered) WidgetsBinding.instance.addPostFrameCallback((_) => _load());
    _lastDelivered = delivered;
    final d = _data;
    final items = ((d?['items'] as List?) ?? const []).whereType<Map>().map((m) => m.cast<String, dynamic>()).toList();
    final top = MediaQuery.paddingOf(context).top;
    final payout = DateTime.tryParse('${d?['next_payout_on'] ?? ''}');
    return Scaffold(
      backgroundColor: AppColors.bg,
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(padding: EdgeInsets.fromLTRB(20, top + 12, 20, 24), children: [
          Text(tr('Заработок', 'Daromad'), style: AppText.h1),
          const SizedBox(height: 16),
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
            Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(color: AppColors.ink, borderRadius: BorderRadius.circular(24)),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(tr('К выплате', 'Toʻlanadi'), style: AppText.small.copyWith(color: const Color(0xFFD1D1D6), fontSize: 14)),
                const SizedBox(height: 4),
                Text(money(d['balance']), style: AppText.h1.copyWith(color: AppColors.white, fontSize: 34)),
                const SizedBox(height: 8),
                Row(children: [
                  const Icon(Icons.event_rounded, size: 18, color: Color(0xFFD1D1D6)),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      payout == null
                          ? tr('Выплата раз в неделю', 'Haftada bir marta toʻlanadi')
                          : tr('Выплата в понедельник, ${payout.day} ${_month(payout.month)}', 'Toʻlov dushanba, ${payout.day}-${_monthUz(payout.month)}'),
                      style: AppText.small.copyWith(color: const Color(0xFFD1D1D6)),
                    ),
                  ),
                ]),
              ]),
            ),
            const SizedBox(height: 14),
            Row(children: [
              _Stat(icon: Icons.local_shipping_rounded, fg: AppColors.primary, bg: AppColors.primarySoft, value: '${d['week_delivered'] ?? 0}', label: tr('доставок за неделю', 'haftalik yetkazish')),
              const SizedBox(width: 12),
              _Stat(
                icon: Icons.timer_rounded,
                fg: AppColors.blue,
                bg: AppColors.blueSoft,
                value: (d['avg_minutes'] as num? ?? 0) > 0 ? tr('${d['avg_minutes']} мин', '${d['avg_minutes']} daq.') : '—',
                label: tr('в пути в среднем', 'oʻrtacha yoʻlda'),
              ),
            ]),
            const SizedBox(height: 18),
            Text(tr('Движения', 'Operatsiyalar'), style: AppText.title),
            const SizedBox(height: 10),
            if (items.isEmpty)
              EmptyState(
                icon: Icons.receipt_long_rounded,
                title: tr('Пока пусто', 'Hozircha boʻsh'),
                text: tr('Здесь будут начисления за доставки и выплаты', 'Yetkazish uchun hisoblangan haqlar va toʻlovlar shu yerda chiqadi'),
              )
            else
              Container(
                decoration: BoxDecoration(color: AppColors.white, borderRadius: BorderRadius.circular(20)),
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                child: Column(children: [
                  for (var i = 0; i < items.length; i++) _Row(items[i], last: i == items.length - 1),
                ]),
              ),
          ],
        ]),
      ),
    );
  }

  static String _month(int m) =>
      const ['января', 'февраля', 'марта', 'апреля', 'мая', 'июня', 'июля', 'августа', 'сентября', 'октября', 'ноября', 'декабря'][m - 1];

  static String _monthUz(int m) =>
      const ['yanvar', 'fevral', 'mart', 'aprel', 'may', 'iyun', 'iyul', 'avgust', 'sentyabr', 'oktyabr', 'noyabr', 'dekabr'][m - 1];
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
          FittedBox(fit: BoxFit.scaleDown, alignment: Alignment.centerLeft, child: Text(value, style: AppText.title.copyWith(fontSize: 22))),
          Text(label, style: AppText.small.copyWith(fontSize: 12), maxLines: 2),
        ]),
      ),
    );
  }
}

class _Row extends StatelessWidget {
  const _Row(this.e, {required this.last});
  final Map<String, dynamic> e;
  final bool last;

  @override
  Widget build(BuildContext context) {
    final amount = num.tryParse('${e['amount']}') ?? 0;
    final plus = amount > 0;
    final t = DateTime.tryParse('${e['created_at'] ?? ''}')?.toLocal();
    final kind = '${e['kind']}';
    final icon = switch (kind) {
      'payout' => Icons.account_balance_rounded,
      'penalty' => Icons.remove_circle_rounded,
      'wait_bonus' || 'adjustment' => Icons.add_circle_rounded,
      _ => Icons.check_circle_rounded,
    };
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 12),
      decoration: BoxDecoration(border: last ? null : const Border(bottom: BorderSide(color: AppColors.line))),
      child: Row(children: [
        Container(
          width: 36,
          height: 36,
          decoration: BoxDecoration(color: plus ? AppColors.successSoft : AppColors.soft, borderRadius: BorderRadius.circular(12)),
          child: Icon(icon, size: 20, color: plus ? AppColors.success : AppColors.ink),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(ledgerTitle(e), style: AppText.bodyStrong),
            if (t != null) Text('${t.day.toString().padLeft(2, '0')}.${t.month.toString().padLeft(2, '0')} ${hm(t)}', style: AppText.small),
          ]),
        ),
        Text('${plus ? '+' : '−'}${money(amount.abs(), suffix: false)}',
            style: AppText.bodyStrong.copyWith(color: plus ? AppColors.successInk : AppColors.ink)),
      ]),
    );
  }
}
