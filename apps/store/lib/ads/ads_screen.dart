import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:sm_core/sm_core.dart';

import '../finance/finance_logic.dart';
import '../main.dart';
import '../ui/theme.dart';
import '../ui/widgets.dart';

/// Реклама брендов: доля сети с рекламы, бренды в магазинах, скрыть бренд.
class AdsScreen extends StatefulWidget {
  const AdsScreen({super.key});

  @override
  State<AdsScreen> createState() => _AdsScreenState();
}

class _AdsScreenState extends State<AdsScreen> {
  Map<String, dynamic>? _d;
  Object? _error;
  String? _saving;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final d = await context.read<Api>().get('/store/ads') as Map<String, dynamic>;
      if (!mounted) return;
      setState(() {
        _d = d;
        _error = null;
      });
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  Set<String> get _hidden => {for (final b in ((_d?['hidden_brands'] as List?) ?? const [])) '${(b as Map)['id']}'};

  Future<void> _toggle(Map<String, dynamic> c, bool show) async {
    final brand = '${c['brand_id']}';
    final next = {..._hidden};
    if (show) {
      next.remove(brand);
    } else {
      next.add(brand);
    }
    setState(() => _saving = brand);
    final api = context.read<Api>();
    try {
      final d = await api.put('/store/ads', {'hidden_brands': next.toList()}) as Map<String, dynamic>;
      if (!mounted) return;
      setState(() => _d = d);
      showMessage(context, show ? '${c['brand_name']}: реклама снова показывается' : '${c['brand_name']} скрыт в ваших магазинах');
    } catch (e) {
      if (mounted) showMessage(context, e);
    } finally {
      if (mounted) setState(() => _saving = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final d = _d;
    return Scaffold(
      appBar: AppBar(title: const Text('Реклама брендов')),
      body: d == null
          ? Center(
              child: _error == null
                  ? const CircularProgressIndicator()
                  : EmptyState(icon: Icons.wifi_off_rounded, title: 'Не удалось загрузить', text: '$_error', action: 'Повторить', onAction: _load),
            )
          : RefreshIndicator(onRefresh: _load, child: ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 24), children: _body(d))),
    );
  }

  List<Widget> _body(Map<String, dynamic> d) {
    final campaigns = ((d['campaigns'] as List?) ?? const []).cast<Map<String, dynamic>>();
    final hidden = _hidden;
    final canHide = d['allow_hide_brands'] == true;
    final pct = n(d['share_pct']);
    return [
      const Text('Бренды платят Super Market за показ своих товаров. Покупатель видит товар в вашем магазине и покупает у вас.', style: AppText.small),
      const SizedBox(height: 12),
      AppCard(
        color: AppColors.primary,
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Ваша доля за месяц', style: AppText.small.copyWith(color: AppColors.white)),
          Text(money(d['month_share']), style: AppText.h1.copyWith(fontSize: 30, color: AppColors.white)),
          Text(
            '${pct == pct.roundToDouble() ? pct.toInt() : pct}% от рекламы в ваших магазинах'
            '${d['share_to_subscription'] == true ? ' — зачтём в счёт за подписку' : ' — на баланс'}',
            style: AppText.small.copyWith(color: AppColors.white),
          ),
        ]),
      ),
      const SizedBox(height: 10),
      Row(children: [
        Expanded(child: _Kpi('Продажи из рекламы', money(d['month_sales']), '${d['month_orders'] ?? 0} заказов')),
        const SizedBox(width: 10),
        Expanded(child: _Kpi('Показы', '${d['month_views'] ?? 0}', 'за месяц')),
      ]),
      const SizedBox(height: 20),
      const Text('Сейчас в ваших магазинах', style: AppText.h3),
      const SizedBox(height: 4),
      Text(
        canHide ? 'Выключите бренд — его реклама пропадёт у вас, доля с него не начисляется.' : 'Скрывать бренды сейчас нельзя — правило Super Market.',
        style: AppText.small,
      ),
      const SizedBox(height: 10),
      if (campaigns.isEmpty)
        const AppCard(child: Text('Сейчас рекламы брендов нет', style: AppText.small))
      else
        AppCard(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
          child: Column(children: [
            for (final c in campaigns)
              SwitchListTile(
                value: !hidden.contains('${c['brand_id']}'),
                onChanged: canHide && _saving == null ? (v) => _toggle(c, v) : null,
                title: Text(
                  '${c['brand_name']}',
                  style: AppText.bodyStrong.copyWith(color: hidden.contains('${c['brand_id']}') ? AppColors.muted : AppColors.ink),
                ),
                subtitle: Text(
                  hidden.contains('${c['brand_id']}')
                      ? 'Скрыт · доля не начисляется'
                      : '${c['title'] ?? ''} · ${c['views'] ?? 0} показов · ${money(c['sales'])}',
                  style: AppText.small,
                ),
              ),
          ]),
        ),
      const SizedBox(height: 12),
      const Text('Сколько рекламы на главной и скрытые категории — в панели магазина.', style: AppText.small, textAlign: TextAlign.center),
    ];
  }
}

class _Kpi extends StatelessWidget {
  const _Kpi(this.label, this.value, this.note);

  final String label;
  final String value;
  final String note;

  @override
  Widget build(BuildContext context) {
    return AppCard(
      padding: const EdgeInsets.all(14),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(label, style: AppText.small.copyWith(fontSize: 12)),
        Text(value, style: AppText.title),
        Text(note, style: AppText.small.copyWith(fontSize: 12)),
      ]),
    );
  }
}
