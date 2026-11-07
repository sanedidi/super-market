import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:sm_core/sm_core.dart';

import 'logic.dart';
import 'ui.dart';

/// Карточка отмеченного магазина: фото витрины, последний результат и
/// история визитов (кто, когда, с каким результатом).
Future<void> showPlaceSheet(BuildContext context, String id) {
  final api = context.read<Api>();
  return showSheet<void>(context, (ctx) => _PlaceCard(api: api, id: id));
}

class _PlaceCard extends StatefulWidget {
  const _PlaceCard({required this.api, required this.id});

  final Api api;
  final String id;

  @override
  State<_PlaceCard> createState() => _PlaceCardState();
}

class _PlaceCardState extends State<_PlaceCard> {
  Map<String, dynamic>? _p;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final p = await widget.api.get('/field/places/${widget.id}') as Map<String, dynamic>;
      if (mounted) setState(() => _p = p);
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = _p;
    if (p == null) {
      return SizedBox(
        height: 200,
        child: Center(child: _error == null ? const CircularProgressIndicator() : Text('$_error', style: AppText.small)),
      );
    }
    final result = '${p['result']}';
    final style = ResultStyle.of(result);
    final name = '${p['name'] ?? ''}'.trim();
    final photo = '${p['photo_url'] ?? ''}';
    final history = ((p['history'] as List?) ?? const []).cast<Map<String, dynamic>>();
    final lead = leadStatusLabel('${p['lead_status'] ?? ''}');
    return Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
      Row(children: [
        IconBox(icon: style.icon, color: style.color, bg: style.bg, size: 44),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(name.isEmpty ? tr('Магазин без названия', 'Nomsiz doʻkon') : name, style: AppText.h2.copyWith(fontSize: 20)),
            const SizedBox(height: 2),
            Text(
              [resultLabel(result), if (lead.isNotEmpty) lead, if (p['remind_on'] != null) remindLabel('${p['remind_on']}')].join(' · '),
              style: AppText.small.copyWith(color: style.color, fontWeight: FontWeight.w600),
            ),
          ]),
        ),
      ]),
      if (photo.isNotEmpty) ...[
        const SizedBox(height: 14),
        ClipRRect(
          borderRadius: BorderRadius.circular(14),
          child: AspectRatio(
            aspectRatio: 4 / 3,
            child: Image.network(photo, fit: BoxFit.cover, errorBuilder: (_, __, ___) => Container(color: AppColors.soft)),
          ),
        ),
      ],
      const SizedBox(height: 16),
      Text(tr('История визитов', 'Tashriflar tarixi'), style: AppText.bodyStrong),
      const SizedBox(height: 8),
      for (final v in history) _VisitRow(v: v),
    ]);
  }
}

class _VisitRow extends StatelessWidget {
  const _VisitRow({required this.v});

  final Map<String, dynamic> v;

  @override
  Widget build(BuildContext context) {
    final result = '${v['result']}';
    final s = ResultStyle.of(result);
    final details = <String>[
      if ('${v['reason'] ?? ''}'.isNotEmpty) reasonLabel('${v['reason']}'),
      if ('${v['program'] ?? ''}'.isNotEmpty) programLabel('${v['program']}'),
      if (v['remind_on'] != null) tr('прийти ${remindLabel('${v['remind_on']}')}', 'kelish: ${remindLabel('${v['remind_on']}')}'),
      if ('${v['comment'] ?? ''}'.isNotEmpty) '«${v['comment']}»',
    ];
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Padding(padding: const EdgeInsets.only(top: 2), child: PlaceDot(result: result, size: 18)),
        const SizedBox(width: 10),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('${resultLabel(result)} · ${v['mine'] == true ? tr('вы', 'siz') : v['rep_name']}', style: AppText.bodyStrong.copyWith(color: s.color == AppColors.muted ? AppColors.ink : s.color)),
            Text(dateTime(v['created_at']), style: AppText.small),
            if (details.isNotEmpty) Text(details.join(' · '), style: AppText.small.copyWith(color: AppColors.ink)),
          ]),
        ),
      ]),
    );
  }
}

/// «Мои магазины»: где продажник был, с фильтром по результату.
class PlacesTab extends StatefulWidget {
  const PlacesTab({super.key});

  @override
  State<PlacesTab> createState() => _PlacesTabState();
}

class _PlacesTabState extends State<PlacesTab> {
  String _filter = '';
  List<Map<String, dynamic>>? _items;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final items = await context.read<Api>().list('/field/places', {'result': _filter, 'limit': 200});
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

  @override
  Widget build(BuildContext context) {
    final filters = [
      ('', tr('Все', 'Hammasi')),
      ('lead', resultLabel('lead')),
      ('refused', resultLabel('refused')),
      ('later', resultLabel('later')),
      ('closed', resultLabel('closed')),
      ('ours', tr('Уже с нами', 'Biz bilan')),
    ];
    final items = _items;
    return Scaffold(
      appBar: AppBar(title: Text(tr('Мои магазины', 'Mening doʻkonlarim'))),
      body: Column(children: [
        SizedBox(
          height: 48,
          child: ListView(scrollDirection: Axis.horizontal, padding: const EdgeInsets.symmetric(horizontal: 16), children: [
            for (final (code, label) in filters)
              Padding(
                padding: const EdgeInsets.only(right: 8, top: 6, bottom: 6),
                child: ChoiceChip(
                  label: Text(label),
                  selected: _filter == code,
                  showCheckmark: false,
                  selectedColor: AppColors.ink,
                  labelStyle: AppText.caption.copyWith(color: _filter == code ? AppColors.white : AppColors.ink, fontSize: 13),
                  backgroundColor: AppColors.soft,
                  side: BorderSide.none,
                  onSelected: (_) {
                    setState(() {
                      _filter = code;
                      _items = null;
                    });
                    _load();
                  },
                ),
              ),
          ]),
        ),
        Expanded(
          child: RefreshIndicator(
            onRefresh: _load,
            child: items == null
                ? ListView(children: [
                    const SizedBox(height: 120),
                    Center(child: _error == null ? const CircularProgressIndicator() : Text('$_error', style: AppText.small)),
                  ])
                : items.isEmpty
                    ? ListView(children: [
                        EmptyState(
                          icon: Icons.storefront_rounded,
                          title: tr('Пока пусто', 'Hozircha boʻsh'),
                          text: tr('Отмечайте магазины во время обхода — они появятся здесь.', 'Aylanish vaqtida doʻkonlarni belgilang — ular shu yerda chiqadi.'),
                        ),
                      ])
                    : ListView.separated(
                        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                        itemCount: items.length,
                        separatorBuilder: (_, __) => const SizedBox(height: 8),
                        itemBuilder: (context, i) => PlaceTile(place: items[i]),
                      ),
          ),
        ),
      ]),
    );
  }
}

/// Строка магазина в списках.
class PlaceTile extends StatelessWidget {
  const PlaceTile({super.key, required this.place});

  final Map<String, dynamic> place;

  @override
  Widget build(BuildContext context) {
    final p = place;
    final result = '${p['result']}';
    final s = ResultStyle.of(result);
    final name = '${p['name'] ?? ''}'.trim();
    final lead = leadStatusLabel('${p['lead_status'] ?? ''}');
    final sub = [
      resultLabel(result),
      if (lead.isNotEmpty) lead,
      if (p['remind_on'] != null) remindLabel('${p['remind_on']}'),
      shortDate(p['last_visit_at']),
    ].join(' · ');
    return AppCard(
      onTap: () => showPlaceSheet(context, '${p['id']}'),
      padding: const EdgeInsets.all(12),
      child: Row(children: [
        IconBox(icon: s.icon, color: s.color, bg: s.bg),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(name.isEmpty ? tr('Без названия', 'Nomsiz') : name, style: AppText.bodyStrong, maxLines: 1, overflow: TextOverflow.ellipsis),
            Text(sub, style: AppText.small, maxLines: 2, overflow: TextOverflow.ellipsis),
          ]),
        ),
        const Icon(Icons.chevron_right_rounded, color: AppColors.muted),
      ]),
    );
  }
}
