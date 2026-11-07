import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:provider/provider.dart';
import 'package:sm_core/sm_core.dart';

import 'flags.dart';
import 'logic.dart';
import 'map_view.dart';
import 'places.dart';
import 'tracker.dart';
import 'ui.dart';

/// Флажок — не дальше от продажника (сервер проверяет 500 м с запасом).
const flagMaxFromMeM = 300.0;

/// Ближе — «Это тот же магазин?» (как на сервере: flagDupM / flagPlaceM).
const flagSameM = 30.0;

/// П12 · «Где магазин?» — карта с флажком в центре: продажник двигает карту к
/// магазину и ставит флажок. П13 — рядом уже флажок или отметка: «Это тот же
/// магазин?» → «Да, это он» (открыть его) / «Нет, другой» (поставить всё равно).
/// Вернёт поставленный флажок или null.
class FlagPickerScreen extends StatefulWidget {
  const FlagPickerScreen({super.key, required this.start, this.onMark, this.onRoute, this.onChanged});

  /// Где продажник сейчас — с этого места начинаем.
  final LatLng start;

  /// «Я здесь — отметить магазин» в шторке существующего флажка.
  final VoidCallback? onMark;
  final ValueChanged<LatLng>? onRoute;

  /// Флажок поменяли в шторке (фото, название, удалили) — обновить карту обхода.
  final VoidCallback? onChanged;

  @override
  State<FlagPickerScreen> createState() => _FlagPickerScreenState();
}

class _FlagPickerScreenState extends State<FlagPickerScreen> {
  final _map = MapController();
  final _mapKey = GlobalKey<CoverageMapState>();
  late LatLng _center = widget.start;
  bool _ready = false;
  bool _busy = false;

  /// Что сервер нашёл рядом (если на карте этого ещё не было): флажок или отметка.
  ({Map<String, dynamic> item, bool isFlag, double distanceM})? _serverNear;

  @override
  void dispose() {
    _map.dispose();
    super.dispose();
  }

  /// setState безопасно и посреди отрисовки карты (камера двигается в layout).
  void _update(VoidCallback fn) {
    if (!mounted) return;
    if (SchedulerBinding.instance.schedulerPhase == SchedulerPhase.persistentCallbacks) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(fn);
      });
    } else {
      setState(fn);
    }
  }

  LatLng get _me {
    final p = context.read<Tracker>().position;
    return p == null ? widget.start : LatLng(p.latitude, p.longitude);
  }

  void _toMe() {
    if (_ready) _map.move(_me, _map.camera.zoom < 17 ? 18 : _map.camera.zoom);
  }

  Future<void> _place({bool force = false}) async {
    setState(() => _busy = true);
    final nav = Navigator.of(context);
    try {
      final f = await context.read<Api>().post('/field/flags', {
        'lat': _center.latitude,
        'lng': _center.longitude,
        if (force) 'force': true,
      }) as Map<String, dynamic>;
      if (mounted) nav.pop(f);
    } on ApiError catch (e) {
      if (!mounted) return;
      final flag = e.details['flag'];
      final place = e.details['place'];
      if (e.code == 'flag_near' && flag is Map<String, dynamic>) {
        setState(() => _serverNear = (item: flag, isFlag: true, distanceM: ((flag['distance_m'] as num?) ?? 0).toDouble()));
      } else if (e.code == 'place_near' && place is Map<String, dynamic>) {
        setState(() => _serverNear = (item: place, isFlag: false, distanceM: ((place['distance_m'] as num?) ?? 0).toDouble()));
      } else {
        showSnack(context, e.message);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// «Да, это он» — открыть существующий флажок или отметку.
  Future<void> _openNear(({Map<String, dynamic> item, bool isFlag, double distanceM}) near) async {
    final nav = Navigator.of(context);
    if (near.isFlag) {
      await showFlagSheet(context, near.item, onMark: widget.onMark == null ? null : () {
        nav.pop();
        widget.onMark!();
      }, onRoute: widget.onRoute == null ? null : (p) {
        nav.pop();
        widget.onRoute!(p);
      }, onChanged: () {
        _mapKey.currentState?.reload();
        _update(() => _serverNear = null);
        widget.onChanged?.call();
      });
    } else {
      await showPlaceSheet(context, '${near.item['id']}');
    }
  }

  @override
  Widget build(BuildContext context) {
    final top = MediaQuery.paddingOf(context).top;
    final bottom = MediaQuery.paddingOf(context).bottom;
    final pos = context.watch<Tracker>().position;
    final me = pos == null ? widget.start : LatLng(pos.latitude, pos.longitude);
    final fromMe = distanceM(me.latitude, me.longitude, _center.latitude, _center.longitude);
    final tooFar = fromMe > flagMaxFromMeM;
    final near = _serverNear ?? _mapKey.currentState?.nearest(_center, flagSameM);
    return Scaffold(
      body: Stack(children: [
        Positioned.fill(
          child: CoverageMap(
            key: _mapKey,
            controller: _map,
            initialCenter: widget.start,
            initialZoom: 18,
            onReady: () => _update(() => _ready = true),
            onLoaded: () => _update(() {}),
            onMove: (c) => _update(() {
              _center = c;
              _serverNear = null;
            }),
          ),
        ),
        // Флажок в центре карты: остриё ножки — точка магазина.
        IgnorePointer(
          child: Center(
            child: Transform.translate(
              offset: const Offset(0, -33),
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                const FlagDot(size: 44),
                Container(width: 3, height: 22, decoration: BoxDecoration(color: AppColors.ink, borderRadius: BorderRadius.circular(2))),
                Container(width: 14, height: 6, decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.25), borderRadius: BorderRadius.circular(6))),
              ]),
            ),
          ),
        ),
        IgnorePointer(
          child: Center(
            child: Transform.translate(
              offset: const Offset(0, 24),
              child: Container(
                padding: const EdgeInsets.fromLTRB(10, 6, 12, 6),
                decoration: BoxDecoration(color: tooFar ? AppColors.error : AppColors.ink, borderRadius: BorderRadius.circular(20)),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  const Icon(Icons.straighten_rounded, size: 14, color: AppColors.white),
                  const SizedBox(width: 6),
                  Text(tr('${formatDistance(fromMe)} от вас', 'sizdan ${formatDistance(fromMe)}'), style: AppText.caption.copyWith(color: AppColors.white)),
                ]),
              ),
            ),
          ),
        ),
        Positioned(
          left: 12,
          right: 12,
          top: top + 8,
          child: Container(
            padding: const EdgeInsets.fromLTRB(6, 6, 16, 6),
            decoration: BoxDecoration(color: AppColors.white, borderRadius: BorderRadius.circular(18), boxShadow: shadow),
            child: Row(children: [
              IconButton(icon: const Icon(Icons.arrow_back_rounded), onPressed: () => Navigator.of(context).pop()),
              const SizedBox(width: 4),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                  Text(tr('Где магазин?', 'Doʻkon qayerda?'), style: AppText.bodyStrong.copyWith(fontSize: 16)),
                  Text(tr('Двигайте карту — флажок в центре', 'Xaritani suring — bayroqcha markazda'), style: AppText.small),
                ]),
              ),
            ]),
          ),
        ),
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Align(
              alignment: Alignment.centerRight,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                child: MapButton(icon: Icons.my_location_rounded, color: AppColors.primary, tooltip: tr('Где я', 'Men qayerdaman'), onTap: _toMe),
              ),
            ),
            Container(
              padding: EdgeInsets.fromLTRB(16, 16, 16, 12 + bottom),
              decoration: const BoxDecoration(
                color: AppColors.white,
                borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
                boxShadow: [BoxShadow(color: Color(0x1A000000), blurRadius: 16, offset: Offset(0, -2))],
              ),
              child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                if (near != null && !tooFar)
                  _SameStoreCard(near: near, busy: _busy, onYes: () => _openNear(near), onNo: () => _place(force: true))
                else ...[
                  BigButton(
                    label: tooFar
                        ? tr('Подойдите ближе — ${formatDistance(fromMe)}', 'Yaqinroq boring — ${formatDistance(fromMe)}')
                        : tr('Поставить флажок здесь', 'Bayroqchani shu yerga qoʻyish'),
                    icon: Icons.flag_rounded,
                    color: FlagColors.amber,
                    busy: _busy,
                    onPressed: tooFar || !_ready ? null : _place,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    tooFar
                        ? tr('Флажок — не дальше 300 м от вас', 'Bayroqcha sizdan 300 m dan uzoq boʻlmasin')
                        : tr('Флажок увидят все продажники. Фото и название — потом, по желанию', 'Bayroqchani barcha agentlar koʻradi. Rasm va nom — keyin, ixtiyoriy'),
                    textAlign: TextAlign.center,
                    style: AppText.small.copyWith(fontSize: 12),
                  ),
                ],
              ]),
            ),
          ]),
        ),
      ]),
    );
  }
}

/// П13 · «Рядом уже флажок — 12 м. Это тот же магазин?»
class _SameStoreCard extends StatelessWidget {
  const _SameStoreCard({required this.near, required this.busy, required this.onYes, required this.onNo});

  final ({Map<String, dynamic> item, bool isFlag, double distanceM}) near;
  final bool busy;
  final VoidCallback onYes;
  final VoidCallback onNo;

  @override
  Widget build(BuildContext context) {
    final it = near.item;
    final name = '${it['name'] ?? ''}'.trim();
    final d = formatDistance(near.distanceM);
    final title = near.isFlag
        ? tr('Рядом уже флажок — $d. Это тот же магазин?', 'Yaqinda bayroqcha bor — $d. Shu doʻkonmi?')
        : tr('Рядом отмечен магазин — $d. Это он?', 'Yaqinda belgilangan doʻkon — $d. Shumi?');
    final sub = near.isFlag
        ? [if (name.isNotEmpty) name, flagSubtitle(it)].join(' · ')
        : [if (name.isNotEmpty) name, resultLabel('${it['result']}'), '${it['rep_name'] ?? ''}'].where((s) => s.isNotEmpty).join(' · ');
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(color: FlagColors.soft, borderRadius: BorderRadius.circular(14)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          near.isFlag ? FlagDot(fromMap: it['source'] == 'osm') : PlaceDot(result: '${it['result']}'),
          const SizedBox(width: 10),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title, style: AppText.bodyStrong),
              if (sub.isNotEmpty) Text(sub, style: AppText.small, maxLines: 1, overflow: TextOverflow.ellipsis),
            ]),
          ),
        ]),
        const SizedBox(height: 10),
        Row(children: [
          Expanded(
            child: SizedBox(
              height: 44,
              child: OutlinedButton(
                style: OutlinedButton.styleFrom(
                  side: const BorderSide(color: FlagColors.amber, width: 1.5),
                  backgroundColor: AppColors.white,
                  foregroundColor: FlagColors.ink,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ),
                onPressed: busy ? null : onYes,
                child: Text(tr('Да, это он', 'Ha, shu'), style: AppText.bodyStrong.copyWith(color: FlagColors.ink, fontSize: 14)),
              ),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(child: BigButton(label: tr('Нет, другой', 'Yoʻq, boshqa'), color: FlagColors.amber, height: 44, busy: busy, onPressed: onNo)),
        ]),
        const SizedBox(height: 8),
        Text(
          tr('В одном доме бывает несколько магазинов — ставьте каждый отдельно.', 'Bir uyda bir nechta doʻkon boʻladi — har birini alohida qoʻying.'),
          style: AppText.small.copyWith(fontSize: 12),
        ),
      ]),
    );
  }
}
