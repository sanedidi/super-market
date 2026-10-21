// Экран кухни (Figma «Кухня» КХ1, отмена — КХ4): планшет или монитор у цеха.
// Светлая тема, крупные номера и таймеры — читается издалека. Колонки
// «Новые», «Готовятся», «Готово — ждут выдачи»; вкладки цехов, если экран
// показывает все цеха; «Стоп-лист» в шапке; звук на новый заказ.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:sm_core/sm_core.dart' show tr;

import '../core/catalog.dart';
import '../data/api.dart';
import '../state/pos.dart';
import '../ui/kit.dart';
import '../ui/theme.dart';
import 'kitchen_board.dart';
import 'menu.dart';

const _blue = Color(0xFF1D5FE8);
const _orange = Color(0xFFDC6803);
const _green = Color(0xFF079455);

String _clock(Duration d) {
  final s = d.inSeconds < 0 ? 0 : d.inSeconds;
  return '${(s ~/ 60).toString().padLeft(2, '0')}:${(s % 60).toString().padLeft(2, '0')}';
}

class KitchenScreen extends StatefulWidget {
  const KitchenScreen({super.key});

  @override
  State<KitchenScreen> createState() => _KitchenScreenState();
}

class _KitchenScreenState extends State<KitchenScreen> {
  late final PosController pos = context.read<PosController>();
  late final LiveFeed feed;
  List<KOrder> orders = [];
  String? fixedWorkshop;

  /// Вкладка цеха на экране всех цехов (null — «Все цеха»).
  String? tab;
  bool sound = true;
  bool busy = false;
  final Set<String> _known = {};
  final Set<String> _acked = {};
  bool _first = true;
  DateTime now = DateTime.now();
  Timer? _tick;
  DateTime _lastCatalog = DateTime.fromMillisecondsSinceEpoch(0);

  @override
  void initState() {
    super.initState();
    sound = pos.catalog.cafe?.kitchenSound ?? true;
    fixedWorkshop = pos.catalog.settings.workshopId;
    feed = LiveFeed(baseUrl: pos.api.baseUrl, token: pos.api.token, load: _load)
      ..addListener(_changed)
      ..start();
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() => now = DateTime.now());
    });
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  }

  @override
  void dispose() {
    _tick?.cancel();
    feed.removeListener(_changed);
    feed.dispose();
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  Future<int> _load(PosApi api) async {
    final res = await api.get('/pos/kitchen/board') as Map<String, dynamic>;
    _apply(res);
    // Стоп-лист и цеха — из каталога кассы; после перемен перечитать (не чаще раза в 10 с).
    if (DateTime.now().difference(_lastCatalog) > const Duration(seconds: 10)) {
      _lastCatalog = DateTime.now();
      unawaited(pos.syncCatalog());
    }
    return (res['version'] as num?)?.toInt() ?? 0;
  }

  void _apply(Map<String, dynamic> res) {
    final list = [for (final o in (res['orders'] as List?) ?? const []) KOrder.fromJson(o as Map<String, dynamic>)];
    fixedWorkshop = res['workshop_id'] as String?;
    if (fixedWorkshop != null) tab = null;
    // Новый заказ — звук (кроме первой загрузки). «По команде» звенит,
    // когда официант скажет «Подавать».
    bool live(KOrder o) => o.visible(_scope).isNotEmpty && KOrder.statusOf(o.visible(_scope)) != 'waiting';
    final fresh = list.where((o) => !_known.contains(o.id) && live(o)).toList();
    _known.addAll([for (final o in list) if (live(o)) o.id]);
    if (!_first && fresh.isNotEmpty && sound) _beep();
    _first = false;
    if (mounted) {
      setState(() => orders = list);
    } else {
      orders = list;
    }
  }

  void _beep() {
    SystemSound.play(SystemSoundType.alert);
    Future<void>.delayed(const Duration(milliseconds: 250), () => SystemSound.play(SystemSoundType.click));
  }

  /// Цех, который сейчас смотрит экран (null — все цеха).
  String? get _scope => fixedWorkshop ?? tab;

  CafeMenu? get menu => pos.catalog.cafe;

  String _wsName(String? id) => menu?.workshop(id)?.name ?? '';

  Future<void> _post(String path, Map<String, dynamic> body) async {
    if (busy) return;
    setState(() => busy = true);
    try {
      final res = await feed.api.post(path, body) as Map<String, dynamic>;
      _apply(res);
    } on ApiError catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  void _act(KOrder o, String action) => _post('/pos/kitchen/orders/${o.id}/action', {
        'action': action,
        if (_scope != null) 'workshop_id': _scope,
      });

  void _done(KItem i) => _post('/pos/kitchen/items/${i.id}/done', {'done': !i.done});

  Future<void> _back(KOrder o) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('Вернуть «${o.title}» в «Готовятся»?', '«${o.title}» ni «Tayyorlanmoqda»ga qaytarishmi?')),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: Text(tr('Нет', 'Yoʻq'))),
          FilledButton(onPressed: () => Navigator.of(ctx).pop(true), child: Text(tr('Вернуть', 'Qaytarish'))),
        ],
      ),
    );
    if (ok == true) _act(o, 'back');
  }

  // ------------------------------------------------------------- стоп-лист

  Future<void> _stopList() async {
    if (menu == null) return;
    await showDialog<void>(context: context, builder: (_) => _StopDialog(pos: pos, api: feed.api, scope: _scope));
    if (mounted) setState(() {});
  }

  // ------------------------------------------------------------------ экран

  @override
  Widget build(BuildContext context) {
    context.watch<PosController>();
    final scope = _scope;
    final cols = <String, List<KOrder>>{'new': [], 'cooking': [], 'ready': []};
    final cancels = <KOrder>[];
    for (final o in orders) {
      final vis = o.visible(scope);
      if (vis.isEmpty) continue;
      final st = KOrder.statusOf(vis);
      // «По команде» — серой карточкой внизу «Новых», пока официант не скажет «Подавать».
      cols[st == 'waiting' ? 'new' : st]?.add(o);
      final cancelled = vis.any((t) => t.cancelledAt != null || t.items.any((i) => i.cancelled > 0));
      if (cancelled && !_acked.contains(o.id)) cancels.add(o);
    }
    final ready = cols['ready']!..sort((a, b) => (a.readyAt(a.visible(scope)) ?? a.paidAt).compareTo(b.readyAt(b.visible(scope)) ?? b.paidAt));
    return Scaffold(
      backgroundColor: C.page,
      body: Column(children: [
        _header(),
        if (!feed.online)
          Container(
            width: double.infinity,
            color: C.warningSoft,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Text(
              tr('Нет связи с сервером — заказы не обновляются. Бегунки печатает касса.', 'Server bilan aloqa yoʻq — buyurtmalar yangilanmayapti. Cheklarni kassa chop etadi.'),
              style: t(14, w: FontWeight.w600, c: C.warning),
            ),
          ),
        if (cancels.isNotEmpty) _cancelBanner(cancels),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
            child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Expanded(child: _column(tr('Новые', 'Yangi'), _blue, cols['new']!, 1)),
              const SizedBox(width: 12),
              Expanded(flex: 2, child: _column(tr('Готовятся', 'Tayyorlanmoqda'), _orange, cols['cooking']!, 2)),
              const SizedBox(width: 12),
              Expanded(child: _column(tr('Готово — ждут выдачи', 'Tayyor — berishni kutmoqda'), _green, ready, 1)),
            ]),
          ),
        ),
      ]),
    );
  }

  Widget _header() {
    final m = menu;
    final s = pos.catalog.settings;
    final counts = <String?, int>{null: 0};
    for (final o in orders) {
      for (final tk in o.tickets) {
        if (tk.untracked || !(tk.status == 'new' || tk.status == 'cooking')) continue;
        counts[tk.workshopId] = (counts[tk.workshopId] ?? 0) + 1;
      }
      if (o.tickets.any((tk) => !tk.untracked && (tk.status == 'new' || tk.status == 'cooking'))) counts[null] = counts[null]! + 1;
    }
    Widget pill(String label, bool on, VoidCallback? onTap) => Padding(
          padding: const EdgeInsets.only(right: 6),
          child: Material(
            color: on ? Colors.white : Colors.white.withValues(alpha: 0.16),
            borderRadius: BorderRadius.circular(8),
            child: InkWell(
              borderRadius: BorderRadius.circular(8),
              onTap: onTap,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
                child: Text(label, style: t(14, w: FontWeight.w700, c: on ? C.brand : Colors.white)),
              ),
            ),
          ),
        );
    final stopCount = m?.stop.length ?? 0;
    return Container(
      height: 52,
      color: C.brand,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(children: [
        const Wordmark(size: 18),
        const SizedBox(width: 14),
        Flexible(
          child: Text(
            '${tr('Кухня', 'Oshxona')} · ${s.storeName}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: t(15, w: FontWeight.w600, c: Colors.white),
          ),
        ),
        const SizedBox(width: 18),
        Expanded(
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(children: [
              if (fixedWorkshop != null)
                pill('${_wsName(fixedWorkshop)}  ${counts[fixedWorkshop] ?? 0}', true, null)
              else if (m != null) ...[
                pill('${tr('Все цеха', 'Barcha sexlar')}  ${counts[null] ?? 0}', tab == null, () => setState(() => tab = null)),
                for (final w in m.workshops) pill('${w.name}  ${counts[w.id] ?? 0}', tab == w.id, () => setState(() => tab = w.id)),
              ],
            ]),
          ),
        ),
        TextButton.icon(
          onPressed: () => setState(() => sound = !sound),
          icon: Icon(sound ? Icons.notifications_active_outlined : Icons.notifications_off_outlined, color: Colors.white, size: 20),
          label: Text(tr('Звук', 'Ovoz'), style: t(14, w: FontWeight.w600, c: Colors.white)),
        ),
        const SizedBox(width: 6),
        Material(
          color: Colors.white.withValues(alpha: 0.16),
          borderRadius: BorderRadius.circular(8),
          child: InkWell(
            borderRadius: BorderRadius.circular(8),
            onTap: _stopList,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
              child: Row(children: [
                const Icon(Icons.block_rounded, color: Colors.white, size: 18),
                const SizedBox(width: 6),
                Text('${tr('Стоп-лист', 'Stop-roʻyxat')} · $stopCount', style: t(14, w: FontWeight.w700, c: Colors.white)),
              ]),
            ),
          ),
        ),
        const SizedBox(width: 16),
        Text('${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}', style: tb(22, c: Colors.white)),
      ]),
    );
  }

  Widget _cancelBanner(List<KOrder> list) {
    final o = list.first;
    final lines = <String>[];
    for (final tk in o.visible(_scope)) {
      for (final i in tk.items) {
        if (i.cancelled > 0) lines.add('${qtyText(i.cancelled)} × ${i.name}');
      }
    }
    final more = list.length > 1 ? tr(' · ещё ${list.length - 1}', ' · yana ${list.length - 1}') : '';
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 12, 12, 0),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(color: C.brand, borderRadius: BorderRadius.circular(12)),
      child: Row(children: [
        const Icon(Icons.notifications_active_outlined, color: Colors.white, size: 28),
        const SizedBox(width: 14),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('${tr('ОТМЕНА', 'BEKOR')} · ${o.title}$more', style: t(17, w: FontWeight.w800, c: Colors.white)),
            Text('${lines.join(', ')} — ${tr('не готовьте', 'tayyorlamang')}', style: t(14, w: FontWeight.w500, c: Colors.white)),
          ]),
        ),
        FilledButton(
          onPressed: () => setState(() => _acked.add(o.id)),
          style: FilledButton.styleFrom(backgroundColor: Colors.white, foregroundColor: C.brand, minimumSize: const Size(96, 44)),
          child: Text(tr('Понял', 'Tushundim'), style: t(15, w: FontWeight.w800, c: C.brand)),
        ),
      ]),
    );
  }

  Widget _column(String title, Color dot, List<KOrder> list, int lanes) {
    // Ждущие команды — после остальных.
    final sorted = [...list.where((o) => KOrder.statusOf(o.visible(_scope)) != 'waiting'), ...list.where((o) => KOrder.statusOf(o.visible(_scope)) == 'waiting')];
    final cards = [for (final o in sorted) _card(o)];
    Widget body;
    if (list.isEmpty) {
      body = const SizedBox.shrink();
    } else if (lanes == 1) {
      body = ListView.separated(
        padding: const EdgeInsets.only(bottom: 12),
        itemCount: cards.length,
        separatorBuilder: (_, __) => const SizedBox(height: 12),
        itemBuilder: (_, i) => cards[i],
      );
    } else {
      // Две дорожки карточек — по очереди, старые сверху.
      final left = <Widget>[], right = <Widget>[];
      for (var i = 0; i < cards.length; i++) {
        (i.isEven ? left : right).add(Padding(padding: const EdgeInsets.only(bottom: 12), child: cards[i]));
      }
      body = SingleChildScrollView(
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(child: Column(children: left)),
          const SizedBox(width: 12),
          Expanded(child: Column(children: right)),
        ]),
      );
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Padding(
        padding: const EdgeInsets.only(left: 4, bottom: 8),
        child: Row(children: [
          Container(width: 10, height: 10, decoration: BoxDecoration(color: dot, shape: BoxShape.circle)),
          const SizedBox(width: 8),
          Flexible(child: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: t(17, w: FontWeight.w800))),
          const SizedBox(width: 8),
          Text('${list.length}', style: t(17, w: FontWeight.w700, c: C.td)),
        ]),
      ),
      Expanded(child: body),
    ]);
  }

  Widget _card(KOrder o) {
    final vis = o.visible(_scope);
    final status = KOrder.statusOf(vis);
    final norm = o.cookMinutes(vis);
    final elapsed = now.difference(o.paidAt);
    final lateAfter = Duration(minutes: norm) + Duration(seconds: (norm * 60 * 0.15).round().clamp(120, 3600).toInt());
    final readyAt = o.readyAt(vis);
    Color bar;
    Color timerColor;
    String? note;
    Color noteColor = _green;
    Duration shown = elapsed;
    if (status == 'ready') {
      bar = _green;
      timerColor = _green;
      shown = readyAt == null ? elapsed : now.difference(readyAt);
      note = o.orderType == 'delivery' ? tr('ждёт курьера', 'kuryerni kutmoqda') : tr('ждёт выдачи', 'berishni kutmoqda');
    } else if (elapsed > lateAfter) {
      bar = C.error;
      timerColor = C.error;
      note = tr('ОПАЗДЫВАЕТ · норма $norm мин', 'KECHIKMOQDA · meʼyor $norm daq');
      noteColor = C.error;
    } else if (elapsed > Duration(minutes: norm)) {
      bar = _orange;
      timerColor = _orange;
      note = tr('дольше нормы ($norm мин)', 'meʼyordan uzoq ($norm daq)');
      noteColor = _orange;
    } else {
      bar = status == 'new' ? _blue : _green;
      timerColor = status == 'new' ? _blue : _green;
    }
    final waiting = status == 'waiting';
    if (waiting) {
      bar = C.border;
      timerColor = C.td;
      note = tr('ждёт команды официанта — не готовьте', 'ofitsiant buyrugʻini kutmoqda — tayyorlamang');
      noteColor = C.td;
    }
    final redFrame = !waiting && status != 'ready' && elapsed > lateAfter;
    // Позиции других цехов — подсказка «+ 2 позиции в баре».
    final others = <String, int>{};
    if (_scope != null) {
      for (final tk in o.tickets) {
        if (tk.workshopId == _scope || tk.status == 'cancelled') continue;
        others[_wsName(tk.workshopId)] = (others[_wsName(tk.workshopId)] ?? 0) + tk.items.length;
      }
    }
    final typeIcon = switch (o.orderType) {
      'takeaway' => Icons.takeout_dining_outlined,
      'delivery' => Icons.two_wheeler_rounded,
      _ => o.tableLabel.isNotEmpty ? Icons.table_restaurant_outlined : Icons.restaurant_rounded,
    };
    final typeLabel = switch (o.orderType) {
      'takeaway' => tr('С собой', 'Olib ketish'),
      'delivery' => tr('Доставка', 'Yetkazish'),
      _ => o.waiter.isNotEmpty ? o.waiter : tr('Здесь', 'Shu yerda'),
    };
    final (label, color, action) = switch (status) {
      'waiting' => (tr('Ждёт команды', 'Buyruq kutilmoqda'), C.td, ''),
      'new' => (tr('Начать готовить', 'Tayyorlashni boshlash'), _blue, 'start'),
      'cooking' => (tr('Готово', 'Tayyor'), _green, 'ready'),
      _ => (o.orderType == 'delivery' ? tr('Отдано курьеру', 'Kuryerga berildi') : tr('Выдано', 'Berildi'), C.dark, 'served'),
    };
    return GestureDetector(
      onLongPress: status == 'ready' ? () => _back(o) : null,
      child: Container(
        decoration: BoxDecoration(
          color: C.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: redFrame ? C.error : C.border, width: redFrame ? 2 : 1),
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Container(height: 5, color: bar),
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 10, 14, 4),
            child: Row(children: [
              Text(o.title, style: tb(26, c: waiting ? C.td : C.tp)),
              const SizedBox(width: 10),
              Icon(typeIcon, size: 16, color: C.t2),
              const SizedBox(width: 4),
              Flexible(child: Text(typeLabel, maxLines: 1, overflow: TextOverflow.ellipsis, style: t(13, w: FontWeight.w600, c: C.t2))),
              const Spacer(),
              Icon(Icons.timer_outlined, size: 20, color: timerColor),
              const SizedBox(width: 4),
              if (!waiting) Text(_clock(shown), style: tb(22, c: timerColor)),
            ]),
          ),
          if (note != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 0, 14, 4),
              child: Text(note, style: t(12.5, w: FontWeight.w700, c: noteColor)),
            ),
          const SizedBox(height: 4),
          for (final tk in vis)
            for (final i in tk.items) _item(i, enabled: status != 'ready' && !waiting),
          if (others.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 4, 14, 0),
              child: Row(children: [
                const Icon(Icons.local_bar_outlined, size: 15, color: C.td),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    others.entries.map((e) => tr('+ ${e.value} поз. · ${e.key}', '+ ${e.value} ta · ${e.key}')).join('   '),
                    style: t(12.5, c: C.td),
                  ),
                ),
              ]),
            ),
          Padding(
            padding: const EdgeInsets.all(12),
            child: SizedBox(
              height: 52,
              child: FilledButton(
                onPressed: busy || waiting ? null : () => _act(o, action),
                style: FilledButton.styleFrom(backgroundColor: color, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10))),
                child: Text(label, style: t(17, w: FontWeight.w700, c: Colors.white)),
              ),
            ),
          ),
        ]),
      ),
    );
  }

  Widget _item(KItem i, {required bool enabled}) {
    final dim = i.done || i.allCancelled;
    final cancelled = i.cancelled > 0;
    final removes = [for (final m in i.mods) if (m.action == 'remove') m.name.toUpperCase()];
    final rest = [for (final m in i.mods) if (m.action != 'remove') m.qty > 1 ? '${m.name} ×${m.qty}' : m.name];
    return InkWell(
      onTap: enabled && !i.allCancelled ? () => _done(i) : null,
      child: Container(
        color: cancelled ? C.errorSoft : null,
        padding: const EdgeInsets.fromLTRB(10, 7, 14, 7),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(i.done ? Icons.check_box_rounded : Icons.check_box_outline_blank_rounded, size: 24, color: i.done ? _green : C.td),
          const SizedBox(width: 10),
          SizedBox(
            width: 34,
            child: Text('${qtyText(i.qty)}×', style: t(17, w: FontWeight.w800, c: dim ? C.td : C.tp)),
          ),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(
                i.name,
                style: t(17, w: FontWeight.w700, c: dim ? C.td : C.tp).copyWith(decoration: dim ? TextDecoration.lineThrough : null),
              ),
              if (rest.isNotEmpty) Text(rest.join(' · '), style: t(13, c: C.ts)),
              if (removes.isNotEmpty) Text(removes.join(' · '), style: t(13, w: FontWeight.w800, c: C.error)),
              if (i.note.isNotEmpty) Text('» ${i.note}', style: t(13, w: FontWeight.w600, c: _orange)),
              if (cancelled)
                Container(
                  margin: const EdgeInsets.only(top: 4),
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(color: C.error, borderRadius: BorderRadius.circular(6)),
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    const Icon(Icons.block_rounded, size: 14, color: Colors.white),
                    const SizedBox(width: 4),
                    Text(
                      i.allCancelled
                          ? tr('ОТМЕНА · не готовить', 'BEKOR · tayyorlamang')
                          : tr('ОТМЕНА ${qtyText(i.cancelled)} из ${qtyText(i.qty)} · не готовить', 'BEKOR ${qtyText(i.qty)} dan ${qtyText(i.cancelled)} · tayyorlamang'),
                      style: t(12, w: FontWeight.w800, c: Colors.white),
                    ),
                  ]),
                ),
            ]),
          ),
        ]),
      ),
    );
  }
}

/// Стоп-лист с кухни: блюдо на стопе — на кассе плитка «стоп-лист», в
/// приложении покупателя блюдо скрыто.
class _StopDialog extends StatefulWidget {
  const _StopDialog({required this.pos, required this.api, required this.scope});

  final PosController pos;
  final PosApi api;
  final String? scope;

  @override
  State<_StopDialog> createState() => _StopDialogState();
}

class _StopDialogState extends State<_StopDialog> {
  final q = TextEditingController();
  String? busy;
  String? error;

  @override
  void dispose() {
    q.dispose();
    super.dispose();
  }

  Future<void> toggle(Product p, bool stopped) async {
    final menu = widget.pos.catalog.cafe;
    if (menu == null) return;
    setState(() {
      busy = p.id;
      error = null;
    });
    try {
      final res = await widget.api.send('PUT', '/pos/kitchen/stop', body: {'product_id': p.id, 'stopped': stopped}) as Map<String, dynamic>;
      menu.stop
        ..clear()
        ..addAll([for (final x in (res['stop'] as List?) ?? const []) '$x']);
    } on ApiError catch (e) {
      error = e.message;
    } finally {
      if (mounted) setState(() => busy = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final menu = widget.pos.catalog.cafe;
    final cat = widget.pos.catalog;
    final query = q.text.trim().toLowerCase();
    final items = <(Product, CafeDish)>[];
    if (menu != null) {
      for (final d in menu.dishes) {
        if (!d.isDish || !d.onSale) continue;
        if (widget.scope != null && menu.workshop(d.workshopId)?.id != widget.scope) continue;
        final p = cat.byId(d.productId);
        if (p == null) continue;
        if (query.isNotEmpty && !'${p.name} ${p.nameRu} ${p.nameUz} ${d.code ?? ''}'.toLowerCase().contains(query)) continue;
        items.add((p, d));
      }
      items.sort((a, b) {
        final sa = menu.stopped(a.$1.id) ? 0 : 1, sb = menu.stopped(b.$1.id) ? 0 : 1;
        if (sa != sb) return sa - sb;
        return a.$1.name.compareTo(b.$1.name);
      });
    }
    return Dialog(
      backgroundColor: C.surface,
      insetPadding: const EdgeInsets.all(24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 620, maxHeight: 640),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Row(children: [
              Expanded(child: Text(tr('Стоп-лист', 'Stop-roʻyxat'), style: t(22, w: FontWeight.w800))),
              IconButton(onPressed: () => Navigator.of(context).pop(), icon: const Icon(Icons.close_rounded)),
            ]),
            Text(
              tr('Закончилось — поставьте на стоп: касса не продаст, в приложении блюдо скроется.',
                  'Tugadi — stopga qoʻying: kassa sotmaydi, ilovada taom yashiriladi.'),
              style: t(13.5, c: C.ts),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: q,
              decoration: InputDecoration(prefixIcon: const Icon(Icons.search_rounded), hintText: tr('Найти блюдо или код', 'Taom yoki kodni toping')),
              onChanged: (_) => setState(() {}),
            ),
            if (error != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text(error!, style: t(13.5, w: FontWeight.w600, c: C.error))),
            const SizedBox(height: 8),
            Expanded(
              child: ListView.separated(
                itemCount: items.length,
                separatorBuilder: (_, __) => const Divider(height: 1, color: C.border),
                itemBuilder: (_, i) {
                  final (p, d) = items[i];
                  final on = menu!.stopped(p.id);
                  return ListTile(
                    contentPadding: const EdgeInsets.symmetric(horizontal: 4),
                    title: Text(p.name, style: t(16, w: FontWeight.w600, c: on ? C.warning : C.tp)),
                    subtitle: Text([if (d.code != null) '${d.code}', menu.group(d.groupId)?.name ?? ''].where((x) => x.isNotEmpty).join(' · '),
                        style: t(12.5, c: C.ts)),
                    trailing: busy == p.id
                        ? const SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2))
                        : Switch(value: on, activeTrackColor: C.warning, onChanged: busy != null ? null : (v) => toggle(p, v)),
                  );
                },
              ),
            ),
          ]),
        ),
      ),
    );
  }
}
