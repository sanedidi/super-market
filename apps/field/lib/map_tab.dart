import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:provider/provider.dart';
import 'package:sm_core/sm_core.dart';

import 'flags.dart';
import 'map_view.dart';
import 'places.dart';
import 'state.dart';
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
  final _mapKey = GlobalKey<CoverageMapState>();
  late final FieldState _state;

  @override
  void initState() {
    super.initState();
    _state = context.read<FieldState>();
    _state.mapRequest.addListener(_onRequest);
  }

  @override
  void dispose() {
    _state.mapRequest.removeListener(_onRequest);
    _map.dispose();
    super.dispose();
  }

  /// «Все на карте» / «Маршрут» из «Зайти потом рядом».
  void _onRequest() {
    final at = _state.mapRequest.value?.at;
    if (!_ready) return;
    _mapKey.currentState?.reload();
    if (at != null) {
      _map.move(at, 17);
    } else if (_me != null) {
      _map.move(_me!, 15);
    }
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
            key: _mapKey,
            controller: _map,
            initialCenter: _me,
            initialZoom: 15,
            layers: _layers,
            onReady: () {
              _ready = true;
              final at = _state.mapRequest.value?.at;
              if (at != null) {
                _map.move(at, 17);
              } else {
                _locate();
              }
            },
            onPlaceTap: (p) => showPlaceSheet(context, '${p['id']}'),
            onFlagTap: (f) => showFlagSheet(
              context,
              f,
              onChanged: () => _mapKey.currentState?.reload(),
              onRoute: (to) {
                if (_ready) _map.move(to, 17.5);
              },
            ),
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
