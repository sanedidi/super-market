import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../map_view.dart';
import '../state.dart';
import '../ui/theme.dart';
import '../ui/widgets.dart';
import 'addresses_screen.dart';
import 'home_screen.dart';

/// Вкладка «Карта»: магазины, которые доставляют по выбранному адресу.
class MapScreen extends StatefulWidget {
  const MapScreen({super.key});

  @override
  State<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends State<MapScreen> {
  String? _selected;
  final _pager = PageController(viewportFraction: 0.9);

  /// Высота карточки магазина внизу.
  static const _cardHeight = 212.0;

  @override
  void dispose() {
    _pager.dispose();
    super.dispose();
  }

  /// Нажали на точку — листаем карточки к этому магазину.
  void _onMarker(List<Store> stores, String id) {
    final i = stores.indexWhere((s) => s.id == id);
    if (i < 0) return;
    setState(() => _selected = id);
    if (_pager.hasClients && (_pager.page?.round() ?? 0) != i) {
      _pager.animateToPage(i, duration: const Duration(milliseconds: 300), curve: Curves.easeOut);
    }
  }

  /// Открыть витрину магазина на главной.
  void _open(AppState state, Store s) {
    state.openCatalog(s);
    state.setTab(0);
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final address = state.address;
    if (address == null) {
      return Scaffold(
        body: SafeArea(
          child: EmptyState(
            icon: Icons.map_outlined,
            title: 'Укажите адрес',
            text: 'Покажем на карте магазины, которые доставляют к вам.',
            action: 'Выбрать адрес',
            onAction: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const AddressesScreen())),
          ),
        ),
      );
    }
    final stores = state.stores;
    final selected = stores.where((s) => s.id == _selected).firstOrNull ?? stores.firstOrNull;
    // Нижнее меню прозрачное поверх карты (extendBody): его высота уже в padding.bottom.
    final bottom = MediaQuery.paddingOf(context).bottom + 12;
    return Scaffold(
      body: Stack(children: [
        Positioned.fill(
          child: StoresMap(
            key: ValueKey('map-${address.id}-${stores.length}'),
            center: (lat: address.lat, lng: address.lng),
            focus: selected == null ? null : (lat: selected.lat, lng: selected.lng),
            focusOffset: 0.006,
            markers: [
              for (final s in stores)
                MapMarker(
                  id: s.id,
                  lat: s.lat,
                  lng: s.lng,
                  highlight: s.id == selected?.id,
                  onTap: () => _onMarker(stores, s.id),
                ),
            ],
          ),
        ),
        // Плашка сверху: сколько магазинов доставляют по адресу.
        Positioned(
          left: 16,
          right: 16,
          top: MediaQuery.paddingOf(context).top + 12,
          child: Material(
            color: AppColors.white,
            elevation: 4,
            shadowColor: const Color(0x22000000),
            borderRadius: BorderRadius.circular(AppRadius.lg),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
              child: Row(children: [
                const IconBox(Icons.storefront_outlined, size: 40),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(state.storesLoading ? 'Ищем магазины…' : 'Магазинов рядом: ${state.stores.length}', style: AppText.bodyStrong),
                    Text(address.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.caption),
                  ]),
                ),
              ]),
            ),
          ),
        ),
        if (stores.isNotEmpty)
          Positioned(
            left: 0,
            right: 0,
            bottom: bottom,
            height: _cardHeight,
            child: PageView.builder(
              controller: _pager,
              itemCount: stores.length,
              onPageChanged: (i) => setState(() => _selected = stores[i].id),
              itemBuilder: (_, i) {
                final s = stores[i];
                return Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                  child: Material(
                    color: AppColors.white,
                    elevation: 6,
                    shadowColor: const Color(0x22000000),
                    borderRadius: BorderRadius.circular(AppRadius.xl),
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Column(children: [
                        StoreCard(
                          name: s.name,
                          subtitle: storeSubtitle(s),
                          logoUrl: s.logoUrl,
                          recommended: s.recommended,
                          closed: !s.isOpen,
                          meta: storeMeta(s),
                          onTap: () => _open(state, s),
                        ),
                        const Spacer(),
                        AppButton(label: 'Смотреть товары', onPressed: () => _open(state, s)),
                      ]),
                    ),
                  ),
                );
              },
            ),
          ),
      ]),
    );
  }
}
