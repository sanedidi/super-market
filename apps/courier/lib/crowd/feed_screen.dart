import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:sm_core/sm_core.dart' hide LoginScreen;

import '../main.dart';
import '../ui/theme.dart';
import '../ui/widgets.dart';
import 'crowd_logic.dart';
import 'crowd_order_screen.dart';
import 'crowd_state.dart';

/// Лента «по пути» (Figma Ц3); пока личность не подтверждена — QR и точки проверки (Ц2).
class FeedScreen extends StatelessWidget {
  const FeedScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final st = context.watch<CrowdState>();
    final top = MediaQuery.paddingOf(context).top;
    Future<void> refresh() => st.refresh().catchError((Object e) {
          if (context.mounted) showMessage(context, e);
        });
    return Scaffold(
      backgroundColor: AppColors.bg,
      body: RefreshIndicator(
        onRefresh: refresh,
        child: ListView(
          padding: EdgeInsets.fromLTRB(20, top + 12, 20, 24),
          children: st.verified ? _feed(context, st) : _unverified(context, st),
        ),
      ),
    );
  }

  List<Widget> _unverified(BuildContext context, CrowdState st) {
    final me = st.me ?? const {};
    final code = '${me['code'] ?? ''}';
    final blocked = st.status == 'blocked';
    return [
      StatusChip(blocked ? 'Заблокирован' : 'Не верифицирован', icon: blocked ? Icons.block_rounded : Icons.hourglass_top_rounded, tone: ChipTone.amber),
      const SizedBox(height: 8),
      const Text('Привет!', style: AppText.h1),
      const SizedBox(height: 16),
      Container(
        padding: const EdgeInsets.all(22),
        decoration: BoxDecoration(color: AppColors.white, borderRadius: BorderRadius.circular(24)),
        child: Column(children: [
          const Text('Покажите этот код продавцу', style: AppText.title, textAlign: TextAlign.center),
          const SizedBox(height: 8),
          Text('В любом магазине Super Market из списка ниже. Возьмите паспорт или ID-карту — продавец сверит документ, копию мы не храним.',
              style: AppText.small.copyWith(fontSize: 14), textAlign: TextAlign.center),
          const SizedBox(height: 16),
          QrImageView(data: courierQr(code), size: 200, backgroundColor: AppColors.white),
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            decoration: BoxDecoration(color: AppColors.soft, borderRadius: BorderRadius.circular(12)),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Text('Код курьера', style: AppText.small.copyWith(fontWeight: FontWeight.w500)),
              const SizedBox(width: 8),
              Text(code, style: AppText.bodyStrong),
            ]),
          ),
        ]),
      ),
      const SizedBox(height: 20),
      Row(children: [
        const Expanded(child: Text('Ближайшие точки проверки', style: AppText.title)),
        if (st.lastPosition == null)
          TextButton.icon(
            onPressed: () => st.locateOnce().catchError((Object e) {
              if (context.mounted) showMessage(context, e);
            }),
            icon: const Icon(Icons.my_location_rounded, size: 18),
            label: const Text('Рядом со мной'),
          ),
      ]),
      const SizedBox(height: 10),
      if (st.points.isEmpty)
        const EmptyState(icon: Icons.storefront_rounded, title: 'Пока нет магазинов', text: 'Скоро магазины Super Market начнут проверять курьеров')
      else
        Container(
          decoration: BoxDecoration(color: AppColors.white, borderRadius: BorderRadius.circular(20)),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          child: Column(children: [
            for (var i = 0; i < st.points.length; i++) _PointRow(st.points[i], last: i == st.points.length - 1),
          ]),
        ),
    ];
  }

  List<Widget> _feed(BuildContext context, CrowdState st) {
    final me = st.me ?? const {};
    final dest = me['dest'] as Map?;
    final state = '${st.feed?['state'] ?? 'ok'}';
    final level = (me['level'] as Map?) ?? const {};
    return [
      Row(children: [
        const Expanded(child: Text('По пути', style: AppText.h1)),
        _OnlineChip(online: st.online, onChanged: (v) => st.setOnline(v).catchError((Object e) {
              if (context.mounted) showMessage(context, e);
            })),
      ]),
      const SizedBox(height: 14),
      if (st.locationProblem != null && st.online) ...[
        _Banner(
          icon: Icons.location_off_rounded,
          text: '${st.locationProblem}. Без геопозиции лента не подберёт заказы рядом.',
          action: 'Настройки',
          onAction: st.openLocationSettings,
        ),
        const SizedBox(height: 12),
      ],
      if (st.activeOrders.isNotEmpty) ...[
        Text('Мои заказы', style: AppText.title),
        const SizedBox(height: 10),
        for (final o in st.activeOrders) _ActiveCard(o),
        const SizedBox(height: 8),
      ],
      Material(
        color: AppColors.white,
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: () => _pickRoute(context, st),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            child: Row(children: [
              const Icon(Icons.route_rounded, color: AppColors.blue),
              const SizedBox(width: 10),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(dest == null ? 'Просто рядом' : 'Иду: ${dest['title']}', style: AppText.bodyStrong),
                  Text(dest == null ? 'Заказы рядом с вами' : 'Показываем заказы с небольшим крюком', style: AppText.small),
                ]),
              ),
              Text('Изменить', style: AppText.bodyStrong.copyWith(color: AppColors.primary, fontSize: 14)),
            ]),
          ),
        ),
      ),
      const SizedBox(height: 18),
      Row(children: [
        Expanded(child: Text(st.offers.isEmpty ? 'Заказы по пути' : '${st.offers.length} ${_ordersWord(st.offers.length)} по пути', style: AppText.title)),
        Text('${level['title'] ?? ''} · до ${money(level['limit'])}', style: AppText.small.copyWith(fontWeight: FontWeight.w500)),
      ]),
      const SizedBox(height: 10),
      if (state == 'offline')
        EmptyState(
          icon: Icons.pause_circle_rounded,
          title: 'Вы не ищете заказы',
          text: 'Включите «Ищу заказы» — покажем собранные заказы рядом и по пути',
          action: 'Искать заказы',
          onAction: () => st.setOnline(true).catchError((Object e) {
            if (context.mounted) showMessage(context, e);
          }),
        )
      else if (state == 'busy')
        const EmptyState(
          icon: Icons.local_shipping_rounded,
          title: 'Сначала доставьте текущий заказ',
          text: 'На вашем уровне можно везти ограниченное число заказов сразу',
        )
      else if (state == 'no_location')
        EmptyState(
          icon: Icons.my_location_rounded,
          title: 'Определяем, где вы',
          text: 'Разрешите доступ к геопозиции — без неё лента не подберёт заказы',
          action: 'Повторить',
          onAction: st.retryLocation,
        )
      else if (st.offers.isEmpty)
        const EmptyState(
          icon: Icons.near_me_rounded,
          title: 'Пока нет заказов по пути',
          text: 'Как только магазин рядом соберёт заказ, он появится здесь — телефон завибрирует',
        )
      else
        for (final o in st.offers) _OfferCard(o),
    ];
  }

  static String _ordersWord(int n) {
    final m10 = n % 10, m100 = n % 100;
    if (m10 == 1 && m100 != 11) return 'заказ';
    if (m10 >= 2 && m10 <= 4 && (m100 < 10 || m100 >= 20)) return 'заказа';
    return 'заказов';
  }

  Future<void> _pickRoute(BuildContext context, CrowdState st) async {
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      backgroundColor: AppColors.white,
      builder: (ctx) => _RouteSheet(st: st),
    );
  }
}

class _RouteSheet extends StatefulWidget {
  const _RouteSheet({required this.st});
  final CrowdState st;

  @override
  State<_RouteSheet> createState() => _RouteSheetState();
}

class _RouteSheetState extends State<_RouteSheet> {
  bool _busy = false;

  Future<void> _run(Future<void> Function() fn) async {
    setState(() => _busy = true);
    try {
      await fn();
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (mounted) showMessage(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final st = widget.st;
    Widget place(String key, String title, IconData icon) {
      final p = st.places[key];
      return ListTile(
        enabled: !_busy,
        leading: Icon(icon, color: AppColors.ink),
        title: Text(p == null ? title : 'Иду: $title', style: AppText.bodyStrong),
        subtitle: Text(p == null ? 'Нажмите, когда будете там — запомним это место' : 'Заказы с небольшим крюком по дороге', style: AppText.small),
        trailing: p == null ? const Icon(Icons.add_location_alt_rounded, color: AppColors.primary) : null,
        onTap: () => _run(() async {
          final target = p ?? await st.saveHere(key, title);
          if (target == null) throw ApiError(0, 'location', 'Не удалось определить место — включите геопозицию');
          await st.setDest(target);
        }),
      );
    }

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 0, 8, 12),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Padding(padding: EdgeInsets.fromLTRB(16, 0, 16, 8), child: Text('Куда идёте?', style: AppText.h3)),
          ListTile(
            enabled: !_busy,
            leading: const Icon(Icons.near_me_rounded, color: AppColors.ink),
            title: const Text('Просто рядом', style: AppText.bodyStrong),
            subtitle: Text('Заказы в радиусе пары километров', style: AppText.small),
            onTap: () => _run(() => st.setDest(null)),
          ),
          place('home', 'Дом', Icons.home_rounded),
          place('work', 'Работа', Icons.work_rounded),
          if (st.places.isNotEmpty)
            TextButton(
              onPressed: _busy
                  ? null
                  : () => _run(() async {
                        for (final k in st.places.keys.toList()) {
                          await st.saveHere(k, st.places[k]!.title);
                        }
                      }),
              child: const Text('Обновить сохранённое место на текущее'),
            ),
        ]),
      ),
    );
  }
}

class _OnlineChip extends StatelessWidget {
  const _OnlineChip({required this.online, required this.onChanged});
  final bool online;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: online ? AppColors.successSoft : AppColors.soft,
      borderRadius: BorderRadius.circular(20),
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: () => onChanged(!online),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.circle, size: 10, color: online ? AppColors.success : AppColors.muted),
            const SizedBox(width: 6),
            Text(online ? 'Ищу заказы' : 'Не ищу', style: AppText.bodyStrong.copyWith(fontSize: 14, color: online ? AppColors.successInk : AppColors.text2)),
          ]),
        ),
      ),
    );
  }
}

class _Banner extends StatelessWidget {
  const _Banner({required this.icon, required this.text, this.action, this.onAction});
  final IconData icon;
  final String text;
  final String? action;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(color: AppColors.warningSoft, borderRadius: BorderRadius.circular(16)),
      child: Row(children: [
        Icon(icon, color: AppColors.warningInk),
        const SizedBox(width: 10),
        Expanded(child: Text(text, style: AppText.small.copyWith(color: AppColors.warningInk, fontSize: 14))),
        if (action != null) TextButton(onPressed: onAction, child: Text(action!)),
      ]),
    );
  }
}

class _PointRow extends StatelessWidget {
  const _PointRow(this.p, {required this.last});
  final Map<String, dynamic> p;
  final bool last;

  @override
  Widget build(BuildContext context) {
    final dist = p['distance_m'] as num?;
    return InkWell(
      onTap: () => route(context, p['lat'] as num?, p['lng'] as num?),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 12),
        decoration: BoxDecoration(border: last ? null : const Border(bottom: BorderSide(color: AppColors.line))),
        child: Row(children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(color: AppColors.primarySoft, borderRadius: BorderRadius.circular(12)),
            child: const Icon(Icons.storefront_rounded, color: AppColors.primary, size: 22),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('${p['name'] ?? ''}', style: AppText.bodyStrong),
              Text('${p['address'] ?? ''}', style: AppText.small, maxLines: 1, overflow: TextOverflow.ellipsis),
            ]),
          ),
          if (dist != null) Text(meters(dist), style: AppText.bodyStrong.copyWith(fontSize: 14)),
        ]),
      ),
    );
  }
}

/// Заказ из ленты (Figma Ц3).
class _OfferCard extends StatefulWidget {
  const _OfferCard(this.o);
  final Map<String, dynamic> o;

  @override
  State<_OfferCard> createState() => _OfferCardState();
}

class _OfferCardState extends State<_OfferCard> {
  bool _busy = false;

  Future<void> _take() async {
    setState(() => _busy = true);
    final st = context.read<CrowdState>();
    try {
      final r = await st.accept('${widget.o['order_id']}');
      if (!mounted) return;
      final id = '${(r['order'] as Map?)?['id'] ?? widget.o['order_id']}';
      await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => CrowdOrderScreen(orderId: id)));
    } catch (e) {
      if (mounted) showMessage(context, e);
      await st.refresh().catchError((_) {});
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final o = widget.o;
    final detour = o['detour_m'] as num?;
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(color: AppColors.white, borderRadius: BorderRadius.circular(20)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(money(o['reward']), style: AppText.h2),
        const SizedBox(height: 8),
        Wrap(spacing: 6, runSpacing: 6, children: [
          if (detour != null) StatusChip('+${meters(detour)}', icon: Icons.turn_right_rounded, tone: ChipTone.blue),
          StatusChip('~${o['minutes']} мин', icon: Icons.schedule_rounded),
          StatusChip('Оплачен', icon: Icons.check_circle_rounded, tone: ChipTone.green),
        ]),
        const SizedBox(height: 14),
        _Line(icon: Icons.storefront_rounded, color: AppColors.primary, title: '${o['store_name']}${o['to_store_m'] == null ? '' : ' — ${meters(o['to_store_m'] as num)} от вас'}', sub: '${o['store_address'] ?? ''}'),
        const SizedBox(height: 10),
        _Line(
          icon: Icons.home_rounded,
          color: AppColors.success,
          title: 'Покупатель — ${meters(o['to_customer_m'] as num?)} от магазина',
          sub: 'Адрес откроется после принятия',
        ),
        const SizedBox(height: 10),
        Text('${o['items_count']} ${_itemsWord((o['items_count'] as num?)?.toInt() ?? 0)} · заказ № ${o['number']}', style: AppText.small),
        const SizedBox(height: 14),
        BigButton(label: 'Взять заказ', icon: Icons.bolt_rounded, busy: _busy, onPressed: _take, height: 52),
      ]),
    );
  }

  static String _itemsWord(int n) {
    final m10 = n % 10, m100 = n % 100;
    if (m10 == 1 && m100 != 11) return 'товар';
    if (m10 >= 2 && m10 <= 4 && (m100 < 10 || m100 >= 20)) return 'товара';
    return 'товаров';
  }
}

class _Line extends StatelessWidget {
  const _Line({required this.icon, required this.color, required this.title, this.sub});
  final IconData icon;
  final Color color;
  final String title;
  final String? sub;

  @override
  Widget build(BuildContext context) {
    return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Icon(icon, color: color, size: 22),
      const SizedBox(width: 12),
      Expanded(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(title, style: AppText.bodyStrong),
          if (sub != null && sub!.isNotEmpty) Text(sub!, style: AppText.small),
        ]),
      ),
    ]);
  }
}

/// Взятый заказ: «забрать в магазине» или «везу» — открыть экран заказа.
class _ActiveCard extends StatelessWidget {
  const _ActiveCard(this.c);
  final Map<String, dynamic> c;

  @override
  Widget build(BuildContext context) {
    final o = (c['order'] as Map?)?.cast<String, dynamic>() ?? const {};
    final store = (c['store'] as Map?)?.cast<String, dynamic>() ?? const {};
    final delivering = o['status'] == 'delivering';
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Material(
        color: AppColors.white,
        borderRadius: BorderRadius.circular(20),
        child: InkWell(
          borderRadius: BorderRadius.circular(20),
          onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => CrowdOrderScreen(orderId: '${o['id']}'))),
          child: Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(borderRadius: BorderRadius.circular(20), border: Border.all(color: AppColors.primary, width: 2)),
            child: Row(children: [
              Icon(delivering ? Icons.local_shipping_rounded : Icons.storefront_rounded, color: AppColors.primary),
              const SizedBox(width: 12),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('№ ${o['number']} · ${delivering ? 'везу покупателю' : 'забрать в магазине'}', style: AppText.bodyStrong),
                  Text(delivering ? '${o['address'] ?? ''}' : '${store['name'] ?? ''}', style: AppText.small, maxLines: 1, overflow: TextOverflow.ellipsis),
                ]),
              ),
              Text(money(c['fee']), style: AppText.bodyStrong),
              const Icon(Icons.chevron_right_rounded, color: AppColors.muted),
            ]),
          ),
        ),
      ),
    );
  }
}
