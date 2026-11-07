import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:provider/provider.dart';
import 'package:sm_core/sm_core.dart';

import 'map_view.dart';
import 'places.dart';
import 'tracker.dart';
import 'ui.dart';

/// «Карта» — где уже прошли и какие магазины отмечены, без записи пути:
/// посмотреть белые зоны перед обходом.
class MapTab extends StatefulWidget {
  const MapTab({super.key});

  @override
  State<MapTab> createState() => _MapTabState();
}

class _MapTabState extends State<MapTab> {
  final _map = MapController();
  MapLayers _layers = const MapLayers();
  bool _ready = false;
  LatLng? _me;

  @override
  void dispose() {
    _map.dispose();
    super.dispose();
  }

  Future<void> _locate() async {
    final t = context.read<Tracker>();
    final p = t.position ?? await currentPosition();
    if (!mounted) return;
    if (p == null) {
      showSnack(context, tr('Не удалось определить, где вы', 'Joylashuvingizni aniqlab boʻlmadi'));
      return;
    }
    setState(() => _me = LatLng(p.latitude, p.longitude));
    if (_ready) _map.move(_me!, 16.5);
  }

  @override
  Widget build(BuildContext context) {
    final top = MediaQuery.paddingOf(context).top;
    return Scaffold(
      body: Stack(children: [
        Positioned.fill(
          child: CoverageMap(
            controller: _map,
            initialCenter: _me,
            initialZoom: 15,
            layers: _layers,
            onReady: () {
              _ready = true;
              _locate();
            },
            onPlaceTap: (p) => showPlaceSheet(context, '${p['id']}'),
          ),
        ),
        Positioned(
          left: 12,
          right: 12,
          top: top + 8,
          child: LayerChips(layers: _layers, onChanged: (l) => setState(() => _layers = l)),
        ),
        Positioned(
          left: 12,
          right: 12,
          bottom: 12,
          child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
            const MapLegend(),
            const Spacer(),
            MapButton(icon: Icons.my_location_rounded, color: AppColors.primary, tooltip: tr('Где я', 'Men qayerdaman'), onTap: _locate),
          ]),
        ),
      ]),
    );
  }
}
