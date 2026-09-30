// Карта Яндекса. Вся работа с yandex_mapkit собрана в этом файле, чтобы
// при обновлении плагина правки были в одном месте.
//
// Ключ MapKit задаётся в нативной части (см. apps/README.md):
//   Android — MainApplication: MapKitFactory.setApiKey("...")
//   iOS     — AppDelegate:     YMKMapKit.setApiKey("...")

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:yandex_mapkit/yandex_mapkit.dart';

/// Центр Ташкента — точка по умолчанию.
const tashkent = (lat: 41.2995, lng: 69.2401);

/// Текущее местоположение или null, если нет разрешения или GPS молчит.
/// Не дольше 6 секунд: на симуляторе без заданной точки getCurrentPosition
/// может не ответить никогда.
Future<({double lat, double lng})?> currentLocation() async {
  try {
    if (!await Geolocator.isLocationServiceEnabled()) return null;
    var perm = await Geolocator.checkPermission();
    if (perm == LocationPermission.denied) perm = await Geolocator.requestPermission();
    if (perm == LocationPermission.denied || perm == LocationPermission.deniedForever) return null;
    final last = await Geolocator.getLastKnownPosition();
    if (last != null) return (lat: last.latitude, lng: last.longitude);
    final pos = await Geolocator.getCurrentPosition().timeout(const Duration(seconds: 6));
    return (lat: pos.latitude, lng: pos.longitude);
  } catch (_) {
    return null;
  }
}

class MapMarker {
  const MapMarker({required this.id, required this.lat, required this.lng, this.highlight = false, this.onTap});
  final String id;
  final double lat;
  final double lng;
  final bool highlight;
  final VoidCallback? onTap;
}

/// Карта с метками (магазины). Метки — круги, без картинок-ассетов.
/// При смене [focus] камера плавно переезжает к этой точке.
class StoresMap extends StatefulWidget {
  const StoresMap({super.key, required this.center, required this.markers, this.focus, this.focusOffset = 0});

  final ({double lat, double lng}) center;
  final List<MapMarker> markers;
  final ({double lat, double lng})? focus;

  /// Сдвиг цели вниз по широте, чтобы точка не пряталась под карточкой снизу.
  final double focusOffset;

  @override
  State<StoresMap> createState() => _StoresMapState();
}

class _StoresMapState extends State<StoresMap> {
  YandexMapController? _controller;

  @override
  void didUpdateWidget(StoresMap old) {
    super.didUpdateWidget(old);
    final f = widget.focus;
    if (f != null && f != old.focus) _moveTo(f, animate: true);
  }

  void _moveTo(({double lat, double lng}) p, {bool animate = false, double zoom = 14}) {
    _controller?.moveCamera(
      CameraUpdate.newCameraPosition(CameraPosition(target: Point(latitude: p.lat - widget.focusOffset, longitude: p.lng), zoom: zoom)),
      animation: animate ? const MapAnimation(duration: 0.4) : null,
    );
  }

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.primary;
    final center = widget.center;
    return YandexMap(
      onMapCreated: (controller) {
        _controller = controller;
        final f = widget.focus;
        if (f != null) {
          _moveTo(f);
        } else {
          controller.moveCamera(CameraUpdate.newCameraPosition(
            CameraPosition(target: Point(latitude: center.lat, longitude: center.lng), zoom: 13),
          ));
        }
      },
      mapObjects: [
        CircleMapObject(
          mapId: const MapObjectId('me'),
          circle: Circle(center: Point(latitude: center.lat, longitude: center.lng), radius: 40),
          fillColor: Colors.blue.withOpacity(0.7),
          strokeColor: Colors.white,
          strokeWidth: 2,
        ),
        for (final m in widget.markers)
          CircleMapObject(
            mapId: MapObjectId('store_${m.id}'),
            circle: Circle(center: Point(latitude: m.lat, longitude: m.lng), radius: m.highlight ? 110 : 70),
            fillColor: m.highlight ? color : color.withOpacity(0.45),
            strokeColor: Colors.white,
            strokeWidth: m.highlight ? 3 : 2,
            zIndex: m.highlight ? 2 : 1,
            consumeTapEvents: true,
            onTap: (_, __) => m.onTap?.call(),
          ),
      ],
    );
  }
}

/// Карта отслеживания: магазин, курьер, дом покупателя и пунктир от курьера
/// (или магазина) до дома. Камера один раз охватывает все точки.
class TrackingMap extends StatelessWidget {
  const TrackingMap({super.key, required this.store, required this.destination, this.courier, this.bottomInset = 0});

  final ({double lat, double lng}) store;
  final ({double lat, double lng}) destination;
  final ({double lat, double lng})? courier;

  /// Высота листа снизу — камера смещается, чтобы точки не прятались под ним.
  final double bottomInset;

  static const _courierColor = Color(0xFFFF6A1A);

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.primary;
    final from = courier ?? store;
    Point pt(({double lat, double lng}) p) => Point(latitude: p.lat, longitude: p.lng);
    return YandexMap(
      onMapCreated: (controller) {
        final pts = [store, destination, if (courier != null) courier!];
        final minLat = pts.map((p) => p.lat).reduce(math.min), maxLat = pts.map((p) => p.lat).reduce(math.max);
        final minLng = pts.map((p) => p.lng).reduce(math.min), maxLng = pts.map((p) => p.lng).reduce(math.max);
        final span = math.max(maxLat - minLat, (maxLng - minLng) * math.cos(minLat * math.pi / 180));
        final zoom = span <= 0 ? 15.0 : (math.log(360 / (span * 2.4)) / math.ln2).clamp(11.0, 16.5).toDouble();
        // Центр чуть ниже середины: снизу лист со статусом.
        final shift = (maxLat - minLat + 0.004) * (bottomInset > 0 ? 0.35 : 0);
        controller.moveCamera(CameraUpdate.newCameraPosition(CameraPosition(
          target: Point(latitude: (minLat + maxLat) / 2 - shift, longitude: (minLng + maxLng) / 2),
          zoom: zoom,
        )));
      },
      mapObjects: [
        PolylineMapObject(
          mapId: const MapObjectId('route'),
          polyline: Polyline(points: [pt(from), pt(destination)]),
          strokeColor: color,
          strokeWidth: 4,
          dashLength: 6,
          gapLength: 6,
        ),
        CircleMapObject(
          mapId: const MapObjectId('store'),
          circle: Circle(center: pt(store), radius: 40),
          fillColor: color,
          strokeColor: Colors.white,
          strokeWidth: 3,
        ),
        CircleMapObject(
          mapId: const MapObjectId('home'),
          circle: Circle(center: pt(destination), radius: 40),
          fillColor: const Color(0xFF101828),
          strokeColor: Colors.white,
          strokeWidth: 3,
        ),
        if (courier != null) ...[
          CircleMapObject(
            mapId: const MapObjectId('courier_halo'),
            circle: Circle(center: pt(courier!), radius: 110),
            fillColor: _courierColor.withOpacity(0.2),
            strokeWidth: 0,
          ),
          CircleMapObject(
            mapId: const MapObjectId('courier'),
            circle: Circle(center: pt(courier!), radius: 50),
            fillColor: _courierColor,
            strokeColor: Colors.white,
            strokeWidth: 3,
            zIndex: 3,
          ),
        ],
      ],
    );
  }
}

/// Адрес точки для поля «Улица, дом»: «ул. Бунёдкор, 52А» (обратное
/// геокодирование MapKit). null — не нашли или нет сети.
Future<String?> addressAt(double lat, double lng) async {
  SearchSession? session;
  try {
    final (s, result) = await YandexSearch.searchByPoint(
      point: Point(latitude: lat, longitude: lng),
      zoom: 17,
      searchOptions: const SearchOptions(searchType: SearchType.geo, resultPageSize: 1),
    );
    session = s;
    final r = await result.timeout(const Duration(seconds: 8));
    final item = r.items?.firstOrNull;
    if (item == null) return null;
    final a = item.toponymMetadata?.address;
    final street = a?.addressComponents[SearchComponentKind.street];
    final house = a?.addressComponents[SearchComponentKind.house];
    if (street != null) return house == null ? street : '$street, $house';
    return item.name.isNotEmpty ? item.name : a?.formattedAddress;
  } catch (_) {
    return null;
  } finally {
    session?.close();
  }
}

/// Выбор точки: метка в центре экрана, карта двигается под ней.
/// [onChanged] — карта остановилась; [located] — её сдвинула кнопка «где я».
class PointPicker extends StatefulWidget {
  const PointPicker({super.key, required this.initial, required this.onChanged});

  final ({double lat, double lng}) initial;
  final void Function(double lat, double lng, {bool located}) onChanged;

  @override
  State<PointPicker> createState() => _PointPickerState();
}

class _PointPickerState extends State<PointPicker> {
  YandexMapController? _controller;

  /// Следующая остановка карты — после кнопки «где я».
  bool _locating = false;

  Future<void> _toMyLocation() async {
    final loc = await currentLocation();
    if (loc == null || _controller == null) return;
    _locating = true;
    await _controller!.moveCamera(
      CameraUpdate.newCameraPosition(CameraPosition(target: Point(latitude: loc.lat, longitude: loc.lng), zoom: 17)),
      animation: const MapAnimation(duration: 0.5),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      alignment: Alignment.center,
      children: [
        YandexMap(
          onMapCreated: (controller) {
            _controller = controller;
            controller.moveCamera(CameraUpdate.newCameraPosition(
              CameraPosition(target: Point(latitude: widget.initial.lat, longitude: widget.initial.lng), zoom: 16),
            ));
          },
          onCameraPositionChanged: (position, reason, finished) {
            if (!finished) return;
            final located = _locating;
            _locating = false;
            widget.onChanged(position.target.latitude, position.target.longitude, located: located);
          },
        ),
        IgnorePointer(
          child: Padding(
            padding: const EdgeInsets.only(bottom: 40),
            child: Icon(Icons.location_on, size: 48, color: Theme.of(context).colorScheme.primary),
          ),
        ),
        Positioned(
          right: 16,
          bottom: 16,
          child: FloatingActionButton.small(
            heroTag: 'my_location',
            onPressed: _toMyLocation,
            child: const Icon(Icons.my_location),
          ),
        ),
      ],
    );
  }
}
