import 'dart:math';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:sm_core/sm_core.dart';

import 'waiter_logic.dart';
import 'waiter_ui.dart';

/// О8 · Зоны на смену (только старший): выбрал официанта → нажал на его
/// столы → «Сохранить на смену». Уже открытые столы не переезжают.
class ZonesScreen extends StatefulWidget {
  const ZonesScreen({super.key});

  @override
  State<ZonesScreen> createState() => _ZonesScreenState();
}

class _ZonesScreenState extends State<ZonesScreen> {
  List<WaiterInfo>? waiters;
  Object? error;

  /// Стол → официант (нет записи — «без зоны»).
  final Map<String, String> zones = {};
  String? selected; // null — «Без зоны»
  String? hall;
  bool busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final ws = context.read<WaiterState>();
    try {
      final list = await ws.waiters();
      if (!mounted) return;
      zones
        ..clear()
        ..addAll({for (final t in ws.tables) if (t.waiterId != null) t.id: t.waiterId!});
      setState(() {
        waiters = list;
        selected = list.isEmpty ? null : list.first.id;
        hall ??= ws.halls.isEmpty ? null : ws.halls.first.id;
        error = null;
      });
    } catch (e) {
      if (mounted) setState(() => error = e);
    }
  }

  Color _color(String id) {
    final i = waiters?.indexWhere((w) => w.id == id) ?? -1;
    return i < 0 ? WC.gray400 : WC.avatars[i % WC.avatars.length];
  }

  String _name(String id) => waiters?.firstWhere((w) => w.id == id, orElse: () => WaiterInfo(id, '—', 0, false)).name ?? '—';

  Future<void> _save() async {
    setState(() => busy = true);
    try {
      await context.read<WaiterState>().saveZones(zones);
      if (mounted) {
        wToast(context, tr('Зоны сохранены на сегодня', 'Zonalar bugunga saqlandi'));
        Navigator.of(context).pop();
      }
    } catch (e) {
      if (mounted) {
        setState(() => busy = false);
        wToast(context, e);
      }
    }
  }

  Future<void> _yesterday() async {
    setState(() => busy = true);
    try {
      await context.read<WaiterState>().likeYesterday();
      await _load();
      if (mounted) wToast(context, tr('Как вчера — проверьте и сохраните', 'Kechagidek — tekshirib saqlang'));
    } catch (e) {
      if (mounted) wToast(context, e);
    }
    if (mounted) setState(() => busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final ws = context.watch<WaiterState>();
    final list = waiters;
    final header = WHeader(
      title: tr('Зоны на смену', 'Smena zonalari'),
      subtitle: tr('сегодня', 'bugun'),
      leading: WRoundButton(Icons.arrow_back_rounded, onTap: () => Navigator.of(context).pop()),
      trailing: TextButton(
        onPressed: busy ? null : _yesterday,
        child: Text(tr('Как вчера', 'Kechagidek'), style: wt(13, w: w7, c: WC.red)),
      ),
    );
    if (list == null) {
      return Scaffold(
        backgroundColor: WC.bg,
        body: SafeArea(
          child: Column(children: [
            header,
            Expanded(child: Center(child: error == null ? const CircularProgressIndicator() : Text(error.toString(), style: wt(14, c: WC.gray600)))),
          ]),
        ),
      );
    }
    final tables = ws.tables.where((t) => hall == null || t.hallId == hall).toList();
    final counts = <String, int>{};
    for (final w in zones.values) {
      counts[w] = (counts[w] ?? 0) + 1;
    }
    final free = ws.tables.length - zones.length;

    return Scaffold(
      backgroundColor: WC.bg,
      body: SafeArea(
        bottom: false,
        child: Column(children: [
          header,
          Expanded(
            child: ListView(padding: const EdgeInsets.fromLTRB(16, 0, 16, 16), children: [
              Text(tr('1. Выберите официанта', '1. Ofitsiantni tanlang'), style: wt(13, w: w7, c: WC.gray600)),
              const SizedBox(height: 12),
              Wrap(spacing: 8, runSpacing: 8, children: [
                for (final w in list) _waiterChip(w.name, _color(w.id), counts[w.id] ?? 0, selected == w.id, () => setState(() => selected = w.id)),
                _waiterChip(tr('Без зоны', 'Zonasiz'), WC.gray400, free, selected == null, () => setState(() => selected = null), dash: true),
              ]),
              const SizedBox(height: 12),
              Text(tr('2. Нажмите на его столы', '2. Uning stollarini bosing'), style: wt(13, w: w7, c: WC.gray600)),
              if (ws.halls.length > 1) ...[
                const SizedBox(height: 12),
                Wrap(spacing: 6, runSpacing: 6, children: [
                  for (final h in ws.halls)
                    GestureDetector(
                      onTap: () => setState(() => hall = h.id),
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                        decoration: BoxDecoration(color: hall == h.id ? WC.red50 : WC.white, borderRadius: BorderRadius.circular(8)),
                        child: Text(h.name, style: wt(13, w: w7, c: hall == h.id ? WC.red : WC.gray600)),
                      ),
                    ),
                ]),
              ],
              const SizedBox(height: 12),
              _Scheme(
                tables: tables,
                zones: zones,
                selected: selected,
                colorOf: _color,
                onTap: (t) => setState(() {
                  if (selected == null) {
                    zones.remove(t.id);
                  } else {
                    zones[t.id] = selected!;
                  }
                }),
              ),
              const SizedBox(height: 12),
              WHint(
                selected == null
                    ? tr('Нажатием стол станет «без зоны» — его откроет любой официант', 'Bosilganda stol «zonasiz» boʻladi — uni istalgan ofitsiant ochadi')
                    : tr('Стол другого официанта нажатием станет столом: ${_name(selected!)}', 'Boshqa ofitsiant stoli bosilganda ${_name(selected!)} stoli boʻladi'),
                icon: Icons.touch_app_rounded,
                size: 12,
              ),
              const SizedBox(height: 12),
              WCard(
                padding: EdgeInsets.zero,
                radius: 14,
                child: Column(children: [
                  for (var i = 0; i < list.length; i++) ...[
                    if (i > 0) const Divider(height: 1, color: WC.gray200),
                    _summaryRow(ws, list[i]),
                  ],
                ]),
              ),
            ]),
          ),
          WBottomBar(gap: 6, children: [
            WButton(label: tr('Сохранить на смену', 'Smenaga saqlash'), icon: Icons.check_rounded, busy: busy, onTap: _save),
            Text(
              tr('Уже открытые столы не переезжают — только новые. Завтра можно «Как вчера».', 'Ochiq stollar koʻchmaydi — faqat yangilari. Ertaga «Kechagidek» mumkin.'),
              style: wt(11, c: WC.gray500),
              textAlign: TextAlign.center,
            ),
          ]),
        ]),
      ),
    );
  }

  Widget _waiterChip(String name, Color color, int n, bool on, VoidCallback onTap, {bool dash = false}) => GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.fromLTRB(5, 5, 12, 5),
          decoration: BoxDecoration(
            color: on ? WC.ink : WC.white,
            border: on ? null : Border.all(color: WC.gray200),
            borderRadius: BorderRadius.circular(20),
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Container(
              width: 26,
              height: 26,
              alignment: Alignment.center,
              decoration: BoxDecoration(color: color, shape: BoxShape.circle),
              child: Text(dash ? '—' : initial(name), style: wt(11, w: w7, c: WC.white)),
            ),
            const SizedBox(width: 6),
            Text(name.split(' ').first, style: wt(13, w: w7, c: on ? WC.white : WC.ink)),
            const SizedBox(width: 6),
            Text('$n', style: wt(12, w: w6, c: on ? WC.gray300 : WC.gray500)),
          ]),
        ),
      );

  Widget _summaryRow(WaiterState ws, WaiterInfo w) {
    final mine = ws.tables.where((t) => zones[t.id] == w.id).toList();
    final byHall = <String, List<String>>{};
    for (final t in mine) {
      byHall.putIfAbsent(ws.hallName(t.hallId), () => []).add(t.number);
    }
    final text = mine.isEmpty ? tr('без столов', 'stolsiz') : byHall.entries.map((e) => '${e.key} ${e.value.join(', ')}'.trim()).join(' · ');
    final c = _color(w.id);
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 9, 14, 9),
      child: Row(children: [
        WAvatar(w.name, color: c, size: 30, fontSize: 12),
        const SizedBox(width: 10),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(w.name, style: wt(14, w: w7)),
            Text(text, style: wt(12, c: WC.gray500), maxLines: 2, overflow: TextOverflow.ellipsis),
          ]),
        ),
        Text('${mine.length}', style: wt(15, w: w8, c: c)),
      ]),
    );
  }
}

/// Мини-схема зала: столы на сетке из панели (П9), цвет — официант.
class _Scheme extends StatelessWidget {
  const _Scheme({required this.tables, required this.zones, required this.selected, required this.colorOf, required this.onTap});

  final List<WTable> tables;
  final Map<String, String> zones;
  final String? selected;
  final Color Function(String id) colorOf;
  final ValueChanged<WTable> onTap;

  @override
  Widget build(BuildContext context) {
    if (tables.isEmpty) {
      return WCard(
        radius: 14,
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Text(tr('В этом зале нет столов', 'Bu zalda stol yoʻq'), style: wt(13, c: WC.gray500), textAlign: TextAlign.center),
        ),
      );
    }
    final minX = tables.map((t) => t.x).reduce(min), minY = tables.map((t) => t.y).reduce(min);
    final maxX = tables.map((t) => t.x + t.w).reduce(max), maxY = tables.map((t) => t.y + t.h).reduce(max);
    return LayoutBuilder(builder: (context, c) {
      const pad = 14.0, gap = 3.0;
      final cols = max(1, maxX - minX), rows = max(1, maxY - minY);
      final cell = min((c.maxWidth - pad * 2) / cols, 40.0);
      return Container(
        height: rows * cell + pad * 2,
        decoration: BoxDecoration(color: WC.white, borderRadius: BorderRadius.circular(14)),
        child: Stack(children: [
          for (final t in tables)
            Positioned(
              left: pad + (t.x - minX) * cell + gap,
              top: pad + (t.y - minY) * cell + gap,
              width: t.w * cell - gap * 2,
              height: t.h * cell - gap * 2,
              child: _cell(t),
            ),
        ]),
      );
    });
  }

  Widget _cell(WTable t) {
    final owner = zones[t.id];
    final on = owner != null && owner == selected;
    final color = owner == null ? WC.gray300 : colorOf(owner);
    return GestureDetector(
      onTap: () => onTap(t),
      child: Container(
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: owner == null ? WC.gray50 : color.withValues(alpha: 0.08),
          border: Border.all(color: color, width: on ? 2 : 1.5),
          borderRadius: BorderRadius.circular(t.shape == 'round' ? 100 : 8),
        ),
        child: FittedBox(
          child: Padding(
            padding: const EdgeInsets.all(2),
            child: Text(t.number, style: wt(14, w: w8, c: owner == null ? WC.gray500 : color)),
          ),
        ),
      ),
    );
  }
}
