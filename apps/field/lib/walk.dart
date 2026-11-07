import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:provider/provider.dart';
import 'package:sm_core/sm_core.dart';

import 'flags.dart';
import 'logic.dart';
import 'map_view.dart';
import 'mark.dart';
import 'places.dart';
import 'state.dart';
import 'summary.dart';
import 'tracker.dart';
import 'ui.dart';

/// П2 · Идёт обход — карта: мой путь красным, чужие серым, сетка, магазины;
/// «Отметить магазин», «Пауза», «Закончить». П3 — баннер «Здесь уже прошёл …»
/// и путь до ближайшей белой зоны. Уйти с экрана можно — путь пишется дальше.
class WalkScreen extends StatefulWidget {
  const WalkScreen({super.key});

  @override
  State<WalkScreen> createState() => _WalkScreenState();
}

class _WalkScreenState extends State<WalkScreen> {
  final _map = MapController();
  final _mapKey = GlobalKey<CoverageMapState>();
  late final Tracker _tracker;
  MapLayers _layers = const MapLayers();
  Timer? _clock;
  Timer? _reload;
  bool _ready = false;
  bool _follow = true;
  bool _dismissed = false;
  bool _wasOther = false;
  bool _busy = false;
  DateTime? _sentAt;
  LatLng? _hint;
  String? _hintText;
  // Флажки «зайти потом», про которые уже вибрировали и баннер которых закрыли.
  bool _flagging = false;
  final _buzzed = <String>{};
  final _hiddenFlags = <String>{};

  @override
  void initState() {
    super.initState();
    _tracker = context.read<Tracker>();
    _tracker.onEnded = _ended;
    _tracker.addListener(_onTracker);
    _clock = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
    // Чужие отметки и пути появляются и без моих точек.
    _reload = Timer.periodic(const Duration(seconds: 60), (_) => _mapKey.currentState?.reload());
  }

  @override
  void dispose() {
    _tracker.removeListener(_onTracker);
    if (_tracker.onEnded == _ended) _tracker.onEnded = null;
    _clock?.cancel();
    _reload?.cancel();
    _map.dispose();
    super.dispose();
  }

  void _onTracker() {
    final here = _tracker.here;
    final other = here?['state'] == 'other';
    if (!other) {
      _dismissed = false;
      _wasOther = false;
    } else if (!_wasOther) {
      // Зашёл в клетки, где уже прошёл другой продажник, — вибрация (П3).
      _wasOther = true;
      _hint = null;
      HapticFeedback.heavyImpact();
      Future.delayed(const Duration(milliseconds: 300), HapticFeedback.heavyImpact);
    }
    final fl = _tracker.nearFlag;
    final flID = fl == null ? null : '${fl['id']}';
    if (flID != null && _buzzed.add(flID) && !_hiddenFlags.contains(flID)) {
      // Подошёл к флажку «зайти потом» — короткая вибрация.
      HapticFeedback.mediumImpact();
    }
    final p = _tracker.position;
    if (_ready && _follow && p != null) {
      _map.move(LatLng(p.latitude, p.longitude), _map.camera.zoom);
    }
    if (_tracker.sentAt != _sentAt) {
      _sentAt = _tracker.sentAt;
      _mapKey.currentState?.reload();
    }
  }

  void _ended() {
    if (!mounted) return;
    context.read<FieldState>().load();
    _tracker.finish();
    showSnack(context, tr('Обход закончен автоматически', 'Aylanish avtomatik tugatildi'));
    // Открытые шторки и формы закрываются вместе с экраном обхода.
    Navigator.of(context).popUntil((r) => r.isFirst);
  }

  void _locate() {
    final p = _tracker.position;
    setState(() => _follow = true);
    if (_ready && p != null) _map.move(LatLng(p.latitude, p.longitude), 17);
  }

  Future<void> _showWay() async {
    final p = _tracker.position;
    if (p == null) return;
    try {
      final d = await context.read<Api>().get('/field/white-zone', {'lat': p.latitude.toStringAsFixed(6), 'lng': p.longitude.toStringAsFixed(6)}) as Map<String, dynamic>;
      if (!mounted) return;
      final h = d['hint'] as Map<String, dynamic>?;
      if (h == null) {
        showSnack(context, tr('Рядом всё обойдено — посмотрите карту района', 'Atrofda hammasi aylanilgan — tuman xaritasini koʻring'));
        return;
      }
      final to = LatLng((h['lat'] as num).toDouble(), (h['lng'] as num).toDouble());
      setState(() {
        _hint = to;
        final way = '${formatDistance(h['distance_m'])} ${directionLabel('${h['direction']}')}';
        _hintText = tr('Белая зона — $way', 'Oq hudud — $way');
        _follow = false;
        _dismissed = true;
      });
      if (!_ready) return;
      _map.fitCamera(CameraFit.coordinates(coordinates: [LatLng(p.latitude, p.longitude), to], padding: const EdgeInsets.fromLTRB(60, 220, 60, 240)));
    } on ApiError catch (e) {
      if (mounted) showSnack(context, e.message);
    }
  }

  Future<void> _mark() async {
    final ok = await markStore(context);
    if (ok) _mapKey.currentState?.reload();
    unawaited(_tracker.flush());
  }

  /// П8 «Потом»: флажок там, где стою; обход идёт дальше.
  Future<void> _later() async {
    if (_flagging) return;
    setState(() => _flagging = true);
    Map<String, dynamic>? f;
    try {
      f = await placeFlag(context, onChanged: () => _mapKey.currentState?.reload(), onMark: _mark, onRoute: _routeTo);
    } finally {
      if (mounted) setState(() => _flagging = false);
    }
    if (f != null) {
      // Свой только что поставленный флажок — без баннера «Рядом флажок».
      _buzzed.add('${f['id']}');
      _hiddenFlags.add('${f['id']}');
    }
  }

  /// «Маршрут» к флажку: пунктир от меня до него.
  void _routeTo(LatLng to) {
    final p = _tracker.position;
    final d = p == null ? null : distanceM(p.latitude, p.longitude, to.latitude, to.longitude);
    setState(() {
      _hint = to;
      _hintText = d == null ? tr('Флажок «зайти потом»', '«Keyin kirish» bayroqchasi') : tr('Флажок — ${formatDistance(d)}', 'Bayroqcha — ${formatDistance(d)}');
      _follow = false;
    });
    if (!_ready || p == null) return;
    _map.fitCamera(CameraFit.coordinates(coordinates: [LatLng(p.latitude, p.longitude), to], padding: const EdgeInsets.fromLTRB(60, 220, 60, 240)));
  }

  void _openFlag(Map<String, dynamic> f) {
    final id = '${f['id']}';
    showFlagSheet(
      context,
      f,
      onRoute: _routeTo,
      onMark: () {
        // Отметили магазин у флажка — баннер «Рядом флажок» больше не нужен.
        setState(() => _hiddenFlags.add(id));
        _mark();
      },
      onChanged: () {
        if (mounted) setState(() => _hiddenFlags.add(id));
        _mapKey.currentState?.reload();
      },
    );
  }

  Future<void> _pause() async {
    final id = _tracker.walkId;
    if (id == null) return;
    setState(() => _busy = true);
    try {
      await _tracker.flush();
      if (!mounted) return;
      final w = await context.read<Api>().post('/field/walks/$id/${_tracker.paused ? 'resume' : 'pause'}') as Map<String, dynamic>;
      _tracker.setWalk(w);
    } on ApiError catch (e) {
      if (mounted) showSnack(context, e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _finish() async {
    final id = _tracker.walkId;
    if (id == null) return;
    final ok = await confirmSheet(
      context,
      title: tr('Закончить обход?', 'Aylanishni tugatasizmi?'),
      text: tr('Путь перестанет записываться. Новый обход можно начать в любой момент.', 'Yoʻl yozilishi toʻxtaydi. Yangi aylanishni istalgan payt boshlash mumkin.'),
      confirm: tr('Закончить', 'Tugatish'),
      icon: Icons.stop_circle_rounded,
    );
    if (!ok || !mounted) return;
    setState(() => _busy = true);
    final api = context.read<Api>();
    final state = context.read<FieldState>();
    final nav = Navigator.of(context);
    try {
      _tracker.onEnded = null;
      await _tracker.flush();
      final s = await api.post('/field/walks/$id/finish') as Map<String, dynamic>;
      await _tracker.finish();
      unawaited(state.load());
      await nav.pushReplacement(MaterialPageRoute<void>(builder: (_) => SummaryScreen(summary: s)));
    } on ApiError catch (e) {
      _tracker.onEnded = _ended;
      if (mounted) showSnack(context, e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = context.watch<Tracker>();
    final top = MediaQuery.paddingOf(context).top;
    final walk = t.walk ?? const <String, dynamic>{};
    final results = (walk['results'] as Map<String, dynamic>?) ?? const {};
    final places = (results['total'] as num?)?.toInt() ?? 0;
    final other = (walk['other_m'] as num?)?.toDouble() ?? 0;
    final paused = t.paused;
    final here = t.here;
    final banner = showOtherBanner(here, dismissed: _dismissed);
    final fl = t.nearFlag;
    final nearFlag = fl != null && !banner && !_hiddenFlags.contains('${fl['id']}') ? fl : null;
    final pos = t.position;
    return Scaffold(
      body: Stack(children: [
        Positioned.fill(
          child: CoverageMap(
            key: _mapKey,
            controller: _map,
            initialCenter: pos == null ? null : LatLng(pos.latitude, pos.longitude),
            initialZoom: 17,
            layers: _layers,
            hint: _hint,
            emptyHintTop: 92,
            onReady: () => _ready = true,
            onGesture: () {
              if (_follow) setState(() => _follow = false);
            },
            onPlaceTap: (p) => showPlaceSheet(context, '${p['id']}'),
            onFlagTap: _openFlag,
          ),
        ),
        Positioned(
          left: 12,
          right: 12,
          top: top + 8,
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            // Идёт обход · таймер · км · магазины · по чужому пути.
            Container(
              padding: const EdgeInsets.fromLTRB(6, 6, 14, 10),
              decoration: BoxDecoration(color: AppColors.white, borderRadius: BorderRadius.circular(18), boxShadow: shadow),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  IconButton(
                    visualDensity: VisualDensity.compact,
                    icon: const Icon(Icons.arrow_back_rounded),
                    tooltip: tr('На главную — обход продолжится', 'Bosh sahifaga — aylanish davom etadi'),
                    onPressed: () => Navigator.of(context).maybePop(),
                  ),
                  Container(
                    width: 10,
                    height: 10,
                    decoration: BoxDecoration(color: paused ? AppColors.warning : AppColors.primary, shape: BoxShape.circle),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      paused
                          ? (walk['auto_paused'] == true ? tr('Пауза — вы стоите на месте', 'Pauza — joyingizda turibsiz') : tr('Пауза', 'Pauza'))
                          : tr('Идёт обход', 'Aylanish davom etmoqda'),
                      style: AppText.bodyStrong,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  Text(formatClock(t.activeSec), style: AppText.bodyStrong.copyWith(fontFeatures: const [FontFeature.tabularFigures()])),
                ]),
                Padding(
                  padding: const EdgeInsets.only(left: 12),
                  child: Text(
                    [
                      formatDistance(walk['distance_m']),
                      storesCount(places),
                      if (other > 0) tr('по чужому пути ${formatDistance(other)}', 'boshqalar yoʻlidan ${formatDistance(other)}'),
                    ].join(' · '),
                    style: AppText.small,
                  ),
                ),
                if (t.error != null || t.pending > 120)
                  Padding(
                    padding: const EdgeInsets.only(left: 12, top: 4),
                    child: Text(
                      t.error ?? tr('Не отправлено точек: ${t.pending} — отправятся, когда появится интернет', 'Yuborilmagan nuqtalar: ${t.pending} — internet paydo boʻlganda yuboriladi'),
                      style: AppText.small.copyWith(color: AppColors.warningInk, fontSize: 12),
                    ),
                  ),
              ]),
            ),
            const SizedBox(height: 10),
            if (banner)
              _OtherBanner(
                here: here!,
                onWay: _showWay,
                onClose: () => setState(() => _dismissed = true),
              )
            else
              LayerChips(layers: _layers, onChanged: (l) => setState(() => _layers = l)),
            if (_hint != null && _hintText != null) ...[
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.fromLTRB(12, 8, 6, 8),
                decoration: BoxDecoration(color: AppColors.white, borderRadius: BorderRadius.circular(14), boxShadow: shadow),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  const Icon(Icons.flag_rounded, color: AppColors.primary, size: 18),
                  const SizedBox(width: 6),
                  Text(_hintText!, style: AppText.caption.copyWith(color: AppColors.primary, fontSize: 13)),
                  IconButton(
                    visualDensity: VisualDensity.compact,
                    icon: const Icon(Icons.close_rounded, size: 18),
                    onPressed: () => setState(() {
                      _hint = null;
                      _hintText = null;
                    }),
                  ),
                ]),
              ),
            ],
            if (nearFlag != null) ...[
              const SizedBox(height: 8),
              FlagNearBanner(
                flag: nearFlag,
                onOpen: () => _openFlag(nearFlag),
                onClose: () => setState(() => _hiddenFlags.add('${nearFlag['id']}')),
              ),
            ],
          ]),
        ),
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
              child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
                const MapLegend(),
                const Spacer(),
                Column(mainAxisSize: MainAxisSize.min, children: [
                  MapButton(
                    icon: Icons.my_location_rounded,
                    color: _follow ? AppColors.primary : AppColors.ink,
                    tooltip: tr('Где я', 'Men qayerdaman'),
                    onTap: _locate,
                  ),
                ]),
              ]),
            ),
            Container(
              padding: EdgeInsets.fromLTRB(16, 16, 16, 12 + MediaQuery.paddingOf(context).bottom),
              decoration: const BoxDecoration(
                color: AppColors.white,
                borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
                boxShadow: [BoxShadow(color: Color(0x1A000000), blurRadius: 16, offset: Offset(0, -2))],
              ),
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                Row(children: [
                  Expanded(child: BigButton(label: tr('Отметить магазин', 'Doʻkonni belgilash'), icon: Icons.add_location_alt_rounded, onPressed: _busy ? null : _mark)),
                  const SizedBox(width: 10),
                  _LaterButton(onPressed: _busy || paused || _flagging ? null : _later),
                ]),
                const SizedBox(height: 10),
                Row(children: [
                  Expanded(
                    child: GrayButton(
                      label: paused ? tr('Продолжить', 'Davom etish') : tr('Пауза', 'Pauza'),
                      icon: paused ? Icons.play_arrow_rounded : Icons.pause_rounded,
                      onPressed: _busy ? null : _pause,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: GrayButton(label: tr('Закончить', 'Tugatish'), icon: Icons.stop_circle_rounded, danger: true, busy: _busy, onPressed: _finish),
                  ),
                ]),
              ]),
            ),
          ]),
        ),
      ]),
    );
  }
}

/// П3 · «Здесь уже прошёл …» — кто и когда, сколько магазинов отмечено рядом.
class _OtherBanner extends StatelessWidget {
  const _OtherBanner({required this.here, required this.onWay, required this.onClose});

  final Map<String, dynamic> here;
  final VoidCallback onWay;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final places = (here['places'] as num?)?.toInt() ?? 0;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(color: AppColors.white, borderRadius: BorderRadius.circular(18), boxShadow: shadow),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const IconBox(icon: Icons.vibration_rounded, color: AppColors.warning, bg: AppColors.warningSoft, size: 40),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(tr('Здесь уже прошёл ${here['rep_name']}', 'Bu yerdan ${here['rep_name']} oʻtgan'), style: AppText.bodyStrong),
              Text(
                [
                  shortDate(here['first_at']),
                  if (places > 0) tr('рядом отмечено: ${storesCount(places)}', 'yaqinda belgilangan: ${storesCount(places)}'),
                ].join(' · '),
                style: AppText.small,
              ),
            ]),
          ),
        ]),
        const SizedBox(height: 10),
        Row(children: [
          Expanded(child: BigButton(label: tr('Путь до белой зоны', 'Oq hududga yoʻl'), icon: Icons.directions_rounded, height: 42, onPressed: onWay)),
          const SizedBox(width: 8),
          Expanded(child: GrayButton(label: tr('Понятно', 'Tushunarli'), height: 42, onPressed: onClose)),
        ]),
      ]),
    );
  }
}

/// П8 «Потом» — флажок «зайти потом» одним нажатием.
class _LaterButton extends StatelessWidget {
  const _LaterButton({required this.onPressed});

  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final on = onPressed != null;
    return SizedBox(
      width: 124,
      height: 52,
      child: Material(
        color: on ? FlagColors.soft : AppColors.soft,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: BorderSide(color: on ? FlagColors.amber : AppColors.line, width: 1.5),
        ),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: onPressed,
          child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            Icon(Icons.flag_rounded, size: 20, color: on ? FlagColors.amber : AppColors.muted),
            const SizedBox(width: 6),
            Text(tr('Потом', 'Keyin'), style: AppText.bodyStrong.copyWith(color: on ? FlagColors.ink : AppColors.muted, fontSize: 16)),
          ]),
        ),
      ),
    );
  }
}
