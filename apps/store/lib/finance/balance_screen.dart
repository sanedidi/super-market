import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:sm_core/sm_core.dart';

import '../main.dart';
import '../ui/theme.dart';
import '../ui/widgets.dart';
import 'finance_logic.dart';

/// Баланс сети на платформе (деньги онлайн-заказов), вывод и подписка.
class BalanceScreen extends StatefulWidget {
  const BalanceScreen({super.key});

  @override
  State<BalanceScreen> createState() => _BalanceScreenState();
}

class _BalanceScreenState extends State<BalanceScreen> {
  Map<String, dynamic>? _balance;
  Map<String, dynamic>? _billing;
  List<Map<String, dynamic>> _invoices = const [];
  List<Map<String, dynamic>> _payouts = const [];
  List<Map<String, dynamic>> _entries = const [];
  Object? _error;
  String? _paying;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final api = context.read<Api>();
    try {
      final res = await Future.wait<Object?>([
        api.get('/store/balance'),
        api.get('/store/billing'),
        api.list('/store/billing/invoices', {'status': 'unpaid'}),
        api.list('/store/payouts', {'limit': 5}),
        api.list('/store/balance/entries', {'limit': 20}),
      ]);
      if (!mounted) return;
      setState(() {
        _balance = res[0] as Map<String, dynamic>;
        _billing = res[1] as Map<String, dynamic>;
        _invoices = res[2] as List<Map<String, dynamic>>;
        _payouts = res[3] as List<Map<String, dynamic>>;
        _entries = res[4] as List<Map<String, dynamic>>;
        _error = null;
      });
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  Future<void> _pay(Map<String, dynamic> inv) async {
    final ok = await confirmSheet(
      context,
      title: 'Оплатить счёт с баланса?',
      text: 'Счёт за ${inv['period']} — ${money(inv['amount_uzs'])}. Сумма спишется с баланса к выводу.',
      confirm: 'Оплатить',
    );
    if (!ok || !mounted) return;
    setState(() => _paying = inv['id'] as String);
    try {
      await context.read<Api>().post('/store/billing/invoices/${inv['id']}/pay');
      if (!mounted) return;
      showMessage(context, 'Счёт оплачен');
      await _load();
    } catch (e) {
      if (mounted) showMessage(context, e);
    } finally {
      if (mounted) setState(() => _paying = null);
    }
  }

  Future<void> _requestPayout() async {
    final done = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      backgroundColor: AppColors.white,
      builder: (_) => _PayoutSheet(available: _balance?['available']),
    );
    if (done == true) await _load();
  }

  @override
  Widget build(BuildContext context) {
    final b = _balance;
    final bill = _billing;
    return Scaffold(
      appBar: AppBar(title: const Text('Баланс и подписка')),
      body: b == null || bill == null
          ? Center(
              child: _error == null
                  ? const CircularProgressIndicator()
                  : EmptyState(icon: Icons.wifi_off_rounded, title: 'Не удалось загрузить', text: '$_error', action: 'Повторить', onAction: _load),
            )
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 24), children: [
                AppCard(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    const Text('К выводу', style: AppText.small),
                    Text(money(b['available']), style: AppText.h1.copyWith(fontSize: 30)),
                    const SizedBox(height: 4),
                    Text('Ждёт доставки: ${money(b['pending'])}', style: AppText.small),
                    const SizedBox(height: 14),
                    if (b['next_payout_at'] != null)
                      Text('Следующий вывод можно запросить ${dateTime(b['next_payout_at'])}', style: AppText.small)
                    else
                      BigButton(
                        label: 'Вывести деньги',
                        icon: Icons.account_balance_rounded,
                        height: 48,
                        onPressed: n(b['available']) > 0 ? _requestPayout : null,
                      ),
                  ]),
                ),
                const SizedBox(height: 16),
                const Text('Подписка', style: AppText.h3),
                const SizedBox(height: 10),
                AppCard(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Row(children: [
                      Expanded(child: Text('\$${money(bill['monthly_usd'], suffix: false)} в месяц', style: AppText.title)),
                      StatusChip(
                        billingStatus(bill),
                        tone: bill['overdue'] == true ? ChipTone.red : (n(bill['unpaid_uzs']) > 0 ? ChipTone.amber : ChipTone.green),
                      ),
                    ]),
                    const SizedBox(height: 6),
                    Text('Магазинов: ${bill['stores_count'] ?? 0} × \$${money(bill['price_per_store'], suffix: false)}', style: AppText.small),
                    if (n(bill['unpaid_uzs']) > 0) Text('К оплате: ${money(bill['unpaid_uzs'])}', style: AppText.bodyStrong),
                  ]),
                ),
                for (final inv in _invoices) ...[
                  const SizedBox(height: 10),
                  AppCard(
                    border: inv['overdue'] == true ? AppColors.primary : null,
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Row(children: [
                        Expanded(child: Text('Счёт за ${inv['period']}', style: AppText.bodyStrong)),
                        Text(money(inv['amount_uzs']), style: AppText.bodyStrong),
                      ]),
                      Text(
                        inv['overdue'] == true ? 'Просрочен · срок был ${inv['due_date']}' : 'Оплатить до ${inv['due_date']}',
                        style: AppText.small.copyWith(color: inv['overdue'] == true ? AppColors.primary : AppColors.text2),
                      ),
                      const SizedBox(height: 10),
                      BigButton(
                        label: 'Оплатить с баланса',
                        height: 44,
                        busy: _paying == inv['id'],
                        onPressed: _paying == null && n(b['available']) >= n(inv['amount_uzs']) ? () => _pay(inv) : null,
                      ),
                      if (n(b['available']) < n(inv['amount_uzs']))
                        const Padding(
                          padding: EdgeInsets.only(top: 6),
                          child: Text('На балансе не хватает — оплатите счёт другим способом, реквизиты у администратора платформы.', style: AppText.small),
                        ),
                    ]),
                  ),
                ],
                if (_payouts.isNotEmpty) ...[
                  const SizedBox(height: 20),
                  const Text('Заявки на вывод', style: AppText.h3),
                  const SizedBox(height: 10),
                  AppCard(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                    child: Column(children: [
                      for (final p in _payouts)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 6),
                          child: Row(children: [
                            Expanded(
                              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                                Text('№ ${p['number']} · ${money(p['amount'])}', style: AppText.bodyStrong),
                                Text(dateTime(p['created_at']), style: AppText.small),
                              ]),
                            ),
                            StatusChip(
                              switch (p['status']) { 'paid' => 'Выплачено', 'rejected' => 'Отклонено', _ => 'На рассмотрении' },
                              tone: switch (p['status']) { 'paid' => ChipTone.green, 'rejected' => ChipTone.red, _ => ChipTone.amber },
                            ),
                          ]),
                        ),
                    ]),
                  ),
                ],
                if (_entries.isNotEmpty) ...[
                  const SizedBox(height: 20),
                  const Text('Движения баланса', style: AppText.h3),
                  const SizedBox(height: 10),
                  AppCard(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                    child: Column(children: [
                      for (final e in _entries)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 6),
                          child: Row(children: [
                            Expanded(
                              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                                Text(
                                  e['order_number'] != null ? 'Заказ № ${e['order_number']}' : balanceKindTitle(e['kind'] as String?),
                                  style: AppText.body,
                                ),
                                Text(dateTime(e['created_at']), style: AppText.small),
                              ]),
                            ),
                            Text(
                              n(e['amount']) > 0 ? '+${money(e['amount'])}' : money(e['amount']),
                              style: AppText.bodyStrong.copyWith(color: n(e['amount']) > 0 ? AppColors.successInk : AppColors.ink),
                            ),
                          ]),
                        ),
                    ]),
                  ),
                ],
              ]),
            ),
    );
  }
}

class _PayoutSheet extends StatefulWidget {
  const _PayoutSheet({required this.available});

  final Object? available;

  @override
  State<_PayoutSheet> createState() => _PayoutSheetState();
}

class _PayoutSheetState extends State<_PayoutSheet> {
  late final TextEditingController _amount = TextEditingController(text: money(widget.available, suffix: false));
  final _requisites = TextEditingController();
  String? _error;
  bool _busy = false;

  @override
  void dispose() {
    _amount.dispose();
    _requisites.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final v = num.tryParse(plainAmount(_amount.text));
    String? err;
    if (v == null || v <= 0) {
      err = 'Введите сумму больше нуля';
    } else if (v > n(widget.available)) {
      err = 'Больше, чем доступно к выводу';
    } else if (_requisites.text.trim().isEmpty) {
      err = 'Укажите реквизиты: счёт или карту для перевода';
    }
    if (err != null) {
      setState(() => _error = err);
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    final api = context.read<Api>();
    try {
      await api.post('/store/payouts', {'amount': plainAmount(_amount.text), 'requisites': _requisites.text.trim(), 'note': ''});
      if (!mounted) return;
      final messenger = ScaffoldMessenger.of(context);
      Navigator.of(context).pop(true);
      messenger.showSnackBar(const SnackBar(content: Text('Заявка на вывод отправлена')));
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(16, 0, 16, 16 + MediaQuery.of(context).viewInsets.bottom),
      child: SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('Вывести деньги', style: AppText.h3),
          const SizedBox(height: 4),
          Text('Доступно ${money(widget.available)}. Вывод — раз в 7 дней.', style: AppText.small),
          const SizedBox(height: 16),
          TextField(
            controller: _amount,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.,\s]'))],
            style: AppText.h2,
            decoration: const InputDecoration(labelText: 'Сумма', suffixText: 'сум'),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _requisites,
            maxLines: 2,
            decoration: InputDecoration(labelText: 'Реквизиты (счёт, МФО или карта)', errorText: _error),
          ),
          const SizedBox(height: 20),
          BigButton(label: 'Отправить заявку', icon: Icons.send_rounded, busy: _busy, onPressed: _submit),
        ]),
      ),
    );
  }
}
