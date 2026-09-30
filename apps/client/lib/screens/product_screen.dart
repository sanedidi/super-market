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
      backgroundColor: AppColors.white,
      body: CustomScrollView(slivers: [
        SliverToBoxAdapter(child: _gallery(fav)),
        SliverToBoxAdapter(
          child: Container(
            decoration: const BoxDecoration(
              color: AppColors.white,
              borderRadius: BorderRadius.vertical(top: Radius.circular(AppRadius.sheet)),
              boxShadow: [BoxShadow(color: Color(0x10000000), blurRadius: 16, offset: Offset(0, -4))],
            ),
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Center(
                child: Container(width: 40, height: 5, decoration: BoxDecoration(color: AppColors.line, borderRadius: BorderRadius.circular(3))),
              ),
              const SizedBox(height: 20),
              Text.rich(
                TextSpan(children: [
                  TextSpan(text: _p.name, style: AppText.h2.copyWith(fontSize: 26, height: 1.25)),
                  TextSpan(text: '  1 ${_p.unit}', style: AppText.h2.copyWith(fontSize: 26, height: 1.25, color: AppColors.muted)),
                ]),
              ),
              if (subtitle.isNotEmpty) ...[const SizedBox(height: 6), Text(subtitle, style: AppText.body.copyWith(color: AppColors.text2))],
              if (_p.description.trim().isNotEmpty) ...[
                const SizedBox(height: 12),
                Text(_p.description, style: AppText.body.copyWith(fontSize: 17, color: AppColors.text2)),
              ],
              const SizedBox(height: 12),
              Wrap(spacing: 8, runSpacing: 8, children: [
                if (_p.isNew) const AppBadge(label: 'Новинка', kind: BadgeKind.isNew),
                available > 0
                    ? const AppBadge(label: 'В наличии', kind: BadgeKind.success)
                    : const AppBadge(label: 'Нет в наличии', kind: BadgeKind.error),
              ]),
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
            child: Padding(
              padding: const EdgeInsets.only(bottom: 24),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const SectionHeader(title: 'Может что-то ещё?'),
                const SizedBox(height: 12),
                ProductCarousel(products: _related, store: _store),
              ]),
            ),
          ),
        const SliverToBoxAdapter(child: SizedBox(height: 24)),
      ]),
      bottomNavigationBar: BottomActionBar(child: _actions(state, available)),
    );
  }

  Widget _gallery(bool fav) {
    final images = _p.images;
    final discount = discountLabel(_p);
    return SizedBox(
      height: 330,
      child: Stack(children: [
        Positioned.fill(
          top: 16,
          bottom: 36,
          right: discount != null ? MediaQuery.sizeOf(context).width * 0.42 : 0,
          child: images.isEmpty
              ? const Padding(padding: EdgeInsets.symmetric(horizontal: 48), child: ProductImage(iconSize: 72))
              : PageView.builder(
                  controller: _page,
                  itemCount: images.length,
                  onPageChanged: (i) => setState(() => _photo = i),
                  itemBuilder: (_, i) => Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 32),
                    child: ProductImage(url: images[i], radius: 0, iconSize: 72),
                  ),
                ),
        ),
        if (images.length > 1)
          Positioned(
            left: 0,
            right: discount != null ? MediaQuery.sizeOf(context).width * 0.42 : 0,
            bottom: 8,
            child: Center(
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                decoration: BoxDecoration(color: AppColors.soft, borderRadius: BorderRadius.circular(12)),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  for (var i = 0; i < images.length; i++)
                    Container(
                      margin: const EdgeInsets.symmetric(horizontal: 3),
                      width: 7,
                      height: 7,
                      decoration: BoxDecoration(color: i == _photo ? AppColors.ink : AppColors.muted, shape: BoxShape.circle),
                    ),
                ]),
              ),
            ),
          ),
        if (discount != null)
          Positioned(
            right: 20,
            top: 64,
            child: Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
                decoration: BoxDecoration(color: AppColors.primary, borderRadius: BorderRadius.circular(8)),
                child: Text('АКЦИЯ', style: AppText.title.copyWith(color: AppColors.white, fontWeight: FontWeight.w800)),
              ),
              const SizedBox(height: 10),
              Transform.rotate(
                angle: -0.05,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                  decoration: BoxDecoration(color: AppColors.accent, borderRadius: BorderRadius.circular(10)),
                  child: Text(discount, style: AppText.h2.copyWith(fontSize: 26)),
                ),
              ),
              const SizedBox(height: 10),
              if (_p.oldPrice != null)
                Text(money(_p.oldPrice, suffix: false),
                    style: AppText.h3.copyWith(fontSize: 22, decoration: TextDecoration.lineThrough, decorationThickness: 2)),
              Text(money(_p.price, suffix: false), style: AppText.h1.copyWith(fontSize: 44, color: AppColors.primary, fontWeight: FontWeight.w800)),
            ]),
          ),
        Positioned(
          top: 12,
          right: 16,
          child: Row(children: [
            RoundIconButton(
              icon: fav ? Icons.favorite_rounded : Icons.favorite_border_rounded,
              iconColor: fav ? AppColors.primary : AppColors.ink,
              bg: AppColors.white,
              shadow: true,
              onTap: _favorite,
            ),
            const SizedBox(width: 10),
            RoundIconButton(icon: Icons.close_rounded, bg: AppColors.white, shadow: true, onTap: () => Navigator.of(context).pop()),
          ]),
        ),
      ]),
    );
  }

  Widget _actions(AppState state, num available) {
    final inCart = state.cartStoreId == _store.id ? state.qtyOf(_p.id) : 0;
    if (available <= 0 && inCart == 0) return const AppButton(label: 'Нет в наличии', onPressed: null);
    if (inCart == 0) {
      return AppButton(
        label: money(_p.price),
        subtitle: '${money(_p.price, suffix: false)} / ${_p.unit}',
        onPressed: () => _change(_p.step),
      );
    }
    return Row(children: [
      QtyStepper(label: qty(inCart, _p.unit), height: 56, filled: false, onMinus: () => _change(inCart - _p.step), onPlus: () => _change(inCart + _p.step)),
      const SizedBox(width: 12),
      Expanded(
        child: AppButton(
          label: 'Корзина',
          subtitle: money(state.cartTotal),
          onPressed: () {
            final nav = Navigator.of(context, rootNavigator: true);
            nav.pop();
            pushCart(nav);
          },
        ),
      ),
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
      color: AppColors.soft,
      borderRadius: BorderRadius.circular(AppRadius.xl),
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
