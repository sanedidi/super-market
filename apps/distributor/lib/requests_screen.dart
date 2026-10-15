import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:sm_core/sm_core.dart';
import 'package:sm_store/main.dart' show showMessage;
import 'package:sm_store/ui/theme.dart';
import 'package:sm_store/ui/widgets.dart';

import 'store_screen.dart';
import 'ui.dart';

/// Д14 · Запросы от магазинов — принять или отклонить; отправленные вами.
class RequestsScreen extends StatefulWidget {
  const RequestsScreen({super.key});

  @override
  State<RequestsScreen> createState() => _RequestsScreenState();
}

class _RequestsScreenState extends State<RequestsScreen> {
  List<Map<String, dynamic>>? _items;
  Object? _error;
  final Set<String> _busy = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final items = await context.read<Api>().list('/store/supply/links', {'status': 'requested', 'limit': 100});
      if (mounted) {
        setState(() {
          _items = items;
          _error = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  Future<void> _answer(Map<String, dynamic> l, bool accept) async {
    setState(() => _busy.add('${l['id']}'));
    try {
      await context.read<Api>().post('/store/supply/links/${l['id']}/${accept ? 'accept' : 'reject'}');
      if (!mounted) return;
      showMessage(context, accept ? tr('${l['store_name']} подключён', '${l['store_name']} ulandi') : tr('Запрос отклонён', 'Soʻrov rad etildi'));
      await _load();
    } catch (e) {
      if (mounted) showMessage(context, e);
    } finally {
      if (mounted) setState(() => _busy.remove('${l['id']}'));
    }
  }

  @override
  Widget build(BuildContext context) {
    final items = _items;
    final incoming = items?.where((l) => l['waits_for_me'] == true).toList() ?? const [];
    final mine = items?.where((l) => l['waits_for_me'] != true).toList() ?? const [];
    return Scaffold(
      appBar: AppBar(
        title: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(tr('Запросы', 'Soʻrovlar'), style: AppText.title),
          Text(tr('Магазины хотят заказывать у вас', 'Doʻkonlar sizdan buyurtma bermoqchi'), style: AppText.small),
        ]),
      ),
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 24), children: [
          if (_error != null && items == null)
            LoadError(_error!, onRetry: _load)
          else if (items == null)
            const Padding(padding: EdgeInsets.only(top: 40), child: Center(child: CircularProgressIndicator()))
          else if (items.isEmpty)
            EmptyState(
              icon: Icons.person_add_alt_rounded,
              title: tr('Запросов нет', 'Soʻrovlar yoʻq'),
              text: tr('Когда магазин попросит подключить вас как поставщика, запрос появится здесь.', 'Doʻkon sizni yetkazib beruvchi sifatida ulashni soʻraganda, soʻrov shu yerda paydo boʻladi.'),
            )
          else ...[
            for (final l in incoming) ...[_card(l, true), const SizedBox(height: 10)],
            if (mine.isNotEmpty) ...[
              const SizedBox(height: 6),
              Text(tr('Отправленные вами', 'Siz yuborganlar'), style: AppText.bodyStrong.copyWith(color: AppColors.text2)),
              const SizedBox(height: 8),
              for (final l in mine) ...[_card(l, false), const SizedBox(height: 10)],
            ],
          ],
        ]),
      ),
    );
  }

  Widget _card(Map<String, dynamic> l, bool incoming) {
    final busy = _busy.contains('${l['id']}');
    return AppCard(
      padding: const EdgeInsets.all(14),
      onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => StoreScreen(storeId: '${l['store_id']}'))).then((_) => _load()),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          IconBox(Icons.storefront_rounded, bg: incoming ? AppColors.blueSoft : AppColors.soft, fg: incoming ? AppColors.blue : AppColors.text2, size: 40, iconSize: 20, radius: 12),
          const SizedBox(width: 10),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('${l['store_name']}', style: AppText.bodyStrong),
              Text(dateTime(l['created_at']), style: AppText.small),
            ]),
          ),
          StatusChip(incoming ? tr('Новый', 'Yangi') : tr('Ждём магазин', 'Doʻkonni kutyapmiz'), tone: incoming ? ChipTone.blue : ChipTone.gray),
        ]),
        if ('${l['message'] ?? ''}'.isNotEmpty) ...[
          const SizedBox(height: 10),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(color: AppColors.bg, borderRadius: BorderRadius.circular(12)),
            child: Text('${l['message']}', style: AppText.small.copyWith(color: AppColors.ink)),
          ),
        ],
        if (incoming) ...[
          const SizedBox(height: 10),
          Row(children: [
            Expanded(child: BigButton(label: tr('Отклонить', 'Rad etish'), height: 44, color: AppColors.soft, foreground: AppColors.ink, onPressed: busy ? null : () => _answer(l, false))),
            const SizedBox(width: 10),
            Expanded(flex: 2, child: BigButton(label: tr('Принять', 'Qabul qilish'), icon: Icons.check_rounded, height: 44, busy: busy, onPressed: () => _answer(l, true))),
          ]),
        ],
      ]),
    );
  }
}
