import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:sm_core/sm_core.dart';

import '../control/cashiers_screen.dart' show initials, plural;
import '../state.dart';
import '../ui/theme.dart';
import '../ui/widgets.dart';
import 'debt_settings_screen.dart';
import 'debtor_screen.dart';

// Долги покупателей (Figma С1): кто должен магазину, просрочка, споры.

const _months = ['янв', 'фев', 'мар', 'апр', 'мая', 'июн', 'июл', 'авг', 'сен', 'окт', 'ноя', 'дек'];
const _monthsUz = ['yan', 'fev', 'mar', 'apr', 'may', 'iyn', 'iyl', 'avg', 'sen', 'okt', 'noy', 'dek'];

/// «2026-11-05» или ISO-время → «5 ноя» / «5-noy».
String shortDate(Object? v) {
  final d = DateTime.tryParse('${v ?? ''}');
  if (d == null) return '';
  final l = d.toLocal();
  return tr('${l.day} ${_months[l.month - 1]}', '${l.day}-${_monthsUz[l.month - 1]}');
}

List<(String, String)> get _filters => [
      ('all', tr('Все', 'Hammasi')),
      ('overdue', tr('Просрочка', 'Muddati oʻtgan')),
      ('unverified', tr('Не подтв.', 'Tasdiqlanmagan')),
      ('disputes', tr('Споры', 'Nizolar')),
      ('blocked', tr('Стоп-лист', 'Stop-list')),
    ];

const _tones = [
  (AppColors.primarySoft, AppColors.primary),
  (AppColors.blueSoft, AppColors.blue),
  (AppColors.warningSoft, AppColors.warningInk),
  (AppColors.successSoft, AppColors.successInk),
  (AppColors.soft, AppColors.ink),
];

class CustomerDebtsScreen extends StatefulWidget {
  const CustomerDebtsScreen({super.key, this.status = 'all'});

  /// Фильтр при открытии: из push «Покупатель оспаривает долг» — disputes.
  final String status;

  @override
  State<CustomerDebtsScreen> createState() => _CustomerDebtsScreenState();
}

class _CustomerDebtsScreenState extends State<CustomerDebtsScreen> {
  late String _status = widget.status;
  Map<String, dynamic>? _sum;
  List<Map<String, dynamic>>? _items;
  Object? _error;
  bool _search = false;
  final _q = TextEditingController();
  Timer? _debounce;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _q.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final api = context.read<Api>();
    final store = context.read<StoreState>().storeId;
    try {
      final res = await Future.wait([
        api.get('/store/debtors/summary', {'store_id': store}),
        api.list('/store/debtors', {'store_id': store, 'status': _status, 'q': _q.text.trim(), 'limit': '200'}),
      ]);
      if (!mounted) return;
      setState(() {
        _sum = res[0] as Map<String, dynamic>;
        _items = res[1] as List<Map<String, dynamic>>;
        _error = null;
      });
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  Future<void> _open(Map<String, dynamic> b) async {
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => DebtorScreen(id: b['debtor_id'] as String)));
    if (mounted) _load();
  }

  int _count(String f) {
    final s = _sum;
    if (s == null) return 0;
    return switch (f) {
      'all' => (s['count'] as num?)?.toInt() ?? 0,
      'overdue' => (s['overdue_count'] as num?)?.toInt() ?? 0,
      'unverified' => (s['unverified'] as num?)?.toInt() ?? 0,
      'disputes' => (s['open_disputes'] as num?)?.toInt() ?? 0,
      _ => 0,
    };
  }

  @override
  Widget build(BuildContext context) {
    final st = context.watch<StoreState>();
    final s = _sum;
    final items = _items;
    final count = (s?['count'] as num?)?.toInt() ?? 0;
    final overdueCount = (s?['overdue_count'] as num?)?.toInt() ?? 0;
    return Scaffold(
      appBar: AppBar(
        title: _search
            ? TextField(
                controller: _q,
                autofocus: true,
                decoration: InputDecoration(hintText: tr('Имя или телефон', 'Ism yoki telefon'), border: InputBorder.none, filled: false),
                onChanged: (_) {
                  _debounce?.cancel();
                  _debounce = Timer(const Duration(milliseconds: 300), _load);
                },
              )
            : Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(tr('Долги покупателей', 'Xaridorlar qarzlari')),
                Text('${st.networkName} · ${st.store?['name'] ?? ''}', style: AppText.small),
              ]),
        actions: [
          IconButton(
            icon: Icon(_search ? Icons.close_rounded : Icons.search_rounded),
            onPressed: () {
              setState(() => _search = !_search);
              if (!_search && _q.text.isNotEmpty) {
                _q.clear();
                _load();
              }
            },
          ),
          IconButton(
            icon: const Icon(Icons.tune_rounded),
            tooltip: tr('Настройки долгов', 'Qarz sozlamalari'),
            onPressed: () async {
              await Navigator.of(context).push(MaterialPageRoute(builder: (_) => const DebtSettingsScreen()));
              if (mounted) _load();
            },
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 24), children: [
          if (s != null)
            Container(
              padding: const EdgeInsets.all(18),
              decoration: BoxDecoration(color: AppColors.ink, borderRadius: BorderRadius.circular(20)),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(tr('Нам должны покупатели', 'Xaridorlarning bizga qarzi'), style: AppText.small.copyWith(color: AppColors.muted)),
                Row(crossAxisAlignment: CrossAxisAlignment.baseline, textBaseline: TextBaseline.alphabetic, children: [
                  Text(money(s['total'], suffix: false), style: AppText.h1.copyWith(color: AppColors.white, fontSize: 30)),
                  const SizedBox(width: 6),
                  Text(tr('сум', 'soʻm'), style: AppText.bodyStrong.copyWith(color: AppColors.muted)),
                ]),
                Text(
                  tr(
                      '$count ${plural(count, 'покупатель', 'покупателя', 'покупателей')}'
                          '${overdueCount > 0 ? ' · просрочено ${money(s['overdue'], suffix: false)} у $overdueCount' : ''}',
                      '$count ta xaridor'
                          '${overdueCount > 0 ? ' · $overdueCount ta xaridorda ${money(s['overdue'], suffix: false)} muddati oʻtgan' : ''}'),
                  style: AppText.small.copyWith(color: AppColors.muted),
                ),
              ]),
            ),
          const SizedBox(height: 14),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(children: [
              for (final (v, t) in _filters) ...[
                ChoiceChip(
                  label: Text(_count(v) > 0 ? '$t ${_count(v)}' : t),
                  selected: _status == v,
                  showCheckmark: false,
                  onSelected: (_) {
                    setState(() {
                      _status = v;
                      _items = null;
                    });
                    _load();
                  },
                ),
                const SizedBox(width: 8),
              ],
            ]),
          ),
          const SizedBox(height: 14),
          if (items == null)
            _error == null
                ? const Padding(padding: EdgeInsets.only(top: 40), child: Center(child: CircularProgressIndicator()))
                : EmptyState(icon: Icons.wifi_off_rounded, title: tr('Не удалось загрузить', 'Yuklab boʻlmadi'), text: '$_error', action: tr('Повторить', 'Qayta urinish'), onAction: _load)
          else if (items.isEmpty)
            EmptyState(
              icon: Icons.handshake_outlined,
              title: _status == 'all' ? tr('Покупатели ничего не должны', 'Xaridorlarning qarzi yoʻq') : tr('Никого нет', 'Hech kim yoʻq'),
              text: _status == 'all'
                  ? tr('Продажа в долг — на кассе, кнопка «В долг». Включается в настройках.', 'Qarzga sotish — kassada, «Qarzga» tugmasi. Sozlamalarda yoqiladi.')
                  : null,
            )
          else
            AppCard(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
              child: Column(children: [
                for (var i = 0; i < items.length; i++) ...[
                  if (i > 0) const Divider(height: 1, indent: 12, endIndent: 12),
                  _Row(b: items[i], tone: _tones[i % _tones.length], onTap: () => _open(items[i])),
                ],
              ]),
            ),
        ]),
      ),
    );
  }
}

class _Row extends StatelessWidget {
  const _Row({required this.b, required this.tone, required this.onTap});

  final Map<String, dynamic> b;
  final (Color, Color) tone;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final name = '${b['full_name'] ?? ''}'.trim();
    final overdue = (b['overdue_days'] as num?)?.toInt() ?? 0;
    final disputes = (b['open_disputes'] as num?)?.toInt() ?? 0;
    final sub = b['blocked'] == true
        ? tr('стоп-лист', 'stop-list')
        : b['verified'] != true
            ? '${tr('не подтверждён', 'tasdiqlanmagan')} · ${shortDate(b['since'])}'
            : tr('с ${shortDate(b['since'])}${b['due_date'] != null ? ' · вернуть до ${shortDate(b['due_date'])}' : ''}',
                '${shortDate(b['since'])} dan${b['due_date'] != null ? ' · ${shortDate(b['due_date'])} gacha qaytarish' : ''}');
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(children: [
          Container(
            width: 44,
            height: 44,
            alignment: Alignment.center,
            decoration: BoxDecoration(color: tone.$1, borderRadius: BorderRadius.circular(12)),
            child: Text(initials(name.isEmpty ? '?' : name), style: AppText.bodyStrong.copyWith(color: tone.$2, fontSize: 14)),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(name.isEmpty ? formatPhone(b['phone']) : name,
                  style: AppText.bodyStrong.copyWith(fontWeight: FontWeight.w500), maxLines: 1, overflow: TextOverflow.ellipsis),
              Text(sub, style: AppText.small),
              if (overdue > 0)
                Row(children: [
                  const Icon(Icons.schedule_rounded, size: 14, color: AppColors.primary),
                  const SizedBox(width: 4),
                  Text(tr('просрочено $overdue ${plural(overdue, 'день', 'дня', 'дней')}', 'muddati $overdue kun oʻtgan'), style: AppText.caption.copyWith(color: AppColors.primary)),
                ]),
              if (disputes > 0)
                Row(children: [
                  const Icon(Icons.report_outlined, size: 14, color: AppColors.warningInk),
                  const SizedBox(width: 4),
                  Text(tr('оспаривает запись', 'yozuvga eʼtiroz bildirgan'), style: AppText.caption.copyWith(color: AppColors.warningInk)),
                ]),
            ]),
          ),
          const SizedBox(width: 8),
          Text(money(b['amount'], suffix: false), style: AppText.bodyStrong),
        ]),
      ),
    );
  }
}
