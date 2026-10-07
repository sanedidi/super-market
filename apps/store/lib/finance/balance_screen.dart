import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:sm_core/sm_core.dart';

import '../main.dart';
import '../ui/theme.dart';
import '../ui/widgets.dart';
import 'finance_logic.dart';

/// На iOS подписка только для просмотра (Apple 3.1.1): без оплаты счетов и без
/// текста о том, где и как платить. Вывод денег магазина — на обеих платформах.
bool get subscriptionReadOnly => defaultTargetPlatform == TargetPlatform.iOS;

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
      title: tr('Оплатить счёт с баланса?', 'Hisob-varaq balansdan toʻlansinmi?'),
      text: tr('Счёт за ${inv['period']} — ${money(inv['amount_uzs'])}. Сумма спишется с баланса к выводу.',
          '${inv['period']} uchun hisob-varaq — ${money(inv['amount_uzs'])}. Summa yechib olish mumkin boʻlgan balansdan yechiladi.'),
      confirm: tr('Оплатить', 'Toʻlash'),
    );
    if (!ok || !mounted) return;
    setState(() => _paying = inv['id'] as String);
    try {
      await context.read<Api>().post('/store/billing/invoices/${inv['id']}/pay');
      if (!mounted) return;
      showMessage(context, tr('Счёт оплачен', 'Hisob-varaq toʻlandi'));
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
      appBar: AppBar(title: Text(tr('Баланс и подписка', 'Balans va obuna'))),
      body: b == null || bill == null
          ? Center(
              child: _error == null
                  ? const CircularProgressIndicator()
                  : EmptyState(icon: Icons.wifi_off_rounded, title: tr('Не удалось загрузить', 'Yuklab boʻlmadi'), text: '$_error', action: tr('Повторить', 'Qayta urinish'), onAction: _load),
            )
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 24), children: [
                AppCard(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(tr('К выводу', 'Yechish mumkin'), style: AppText.small),
                    Text(money(b['available']), style: AppText.h1.copyWith(fontSize: 30)),
                    const SizedBox(height: 4),
                    Text(tr('Ждёт доставки: ${money(b['pending'])}', 'Yetkazilishini kutmoqda: ${money(b['pending'])}'), style: AppText.small),
                    const SizedBox(height: 14),
                    if (b['next_payout_at'] != null)
                      Text(
                          tr('Следующий вывод можно запросить ${dateTime(b['next_payout_at'])}',
                              'Keyingi yechib olishni ${dateTime(b['next_payout_at'])} dan soʻrash mumkin'),
                          style: AppText.small)
                    else
                      BigButton(
                        label: tr('Вывести деньги', 'Pulni yechib olish'),
                        icon: Icons.account_balance_rounded,
                        height: 48,
                        onPressed: n(b['available']) > 0 ? _requestPayout : null,
                      ),
                  ]),
                ),
                const SizedBox(height: 16),
                if (subscriptionReadOnly)
                  SubscriptionInfoCard(bill: bill)
                else ...[
                  Text(tr('Подписка', 'Obuna'), style: AppText.h3),
                  const SizedBox(height: 10),
                  AppCard(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Row(children: [
                        Expanded(
                            child: Text(tr('\$${money(bill['monthly_usd'], suffix: false)} в месяц', 'Oyiga \$${money(bill['monthly_usd'], suffix: false)}'),
                                style: AppText.title)),
                        StatusChip(
                          billingStatus(bill),
                          tone: bill['overdue'] == true ? ChipTone.red : (n(bill['unpaid_uzs']) > 0 ? ChipTone.amber : ChipTone.green),
                        ),
                      ]),
                      const SizedBox(height: 6),
                      Text('${tr('Магазинов', 'Doʻkonlar')}: ${bill['stores_count'] ?? 0} × \$${money(bill['price_per_store'], suffix: false)}', style: AppText.small),
                      if (n(bill['unpaid_uzs']) > 0) Text('${tr('К оплате', 'Toʻlash kerak')}: ${money(bill['unpaid_uzs'])}', style: AppText.bodyStrong),
                    ]),
                  ),
                ],
                if (!subscriptionReadOnly)
                  for (final inv in _invoices) ...[
                    const SizedBox(height: 10),
                    AppCard(
                      border: inv['overdue'] == true ? AppColors.primary : null,
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Row(children: [
                          Expanded(child: Text(tr('Счёт за ${inv['period']}', '${inv['period']} uchun hisob-varaq'), style: AppText.bodyStrong)),
                          Text(money(inv['amount_uzs']), style: AppText.bodyStrong),
                        ]),
                        Text(
                          inv['overdue'] == true
                              ? tr('Просрочен · срок был ${inv['due_date']}', 'Muddati oʻtgan · muddat ${inv['due_date']} edi')
                              : tr('Оплатить до ${inv['due_date']}', '${inv['due_date']} gacha toʻlang'),
                          style: AppText.small.copyWith(color: inv['overdue'] == true ? AppColors.primary : AppColors.text2),
                        ),
                        const SizedBox(height: 10),
                        BigButton(
                          label: tr('Оплатить с баланса', 'Balansdan toʻlash'),
                          height: 44,
                          busy: _paying == inv['id'],
                          onPressed: _paying == null && n(b['available']) >= n(inv['amount_uzs']) ? () => _pay(inv) : null,
                        ),
                        if (n(b['available']) < n(inv['amount_uzs']))
                          Padding(
                            padding: const EdgeInsets.only(top: 6),
                            child: Text(
                                tr('На балансе не хватает — оплатите счёт другим способом, реквизиты у администратора платформы.',
                                    'Balansda yetarli emas — hisob-varaqni boshqa usulda toʻlang, rekvizitlar platforma administratorida.'),
                                style: AppText.small),
                          ),
                      ]),
                    ),
                  ],
                if (_payouts.isNotEmpty) ...[
                  const SizedBox(height: 20),
                  Text(tr('Заявки на вывод', 'Yechib olish soʻrovlari'), style: AppText.h3),
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
                              switch (p['status']) {
                                'paid' => tr('Выплачено', 'Toʻlab berildi'),
                                'rejected' => tr('Отклонено', 'Rad etildi'),
                                _ => tr('На рассмотрении', 'Koʻrib chiqilmoqda'),
                              },
                              tone: switch (p['status']) { 'paid' => ChipTone.green, 'rejected' => ChipTone.red, _ => ChipTone.amber },
                            ),
                          ]),
                        ),
                    ]),
                  ),
                ],
                if (_entries.isNotEmpty) ...[
                  const SizedBox(height: 20),
                  Text(tr('Движения баланса', 'Balans harakati'), style: AppText.h3),
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
                                  e['order_number'] != null ? '${tr('Заказ', 'Buyurtma')} № ${e['order_number']}' : balanceKindTitle(e['kind'] as String?),
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

/// Подписка на iOS (Figma М11а): тариф, число магазинов, «Оплачено до» и статус —
/// только просмотр, без цен, кнопок оплаты и текста о способах оплаты (Apple 3.1.1).
class SubscriptionInfoCard extends StatelessWidget {
  const SubscriptionInfoCard({super.key, required this.bill, this.today});

  final Map<String, dynamic> bill;

  /// Для тестов; по умолчанию — сегодня.
  final DateTime? today;

  @override
  Widget build(BuildContext context) {
    final tariff = '${bill['tariff_name'] ?? ''}'.trim();
    final paidUntil = subscriptionPaidUntil(bill, today ?? DateTime.now());
    return AppCard(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(child: Text(tr('Подписка', 'Obuna'), style: AppText.title)),
          StatusChip(
            billingStatus(bill),
            icon: bill['overdue'] != true && n(bill['unpaid_uzs']) <= 0 ? Icons.check_circle_rounded : null,
            tone: bill['overdue'] == true ? ChipTone.red : (n(bill['unpaid_uzs']) > 0 ? ChipTone.amber : ChipTone.green),
          ),
        ]),
        const SizedBox(height: 8),
        if (tariff.isNotEmpty) _row(tr('Тариф', 'Tarif'), tariff),
        _row(tr('Магазинов', 'Doʻkonlar'), '${bill['stores_count'] ?? 0}'),
        if (paidUntil != null) _row(tr('Оплачено до', 'Toʻlangan muddat'), ruDate(paidUntil)),
      ]),
    );
  }

  Widget _row(String label, String value) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(children: [
          Text(label, style: AppText.body.copyWith(color: AppColors.text2)),
          const SizedBox(width: 12),
          Expanded(child: Text(value, style: AppText.bodyStrong, textAlign: TextAlign.right)),
        ]),
      );
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
      err = tr('Введите сумму больше нуля', 'Noldan katta summani kiriting');
    } else if (v > n(widget.available)) {
      err = tr('Больше, чем доступно к выводу', 'Yechish mumkin boʻlgan summadan koʻp');
    } else if (_requisites.text.trim().isEmpty) {
      err = tr('Укажите реквизиты: счёт или карту для перевода', 'Rekvizitlarni kiriting: oʻtkazma uchun hisob raqami yoki karta');
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
      messenger.showSnackBar(SnackBar(content: Text(tr('Заявка на вывод отправлена', 'Yechib olish soʻrovi yuborildi'))));
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
          Text(tr('Вывести деньги', 'Pulni yechib olish'), style: AppText.h3),
          const SizedBox(height: 4),
          Text(tr('Доступно ${money(widget.available)}. Вывод — раз в 7 дней.', 'Mavjud: ${money(widget.available)}. Yechib olish — 7 kunda bir marta.'),
              style: AppText.small),
          const SizedBox(height: 16),
          TextField(
            controller: _amount,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.,\s]'))],
            style: AppText.h2,
            decoration: InputDecoration(labelText: tr('Сумма', 'Summa'), suffixText: tr('сум', 'soʻm')),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _requisites,
            maxLines: 2,
            decoration: InputDecoration(labelText: tr('Реквизиты (счёт, МФО или карта)', 'Rekvizitlar (hisob raqami, MFO yoki karta)'), errorText: _error),
          ),
          const SizedBox(height: 20),
          BigButton(label: tr('Отправить заявку', 'Soʻrov yuborish'), icon: Icons.send_rounded, busy: _busy, onPressed: _submit),
        ]),
      ),
    );
  }
}
