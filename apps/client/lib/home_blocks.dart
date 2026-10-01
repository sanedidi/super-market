import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sm_core/sm_core.dart';

import 'catalog.dart';
import 'main.dart';
import 'product_tile.dart';
import 'screens/category_screen.dart';
import 'screens/home_screen.dart';
import 'screens/root_shell.dart';
import 'state.dart';
import 'ui/theme.dart';
import 'ui/widgets.dart';

/// Главная из блоков, которые настраивает супер-админ (Figma «Админка ·
/// Главная приложения»): полка товаров, баннеры, промо-полоска, иконки
/// разделов, каталог по разделам. Неизвестные типы пропускаются — старое
/// приложение не ломается от новых блоков.
typedef HomeBlock = Map<String, dynamic>;

/// Блоки главной магазина: GET /client/stores/{id}/home, с копией в
/// SharedPreferences, чтобы главная открывалась сразу.
class HomeBlocksCache {
  final _mem = <String, List<HomeBlock>>{};
  final _loading = <String, Future<List<HomeBlock>?>>{};

  static String _key(String store) => 'sm_home_$store';

  /// Уже известные блоки (из памяти или с диска); null — нет.
  List<HomeBlock>? peek(String store) => _mem[store];

  /// Загрузить с сервера; null — ошибка (тогда главная рисуется по-старому).
  Future<List<HomeBlock>?> load(Api api, String store, {bool force = false}) {
    if (force) _loading.remove(store);
    return _loading.putIfAbsent(store, () async {
      SharedPreferences? prefs;
      try {
        prefs = await SharedPreferences.getInstance();
        if (!_mem.containsKey(store)) {
          final saved = prefs.getString(_key(store));
          if (saved != null) _mem[store] = _parse(jsonDecode(saved));
        }
      } catch (_) {}
      try {
        final j = await api.get('/client/stores/$store/home');
        if (j is! Map<String, dynamic> || j['blocks'] is! List) throw const FormatException('blocks');
        final blocks = _parse(j);
        _mem[store] = blocks;
        unawaited(prefs?.setString(_key(store), jsonEncode({'version': j['version'], 'blocks': blocks})));
        return blocks;
      } catch (_) {
        _loading.remove(store);
        return _mem[store];
      }
    });
  }

  static List<HomeBlock> _parse(Object? j) =>
      j is Map && j['blocks'] is List ? (j['blocks'] as List).whereType<Map<String, dynamic>>().where((b) => _known.contains(b['type'])).toList() : [];

  static const _known = {'shelf', 'banners', 'promo', 'category_icons', 'catalog_sections'};
}

/// Слайверы главной по блокам.
List<Widget> homeBlockSlivers(BuildContext context, Store store, List<HomeBlock> blocks) {
  final out = <Widget>[];
  for (final b in blocks) {
    switch (b['type']) {
      case 'shelf':
        out.addAll(_shelf(context, store, b));
      case 'banners':
        out.add(SliverToBoxAdapter(child: HomeBanners(store: store, block: b)));
      case 'promo':
        out.add(SliverToBoxAdapter(child: b['kind'] == 'free_delivery' ? FreeDeliveryStrip(store: store) : PromoStrip(store: store, block: b)));
      case 'category_icons':
        out.add(SliverToBoxAdapter(child: CategoryIcons(store: store, block: b)));
      case 'catalog_sections':
        out.add(SliverToBoxAdapter(
          child: CategorySectionsList(
            store: store,
            view: '${b['view'] ?? 'tiles3'}',
            only: b['mode'] == 'selected' ? (b['category_ids'] as List?)?.cast<String>() : null,
            showImages: b['show_images'] != false,
          ),
        ));
    }
  }
  return out;
}

List<Product> _products(HomeBlock b) => ((b['products'] as List?) ?? const []).whereType<Map<String, dynamic>>().map(Product.new).toList();

/// Полка: заголовок «… · Все», лента или сетка в 2–3 колонки.
List<Widget> _shelf(BuildContext context, Store store, HomeBlock b) {
  final items = _products(b);
  if (items.isEmpty) return const [];
  final title = '${b['title'] ?? ''}';
  final source = '${b['source'] ?? ''}';
  final canAll = b['show_all'] != false && source != 'manual';
  final header = Padding(
    padding: const EdgeInsets.only(top: 24, bottom: 12),
    child: SectionHeader(title: title, action: canAll ? 'Все' : null, onAction: canAll ? () => _openShelf(context, store, b) : null),
  );
  final ref = storeRef(store);
  final view = '${b['view'] ?? 'row'}';
  if (view == 'row') {
    return [SliverToBoxAdapter(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [header, ProductCarousel(products: items, store: ref)]))];
  }
  final cols = view == 'grid3' ? 3 : 2;
  final gap = cols == 3 ? 10.0 : 12.0;
  final w = (MediaQuery.sizeOf(context).width - AppSpace.page * 2 - gap * (cols - 1)) / cols;
  return [
    SliverToBoxAdapter(child: header),
    SliverPadding(
      padding: const EdgeInsets.symmetric(horizontal: AppSpace.page),
      sliver: SliverGrid.builder(
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: cols,
          crossAxisSpacing: gap,
          mainAxisSpacing: 16,
          mainAxisExtent: productCardHeight(w),
        ),
        itemCount: items.length,
        itemBuilder: (_, i) => ProductTile(product: items[i], store: ref),
      ),
    ),
  ];
}

/// «Все» у полки: список по источнику или раздел.
Future<void> _openShelf(BuildContext context, Store store, HomeBlock b) async {
  final title = '${b['title'] ?? ''}';
  switch (b['source']) {
    case 'category':
      await openCategoryById(context, store, '${b['category_id']}');
    case 'hits' || 'discount' || 'new':
      await openDeals(context, store, title: title, filter: '${b['source']}');
  }
}

/// Раздел по id.
Future<void> openCategoryById(BuildContext context, Store store, String id) async {
  try {
    final cat = findCategory(await context.read<AppState>().categoriesOf(store), id);
    if (cat != null && context.mounted) {
      await Navigator.of(context).push(MaterialPageRoute(builder: (_) => CategoryScreen(store: store, category: cat)));
    }
  } catch (e) {
    if (context.mounted) showError(context, e);
  }
}

/// Переход по ссылке промо-полоски: скидки, раздел, товар, условия доставки, сайт.
Future<void> openBlockLink(BuildContext context, Store store, Map<String, dynamic>? link, {String title = 'Горячие скидки'}) async {
  if (link == null) return;
  final id = '${link['id'] ?? ''}';
  try {
    switch (link['type']) {
      case 'deals':
        await openDeals(context, store, title: title);
      case 'category':
        await openCategoryById(context, store, id);
      case 'product':
        final j = await context.read<Api>().get('/client/stores/${store.id}/products/$id') as Map<String, dynamic>;
        if (context.mounted) await openProduct(context, storeRef(store), Product(j));
      case 'delivery_terms':
        await showDeliveryTerms(context, store);
      case 'url':
        final url = '${link['url'] ?? ''}';
        if (url.startsWith('https://')) await openUrl(url);
    }
  } catch (e) {
    if (context.mounted) showError(context, e);
  }
}

/// Цвета промо-полоски: фон, иконка, текст.
const promoColors = <String, (Color, Color, Color)>{
  'yellow': (AppColors.accentSoft, Color(0xFFD69E00), AppColors.ink),
  'red': (AppColors.primary, AppColors.white, AppColors.white),
  'green': (Color(0xFFE8F6EE), Color(0xFF2E9E5B), AppColors.ink),
  'dark': (AppColors.ink, Color(0xFFFFD84D), AppColors.white),
};

/// Иконки промо-полоски, которые предлагает редактор.
const promoIcons = <String, IconData>{
  'gift': Icons.card_giftcard_rounded,
  'percent': Icons.percent_rounded,
  'truck': Icons.local_shipping_rounded,
  'fire': Icons.local_fire_department_rounded,
  'star': Icons.star_rounded,
  'clock': Icons.schedule_rounded,
  'bolt': Icons.bolt_rounded,
  'tag': Icons.local_offer_rounded,
  'leaf': Icons.eco_rounded,
  'party': Icons.celebration_rounded,
};

/// Своя промо-полоска: иконка, заголовок, подпись, переход.
class PromoStrip extends StatelessWidget {
  const PromoStrip({super.key, required this.store, required this.block});
  final Store store;
  final HomeBlock block;

  @override
  Widget build(BuildContext context) {
    final (bg, icon, fg) = promoColors[block['color']] ?? promoColors['yellow']!;
    final link = block['link'] as Map<String, dynamic>?;
    final tappable = link != null && link['type'] != 'none';
    final subtitle = '${block['subtitle'] ?? ''}';
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      child: Material(
        color: bg,
        borderRadius: BorderRadius.circular(18),
        child: InkWell(
          borderRadius: BorderRadius.circular(18),
          onTap: tappable ? () => openBlockLink(context, store, link, title: '${block['title']}') : null,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 10, 8, 10),
            child: Row(children: [
              Icon(promoIcons[block['icon']] ?? Icons.local_offer_rounded, color: icon, size: 26),
              const SizedBox(width: 12),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('${block['title'] ?? ''}', maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.smallStrong.copyWith(fontSize: 14, color: fg)),
                  if (subtitle.isNotEmpty)
                    Text(subtitle, maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.caption.copyWith(color: fg.withValues(alpha: 0.75))),
                ]),
              ),
              if (tappable) Icon(Icons.chevron_right_rounded, color: fg.withValues(alpha: 0.7)) else const SizedBox(width: 8),
            ]),
          ),
        ),
      ),
    );
  }
}

/// Баннеры: «Большой» — фото на всю ширину с подписью и точками,
/// прокрутка каждые 5 с; «Узкая лента» — невысокие карточки в ряд.
class HomeBanners extends StatefulWidget {
  const HomeBanners({super.key, required this.store, required this.block});
  final Store store;
  final HomeBlock block;

  @override
  State<HomeBanners> createState() => _HomeBannersState();
}

class _HomeBannersState extends State<HomeBanners> {
  final _page = PageController();
  Timer? _timer;
  int _index = 0;

  List<Map<String, dynamic>> get _list => ((widget.block['banners'] as List?) ?? const []).whereType<Map<String, dynamic>>().toList();

  @override
  void initState() {
    super.initState();
    if (widget.block['size'] != 'strip' && widget.block['autoplay'] != false && _list.length > 1) {
      _timer = Timer.periodic(const Duration(seconds: 5), (_) {
        if (!_page.hasClients) return;
        final next = (_index + 1) % _list.length;
        _page.animateToPage(next, duration: const Duration(milliseconds: 400), curve: Curves.easeOut);
      });
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    _page.dispose();
    super.dispose();
  }

  Widget _image(Map<String, dynamic> b) {
    final url = '${b['image_url'] ?? ''}';
    return url.isEmpty ? const SizedBox() : Image.network(url, fit: BoxFit.cover, errorBuilder: (_, __, ___) => const SizedBox());
  }

  @override
  Widget build(BuildContext context) {
    if (widget.block['size'] == 'strip') return StripBanner(store: widget.store, block: widget.block);
    final list = _list;
    if (list.isEmpty) return const SizedBox.shrink();
    void open(Map<String, dynamic> b) => openBannerLink(context, widget.store, b);
    final h = (MediaQuery.sizeOf(context).width - 32) * 0.5;
    return Padding(
      padding: const EdgeInsets.only(top: 16),
      child: Column(children: [
        SizedBox(
          height: h,
          child: PageView.builder(
            controller: _page,
            itemCount: list.length,
            onPageChanged: (i) => setState(() => _index = i),
            itemBuilder: (_, i) {
              final b = list[i];
              final hasImage = '${b['image_url'] ?? ''}'.isNotEmpty;
              final showText = b['show_text'] != false || !hasImage;
              return Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Material(
                  color: bannerColor(b),
                  borderRadius: BorderRadius.circular(AppRadius.xl),
                  clipBehavior: Clip.antiAlias,
                  child: InkWell(
                    onTap: () => open(b),
                    child: Stack(fit: StackFit.expand, children: [
                      _image(b),
                      if (hasImage && showText)
                        const DecoratedBox(
                          decoration: BoxDecoration(
                            gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [Color(0x00000000), Color(0x99000000)], stops: [0.35, 1]),
                          ),
                        ),
                      if (showText)
                      Padding(
                        padding: const EdgeInsets.all(16),
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisAlignment: MainAxisAlignment.end, children: [
                          Text('${b['title']}', maxLines: 2, overflow: TextOverflow.ellipsis, style: AppText.title.copyWith(color: AppColors.white)),
                          if ('${b['subtitle'] ?? ''}'.isNotEmpty) ...[
                            const SizedBox(height: 4),
                            Text('${b['subtitle']}', maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.caption.copyWith(color: const Color(0xDDFFFFFF))),
                          ],
                        ]),
                      ),
                    ]),
                  ),
                ),
              );
            },
          ),
        ),
        if (list.length > 1)
          Padding(
            padding: const EdgeInsets.only(top: 10),
            child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
              for (var i = 0; i < list.length; i++)
                AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  margin: const EdgeInsets.symmetric(horizontal: 3),
                  width: i == _index ? 18 : 6,
                  height: 6,
                  decoration: BoxDecoration(color: i == _index ? AppColors.primary : AppColors.line, borderRadius: BorderRadius.circular(3)),
                ),
            ]),
          ),
      ]),
    );
  }
}

/// «Узкая лента»: текст с иконкой на цветной полосе и переход по ссылке.
class StripBanner extends StatelessWidget {
  const StripBanner({super.key, required this.store, required this.block});
  final Store store;
  final HomeBlock block;

  static const _gradients = <String, List<Color>>{
    'red': [Color(0xFFE11D2A), Color(0xFFFF4D5A)],
    'yellow': [Color(0xFFFFC21A), Color(0xFFFFD84D)],
    'green': [Color(0xFF1E9E55), Color(0xFF3CC47A)],
    'dark': [Color(0xFF1F2430), Color(0xFF3A4252)],
  };

  @override
  Widget build(BuildContext context) {
    final title = '${block['title'] ?? ''}';
    if (title.isEmpty) return const SizedBox.shrink();
    final color = '${block['color'] ?? 'red'}';
    final fg = color == 'yellow' ? AppColors.ink : AppColors.white;
    final link = block['link'] as Map<String, dynamic>?;
    final tappable = link != null && link['type'] != 'none';
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
      child: Material(
        borderRadius: BorderRadius.circular(16),
        clipBehavior: Clip.antiAlias,
        child: Ink(
          decoration: BoxDecoration(gradient: LinearGradient(colors: _gradients[color] ?? _gradients['red']!)),
          child: InkWell(
            onTap: tappable ? () => openBlockLink(context, store, link, title: title) : null,
            child: SizedBox(
              height: 52,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 14),
                child: Row(children: [
                  Icon(promoIcons[block['icon']] ?? Icons.local_offer_rounded, color: fg, size: 24),
                  const SizedBox(width: 10),
                  Expanded(child: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.bodyStrong.copyWith(color: fg))),
                  if (tappable) Icon(Icons.chevron_right_rounded, color: fg),
                ]),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Иконки разделов: круги, квадраты или плитки; авто — корневые разделы
/// магазина, вручную — выбранные в админке (в их порядке).
class CategoryIcons extends StatelessWidget {
  const CategoryIcons({super.key, required this.store, required this.block});
  final Store store;
  final HomeBlock block;

  static const _tones = [
    (Color(0xFFEEF3FB), Color(0xFF3B6FD8)),
    (Color(0xFFEFF6EC), Color(0xFF2E9E5B)),
    (Color(0xFFFFF4E6), Color(0xFFE8850C)),
    (Color(0xFFFFF0EB), Color(0xFFD9544A)),
    (Color(0xFFF3F0FA), Color(0xFF7C5CD6)),
  ];

  List<CatalogCategory> _pick(List<CatalogCategory> roots) {
    if (block['mode'] != 'manual') return roots;
    final ids = ((block['category_ids'] as List?) ?? const []).cast<String>();
    return [for (final id in ids) findCategory(roots, id)].whereType<CatalogCategory>().toList();
  }

  @override
  Widget build(BuildContext context) {
    final state = context.read<AppState>();
    final shape = '${block['shape'] ?? 'circle'}';
    final deals = block['show_deals'] != false;
    return FutureBuilder<List<CatalogCategory>>(
      future: state.categoriesOf(store),
      builder: (context, snap) {
        final cats = _pick(snap.data ?? const []);
        void open(CatalogCategory c) => Navigator.of(context).push(MaterialPageRoute(builder: (_) => CategoryScreen(store: store, category: c)));
        Widget glyph(CatalogCategory c, int i) => c.imageUrl != null
            ? Image.network(c.imageUrl!, fit: BoxFit.cover, errorBuilder: (_, __, ___) => Icon(categoryIcon(c.name), color: _tones[i % _tones.length].$2, size: 30))
            : Icon(categoryIcon(c.name), color: _tones[i % _tones.length].$2, size: 30);
        const dealsGlyph = Icon(Icons.local_offer_rounded, color: AppColors.primary, size: 30);
        const dealsBg = Color(0xFFFFE9EA);

        if (shape == 'tiles') {
          final items = <(String, Color, Widget, VoidCallback)>[
            if (deals) ('Скидки', dealsBg, dealsGlyph, () => openDeals(context, store)),
            for (var i = 0; i < cats.length; i++) (cats[i].name, _tones[i % _tones.length].$1, glyph(cats[i], i), () => open(cats[i])),
          ];
          return GridView.count(
            crossAxisCount: 4,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
            mainAxisSpacing: 8,
            crossAxisSpacing: 8,
            childAspectRatio: 0.82,
            children: [
              for (final (label, bg, child, tap) in items)
                Material(
                  color: bg,
                  borderRadius: BorderRadius.circular(16),
                  clipBehavior: Clip.antiAlias,
                  child: InkWell(
                    onTap: tap,
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(8, 10, 8, 8),
                      child: Column(children: [
                        Expanded(child: Center(child: SizedBox(width: 44, height: 44, child: child))),
                        Text(label, maxLines: 2, textAlign: TextAlign.center, overflow: TextOverflow.ellipsis, style: AppText.caption.copyWith(color: AppColors.ink, height: 1.15)),
                      ]),
                    ),
                  ),
                ),
            ],
          );
        }

        final square = shape == 'square';
        Widget item({required Widget child, required Color bg, required String label, required VoidCallback onTap}) => SizedBox(
              width: 74,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: onTap,
                child: Column(children: [
                  Container(
                    width: 62,
                    height: 62,
                    clipBehavior: Clip.antiAlias,
                    decoration: BoxDecoration(
                      color: bg,
                      shape: square ? BoxShape.rectangle : BoxShape.circle,
                      borderRadius: square ? BorderRadius.circular(18) : null,
                    ),
                    child: child,
                  ),
                  const SizedBox(height: 6),
                  Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, textAlign: TextAlign.center, style: AppText.caption.copyWith(color: AppColors.ink)),
                ]),
              ),
            );
        return SizedBox(
          height: 112,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.fromLTRB(10, 16, 10, 0),
            children: [
              if (deals) item(bg: dealsBg, label: 'Скидки', onTap: () => openDeals(context, store), child: dealsGlyph),
              for (var i = 0; i < cats.length; i++)
                item(bg: _tones[i % _tones.length].$1, label: cats[i].name, onTap: () => open(cats[i]), child: glyph(cats[i], i)),
            ],
          ),
        );
      },
    );
  }
}
