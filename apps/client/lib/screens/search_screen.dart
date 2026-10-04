import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:sm_core/sm_core.dart';

import '../cart_actions.dart';
import '../main.dart';
import '../product_tile.dart';
import '../state.dart';
import '../ui/theme.dart';
import '../ui/widgets.dart';

/// Открыть поиск по всем магазинам рядом.
Future<void> openSearch(BuildContext context, {String query = ''}) {
  return Navigator.of(context).push(MaterialPageRoute(builder: (_) => SearchScreen(query: query)));
}

/// Товар в одном магазине из /client/search.
class SearchOffer {
  SearchOffer(this.json);
  final Map<String, dynamic> json;

  String get storeId => json['store_id'] as String;
  String get storeName => (json['store_name'] as String?) ?? '';
  bool get delivers => json['delivers'] == true;
  int get distanceM => (json['distance_m'] as num?)?.toInt() ?? 0;
  String get price => '${json['price']}';
  int? get etaMin => (json['eta_min'] as num?)?.toInt();
  int? get etaMax => (json['eta_max'] as num?)?.toInt();

  String get distanceText => distanceM < 1000 ? '$distanceM м' : '${(distanceM / 1000).toStringAsFixed(1)} км';

  /// «привезут за 25–35 мин» или «не доставляет · 1,2 км».
  String get meta {
    if (!delivers) return 'не доставляет · $distanceText';
    final eta = Store({'eta_min': etaMin, 'eta_max': etaMax}).etaText;
    return eta == null ? 'привезут · $distanceText' : 'привезут за $eta';
  }
}

/// Товар и магазины, где он есть.
class SearchItem {
  SearchItem(this.json);
  final Map<String, dynamic> json;

  Map<String, dynamic> get product => (json['product'] as Map<String, dynamic>?) ?? const {};
  List<SearchOffer> get offers => ((json['offers'] as List?) ?? const []).cast<Map<String, dynamic>>().map(SearchOffer.new).toList();
  String get minPrice => '${json['min_price'] ?? '0'}';

  /// Товар с ценой и остатком конкретного магазина — для карточки и корзины.
  Product productIn(SearchOffer o) => Product({
        ...product,
        'price': o.json['price'],
        'old_price': o.json['old_price'],
        'discount_percent': o.json['discount_percent'],
        'available': o.json['available'],
      });
}

/// «Склонение»: 1 магазине, 3 магазинах.
String inStoresWord(int n) => n % 10 == 1 && n % 100 != 11 ? '$n магазине' : '$n магазинах';

/// Поиск по всем магазинам рядом (Figma К7): товар → в каких магазинах есть,
/// почём и привезут ли. Сначала магазины, которые привезут, дешевле и ближе.
class SearchScreen extends StatefulWidget {
  const SearchScreen({super.key, this.query = ''});
  final String query;

  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends State<SearchScreen> {
  late final _q = TextEditingController(text: widget.query);
  Timer? _debounce;
  bool _onlyDelivering = false;
  bool _loading = false;
  Object? _error;
  List<SearchItem>? _items;
  int _stores = 0;
  int _seq = 0;
  final _expanded = <String>{};

  @override
  void initState() {
    super.initState();
    if (widget.query.trim().length >= 2) WidgetsBinding.instance.addPostFrameCallback((_) => _search());
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _q.dispose();
    super.dispose();
  }

  void _onChanged(String _) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 400), _search);
    setState(() {});
  }

  Future<void> _search() async {
    final q = _q.text.trim();
    final a = context.read<AppState>().address;
    final seq = ++_seq;
    if (q.length < 2 || a == null) {
      setState(() {
        _items = null;
        _loading = false;
      });
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final r = await context.read<Api>().get('/client/search', {
        'lat': a.lat,
        'lng': a.lng,
        'q': q,
        'limit': 30,
        if (_onlyDelivering) 'only_delivering': 1,
      }) as Map<String, dynamic>;
      if (!mounted || seq != _seq) return;
      setState(() {
        _items = ((r['items'] as List?) ?? const []).cast<Map<String, dynamic>>().map(SearchItem.new).toList();
        _stores = (r['stores'] as num?)?.toInt() ?? 0;
      });
    } catch (e) {
      if (mounted && seq == _seq) setState(() => _error = e);
    } finally {
      if (mounted && seq == _seq) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final items = _items;
    // Корзина меняется — пересобираем кнопки «+» и счётчики.
    final state = context.watch<AppState>();
    return Scaffold(
      backgroundColor: AppColors.bg,
      body: SafeArea(
        bottom: false,
        child: Column(children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: Row(children: [
              RoundIconButton(icon: Icons.chevron_left_rounded, onTap: () => Navigator.of(context).pop()),
              const SizedBox(width: 10),
              Expanded(
                child: Stack(alignment: Alignment.centerRight, children: [
                  AppSearchField(hint: 'Найти во всех магазинах', controller: _q, autofocus: widget.query.isEmpty, onChanged: _onChanged),
                  if (_q.text.isNotEmpty)
                    IconButton(
                      icon: const Icon(Icons.cancel_rounded, color: AppColors.muted),
                      onPressed: () {
                        _q.clear();
                        _onChanged('');
                      },
                    ),
                ]),
              ),
            ]),
          ),
          SizedBox(
            height: 40,
            child: ListView(scrollDirection: Axis.horizontal, padding: const EdgeInsets.symmetric(horizontal: 16), children: [
              AppChip(
                label: 'Все магазины',
                selected: !_onlyDelivering,
                onTap: () {
                  setState(() => _onlyDelivering = false);
                  _search();
                },
              ),
              const SizedBox(width: 8),
              AppChip(
                label: 'Только с доставкой',
                selected: _onlyDelivering,
                onTap: () {
                  setState(() => _onlyDelivering = true);
                  _search();
                },
              ),
            ]),
          ),
          if (_loading) const LinearProgressIndicator(minHeight: 2),
          Expanded(child: _body(items, state)),
        ]),
      ),
    );
  }

  Widget _body(List<SearchItem>? items, AppState state) {
    if (_error != null && items == null) {
      return EmptyState(icon: Icons.wifi_off_rounded, title: 'Не удалось найти', text: _error.toString(), action: 'Повторить', onAction: _search);
    }
    if (items == null) {
      return const EmptyState(
        icon: Icons.search_rounded,
        title: 'Что ищем?',
        text: 'Ищем во всех магазинах рядом — покажем, где есть товар, почём и привезут ли.',
      );
    }
    if (items.isEmpty) {
      return EmptyState(
        icon: Icons.search_off_rounded,
        title: 'Ничего не нашли',
        text: _onlyDelivering ? 'В магазинах с доставкой такого нет. Попробуйте «Все магазины».' : 'Попробуйте написать по-другому.',
      );
    }
    return ListView.separated(
      padding: EdgeInsets.fromLTRB(16, 8, 16, 24 + MediaQuery.paddingOf(context).bottom),
      itemCount: items.length + 1,
      separatorBuilder: (_, __) => const SizedBox(height: 12),
      itemBuilder: (_, i) {
        if (i == 0) {
          return Text('Нашли ${items.length} ${_goods(items.length)} в ${inStoresWord(_stores)} рядом', style: AppText.small);
        }
        return _card(items[i - 1], state);
      },
    );
  }

  static String _goods(int n) {
    final m10 = n % 10;
    final m100 = n % 100;
    if (m10 == 1 && m100 != 11) return 'товар';
    if (m10 >= 2 && m10 <= 4 && (m100 < 12 || m100 > 14)) return 'товара';
    return 'товаров';
  }

  Widget _card(SearchItem it, AppState state) {
    final p = it.product;
    final images = ((p['images'] as List?) ?? const []).cast<String>();
    final offers = it.offers;
    final id = '${p['id']}';
    final open = _expanded.contains(id);
    final shown = open || offers.length <= 3 ? offers : offers.take(3).toList();
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(color: AppColors.white, borderRadius: BorderRadius.circular(AppRadius.xl)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          SizedBox(width: 64, height: 64, child: ProductImage(url: images.isEmpty ? null : images.first, radius: AppRadius.md, background: AppColors.soft)),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('${p['name'] ?? ''}', maxLines: 2, overflow: TextOverflow.ellipsis, style: AppText.bodyStrong),
              const SizedBox(height: 4),
              Text(
                offers.length == 1 ? 'есть в 1 магазине · ${money(it.minPrice)}' : 'есть в ${inStoresWord(offers.length)} · от ${money(it.minPrice)}',
                style: AppText.small,
              ),
            ]),
          ),
        ]),
        const Padding(padding: EdgeInsets.symmetric(vertical: 10), child: Divider(height: 1, color: AppColors.line)),
        for (final o in shown) _offer(it, o, state),
        if (offers.length > 3)
          TextButton(
            onPressed: () => setState(() => open ? _expanded.remove(id) : _expanded.add(id)),
            child: Text(open ? 'Свернуть' : 'Ещё ${offers.length - 3}', style: AppText.smallStrong.copyWith(color: AppColors.primary)),
          ),
      ]),
    );
  }

  Widget _offer(SearchItem it, SearchOffer o, AppState state) {
    final product = it.productIn(o);
    final store = (id: o.storeId, name: o.storeName);
    final inCart = state.cartStoreId == o.storeId ? state.qtyOf(product.id) : 0;
    Future<void> change(num q) async {
      try {
        await changeQty(context, storeId: o.storeId, storeName: o.storeName, product: product, qty: q);
      } catch (e) {
        if (mounted) showError(context, e);
      }
    }

    return InkWell(
      onTap: () => openProduct(context, store, product),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(o.storeName, maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.bodyStrong.copyWith(color: o.delivers ? AppColors.ink : AppColors.dark)),
              Text(o.meta, style: AppText.caption.copyWith(color: o.delivers ? AppColors.successInk : AppColors.text2)),
            ]),
          ),
          const SizedBox(width: 8),
          Text(money(o.price, suffix: false), style: AppText.bodyStrong.copyWith(color: o.delivers ? AppColors.ink : AppColors.text2)),
          const SizedBox(width: 10),
          if (!o.delivers)
            const SizedBox(width: 40, height: 40, child: Icon(Icons.chevron_right_rounded, color: AppColors.muted))
          else if (inCart == 0)
            AddCircleButton(onTap: () => change(product.step))
          else
            QtyStepper(label: qty(inCart), onMinus: () => change(inCart - product.step), onPlus: () => change(inCart + product.step), height: 36),
        ]),
      ),
    );
  }
}
