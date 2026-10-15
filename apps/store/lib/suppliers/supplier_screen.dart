// «SM Магазин» · карточка поставщика-агента (Figma М29–М32): «Мы должны»,
// «Оплатить» (М30), статусы оплат и расхождение (М32), акт сверки, приходы.
// Деньги через Super Market не идут — только учёт и подтверждение агентом.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';
import 'package:sm_core/sm_core.dart';
import 'package:url_launcher/url_launcher.dart';

import '../debts/supplier_screen.dart' show SupplierScreen;
import '../finance/finance_logic.dart' show n, plainAmount;
import '../kassa/widgets.dart' show PickChip;
import '../lock/app_lock.dart';
import '../main.dart' show showMessage;
import '../state.dart';
import '../ui/theme.dart';
import '../ui/widgets.dart';
import 'income_screen.dart';
import 'order_screen.dart';

String payMethodTitle(Object? m) => switch ('$m') {
      'transfer' => tr('перевод', 'oʻtkazma'),
      'card' => tr('карта', 'karta'),
      _ => tr('наличные', 'naqd'),
    };

/// Статус оплаты глазами магазина.
(String, ChipTone, IconData) payState(Map<String, dynamic> p) => switch ('${p['status']}') {
      'confirmed' => (tr('Получено', 'Olindi'), ChipTone.green, Icons.check_rounded),
      'cancelled' => (tr('Отменена', 'Bekor qilindi'), ChipTone.gray, Icons.undo_rounded),
      'disputed' => n(p['received']) == 0
          ? (tr('Не получал', 'Olmagan'), ChipTone.red, Icons.error_outline_rounded)
          : (tr('Расхождение', 'Farq bor'), ChipTone.red, Icons.error_outline_rounded),
      _ => (tr('Ждёт', 'Kutmoqda'), ChipTone.amber, Icons.schedule_rounded),
    };

/// М29 · Поставщик-агент: долг, оплаты, заказ, акт сверки, приходы.
class DistSupplierScreen extends StatefulWidget {
  const DistSupplierScreen({super.key, required this.id});

  /// id сети дистрибьютора.
  final String id;

  @override
  State<DistSupplierScreen> createState() => _DistSupplierScreenState();
}

class _DistSupplierScreenState extends State<DistSupplierScreen> {
  Map<String, dynamic>? _s;
  List<Map<String, dynamic>>? _payments;
  Object? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final st = context.read<StoreState>();
    final api = context.read<Api>();
    try {
      final res = await Future.wait([
        api.get('/store/suppliers/${widget.id}', {'store_id': st.storeId}),
        api.list('/store/suppliers/${widget.id}/payments', {'limit': 30}),
      ]);
      if (!mounted) return;
      setState(() {
        _s = res[0] as Map<String, dynamic>;
        _payments = [for (final p in res[1] as List<Map<String, dynamic>>) if (p['store_id'] == st.storeId) p];
        _error = null;
      });
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  Future<void> _push(Widget w) async {
    await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => w));
    if (mounted) _load();
  }

  Future<void> _pay() async {
    final s = _s;
    if (s == null) return;
    final ok = await showSheet<bool>(context, (ctx) => PaySupplierSheet(supplier: s));
    if (ok == true && mounted) _load();
  }

  Future<void> _request() async {
    final st = context.read<StoreState>();
    setState(() => _busy = true);
    try {
      await context.read<Api>().post('/store/suppliers/${widget.id}/request', {'store_id': st.storeId});
      await _load();
    } catch (e) {
      if (mounted) showMessage(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _disconnect() async {
    final st = context.read<StoreState>();
    final ok = await confirmSheet(context,
        icon: Icons.link_off_rounded,
        title: tr('Отключить поставщика?', 'Yetkazib beruvchini uzasizmi?'),
        text: tr('Незакрытые заказы отменятся. Долг и акт сверки останутся.', 'Yopilmagan buyurtmalar bekor qilinadi. Qarz va dalolatnoma qoladi.'),
        confirm: tr('Отключить', 'Uzish'));
    if (!ok || !mounted) return;
    try {
      await context.read<Api>().post('/store/suppliers/${widget.id}/disconnect', {'store_id': st.storeId});
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (mounted) showMessage(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = _s;
    final phone = '${s?['phone'] ?? ''}';
    final agent = '${s?['agent_name'] ?? ''}';
    return Scaffold(
      appBar: AppBar(
        title: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('${s?['name'] ?? tr('Поставщик', 'Yetkazib beruvchi')}'),
          if (s != null)
            Text(
                [
                  ((s['brands'] as List?) ?? const []).take(2).join(', '),
                  if (agent.isNotEmpty) tr('агент $agent', 'agent $agent'),
                ].where((e) => e.isNotEmpty).join(' · '),
                style: AppText.small),
        ]),
        actions: [
          if (phone.isNotEmpty) IconButton(icon: const Icon(Icons.call_rounded), onPressed: () => launchUrl(Uri.parse('tel:$phone'))),
          if (s?['link_status'] == 'active')
            PopupMenuButton<String>(
              onSelected: (_) => _disconnect(),
              itemBuilder: (_) => [PopupMenuItem(value: 'off', child: Text(tr('Отключить поставщика', 'Yetkazib beruvchini uzish')))],
            ),
        ],
      ),
      body: s == null
          ? Center(
              child: _error == null
                  ? const CircularProgressIndicator()
                  : EmptyState(icon: Icons.wifi_off_rounded, title: tr('Не удалось загрузить', 'Yuklab boʻlmadi'), text: '$_error', action: tr('Повторить', 'Qayta urinish'), onAction: _load),
            )
          : RefreshIndicator(onRefresh: _load, child: ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 24), children: _body(s))),
    );
  }

  List<Widget> _body(Map<String, dynamic> s) {
    final st = context.watch<StoreState>();
    final active = s['link_status'] == 'active';
    final debt = n(s['debt']);
    final pendingSum = n(s['pending_sum']);
    final canPay = st.can('finance.manage') && s['counterparty_id'] != null;
    final payments = _payments ?? const <Map<String, dynamic>>[];
    final incomes = ((s['incomes'] as List?) ?? const []).cast<Map<String, dynamic>>();
    final draft = incomes.where((d) => d['status'] == 'draft').toList();
    final terms = '${s['supply_terms'] ?? ''}';
    return [
      if (!active)
        Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: AppCard(
            color: AppColors.warningSoft,
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(
                  s['link_status'] == 'requested'
                      ? tr('Ждём ответа агента — после подключения откроется прайс и заказ', 'Agent javobini kutyapmiz — ulangandan keyin narxlar va buyurtma ochiladi')
                      : tr('Поставщик не подключён', 'Yetkazib beruvchi ulanmagan'),
                  style: AppText.bodyStrong.copyWith(color: AppColors.warningInk)),
              if (s['link_status'] != 'requested') ...[
                const SizedBox(height: 10),
                BigButton(label: tr('Отправить запрос', 'Soʻrov yuborish'), icon: Icons.send_rounded, height: 44, busy: _busy, onPressed: _request),
              ],
            ]),
          ),
        ),
      for (final d in draft) ...[
        AppCard(
          color: AppColors.blueSoft,
          onTap: () => _push(SupplyIncomeScreen(id: '${d['id']}', supplier: s)),
          child: Row(children: [
            const IconBox(Icons.move_to_inbox_rounded, bg: AppColors.white, fg: AppColors.blue, size: 40, iconSize: 20, radius: 12),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(tr('Товар привезли · приход № ${d['number']}', 'Tovar keldi · № ${d['number']} kirim'), style: AppText.bodyStrong),
                Text(tr('Проверьте и нажмите «Принять товар» · ${money(d['total'])}', 'Tekshiring va «Tovarni qabul qilish»ni bosing · ${money(d['total'])}'),
                    style: AppText.small),
              ]),
            ),
            const Icon(Icons.chevron_right_rounded, color: AppColors.blue),
          ]),
        ),
        const SizedBox(height: 12),
      ],
      AppCard(
        padding: const EdgeInsets.all(18),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(debt >= 0 ? tr('Мы должны', 'Bizning qarzimiz') : tr('Поставщик должен нам', 'Yetkazib beruvchi bizga qarzdor'), style: AppText.small),
          Row(crossAxisAlignment: CrossAxisAlignment.baseline, textBaseline: TextBaseline.alphabetic, children: [
            Text(money(debt.abs(), suffix: false), style: AppText.h1),
            const SizedBox(width: 6),
            Text(tr('сум', 'soʻm'), style: AppText.body.copyWith(color: AppColors.text2)),
          ]),
          if (pendingSum > 0) ...[
            const SizedBox(height: 6),
            Text(tr('Ещё ${money(pendingSum, suffix: false)} вы отдали — агент пока не подтвердил', 'Yana ${money(pendingSum, suffix: false)} berdingiz — agent hali tasdiqlamadi'),
                style: AppText.small.copyWith(color: AppColors.warningInk)),
          ],
          const SizedBox(height: 14),
          Row(children: [
            if (canPay) ...[
              Expanded(child: BigButton(label: tr('Оплатить', 'Toʻlash'), icon: Icons.payments_rounded, height: 48, onPressed: _pay)),
              const SizedBox(width: 10),
            ],
            Expanded(
              child: BigButton(
                label: tr('Заказать', 'Buyurtma'),
                icon: Icons.add_shopping_cart_rounded,
                height: 48,
                color: canPay ? AppColors.white : AppColors.primary,
                foreground: canPay ? AppColors.ink : AppColors.white,
                onPressed: active ? () => _push(SupplierOrderScreen(supplier: s)) : null,
              ),
            ),
          ]),
        ]),
      ),
      if (terms.isNotEmpty) ...[
        const SizedBox(height: 12),
        AppCard(
          padding: const EdgeInsets.all(14),
          child: Row(children: [
            const Icon(Icons.handshake_outlined, color: AppColors.text2, size: 20),
            const SizedBox(width: 10),
            Expanded(child: Text(terms, style: AppText.small.copyWith(color: AppColors.ink))),
          ]),
        ),
      ],
      const SizedBox(height: 16),
      if (payments.isNotEmpty) ...[
        AppCard(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(tr('Оплаты', 'Toʻlovlar'), style: AppText.title),
            const SizedBox(height: 6),
            for (final (i, p) in payments.take(10).indexed) ...[
              if (i > 0) const Divider(height: 1),
              _PaymentRow(p: p, onTap: p['status'] == 'disputed' ? () => _push(DisputeScreen(payment: p, supplier: s)) : null),
            ],
          ]),
        ),
        const SizedBox(height: 16),
      ],
      AppCard(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: Column(children: [
          if (s['counterparty_id'] != null)
            ListTile(
              leading: const IconBox(Icons.description_rounded, size: 40, iconSize: 20, radius: 12),
              title: Text(tr('Акт сверки', 'Solishtirma dalolatnoma'), style: AppText.bodyStrong),
              subtitle: Text(tr('Тот же, что у агента', 'Agentdagi bilan bir xil'), style: AppText.small),
              trailing: const Icon(Icons.chevron_right_rounded, color: AppColors.muted),
              onTap: () => _push(SupplierScreen(id: '${s['counterparty_id']}')),
            ),
          ListTile(
            leading: const IconBox(Icons.receipt_long_rounded, size: 40, iconSize: 20, radius: 12),
            title: Text(tr('Заказы поставщику', 'Yetkazib beruvchiga buyurtmalar'), style: AppText.bodyStrong),
            subtitle: Text(
                (s['open_orders'] as num? ?? 0) > 0 ? tr('В работе: ${s['open_orders']}', 'Jarayonda: ${s['open_orders']}') : tr('История заказов', 'Buyurtmalar tarixi'),
                style: AppText.small),
            trailing: const Icon(Icons.chevron_right_rounded, color: AppColors.muted),
            onTap: () => _push(SupplierOrderScreen(supplier: s, initialTab: 2)),
          ),
          for (final d in incomes.where((d) => d['status'] != 'draft').take(3))
            ListTile(
              leading: const IconBox(Icons.move_to_inbox_rounded, size: 40, iconSize: 20, radius: 12),
              title: Text(tr('Приход № ${d['number']}', '№ ${d['number']} kirim'), style: AppText.bodyStrong),
              subtitle: Text('${dateTime(d['created_at'])} · ${money(d['total'])}', style: AppText.small),
              trailing: const Icon(Icons.chevron_right_rounded, color: AppColors.muted),
              onTap: () => _push(SupplyIncomeScreen(id: '${d['id']}', supplier: s)),
            ),
        ]),
      ),
    ];
  }
}

class _PaymentRow extends StatelessWidget {
  const _PaymentRow({required this.p, required this.onTap});

  final Map<String, dynamic> p;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final (label, tone, icon) = payState(p);
    final (bg, fg) = StatusChip.colors(tone);
    final disputed = p['status'] == 'disputed';
    final title = disputed
        ? tr('${money(p['amount'], suffix: false)} → агент: ${money(p['received'], suffix: false)}', '${money(p['amount'], suffix: false)} → agent: ${money(p['received'], suffix: false)}')
        : '${money(p['amount'], suffix: false)} · ${payMethodTitle(p['method'])}';
    final sub = switch ('${p['status']}') {
      'confirmed' => tr('${dateTime(p['confirmed_at'] ?? p['created_at'])} · агент подтвердил', '${dateTime(p['confirmed_at'] ?? p['created_at'])} · agent tasdiqladi'),
      'disputed' => tr('${dateTime(p['answered_at'] ?? p['created_at'])} · расхождение — откройте', '${dateTime(p['answered_at'] ?? p['created_at'])} · farq bor — oching'),
      'cancelled' => tr('${dateTime(p['answered_at'] ?? p['created_at'])} · деньги вернулись в кассу', '${dateTime(p['answered_at'] ?? p['created_at'])} · pul kassaga qaytdi'),
      _ => tr('${dateTime(p['created_at'])} · ждёт подтверждения агента', '${dateTime(p['created_at'])} · agent tasdigʻini kutmoqda'),
    };
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Row(children: [
          IconBox(icon, bg: bg, fg: fg, size: 40, iconSize: 20, radius: 12),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title, style: AppText.bodyStrong),
              Text(sub, style: AppText.small),
            ]),
          ),
          StatusChip(label, tone: tone),
        ]),
      ),
    );
  }
}

/// М30 · Оплатить поставщику: сумма, способ, касса, фото чека.
/// [amount] — подставить сумму (М31: «Сразу оплатили» при приёме товара).
class PaySupplierSheet extends StatefulWidget {
  const PaySupplierSheet({super.key, required this.supplier, this.amount, this.title});

  final Map<String, dynamic> supplier;
  final num? amount;
  final String? title;

  @override
  State<PaySupplierSheet> createState() => _PaySupplierSheetState();
}

class _PaySupplierSheetState extends State<PaySupplierSheet> {
  late final _amount = TextEditingController(text: money(widget.amount ?? _debt.clamp(0, double.infinity), suffix: false));
  String _method = 'cash';
  List<Map<String, dynamic>>? _boxes;
  String? _boxId;
  List<int>? _photo;
  String? _error;
  bool _busy = false;

  num get _debt => n(widget.supplier['debt']) - n(widget.supplier['pending_sum']);

  @override
  void initState() {
    super.initState();
    _amount.addListener(() => setState(() {}));
    _loadBoxes();
  }

  @override
  void dispose() {
    _amount.dispose();
    super.dispose();
  }

  Future<void> _loadBoxes() async {
    final st = context.read<StoreState>();
    try {
      final all = await context.read<Api>().list('/store/finance/cashboxes');
      final boxes = [
        for (final c in all)
          if (c['is_active'] != false && c['currency'] == 'UZS' && (c['is_main'] == true || c['store_id'] == st.storeId)) c,
      ]..sort((a, b) => (b['is_main'] == true ? 1 : 0) - (a['is_main'] == true ? 1 : 0));
      if (!mounted) return;
      setState(() {
        _boxes = boxes;
        _boxId = boxes.where((b) => n(b['balance']) > 0).firstOrNull?['id'] as String? ?? boxes.firstOrNull?['id'] as String?;
      });
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  Future<void> _pickBox() async {
    final boxes = _boxes;
    if (boxes == null || boxes.isEmpty) return;
    final id = await showSheet<String>(
      context,
      (ctx) => Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text(tr('Из какой кассы', 'Qaysi kassadan'), style: AppText.h3),
        const SizedBox(height: 12),
        for (final b in boxes)
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(b['is_main'] == true ? Icons.account_balance_rounded : Icons.point_of_sale_rounded),
            title: Text('${b['name']}', style: AppText.bodyStrong),
            trailing: Text(money(b['balance'], suffix: false), style: AppText.bodyStrong),
            onTap: () => Navigator.pop(ctx, '${b['id']}'),
          ),
      ]),
    );
    if (id != null && mounted) setState(() => _boxId = id);
  }

  Future<void> _takePhoto() async {
    final lock = context.read<AppLock>();
    try {
      final x = await lock.hold(() => ImagePicker().pickImage(source: ImageSource.camera, maxWidth: 1600, maxHeight: 1600, imageQuality: 85));
      if (x == null) return;
      final bytes = await x.readAsBytes();
      if (mounted) setState(() => _photo = bytes);
    } catch (_) {
      if (mounted) {
        showMessage(context, tr('Нет доступа к камере. Разрешите доступ в настройках телефона.', 'Kameraga ruxsat yoʻq. Telefon sozlamalarida ruxsat bering.'));
      }
    }
  }

  Future<void> _submit() async {
    final v = num.tryParse(plainAmount(_amount.text));
    final box = _boxes?.where((b) => b['id'] == _boxId).firstOrNull;
    String? err;
    if (v == null || v <= 0) {
      err = tr('Введите сумму больше нуля', 'Noldan katta summani kiriting');
    } else if (box == null) {
      err = tr('Выберите кассу', 'Kassani tanlang');
    } else if (v > n(box['balance'])) {
      err = tr('В кассе «${box['name']}» только ${money(box['balance'])}', '«${box['name']}» kassasida faqat ${money(box['balance'])}');
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
    final st = context.read<StoreState>();
    try {
      var photoUrl = '';
      final photo = _photo;
      if (photo != null) {
        final res = await api.upload('/store/uploads', photo, 'payment.jpg') as Map<String, dynamic>;
        photoUrl = '${res['url'] ?? ''}';
      }
      await api.post('/store/suppliers/${widget.supplier['id']}/pay', {
        'amount': plainAmount(_amount.text),
        'cashbox_id': _boxId,
        'method': _method,
        'photo_url': photoUrl,
        'store_id': st.storeId,
      });
      if (!mounted) return;
      final messenger = ScaffoldMessenger.of(context);
      Navigator.of(context).pop(true);
      messenger.showSnackBar(SnackBar(content: Text(tr('Оплата записана — ждём подтверждения агента', 'Toʻlov yozildi — agent tasdigʻini kutyapmiz'))));
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.supplier;
    final debt = _debt;
    final box = _boxes?.where((b) => b['id'] == _boxId).firstOrNull;
    final agent = '${s['agent_name'] ?? ''}';
    final v = num.tryParse(plainAmount(_amount.text)) ?? 0;
    return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Text(widget.title ?? tr('Оплата поставщику', 'Yetkazib beruvchiga toʻlov'), style: AppText.h3),
      Text(
          [
            '${s['name']}',
            if (agent.isNotEmpty) tr('агент $agent', 'agent $agent'),
            if (debt > 0) tr('долг ${money(debt)}', 'qarz ${money(debt)}'),
          ].join(' · '),
          style: AppText.small),
      const SizedBox(height: 16),
      TextField(
        controller: _amount,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.,\s]'))],
        style: AppText.h2,
        decoration: InputDecoration(labelText: tr('Сумма', 'Summa'), suffixText: tr('сум', 'soʻm')),
      ),
      if (debt > 0 && widget.amount == null) ...[
        const SizedBox(height: 10),
        Wrap(spacing: 8, runSpacing: 8, children: [
          ActionChip(label: Text(tr('Весь долг · ${money(debt, suffix: false)}', 'Butun qarz · ${money(debt, suffix: false)}')), onPressed: () => _amount.text = money(debt, suffix: false)),
          ActionChip(label: Text(tr('Половина', 'Yarmi')), onPressed: () => _amount.text = money((debt / 2).roundToDouble(), suffix: false)),
        ]),
      ],
      const SizedBox(height: 16),
      Text(tr('СПОСОБ', 'USUL'), style: AppText.caption),
      const SizedBox(height: 8),
      Row(children: [
        for (final (i, m) in ['cash', 'transfer', 'card'].indexed) ...[
          if (i > 0) const SizedBox(width: 8),
          Expanded(
            child: PickChip(
              label: switch (m) { 'transfer' => tr('Перевод', 'Oʻtkazma'), 'card' => tr('Карта', 'Karta'), _ => tr('Наличные', 'Naqd') },
              selected: _method == m,
              onTap: () => setState(() => _method = m),
            ),
          ),
        ],
      ]),
      const SizedBox(height: 16),
      Text(tr('ИЗ КАССЫ', 'KASSADAN'), style: AppText.caption),
      const SizedBox(height: 8),
      AppCard(
        color: AppColors.soft,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        onTap: _pickBox,
        child: Row(children: [
          const Icon(Icons.point_of_sale_rounded, color: AppColors.text2),
          const SizedBox(width: 10),
          Expanded(
            child: _boxes == null
                ? const LinearProgressIndicator()
                : Text(box == null ? tr('Нет кассы', 'Kassa yoʻq') : '${box['name']} · ${money(box['balance'], suffix: false)}', style: AppText.bodyStrong),
          ),
          const Icon(Icons.expand_more_rounded, color: AppColors.muted),
        ]),
      ),
      const SizedBox(height: 10),
      AppCard(
        color: AppColors.soft,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        onTap: _busy ? null : _takePhoto,
        child: Row(children: [
          Icon(_photo == null ? Icons.add_a_photo_rounded : Icons.check_circle_rounded, color: _photo == null ? AppColors.text2 : AppColors.success),
          const SizedBox(width: 10),
          Expanded(
            child: Text(_photo == null ? tr('Фото чека или расписки · необязательно', 'Chek yoki tilxat surati · ixtiyoriy') : tr('Фото добавлено — нажмите, чтобы переснять', 'Surat qoʻshildi — qayta olish uchun bosing'),
                style: AppText.small.copyWith(color: AppColors.ink)),
          ),
        ]),
      ),
      const SizedBox(height: 12),
      Text(tr('Агент получит уведомление и подтвердит, что получил деньги. До подтверждения оплата помечена «Ждёт».', 'Agent bildirishnoma oladi va pulni olganini tasdiqlaydi. Tasdiqlanguncha toʻlov «Kutmoqda» deb belgilanadi.'),
          style: AppText.small),
      if (_error != null) ...[
        const SizedBox(height: 10),
        Text(_error!, style: AppText.small.copyWith(color: AppColors.error)),
      ],
      const SizedBox(height: 16),
      BigButton(label: tr('Оплатить ${money(v)}', '${money(v)} toʻlash'), busy: _busy, onPressed: _submit),
    ]);
  }
}

/// М32 · Агент получил другую сумму: согласиться или исправить.
class DisputeScreen extends StatefulWidget {
  const DisputeScreen({super.key, required this.payment, required this.supplier});

  final Map<String, dynamic> payment;
  final Map<String, dynamic> supplier;

  @override
  State<DisputeScreen> createState() => _DisputeScreenState();
}

class _DisputeScreenState extends State<DisputeScreen> {
  bool _busy = false;

  Future<void> _resolve(String amount) async {
    setState(() => _busy = true);
    try {
      await context.read<Api>().post('/store/suppliers/payments/${widget.payment['id']}/resolve', {'amount': amount});
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (mounted) showMessage(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _edit() async {
    final v = await promptSheet(
      context,
      title: tr('Исправить сумму', 'Summani tuzatish'),
      text: tr('Сколько вы на самом деле отдали агенту. Агент подтвердит снова.', 'Agentga aslida qancha berdingiz. Agent yana tasdiqlaydi.'),
      hint: money(widget.payment['amount'], suffix: false),
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      confirm: tr('Сохранить', 'Saqlash'),
    );
    if (v == null || !mounted) return;
    final amount = plainAmount(v);
    if ((num.tryParse(amount) ?? 0) <= 0) {
      showMessage(context, tr('Введите сумму больше нуля', 'Noldan katta summani kiriting'));
      return;
    }
    await _resolve(amount);
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.payment;
    final s = widget.supplier;
    final phone = '${s['phone'] ?? ''}';
    final received = n(p['received']);
    final comment = '${p['agent_comment'] ?? ''}';
    final agent = '${s['agent_name'] ?? ''}';
    return Scaffold(
      appBar: AppBar(
        title: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('${s['name']}'),
          Text(tr('Оплата от ${dateTime(p['created_at'])}', '${dateTime(p['created_at'])} dagi toʻlov'), style: AppText.small),
        ]),
        actions: [
          if (phone.isNotEmpty) IconButton(icon: const Icon(Icons.call_rounded), onPressed: () => launchUrl(Uri.parse('tel:$phone'))),
        ],
      ),
      body: ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 24), children: [
        AppCard(
          color: AppColors.errorSoft,
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              const Icon(Icons.error_outline_rounded, color: AppColors.error),
              const SizedBox(width: 8),
              Expanded(
                child: Text(received == 0 ? tr('Агент не получал деньги', 'Agent pulni olmagan') : tr('Агент получил другую сумму', 'Agent boshqa summa olgan'),
                    style: AppText.bodyStrong.copyWith(color: AppColors.error)),
              ),
            ]),
            const SizedBox(height: 4),
            Text([if (agent.isNotEmpty) agent, dateTime(p['answered_at'])].join(' · '), style: AppText.small),
            const SizedBox(height: 14),
            Row(children: [
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(tr('Вы указали', 'Siz koʻrsatdingiz'), style: AppText.small),
                  Text(money(p['amount']), style: AppText.title),
                ]),
              ),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(tr('Агент получил', 'Agent oldi'), style: AppText.small),
                  Text(money(received), style: AppText.title.copyWith(color: AppColors.error)),
                ]),
              ),
            ]),
          ]),
        ),
        if (comment.isNotEmpty) ...[
          const SizedBox(height: 12),
          AppCard(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(tr('Комментарий агента', 'Agent izohi'), style: AppText.small),
              const SizedBox(height: 4),
              Text('«$comment»', style: AppText.body),
            ]),
          ),
        ],
        const SizedBox(height: 20),
        BigButton(
          label: received == 0
              ? tr('Согласиться — оплаты не было', 'Rozi boʻlish — toʻlov boʻlmagan')
              : tr('Согласиться — ${money(received, suffix: false)}', 'Rozi boʻlish — ${money(received, suffix: false)}'),
          icon: Icons.check_rounded,
          busy: _busy,
          onPressed: () => _resolve(received == 0 ? '0' : '${p['received']}'),
        ),
        const SizedBox(height: 10),
        BigButton(label: tr('Исправить сумму', 'Summani tuzatish'), icon: Icons.edit_rounded, color: AppColors.white, foreground: AppColors.ink, onPressed: _busy ? null : _edit),
        if (phone.isNotEmpty) ...[
          const SizedBox(height: 10),
          BigButton(
              label: tr('Позвонить агенту', 'Agentga qoʻngʻiroq'),
              icon: Icons.call_rounded,
              color: AppColors.soft,
              foreground: AppColors.ink,
              onPressed: () => launchUrl(Uri.parse('tel:$phone'))),
        ],
        const SizedBox(height: 16),
        Text(
            received == 0
                ? tr('Согласились — оплата отменяется, деньги возвращаются в кассу, долг — как был. Исправили — агент снова подтверждает.',
                    'Rozi boʻlsangiz — toʻlov bekor qilinadi, pul kassaga qaytadi, qarz avvalgidek. Tuzatsangiz — agent yana tasdiqlaydi.')
                : tr('Согласились — оплата становится ${money(received)} и сразу «Получено», разница возвращается в долг. Исправили — агент снова подтверждает.',
                    'Rozi boʻlsangiz — toʻlov ${money(received)} boʻladi va darhol «Olindi», farq qarzga qaytadi. Tuzatsangiz — agent yana tasdiqlaydi.'),
            style: AppText.small),
      ]),
    );
  }
}
