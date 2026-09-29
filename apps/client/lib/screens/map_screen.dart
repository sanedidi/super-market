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
    final selected = state.stores.where((s) => s.id == _selected).firstOrNull;
    final bottom = MediaQuery.paddingOf(context).bottom + 88;
    return Scaffold(
      body: Stack(children: [
        Positioned.fill(
          child: StoresMap(
            key: ValueKey('map-${address.id}-${state.stores.length}'),
            center: (lat: address.lat, lng: address.lng),
            markers: [
              for (final s in state.stores)
                MapMarker(
                  id: s.id,
                  lat: s.lat,
                  lng: s.lng,
                  highlight: s.id == _selected || (_selected == null && s.recommended),
                  onTap: () => setState(() => _selected = s.id),
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
        if (selected != null)
          Positioned(
            left: 16,
            right: 16,
            bottom: bottom,
            child: Material(
              color: AppColors.white,
              elevation: 6,
              shadowColor: const Color(0x22000000),
              borderRadius: BorderRadius.circular(AppRadius.xl),
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  StoreCard(
                    name: selected.name,
                    subtitle: storeSubtitle(selected),
                    logoUrl: selected.logoUrl,
                    recommended: selected.recommended,
                    closed: !selected.isOpen,
                    meta: storeMeta(selected),
                  ),
                  const SizedBox(height: 10),
                  AppButton(label: 'Смотреть товары', onPressed: () => state.openCatalog(selected)),
                ]),
              ),
            ),
          ),
      ]),
    );
  }
}
