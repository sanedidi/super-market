import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:provider/provider.dart';
import 'package:sm_core/sm_core.dart';
import 'package:sm_store/setup/setup_map.dart' show tashkent;
import 'package:sm_store/state.dart';
import 'package:sm_store/ui/theme.dart';
import 'package:sm_store/ui/widgets.dart';

import 'logic.dart';
import 'store_screen.dart';
import 'ui.dart';

/// Д2 · Магазины: карта и список — кому чего не хватает; неподключённые рядом.
class StoresScreen extends StatefulWidget {
  const StoresScreen({super.key, this.initialFilter = ''});

  final String initialFilter;

  @override
  State<StoresScreen> createState() => _StoresScreenState();
}

class _StoresScreenState extends State<StoresScreen> {
  late String _filter = widget.initialFilter;
  final _q = TextEditingController();
  bool _searching = false;
  Timer? _debounce;
  List<Map<String, dynamic>>? _items;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _q.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final items = await context.read<Api>().list('/store/supply/stores', {'status': _filter, 'q': _q.text.trim(), 'limit': 200});
      if (mounted) {
        setState(() {
          _items = items;
          _error = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  Future<void> _open(Map<String, dynamic> s) async {
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => StoreScreen(storeId: '${s['id']}')));
    if (mounted) _load();
  }

  @override
  Widget build(BuildContext context) {
    final items = _items;
    final linked = items?.where((s) => s['link_status'] == 'active').length ?? 0;
    return SafeArea(
      child: RefreshIndicator(
        onRefresh: _load,
        child: ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 24), children: [
          Row(children: [
            Expanded(
              child: _searching
                  ? TextField(
                      controller: _q,
                      autofocus: true,
                      onChanged: (_) {
                        _debounce?.cancel();
                        _debounce = Timer(const Duration(milliseconds: 300), _load);
                      },
                      decoration: InputDecoration(prefixIcon: const Icon(Icons.search_rounded), hintText: tr('Название или адрес', 'Nomi yoki manzil')),
                    )
                  : Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(tr('Магазины', 'Doʻkonlar'), style: AppText.h1),
                      Text(tr('$linked подключили вас · рядом ещё ${(items?.length ?? 0) - linked}', '$linked ta sizni ulagan · yaqinda yana ${(items?.length ?? 0) - linked} ta'),
                          style: AppText.small),
                    ]),
            ),
            const SizedBox(width: 8),
            RoundIcon(
              icon: _searching ? Icons.close_rounded : Icons.search_rounded,
              color: AppColors.white,
              onTap: () {
                setState(() => _searching = !_searching);
                if (!_searching && _q.text.isNotEmpty) {
                  _q.clear();
                  _load();
                }
              },
            ),
          ]),
          const SizedBox(height: 12),
          if (items != null) _StoresMap(items: items, onTap: _open),
          const SizedBox(height: 12),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(children: [
              for (final f in storeFilters) ...[
                ChipButton(
                  label: storeFilterLabel(f),
                  color: _filter == f ? AppColors.ink : AppColors.white,
                  foreground: _filter == f ? AppColors.white : AppColors.ink,
                  onPressed: () {
                    setState(() {
                      _filter = f;
                      _items = null;
                    });
                    _load();
                  },
                ),
                const SizedBox(width: 6),
              ],
            ]),
          ),
          const SizedBox(height: 12),
          if (_error != null && items == null)
            LoadError(_error!, onRetry: _load)
          else if (items == null)
            const Padding(padding: EdgeInsets.only(top: 40), child: Center(child: CircularProgressIndicator()))
          else if (items.isEmpty)
            EmptyState(
              icon: Icons.storefront_outlined,
              title: tr('Магазинов нет', 'Doʻkonlar yoʻq'),
              text: tr('Рядом со складом (15 км) нет магазинов Super Market с таким статусом.', 'Ombor yonida (15 km) bunday holatdagi Super Market doʻkonlari yoʻq.'),
            )
          else
            AppCard(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
              child: Column(children: [
                for (var i = 0; i < items.length; i++) ...[
                  if (i > 0) const Divider(height: 1),
                  _StoreRow(s: items[i], onTap: () => _open(items[i])),
                ],
              ]),
            ),
        ]),
      ),
    );
  }
}

class _StoreRow extends StatelessWidget {
  const _StoreRow({required this.s, required this.onTap});

  final Map<String, dynamic> s;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final st = stockStatus(s['status']);
    final km = s['distance_km'];
    final linked = s['link_status'] == 'active';
    final requested = s['link_status'] == 'requested';
    final String line2;
    if (linked) {
      line2 = st == StockStatus.noBrand
          ? tr('Ваш бренд не продаёт', 'Brendingizni sotmaydi')
          : st == StockStatus.ok
              ? tr('Всё в наличии · ${s['carried_count']} ваших товаров', 'Hammasi bor · ${s['carried_count']} ta mahsulotingiz')
              : tr('Нет ${s['out_count']} · мало ${s['low_count']}', 'Yoʻq ${s['out_count']} · kam ${s['low_count']}');
    } else if (requested) {
      line2 = s['requested_by'] == 'store' ? tr('Просит подключиться — ответьте', 'Ulanishni soʻrayapti — javob bering') : tr('Запрос отправлен — ждём магазин', 'Soʻrov yuborildi — doʻkonni kutyapmiz');
    } else {
      line2 = tr('Не подключён — нажмите, чтобы договориться', 'Ulanmagan — kelishish uchun bosing');
    }
    final tag = linked
        ? StatusChip(
            stockLabel(st, count: st == StockStatus.out ? (s['out_count'] as num).toInt() : st == StockStatus.low ? (s['low_count'] as num).toInt() : 0),
            tone: stockTone(st))
        : requested
            ? StatusChip(tr('Запрос', 'Soʻrov'), tone: ChipTone.blue)
            : null;
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Row(children: [
          StoreIcon(st),
          const SizedBox(width: 10),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('${s['name']}', style: AppText.bodyStrong),
              Text([if ('${s['address'] ?? ''}'.isNotEmpty) '${s['address']}', if (km != null) '${qty(km)} км'].join(' · '), style: AppText.small, maxLines: 1, overflow: TextOverflow.ellipsis),
              Text(line2, style: AppText.small.copyWith(fontWeight: FontWeight.w500, color: linked ? stockColors(st).$2 : AppColors.text2)),
            ]),
          ),
          if (tag != null) ...[const SizedBox(width: 8), tag],
          const Icon(Icons.chevron_right_rounded, color: AppColors.muted),
        ]),
      ),
    );
  }
}

/// Карта: точки магазинов в цвете статуса.
class _StoresMap extends StatelessWidget {
  const _StoresMap({required this.items, required this.onTap});

  final List<Map<String, dynamic>> items;
  final void Function(Map<String, dynamic>) onTap;

  @override
  Widget build(BuildContext context) {
    final me = context.watch<StoreState>().store;
    final points = [
      for (final s in items)
        if (s['lat'] != null && s['lng'] != null) (s, LatLng((s['lat'] as num).toDouble(), (s['lng'] as num).toDouble())),
    ];
    final myLat = me?['lat'], myLng = me?['lng'];
    final center = myLat is num && myLng is num ? LatLng(myLat.toDouble(), myLng.toDouble()) : (points.isNotEmpty ? points.first.$2 : tashkent);
    return ClipRRect(
      borderRadius: BorderRadius.circular(16),
      child: SizedBox(
        height: 180,
        child: Stack(children: [
          FlutterMap(
            options: MapOptions(initialCenter: center, initialZoom: 12.5),
            children: [
              TileLayer(urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png', userAgentPackageName: 'uz.supermarket.sm_distributor'),
              MarkerLayer(markers: [
                if (myLat is num && myLng is num)
                  Marker(point: center, width: 26, height: 26, child: const IconBox(Icons.warehouse_rounded, bg: AppColors.ink, fg: AppColors.white, size: 26, iconSize: 15, radius: 8)),
                for (final (s, p) in points)
                  Marker(
                    point: p,
                    width: 20,
                    height: 20,
                    child: GestureDetector(
                      onTap: () => onTap(s),
                      child: Container(
                        decoration: BoxDecoration(
                          color: s['link_status'] == 'active' ? stockColors(stockStatus(s['status'])).$2 : AppColors.muted,
                          shape: BoxShape.circle,
                          border: Border.all(color: AppColors.white, width: 2),
                        ),
                      ),
                    ),
                  ),
              ]),
            ],
          ),
          Positioned(
            left: 10,
            bottom: 10,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(color: AppColors.white, borderRadius: BorderRadius.circular(10)),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                for (final (c, l) in [
                  (AppColors.primary, tr('нет', 'yoʻq')),
                  (AppColors.warningInk, tr('мало', 'kam')),
                  (AppColors.successInk, tr('есть', 'bor')),
                  (AppColors.muted, tr('не подкл.', 'ulanmagan')),
                ]) ...[
                  Container(width: 8, height: 8, decoration: BoxDecoration(color: c, shape: BoxShape.circle)),
                  const SizedBox(width: 4),
                  Text(l, style: AppText.small.copyWith(fontSize: 11)),
                  const SizedBox(width: 8),
                ],
              ]),
            ),
          ),
        ]),
      ),
    );
  }
}
