import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:latlong2/latlong.dart';
import 'package:provider/provider.dart';
import 'package:sm_core/sm_core.dart';

import 'flag_picker.dart';
import 'logic.dart';
import 'tracker.dart';
import 'ui.dart';

// «Зайти потом» (Figma П8–П11): продажник увидел магазин по дороге — одно
// нажатие «Потом», жёлтый флажок там, где он стоит, и идёт дальше. Флажки
// видят все продажники; флажок закрывается, когда кто-то отметит магазин рядом.

/// Цвета флажка.
class FlagColors {
  static const amber = Color(0xFFF59E0B);
  static const soft = Color(0xFFFFF4D6);
  static const ink = Color(0xFF8C5404);
}

/// Жёлтый флажок на карте.
class FlagDot extends StatelessWidget {
  const FlagDot({super.key, this.size = 26, this.old = false, this.fromMap = false});

  final double size;

  /// Старше 14 дней — бледнее.
  final bool old;

  /// Магазин с карты OpenStreetMap (никто ещё не был) — белый с жёлтой рамкой.
  final bool fromMap;

  @override
  Widget build(BuildContext context) => Opacity(
        opacity: old && !fromMap ? 0.6 : 1,
        child: Container(
          width: size,
          height: size,
          decoration: BoxDecoration(
            color: fromMap ? AppColors.white : FlagColors.amber,
            borderRadius: BorderRadius.circular(size * 0.32),
            border: Border.all(color: fromMap ? FlagColors.amber : AppColors.white, width: 2),
            boxShadow: shadow,
          ),
          child: Icon(fromMap ? Icons.outlined_flag : Icons.flag_rounded, size: size * 0.58, color: fromMap ? FlagColors.amber : AppColors.white),
        ),
      );
}

LatLng? flagPoint(Map<String, dynamic> f) {
  final lat = (f['lat'] as num?)?.toDouble(), lng = (f['lng'] as num?)?.toDouble();
  return lat == null || lng == null ? null : LatLng(lat, lng);
}

/// П8 «Потом» → П12 «Где магазин?»: продажник двигает карту к магазину и ставит
/// флажок. Потом — подсказка «Флажок поставлен · + Фото · Отменить» (10 с).
/// Вернёт флажок или null. onMark / onRoute — для шторки уже стоящего флажка (П13 «Да, это он»).
Future<Map<String, dynamic>?> placeFlag(BuildContext context, {VoidCallback? onChanged, VoidCallback? onMark, ValueChanged<LatLng>? onRoute}) async {
  final api = context.read<Api>();
  final tracker = context.read<Tracker>();
  final messenger = ScaffoldMessenger.of(context);
  final nav = Navigator.of(context);
  var pos = tracker.position;
  if (pos == null || DateTime.now().difference(pos.timestamp).inSeconds > 30) {
    pos = await currentPosition();
  }
  if (!context.mounted) return null;
  if (pos == null) {
    showSnack(context, tr('Нет геопозиции — включите GPS', 'Geojoylashuv yoʻq — GPS ni yoqing'));
    return null;
  }
  final start = LatLng(pos.latitude, pos.longitude);
  final f = await nav.push<Map<String, dynamic>>(MaterialPageRoute(
    builder: (_) => FlagPickerScreen(start: start, onMark: onMark, onRoute: onRoute, onChanged: onChanged),
  ));
  if (f == null) return null;
  HapticFeedback.mediumImpact();
  onChanged?.call();
  if (!context.mounted) return f;
  messenger.hideCurrentSnackBar();
  messenger.showSnackBar(SnackBar(
    duration: const Duration(seconds: 10),
    behavior: SnackBarBehavior.floating,
    backgroundColor: AppColors.ink,
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
    content: Row(children: [
      const Icon(Icons.flag_rounded, color: FlagColors.amber, size: 20),
      const SizedBox(width: 10),
      Expanded(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
          Text(tr('Флажок поставлен', 'Bayroqcha qoʻyildi'), style: AppText.bodyStrong.copyWith(color: AppColors.white, fontSize: 14)),
          Text(tr('Его видят все продажники', 'Uni barcha savdo agentlari koʻradi'), style: AppText.small.copyWith(color: AppColors.muted, fontSize: 12)),
        ]),
      ),
      TextButton(
        onPressed: () {
          messenger.hideCurrentSnackBar();
          if (context.mounted) showFlagSheet(context, f, justPlaced: true, onChanged: onChanged);
        },
        child: Text(tr('+ Фото', '+ Rasm'), style: AppText.bodyStrong.copyWith(color: FlagColors.amber, fontSize: 14)),
      ),
      TextButton(
        onPressed: () async {
          messenger.hideCurrentSnackBar();
          try {
            await api.delete('/field/flags/${f['id']}');
            onChanged?.call();
          } on ApiError catch (e) {
            messenger.showSnackBar(SnackBar(content: Text(e.message)));
          }
        },
        child: Text(tr('Отменить', 'Bekor qilish'), style: AppText.bodyStrong.copyWith(color: AppColors.white, fontSize: 14)),
      ),
    ]),
  ));
  return f;
}

/// П9 (свой, только что поставлен) и П10 (чужой) — шторка флажка.
/// onMark — «Я здесь — отметить магазин» (только во время обхода);
/// onRoute — «Маршрут»: показать флажок на карте.
Future<void> showFlagSheet(
  BuildContext context,
  Map<String, dynamic> flag, {
  bool justPlaced = false,
  VoidCallback? onChanged,
  VoidCallback? onMark,
  ValueChanged<LatLng>? onRoute,
}) {
  final api = context.read<Api>();
  return showSheet<void>(
    context,
    (ctx) => _FlagSheet(api: api, flag: flag, justPlaced: justPlaced, onChanged: onChanged, onMark: onMark, onRoute: onRoute),
  );
}

class _FlagSheet extends StatefulWidget {
  const _FlagSheet({required this.api, required this.flag, required this.justPlaced, this.onChanged, this.onMark, this.onRoute});

  final Api api;
  final Map<String, dynamic> flag;
  final bool justPlaced;
  final VoidCallback? onChanged;
  final VoidCallback? onMark;
  final ValueChanged<LatLng>? onRoute;

  @override
  State<_FlagSheet> createState() => _FlagSheetState();
}

class _FlagSheetState extends State<_FlagSheet> {
  late Map<String, dynamic> _f = widget.flag;
  late final _name = TextEditingController(text: '${widget.flag['name'] ?? ''}');
  bool _uploading = false;
  bool _busy = false;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  bool get _mine => _f['mine'] == true;
  bool get _open => '${_f['status'] ?? 'open'}' == 'open';

  Future<void> _patch(Map<String, dynamic> body) async {
    final f = await widget.api.patch('/field/flags/${_f['id']}', body) as Map<String, dynamic>;
    if (!mounted) return;
    setState(() => _f = {..._f, ...f, if (_f['distance_m'] != null) 'distance_m': _f['distance_m']});
    widget.onChanged?.call();
  }

  Future<void> _takePhoto() async {
    XFile? file;
    try {
      file = await ImagePicker().pickImage(source: ImageSource.camera, maxWidth: 1600, imageQuality: 80);
    } catch (_) {
      if (mounted) showSnack(context, tr('Нет доступа к камере — разрешите его в настройках', 'Kameraga ruxsat yoʻq — sozlamalarda ruxsat bering'));
      return;
    }
    if (file == null || !mounted) return;
    setState(() => _uploading = true);
    try {
      final bytes = await file.readAsBytes();
      final res = await widget.api.upload('/field/uploads', bytes, 'shop.jpg') as Map<String, dynamic>;
      await _patch({'photo_url': '${res['url']}'});
    } on ApiError catch (e) {
      if (mounted) showSnack(context, e.message);
    } finally {
      if (mounted) setState(() => _uploading = false);
    }
  }

  /// Сохранить название, если поменяли. false — не получилось.
  Future<bool> _saveName() async {
    final name = _name.text.trim();
    if (!_open || name == '${_f['name'] ?? ''}') return true;
    setState(() => _busy = true);
    try {
      await _patch({'name': name});
      return true;
    } on ApiError catch (e) {
      if (mounted) showSnack(context, e.message);
      return false;
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _done() async {
    final nav = Navigator.of(context);
    if (await _saveName() && mounted) nav.pop();
  }

  Future<void> _remove({required bool notStore}) async {
    final ok = await confirmSheet(
      context,
      title: notStore ? tr('Это не магазин?', 'Bu doʻkon emasmi?') : tr('Удалить флажок?', 'Bayroqchani oʻchirasizmi?'),
      text: notStore
          ? tr('Флажок уберётся у всех продажников.', 'Bayroqcha barcha savdo agentlarida olib tashlanadi.')
          : tr('Флажок пропадёт с карты.', 'Bayroqcha xaritadan yoʻqoladi.'),
      confirm: notStore ? tr('Не магазин — убрать', 'Doʻkon emas — olib tashlash') : tr('Удалить', 'Oʻchirish'),
      icon: notStore ? Icons.close_rounded : Icons.delete_outline_rounded,
    );
    if (!ok || !mounted) return;
    final nav = Navigator.of(context);
    setState(() => _busy = true);
    try {
      if (notStore) {
        await widget.api.post('/field/flags/${_f['id']}/not-store');
      } else {
        await widget.api.delete('/field/flags/${_f['id']}');
      }
      widget.onChanged?.call();
      if (mounted) nav.pop();
    } on ApiError catch (e) {
      if (mounted) {
        showSnack(context, e.message);
        setState(() => _busy = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final name = '${_f['name'] ?? ''}'.trim();
    final photo = '${_f['photo_url'] ?? ''}';
    final dist = (_f['distance_m'] as num?)?.toInt();
    final point = flagPoint(_f);
    final editName = widget.justPlaced || (_mine && _open) || (_open && name.isEmpty);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
      Row(children: [
        const IconBox(icon: Icons.flag_rounded, color: FlagColors.amber, bg: FlagColors.soft, size: 44),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(
              widget.justPlaced ? tr('Флажок «зайти потом»', '«Keyin kirish» bayroqchasi') : (name.isEmpty ? tr('Зайти потом', 'Keyin kirish') : name),
              style: AppText.h2.copyWith(fontSize: 20),
            ),
            const SizedBox(height: 2),
            Text(
              [
                if (_f['source'] == 'osm')
                  tr('С карты OpenStreetMap', 'OpenStreetMap xaritasidan')
                else
                  _mine ? tr('Вы поставили', 'Siz qoʻydingiz') : tr('Поставил ${_f['rep_name']}', '${_f['rep_name']} qoʻydi'),
                flagWhen(_f),
                if (_f['old'] == true) tr('давно', 'ancha oldin'),
                if (dist != null) tr('$dist м от вас', 'sizdan $dist m'),
              ].where((s) => s.isNotEmpty).join(' · '),
              style: AppText.small.copyWith(color: FlagColors.ink, fontWeight: FontWeight.w600),
            ),
          ]),
        ),
      ]),
      if (!_open) ...[
        const SizedBox(height: 12),
        Pill(
          _f['close_reason'] == 'visited'
              ? tr('Магазин уже отметил ${_f['closed_by']}', 'Doʻkonni ${_f['closed_by']} belgilagan')
              : tr('Флажок убран', 'Bayroqcha olib tashlangan'),
          icon: Icons.check_rounded,
        ),
      ],
      if (widget.justPlaced) ...[
        const SizedBox(height: 10),
        Text(tr('Флажок уже сохранён — заполнять ничего не обязательно.', 'Bayroqcha saqlandi — hech narsa toʻldirish shart emas.'), style: AppText.small),
      ],
      const SizedBox(height: 14),
      // Фото витрины — по желанию; к чужому флажку тоже можно добавить.
      if (photo.isNotEmpty)
        ClipRRect(
          borderRadius: BorderRadius.circular(14),
          child: AspectRatio(
            aspectRatio: 4 / 3,
            child: Image.network(photo, fit: BoxFit.cover, errorBuilder: (_, __, ___) => Container(color: AppColors.soft)),
          ),
        )
      else if (_open)
        InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: _uploading ? null : _takePhoto,
          child: Container(
            height: 116,
            decoration: BoxDecoration(
              color: const Color(0xFFFFFBF0),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: FlagColors.amber, width: 1.5),
            ),
            child: _uploading
                ? const Center(child: CircularProgressIndicator())
                : Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                    const Icon(Icons.photo_camera_rounded, color: FlagColors.amber, size: 30),
                    const SizedBox(height: 4),
                    Text(tr('Фото витрины', 'Vitrina rasmi'), style: AppText.bodyStrong),
                    Text(tr('по желанию — так другой продажник узнает магазин', 'ixtiyoriy — shunda boshqa agent doʻkonni taniydi'), style: AppText.small.copyWith(fontSize: 12)),
                  ]),
          ),
        ),
      if (photo.isNotEmpty && _open) ...[
        const SizedBox(height: 6),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: _uploading ? null : _takePhoto,
            icon: const Icon(Icons.refresh_rounded, size: 18),
            label: Text(tr('Переснять', 'Qayta suratga olish')),
          ),
        ),
      ],
      if (editName && _open) ...[
        const SizedBox(height: 12),
        TextField(
          controller: _name,
          maxLength: 120,
          textCapitalization: TextCapitalization.sentences,
          decoration: InputDecoration(labelText: tr('Название (если видно)', 'Nomi (koʻrinsa)'), hintText: tr('Магазин у остановки', 'Bekat yonidagi doʻkon'), counterText: ''),
          onSubmitted: (_) => _done(),
        ),
      ],
      const SizedBox(height: 16),
      if (widget.justPlaced || !_open) ...[
        BigButton(label: tr('Готово', 'Tayyor'), busy: _busy, onPressed: _done),
      ] else ...[
        if (widget.onMark != null) ...[
          BigButton(
            label: tr('Я здесь — отметить магазин', 'Shu yerdaman — doʻkonni belgilash'),
            icon: Icons.add_location_alt_rounded,
            onPressed: _busy
                ? null
                : () async {
                    final onMark = widget.onMark!;
                    final nav = Navigator.of(context);
                    if (!await _saveName() || !mounted) return;
                    nav.pop();
                    onMark();
                  },
          ),
          const SizedBox(height: 10),
        ] else if (editName) ...[
          BigButton(label: tr('Сохранить', 'Saqlash'), busy: _busy, onPressed: _done),
          const SizedBox(height: 10),
        ],
        Row(children: [
          if (widget.onRoute != null && point != null) ...[
            Expanded(
              child: GrayButton(
                label: tr('Маршрут', 'Yoʻnalish'),
                icon: Icons.directions_walk_rounded,
                onPressed: () {
                  Navigator.of(context).pop();
                  widget.onRoute!(point);
                },
              ),
            ),
            const SizedBox(width: 10),
          ],
          Expanded(
            child: _mine
                ? GrayButton(label: tr('Удалить', 'Oʻchirish'), icon: Icons.delete_outline_rounded, danger: true, onPressed: _busy ? null : () => _remove(notStore: false))
                : GrayButton(label: tr('Не магазин', 'Doʻkon emas'), icon: Icons.close_rounded, danger: true, onPressed: _busy ? null : () => _remove(notStore: true)),
          ),
        ]),
      ],
      if (widget.justPlaced && _open) ...[
        const SizedBox(height: 6),
        TextButton.icon(
          onPressed: _busy ? null : () => _remove(notStore: false),
          icon: const Icon(Icons.delete_outline_rounded, color: AppColors.error, size: 18),
          label: Text(tr('Удалить флажок — поставил по ошибке', 'Bayroqchani oʻchirish — xato qoʻydim'), style: AppText.bodyStrong.copyWith(color: AppColors.error, fontSize: 14)),
        ),
      ],
      if (_open && !widget.justPlaced) ...[
        const SizedBox(height: 10),
        Text(
          tr('Флажок закроется сам, когда любой продажник отметит магазин в 50 м от него.', 'Istalgan agent 50 m ichida doʻkonni belgilasa, bayroqcha oʻzi yopiladi.'),
          style: AppText.small.copyWith(fontSize: 12),
        ),
      ],
    ]);
  }
}

/// П11 · «Зайти потом рядом» на главной: флажки всех продажников по расстоянию;
/// «Мои» — поставленные мной. onOpenMap — «Все N на карте», onShow — флажок на карте.
class FlagsNearby extends StatefulWidget {
  const FlagsNearby({super.key, required this.onOpenMap});

  final ValueChanged<LatLng?> onOpenMap;

  @override
  State<FlagsNearby> createState() => FlagsNearbyState();
}

class FlagsNearbyState extends State<FlagsNearby> {
  bool _mine = false;
  Map<String, dynamic>? _data;
  int _seq = 0;

  @override
  void initState() {
    super.initState();
    reload();
  }

  Future<void> reload() async {
    if (!mounted) return;
    final seq = ++_seq;
    final api = context.read<Api>();
    final tracker = context.read<Tracker>();
    final pos = tracker.position ?? await currentPosition();
    try {
      final d = await api.get('/field/flags', {
        if (pos != null) 'lat': pos.latitude.toStringAsFixed(6),
        if (pos != null) 'lng': pos.longitude.toStringAsFixed(6),
        if (_mine) 'mine': '1',
        'limit': '3',
      }) as Map<String, dynamic>;
      if (mounted && seq == _seq) setState(() => _data = d);
    } catch (_) {
      // Нет сети — блок просто не обновится.
    }
  }

  @override
  Widget build(BuildContext context) {
    final d = _data;
    if (d == null) return const SizedBox.shrink();
    final all = (d['all'] as num?)?.toInt() ?? 0;
    final mine = (d['mine'] as num?)?.toInt() ?? 0;
    if (all == 0) return const SizedBox.shrink();
    final items = ((d['items'] as List?) ?? const []).cast<Map<String, dynamic>>();
    Widget chip(String label, bool on, bool mineValue) => Padding(
          padding: const EdgeInsets.only(left: 6),
          child: ChoiceChip(
            label: Text(label),
            selected: on,
            showCheckmark: false,
            selectedColor: AppColors.ink,
            backgroundColor: AppColors.soft,
            side: BorderSide.none,
            labelStyle: AppText.caption.copyWith(color: on ? AppColors.white : AppColors.ink, fontSize: 13),
            onSelected: (_) {
              if (_mine == mineValue) return;
              setState(() => _mine = mineValue);
              reload();
            },
          ),
        );
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      const SizedBox(height: 18),
      Row(children: [
        const Icon(Icons.flag_rounded, color: FlagColors.amber, size: 20),
        const SizedBox(width: 6),
        Expanded(child: Text(tr('Зайти потом рядом', 'Yaqinda keyin kirish'), style: AppText.title.copyWith(fontSize: 15))),
        chip(tr('Все · $all', 'Hammasi · $all'), !_mine, false),
        chip(tr('Мои · $mine', 'Meniki · $mine'), _mine, true),
      ]),
      const SizedBox(height: 8),
      AppCard(
        padding: EdgeInsets.zero,
        child: Column(children: [
          if (items.isEmpty)
            Padding(
              padding: const EdgeInsets.all(14),
              child: Text(tr('Своих флажков нет — ставьте «Потом» во время обхода', 'Bayroqchalaringiz yoʻq — aylanishda «Keyin» ni bosing'), style: AppText.small),
            ),
          for (var i = 0; i < items.length; i++) ...[
            if (i > 0) const Divider(height: 1, color: AppColors.line),
            _FlagRow(
              f: items[i],
              onTap: () => showFlagSheet(context, items[i], onChanged: reload, onRoute: (p) => widget.onOpenMap(p)),
            ),
          ],
          const Divider(height: 1, color: AppColors.line),
          InkWell(
            onTap: () => widget.onOpenMap(null),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Center(
                child: Text(tr('Все ${_mine ? mine : all} на карте →', 'Hammasi (${_mine ? mine : all}) xaritada →'),
                    style: AppText.bodyStrong.copyWith(color: AppColors.primary, fontSize: 14)),
              ),
            ),
          ),
        ]),
      ),
    ]);
  }
}

class _FlagRow extends StatelessWidget {
  const _FlagRow({required this.f, required this.onTap});

  final Map<String, dynamic> f;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final name = '${f['name'] ?? ''}'.trim();
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 10, 8, 10),
        child: Row(children: [
          const IconBox(icon: Icons.flag_rounded, color: FlagColors.amber, bg: FlagColors.soft, size: 36),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(name.isEmpty ? tr('Без названия', 'Nomsiz') : name, style: AppText.bodyStrong, maxLines: 1, overflow: TextOverflow.ellipsis),
              Text(flagSubtitle(f), style: AppText.small, maxLines: 1, overflow: TextOverflow.ellipsis),
            ]),
          ),
          if (f['distance_m'] != null) Text(formatDistance(f['distance_m']), style: AppText.bodyStrong.copyWith(fontSize: 14)),
          const Icon(Icons.chevron_right_rounded, color: AppColors.muted),
        ]),
      ),
    );
  }
}

/// Баннер во время обхода: «Рядом флажок — 60 м · Магазин у остановки».
class FlagNearBanner extends StatelessWidget {
  const FlagNearBanner({super.key, required this.flag, required this.onOpen, required this.onClose});

  final Map<String, dynamic> flag;
  final VoidCallback onOpen;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final name = '${flag['name'] ?? ''}'.trim();
    return Material(
      color: AppColors.white,
      borderRadius: BorderRadius.circular(16),
      elevation: 0,
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onOpen,
        child: Container(
          padding: const EdgeInsets.fromLTRB(12, 10, 4, 10),
          decoration: BoxDecoration(borderRadius: BorderRadius.circular(16), boxShadow: shadow, border: Border.all(color: FlagColors.amber, width: 1.5)),
          child: Row(children: [
            const FlagDot(size: 30),
            const SizedBox(width: 10),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(tr('Рядом флажок — ${formatDistance(flag['distance_m'])}', 'Yaqinda bayroqcha — ${formatDistance(flag['distance_m'])}'), style: AppText.bodyStrong),
                Text(
                  [if (name.isNotEmpty) name, flagSubtitle(flag)].join(' · '),
                  style: AppText.small,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ]),
            ),
            IconButton(visualDensity: VisualDensity.compact, icon: const Icon(Icons.close_rounded, size: 18), onPressed: onClose),
          ]),
        ),
      ),
    );
  }
}
