import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:sm_core/sm_core.dart';

import '../delivery_time.dart';
import '../main.dart';
import '../product_tile.dart';
import '../state.dart';
import '../ui/theme.dart';
import '../ui/widgets.dart';
import 'checkout_sheets.dart';
import 'payment_screen.dart';
import 'root_shell.dart';

const _problemText = {
  'out_of_stock': 'Закончился',
  'not_enough': 'Столько нет в наличии',
  'fractional': 'Только целое количество',
  'unavailable': 'Недоступен',
};

const _orderProblemText = {
  'items': 'Часть товаров недоступна — уберите их или уменьшите количество',
  'store_closed': 'Магазин сейчас закрыт',
  'min_order_amount': 'Сумма меньше минимального заказа',
  'not_deliverable': 'Магазин не доставляет по этому адресу',
  'store_not_accepting': 'Магазин сейчас не принимает заказы',
  'slot_full': 'На выбранное время заказов больше нет — выберите другое',
  'slot_unavailable': 'Выбранное время уже недоступно — выберите другое',
};

/// Тело предпросмотра и заказа.
Map<String, dynamic> _orderBody(AppState s, {String provider = 'payme', String comment = '', Slot? slot}) => {
      'store_id': s.cartStoreId,
      'address_id': s.address?.id,
      'items': s.cartItems,
      'payment_provider': provider,
      'comment': comment,
      'delivery_from': slot?.fromRaw,
    };

/// Текст проблемы заказа для показа.
String _problemMessage(String pr, Map<String, dynamic>? delivery) => pr == 'min_order_amount' && delivery != null
    ? 'Минимальный заказ — ${money(delivery['min_order_amount'])}'
    : (_orderProblemText[pr] ?? pr);

/// Корзина (Figma «08 Корзина»): время доставки чипами, условия доставки,
/// товары и кнопка «Оформить». Пересчёт — на сервере.
class CartScreen extends StatefulWidget {
  const CartScreen({super.key});

  @override
  State<CartScreen> createState() => _CartScreenState();
}

class _CartScreenState extends State<CartScreen> {
  Map<String, dynamic>? _preview;
  String? _error;

  /// Окно доставки; null — как можно скорее.
  Slot? _slot;

  /// Ближайшие свободные окна для чипов.
  List<Slot> _slots = const [];

  /// «Не забудьте»: что покупают вместе с товарами корзины.
  List<Product> _suggest = const [];

  /// Состав корзины при последнем пересчёте — пересчитываем, когда он меняется.
  String? _sig;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _refresh();
      _loadSlots();
      _loadSuggest();
    });
  }

  Future<void> _loadSlots() async {
    final storeId = context.read<AppState>().cartStoreId;
    if (storeId == null) return;
    try {
      final r = await context.read<Api>().get('/client/stores/$storeId/slots') as Map<String, dynamic>;
      final days = ((r['days'] as List?) ?? const []).cast<Map<String, dynamic>>().map(SlotDay.new);
      final free = [for (final d in days) ...d.slots.where((s) => s.free)].take(4).toList();
      if (mounted) setState(() => _slots = free);
    } catch (_) {
      // Без окон остаётся «Как можно скорее» и выбор в листе.
    }
  }

  Future<void> _loadSuggest() async {
    final s = context.read<AppState>();
    final api = context.read<Api>();
    final storeId = s.cartStoreId;
    if (storeId == null) return;
    final seen = <String>{};
    final out = <Product>[];
    for (final id in s.cart.keys.take(3).toList()) {
      try {
        for (final j in await api.list('/client/stores/$storeId/products/$id/related')) {
          final p = Product(j);
          if (seen.add(p.id)) out.add(p);
        }
      } catch (_) {
        // Подсказки не обязательны.
      }
    }
    if (mounted) setState(() => _suggest = out);
  }

  Future<void> _refresh() async {
    final s = context.read<AppState>();
    if (s.cartCount == 0 || s.address == null) return;
    setState(() => _error = null);
    try {
      final p = await context.read<Api>().post('/client/checkout/preview', _orderBody(s, slot: _slot)) as Map<String, dynamic>;
      if (mounted) setState(() => _preview = p);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  void _setSlot(Slot? slot) {
    setState(() => _slot = slot);
    _refresh();
  }

  Future<void> _otherTime(String? eta) async {
    final s = context.read<AppState>();
    if (s.cartStoreId == null) return;
    final choice = await pickDeliveryTime(context, storeId: s.cartStoreId!, eta: eta, current: _slot);
    if (choice != null && mounted) _setSlot(choice.slot);
  }

  Future<void> _checkout() async {
    final slot = await Navigator.of(context).push<Slot?>(MaterialPageRoute(builder: (_) => CheckoutScreen(slot: _slot)));
    if (mounted && slot != _slot) _setSlot(slot);
  }

  Future<void> _clear() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Очистить корзину?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Отмена')),
          TextButton(style: TextButton.styleFrom(foregroundColor: AppColors.error), onPressed: () => Navigator.pop(ctx, true), child: const Text('Очистить')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    context.read<AppState>().clearCart();
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final s = context.watch<AppState>();
    final p = _preview;
    final lines = {for (final l in (p?['lines'] as List? ?? const [])) (l as Map<String, dynamic>)['product_id']: l};
    final problems = ((p?['problems'] as List?) ?? const []).cast<String>();
    final delivery = p?['delivery'] as Map<String, dynamic>?;
    final suggest = _suggest.where((x) => !s.cart.containsKey(x.id)).take(10).toList();
    final cartStore = s.stores.where((x) => x.id == s.cartStoreId).firstOrNull;
    final sig = s.cartItems.toString();
    if (_sig != null && sig != _sig && s.cartCount > 0) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _refresh();
      });
    }
    _sig = sig;

    final chips = <Widget>[
      AppChip(label: 'Как можно скорее', selected: _slot == null, onTap: () => _setSlot(null)),
      for (final sl in _slots)
        AppChip(label: sl.range, selected: _slot?.fromRaw == sl.fromRaw, onTap: () => _setSlot(sl)),
      if (_slot != null && !_slots.any((x) => x.fromRaw == _slot!.fromRaw))
        AppChip(label: '${dayLabel(_slot!.from).split(',').first}, ${_slot!.range}', selected: true, onTap: () => _otherTime(cartStore?.etaText)),
      AppChip(label: 'Другое время', selected: false, onTap: () => _otherTime(cartStore?.etaText)),
    ];

    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 8, 0),
            child: Row(children: [
              RoundIconButton(icon: Icons.chevron_left_rounded, onTap: () => Navigator.of(context).pop()),
              const Spacer(),
              if (s.cartCount > 0)
                IconButton(tooltip: 'Очистить корзину', icon: const Icon(Icons.delete_rounded, color: AppColors.dark, size: 28), onPressed: _clear),
            ]),
          ),
          const Padding(padding: EdgeInsets.fromLTRB(16, 12, 16, 12), child: Text('Корзина', style: AppText.h1)),
          Expanded(
            child: s.cartCount == 0
                ? EmptyState(
                    icon: Icons.shopping_cart_outlined,
                    title: 'В корзине пусто',
                    text: 'Добавьте товары из каталога магазина рядом.',
                    action: 'В каталог',
                    onAction: () {
                      s.setTab(1);
                      Navigator.of(context).pop();
                    },
                  )
                : RefreshIndicator(
                    onRefresh: _refresh,
                    child: ListView(padding: const EdgeInsets.only(bottom: 24), children: [
                      SizedBox(
                        height: 44,
                        child: ListView.separated(
                          scrollDirection: Axis.horizontal,
                          padding: const EdgeInsets.symmetric(horizontal: 16),
                          itemCount: chips.length,
                          separatorBuilder: (_, __) => const SizedBox(width: 8),
                          itemBuilder: (_, i) => Center(child: chips[i]),
                        ),
                      ),
                      const SizedBox(height: 16),
                      if (p != null && delivery != null)
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 16),
                          child: _DeliveryTerms(
                            subtotal: num.tryParse('${p['subtotal']}') ?? 0,
                            delivery: delivery,
                            onTap: cartStore == null ? null : () => showDeliveryTerms(context, cartStore),
                          ),
                        ),
                      const SizedBox(height: 8),
                      for (final line in s.cart.values)
                        _LineTile(
                          line: line,
                          server: lines[line.product.id] as Map<String, dynamic>?,
                          onChanged: (q) => s.setQty(s.cartStoreId!, s.cartStoreName!, line.product, q),
                        ),
                      if (_error != null)
                        Padding(
                          padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                          child: Text(_error!, style: AppText.small.copyWith(color: AppColors.error)),
                        ),
                      for (final pr in problems.where((x) => x != 'items'))
                        Padding(
                          padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            const Icon(Icons.error_outline_rounded, size: 18, color: AppColors.error),
                            const SizedBox(width: 8),
                            Expanded(child: Text(_problemMessage(pr, delivery), style: AppText.small.copyWith(color: AppColors.error))),
                          ]),
                        ),
                      if (suggest.isNotEmpty && s.cartStoreId != null) ...[
                        const SizedBox(height: 24),
                        const SectionHeader(title: 'Не забудьте'),
                        const SizedBox(height: 12),
                        ProductCarousel(products: suggest, store: (id: s.cartStoreId!, name: s.cartStoreName ?? '')),
                      ],
                    ]),
                  ),
          ),
        ]),
      ),
      bottomNavigationBar: s.cartCount == 0
          ? null
          : BottomActionBar(
              child: AppButton(
                label: p == null ? 'Считаем…' : 'Оформить · ${money(p['total'])}',
                onPressed: p == null ? null : _checkout,
              ),
            ),
    );
  }
}

/// «Условия доставки»: полоска до минимального заказа (или до бесплатной
/// доставки) и цена доставки справа.
class _DeliveryTerms extends StatelessWidget {
  const _DeliveryTerms({required this.subtotal, required this.delivery, this.onTap});
  final num subtotal;
  final Map<String, dynamic> delivery;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final fee = num.tryParse('${delivery['delivery_fee']}') ?? 0;
    final min = num.tryParse('${delivery['min_order_amount'] ?? ''}') ?? 0;
    final freeLeft = num.tryParse('${delivery['free_from'] ?? ''}') ?? 0;
    // Цель полоски: сначала минимальный заказ, потом бесплатная доставка.
    final num target = subtotal < min ? min : (freeLeft > 0 ? subtotal + freeLeft : (min > 0 ? min : subtotal));
    final progress = target <= 0 ? 1.0 : (subtotal / target).clamp(0.0, 1.0).toDouble();
    final left = subtotal < min
        ? '${money(subtotal, suffix: false)} / ${money(min)}'
        : freeLeft > 0
            ? 'Ещё ${money(freeLeft)} до бесплатной'
            : 'Минимальная сумма набрана';
    return Material(
      color: AppColors.soft,
      borderRadius: BorderRadius.circular(AppRadius.xl),
      child: InkWell(
        borderRadius: BorderRadius.circular(AppRadius.xl),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Row(children: [
              const Expanded(child: Text('Условия доставки', style: AppText.title)),
              if (onTap != null) const Icon(Icons.chevron_right_rounded, color: AppColors.text2),
            ]),
            const SizedBox(height: 12),
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(value: progress, minHeight: 6, color: AppColors.dark, backgroundColor: AppColors.line),
            ),
            const SizedBox(height: 8),
            Row(children: [
              Expanded(child: Text(left, style: AppText.small)),
              Text(fee == 0 ? 'Бесплатно' : money(fee), style: AppText.small.copyWith(color: fee == 0 ? AppColors.successInk : null)),
              const SizedBox(width: 6),
              const Icon(Icons.directions_car_filled_rounded, size: 16, color: AppColors.text2),
            ]),
          ]),
        ),
      ),
    );
  }
}

class _LineTile extends StatelessWidget {
  const _LineTile({required this.line, required this.server, required this.onChanged});
  final CartLine line;
  final Map<String, dynamic>? server;
  final void Function(num qty) onChanged;

  @override
  Widget build(BuildContext context) {
    final p = line.product;
    final problem = server?['problem'] as String?;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(children: [
        Container(
          width: 72,
          height: 72,
          decoration: BoxDecoration(color: AppColors.soft, borderRadius: BorderRadius.circular(AppRadius.lg)),
          child: ProductImage(url: p.image, radius: AppRadius.lg, iconSize: 30),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(p.name, maxLines: 2, overflow: TextOverflow.ellipsis, style: AppText.body),
            if (problem != null)
              Text(_problemText[problem] ?? problem, style: AppText.small.copyWith(color: AppColors.error))
            else if (server?['old_price'] != null)
              Text('было ${money(mulMoney('${server!['old_price']}', '${line.qty}'))}',
                  style: AppText.caption.copyWith(color: AppColors.muted, decoration: TextDecoration.lineThrough, decorationColor: AppColors.muted)),
            const SizedBox(height: 2),
            Text(money(mulMoney(p.price, '${line.qty}')), style: AppText.price),
          ]),
        ),
        const SizedBox(width: 8),
        QtyStepper(
          label: qty(line.qty),
          height: 40,
          soft: true,
          onMinus: () => onChanged(line.qty - p.step),
          onPlus: () => onChanged(line.qty + p.step),
        ),
      ]),
    );
  }
}

/// «Оформление заказа» (Figma «09 Оформление»): время, адрес, комментарий,
/// оплата, итог и кнопка «Заказать». Возвращает выбранное окно в корзину.
class CheckoutScreen extends StatefulWidget {
  const CheckoutScreen({super.key, this.slot});
  final Slot? slot;

  @override
  State<CheckoutScreen> createState() => _CheckoutScreenState();
}

class _CheckoutScreenState extends State<CheckoutScreen> {
  late Slot? _slot = widget.slot;
  Map<String, dynamic>? _preview;
  String? _error;
  bool _busy = false;
  String _provider = 'payme';
  final _comment = TextEditingController();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _refresh());
  }

  @override
  void dispose() {
    _comment.dispose();
    super.dispose();
  }

  Map<String, dynamic> _body(AppState s) => _orderBody(s, provider: _provider, comment: _comment.text.trim(), slot: _slot);

  Future<void> _refresh() async {
    final s = context.read<AppState>();
    if (s.cartCount == 0 || s.address == null) return;
    setState(() => _error = null);
    try {
      final p = await context.read<Api>().post('/client/checkout/preview', _body(s)) as Map<String, dynamic>;
      if (mounted) setState(() => _preview = p);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  Future<void> _order() async {
    final s = context.read<AppState>();
    final api = context.read<Api>();
    setState(() => _busy = true);
    try {
      final res = await api.post('/client/orders', _body(s)) as Map<String, dynamic>;
      final order = res['order'] as Map<String, dynamic>;
      final url = res['payment_url'] as String?;
      final requestId = s.familyRequestId;
      s.clearCart();
      if (requestId != null) {
        // Просьба семьи выполнена заказом — автору уйдёт уведомление.
        api.post('/client/family/requests/$requestId/ordered', {'order_id': order['id']}).catchError((_) => null);
      }
      if (!mounted) return;
      final nav = Navigator.of(context);
      nav.pop(); // оформление
      nav.pushReplacement(MaterialPageRoute(builder: (_) => PaymentScreen(order: order))); // корзина → оплата
      if (url != null) {
        try {
          await openUrl(url);
        } catch (_) {
          // Страница оплаты откроется кнопкой на экране оплаты.
        }
      }
    } on ApiError catch (e) {
      if (mounted) showError(context, e);
      await _refresh();
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _changeAddress() async {
    final s = context.read<AppState>();
    if (s.cartStoreId == null) return;
    await pickDeliveryAddress(context, storeId: s.cartStoreId!, storeName: s.cartStoreName ?? 'Магазин');
    if (mounted) _refresh();
  }

  Future<void> _changeTime(String? eta) async {
    final s = context.read<AppState>();
    if (s.cartStoreId == null) return;
    final choice = await pickDeliveryTime(context, storeId: s.cartStoreId!, eta: eta, current: _slot);
    if (choice == null || !mounted) return;
    setState(() => _slot = choice.slot);
    _refresh();
  }

  @override
  Widget build(BuildContext context) {
    final s = context.watch<AppState>();
    final p = _preview;
    final delivery = p?['delivery'] as Map<String, dynamic>?;
    final fee = num.tryParse('${delivery?['delivery_fee']}') ?? 0;
    final discount = num.tryParse('${p?['discount'] ?? ''}') ?? 0;
    final problems = ((p?['problems'] as List?) ?? const []).cast<String>();
    final cartStore = s.stores.where((x) => x.id == s.cartStoreId).firstOrNull;
    final a = s.address;
    final timeTitle = _slot == null
        ? (cartStore?.etaText == null ? 'Как можно скорее' : 'Как можно скорее · ${cartStore!.etaText}')
        : '${dayLabel(_slot!.from).split(',').first}, ${_slot!.range}';

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) Navigator.of(context).pop(_slot);
      },
      child: Scaffold(
        body: SafeArea(
          bottom: false,
          child: ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 24), children: [
            Align(
              alignment: Alignment.centerLeft,
              child: RoundIconButton(icon: Icons.chevron_left_rounded, onTap: () => Navigator.of(context).pop(_slot)),
            ),
            const SizedBox(height: 12),
            const Text('Оформление\nзаказа', style: AppText.h1),
            const SizedBox(height: 16),
            _Card(
              icon: Icons.directions_car_filled_rounded,
              title: timeTitle,
              subtitle: 'Доставка · ${fee == 0 ? 'бесплатно' : money(fee)}',
              onTap: () => _changeTime(cartStore?.etaText),
            ),
            const SizedBox(height: 24),
            const Text('Адрес доставки', style: AppText.h3),
            const SizedBox(height: 12),
            _Card(
              icon: Icons.location_on_rounded,
              title: a?.title ?? 'Выберите адрес',
              subtitle: a != null && a.label.isNotEmpty ? a.address : null,
              onTap: _changeAddress,
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _comment,
              maxLines: null,
              decoration: InputDecoration(
                hintText: 'Комментарий курьеру: подъезд, этаж, позвонить заранее',
                filled: true,
                fillColor: AppColors.soft,
                prefixIcon: const Icon(Icons.chat_bubble_outline_rounded, color: AppColors.text2),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(AppRadius.lg), borderSide: BorderSide.none),
              ),
            ),
            const SizedBox(height: 24),
            const Text('Способ оплаты', style: AppText.h3),
            const SizedBox(height: 12),
            Row(children: [
              Expanded(child: _PayOption(title: 'Payme', color: const Color(0xFF33CCCC), selected: _provider == 'payme', onTap: () => setState(() => _provider = 'payme'))),
              const SizedBox(width: 12),
              Expanded(child: _PayOption(title: 'Click', color: const Color(0xFF0073E6), selected: _provider == 'click', onTap: () => setState(() => _provider = 'click'))),
            ]),
            const SizedBox(height: 24),
            const Text('Итого', style: AppText.h3),
            const SizedBox(height: 12),
            if (_error != null)
              Padding(padding: const EdgeInsets.only(bottom: 12), child: Text(_error!, style: AppText.small.copyWith(color: AppColors.error))),
            if (p == null)
              const Padding(padding: EdgeInsets.all(24), child: Center(child: CircularProgressIndicator()))
            else
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(color: AppColors.soft, borderRadius: BorderRadius.circular(AppRadius.xl)),
                child: Column(children: [
                  _row('Товары', money(discount > 0 ? addMoney(['${p['subtotal']}', '${p['discount']}']) : p['subtotal'])),
                  if (discount > 0) _row('Скидка', '−${money(discount)}', valueColor: AppColors.primary),
                  _row('Доставка', fee == 0 ? 'Бесплатно' : money(fee), valueColor: fee == 0 ? AppColors.successInk : null),
                  const Padding(padding: EdgeInsets.symmetric(vertical: 8), child: Divider(color: AppColors.line)),
                  _row('К оплате', money(p['total']), bold: true),
                  for (final pr in problems)
                    Padding(
                      padding: const EdgeInsets.only(top: 12),
                      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        const Icon(Icons.error_outline_rounded, size: 18, color: AppColors.error),
                        const SizedBox(width: 8),
                        Expanded(child: Text(_problemMessage(pr, delivery), style: AppText.small.copyWith(color: AppColors.error))),
                      ]),
                    ),
                ]),
              ),
          ]),
        ),
        bottomNavigationBar: BottomActionBar(
          child: AppButton(
            label: p == null ? 'Считаем…' : 'Заказать · ${money(p['total'])}',
            loading: _busy,
            onPressed: p == null || p['can_order'] != true ? null : _order,
          ),
        ),
      ),
    );
  }

  Widget _row(String label, String value, {bool bold = false, Color? valueColor}) {
    final l = bold ? AppText.title : AppText.body.copyWith(color: AppColors.text2);
    final v = bold ? AppText.title : AppText.bodyMedium.copyWith(color: valueColor);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(children: [Expanded(child: Text(label, style: l)), Text(value, style: v)]),
    );
  }
}

/// Белая карточка с тенью: иконка, заголовок, подпись, шеврон.
class _Card extends StatelessWidget {
  const _Card({required this.icon, required this.title, this.subtitle, required this.onTap});
  final IconData icon;
  final String title;
  final String? subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppColors.white,
      elevation: 3,
      shadowColor: const Color(0x22000000),
      borderRadius: BorderRadius.circular(AppRadius.xl),
      child: InkWell(
        borderRadius: BorderRadius.circular(AppRadius.xl),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
          child: Row(children: [
            Icon(icon, color: AppColors.dark, size: 28),
            const SizedBox(width: 14),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(title, maxLines: 2, overflow: TextOverflow.ellipsis, style: AppText.bodyStrong.copyWith(fontSize: 16)),
                if (subtitle != null) ...[const SizedBox(height: 2), Text(subtitle!, style: AppText.small)],
              ]),
            ),
            const Icon(Icons.chevron_right_rounded, color: AppColors.text2),
          ]),
        ),
      ),
    );
  }
}

/// Плитка оплаты: логотип-иконка сверху, название, галочка у выбранной.
class _PayOption extends StatelessWidget {
  const _PayOption({required this.title, required this.color, required this.selected, required this.onTap});
  final String title;
  final Color color;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppColors.white,
      elevation: selected ? 0 : 3,
      shadowColor: const Color(0x22000000),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.xl),
        side: selected ? const BorderSide(color: AppColors.primary, width: 2) : BorderSide.none,
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(AppRadius.xl),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              IconBox(Icons.credit_card_rounded, size: 36, bg: color, fg: AppColors.white, radius: 10),
              const Spacer(),
              if (selected) const Icon(Icons.check_circle_rounded, color: AppColors.primary),
            ]),
            const SizedBox(height: 12),
            Text(title, style: AppText.bodyStrong),
          ]),
        ),
      ),
    );
  }
}
