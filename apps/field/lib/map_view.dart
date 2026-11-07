import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:provider/provider.dart';
import 'package:sm_core/sm_core.dart';

import 'flags.dart';
import 'logic.dart';
import 'state.dart';
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
    this.emptyHintTop = 0,
    this.onFlagTap,
    this.onMove,
    this.onLoaded,
  });

  final MapController controller;
  final LatLng? initialCenter;
  final double initialZoom;
  final MapLayers layers;

  /// Ближайшая белая зона (П3 «Показать путь»): пунктир от меня до неё.
  final LatLng? hint;
  final ValueChanged<Map<String, dynamic>>? onPlaceTap;

  /// Нажали на флажок «зайти потом».
  final ValueChanged<Map<String, dynamic>>? onFlagTap;

  /// Карта сдвинулась — новая середина (П12 «Где магазин?»: флажок в центре).
  final ValueChanged<LatLng>? onMove;

  /// Пришли данные с сервера (флажки, магазины) — чтобы экран сверху пересчитал «рядом».
  final VoidCallback? onLoaded;
  final VoidCallback? onReady;

  /// Карту подвинули рукой (перестать следовать за мной).
  final VoidCallback? onGesture;

  /// Насколько ниже чипов показать подсказку «здесь никто не обходил» (под шапкой обхода).
  final double emptyHintTop;

  @override
  State<CoverageMap> createState() => CoverageMapState();
}

class CoverageMapState extends State<CoverageMap> {
  Grid _grid = Grid.tashkent;
  List<List<int>> _cells = const [];
  List<Map<String, dynamic>> _tracks = const [];
  List<Map<String, dynamic>> _places = const [];
  List<Map<String, dynamic>> _stores = const [];
  List<Map<String, dynamic>> _flags = const [];
  bool _loaded = false;
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

  /// Ближайший к точке открытый флажок или отмеченный магазин не дальше maxM
  /// (П13 «Это тот же магазин?»). null — рядом никого.
  ({Map<String, dynamic> item, bool isFlag, double distanceM})? nearest(LatLng p, double maxM) {
    ({Map<String, dynamic> item, bool isFlag, double distanceM})? best;
    void check(Map<String, dynamic> it, bool isFlag) {
      final lat = (it['lat'] as num?)?.toDouble(), lng = (it['lng'] as num?)?.toDouble();
      if (lat == null || lng == null) return;
      final d = distanceM(p.latitude, p.longitude, lat, lng);
      if (d <= maxM && (best == null || d < best!.distanceM)) best = (item: it, isFlag: isFlag, distanceM: d);
    }

    for (final f in _flags) {
      check(f, true);
    }
    for (final pl in _places) {
      check(pl, false);
    }
    return best;
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
        _stores = ((d['stores'] as List?) ?? const []).cast<Map<String, dynamic>>();
        _flags = ((d['flags'] as List?) ?? const []).cast<Map<String, dynamic>>();
        _loaded = true;
      });
      widget.onLoaded?.call();
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
    // Граница моего района (если супер-админ назначил район).
    final district = _pts(context.select<FieldState, Object?>((s) => s.district?['boundary']));
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
      // Магазины, которые уже работают в Super Market, — туда не ходить.
      for (final st in _stores) {
        final lat = (st['lat'] as num?)?.toDouble(), lng = (st['lng'] as num?)?.toDouble();
        if (lat == null || lng == null) continue;
        markers.add(Marker(
          point: LatLng(lat, lng),
          width: 30,
          height: 30,
          child: GestureDetector(
            onTap: () => showSnack(context, '${st['name']} · ${tr('уже в Super Market', 'Super Market’da ishlaydi')}'),
            child: const Center(child: SmStoreDot()),
          ),
        ));
      }
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
    if (layers.places) {
      // Флажки «зайти потом» — поверх отметок.
      for (final f in _flags) {
        final pt = flagPoint(f);
        if (pt == null) continue;
        markers.add(Marker(
          point: pt,
          width: 32,
          height: 32,
          child: GestureDetector(
            onTap: widget.onFlagTap == null ? null : () => widget.onFlagTap!(f),
            child: Center(child: FlagDot(old: f['old'] == true, fromMap: f['source'] == 'osm')),
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
          widget.onMove?.call(camera.center);
          _schedule();
        },
      ),
      children: [
        // Подложка — светло-серая: на цветной карте OSM не видно ни путей, ни клеток.
        TileLayer(
          urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
          userAgentPackageName: _agent,
          tileBuilder: (_, tile, __) => ColorFiltered(colorFilter: _lightGrey, child: tile),
        ),
        if (layers.grid) _GridLines(grid: _grid),
        if (polygons.isNotEmpty) PolygonLayer(polygons: polygons),
        if (district.length > 2)
          PolylineLayer(polylines: [
            Polyline(points: [...district, district.first], strokeWidth: 3, color: AppColors.primary.withValues(alpha: 0.75)),
          ]),
        if (lines.isNotEmpty) PolylineLayer(polylines: lines),
        MarkerLayer(markers: markers),
        // Подпись «© OpenStreetMap» — в легенде (MapLegend): здесь её закрывали кнопки.
        if (_loaded && _cells.isEmpty && _tracks.isEmpty && _places.isEmpty && _flags.isEmpty && tracker.trail.length < 2)
          Align(
            alignment: Alignment.topCenter,
            child: Padding(
              padding: EdgeInsets.only(top: MediaQuery.paddingOf(context).top + 60 + widget.emptyHintTop),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
                decoration: BoxDecoration(color: AppColors.ink.withValues(alpha: 0.82), borderRadius: BorderRadius.circular(14)),
                child: Text(
                  tr('Здесь ещё никто не обходил — все клетки белые', 'Bu yerda hali hech kim aylanmagan — barcha kataklar oq'),
                  style: AppText.small.copyWith(color: AppColors.white, fontSize: 12),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

/// Светло-серая подложка: яркость карты × 0,6 + 40% белого.
const _lightGrey = ColorFilter.matrix(<double>[
  0.1276, 0.4291, 0.0433, 0, 102, //
  0.1276, 0.4291, 0.0433, 0, 102, //
  0.1276, 0.4291, 0.0433, 0, 102, //
  0, 0, 0, 1, 0,
]);

/// Тонкая сетка клеток 100×100 м в видимой области — видно, какие клетки
/// белые (никто не был). Мельче 15-го масштаба клетки слишком малы — не рисуем.
class _GridLines extends StatelessWidget {
  const _GridLines({required this.grid});

  final Grid grid;

  @override
  Widget build(BuildContext context) {
    final camera = MapCamera.of(context);
    if (camera.zoom < 15) return const SizedBox.shrink();
    final b = camera.visibleBounds;
    final x0 = (b.west / grid.lng).floor(), x1 = (b.east / grid.lng).ceil();
    final y0 = (b.south / grid.lat).floor(), y1 = (b.north / grid.lat).ceil();
    if ((x1 - x0) + (y1 - y0) > 240) return const SizedBox.shrink();
    final s = y0 * grid.lat, n = y1 * grid.lat, w = x0 * grid.lng, e = x1 * grid.lng;
    const c = Color(0x1F000000);
    return PolylineLayer(polylines: [
      for (var x = x0; x <= x1; x++) Polyline(points: [LatLng(s, x * grid.lng), LatLng(n, x * grid.lng)], strokeWidth: 1, color: c),
      for (var y = y0; y <= y1; y++) Polyline(points: [LatLng(y * grid.lat, w), LatLng(y * grid.lat, e)], strokeWidth: 1, color: c),
    ]);
  }
}

/// Магазин Super Market на карте: красный кружок с витриной.
class SmStoreDot extends StatelessWidget {
  const SmStoreDot({super.key});

  @override
  Widget build(BuildContext context) => Container(
        width: 24,
        height: 24,
        decoration: BoxDecoration(color: AppColors.primary, shape: BoxShape.circle, border: Border.all(color: AppColors.white, width: 2), boxShadow: shadow),
        child: const Icon(Icons.storefront_rounded, size: 13, color: AppColors.white),
      );
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

/// Чипы слоёв карты: «Улицы · Сетка · Магазины». Включён — тёмный, выключен — белый с перечёркнутым глазом.
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
                    Icon(on ? icon : Icons.visibility_off_outlined, size: 16, color: on ? AppColors.white : AppColors.muted),
                    const SizedBox(width: 6),
                    Text(label, style: AppText.caption.copyWith(color: on ? AppColors.white : AppColors.muted, fontSize: 13)),
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

/// Легенда: мой путь, другие продажники, белая клетка, граница района; подпись OpenStreetMap.
class MapLegend extends StatelessWidget {
  const MapLegend({super.key});

  @override
  Widget build(BuildContext context) {
    final hasDistrict = ((context.select<FieldState, Object?>((s) => s.district?['boundary']) as List?)?.length ?? 0) > 2;
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
        row(line(AppColors.otherPath), tr('другие продажники', 'boshqa savdo agentlari')),
        row(
          Container(width: 11, height: 11, decoration: BoxDecoration(color: AppColors.white, borderRadius: BorderRadius.circular(3), border: Border.all(color: AppColors.muted))),
          tr('белая клетка — никто не был', 'oq katak — hech kim boʻlmagan'),
        ),
        row(const SizedBox(width: 14, height: 14, child: FittedBox(child: SmStoreDot())), tr('уже в Super Market', 'Super Market’da')),
        row(const SizedBox(width: 14, height: 14, child: FittedBox(child: FlagDot())), tr('зайти потом', 'keyin kirish')),
        row(const SizedBox(width: 14, height: 14, child: FittedBox(child: FlagDot(fromMap: true))), tr('магазин с карты', 'xaritadagi doʻkon')),
        if (hasDistrict) row(Container(width: 14, height: 3, color: AppColors.primary.withValues(alpha: 0.75)), tr('граница моего района', 'tumanim chegarasi')),
        const SizedBox(height: 2),
        Text('© OpenStreetMap', style: AppText.small.copyWith(fontSize: 9, color: AppColors.muted)),
      ]),
    );
  }
}
