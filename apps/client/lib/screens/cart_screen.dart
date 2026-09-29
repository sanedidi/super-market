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

/// Корзина на весь экран: товары, доставка, оплата, итог. Пересчёт — на сервере.
class CartScreen extends StatefulWidget {
  const CartScreen({super.key});

  @override
  State<CartScreen> createState() => _CartScreenState();
}

class _CartScreenState extends State<CartScreen> {
  Map<String, dynamic>? _preview;
  String? _error;
  bool _busy = false;
  String _provider = 'payme';

  /// Окно доставки; null — как можно скорее.
  Slot? _slot;
  final _comment = TextEditingController();

  /// «Не забудьте»: что покупают вместе с товарами корзины.
  List<Product> _suggest = const [];

  /// Состав корзины при последнем пересчёте — пересчитываем, когда он меняется.
  String? _sig;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _refresh();
      _loadSuggest();
    });
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

  @override
  void dispose() {
    _comment.dispose();
    super.dispose();
  }

  Map<String, dynamic> _body(AppState s) => {
        'store_id': s.cartStoreId,
        'address_id': s.address?.id,
        'items': s.cartItems,
        'payment_provider': _provider,
        'comment': _comment.text.trim(),
        'delivery_from': _slot?.fromRaw,
      };

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
    setState(() => _busy = true);
    try {
      final res = await context.read<Api>().post('/client/orders', _body(s)) as Map<String, dynamic>;
      final order = res['order'] as Map<String, dynamic>;
      final url = res['payment_url'] as String?;
      s.clearCart();
      if (!mounted) return;
      Navigator.of(context).pushReplacement(MaterialPageRoute(builder: (_) => PaymentScreen(order: order)));
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
    final lines = {for (final l in (p?['lines'] as List? ?? const [])) (l as Map<String, dynamic>)['product_id']: l};
    final problems = ((p?['problems'] as List?) ?? const []).cast<String>();
    final delivery = p?['delivery'] as Map<String, dynamic>?;
    final fee = num.tryParse('${delivery?['delivery_fee']}') ?? 0;
    final freeLeft = num.tryParse('${delivery?['free_from'] ?? ''}') ?? 0;
    final discount = num.tryParse('${p?['discount'] ?? ''}') ?? 0;
    final suggest = _suggest.where((x) => !s.cart.containsKey(x.id)).take(10).toList();
    final cartStore = s.stores.where((x) => x.id == s.cartStoreId).firstOrNull;
    final sig = s.cartItems.toString();
    if (_sig != null && sig != _sig && s.cartCount > 0) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _refresh();
      });
    }
    _sig = sig;

    return Scaffold(
      backgroundColor: AppColors.bg,
      body: SafeArea(
        bottom: false,
        child: Column(children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
            child: Row(children: [
              RoundIconButton(icon: Icons.close_rounded, bg: AppColors.white, onTap: () => Navigator.of(context).pop()),
              const SizedBox(width: 12),
              const Text('Корзина', style: AppText.h2),
              const SizedBox(width: 8),
              Expanded(
                child: s.cartCount > 0
                    ? Text(itemsWord(s.cartCount), maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.small.copyWith(fontSize: 15))
                    : const SizedBox(),
              ),
              if (s.cartCount > 0)
                TextButton(
                  style: TextButton.styleFrom(foregroundColor: AppColors.text2),
                  onPressed: () {
                    s.clearCart();
                    Navigator.of(context).pop();
                  },
                  child: const Text('Очистить'),
                ),
            ]),
          ),
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
                    child: ListView(
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                      children: [
                        // Магазин и товары.
                        AppCard(
                          padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
                          child: Column(children: [
                            Row(children: [
                              StoreLogo(name: s.cartStoreName ?? '', url: cartStore?.logoUrl, size: 36),
                              const SizedBox(width: 12),
                              Expanded(child: Text(s.cartStoreName ?? '', style: AppText.bodyStrong)),
                            ]),
                            if (delivery != null) ...[
                              const SizedBox(height: 12),
                              _DeliveryHint(fee: fee, freeLeft: freeLeft),
                            ],
                            const SizedBox(height: 4),
                            for (final line in s.cart.values)
                              _LineTile(
                                line: line,
                                server: lines[line.product.id] as Map<String, dynamic>?,
                                onChanged: (q) => s.setQty(s.cartStoreId!, s.cartStoreName!, line.product, q),
                              ),
                          ]),
                        ),
                        if (suggest.isNotEmpty && s.cartStoreId != null) ...[
                          const SizedBox(height: 24),
                          const SectionHeader(title: 'Не забудьте', padding: EdgeInsets.zero),
                          const SizedBox(height: 12),
                          ProductCarousel(products: suggest, store: (id: s.cartStoreId!, name: s.cartStoreName ?? ''), padding: EdgeInsets.zero),
                        ],
                        const SizedBox(height: 16),
                        // Доставка.
                        AppCard(
                          padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
                          child: Column(children: [
                            AppListRow(
                              icon: Icons.location_on_outlined,
                              title: s.address?.title ?? 'Выберите адрес',
                              subtitle: s.address?.label.isNotEmpty == true ? s.address!.address : null,
                              onTap: _changeAddress,
                            ),
                            AppListRow(
                              icon: Icons.schedule_rounded,
                              title: _slot == null ? 'Как можно скорее' : '${dayLabel(_slot!.from).split(',').first}, ${_slot!.range}',
                              subtitle: _slot == null
                                  ? (cartStore?.etaText == null ? 'Магазин соберёт и привезёт заказ' : 'Привезём за ${cartStore!.etaText}')
                                  : 'Доставка ко времени',
                              onTap: () => _changeTime(cartStore?.etaText),
                            ),
                            Padding(
                              padding: const EdgeInsets.symmetric(vertical: 12),
                              child: TextField(
                                controller: _comment,
                                maxLines: null,
                                decoration: const InputDecoration(
                                  hintText: 'Комментарий курьеру: например, позвоните за 5 минут',
                                  prefixIcon: Icon(Icons.chat_bubble_outline_rounded, color: AppColors.text2),
                                ),
                              ),
                            ),
                          ]),
                        ),
                        const SizedBox(height: 24),
                        const Text('Способ оплаты', style: AppText.title),
                        const SizedBox(height: 12),
                        Row(children: [
                          Expanded(child: _PayOption(title: 'Payme', color: const Color(0xFF33CCCC), selected: _provider == 'payme', onTap: () => setState(() => _provider = 'payme'))),
                          const SizedBox(width: 12),
                          Expanded(child: _PayOption(title: 'Click', color: const Color(0xFF0073E6), selected: _provider == 'click', onTap: () => setState(() => _provider = 'click'))),
                        ]),
                        const SizedBox(height: 24),
                        if (_error != null)
                          Padding(padding: const EdgeInsets.only(bottom: 12), child: Text(_error!, style: AppText.small.copyWith(color: AppColors.error))),
                        if (p != null)
                          AppCard(
                            child: Column(children: [
                              _row('Товары (${s.cartCount})', money(discount > 0 ? addMoney(['${p['subtotal']}', '${p['discount']}']) : p['subtotal'])),
                              if (discount > 0) _row('Скидка', '−${money(discount)}', valueColor: AppColors.accent),
                              _row('Доставка', fee == 0 ? 'Бесплатно' : money(fee), valueColor: fee == 0 ? AppColors.success : null),
                              const Padding(padding: EdgeInsets.symmetric(vertical: 8), child: Divider()),
                              _row('Итого', money(p['total']), bold: true),
                              for (final pr in problems)
                                Padding(
                                  padding: const EdgeInsets.only(top: 12),
                                  child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                                    const Icon(Icons.error_outline_rounded, size: 18, color: AppColors.error),
                                    const SizedBox(width: 8),
                                    Expanded(
                                      child: Text(
                                        pr == 'min_order_amount' && delivery != null
                                            ? 'Минимальный заказ — ${money(delivery['min_order_amount'])}'
                                            : (_orderProblemText[pr] ?? pr),
                                        style: AppText.small.copyWith(color: AppColors.error),
                                      ),
                                    ),
                                  ]),
                                ),
                            ]),
                          ),
                      ],
                    ),
                  ),
          ),
        ]),
      ),
      bottomNavigationBar: s.cartCount == 0
          ? null
          : BottomActionBar(
              child: AppButton(
                label: p == null ? 'Считаем…' : 'Оформить заказ · ${money(p['total'])}',
                loading: _busy,
                onPressed: p == null || p['can_order'] != true ? null : _order,
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

/// «Доставка бесплатная» или «Ещё N сум до бесплатной доставки».
class _DeliveryHint extends StatelessWidget {
  const _DeliveryHint({required this.fee, required this.freeLeft});
  final num fee;
  final num freeLeft;

  @override
  Widget build(BuildContext context) {
    final free = fee == 0;
    if (!free && freeLeft <= 0) return const SizedBox.shrink();
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(color: free ? AppColors.successSoft : AppColors.accentSoft, borderRadius: BorderRadius.circular(AppRadius.md)),
      child: Row(children: [
        Icon(free ? Icons.check_circle_outline_rounded : Icons.local_shipping_outlined, size: 18, color: free ? AppColors.successInk : AppColors.warningInk),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            free ? 'Доставка бесплатная' : 'Ещё ${money(freeLeft)} до бесплатной доставки',
            style: AppText.small.copyWith(color: free ? AppColors.successInk : AppColors.warningInk, fontWeight: FontWeight.w500),
          ),
        ),
      ]),
    );
  }
}

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
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.lg),
        side: BorderSide(color: selected ? AppColors.primary : AppColors.line, width: selected ? 2 : 1),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(AppRadius.lg),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(children: [
            IconBox(Icons.credit_card_rounded, size: 32, bg: color, fg: AppColors.white, radius: 8),
            const SizedBox(width: 10),
            Expanded(child: Text(title, style: AppText.bodyStrong)),
            Icon(selected ? Icons.radio_button_checked_rounded : Icons.radio_button_off_rounded, color: selected ? AppColors.primary : AppColors.muted),
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
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 12),
      decoration: const BoxDecoration(border: Border(top: BorderSide(color: AppColors.line))),
      child: Row(children: [
        SizedBox(width: 64, height: 64, child: ProductImage(url: p.image, radius: AppRadius.md, iconSize: 28)),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(p.name, maxLines: 2, overflow: TextOverflow.ellipsis, style: AppText.bodyMedium),
            const SizedBox(height: 2),
            Text(
              problem != null ? (_problemText[problem] ?? problem) : '${money(p.price)} за 1 ${p.unit}',
              style: AppText.small.copyWith(color: problem != null ? AppColors.error : null),
            ),
            if (problem == null && server?['old_price'] != null)
              Text('было ${money(server!['old_price'])}',
                  style: AppText.caption.copyWith(color: AppColors.muted, decoration: TextDecoration.lineThrough, decorationColor: AppColors.muted)),
            const SizedBox(height: 4),
            Text(money(mulMoney(p.price, '${line.qty}')), style: AppText.price),
          ]),
        ),
        const SizedBox(width: 8),
        QtyStepper(
          label: qty(line.qty),
          height: 36,
          onMinus: () => onChanged(line.qty - p.step),
          onPlus: () => onChanged(line.qty + p.step),
        ),
      ]),
    );
  }
}
