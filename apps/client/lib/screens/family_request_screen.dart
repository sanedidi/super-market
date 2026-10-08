import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:sm_core/sm_core.dart';

import '../family_ui.dart';
import '../main.dart';
import '../state.dart';
import '../ui/theme.dart';
import '../ui/widgets.dart';
import 'order_screen.dart';
import 'root_shell.dart' show itemsWord, openCart;

/// «Просьба» по макету Figma: комментарий автора, когда напомним, чек-лист с
/// ценами ближайшего магазина, «Заказать домой» и «Куплю сам».
class FamilyRequestScreen extends StatefulWidget {
  const FamilyRequestScreen({super.key, required this.id});
  final String id;

  @override
  State<FamilyRequestScreen> createState() => _FamilyRequestScreenState();
}

class _FamilyRequestScreenState extends State<FamilyRequestScreen> {
  Map<String, dynamic>? _r;

  /// Ответ /to-cart: магазин и цены некупленных товаров.
  Map<String, dynamic>? _quote;
  Object? _error;
  bool _busy = false;
  final _marking = <String>{};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  bool get _active => _r != null && (_r!['status'] == 'pending' || _r!['status'] == 'partial');

  Future<void> _load() async {
    final api = context.read<Api>();
    try {
      final r = await api.get('/client/family/requests/${widget.id}') as Map<String, dynamic>;
      if (!mounted) return;
      setState(() {
        _r = r;
        _error = null;
      });
      await _loadQuote();
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  Future<void> _loadQuote() async {
    final address = context.read<AppState>().address;
    if (!_active || address == null) {
      setState(() => _quote = null);
      return;
    }
    try {
      final q = await context.read<Api>().get('/client/family/requests/${widget.id}/to-cart', {'lat': address.lat, 'lng': address.lng});
      if (mounted) setState(() => _quote = q as Map<String, dynamic>);
    } catch (_) {
      if (mounted) setState(() => _quote = null);
    }
  }

  Future<void> _mark(Map<String, dynamic> item) async {
    final id = item['id'] as String;
    if (_marking.contains(id) || !_active) return;
    setState(() => _marking.add(id));
    try {
      final r = await context.read<Api>().post('/client/family/requests/${widget.id}/items/$id/bought', {'bought': item['bought'] != true});
      if (!mounted) return;
      setState(() => _r = r as Map<String, dynamic>);
      if (r['status'] == 'bought') {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(tr('Всё куплено — отправили уведомление', 'Hammasi olindi — bildirishnoma yuborildi'))));
      }
      _loadQuote();
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _marking.remove(id));
    }
  }

  Future<void> _action(String path, [Map<String, dynamic>? body, String? done]) async {
    setState(() => _busy = true);
    try {
      final r = await context.read<Api>().post('/client/family/requests/${widget.id}/$path', body);
      if (!mounted) return;
      setState(() => _r = r as Map<String, dynamic>);
      if (done != null) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(done)));
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// «Заказать домой»: корзина из найденных товаров ближайшего магазина.
  Future<void> _orderHome() async {
    final q = _quote;
    final state = context.read<AppState>();
    if (q == null || q['store'] == null) return;
    final lines = <(Product, num)>[];
    for (final l in ((q['lines'] as List?) ?? const []).cast<Map<String, dynamic>>()) {
      final p = l['product'] as Map<String, dynamic>?;
      if (p != null) lines.add((Product(p), num.tryParse('${l['qty']}') ?? 1));
    }
    if (lines.isEmpty) return;
    if (state.cartCount > 0 && state.familyRequestId != widget.id) {
      final ok = await confirmSheet(
        context,
        title: tr('Заменить корзину?', 'Savat almashtirilsinmi?'),
        text: tr('В корзине уже есть товары. Положим вместо них товары из просьбы.', 'Savatda allaqachon mahsulotlar bor. Ular oʻrniga iltimosdagi mahsulotlarni qoʻyamiz.'),
        confirm: tr('Заменить', 'Almashtirish'),
      );
      if (!ok || !mounted) return;
    }
    state.fillCartFromRequest(widget.id, Store(q['store'] as Map<String, dynamic>), lines);
    final missing = (q['lines'] as List).length - lines.length;
    if (missing > 0) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(tr('Не нашли в магазине: ${itemsWord(missing)} — купите их отдельно', 'Doʻkonda topilmadi: ${itemsWord(missing)} — ularni alohida xarid qiling'))));
    }
    await openCart(context);
    if (mounted) _load();
  }

  Future<void> _more() async {
    final r = _r!;
    final state = context.read<AppState>();
    final myId = ((state.family?['members'] as List?) ?? const []).cast<Map<String, dynamic>>().where((m) => m['is_me'] == true).firstOrNull?['user_id'];
    final canCancel = r['author_id'] == myId || state.family?['my_role'] == 'owner';
    final a = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: AppColors.white,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            AppListRow(icon: Icons.snooze_rounded, title: tr('Напомнить через час', 'Bir soatdan keyin eslatish'), onTap: () => Navigator.pop(ctx, 'snooze'), divider: canCancel),
            if (canCancel)
              AppListRow(
                  icon: Icons.close_rounded,
                  iconColor: AppColors.error,
                  title: tr('Отменить просьбу', 'Iltimosni bekor qilish'),
                  divider: false, onTap: () => Navigator.pop(ctx, 'cancel')),
          ]),
        ),
      ),
    );
    if (a == 'snooze') await _action('snooze', {'minutes': 60}, tr('Напомним через час', 'Bir soatdan keyin eslatamiz'));
    if (a == 'cancel') await _action('cancel', null, tr('Просьба отменена', 'Iltimos bekor qilindi'));
  }

  @override
  Widget build(BuildContext context) {
    final r = _r;
    if (r == null) {
      return Scaffold(
        backgroundColor: AppColors.bg,
        appBar: AppBar(backgroundColor: AppColors.bg),
        body: _error == null
            ? const Center(child: CircularProgressIndicator())
            : EmptyState(
                    icon: Icons.wifi_off_rounded,
                    title: tr('Не удалось загрузить', 'Yuklab boʻlmadi'),
                    text: _error.toString(),
                    action: tr('Повторить', 'Qayta urinish'),
                    onAction: _load),
      );
    }
    final items = ((r['items'] as List?) ?? const []).cast<Map<String, dynamic>>();
    final created = DateTime.tryParse('${r['created_at']}')?.toLocal();
    final author = '${r['author_name'] ?? ''}';
    final comment = '${r['comment'] ?? ''}';
    final remind = DateTime.tryParse('${r['remind_at'] ?? ''}');
    final offer = DateTime.tryParse('${r['deliver_offer_at'] ?? ''}');
    final quote = _quote;
    final prices = <String, Map<String, dynamic>>{
      for (final l in ((quote?['lines'] as List?) ?? const []).cast<Map<String, dynamic>>())
        if (l['product'] != null) l['item_id'] as String: l,
    };
    final canOrder = _active && quote != null && quote['store'] != null && (quote['found'] as num? ?? 0) > 0;
    final storeName = (quote?['store'] as Map<String, dynamic>?)?['name'];

    return Scaffold(
      backgroundColor: AppColors.bg,
      body: SafeArea(
        bottom: false,
        child: Column(children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: Row(children: [
              RoundIconButton(icon: Icons.arrow_back_ios_new_rounded, bg: AppColors.white, onTap: () => Navigator.of(context).pop()),
              const SizedBox(width: 12),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('${r['title']}', maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.title),
                  Text('${created == null ? '' : capitalize(whenText(created).split(tr(' в ', ' soat ')).first)} · ${itemsWord(items.length)}', style: AppText.small),
                ]),
              ),
              if (_active) IconButton(onPressed: _busy ? null : _more, icon: const Icon(Icons.more_horiz_rounded)),
            ]),
          ),
          Expanded(
            child: RefreshIndicator(
              onRefresh: _load,
              child: ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 24), children: [
                Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  MemberAvatar(id: '${r['author_id'] ?? ''}', name: author, size: 36),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Container(
                      padding: const EdgeInsets.all(12),
                      decoration: const BoxDecoration(
                        color: AppColors.white,
                        borderRadius: BorderRadius.only(
                            topRight: Radius.circular(16), bottomLeft: Radius.circular(16), bottomRight: Radius.circular(16), topLeft: Radius.circular(4)),
                      ),
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text('$author${created == null ? '' : ' · ${hhmm(created)}'}',
                            style: AppText.caption.copyWith(color: avatarTone('${r['author_id'] ?? ''}').fg, fontWeight: FontWeight.w600)),
                        const SizedBox(height: 4),
                        Text(comment.isEmpty ? tr('Купи, пожалуйста: ${r['summary']}', 'Iltimos, olib kel: ${r['summary']}') : comment, style: AppText.body),
                      ]),
                    ),
                  ),
                ]),
                const SizedBox(height: 16),
                if (_active && (remind != null || r['remind_at_store'] == true))
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 14),
                    decoration: BoxDecoration(color: AppColors.primarySoft, borderRadius: BorderRadius.circular(AppRadius.lg)),
                    child: Column(children: [
                      if (remind != null)
                        _InfoRow(
                          icon: Icons.schedule_rounded,
                          title: remind.isAfter(DateTime.now())
                              ? tr('Напомним ${whenText(remind)}', 'Eslatamiz: ${whenText(remind)}')
                              : tr('Напомнили ${whenText(remind)}', 'Eslatildi: ${whenText(remind)}'),
                          subtitle: offer == null
                              ? tr('Уведомление придёт на телефон', 'Bildirishnoma telefonga keladi')
                              : tr('Если не успеете — предложим доставку после ${hhmm(offer.toLocal())}',
                                  'Ulgurmasangiz — soat ${hhmm(offer.toLocal())} dan keyin yetkazib berishni taklif qilamiz'),
                          divider: r['remind_at_store'] == true,
                        ),
                      if (r['remind_at_store'] == true)
                        _InfoRow(
                          icon: Icons.location_on_outlined,
                          title: remind == null ? tr('Напомним у магазина', 'Doʻkon yonida eslatamiz') : tr('И рядом с магазином', 'Va doʻkon yonida'),
                          subtitle: storeName == null
                              ? tr('Когда будете рядом с магазином', 'Doʻkon yonida boʻlganingizda')
                              : tr('$storeName рядом с вашим адресом', '$storeName manzilingizga yaqin'),
                        ),
                    ]),
                  ),
                if (r['status'] == 'ordered' && r['order_id'] != null) ...[
                  AppCard(
                    child: AppListRow(
                      icon: Icons.local_shipping_outlined,
                      title: tr('Заказано домой', 'Uyga buyurtma qilindi'),
                      subtitle: tr('Посмотреть заказ', 'Buyurtmani koʻrish'),
                      divider: false,
                      onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => OrderScreen(id: r['order_id'] as String))),
                    ),
                  ),
                ],
                const SizedBox(height: 16),
                AppCard(
                  padding: const EdgeInsets.symmetric(horizontal: 14),
                  child: Column(children: [
                    for (var i = 0; i < items.length; i++)
                      _ItemRow(
                        item: items[i],
                        quote: prices[items[i]['id']],
                        busy: _marking.contains(items[i]['id']),
                        enabled: _active,
                        last: i == items.length - 1,
                        onTap: () => _mark(items[i]),
                      ),
                  ]),
                ),
                if (!_active) ...[
                  const SizedBox(height: 16),
                  Center(child: requestBadge(r)),
                ],
              ]),
            ),
          ),
        ]),
      ),
      bottomNavigationBar: !_active
          ? null
          : BottomActionBar(
              top: canOrder
                  ? Text(
                      tr('Не успеваете? Привезём домой${storeName == null ? '' : ' из «$storeName»'} — $author получит уведомление.',
                          'Ulgurmayapsizmi? ${storeName == null ? '' : '«$storeName» doʻkonidan '}uyga yetkazamiz — $author bildirishnoma oladi.'),
                      textAlign: TextAlign.center,
                      style: AppText.caption,
                    )
                  : null,
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                if (canOrder) ...[
                  AppButton(label: tr('Заказать домой · ${money(quote['total'])}', 'Uyga buyurtma · ${money(quote['total'])}'), onPressed: _busy ? null : _orderHome),
                  const SizedBox(height: 10),
                ],
                AppButton(
                  label: tr('Куплю сам — отмечу в магазине', 'Oʻzim olaman — doʻkonda belgilayman'),
                  type: AppButtonType.secondary,
                  onPressed: () {
                    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(tr('Отмечайте товары галочкой — автор увидит, что куплено', 'Mahsulotlarni belgilab boring — muallif nima olinganini koʻradi'))));
                    Navigator.of(context).pop();
                  },
                ),
              ]),
            ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  const _InfoRow({required this.icon, required this.title, required this.subtitle, this.divider = false});
  final IconData icon;
  final String title;
  final String subtitle;
  final bool divider;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 12),
      decoration: BoxDecoration(border: divider ? const Border(bottom: BorderSide(color: AppColors.primaryLine)) : null),
      child: Row(children: [
        Icon(icon, color: AppColors.ink, size: 22),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title, style: AppText.bodyStrong),
            Text(subtitle, style: AppText.caption),
          ]),
        ),
      ]),
    );
  }
}

class _ItemRow extends StatelessWidget {
  const _ItemRow({required this.item, required this.onTap, required this.busy, required this.enabled, required this.last, this.quote});
  final Map<String, dynamic> item;
  final Map<String, dynamic>? quote;
  final VoidCallback onTap;
  final bool busy;
  final bool enabled;
  final bool last;

  @override
  Widget build(BuildContext context) {
    final bought = item['bought'] == true;
    final name = '${item['product_name'] ?? item['text'] ?? ''}';
    final unit = '${item['unit_short'] ?? ''}';
    final q = item['qty'];
    final product = quote?['product'] as Map<String, dynamic>?;
    final sub = [
      if (item['product_id'] == null) tr('добавлено текстом', 'matn bilan qoʻshilgan'),
      if (bought && item['bought_by_name'] != null) tr('купил(а) ${item['bought_by_name']}', '${item['bought_by_name']} oldi'),
    ].join(' · ');
    return InkWell(
      onTap: enabled ? onTap : null,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 12),
        decoration: BoxDecoration(border: last ? null : const Border(bottom: BorderSide(color: AppColors.line))),
        child: Row(children: [
          SizedBox(
            width: 28,
            height: 28,
            child: busy
                ? const Padding(padding: EdgeInsets.all(4), child: CircularProgressIndicator(strokeWidth: 2))
                : Container(
                    decoration: BoxDecoration(
                      color: bought ? AppColors.success : AppColors.white,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: bought ? AppColors.success : AppColors.line, width: 2),
                    ),
                    child: bought ? const Icon(Icons.check_rounded, size: 18, color: AppColors.white) : null,
                  ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(name,
                  style: AppText.bodyMedium.copyWith(
                    decoration: bought ? TextDecoration.lineThrough : null,
                    color: bought ? AppColors.text2 : AppColors.ink,
                  )),
              if (sub.isNotEmpty) Text(sub, style: AppText.caption),
            ]),
          ),
          const SizedBox(width: 8),
          Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
            if (product != null && !bought) Text(money(mulMoney(product['price'] as String, '${quote!['qty']}')), style: AppText.bodyStrong),
            // Единицы приходят на языке приложения: «шт» / «dona».
            Text(unit.isEmpty || unit == 'шт' || unit == 'dona' ? '×${qty(q)}' : qty(q, unit), style: AppText.caption),
          ]),
        ]),
      ),
    );
  }
}
