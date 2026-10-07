import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:sm_core/sm_core.dart' hide LoginScreen;

import '../main.dart';
import '../ui/theme.dart';
import '../ui/widgets.dart';
import 'crowd_logic.dart';
import 'crowd_state.dart';

/// Заказ курьера «по пути»: QR выдачи в магазине (Figma Ц4) и вручение по
/// коду покупателя (Ц5).
class CrowdOrderScreen extends StatefulWidget {
  const CrowdOrderScreen({super.key, required this.orderId});
  final String orderId;

  @override
  State<CrowdOrderScreen> createState() => _CrowdOrderScreenState();
}

class _CrowdOrderScreenState extends State<CrowdOrderScreen> {
  Map<String, dynamic>? _c;
  Object? _error;
  bool _busy = false;
  String? _codeError;
  final _code = TextEditingController();
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
    // Пока ждём выдачу — обновляем: продавец отсканирует QR, и экран сам перейдёт к «везу».
    _timer = Timer.periodic(const Duration(seconds: 5), (_) {
      if ('${_order['status']}' == 'picked') _load();
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    _code.dispose();
    super.dispose();
  }

  Map<String, dynamic> get _order => (_c?['order'] as Map?)?.cast<String, dynamic>() ?? const {};
  Map<String, dynamic> get _store => (_c?['store'] as Map?)?.cast<String, dynamic>() ?? const {};

  Future<void> _load() async {
    try {
      final c = await context.read<CrowdState>().order(widget.orderId);
      if (!mounted) return;
      setState(() {
        _c = c;
        _error = null;
      });
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  Future<void> _release() async {
    final ok = await confirmSheet(
      context,
      title: tr('Отказаться от заказа?', 'Buyurtmadan voz kechasizmi?'),
      text: tr('Заказ вернётся в ленту, его возьмёт другой курьер.', 'Buyurtma lentaga qaytadi, uni boshqa kuryer oladi.'),
      confirm: tr('Отказаться', 'Voz kechish'),
    );
    if (!ok || !mounted) return;
    setState(() => _busy = true);
    try {
      await context.read<CrowdState>().release(widget.orderId);
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (mounted) showMessage(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _deliver() async {
    final code = _code.text.trim();
    if (code.length != 4) {
      setState(() => _codeError = tr('Код — 4 цифры', 'Kod — 4 ta raqam'));
      return;
    }
    setState(() {
      _busy = true;
      _codeError = null;
    });
    try {
      await context.read<CrowdState>().deliver(widget.orderId, code);
      if (!mounted) return;
      showMessage(context, tr('Заказ № ${_order['number']} вручён — вознаграждение начислено', 'Buyurtma № ${_order['number']} topshirildi — haq hisoblandi'));
      Navigator.of(context).pop();
    } on ApiError catch (e) {
      if (mounted) setState(() => _codeError = e.message);
    } catch (e) {
      if (mounted) showMessage(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _noAnswer() async {
    try {
      await context.read<CrowdState>().problem(widget.orderId, 'no_handoff');
      if (!mounted) return;
      await infoSheet(
        context,
        icon: Icons.support_agent_rounded,
        title: tr('Сообщили в поддержку', 'Qoʻllab-quvvatlash xizmatiga xabar berdik'),
        text: tr('Позвоните покупателю ещё раз и подождите у двери 5–10 минут. Поддержка Super Market свяжется с вами.',
            'Xaridorga yana qoʻngʻiroq qiling va eshik oldida 5–10 daqiqa kuting. Super Market qoʻllab-quvvatlash xizmati siz bilan bogʻlanadi.'),
      );
    } catch (e) {
      if (mounted) showMessage(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = _c;
    if (c == null) {
      return Scaffold(
        appBar: AppBar(),
        body: Center(
          child: _error == null
              ? const CircularProgressIndicator()
              : EmptyState(
                  icon: Icons.wifi_off_rounded,
                  title: tr('Не удалось загрузить', 'Yuklab boʻlmadi'),
                  text: '$_error',
                  action: tr('Повторить', 'Qayta urinish'),
                  onAction: _load,
                ),
        ),
      );
    }
    final o = _order;
    final status = '${o['status']}';
    final step = switch (status) { 'picked' => 1, 'delivering' => 2, 'delivered' => 3, _ => 0 };
    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(
        backgroundColor: AppColors.bg,
        leading: Padding(
          padding: const EdgeInsets.only(left: 12),
          child: Center(child: RoundIcon(icon: Icons.arrow_back_rounded, color: AppColors.white, onTap: () => Navigator.of(context).pop())),
        ),
        leadingWidth: 56,
        title: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(tr('Заказ № ${o['number']}', 'Buyurtma № ${o['number']}'), style: AppText.h3),
          Text(tr('${money(c['fee'])} за доставку', 'Yetkazish uchun ${money(c['fee'])}'), style: AppText.small),
        ]),
      ),
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(padding: const EdgeInsets.fromLTRB(20, 4, 20, 32), children: [
          _Steps(active: step),
          const SizedBox(height: 16),
          if (status == 'picked') ..._pickup(c, o),
          if (status == 'delivering') ..._handoff(c, o),
          if (status == 'delivered')
            EmptyState(
              icon: Icons.check_circle_rounded,
              title: tr('Заказ вручён', 'Buyurtma topshirildi'),
              text: tr('Вознаграждение уже в разделе «Заработок»', 'Haq allaqachon «Daromad» boʻlimida'),
            ),
          if (status == 'cancelled')
            EmptyState(
              icon: Icons.cancel_rounded,
              title: tr('Заказ отменён', 'Buyurtma bekor qilindi'),
              text: tr('Верните пакет в магазин, если он у вас', 'Paket sizda boʻlsa, uni doʻkonga qaytaring'),
            ),
        ]),
      ),
    );
  }

  List<Widget> _pickup(Map<String, dynamic> c, Map<String, dynamic> o) {
    final until = DateTime.tryParse('${c['pickup_until'] ?? ''}')?.toLocal();
    final code = '${c['pickup_code'] ?? ''}';
    return [
      if (until != null)
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(color: AppColors.warningSoft, borderRadius: BorderRadius.circular(16)),
          child: Row(children: [
            const Icon(Icons.timer_rounded, color: AppColors.warningInk),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                tr(
                    'Заберите до ${until.hour.toString().padLeft(2, '0')}:${until.minute.toString().padLeft(2, '0')} — '
                        '${minutesLeft(until, DateTime.now())}. Потом заказ вернётся в ленту.',
                    '${until.hour.toString().padLeft(2, '0')}:${until.minute.toString().padLeft(2, '0')} gacha oling — '
                        '${minutesLeft(until, DateTime.now())}. Keyin buyurtma lentaga qaytadi.'),
                style: AppText.small.copyWith(color: AppColors.warningInk, fontSize: 14, fontWeight: FontWeight.w500),
              ),
            ),
          ]),
        ),
      const SizedBox(height: 14),
      Container(
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(color: AppColors.white, borderRadius: BorderRadius.circular(24)),
        child: Column(children: [
          Text(tr('Покажите код продавцу', 'Kodni sotuvchiga koʻrsating'), style: AppText.title),
          const SizedBox(height: 14),
          QrImageView(data: pickupQr(o['number'], code), size: 180, backgroundColor: AppColors.white),
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            decoration: BoxDecoration(color: AppColors.soft, borderRadius: BorderRadius.circular(12)),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Text(tr('Код выдачи', 'Berish kodi'), style: AppText.small.copyWith(fontWeight: FontWeight.w500)),
              const SizedBox(width: 8),
              Text('${o['number']} · $code', style: AppText.bodyStrong),
            ]),
          ),
        ]),
      ),
      const SizedBox(height: 14),
      _PlaceCard(
        icon: Icons.storefront_rounded,
        title: '${_store['name'] ?? ''}',
        sub: '${_store['address'] ?? ''}',
        onRoute: () => route(context, _store['lat'] as num?, _store['lng'] as num?),
        onCall: '${_store['phone'] ?? ''}'.isEmpty ? null : () => call(context, '${_store['phone']}'),
      ),
      const SizedBox(height: 8),
      Center(
        child: TextButton(
          onPressed: _busy ? null : _release,
          child: Text(tr('Не могу забрать', 'Ola olmayman'), style: AppText.bodyStrong.copyWith(color: AppColors.text2)),
        ),
      ),
    ];
  }

  List<Widget> _handoff(Map<String, dynamic> c, Map<String, dynamic> o) {
    final details = [
      if ('${o['entrance'] ?? ''}'.isNotEmpty) tr('подъезд ${o['entrance']}', 'podʼezd ${o['entrance']}'),
      if ('${o['floor'] ?? ''}'.isNotEmpty) tr('этаж ${o['floor']}', 'qavat ${o['floor']}'),
      if ('${o['apartment'] ?? ''}'.isNotEmpty) tr('кв. ${o['apartment']}', 'xonadon ${o['apartment']}'),
    ].join(' · ');
    final phone = '${o['customer_phone'] ?? ''}';
    return [
      _PlaceCard(
        icon: Icons.person_rounded,
        title: '${c['customer_name'] ?? ''}'.isEmpty ? tr('Покупатель', 'Xaridor') : '${c['customer_name']}',
        sub: [o['address'], details, if ('${o['address_comment'] ?? ''}'.isNotEmpty) o['address_comment']]
            .where((x) => '${x ?? ''}'.isNotEmpty)
            .join(' · '),
        onRoute: () => route(context, o['lat'] as num?, o['lng'] as num?),
        onCall: phone.isEmpty ? null : () => call(context, phone),
      ),
      const SizedBox(height: 14),
      Container(
        padding: const EdgeInsets.all(22),
        decoration: BoxDecoration(color: AppColors.white, borderRadius: BorderRadius.circular(24)),
        child: Column(children: [
          Text(tr('Попросите код у покупателя', 'Xaridordan kodni soʻrang'), style: AppText.title, textAlign: TextAlign.center),
          const SizedBox(height: 6),
          Text(
              tr('Код есть в приложении Super Market в этом заказе. Без кода заказ не закрыть.',
                  'Kod Super Market ilovasida, shu buyurtma ichida. Kodsiz buyurtmani yopib boʻlmaydi.'),
              style: AppText.small.copyWith(fontSize: 14), textAlign: TextAlign.center),
          const SizedBox(height: 16),
          SizedBox(
            width: 220,
            child: TextField(
              controller: _code,
              enabled: !_busy,
              autofocus: false,
              keyboardType: TextInputType.number,
              textAlign: TextAlign.center,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(4)],
              style: AppText.h1.copyWith(letterSpacing: 18),
              onChanged: (_) => setState(() => _codeError = null),
              onSubmitted: (_) => _deliver(),
              decoration: InputDecoration(
                hintText: '••••',
                errorText: _codeError,
                errorMaxLines: 2,
              ),
            ),
          ),
        ]),
      ),
      const SizedBox(height: 16),
      BigButton(
        label: tr('Вручил заказ', 'Buyurtmani topshirdim'),
        icon: Icons.check_circle_rounded,
        color: AppColors.success,
        busy: _busy,
        onPressed: _code.text.length == 4 ? _deliver : null,
      ),
      const SizedBox(height: 8),
      Center(
        child: TextButton.icon(
          onPressed: _busy ? null : _noAnswer,
          icon: const Icon(Icons.help_outline_rounded, size: 18, color: AppColors.text2),
          label: Text(tr('Покупатель не отвечает', 'Xaridor javob bermayapti'), style: AppText.bodyStrong.copyWith(color: AppColors.text2)),
        ),
      ),
    ];
  }
}

class _Steps extends StatelessWidget {
  const _Steps({required this.active});
  final int active;

  @override
  Widget build(BuildContext context) {
    final labels = [tr('Принят', 'Qabul qilindi'), tr('В магазине', 'Doʻkonda'), tr('В пути', 'Yoʻlda'), tr('Вручён', 'Topshirildi')];
    return Row(children: [
      for (var i = 0; i < labels.length; i++) ...[
        if (i > 0) const SizedBox(width: 6),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Container(height: 5, decoration: BoxDecoration(color: i <= active ? AppColors.primary : AppColors.line, borderRadius: BorderRadius.circular(3))),
            const SizedBox(height: 6),
            Text(labels[i],
                style: AppText.small.copyWith(
                    fontSize: 12, color: i <= active ? AppColors.ink : AppColors.text2, fontWeight: i == active ? FontWeight.w600 : FontWeight.w500)),
          ]),
        ),
      ],
    ]);
  }
}

class _PlaceCard extends StatelessWidget {
  const _PlaceCard({required this.icon, required this.title, required this.sub, this.onRoute, this.onCall});
  final IconData icon;
  final String title;
  final String sub;
  final VoidCallback? onRoute;
  final VoidCallback? onCall;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(color: AppColors.white, borderRadius: BorderRadius.circular(20)),
      child: Row(children: [
        Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(color: AppColors.soft, borderRadius: BorderRadius.circular(12)),
          child: Icon(icon, size: 22, color: AppColors.ink),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title, style: AppText.bodyStrong),
            if (sub.isNotEmpty) Text(sub, style: AppText.small),
          ]),
        ),
        if (onCall != null) ...[
          const SizedBox(width: 8),
          RoundIcon(icon: Icons.call_rounded, color: AppColors.successSoft, onTap: onCall),
        ],
        if (onRoute != null) ...[
          const SizedBox(width: 8),
          RoundIcon(icon: Icons.directions_rounded, color: AppColors.blueSoft, onTap: onRoute),
        ],
      ]),
    );
  }
}
