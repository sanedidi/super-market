import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:sm_core/sm_core.dart';

import 'logic.dart';
import 'tracker.dart';
import 'ui.dart';
import 'visit_form.dart';

/// П4 «Что с этим магазином?»: отметка ставится там, где стоит продажник.
/// Если ближе 50 м уже есть отметка — сначала «Это он?», чтобы не было дублей.
/// Возвращает true, если магазин отметили.
Future<bool> markStore(BuildContext context) async {
  final api = context.read<Api>();
  final tracker = context.read<Tracker>();
  final nav = Navigator.of(context);
  var pos = tracker.position;
  if (pos == null || DateTime.now().difference(pos.timestamp).inSeconds > 60) {
    pos = await currentPosition();
  }
  if (!context.mounted) return false;
  if (pos == null) {
    await infoSheet(
      context,
      title: tr('Нет геопозиции', 'Geojoylashuv yoʻq'),
      text: tr('Включите геолокацию и выйдите на открытое место — отметка ставится там, где вы стоите.',
          'Geojoylashuvni yoqing va ochiq joyga chiqing — belgi siz turgan joyga qoʻyiladi.'),
      icon: Icons.location_off_rounded,
    );
    return false;
  }
  final point = VisitPoint(pos.latitude, pos.longitude, pos.accuracy);
  var near = <Map<String, dynamic>>[];
  try {
    near = await api.list('/field/places/near', {'lat': pos.latitude.toStringAsFixed(6), 'lng': pos.longitude.toStringAsFixed(6)});
  } catch (_) {
    // Нет сети — отметим как новый; сервер всё равно проверит дубль заявки.
  }
  if (!context.mounted) return false;
  final choice = await showSheet<(String, Map<String, dynamic>?)>(context, (ctx) => _MarkSheet(point: point, near: near));
  if (choice == null) return false;
  final ok = await nav.push<bool>(MaterialPageRoute(builder: (_) => VisitFormScreen(result: choice.$1, point: point, place: choice.$2)));
  return ok == true;
}

class _MarkSheet extends StatefulWidget {
  const _MarkSheet({required this.point, required this.near});

  final VisitPoint point;
  final List<Map<String, dynamic>> near;

  @override
  State<_MarkSheet> createState() => _MarkSheetState();
}

class _MarkSheetState extends State<_MarkSheet> {
  /// «Это он — обновить»: отметка этого магазина.
  Map<String, dynamic>? _place;
  bool _other = false;

  @override
  Widget build(BuildContext context) {
    final near = widget.near.isEmpty || _other ? null : widget.near.first;
    final acc = widget.point.accuracy;
    final options = [
      ('lead', Icons.add_business_rounded, tr('Подключить — новый магазин', 'Ulash — yangi doʻkon'),
          tr('Заявка супер-админу: название, владелец, телефон', 'Super-adminga ariza: nomi, egasi, telefoni')),
      ('refused', Icons.block_rounded, tr('Отказ', 'Rad etdi'), tr('Не хотят — фото витрины и причина', 'Xohlamaydi — vitrina surati va sabab')),
      ('closed', Icons.do_not_disturb_on_rounded, tr('Закрыт / не работает', 'Yopiq / ishlamaydi'),
          tr('Пустое помещение или закрыт навсегда', 'Boʻsh joy yoki butunlay yopilgan')),
      ('later', Icons.schedule_rounded, tr('Прийти позже', 'Keyinroq kelish'),
          tr('Владельца нет — выберите день, магазин появится в «Сегодня прийти»', 'Egasi yoʻq — kunni tanlang, doʻkon «Bugun kelish»da chiqadi')),
      ('ours', Icons.verified_rounded, tr('Уже с Super Market', 'Allaqachon Super Market’da'),
          tr('Магазин уже работает в Super Market', 'Doʻkon allaqachon Super Market’da ishlaydi')),
    ];
    return Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
      Text(tr('Что с этим магазином?', 'Bu doʻkon bilan nima?'), style: AppText.h2),
      const SizedBox(height: 6),
      Row(children: [
        const Icon(Icons.location_on_rounded, size: 18, color: AppColors.primary),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            _place != null
                ? tr('Обновляем отметку магазина рядом', 'Yaqindagi doʻkon belgisini yangilaymiz')
                : tr('Там, где вы стоите${acc != null ? ' · точность ${acc.round()} м' : ''}', 'Siz turgan joyda${acc != null ? ' · aniqlik ${acc.round()} m' : ''}'),
            style: AppText.small,
          ),
        ),
      ]),
      if (near != null && _place == null) ...[
        const SizedBox(height: 12),
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(color: AppColors.warningSoft, borderRadius: BorderRadius.circular(16)),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const IconBox(icon: Icons.storefront_rounded, color: AppColors.warning, bg: AppColors.white),
              const SizedBox(width: 10),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(tr('Рядом уже отмечен магазин — ${near['distance_m']} м', 'Yaqinda doʻkon belgilangan — ${near['distance_m']} m'), style: AppText.bodyStrong),
                  Text(
                    [
                      if ('${near['name'] ?? ''}'.trim().isNotEmpty) '${near['name']}',
                      resultLabel('${near['result']}'),
                      '${near['mine'] == true ? tr('вы', 'siz') : near['rep_name']}, ${shortDate(near['last_visit_at'])}',
                    ].join(' · '),
                    style: AppText.small,
                  ),
                ]),
              ),
            ]),
            const SizedBox(height: 10),
            Row(children: [
              Expanded(child: BigButton(label: tr('Это он — обновить', 'Bu oʻsha — yangilash'), height: 42, onPressed: () => setState(() => _place = near))),
              const SizedBox(width: 8),
              Expanded(
                child: BigButton(
                  label: tr('Нет, другой', 'Yoʻq, boshqa'),
                  height: 42,
                  color: AppColors.white,
                  foreground: AppColors.ink,
                  onPressed: () => setState(() => _other = true),
                ),
              ),
            ]),
          ]),
        ),
      ],
      const SizedBox(height: 12),
      Container(
        decoration: BoxDecoration(borderRadius: BorderRadius.circular(16), border: Border.all(color: AppColors.line)),
        child: Column(children: [
          for (var i = 0; i < options.length; i++) ...[
            if (i > 0) const Divider(height: 1, color: AppColors.line),
            _option(options[i].$1, options[i].$2, options[i].$3, options[i].$4),
          ],
        ]),
      ),
    ]);
  }

  Widget _option(String result, IconData icon, String title, String sub) {
    final s = ResultStyle.of(result);
    // «Подключить» для уже отмеченного магазина — тоже можно (передумали после отказа).
    return InkWell(
      onTap: () => Navigator.of(context).pop((result, _place)),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
        child: Row(children: [
          IconBox(icon: icon, color: s.color, bg: s.bg),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title, style: AppText.bodyStrong),
              Text(sub, style: AppText.small),
            ]),
          ),
          const Icon(Icons.chevron_right_rounded, color: AppColors.muted),
        ]),
      ),
    );
  }
}
