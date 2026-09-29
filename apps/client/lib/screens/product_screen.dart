import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:sm_core/sm_core.dart';

import '../cart_actions.dart';
import '../main.dart';
import '../product_tile.dart';
import '../state.dart';
import '../ui/theme.dart';
import '../ui/widgets.dart';
import 'root_shell.dart';

/// Карточка товара: фото, цена со скидкой, магазин, пищевая ценность,
/// описание и характеристики, «С этим покупают», количество внизу.
class ProductScreen extends StatefulWidget {
  const ProductScreen({super.key, required this.store, required this.product});
  final StoreRef store;

  /// Товар из списка — показываем сразу, пока грузится полная карточка.
  final Product product;

  @override
  State<ProductScreen> createState() => _ProductScreenState();
}

class _ProductScreenState extends State<ProductScreen> {
  late Product _p = widget.product;
  List<Product> _related = const [];
  final _page = PageController();
  int _photo = 0;

  StoreRef get _store => widget.store;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  @override
  void dispose() {
    _page.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final api = context.read<Api>();
    final base = '/client/stores/${_store.id}/products/${widget.product.id}';
    try {
      final j = await api.get(base) as Map<String, dynamic>;
      if (mounted) setState(() => _p = Product(j));
    } catch (e) {
      if (mounted) showError(context, e);
    }
    try {
      final items = await api.list('$base/related');
      if (mounted) setState(() => _related = items.map(Product.new).toList());
    } catch (_) {
      // Рекомендации не обязательны.
    }
  }

  Future<void> _favorite() async {
    try {
      await context.read<AppState>().toggleFavorite(_p.id);
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Future<void> _change(num q) async {
    try {
      await changeQty(context, storeId: _store.id, storeName: _store.name, product: _p, qty: q);
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Map<String, dynamic> get _attrs => (_p.json['attributes'] as Map<String, dynamic>?) ?? const {};

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final fav = state.isFavorite(_p.id);
    final store = state.stores.where((s) => s.id == _store.id).firstOrNull;
    final attrs = _attrs;
    final subtitle = [_p.brand, attrs['volume']].whereType<String>().where((s) => s.isNotEmpty).join(' · ');
    final nutrition = (attrs['nutrition'] as Map<String, dynamic>?) ?? const {};
    final details = <(String, String)>[
      for (final (k, label) in const [
        ('composition', 'Состав'),
        ('shelf_life', 'Срок хранения'),
        ('storage', 'Хранение'),
        ('manufacturer', 'Производитель'),
        ('country', 'Страна'),
      ])
        if ('${attrs[k] ?? ''}'.trim().isNotEmpty) (label, '${attrs[k]}'),
    ];
    final available = num.tryParse(_p.available) ?? 0;

    return Scaffold(
      backgroundColor: AppColors.bg,
      body: CustomScrollView(slivers: [
        SliverToBoxAdapter(child: _gallery(fav)),
        SliverToBoxAdapter(
          child: Container(
            decoration: const BoxDecoration(
              color: AppColors.white,
              borderRadius: BorderRadius.vertical(top: Radius.circular(AppRadius.sheet)),
            ),
            padding: const EdgeInsets.fromLTRB(16, 20, 16, 24),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Wrap(spacing: 8, runSpacing: 8, children: [
                if (discountLabel(_p) != null) AppBadge(label: discountLabel(_p)!, kind: BadgeKind.discount),
                if (_p.isNew) const AppBadge(label: 'Новинка', kind: BadgeKind.isNew),
                available > 0
                    ? const AppBadge(label: 'В наличии', kind: BadgeKind.success)
                    : const AppBadge(label: 'Нет в наличии', kind: BadgeKind.error),
              ]),
              const SizedBox(height: 12),
              Text(_p.name, style: AppText.h2),
              if (subtitle.isNotEmpty) ...[const SizedBox(height: 4), Text(subtitle, style: AppText.small.copyWith(fontSize: 15))],
              const SizedBox(height: 12),
              Wrap(crossAxisAlignment: WrapCrossAlignment.end, spacing: 10, children: [
                Text(money(_p.price), style: AppText.h2.copyWith(fontSize: 26)),
                if (_p.oldPrice != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 3),
                    child: Text(money(_p.oldPrice),
                        style: AppText.body.copyWith(color: AppColors.muted, decoration: TextDecoration.lineThrough, decorationColor: AppColors.muted)),
                  ),
              ]),
              const SizedBox(height: 4),
              Text('за 1 ${_p.unit}', style: AppText.caption),
              const SizedBox(height: 20),
              _StoreRow(name: _store.name, logoUrl: store?.logoUrl, eta: store?.etaText, onTap: store == null ? null : () {
                state.openCatalog(store);
                Navigator.of(context).popUntil((r) => r.isFirst);
              }),
              if (nutrition.isNotEmpty) ...[
                const SizedBox(height: 24),
                const Text('Пищевая ценность на 100 г', style: AppText.title),
                const SizedBox(height: 12),
                Row(children: [
                  for (final (k, label, unit) in const [('kcal', 'ккал', ''), ('protein', 'белки', ' г'), ('fat', 'жиры', ' г'), ('carbs', 'углеводы', ' г')]) ...[
                    if (k != 'kcal') const SizedBox(width: 8),
                    Expanded(child: _Nutrient(value: nutrition[k] == null ? '—' : '${qty(nutrition[k])}$unit', label: label)),
                  ],
                ]),
              ],
              if (_p.description.trim().isNotEmpty) ...[
                const SizedBox(height: 24),
                const Text('Описание', style: AppText.title),
                const SizedBox(height: 8),
                Text(_p.description, style: AppText.body.copyWith(color: AppColors.text2)),
              ],
              if (details.isNotEmpty) ...[
                const SizedBox(height: 16),
                for (final (label, value) in details)
                  Container(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: AppColors.line))),
                    child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      SizedBox(width: 130, child: Text(label, style: AppText.small.copyWith(fontSize: 14))),
                      const SizedBox(width: 12),
                      Expanded(child: Text(value, textAlign: TextAlign.right, style: AppText.bodyMedium.copyWith(fontSize: 14))),
                    ]),
                  ),
              ],
            ]),
          ),
        ),
        if (_related.isNotEmpty)
          SliverToBoxAdapter(
            child: Container(
              color: AppColors.white,
              padding: const EdgeInsets.only(bottom: 24),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const SectionHeader(title: 'С этим покупают'),
                const SizedBox(height: 12),
                ProductCarousel(products: _related, store: _store),
              ]),
            ),
          ),
        const SliverFillRemaining(hasScrollBody: false, child: ColoredBox(color: AppColors.white)),
      ]),
      bottomNavigationBar: BottomActionBar(child: _actions(state, available)),
    );
  }

  Widget _gallery(bool fav) {
    final images = _p.images;
    final top = MediaQuery.paddingOf(context).top;
    return SizedBox(
      height: top + 320,
      child: Stack(children: [
        Positioned.fill(
          top: top + 56,
          bottom: 28,
          child: images.isEmpty
              ? const ProductImage(radius: 0, iconSize: 72)
              : PageView.builder(
                  controller: _page,
                  itemCount: images.length,
                  onPageChanged: (i) => setState(() => _photo = i),
                  itemBuilder: (_, i) => Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 48),
                    child: ProductImage(url: images[i], radius: AppRadius.lg, iconSize: 72),
                  ),
                ),
        ),
        if (images.length > 1)
          Positioned(
            left: 0,
            right: 0,
            bottom: 10,
            child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
              for (var i = 0; i < images.length; i++)
                AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  margin: const EdgeInsets.symmetric(horizontal: 3),
                  width: i == _photo ? 18 : 6,
                  height: 6,
                  decoration: BoxDecoration(color: i == _photo ? AppColors.primary : AppColors.line, borderRadius: BorderRadius.circular(3)),
                ),
            ]),
          ),
        Positioned(
          top: top + 8,
          left: 16,
          right: 16,
          child: Row(children: [
            RoundIconButton(icon: Icons.arrow_back_rounded, bg: AppColors.white, shadow: true, onTap: () => Navigator.of(context).pop()),
            const Spacer(),
            RoundIconButton(
              icon: fav ? Icons.favorite_rounded : Icons.favorite_border_rounded,
              bg: AppColors.white,
              shadow: true,
              onTap: _favorite,
            ),
          ]),
        ),
      ]),
    );
  }

  Widget _actions(AppState state, num available) {
    final inCart = state.cartStoreId == _store.id ? state.qtyOf(_p.id) : 0;
    if (available <= 0 && inCart == 0) return const AppButton(label: 'Нет в наличии', onPressed: null);
    if (inCart == 0) {
      return AppButton(label: 'В корзину · ${money(_p.price)}', icon: Icons.add_rounded, onPressed: () => _change(_p.step));
    }
    return Row(children: [
      QtyStepper(label: qty(inCart), height: 52, onMinus: () => _change(inCart - _p.step), onPlus: () => _change(inCart + _p.step)),
      const SizedBox(width: 12),
      Expanded(child: AppButton(label: 'В корзине · ${money(mulMoney(_p.price, '$inCart'))}', onPressed: () => openCart(context))),
    ]);
  }
}

class _StoreRow extends StatelessWidget {
  const _StoreRow({required this.name, this.logoUrl, this.eta, this.onTap});
  final String name;
  final String? logoUrl;
  final String? eta;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppColors.primarySoft,
      borderRadius: BorderRadius.circular(AppRadius.lg),
      child: InkWell(
        borderRadius: BorderRadius.circular(AppRadius.lg),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(children: [
            StoreLogo(name: name, url: logoUrl, size: 40),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(name, maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.bodyStrong),
                if (eta != null) ...[
                  const SizedBox(height: 2),
                  Row(children: [
                    const Icon(Icons.schedule_rounded, size: 14, color: AppColors.text2),
                    const SizedBox(width: 4),
                    Text('Привезём за $eta', style: AppText.small),
                  ]),
                ],
              ]),
            ),
            if (onTap != null) const Icon(Icons.chevron_right_rounded, color: AppColors.ink),
          ]),
        ),
      ),
    );
  }
}

class _Nutrient extends StatelessWidget {
  const _Nutrient({required this.value, required this.label});
  final String value;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 12),
      decoration: BoxDecoration(color: AppColors.soft, borderRadius: BorderRadius.circular(AppRadius.md)),
      child: Column(children: [
        FittedBox(child: Text(value, style: AppText.bodyStrong)),
        const SizedBox(height: 2),
        Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.caption),
      ]),
    );
  }
}
