import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:sm_core/sm_core.dart';

import '../lock/pin_screens.dart';
import '../push.dart';
import '../screens/store_picker.dart';
import '../state.dart';
import 'bill_screen.dart';
import 'table_sheets.dart';
import 'waiter_logic.dart';
import 'waiter_ui.dart';
import 'zones_screen.dart';

/// Режим «Официант» в SM Магазин (Figma «Кафе» → «Официант · телефон», О1):
/// Столы · Готово · Брони · Ещё.
class WaiterShell extends StatefulWidget {
  const WaiterShell({super.key});

  @override
  State<WaiterShell> createState() => _WaiterShellState();
}

class _WaiterShellState extends State<WaiterShell> {
  late final WaiterState ws;
  late final AppLifecycleListener _life;
  int _tab = 0;
  final Set<String> _shownTransfers = {};
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    final st = context.read<StoreState>();
    ws = WaiterState(context.read<Api>(), st.storeId!);
    ws.load().then((_) => ws.startPolling());
    ws.addListener(_onChange);
    _life = AppLifecycleListener(
      onResume: () {
        ws.refreshHall().catchError((_) {});
        ws.startPolling();
      },
      onPause: ws.stopPolling,
    );
    // Время у столов («22 мин») — раз в минуту.
    _tick = Timer.periodic(const Duration(minutes: 1), (_) {
      if (mounted) setState(() {});
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => Push.register(context.read<Api>()));
  }

  /// Мне передают стол (О7) — окно «Принять / Отказаться», один раз на передачу.
  void _onChange() {
    for (final b in ws.incoming) {
      final key = '${b.id}@${b.transferAt?.toIso8601String()}';
      if (_shownTransfers.add(key)) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) showIncomingTransfer(context, ws, b);
        });
      }
    }
  }

  @override
  void dispose() {
    _tick?.cancel();
    _life.dispose();
    ws.removeListener(_onChange);
    ws.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider.value(
      value: ws,
      child: Scaffold(
        backgroundColor: WC.bg,
        body: SafeArea(
          bottom: false,
          child: IndexedStack(index: _tab, children: [
            TablesTab(onReady: () => setState(() => _tab = 1)),
            const ReadyTab(),
            const _BookingsTab(),
            const _MoreTab(),
          ]),
        ),
        bottomNavigationBar: _NavBar(tab: _tab, onTab: (i) => setState(() => _tab = i)),
      ),
    );
  }
}

class _NavBar extends StatelessWidget {
  const _NavBar({required this.tab, required this.onTab});

  final int tab;
  final ValueChanged<int> onTab;

  @override
  Widget build(BuildContext context) {
    final ready = context.watch<WaiterState>().readyForMe.length;
    Widget item(int i, IconData icon, String label, {int badge = 0}) {
      final on = tab == i;
      final c = on ? WC.red : WC.gray500;
      return Expanded(
        child: InkWell(
          onTap: () => onTab(i),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Row(mainAxisSize: MainAxisSize.min, children: [
                Icon(icon, size: 24, color: c),
                if (badge > 0)
                  Container(
                    margin: const EdgeInsets.only(left: 2),
                    padding: const EdgeInsets.symmetric(horizontal: 5),
                    decoration: BoxDecoration(color: WC.green, borderRadius: BorderRadius.circular(8)),
                    child: Text('$badge', style: wt(10, w: w7, c: WC.white)),
                  ),
              ]),
              const SizedBox(height: 2),
              Text(label, style: wt(11, w: on ? w7 : w5, c: c)),
            ]),
          ),
        ),
      );
    }

    return Container(
      decoration: const BoxDecoration(color: WC.white, border: Border(top: BorderSide(color: WC.gray200))),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(8, 6, 8, 2),
          child: Row(children: [
            item(0, Icons.table_restaurant_rounded, tr('Столы', 'Stollar')),
            item(1, Icons.room_service_rounded, tr('Готово', 'Tayyor'), badge: ready),
            item(2, Icons.event_rounded, tr('Брони', 'Bronlar')),
            item(3, Icons.more_horiz_rounded, tr('Ещё', 'Yana')),
          ]),
        ),
      ),
    );
  }
}

// ------------------------------------------------------------------ О1 · Столы

enum _Filter { mine, all, free }

class TablesTab extends StatefulWidget {
  const TablesTab({super.key, required this.onReady});

  final VoidCallback onReady;

  @override
  State<TablesTab> createState() => _TablesTabState();
}

class _TablesTabState extends State<TablesTab> {
  _Filter _filter = _Filter.mine;
  bool _serving = false;

  @override
  Widget build(BuildContext context) {
    final ws = context.watch<WaiterState>();
    final st = context.watch<StoreState>();
    final name = '${st.me?['full_name'] ?? ''}';
    final header = Padding(
      padding: const EdgeInsets.fromLTRB(16, 6, 16, 10),
      child: Row(children: [
        WAvatar(name),
        const SizedBox(width: 10),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(tr('$name · официант', '$name · ofitsiant'), style: wt(18, w: w7), maxLines: 1, overflow: TextOverflow.ellipsis),
            const SizedBox(height: 1),
            Text('${st.store?['name'] ?? ''}', style: wt(12, c: WC.gray500), maxLines: 1, overflow: TextOverflow.ellipsis),
          ]),
        ),
        WRoundButton(Icons.notifications_rounded, onTap: widget.onReady, tooltip: tr('Готово на кухне', 'Oshxonada tayyor')),
      ]),
    );
    if (!ws.loaded) {
      return Column(children: [
        header,
        Expanded(
          child: Center(
            child: ws.error == null
                ? const CircularProgressIndicator()
                : Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(mainAxisSize: MainAxisSize.min, children: [
                      const Icon(Icons.wifi_off_rounded, size: 40, color: WC.gray400),
                      const SizedBox(height: 12),
                      Text(ws.error.toString(), style: wt(14, c: WC.gray600), textAlign: TextAlign.center),
                      const SizedBox(height: 16),
                      WButton(label: tr('Повторить', 'Qayta urinish'), onTap: ws.load),
                    ]),
                  ),
          ),
        ),
      ]);
    }

    final busy = {for (final b in ws.bills) if (b.open && b.tableId != null) b.tableId!: b};
    final mine = ws.tables.where((t) => busy[t.id]?.mine == true).toList();
    final occupied = ws.tables.where((t) => busy.containsKey(t.id)).toList();
    final free = ws.tables.where((t) => !busy.containsKey(t.id)).toList();
    final list = switch (_filter) { _Filter.mine => mine, _Filter.all => occupied, _Filter.free => free };
    final ready = ws.readyForMe;

    return RefreshIndicator(
      onRefresh: () async {
        await ws.refreshHall();
        await ws.refreshMenu(force: true);
      },
      child: ListView(padding: const EdgeInsets.only(bottom: 24), children: [
        header,
        if (ready.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: WCard(
              color: WC.green50,
              border: WC.green,
              onTap: widget.onReady,
              child: Row(children: [
                const Icon(Icons.room_service_rounded, size: 26, color: WC.green),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(tr('Готово · заберите на кухне', 'Tayyor · oshxonadan oling'), style: wt(14, w: w7, c: WC.green700)),
                    const SizedBox(height: 1),
                    Text(
                      ready.map((r) => tr('Стол ${r.$1.tableNumber}: ${r.$2.name} × ${qtyText(r.$2.left)}', '${r.$1.tableNumber}-stol: ${r.$2.name} × ${qtyText(r.$2.left)}')).join('  ·  '),
                      style: wt(12, c: WC.gray700),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ]),
                ),
                const SizedBox(width: 10),
                SizedBox(
                  height: 34,
                  child: FilledButton(
                    style: FilledButton.styleFrom(
                      backgroundColor: WC.green,
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                    ),
                    onPressed: _serving
                        ? null
                        : () async {
                            setState(() => _serving = true);
                            try {
                              await ws.serveAll(ready);
                            } catch (e) {
                              if (context.mounted) wToast(context, e);
                            }
                            if (mounted) setState(() => _serving = false);
                          },
                    child: Text(tr('Несу', 'Olib boryapman'), style: wt(13, w: w7, c: WC.white)),
                  ),
                ),
              ]),
            ),
          ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Container(
            padding: const EdgeInsets.all(4),
            decoration: BoxDecoration(color: WC.white, borderRadius: BorderRadius.circular(12)),
            child: Row(children: [
              _seg(tr('Мои столы', 'Mening stollarim'), mine.length, _Filter.mine),
              const SizedBox(width: 4),
              _seg(tr('Все', 'Hammasi'), occupied.length, _Filter.all),
              const SizedBox(width: 4),
              _seg(tr('Свободные', 'Boʻsh'), free.length, _Filter.free),
            ]),
          ),
        ),
        const SizedBox(height: 12),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: LayoutBuilder(builder: (context, c) {
            final w = (c.maxWidth - 10) / 2;
            return Wrap(spacing: 10, runSpacing: 10, children: [
              for (final t in list) SizedBox(width: w, child: _TableCard(table: t, bill: busy[t.id], ws: ws)),
              if (_filter == _Filter.mine)
                SizedBox(
                  width: w,
                  height: 118,
                  child: _DashedCard(
                    onTap: () => setState(() => _filter = _Filter.free),
                    child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                      const Icon(Icons.add_circle_outline_rounded, size: 28, color: WC.gray500),
                      const SizedBox(height: 4),
                      Text(tr('Открыть стол', 'Stol ochish'), style: wt(13, w: w7, c: WC.gray600)),
                    ]),
                  ),
                ),
            ]);
          }),
        ),
        if (list.isEmpty && _filter != _Filter.mine)
          Padding(
            padding: const EdgeInsets.all(32),
            child: Text(
              _filter == _Filter.free ? tr('Свободных столов нет', 'Boʻsh stol yoʻq') : tr('Открытых столов нет', 'Ochiq stol yoʻq'),
              style: wt(14, c: WC.gray500),
              textAlign: TextAlign.center,
            ),
          ),
        if (ws.tables.isEmpty)
          Padding(
            padding: const EdgeInsets.all(32),
            child: Text(
              tr('Столов пока нет — их добавляют в панели: «Касса → Залы и столы».', 'Hozircha stollar yoʻq — ular panelda qoʻshiladi: «Kassa → Zallar va stollar».'),
              style: wt(14, c: WC.gray500),
              textAlign: TextAlign.center,
            ),
          ),
      ]),
    );
  }

  Widget _seg(String label, int n, _Filter f) {
    final on = _filter == f;
    return Expanded(
      child: GestureDetector(
        onTap: () => setState(() => _filter = f),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          padding: const EdgeInsets.symmetric(vertical: 9),
          decoration: BoxDecoration(color: on ? WC.ink : Colors.transparent, borderRadius: BorderRadius.circular(9)),
          child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            Flexible(child: Text(label, style: wt(13, w: w7, c: on ? WC.white : WC.gray600), maxLines: 1, overflow: TextOverflow.ellipsis)),
            const SizedBox(width: 6),
            Text('$n', style: wt(12, w: w6, c: on ? WC.gray300 : WC.gray400)),
          ]),
        ),
      ),
    );
  }
}

/// Карточка стола 174×118: номер, зал, статус, сумма, время.
class _TableCard extends StatelessWidget {
  const _TableCard({required this.table, required this.bill, required this.ws});

  final WTable table;
  final WBill? bill;
  final WaiterState ws;

  @override
  Widget build(BuildContext context) {
    final b = bill;
    final hall = ws.hallName(table.hallId);
    var foreign = false;
    Color bg = WC.white, border = WC.gray200;
    double bw = 1;
    Widget? badge;
    if (b != null) {
      // Чужой стол при «только свои» — серый (сервер не отдал суммы).
      foreign = !b.mine && b.waiterId != null && !ws.senior && b.hidden;
      final ready = b.mine && b.readyItems.isNotEmpty;
      final pre = b.precheckAt != null;
      if (ready) {
        border = WC.green;
        bw = 2.5;
      } else if (pre && b.mine) {
        bg = WC.orange50;
        border = WC.orange;
        bw = 2.5;
      }
      if (b.transferAt != null) {
        badge = WPill(b.transferTo == ws.me ? tr('вам', 'sizga') : tr('передаётся', 'berilmoqda'), icon: Icons.swap_horiz_rounded, fg: WC.blue, bg: WC.blue50);
      } else if (ready) {
        badge = WPill.ready(tr('готово', 'tayyor'));
      } else if (pre) {
        badge = WPill(tr('пречек', 'oldindan chek'), icon: Icons.receipt_long_rounded, fg: WC.orange, bg: WC.white);
      }
    }
    final String bottom;
    if (b == null) {
      bottom = tr('${table.seats} мест · свободен', '${table.seats} oʻrin · boʻsh');
    } else if (foreign) {
      bottom = b.waiterName;
    } else if (b.waiterId == null) {
      bottom = tr('без официанта', 'ofitsiantsiz');
    } else if (!b.mine) {
      bottom = b.waiterName;
    } else {
      bottom = elapsed(b.openedAt);
    }
    return Opacity(
      opacity: foreign ? 0.55 : 1,
      child: SizedBox(
        height: 118,
        child: WCard(
          color: foreign ? WC.gray50 : bg,
          border: border,
          borderWidth: bw,
          radius: 14,
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
          onTap: () => _open(context),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
              Flexible(child: Text(table.number, style: wt(24, w: w8), maxLines: 1, overflow: TextOverflow.ellipsis)),
              if (hall.isNotEmpty && table.number.length <= 3) ...[
                const SizedBox(width: 6),
                Flexible(child: Text(hall, style: wt(11, w: w6, c: WC.gray400), maxLines: 1, overflow: TextOverflow.ellipsis)),
              ],
              const Spacer(),
              if (badge != null) badge,
            ]),
            const Spacer(),
            if (b != null && !b.hidden) Text(sum(b.total), style: wt(16, w: w7)),
            if (b == null) Text(tr('Открыть', 'Ochish'), style: wt(16, w: w7, c: WC.red)),
            const SizedBox(height: 2),
            Row(children: [
              Icon(b == null ? Icons.event_seat_rounded : (b.mine ? Icons.schedule_rounded : Icons.person_rounded), size: 13, color: WC.gray400),
              const SizedBox(width: 3),
              Flexible(child: Text(bottom, style: wt(11, c: WC.gray500), maxLines: 1, overflow: TextOverflow.ellipsis)),
            ]),
          ]),
        ),
      ),
    );
  }

  Future<void> _open(BuildContext context) async {
    final b = bill;
    if (b == null) {
      final opened = await showOpenTable(context, ws, table);
      if (opened != null && context.mounted) {
        await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => ChangeNotifierProvider.value(value: ws, child: BillScreen(billId: opened.id, openMenu: true))));
      }
      return;
    }
    if (b.transferTo == ws.me) {
      await showIncomingTransfer(context, ws, b);
      return;
    }
    if (b.waiterId == null && !b.mine) {
      await showTakeTable(context, ws, b, table);
      return;
    }
    if (!b.mine && !ws.senior && ws.ownTables) {
      await showForeignTable(context, ws, b, table);
      return;
    }
    await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => ChangeNotifierProvider.value(value: ws, child: BillScreen(billId: b.id))));
  }
}

class _DashedCard extends StatelessWidget {
  const _DashedCard({required this.child, required this.onTap});

  final Widget child;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => GestureDetector(
        onTap: onTap,
        child: CustomPaint(
          painter: _DashPainter(),
          child: Container(
            decoration: BoxDecoration(color: WC.white, borderRadius: BorderRadius.circular(14)),
            child: Center(child: child),
          ),
        ),
      );
}

/// Пунктирная рамка (карточка «Открыть стол», «Добавить блюда»).
class _DashPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()
      ..color = WC.gray300
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    final path = Path()..addRRect(RRect.fromRectAndRadius(Offset.zero & size, const Radius.circular(14)));
    for (final m in path.computeMetrics()) {
      var d = 0.0;
      while (d < m.length) {
        canvas.drawPath(m.extractPath(d, d + 5), p);
        d += 9;
      }
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

/// Та же пунктирная рамка снаружи — для «Добавить блюда» в счёте.
class DashedBox extends StatelessWidget {
  const DashedBox({super.key, required this.child, required this.onTap});

  final Widget child;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => _DashedCard(onTap: onTap, child: child);
}

// ------------------------------------------------------------------ Готово

class ReadyTab extends StatefulWidget {
  const ReadyTab({super.key});

  @override
  State<ReadyTab> createState() => _ReadyTabState();
}

class _ReadyTabState extends State<ReadyTab> {
  final Set<String> _busy = {};

  Future<void> _serve(WaiterState ws, List<(WBill, WItem)> list, String key) async {
    setState(() => _busy.add(key));
    try {
      await ws.serveAll(list);
    } catch (e) {
      if (mounted) wToast(context, e);
    }
    if (mounted) setState(() => _busy.remove(key));
  }

  @override
  Widget build(BuildContext context) {
    final ws = context.watch<WaiterState>();
    final byBill = <WBill, List<WItem>>{};
    for (final (b, i) in ws.readyForMe) {
      byBill.putIfAbsent(b, () => []).add(i);
    }
    return ListView(padding: const EdgeInsets.only(bottom: 24), children: [
      WHeader(title: tr('Готово на кухне', 'Oshxonada tayyor'), subtitle: tr('Заберите и отнесите гостям', 'Olib, mehmonlarga olib boring')),
      if (byBill.isEmpty)
        Padding(
          padding: const EdgeInsets.fromLTRB(32, 60, 32, 0),
          child: Column(children: [
            Container(
              width: 72,
              height: 72,
              decoration: const BoxDecoration(color: WC.green50, shape: BoxShape.circle),
              child: const Icon(Icons.room_service_rounded, size: 34, color: WC.green),
            ),
            const SizedBox(height: 12),
            Text(tr('Пока ничего не готово', 'Hozircha hech narsa tayyor emas'), style: wt(17, w: w7)),
            const SizedBox(height: 6),
            Text(tr('Когда кухня отметит блюдо готовым, оно появится здесь и придёт уведомление.', 'Oshxona taomni tayyor deb belgilaganda, u shu yerda paydo boʻladi va bildirishnoma keladi.'),
                style: wt(13, c: WC.gray500), textAlign: TextAlign.center),
          ]),
        ),
      for (final e in byBill.entries)
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
          child: WCard(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Text(tr('Стол ${e.key.tableNumber}', '${e.key.tableNumber}-stol'), style: wt(17, w: w7)),
                const SizedBox(width: 6),
                Expanded(child: Text(e.key.hallName, style: wt(12, c: WC.gray400), maxLines: 1, overflow: TextOverflow.ellipsis)),
                SizedBox(
                  height: 34,
                  child: FilledButton(
                    style: FilledButton.styleFrom(
                      backgroundColor: WC.green,
                      padding: const EdgeInsets.symmetric(horizontal: 14),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                    ),
                    onPressed: _busy.contains(e.key.id) ? null : () => _serve(ws, [for (final i in e.value) (e.key, i)], e.key.id),
                    child: Text(tr('Несу всё', 'Hammasini olaman'), style: wt(13, w: w7, c: WC.white)),
                  ),
                ),
              ]),
              const SizedBox(height: 4),
              for (final i in e.value)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 7),
                  child: Row(children: [
                    WQtyBox(qtyText(i.left)),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text(i.name, style: wt(14, w: w6)),
                        if (i.modsText.isNotEmpty || i.guest != null)
                          Text([if (i.guest != null) guestTag(i.guest!), if (i.modsText.isNotEmpty) i.modsText].join(' · '), style: wt(11, w: w4, c: WC.gray500)),
                      ]),
                    ),
                    TextButton(
                      onPressed: _busy.contains(i.id) ? null : () => _serve(ws, [(e.key, i)], i.id),
                      child: Text(tr('Несу', 'Olib boryapman'), style: wt(13, w: w7, c: WC.green)),
                    ),
                  ]),
                ),
            ]),
          ),
        ),
    ]);
  }
}

// ------------------------------------------------------------------ Брони

class _BookingsTab extends StatelessWidget {
  const _BookingsTab();

  @override
  Widget build(BuildContext context) {
    return ListView(children: [
      WHeader(title: tr('Брони', 'Bronlar')),
      Padding(
        padding: const EdgeInsets.fromLTRB(32, 60, 32, 0),
        child: Column(children: [
          Container(
            width: 72,
            height: 72,
            decoration: const BoxDecoration(color: WC.blue50, shape: BoxShape.circle),
            child: const Icon(Icons.event_rounded, size: 34, color: WC.blue),
          ),
          const SizedBox(height: 12),
          Text(tr('Брони скоро', 'Bronlar tez orada'), style: wt(17, w: w7)),
          const SizedBox(height: 6),
          Text(
            tr('Здесь будут брони на сегодня: кто придёт, к какому столу, «Гости пришли».', 'Bu yerda bugungi bronlar boʻladi: kim keladi, qaysi stolga, «Mehmonlar keldi».'),
            style: wt(13, c: WC.gray500),
            textAlign: TextAlign.center,
          ),
        ]),
      ),
    ]);
  }
}

// ------------------------------------------------------------------ Ещё

class _MoreTab extends StatefulWidget {
  const _MoreTab();

  @override
  State<_MoreTab> createState() => _MoreTabState();
}

class _MoreTabState extends State<_MoreTab> {
  Future<Map<String, dynamic>>? _sales;

  @override
  Widget build(BuildContext context) {
    final ws = context.watch<WaiterState>();
    final st = context.watch<StoreState>();
    _sales ??= ws.mySales();
    final name = '${st.me?['full_name'] ?? ''}';
    Widget tile(IconData icon, String title, {String? sub, VoidCallback? onTap, Color color = WC.ink}) => ListTile(
          leading: Icon(icon, color: color == WC.ink ? WC.gray600 : color),
          title: Text(title, style: wt(15, w: w6, c: color)),
          subtitle: sub == null ? null : Text(sub, style: wt(12, c: WC.gray500)),
          trailing: onTap == null || color != WC.ink ? null : const Icon(Icons.chevron_right_rounded, color: WC.gray400),
          onTap: onTap,
        );
    return RefreshIndicator(
      onRefresh: () async => setState(() => _sales = ws.mySales()),
      child: ListView(padding: const EdgeInsets.fromLTRB(16, 0, 16, 24), children: [
        Padding(
          padding: const EdgeInsets.only(top: 6, bottom: 12),
          child: Row(children: [
            WAvatar(name),
            const SizedBox(width: 10),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(name, style: wt(18, w: w7)),
                Text('${st.networkName} · ${st.store?['name'] ?? ''}', style: wt(12, c: WC.gray500), maxLines: 1, overflow: TextOverflow.ellipsis),
              ]),
            ),
          ]),
        ),
        // Мои продажи за сегодня.
        WCard(
          child: FutureBuilder<Map<String, dynamic>>(
            future: _sales,
            builder: (context, snap) {
              final d = snap.data;
              Widget cell(String label, String value) => Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(value, style: wt(18, w: w8)),
                      const SizedBox(height: 2),
                      Text(label, style: wt(11, c: WC.gray500)),
                    ]),
                  );
              return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(tr('Мои продажи сегодня', 'Bugungi savdolarim'), style: wt(14, w: w7)),
                const SizedBox(height: 10),
                if (d == null)
                  snap.hasError
                      ? Text(snap.error.toString(), style: wt(12, c: WC.red))
                      : const LinearProgressIndicator(minHeight: 2)
                else ...[
                  Row(children: [
                    cell(tr('выручка', 'tushum'), sum(d['total'])),
                    cell(tr('обслуживание', 'xizmat'), sum(d['service'])),
                  ]),
                  const SizedBox(height: 12),
                  Row(children: [
                    cell(tr('столов закрыто', 'yopilgan stollar'), '${d['bills'] ?? 0}'),
                    cell(tr('гостей', 'mehmonlar'), '${d['guests'] ?? 0}'),
                    cell(tr('открыто сейчас', 'hozir ochiq'), '${d['open'] ?? 0}'),
                  ]),
                ],
              ]);
            },
          ),
        ),
        const SizedBox(height: 12),
        WCard(
          padding: EdgeInsets.zero,
          child: Column(children: [
            if (ws.senior)
              tile(Icons.grid_view_rounded, tr('Зоны на смену', 'Smena zonalari'), sub: tr('Кто за какими столами сегодня', 'Bugun kim qaysi stollarda'), onTap: () {
                Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => ChangeNotifierProvider.value(value: ws, child: const ZonesScreen())));
              }),
            if (st.stores.length > 1)
              tile(Icons.storefront_outlined, tr('Заведение', 'Muassasa'), sub: '${st.store?['name'] ?? ''}', onTap: () => pickStore(context)),
            if (!st.onlyWaiter)
              tile(Icons.storefront_rounded, tr('Режим магазина', 'Doʻkon rejimi'), sub: tr('Склад, финансы, заказы', 'Ombor, moliya, buyurtmalar'), onTap: () => st.setWaiterMode(false)),
            tile(Icons.translate_rounded, tr('Язык', 'Til'), sub: Lang.names[Lang.instance.code], onTap: () => _pickLanguage(context)),
            tile(Icons.logout_rounded, tr('Выйти', 'Chiqish'), color: WC.red, onTap: () async {
              final ok = await confirmSheet(
                context,
                icon: Icons.logout_rounded,
                title: tr('Выйти из приложения?', 'Ilovadan chiqasizmi?'),
                text: tr('Уведомления «Готово» перестанут приходить.', '«Tayyor» bildirishnomalari kelmay qoladi.'),
                confirm: tr('Выйти', 'Chiqish'),
              );
              if (ok && context.mounted) await signOut(context);
            }),
          ]),
        ),
      ]),
    );
  }

  Future<void> _pickLanguage(BuildContext context) async {
    final api = context.read<Api>();
    final code = await pickLanguage(context);
    if (code == null || !api.loggedIn) return;
    try {
      await api.put('/me/language', {'language': code});
    } catch (_) {}
  }
}
