import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:provider/provider.dart';
import 'package:sm_core/sm_core.dart';

import 'logic.dart';
import 'tracker.dart';
import 'ui.dart';

const tashkent = LatLng(41.311, 69.279);
const _agent = 'uz.supermarket.sm_field';

/// Слои карты (чипы «Улицы · Сетка · Магазины»).
class MapLayers {
  const MapLayers({this.streets = true, this.grid = true, this.places = true});

  final bool streets;
  final bool grid;
  final bool places;

  MapLayers copyWith({bool? streets, bool? grid, bool? places}) =>
      MapLayers(streets: streets ?? this.streets, grid: grid ?? this.grid, places: places ?? this.places);
}

/// Карта обхода: обойдённые клетки (свои — красные, чужие — серые, белые —
/// никто не был), пройденные улицы, отмеченные магазины и где я сейчас.
/// Данные — GET /field/map по видимой области, после каждого сдвига карты.
class CoverageMap extends StatefulWidget {
  const CoverageMap({
    super.key,
    required this.controller,
    this.initialCenter,
    this.initialZoom = 16.5,
    this.layers = const MapLayers(),
    this.hint,
    this.onPlaceTap,
    this.onReady,
    this.onGesture,
  });

  final MapController controller;
  final LatLng? initialCenter;
  final double initialZoom;
  final MapLayers layers;

  /// Ближайшая белая зона (П3 «Показать путь»): пунктир от меня до неё.
  final LatLng? hint;
  final ValueChanged<Map<String, dynamic>>? onPlaceTap;
  final VoidCallback? onReady;

  /// Карту подвинули рукой (перестать следовать за мной).
  final VoidCallback? onGesture;

  @override
  State<CoverageMap> createState() => CoverageMapState();
}

class CoverageMapState extends State<CoverageMap> {
  Grid _grid = Grid.tashkent;
  List<List<int>> _cells = const [];
  List<Map<String, dynamic>> _tracks = const [];
  List<Map<String, dynamic>> _places = const [];
  Timer? _debounce;
  bool _ready = false;
  int _seq = 0;

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
  }

  /// Перечитать данные видимой области (после отметки магазина, отправки точек).
  void reload() {
    if (_ready) _load();
  }

  void _schedule() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 450), _load);
  }

  Future<void> _load() async {
    if (!mounted || !_ready) return;
    final b = widget.controller.camera.visibleBounds;
    final seq = ++_seq;
    try {
      final d = await context.read<Api>().get('/field/map', {
        'min_lat': b.south.toStringAsFixed(6),
        'min_lng': b.west.toStringAsFixed(6),
        'max_lat': b.north.toStringAsFixed(6),
        'max_lng': b.east.toStringAsFixed(6),
      }) as Map<String, dynamic>;
      if (!mounted || seq != _seq) return;
      setState(() {
        _grid = Grid.from(d['grid']);
        _cells = ((d['cells'] as List?) ?? const []).map((c) => (c as List).map((v) => (v as num).toInt()).toList()).toList();
        _tracks = ((d['tracks'] as List?) ?? const []).cast<Map<String, dynamic>>();
        _places = ((d['places'] as List?) ?? const []).cast<Map<String, dynamic>>();
      });
    } catch (_) {
      // Нет сети — остаётся то, что уже показано.
    }
  }

  static List<LatLng> _pts(Object? raw) => ((raw as List?) ?? const [])
      .map((p) => LatLng(((p as List)[0] as num).toDouble(), (p[1] as num).toDouble()))
      .toList();

  @override
  Widget build(BuildContext context) {
    final tracker = context.watch<Tracker>();
    final pos = tracker.position;
    final me = pos == null ? null : LatLng(pos.latitude, pos.longitude);
    final layers = widget.layers;
    final polygons = <Polygon>[];
    if (layers.grid) {
      for (final c in _cells) {
        if (c.length < 3) continue;
        final (s, w, n, e) = _grid.bounds(c[0], c[1]);
        final mine = c[2] == 1;
        polygons.add(Polygon(
          points: [LatLng(s, w), LatLng(n, w), LatLng(n, e), LatLng(s, e)],
          color: (mine ? AppColors.primary : AppColors.dark).withValues(alpha: mine ? 0.16 : 0.14),
          borderStrokeWidth: 0,
        ));
      }
    }
    final lines = <Polyline>[];
    if (layers.streets) {
      // Чужие — снизу, свои — сверху.
      final sorted = [..._tracks]..sort((a, b) => (a['mine'] == true ? 1 : 0).compareTo(b['mine'] == true ? 1 : 0));
      for (final t in sorted) {
        final pts = _pts(t['pts']);
        if (pts.length < 2) continue;
        final mine = t['mine'] == true;
        lines.add(Polyline(
          points: pts,
          strokeWidth: mine ? 4.5 : 4,
          color: mine ? AppColors.primary : AppColors.otherPath,
          borderStrokeWidth: 1.5,
          borderColor: AppColors.white,
        ));
      }
      if (tracker.trail.length > 1) {
        lines.add(Polyline(points: List.of(tracker.trail), strokeWidth: 5, color: AppColors.primary, borderStrokeWidth: 1.5, borderColor: AppColors.white));
      }
    }
    if (widget.hint != null && me != null) {
      lines.add(Polyline(points: [me, widget.hint!], strokeWidth: 4, color: AppColors.primary, pattern: StrokePattern.dotted()));
    }
    final markers = <Marker>[];
    if (layers.places) {
      for (final p in _places) {
        final lat = (p['lat'] as num?)?.toDouble(), lng = (p['lng'] as num?)?.toDouble();
        if (lat == null || lng == null) continue;
        markers.add(Marker(
          point: LatLng(lat, lng),
          width: 30,
          height: 30,
          child: GestureDetector(
            onTap: widget.onPlaceTap == null ? null : () => widget.onPlaceTap!(p),
            child: Center(child: PlaceDot(result: '${p['result']}')),
          ),
        ));
      }
    }
    if (widget.hint != null) {
      markers.add(Marker(
        point: widget.hint!,
        width: 26,
        height: 26,
        child: Container(
          decoration: BoxDecoration(color: AppColors.white, shape: BoxShape.circle, border: Border.all(color: AppColors.primary, width: 4)),
        ),
      ));
    }
    if (me != null) {
      markers.add(Marker(
        point: me,
        width: 40,
        height: 40,
        child: Center(
          child: Container(
            width: 40,
            height: 40,
            alignment: Alignment.center,
            decoration: BoxDecoration(color: AppColors.primary.withValues(alpha: 0.16), shape: BoxShape.circle),
            child: Container(
              width: 16,
              height: 16,
              decoration: BoxDecoration(color: AppColors.primary, shape: BoxShape.circle, border: Border.all(color: AppColors.white, width: 3)),
            ),
          ),
        ),
      ));
    }
    return FlutterMap(
      mapController: widget.controller,
      options: MapOptions(
        initialCenter: widget.initialCenter ?? me ?? tashkent,
        initialZoom: widget.initialZoom,
        minZoom: 12,
        maxZoom: 19,
        interactionOptions: const InteractionOptions(flags: InteractiveFlag.all & ~InteractiveFlag.rotate),
        onMapReady: () {
          _ready = true;
          widget.onReady?.call();
          _load();
        },
        onPositionChanged: (camera, hasGesture) {
          if (hasGesture) widget.onGesture?.call();
          _schedule();
        },
      ),
      children: [
        TileLayer(urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png', userAgentPackageName: _agent),
        if (polygons.isNotEmpty) PolygonLayer(polygons: polygons),
        if (lines.isNotEmpty) PolylineLayer(polylines: lines),
        MarkerLayer(markers: markers),
        const SimpleAttributionWidget(source: Text('OpenStreetMap')),
      ],
    );
  }
}

/// Круглая кнопка поверх карты.
class MapButton extends StatelessWidget {
  const MapButton({super.key, required this.icon, required this.onTap, this.color = AppColors.ink, this.tooltip});

  final IconData icon;
  final VoidCallback onTap;
  final Color color;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final b = Container(
      decoration: const BoxDecoration(shape: BoxShape.circle, boxShadow: shadow),
      child: Material(
        color: AppColors.white,
        shape: const CircleBorder(),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onTap,
          child: SizedBox(width: 48, height: 48, child: Icon(icon, size: 22, color: color)),
        ),
      ),
    );
    return tooltip == null ? b : Tooltip(message: tooltip!, child: b);
  }
}

/// Чипы слоёв карты: «Улицы · Сетка · Магазины».
class LayerChips extends StatelessWidget {
  const LayerChips({super.key, required this.layers, required this.onChanged});

  final MapLayers layers;
  final ValueChanged<MapLayers> onChanged;

  @override
  Widget build(BuildContext context) {
    Widget chip(IconData icon, String label, bool on, MapLayers next) => Padding(
          padding: const EdgeInsets.only(right: 8),
          child: Container(
            decoration: BoxDecoration(borderRadius: BorderRadius.circular(18), boxShadow: shadow),
            child: Material(
              color: on ? AppColors.ink : AppColors.white,
              borderRadius: BorderRadius.circular(18),
              child: InkWell(
                borderRadius: BorderRadius.circular(18),
                onTap: () => onChanged(next),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 8, 14, 8),
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    Icon(icon, size: 16, color: on ? AppColors.white : AppColors.ink),
                    const SizedBox(width: 6),
                    Text(label, style: AppText.caption.copyWith(color: on ? AppColors.white : AppColors.ink, fontSize: 13)),
                  ]),
                ),
              ),
            ),
          ),
        );
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(children: [
        chip(Icons.route_rounded, tr('Улицы', 'Koʻchalar'), layers.streets, layers.copyWith(streets: !layers.streets)),
        chip(Icons.grid_on_rounded, tr('Сетка', 'Toʻr'), layers.grid, layers.copyWith(grid: !layers.grid)),
        chip(Icons.storefront_rounded, tr('Магазины', 'Doʻkonlar'), layers.places, layers.copyWith(places: !layers.places)),
      ]),
    );
  }
}

/// Легенда: мой путь, другие продажники, белая зона.
class MapLegend extends StatelessWidget {
  const MapLegend({super.key});

  @override
  Widget build(BuildContext context) {
    Widget row(Widget swatch, String label) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            SizedBox(width: 16, child: Center(child: swatch)),
            const SizedBox(width: 6),
            Text(label, style: AppText.small.copyWith(fontSize: 11)),
          ]),
        );
    Widget line(Color c) => Container(width: 14, height: 4, decoration: BoxDecoration(color: c, borderRadius: BorderRadius.circular(2)));
    return Container(
      padding: const EdgeInsets.fromLTRB(10, 8, 12, 8),
      decoration: BoxDecoration(color: AppColors.white, borderRadius: BorderRadius.circular(14), boxShadow: shadow),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
        row(line(AppColors.primary), tr('мой путь', 'mening yoʻlim')),
        row(line(AppColors.otherPath), tr('другие продажники', 'boshqa agentlar')),
        row(
          Container(width: 11, height: 11, decoration: BoxDecoration(color: AppColors.white, borderRadius: BorderRadius.circular(3), border: Border.all(color: AppColors.line))),
          tr('белая зона — не были', 'oq hudud — hech kim boʻlmagan'),
        ),
      ]),
    );
  }
}
