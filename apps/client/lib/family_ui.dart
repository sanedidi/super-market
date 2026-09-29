// Общие части экранов «Моя семья»: аватар участника, метка статуса просьбы,
// карточка просьбы, время напоминания.
import 'package:flutter/material.dart';

import 'ui/theme.dart';
import 'ui/widgets.dart';

/// Цвета аватаров: у каждого участника свой, по id.
const _avatarTones = [
  (bg: Color(0xFFFCE7F6), fg: Color(0xFFDD2590)),
  (bg: Color(0xFFFEF0C7), fg: Color(0xFFB54708)),
  (bg: Color(0xFFD1FADF), fg: Color(0xFF067647)),
  (bg: Color(0xFFEBE9FE), fg: Color(0xFF6938EF)),
  (bg: Color(0xFFD1E9FF), fg: Color(0xFF175CD3)),
];

({Color bg, Color fg}) avatarTone(String id) => _avatarTones[id.codeUnits.fold(0, (a, b) => a + b) % _avatarTones.length];

/// «Азиз Каримов» → «АК», «Малика» → «М».
String initials(String name) {
  final parts = name.trim().split(RegExp(r'\s+')).where((p) => p.isNotEmpty).toList();
  if (parts.isEmpty) return '?';
  return parts.take(2).map((p) => p[0].toUpperCase()).join();
}

/// Круглый аватар с инициалами. Свой — синий.
class MemberAvatar extends StatelessWidget {
  const MemberAvatar({super.key, required this.id, required this.name, this.me = false, this.size = 40});
  final String id;
  final String name;
  final bool me;
  final double size;

  @override
  Widget build(BuildContext context) {
    final t = me ? (bg: AppColors.primary, fg: AppColors.white) : avatarTone(id);
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(color: t.bg, shape: BoxShape.circle),
      child: Text(initials(name), style: AppText.bodyStrong.copyWith(color: t.fg, fontSize: size * 0.36)),
    );
  }
}

/// Имя участника для показа: подпись («Жена») или имя, или телефон.
String memberName(Map<String, dynamic> m) {
  final name = '${m['name'] ?? ''}'.trim();
  if (name.isNotEmpty) return name;
  return '${m['phone'] ?? 'Участник'}';
}

/// Метка статуса просьбы: «Ждёт», «Куплено 1/2», «Куплено», «Заказано», «Отменено».
Widget requestBadge(Map<String, dynamic> r) {
  final total = (r['items_total'] as num?)?.toInt() ?? 0;
  final bought = (r['items_bought'] as num?)?.toInt() ?? 0;
  return switch (r['status']) {
    'pending' => const AppBadge(label: 'Ждёт', kind: BadgeKind.warning),
    'partial' => AppBadge(label: 'Куплено $bought/$total', kind: BadgeKind.success),
    'bought' => const AppBadge(label: 'Куплено', kind: BadgeKind.success),
    'ordered' => const AppBadge(label: 'Заказано', kind: BadgeKind.isNew),
    _ => const AppBadge(label: 'Отменено'),
  };
}

const _months = ['января', 'февраля', 'марта', 'апреля', 'мая', 'июня', 'июля', 'августа', 'сентября', 'октября', 'ноября', 'декабря'];

String hhmm(DateTime d) => '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';

/// «сегодня в 18:00», «завтра в 7:30», «5 октября в 9:00».
String whenText(DateTime d) {
  d = d.toLocal();
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final day = DateTime(d.year, d.month, d.day);
  final diff = day.difference(today).inDays;
  final prefix = switch (diff) {
    0 => 'сегодня',
    1 => 'завтра',
    -1 => 'вчера',
    _ => '${d.day} ${_months[d.month - 1]}',
  };
  return '$prefix в ${hhmm(d)}';
}

String capitalize(String s) => s.isEmpty ? s : s[0].toUpperCase() + s.substring(1);

/// Строка про напоминание и доставку в карточке просьбы.
String? requestSchedule(Map<String, dynamic> r) {
  final remind = DateTime.tryParse('${r['remind_at'] ?? ''}');
  final offer = DateTime.tryParse('${r['deliver_offer_at'] ?? ''}');
  final atStore = r['remind_at_store'] == true;
  final parts = <String>[];
  if (remind != null && remind.isAfter(DateTime.now().subtract(const Duration(minutes: 1)))) {
    parts.add('Напомнить ${whenText(remind)}${atStore ? ' и у магазина' : ''}');
  } else if (atStore) {
    parts.add('Напомнить у магазина');
  }
  if (offer != null) parts.add('доставка домой после ${hhmm(offer.toLocal())}');
  if (parts.isEmpty) return null;
  return capitalize(parts.join(' · '));
}

/// Карточка просьбы в списке «Моя семья».
class RequestCard extends StatelessWidget {
  const RequestCard({super.key, required this.request, required this.onTap});
  final Map<String, dynamic> request;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final r = request;
    final total = (r['items_total'] as num?)?.toInt() ?? 0;
    final bought = (r['items_bought'] as num?)?.toInt() ?? 0;
    final author = '${r['author_name'] ?? ''}';
    final assignee = '${r['assignee_name'] ?? ''}';
    final who = assignee.isEmpty ? '$author → всем' : '$author → $assignee';
    final schedule = requestSchedule(r);
    return Material(
      color: AppColors.white,
      borderRadius: BorderRadius.circular(AppRadius.lg),
      child: InkWell(
        borderRadius: BorderRadius.circular(AppRadius.lg),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              MemberAvatar(id: '${r['author_id'] ?? ''}', name: author, size: 36),
              const SizedBox(width: 10),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('${r['title']}', maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.bodyStrong),
                  Text(who, maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.caption),
                ]),
              ),
              const SizedBox(width: 8),
              requestBadge(r),
            ]),
            const SizedBox(height: 10),
            Text('${r['summary'] ?? ''}', maxLines: 3, overflow: TextOverflow.ellipsis, style: AppText.body.copyWith(fontSize: 14)),
            if (schedule != null) ...[
              const SizedBox(height: 10),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                decoration: BoxDecoration(color: AppColors.soft, borderRadius: BorderRadius.circular(AppRadius.sm)),
                child: Row(children: [
                  const Icon(Icons.schedule_rounded, size: 16, color: AppColors.ink),
                  const SizedBox(width: 6),
                  Expanded(child: Text(schedule, style: AppText.smallStrong.copyWith(fontWeight: FontWeight.w500))),
                ]),
              ),
            ],
            const SizedBox(height: 12),
            Row(children: [
              Expanded(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(3),
                  child: LinearProgressIndicator(
                    value: total == 0 ? 0 : bought / total,
                    minHeight: 5,
                    backgroundColor: AppColors.line,
                    color: AppColors.success,
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Text('$bought из $total', style: AppText.caption),
            ]),
          ]),
        ),
      ),
    );
  }
}
