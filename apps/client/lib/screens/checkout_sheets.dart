import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:sm_core/sm_core.dart';

import '../delivery_time.dart';
import '../state.dart';
import '../ui/theme.dart';
import '../ui/widgets.dart';
import 'addresses_screen.dart';

/// Выбор времени: null в поле slot — «как можно скорее».
class TimeChoice {
  const TimeChoice(this.slot);
  final Slot? slot;
}

/// «Когда привезти?» по макету: как можно скорее или окно на сегодня/завтра.
/// Возвращает выбор или null, если лист закрыли.
Future<TimeChoice?> pickDeliveryTime(BuildContext context, {required String storeId, String? eta, Slot? current}) {
  return showModalBottomSheet<TimeChoice>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    backgroundColor: AppColors.white,
    builder: (_) => _TimeSheet(storeId: storeId, eta: eta, current: current),
  );
}

class _TimeSheet extends StatefulWidget {
  const _TimeSheet({required this.storeId, this.eta, this.current});
  final String storeId;
  final String? eta;
  final Slot? current;

  @override
  State<_TimeSheet> createState() => _TimeSheetState();
}

class _TimeSheetState extends State<_TimeSheet> {
  List<SlotDay>? _days;
  bool _enabled = false;
  Object? _error;
  late bool _asap = widget.current == null;
  late Slot? _slot = widget.current;
  int _day = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final r = await context.read<Api>().get('/client/stores/${widget.storeId}/slots') as Map<String, dynamic>;
      final days = ((r['days'] as List?) ?? const []).cast<Map<String, dynamic>>().map(SlotDay.new).toList()
        ..removeWhere((d) => d.slots.isEmpty);
      if (!mounted) return;
      setState(() {
        _enabled = r['enabled'] == true;
        _days = days;
        // Открыть день выбранного окна или первый день со свободными окнами.
        final cur = _slot;
        final i = cur == null ? days.indexWhere((d) => d.slots.any((s) => s.free)) : days.indexWhere((d) => d.slots.any((s) => s.fromRaw == cur.fromRaw));
        _day = i < 0 ? 0 : i;
      });
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final days = _days;
    final slot = _slot;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(tr('Когда привезти?', 'Qachon yetkazaylik?'), style: AppText.h3),
          const SizedBox(height: 16),
          _Option(
            title: tr('Как можно скорее', 'Imkon qadar tez'),
            subtitle: widget.eta == null
                ? tr('Магазин соберёт и привезёт заказ', 'Doʻkon buyurtmani yigʻib, yetkazib beradi')
                : tr('Привезём за ${widget.eta}', '${widget.eta} ichida yetkazamiz'),
            selected: _asap,
            onTap: () => setState(() => _asap = true),
          ),
          const SizedBox(height: 10),
          if (days == null && _error == null)
            const Padding(padding: EdgeInsets.all(24), child: Center(child: CircularProgressIndicator()))
          else if (_error != null)
            Text(tr('Не удалось загрузить время доставки: $_error', 'Yetkazish vaqtini yuklab boʻlmadi: $_error'), style: AppText.small.copyWith(color: AppColors.error))
          else if (!_enabled || days!.isEmpty)
            Text(tr('Этот магазин пока доставляет только как можно скорее.', 'Bu doʻkon hozircha faqat imkon qadar tez yetkazadi.'), style: AppText.small)
          else ...[
            _Option(
              title: tr('Ко времени', 'Belgilangan vaqtga'),
              subtitle: tr('Выберите удобный час', 'Qulay soatni tanlang'),
              selected: !_asap,
              onTap: () => setState(() => _asap = false),
            ),
            if (!_asap) ...[
              const SizedBox(height: 16),
              SizedBox(
                height: 40,
                child: ListView(scrollDirection: Axis.horizontal, children: [
                  for (var i = 0; i < days.length; i++)
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: AppChip(label: days[i].label, selected: i == _day, onTap: () => setState(() => _day = i)),
                    ),
                ]),
              ),
              const SizedBox(height: 12),
              ConstrainedBox(
                constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.35),
                child: GridView.count(
                  shrinkWrap: true,
                  crossAxisCount: 3,
                  mainAxisSpacing: 8,
                  crossAxisSpacing: 8,
                  childAspectRatio: 1.9,
                  children: [
                    for (final s in days[_day].slots)
                      _SlotTile(slot: s, selected: slot?.fromRaw == s.fromRaw, onTap: s.free ? () => setState(() => _slot = s) : null),
                  ],
                ),
              ),
            ],
          ],
          const SizedBox(height: 16),
          AppButton(
            label: _asap
                ? tr('Как можно скорее', 'Imkon qadar tez')
                : (slot == null ? tr('Выберите время', 'Vaqtni tanlang') : tr('Привезти ${slot.range}', '${slot.range} da yetkazish')),
            onPressed: _asap || slot != null ? () => Navigator.pop(context, TimeChoice(_asap ? null : slot)) : null,
          ),
        ]),
      ),
    );
  }
}

class _Option extends StatelessWidget {
  const _Option({required this.title, required this.subtitle, required this.selected, required this.onTap, this.disabled = false, this.note});
  final String title;
  final String subtitle;
  final bool selected;
  final bool disabled;
  final String? note;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: selected ? AppColors.primarySoft : AppColors.white,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.lg),
        side: BorderSide(color: selected ? AppColors.primary : AppColors.line, width: selected ? 2 : 1),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(AppRadius.lg),
        onTap: disabled ? null : onTap,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(children: [
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(title, style: AppText.bodyStrong.copyWith(color: disabled ? AppColors.muted : AppColors.ink)),
                const SizedBox(height: 2),
                Text(subtitle, style: AppText.small),
                if (note != null) ...[const SizedBox(height: 2), Text(note!, style: AppText.caption.copyWith(color: AppColors.warningInk))],
              ]),
            ),
            Icon(selected ? Icons.radio_button_checked_rounded : Icons.radio_button_off_rounded,
                color: selected ? AppColors.primary : AppColors.muted),
          ]),
        ),
      ),
    );
  }
}

class _SlotTile extends StatelessWidget {
  const _SlotTile({required this.slot, required this.selected, this.onTap});
  final Slot slot;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final free = slot.free;
    final note = switch (slot.status) { 'past' => tr('прошло', 'oʻtdi'), 'full' => tr('нет мест', 'joy yoʻq'), _ => null };
    return Material(
      color: selected ? AppColors.primary : (free ? AppColors.white : AppColors.soft),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.md),
        side: BorderSide(color: selected ? AppColors.primary : (free ? AppColors.line : AppColors.soft)),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(AppRadius.md),
        onTap: onTap,
        child: Center(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Text(slot.range,
                style: AppText.smallStrong.copyWith(fontSize: 14, color: selected ? AppColors.white : (free ? AppColors.ink : AppColors.muted))),
            if (note != null) Text(note, style: AppText.caption.copyWith(color: AppColors.muted, fontSize: 11)),
          ]),
        ),
      ),
    );
  }
}

/// «Куда доставить?» по макету: адреса с пометкой, если магазин туда не
/// доставляет, и новый адрес на карте. Выбранный адрес становится текущим.
Future<void> pickDeliveryAddress(BuildContext context, {required String storeId, required String storeName}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    backgroundColor: AppColors.white,
    builder: (_) => _AddressSheet(storeId: storeId, storeName: storeName),
  );
}

class _AddressSheet extends StatefulWidget {
  const _AddressSheet({required this.storeId, required this.storeName});
  final String storeId;
  final String storeName;

  @override
  State<_AddressSheet> createState() => _AddressSheetState();
}

class _AddressSheetState extends State<_AddressSheet> {
  /// id адреса → доставляет ли магазин (null — ещё проверяем).
  final Map<String, bool> _ok = {};
  late String? _selected = context.read<AppState>().address?.id;

  @override
  void initState() {
    super.initState();
    _check();
  }

  Future<void> _check() async {
    final api = context.read<Api>();
    final list = context.read<AppState>().addresses;
    await Future.wait(list.map((a) async {
      try {
        final near = await api.list('/client/stores/nearby', {'lat': a.lat, 'lng': a.lng});
        if (mounted) setState(() => _ok[a.id] = near.any((s) => s['id'] == widget.storeId));
      } catch (_) {
        if (mounted) setState(() => _ok[a.id] = true); // не знаем — не мешаем выбрать
      }
    }));
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final chosen = state.addresses.where((a) => a.id == _selected).firstOrNull;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(tr('Куда доставить?', 'Qayerga yetkazaylik?'), style: AppText.h3),
          const SizedBox(height: 16),
          ConstrainedBox(
            constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.45),
            child: ListView(shrinkWrap: true, children: [
              for (final a in state.addresses) ...[
                _Option(
                  title: a.label.isNotEmpty ? a.label : a.address,
                  subtitle: a.label.isNotEmpty ? a.address : (a.json['apartment'] as String? ?? '').isEmpty ? tr('Адрес', 'Manzil') : tr('кв. ${a.json['apartment']}', '${a.json['apartment']}-xonadon'),
                  selected: a.id == _selected,
                  disabled: _ok[a.id] == false,
                  note: _ok[a.id] == false ? tr('${widget.storeName} сюда не доставляет', '${widget.storeName} bu yerga yetkazmaydi') : null,
                  onTap: () => setState(() => _selected = a.id),
                ),
                const SizedBox(height: 10),
              ],
            ]),
          ),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const IconBox(Icons.add_rounded, size: 44),
            title: Text(tr('Новый адрес на карте', 'Xaritada yangi manzil'), style: AppText.bodyStrong.copyWith(color: AppColors.primary)),
            onTap: () async {
              final before = state.addresses.map((a) => a.id).toSet();
              await openAddressEditor(context);
              if (!mounted) return;
              final added = context.read<AppState>().addresses.where((a) => !before.contains(a.id)).firstOrNull;
              if (added != null) setState(() => _selected = added.id);
              _check();
            },
          ),
          const SizedBox(height: 8),
          AppButton(
            label: tr('Доставить сюда', 'Shu yerga yetkazish'),
            onPressed: chosen == null || _ok[chosen.id] == false
                ? null
                : () {
                    if (chosen.id != state.address?.id) state.selectAddress(chosen);
                    Navigator.pop(context);
                  },
          ),
        ]),
      ),
    );
  }
}
