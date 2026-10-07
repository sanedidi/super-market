// Карта для первой настройки: превью точки магазина, круг доставки и
// полноэкранный выбор точки (Figma С2). Карта — OpenStreetMap через flutter_map:
// без ключей и нативной настройки; поиск адреса — геокодер Nominatim (OSM).
import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';
import 'package:sm_core/sm_core.dart';

import '../ui/theme.dart';
import '../ui/widgets.dart';

const tashkent = LatLng(41.311, 69.279);
const _agent = 'uz.supermarket.sm_store';

Widget _tiles() => TileLayer(urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png', userAgentPackageName: _agent);

/// Где сейчас телефон (null — нет разрешения или геолокация выключена).
Future<LatLng?> currentPoint() async {
  try {
    if (!await Geolocator.isLocationServiceEnabled()) return null;
    var perm = await Geolocator.checkPermission();
    if (perm == LocationPermission.denied) perm = await Geolocator.requestPermission();
    if (perm == LocationPermission.denied || perm == LocationPermission.deniedForever) return null;
    final pos = await Geolocator.getCurrentPosition().timeout(const Duration(seconds: 8));
    return LatLng(pos.latitude, pos.longitude);
  } catch (_) {
    return null;
  }
}

/// [lang] — язык названий: по умолчанию язык интерфейса (узбекский, если есть в OSM, иначе русский).
Future<dynamic> _osm(String path, Map<String, String> q, {String? lang}) async {
  final uri = Uri.https('nominatim.openstreetmap.org', path, {...q, 'format': 'json', 'accept-language': lang ?? (Lang.instance.isUz ? 'uz,ru' : 'ru')});
  final r = await http.get(uri, headers: {'User-Agent': _agent}).timeout(const Duration(seconds: 8));
  if (r.statusCode != 200) return null;
  return jsonDecode(utf8.decode(r.bodyBytes));
}

/// Адрес точки: «улица, дом» (null — не нашли).
Future<String?> addressAt(LatLng p) async {
  try {
    final d = await _osm('/reverse', {'lat': '${p.latitude}', 'lon': '${p.longitude}', 'zoom': '18', 'addressdetails': '1'}) as Map<String, dynamic>?;
    final a = d?['address'] as Map<String, dynamic>?;
    if (a == null) return null;
    final street = a['road'] ?? a['pedestrian'] ?? a['neighbourhood'] ?? a['suburb'];
    final parts = [street, a['house_number']].whereType<String>().toList();
    return parts.isEmpty ? (d?['display_name'] as String?)?.split(',').take(2).join(',') : parts.join(', ');
  } catch (_) {
    return null;
  }
}

/// Город точки (для рекламы брендов по городам).
Future<String?> cityAt(LatLng p) async {
  try {
    // Город — всегда по-русски: по нему сервер подбирает рекламу брендов.
    final d = await _osm('/reverse', {'lat': '${p.latitude}', 'lon': '${p.longitude}', 'zoom': '10', 'addressdetails': '1'}, lang: 'ru') as Map<String, dynamic>?;
    final a = d?['address'] as Map<String, dynamic>?;
    return (a?['city'] ?? a?['town'] ?? a?['village'] ?? a?['state']) as String?;
  } catch (_) {
    return null;
  }
}

class Place {
  const Place(this.title, this.point);
  final String title;
  final LatLng point;
}

/// Поиск адреса в Узбекистане.
Future<List<Place>> searchPlaces(String q) async {
  try {
    final d = await _osm('/search', {'q': q, 'countrycodes': 'uz', 'limit': '6'}) as List?;
    return [
      for (final r in (d ?? const []).cast<Map<String, dynamic>>())
        Place('${r['display_name']}'.split(',').take(3).join(','), LatLng(double.parse('${r['lat']}'), double.parse('${r['lon']}'))),
    ];
  } catch (_) {
    return const [];
  }
}

/// Метка магазина: красный круг с витриной и ножка; кончик — в точке.
class StorePin extends StatelessWidget {
  const StorePin({super.key});

  static const height = 64.0;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: SizedBox(
        height: height,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: AppColors.primary,
              shape: BoxShape.circle,
              border: Border.all(color: AppColors.white, width: 3),
              boxShadow: const [BoxShadow(color: Color(0x33000000), blurRadius: 8, offset: Offset(0, 2))],
            ),
            child: const Icon(Icons.storefront_rounded, color: AppColors.white, size: 22),
          ),
          Container(width: 4, height: 14, decoration: BoxDecoration(color: AppColors.primary, borderRadius: BorderRadius.circular(2))),
          Container(width: 14, height: 6, decoration: BoxDecoration(color: const Color(0x40151515), borderRadius: BorderRadius.circular(7))),
        ]),
      ),
    );
  }
}

/// Метка по центру карты: кончик ножки — ровно в центре.
Widget _centerPin() => const Center(child: Padding(padding: EdgeInsets.only(bottom: StorePin.height - 6), child: StorePin()));

/// Зум, при котором круг радиуса [m] метров помещается в [px] точек.
double zoomFor(double m, double px, double lat) {
  final metersPerPx = 2 * m * 1.25 / px;
  final z = math.log(156543.03 * math.cos(lat * math.pi / 180) / metersPerPx) / math.ln2;
  return z.clamp(9, 18).toDouble();
}

/// Неподвижная карта: точка магазина и, если задан [radiusM], круг доставки.
class MapPreview extends StatelessWidget {
  const MapPreview({super.key, required this.point, this.radiusM, this.height = 150, this.overlay});

  final LatLng point;
  final int? radiusM;
  final double height;
  final Widget? overlay;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(16),
      child: SizedBox(
        height: height,
        child: LayoutBuilder(builder: (context, c) {
          final zoom = radiusM == null ? 16.0 : zoomFor(radiusM!.toDouble(), math.min(c.maxWidth, height), point.latitude);
          return Stack(children: [
            IgnorePointer(
              child: FlutterMap(
              key: ValueKey('${point.latitude},${point.longitude},$radiusM'),
              options: MapOptions(initialCenter: point, initialZoom: zoom, interactionOptions: const InteractionOptions(flags: InteractiveFlag.none)),
              children: [
                _tiles(),
                if (radiusM != null)
                  CircleLayer(circles: [
                    CircleMarker(
                      point: point,
                      radius: radiusM!.toDouble(),
                      useRadiusInMeter: true,
                      color: AppColors.primary.withValues(alpha: 0.08),
                      borderColor: AppColors.primary,
                      borderStrokeWidth: 1.5,
                    ),
                  ]),
              ],
            ),
            ),
            _centerPin(),
            Positioned(right: 6, top: 4, child: Text('© OpenStreetMap', style: AppText.caption.copyWith(fontSize: 9, color: AppColors.text2))),
            if (overlay != null) Positioned(right: 10, bottom: 10, child: overlay!),
          ]);
        }),
      ),
    );
  }
}

/// Выбранная точка и адрес под ней.
class PickedPoint {
  const PickedPoint(this.point, this.address);
  final LatLng point;
  final String? address;
}

/// С2 · Точка на карте: карта двигается под меткой, «Здесь вход в магазин».
class MapPickerScreen extends StatefulWidget {
  const MapPickerScreen({super.key, this.initial, this.address});

  final LatLng? initial;
  final String? address;

  @override
  State<MapPickerScreen> createState() => _MapPickerScreenState();
}

class _MapPickerScreenState extends State<MapPickerScreen> {
  final _map = MapController();
  final _q = TextEditingController();
  late LatLng _center = widget.initial ?? tashkent;
  String? _address;
  bool _resolving = false;
  List<Place> _found = const [];
  bool _searching = false;
  Timer? _debounce;

  @override
  void initState() {
    super.initState();
    _address = widget.initial == null ? null : widget.address;
    if (widget.initial == null) WidgetsBinding.instance.addPostFrameCallback((_) => _locate());
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _q.dispose();
    _map.dispose();
    super.dispose();
  }

  Future<void> _locate() async {
    final p = await currentPoint();
    if (p == null || !mounted) {
      if (mounted) showSnack(context, tr('Не удалось определить местоположение — найдите адрес или подвиньте карту', 'Joylashuvni aniqlab boʻlmadi — manzilni qidiring yoki xaritani suring'));
      return;
    }
    _map.move(p, 17);
    _moved(p);
  }

  void _moved(LatLng p) {
    _center = p;
    _debounce?.cancel();
    if (!_resolving) setState(() => _resolving = true);
    _debounce = Timer(const Duration(milliseconds: 700), () async {
      final a = await addressAt(p);
      if (!mounted || _center != p) return;
      setState(() {
        _address = a;
        _resolving = false;
      });
    });
  }

  Future<void> _search(String q) async {
    if (q.trim().length < 3) return;
    setState(() => _searching = true);
    final r = await searchPlaces(q.trim());
    if (!mounted) return;
    setState(() {
      _found = r;
      _searching = false;
    });
    if (r.isEmpty) showSnack(context, tr('Ничего не нашли — подвиньте карту к магазину', 'Hech narsa topilmadi — xaritani doʻkon tomon suring'));
  }

  @override
  Widget build(BuildContext context) {
    final top = MediaQuery.paddingOf(context).top;
    return Scaffold(
      body: Stack(children: [
        FlutterMap(
          mapController: _map,
          options: MapOptions(
            initialCenter: _center,
            initialZoom: widget.initial == null ? 12 : 17,
            interactionOptions: const InteractionOptions(flags: InteractiveFlag.all & ~InteractiveFlag.rotate),
            onPositionChanged: (camera, hasGesture) {
              if (hasGesture) _moved(camera.center);
            },
          ),
          children: [
            _tiles(),
            const SimpleAttributionWidget(source: Text('OpenStreetMap')),
          ],
        ),
        _centerPin(),
        Center(
          child: Padding(
            padding: const EdgeInsets.only(bottom: StorePin.height * 2 + 40),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(color: AppColors.ink, borderRadius: BorderRadius.circular(12)),
              child: Text(tr('Вход в магазин здесь?', 'Doʻkonga kirish shu yerdami?'), style: AppText.bodyStrong.copyWith(color: AppColors.white, fontSize: 14)),
            ),
          ),
        ),
        Positioned(
          left: 16,
          right: 16,
          top: top + 8,
          child: Column(children: [
            Row(children: [
              _Round(icon: Icons.arrow_back_rounded, onTap: () => Navigator.of(context).pop()),
              const SizedBox(width: 10),
              Expanded(
                child: Container(
                  height: 44,
                  decoration: BoxDecoration(color: AppColors.white, borderRadius: BorderRadius.circular(22), boxShadow: _shadow),
                  child: TextField(
                    controller: _q,
                    textInputAction: TextInputAction.search,
                    onSubmitted: _search,
                    style: AppText.body,
                    decoration: InputDecoration(
                      hintText: tr('Найти адрес', 'Manzilni topish'),
                      filled: false,
                      isDense: true,
                      contentPadding: const EdgeInsets.symmetric(vertical: 12),
                      prefixIconConstraints: const BoxConstraints(minWidth: 44, minHeight: 44),
                      prefixIcon: _searching
                          ? const Padding(padding: EdgeInsets.all(13), child: SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)))
                          : const Icon(Icons.search_rounded, color: AppColors.muted),
                      border: InputBorder.none,
                      enabledBorder: InputBorder.none,
                      focusedBorder: InputBorder.none,
                    ),
                  ),
                ),
              ),
            ]),
            if (_found.isNotEmpty)
              Container(
                margin: const EdgeInsets.only(top: 8, left: 54),
                decoration: BoxDecoration(borderRadius: BorderRadius.circular(16), boxShadow: _shadow),
                child: Material(
                  color: AppColors.white,
                  borderRadius: BorderRadius.circular(16),
                  clipBehavior: Clip.antiAlias,
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                  for (final f in _found)
                    ListTile(
                      dense: true,
                      leading: const Icon(Icons.place_outlined, color: AppColors.text2),
                      title: Text(f.title, style: AppText.body, maxLines: 2, overflow: TextOverflow.ellipsis),
                      onTap: () {
                        FocusScope.of(context).unfocus();
                        setState(() => _found = const []);
                        _map.move(f.point, 17);
                        _moved(f.point);
                      },
                    ),
                  ]),
                ),
              ),
          ]),
        ),
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          child: Column(crossAxisAlignment: CrossAxisAlignment.end, mainAxisSize: MainAxisSize.min, children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(0, 0, 16, 16),
              child: _Round(icon: Icons.my_location_rounded, color: AppColors.blue, size: 48, onTap: _locate),
            ),
            Container(
            width: double.infinity,
            padding: EdgeInsets.fromLTRB(16, 20, 16, 16 + MediaQuery.paddingOf(context).bottom),
            decoration: const BoxDecoration(color: AppColors.white, borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
              Text(
                _resolving ? tr('Определяем адрес…', 'Manzil aniqlanmoqda…') : (_address ?? tr('Адрес не определили', 'Manzil aniqlanmadi')),
                style: AppText.h3,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 4),
              Text(tr('Двигайте карту, чтобы метка встала точно на вход', 'Belgi aynan kirish joyiga tushishi uchun xaritani suring'), style: AppText.small),
              const SizedBox(height: 16),
              BigButton(
                label: tr('Здесь вход в магазин', 'Doʻkonga kirish shu yerda'),
                icon: Icons.check_rounded,
                onPressed: () => Navigator.of(context).pop(PickedPoint(_center, _resolving ? null : _address)),
              ),
            ]),
          ),
          ]),
        ),
      ]),
    );
  }
}

const _shadow = [BoxShadow(color: Color(0x1F000000), blurRadius: 10, offset: Offset(0, 2))];

class _Round extends StatelessWidget {
  const _Round({required this.icon, required this.onTap, this.color = AppColors.ink, this.size = 44});

  final IconData icon;
  final VoidCallback onTap;
  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(shape: BoxShape.circle, boxShadow: _shadow),
      child: Material(
        color: AppColors.white,
        shape: const CircleBorder(),
        child: InkWell(customBorder: const CircleBorder(), onTap: onTap, child: SizedBox(width: size, height: size, child: Icon(icon, color: color, size: 22))),
      ),
    );
  }
}

/// Короткое сообщение внизу экрана.
void showSnack(BuildContext context, String text) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(text)));
}
