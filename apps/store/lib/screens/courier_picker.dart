import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:sm_core/sm_core.dart';

import '../staff/staff_screen.dart';
import '../ui/theme.dart';
import '../ui/widgets.dart';

/// Название транспорта курьера (как в панели магазина).
String vehicleTitle(String? v) => switch (v) {
      'foot' => tr('пешком', 'piyoda'),
      'bike' => tr('велосипед', 'velosiped'),
      'scooter' => tr('скутер', 'skuter'),
      'car' => tr('машина', 'mashina'),
      _ => '',
    };

/// Инициалы для аватара: «Бобур Ташев» → «БТ».
String initials(String name) {
  final parts = name.trim().split(RegExp(r'\s+')).where((p) => p.isNotEmpty).take(2);
  return parts.map((p) => p[0].toUpperCase()).join();
}

/// Круглый аватар с инициалами (Figma Н2, Ш4).
class CourierAvatar extends StatelessWidget {
  const CourierAvatar(this.name, {super.key, this.tone = ChipTone.red, this.size = 40});

  final String name;
  final ChipTone tone;
  final double size;

  @override
  Widget build(BuildContext context) {
    final (bg, fg) = StatusChip.colors(tone);
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(color: bg, shape: BoxShape.circle),
      child: Text(initials(name), style: AppText.bodyStrong.copyWith(color: fg, fontSize: 14, fontWeight: FontWeight.w700)),
    );
  }
}

/// Шторка Ш4 «Назначить курьера»: штатные курьеры магазина, сначала те, кто на смене.
/// Возвращает выбранного курьера (`employee_id`, `full_name`, `vehicle`, …) или null.
/// Если курьеров нет — Ш5 с подсказкой про право «Курьер: доставка заказов».
Future<Map<String, dynamic>?> pickCourierSheet(BuildContext context, {required String storeId, String? currentId}) =>
    showSheet<Map<String, dynamic>>(context, (ctx) => _CourierPicker(storeId: storeId, currentId: currentId));

class _CourierPicker extends StatefulWidget {
  const _CourierPicker({required this.storeId, this.currentId});

  final String storeId;
  final String? currentId;

  @override
  State<_CourierPicker> createState() => _CourierPickerState();
}

class _CourierPickerState extends State<_CourierPicker> {
  List<Map<String, dynamic>>? _items;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _error = null);
    try {
      final items = await context.read<Api>().list('/store/couriers', {'store_id': widget.storeId});
      // На смене — вверх, остальные ниже; порядок внутри групп как у сервера.
      final sorted = [...items.where((c) => c['on_shift'] == true), ...items.where((c) => c['on_shift'] != true)];
      if (mounted) setState(() => _items = sorted);
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final items = _items;
    if (_error != null) {
      return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        SheetHeader(title: tr('Не удалось загрузить курьеров', 'Kuryerlarni yuklab boʻlmadi'), text: '$_error'),
        const SizedBox(height: 20),
        SheetButton(label: tr('Повторить', 'Qayta urinish'), onPressed: _load),
        const SizedBox(height: 10),
        SheetButton(label: tr('Закрыть', 'Yopish'), primary: false, onPressed: () => Navigator.pop(context)),
      ]);
    }
    if (items == null) {
      return const Padding(padding: EdgeInsets.symmetric(vertical: 48), child: Center(child: CircularProgressIndicator()));
    }
    if (items.isEmpty) return _empty(context);
    return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      SheetHeader(
        title: tr('Назначить курьера', 'Kuryerni tayinlash'),
        text: tr('Сначала те, кто на смене. Курьер получит push о заказе и увидит адрес в своём приложении.',
            'Avval smenadagilar. Kuryer buyurtma haqida push oladi va manzilni oʻz ilovasida koʻradi.'),
      ),
      const SizedBox(height: 16),
      Container(
        padding: const EdgeInsets.symmetric(vertical: 4),
        decoration: BoxDecoration(color: AppColors.soft, borderRadius: BorderRadius.circular(20)),
        child: Column(children: [
          for (var i = 0; i < items.length; i++) ...[
            if (i > 0) const Divider(height: 1, indent: 14, endIndent: 14, color: AppColors.line),
            _tile(context, items[i]),
          ],
        ]),
      ),
      const SizedBox(height: 12),
      Text(
        tr('Нажмите на курьера — заказ назначится сразу. Сменить или снять можно в любой момент до «Доставлен».',
            'Kuryerni bosing — buyurtma darhol tayinlanadi. «Yetkazildi»gacha istalgan vaqtda almashtirish yoki olib tashlash mumkin.'),
        style: AppText.small,
      ),
      const SizedBox(height: 16),
      SheetButton(label: tr('Отмена', 'Bekor qilish'), primary: false, onPressed: () => Navigator.pop(context)),
    ]);
  }

  Widget _tile(BuildContext context, Map<String, dynamic> c) {
    final onShift = c['on_shift'] == true;
    final active = (c['active_orders'] as num?)?.toInt() ?? 0;
    final current = c['employee_id'] == widget.currentId;
    final sub = [
      vehicleTitle(c['vehicle'] as String?),
      active > 0 ? tr('заказов: $active', 'buyurtmalar: $active') : tr('свободен', 'boʻsh'),
    ].where((e) => e.isNotEmpty).join(' · ');
    return Opacity(
      opacity: onShift ? 1 : 0.55,
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: () => Navigator.pop(context, c),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          child: Row(children: [
            CourierAvatar('${c['full_name']}', tone: onShift ? ChipTone.red : ChipTone.gray),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('${c['full_name']}', style: AppText.bodyStrong),
                Text(sub, style: AppText.small),
              ]),
            ),
            const SizedBox(width: 8),
            if (current)
              const Icon(Icons.check_circle_rounded, color: AppColors.success, size: 22)
            else
              StatusChip(onShift ? tr('На смене', 'Smenada') : tr('Не на смене', 'Smenada emas'), tone: onShift ? ChipTone.green : ChipTone.gray),
          ]),
        ),
      ),
    );
  }

  /// Ш5: штатных курьеров нет — подсказываем, где выдать право.
  Widget _empty(BuildContext context) {
    return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Center(
        child: Container(
          width: 64,
          height: 64,
          decoration: const BoxDecoration(color: AppColors.primarySoft, shape: BoxShape.circle),
          child: const Icon(Icons.delivery_dining_rounded, color: AppColors.primary, size: 32),
        ),
      ),
      const SizedBox(height: 16),
      Text(tr('Нет штатных курьеров', 'Shtatdagi kuryerlar yoʻq'), style: AppText.h3, textAlign: TextAlign.center),
      const SizedBox(height: 6),
      Text(
        tr('Чтобы назначать своих курьеров, дайте сотруднику право «Курьер: доставка заказов» в разделе «Сотрудники → Роли и права». Пока заказ можно отдать курьеру по пути.',
            'Oʻz kuryerlaringizni tayinlash uchun xodimga «Xodimlar → Rollar va huquqlar» boʻlimida «Kuryer: buyurtmalarni yetkazish» huquqini bering. Hozircha buyurtmani yoʻlakay kuryerga berish mumkin.'),
        style: AppText.body.copyWith(color: AppColors.text2),
        textAlign: TextAlign.center,
      ),
      const SizedBox(height: 20),
      SheetButton(
        label: tr('К сотрудникам', 'Xodimlarga oʻtish'),
        onPressed: () {
          final nav = Navigator.of(context);
          nav.pop();
          nav.push(MaterialPageRoute(builder: (_) => const StaffScreen()));
        },
      ),
      const SizedBox(height: 10),
      SheetButton(label: tr('Закрыть', 'Yopish'), primary: false, onPressed: () => Navigator.pop(context)),
    ]);
  }
}
