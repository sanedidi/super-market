import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../links.dart';
import '../state.dart';
import '../ui/theme.dart';
import '../ui/widgets.dart';

/// Уведомления (колокольчик на главной): статусы заказов, семья, акции.
/// При открытии все отмечаются прочитанными; новые подсвечены.
class NotificationsScreen extends StatefulWidget {
  const NotificationsScreen({super.key});

  @override
  State<NotificationsScreen> createState() => _NotificationsScreenState();
}

class _NotificationsScreenState extends State<NotificationsScreen> {
  List<Map<String, dynamic>>? _items;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final state = context.read<AppState>();
    try {
      final r = await state.api.get('/client/notifications') as Map<String, dynamic>;
      final items = ((r['items'] as List?) ?? const []).cast<Map<String, dynamic>>();
      if (!mounted) return;
      setState(() {
        _items = items;
        _error = null;
      });
      if (items.any((n) => n['read'] != true)) state.markAllRead().catchError((_) {});
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  void _open(Map<String, dynamic> n) {
    final data = (n['data'] as Map?)?.cast<String, dynamic>() ?? const {};
    openNotification(data);
  }

  @override
  Widget build(BuildContext context) {
    final items = _items;
    Widget body;
    if (items == null) {
      body = _error == null
          ? const Center(child: CircularProgressIndicator())
          : EmptyState(icon: Icons.wifi_off_rounded, title: 'Не удалось загрузить', text: _error.toString(), action: 'Повторить', onAction: _load);
    } else if (items.isEmpty) {
      body = const EmptyState(
        icon: Icons.notifications_none_rounded,
        title: 'Пока тихо',
        text: 'Здесь появятся статусы заказов, просьбы семьи и скидки.',
      );
    } else {
      body = RefreshIndicator(
        onRefresh: _load,
        child: ListView.separated(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
          itemCount: items.length,
          separatorBuilder: (_, __) => const SizedBox(height: 8),
          itemBuilder: (_, i) => _NotificationTile(n: items[i], onTap: () => _open(items[i])),
        ),
      );
    }
    return Scaffold(
      backgroundColor: AppColors.white,
      body: SafeArea(child: Column(children: [const PageHeader(title: 'Уведомления'), Expanded(child: body)])),
    );
  }
}

class _NotificationTile extends StatelessWidget {
  const _NotificationTile({required this.n, required this.onTap});
  final Map<String, dynamic> n;
  final VoidCallback onTap;

  static (IconData, Color) _icon(String kind) {
    if (kind.startsWith('order')) return (Icons.shopping_bag_rounded, AppColors.primary);
    if (kind.startsWith('debt')) return (Icons.account_balance_wallet_rounded, AppColors.warningInk);
    if (kind.startsWith('family')) return (Icons.family_restroom_rounded, const Color(0xFF3B6FD8));
    if (kind.startsWith('promo') || kind == 'campaign') return (Icons.campaign_rounded, const Color(0xFFD99A4E));
    return (Icons.notifications_rounded, AppColors.dark);
  }

  @override
  Widget build(BuildContext context) {
    final unread = n['read'] != true;
    final (icon, color) = _icon('${n['kind'] ?? ''}');
    final body = '${n['body'] ?? ''}';
    return Material(
      color: unread ? AppColors.primarySoft : AppColors.soft,
      borderRadius: BorderRadius.circular(AppRadius.xl),
      child: InkWell(
        borderRadius: BorderRadius.circular(AppRadius.xl),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Container(
              width: 40,
              height: 40,
              decoration: const BoxDecoration(color: AppColors.white, shape: BoxShape.circle),
              child: Icon(icon, color: color, size: 22),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  Expanded(child: Text('${n['title'] ?? ''}', style: AppText.bodyStrong)),
                  const SizedBox(width: 8),
                  Text(notificationTime(DateTime.tryParse('${n['created_at']}')), style: AppText.caption),
                ]),
                if (body.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(body, style: AppText.small.copyWith(fontSize: 14)),
                ],
              ]),
            ),
          ]),
        ),
      ),
    );
  }
}

const _months = ['янв', 'фев', 'мар', 'апр', 'мая', 'июн', 'июл', 'авг', 'сен', 'окт', 'ноя', 'дек'];

/// «14:05» сегодня, «вчера», иначе «3 окт». Время ташкентское (UTC+5).
String notificationTime(DateTime? t, {DateTime? now}) {
  if (t == null) return '';
  final local = t.toUtc().add(const Duration(hours: 5));
  final today = (now ?? DateTime.now()).toUtc().add(const Duration(hours: 5));
  final d0 = DateTime.utc(today.year, today.month, today.day);
  final d = DateTime.utc(local.year, local.month, local.day);
  final days = d0.difference(d).inDays;
  if (days == 0) return '${local.hour.toString().padLeft(2, '0')}:${local.minute.toString().padLeft(2, '0')}';
  if (days == 1) return 'вчера';
  return '${local.day} ${_months[local.month - 1]}';
}
