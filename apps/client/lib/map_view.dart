// Карта Яндекса. Вся работа с yandex_mapkit собрана в этом файле, чтобы
// при обновлении плагина правки были в одном месте.
//
// Ключ MapKit задаётся в нативной части (см. apps/README.md):
//   Android — MainApplication: MapKitFactory.setApiKey("...")
//   iOS     — AppDelegate:     YMKMapKit.setApiKey("...")

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

/// Выбор точки: метка в центре экрана, карта двигается под ней.
class PointPicker extends StatefulWidget {
  const PointPicker({super.key, required this.initial, required this.onChanged});

  final ({double lat, double lng}) initial;
  final void Function(double lat, double lng) onChanged;

  @override
  State<PointPicker> createState() => _PointPickerState();
}

class _PointPickerState extends State<PointPicker> {
  YandexMapController? _controller;

  Future<void> _toMyLocation() async {
    final loc = await currentLocation();
    if (loc == null || _controller == null) return;
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
            if (finished) widget.onChanged(position.target.latitude, position.target.longitude);
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
