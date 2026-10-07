import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:sm_core/sm_core.dart';

import '../delivery_time.dart';
import '../main.dart';
import '../state.dart';
import '../ui/theme.dart';
import '../ui/widgets.dart';
import 'order_screen.dart';

/// Оплата только что оформленного заказа: ждём подтверждение от Payme/Click
/// с таймером до отмены, затем «Заказ оплачен!». Статус проверяется каждые
/// 3 секунды и сразу при возврате в приложение.
class PaymentScreen extends StatefulWidget {
  const PaymentScreen({super.key, required this.order});

  /// Заказ из ответа POST /client/orders.
  final Map<String, dynamic> order;

  @override
  State<PaymentScreen> createState() => _PaymentScreenState();
}

class _PaymentScreenState extends State<PaymentScreen> with WidgetsBindingObserver {
  late Map<String, dynamic> _o = widget.order;
  Timer? _poll;
  Timer? _tick;
  bool _busy = false;

  String get _id => _o['id'] as String;
  String get _status => _o['status'] as String;
  bool get _click => _o['payment_provider'] == 'click';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _poll = Timer.periodic(const Duration(seconds: 3), (_) {
      if (_status == 'awaiting_payment') _load();
    });
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted && _status == 'awaiting_payment') setState(() {});
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _poll?.cancel();
    _tick?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && _status == 'awaiting_payment') _load();
  }

  Future<void> _load() async {
    try {
      final o = await context.read<Api>().get('/client/orders/$_id') as Map<String, dynamic>;
      if (mounted) setState(() => _o = o);
    } catch (_) {
      // Сеть моргнула — проверим в следующий раз.
    }
  }

  Future<void> _pay() async {
    try {
      final r = await context.read<Api>().get('/client/orders/$_id/payment-url') as Map<String, dynamic>;
      await openUrl(r['payment_url'] as String);
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Future<void> _cancel() async {
    setState(() => _busy = true);
    try {
      final o = await context.read<Api>().post('/client/orders/$_id/cancel') as Map<String, dynamic>;
      if (mounted) setState(() => _o = o);
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _toOrder() => Navigator.of(context).pushReplacement(MaterialPageRoute(builder: (_) => OrderScreen(id: _id)));

  void _home() {
    context.read<AppState>().setTab(0);
    Navigator.of(context).popUntil((r) => r.isFirst);
  }

  /// «14:32» до отмены неоплаченного заказа.
  String? get _left {
    final d = _o['payment_deadline'];
    if (d == null) return null;
    final left = DateTime.parse('$d').difference(DateTime.now());
    if (left.isNegative) return '0:00';
    return '${left.inMinutes}:${(left.inSeconds % 60).toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final paid = !{'awaiting_payment', 'expired', 'cancelled'}.contains(_status);
    return Scaffold(
      backgroundColor: AppColors.white,
      body: SafeArea(
        child: Column(children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: Row(children: [
              RoundIconButton(icon: Icons.close_rounded, onTap: paid ? _home : () => Navigator.of(context).pop()),
              const SizedBox(width: 12),
              if (!paid) Text(tr('Оплата заказа', 'Buyurtma toʻlovi'), style: AppText.title),
            ]),
          ),
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
              child: paid ? _paid() : (_status == 'awaiting_payment' ? _waiting() : _failed()),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
            child: Column(children: [
              if (paid) ...[
                AppButton(label: tr('Следить за заказом', 'Buyurtmani kuzatish'), onPressed: _toOrder),
                TextButton(onPressed: _home, child: Text(tr('Вернуться на главную', 'Bosh sahifaga qaytish'))),
              ] else if (_status == 'awaiting_payment') ...[
                AppButton(label: tr('Открыть ${_click ? 'Click' : 'Payme'} ещё раз', '${_click ? 'Click' : 'Payme'} ni qayta ochish'), onPressed: _pay),
                TextButton(
                  style: TextButton.styleFrom(foregroundColor: AppColors.error),
                  onPressed: _busy ? null : _cancel,
                  child: Text(tr('Отменить заказ', 'Buyurtmani bekor qilish')),
                ),
              ] else
                AppButton(label: tr('Вернуться на главную', 'Bosh sahifaga qaytish'), onPressed: _home),
            ]),
          ),
        ]),
      ),
    );
  }

  Widget _waiting() {
    final left = _left;
    return Column(children: [
      Container(
        width: 112,
        height: 112,
        alignment: Alignment.center,
        decoration: BoxDecoration(color: _click ? const Color(0xFF0073E6) : const Color(0xFF33CCCC), borderRadius: BorderRadius.circular(28)),
        child: Text(_click ? 'click' : 'payme', style: AppText.h2.copyWith(color: AppColors.white)),
      ),
      const SizedBox(height: 20),
      const SizedBox(width: 32, height: 32, child: CircularProgressIndicator(strokeWidth: 3.5)),
      const SizedBox(height: 20),
      Text(tr('Ждём подтверждения оплаты', 'Toʻlov tasdigʻini kutyapmiz'), textAlign: TextAlign.center, style: AppText.h2),
      const SizedBox(height: 10),
      Text(
          tr('Мы открыли ${_click ? 'Click' : 'Payme'}. Подтвердите платёж и вернитесь в приложение — статус обновится сам.',
              '${_click ? 'Click' : 'Payme'} ochildi. Toʻlovni tasdiqlang va ilovaga qayting — holat oʻzi yangilanadi.'),
          textAlign: TextAlign.center, style: AppText.body.copyWith(color: AppColors.text2)),
      const SizedBox(height: 20),
      AppCard(
        color: AppColors.bg,
        child: Column(children: [
          _row(tr('Заказ', 'Buyurtma'), '№ ${_o['number']}'),
          _row(tr('Магазин', 'Doʻkon'), '${_o['store_name']}'),
          if (windowLabel(_o['delivery_from'], _o['delivery_to']) case final w?) _row(tr('Доставка', 'Yetkazish'), w),
          _row(tr('К оплате', 'Toʻlov uchun'), money(_o['total']), bold: true),
        ]),
      ),
      if (left != null) ...[
        const SizedBox(height: 16),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(color: AppColors.accentSoft, borderRadius: BorderRadius.circular(AppRadius.md)),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            const Icon(Icons.schedule_rounded, size: 16, color: AppColors.warningInk),
            const SizedBox(width: 6),
            Text(tr('Заказ отменится, если не оплатить за $left', '$left ichida toʻlanmasa, buyurtma bekor qilinadi'), style: AppText.small.copyWith(color: AppColors.warningInk, fontWeight: FontWeight.w500)),
          ]),
        ),
      ],
    ]);
  }

  Widget _paid() {
    final store = context.read<AppState>().stores.where((s) => s.id == _o['store_id']).firstOrNull;
    final window = windowLabel(_o['delivery_from'], _o['delivery_to']);
    String when;
    if (window != null) {
      when = tr('Привезём $window', '$window yetkazamiz');
    } else if (store?.etaMax != null) {
      final paidAt = DateTime.tryParse('${_o['paid_at']}') ?? DateTime.now();
      final at = hhmm(paidAt.add(Duration(minutes: store!.etaMax!)));
      when = tr('Привезём к $at', 'Soat $at gacha yetkazamiz');
    } else {
      when = tr('Привезём как можно скорее', 'Imkon qadar tez yetkazamiz');
    }
    final address = '${_o['address']}${'${_o['apartment'] ?? ''}'.isNotEmpty ? tr(', кв. ${_o['apartment']}', ', ${_o['apartment']}-xonadon') : ''}';
    return Column(children: [
      const SizedBox(height: 40),
      Container(
        width: 140,
        height: 140,
        decoration: const BoxDecoration(color: AppColors.successSoft, shape: BoxShape.circle),
        alignment: Alignment.center,
        child: Container(
          width: 92,
          height: 92,
          decoration: const BoxDecoration(color: AppColors.success, shape: BoxShape.circle),
          child: const Icon(Icons.check_rounded, color: AppColors.white, size: 48),
        ),
      ),
      const SizedBox(height: 28),
      Text(tr('Заказ оплачен!', 'Buyurtma toʻlandi!'), style: AppText.h1),
      const SizedBox(height: 10),
      Text(
          tr('Заказ № ${_o['number']} передан в ${_o['store_name']}. Магазин скоро начнёт собирать ваши продукты.',
              'Buyurtma № ${_o['number']} ${_o['store_name']} doʻkoniga yuborildi. Doʻkon tez orada mahsulotlaringizni yigʻishni boshlaydi.'),
          textAlign: TextAlign.center, style: AppText.body.copyWith(color: AppColors.text2)),
      const SizedBox(height: 24),
      AppCard(
        color: AppColors.primarySoft,
        child: Row(children: [
          const IconBox(Icons.schedule_rounded, bg: AppColors.white, fg: AppColors.ink, size: 44),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(when, style: AppText.bodyStrong),
              Text(address, maxLines: 2, overflow: TextOverflow.ellipsis, style: AppText.small),
            ]),
          ),
        ]),
      ),
    ]);
  }

  Widget _failed() {
    final expired = _status == 'expired';
    return Column(children: [
      const SizedBox(height: 60),
      const IconBox(Icons.close_rounded, size: 96, bg: AppColors.soft, fg: AppColors.text2),
      const SizedBox(height: 24),
      Text(expired ? tr('Время на оплату истекло', 'Toʻlov vaqti tugadi') : tr('Заказ отменён', 'Buyurtma bekor qilindi'), style: AppText.h2, textAlign: TextAlign.center),
      const SizedBox(height: 10),
      Text(
          expired
              ? tr('Заказ отменён, товары вернулись в магазин. Можно оформить заново.', 'Buyurtma bekor qilindi, mahsulotlar doʻkonga qaytdi. Qaytadan rasmiylashtirish mumkin.')
              : tr('Если деньги успели списаться, они вернутся на карту.', 'Agar pul yechib olingan boʻlsa, u kartaga qaytariladi.'),
          textAlign: TextAlign.center, style: AppText.body.copyWith(color: AppColors.text2)),
    ]);
  }

  Widget _row(String label, String value, {bool bold = false}) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(children: [
          Expanded(child: Text(label, style: AppText.small.copyWith(fontSize: 14))),
          Text(value, style: bold ? AppText.bodyStrong.copyWith(fontSize: 17) : AppText.bodyMedium),
        ]),
      );
}
