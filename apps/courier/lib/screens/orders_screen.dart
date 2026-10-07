import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:sm_core/sm_core.dart';

import '../logic.dart';
import '../main.dart';
import '../state.dart';
import '../ui/theme.dart';
import '../ui/widgets.dart';
import 'order_screen.dart';

const vehicleIcons = {
  'foot': Icons.directions_walk_rounded,
  'bike': Icons.pedal_bike_rounded,
  'scooter': Icons.electric_scooter_rounded,
  'car': Icons.directions_car_rounded,
};

/// Главный экран: смена и заказы (Figma К2, К3, К9).
class OrdersScreen extends StatelessWidget {
  const OrdersScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final st = context.watch<CourierState>();
    final g = groupOrders(st.orders);
    final top = MediaQuery.paddingOf(context).top;
    return Scaffold(
      backgroundColor: st.onShift ? AppColors.bg : AppColors.white,
      body: RefreshIndicator(
        onRefresh: () => st.refreshOrders().catchError((Object e) {
          if (context.mounted) showMessage(context, e);
        }),
        child: ListView(
          padding: EdgeInsets.fromLTRB(20, top + 12, 20, 24),
          children: [
            Row(children: [
              Expanded(child: Text(st.onShift ? tr('Заказы', 'Buyurtmalar') : tr('Привет, ${_firstName(st)}', 'Salom, ${_firstName(st)}'), style: AppText.h1)),
              RoundIcon(
                icon: Icons.refresh_rounded,
                tooltip: tr('Обновить', 'Yangilash'),
                color: st.onShift ? AppColors.white : AppColors.soft,
                onTap: () => st.refreshOrders().catchError((Object e) {
                  if (context.mounted) showMessage(context, e);
                }),
              ),
            ]),
            const SizedBox(height: 16),
            if (!st.onShift) ...[
              const _OffShiftCard(),
              const SizedBox(height: 20),
            ] else ...[
              const _ShiftBar(),
              const SizedBox(height: 14),
            ],
            if (st.onShift && st.locationProblem != null) ...[
              const _LocationProblem(),
              const SizedBox(height: 14),
            ],
            if (g.delivering.isNotEmpty) ...[
              _SectionTitle(tr('Везу', 'Yetkazyapman'), g.delivering.length),
              for (final c in g.delivering) _OrderCard(c, fresh: st.fresh.contains(idOf(c))),
            ],
            if (g.toPick.isNotEmpty) ...[
              _SectionTitle(tr('Забрать в магазине', 'Doʻkondan olish'), g.toPick.length),
              for (final c in g.toPick) _OrderCard(c, fresh: st.fresh.contains(idOf(c))),
            ],
            if (g.delivering.isEmpty && g.toPick.isEmpty)
              st.onShift
                  ? EmptyState(
                      icon: Icons.inventory_2_rounded,
                      title: tr('Пока заказов нет', 'Hozircha buyurtma yoʻq'),
                      text: tr('Как только магазин назначит заказ, он появится здесь — телефон завибрирует',
                          'Doʻkon buyurtma biriktirishi bilan u shu yerda chiqadi — telefon tebranadi'),
                    )
                  : const _TodayHint(),
            if (g.done.isNotEmpty) ...[
              const SizedBox(height: 8),
              _SectionTitle(tr('Доставлены сегодня', 'Bugun yetkazilgan'), g.done.length),
              for (final c in g.done) _OrderCard(c, fresh: false),
            ],
          ],
        ),
      ),
    );
  }

  static String _firstName(CourierState st) => '${st.me?['full_name'] ?? ''}'.split(' ').first;
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.title, this.count);
  final String title;
  final int count;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 6, bottom: 12),
      child: Row(children: [
        Text(title, style: AppText.h3),
        const SizedBox(width: 8),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
          decoration: BoxDecoration(color: AppColors.ink, borderRadius: BorderRadius.circular(11)),
          child: Text('$count', style: AppText.small.copyWith(color: AppColors.white, fontWeight: FontWeight.w700)),
        ),
      ]),
    );
  }
}

/// «Вы не на смене»: транспорт и кнопка «Выйти на смену».
class _OffShiftCard extends StatefulWidget {
  const _OffShiftCard();

  @override
  State<_OffShiftCard> createState() => _OffShiftCardState();
}

class _OffShiftCardState extends State<_OffShiftCard> {
  bool _busy = false;

  Future<void> _run(Future<void> Function() fn) async {
    setState(() => _busy = true);
    try {
      await fn();
    } catch (e) {
      if (mounted) showMessage(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final st = context.watch<CourierState>();
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(color: AppColors.ink, borderRadius: BorderRadius.circular(24)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          Container(
            width: 44,
            height: 44,
            decoration: const BoxDecoration(color: Color(0x1FFFFFFF), shape: BoxShape.circle),
            child: const Icon(Icons.bedtime_rounded, color: AppColors.white),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(tr('Вы не на смене', 'Siz smenada emassiz'),
                  style: const TextStyle(fontFamily: 'Inter', fontSize: 20, fontWeight: FontWeight.w700, color: AppColors.white)),
              Text(tr('Магазин не назначает заказы', 'Doʻkon buyurtma biriktirmaydi'),
                  style: const TextStyle(fontFamily: 'Inter', fontSize: 14, color: Color(0xFFD1D1D6))),
            ]),
          ),
        ]),
        const SizedBox(height: 16),
        Text(tr('На чём доставляете?', 'Nimada yetkazasiz?'),
            style: const TextStyle(fontFamily: 'Inter', fontSize: 13, fontWeight: FontWeight.w500, color: Color(0xFFD1D1D6))),
        const SizedBox(height: 10),
        Row(children: [
          for (final e in vehicleTitles.entries) ...[
            if (e.key != 'foot') const SizedBox(width: 8),
            Expanded(
              child: _VehicleTile(
                icon: vehicleIcons[e.key]!,
                label: e.value,
                selected: st.vehicle == e.key,
                onTap: _busy ? null : () => _run(() => st.setShift(vehicle: e.key)),
              ),
            ),
          ],
        ]),
        const SizedBox(height: 16),
        BigButton(label: tr('Выйти на смену', 'Smenaga chiqish'), icon: Icons.play_arrow_rounded, busy: _busy, onPressed: () => _run(() => st.setShift(onShift: true))),
      ]),
    );
  }
}

class _VehicleTile extends StatelessWidget {
  const _VehicleTile({required this.icon, required this.label, required this.selected, required this.onTap});
  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final fg = selected ? AppColors.ink : AppColors.white;
    return Material(
      color: selected ? AppColors.white : Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: selected ? BorderSide.none : const BorderSide(color: Color(0xFF5A5A5E)),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 10),
          child: Column(children: [
            Icon(icon, color: fg),
            const SizedBox(height: 4),
            Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontFamily: 'Inter', fontSize: 11, fontWeight: FontWeight.w500, color: fg)),
          ]),
        ),
      ),
    );
  }
}

/// На смене: транспорт, когда ушла последняя точка, «Завершить».
class _ShiftBar extends StatefulWidget {
  const _ShiftBar();

  @override
  State<_ShiftBar> createState() => _ShiftBarState();
}

class _ShiftBarState extends State<_ShiftBar> {
  bool _busy = false;

  Future<void> _end() async {
    final st = context.read<CourierState>();
    final active = groupOrders(st.orders);
    final ok = await confirmSheet(
      context,
      title: tr('Завершить смену?', 'Smenani yakunlaysizmi?'),
      text: active.delivering.isNotEmpty || active.toPick.isNotEmpty
          ? tr('У вас есть незавершённые заказы. Магазин увидит, что вы ушли со смены.',
              'Sizda yakunlanmagan buyurtmalar bor. Doʻkon smenadan ketganingizni koʻradi.')
          : tr('Магазин перестанет назначать вам заказы.', 'Doʻkon sizga buyurtma biriktirishni toʻxtatadi.'),
      confirm: tr('Завершить смену', 'Smenani yakunlash'),
      cancel: tr('Остаться на смене', 'Smenada qolish'),
    );
    if (!ok || !mounted) return;
    setState(() => _busy = true);
    try {
      await st.setShift(onShift: false);
    } catch (e) {
      if (mounted) showMessage(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final st = context.watch<CourierState>();
    final at = st.lastLocationAt;
    final sub = st.locationProblem != null
        ? tr('Геопозиция не передаётся', 'Joylashuv uzatilmayapti')
        : at == null
            ? tr('Ищем геопозицию…', 'Joylashuv aniqlanmoqda…')
            : tr('Геопозиция передаётся · ${hm(at)}', 'Joylashuv uzatilmoqda · ${hm(at)}');
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 14, 12, 14),
      decoration: BoxDecoration(color: AppColors.white, borderRadius: BorderRadius.circular(20)),
      child: Row(children: [
        Container(
          width: 40,
          height: 40,
          decoration: const BoxDecoration(color: AppColors.successSoft, shape: BoxShape.circle),
          child: Icon(vehicleIcons[st.vehicle] ?? Icons.directions_walk_rounded, color: AppColors.successInk, size: 22),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Container(width: 8, height: 8, decoration: const BoxDecoration(color: AppColors.success, shape: BoxShape.circle)),
              const SizedBox(width: 6),
              Text(tr('На смене', 'Smenada'), style: AppText.title),
            ]),
            Text(sub, style: AppText.small, maxLines: 2),
          ]),
        ),
        const SizedBox(width: 8),
        SizedBox(
          height: 40,
          child: TextButton(
            style: TextButton.styleFrom(
              backgroundColor: AppColors.soft,
              foregroundColor: AppColors.ink,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              padding: const EdgeInsets.symmetric(horizontal: 14),
            ),
            onPressed: _busy ? null : _end,
            child: Text(tr('Завершить', 'Yakunlash'), style: AppText.bodyStrong.copyWith(fontSize: 14)),
          ),
        ),
      ]),
    );
  }
}

class _LocationProblem extends StatelessWidget {
  const _LocationProblem();

  @override
  Widget build(BuildContext context) {
    final st = context.watch<CourierState>();
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(color: AppColors.errorSoft, borderRadius: BorderRadius.circular(20)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          const Icon(Icons.location_off_rounded, color: AppColors.error),
          const SizedBox(width: 10),
          Expanded(child: Text(st.locationProblem ?? '', style: AppText.title.copyWith(color: AppColors.error, fontSize: 17))),
        ]),
        const SizedBox(height: 8),
        Text(
            tr('Покупатель не видит, где заказ, а магазин — где вы. Разрешите доступ к геопозиции «Всегда».',
                'Xaridor buyurtma qayerdaligini, doʻkon esa sizni koʻrmayapti. Joylashuvga «Har doim» ruxsatini bering.'),
            style: AppText.small.copyWith(color: AppColors.error, fontSize: 14)),
        const SizedBox(height: 12),
        BigButton(label: tr('Открыть настройки', 'Sozlamalarni ochish'), height: 44, onPressed: st.openLocationSettings),
      ]),
    );
  }
}

class _TodayHint extends StatelessWidget {
  const _TodayHint();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(color: AppColors.blueSoft, borderRadius: BorderRadius.circular(16)),
      child: Row(children: [
        const Icon(Icons.my_location_rounded, color: AppColors.blue),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
              tr('На смене приложение передаёт вашу геопозицию — покупатель видит курьера на карте',
                  'Smenada ilova joylashuvingizni uzatadi — xaridor kuryerni xaritada koʻradi'),
              style: AppText.small.copyWith(color: AppColors.blue)),
        ),
      ]),
    );
  }
}

/// Карточка заказа в списке.
class _OrderCard extends StatefulWidget {
  const _OrderCard(this.c, {required this.fresh});
  final CourierOrder c;
  final bool fresh;

  @override
  State<_OrderCard> createState() => _OrderCardState();
}

class _OrderCardState extends State<_OrderCard> {
  bool _busy = false;

  Future<void> _open() async {
    final st = context.read<CourierState>();
    st.seen(idOf(widget.c));
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => OrderScreen(id: idOf(widget.c), initial: widget.c)));
  }

  Future<void> _action(String action) async {
    if (action == 'delivered') {
      final ok = await confirmDelivered(context, widget.c);
      if (!ok || !mounted) return;
    }
    setState(() => _busy = true);
    try {
      await context.read<CourierState>().act(idOf(widget.c), action);
    } catch (e) {
      if (mounted) showMessage(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.c;
    final o = orderOf(c);
    final s = storeOf(c);
    final status = statusOf(c);
    final flat = flatDetails(o);
    final delivering = status == 'delivering';
    final done = status == 'delivered';
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Material(
        color: AppColors.white,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
          side: widget.fresh
              ? const BorderSide(color: AppColors.primary, width: 2)
              : delivering
                  ? const BorderSide(color: AppColors.blue, width: 2)
                  : BorderSide.none,
        ),
        child: InkWell(
          borderRadius: BorderRadius.circular(20),
          onTap: _open,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Text('№ ${o['number']}', style: AppText.title),
                const SizedBox(width: 8),
                Expanded(child: Text(done ? tr('в ${_hmOf(o['delivered_at'])}', 'soat ${_hmOf(o['delivered_at'])}') : whenText(o), style: AppText.small.copyWith(fontSize: 14))),
                if (widget.fresh) StatusChip(tr('Новый', 'Yangi'), tone: ChipTone.red, icon: Icons.fiber_new_rounded) else statusChip(status),
              ]),
              const SizedBox(height: 12),
              _Line(icon: Icons.storefront_rounded, text: '${s['name'] ?? o['store_name']}', sub: _storeSub(c)),
              const SizedBox(height: 10),
              _Line(icon: Icons.location_on_rounded, text: '${o['address']}', sub: [if (flat.isNotEmpty) flat, distanceText(o['distance_m'] as num?)].where((x) => x.isNotEmpty).join(' · ')),
              const SizedBox(height: 12),
              Row(children: [
                Flexible(child: paymentChip(c)),
                const SizedBox(width: 8),
                Text(itemsText((c['items_count'] as num?)?.toInt() ?? 0), style: AppText.small),
              ]),
              if (status == 'picked' || delivering) ...[
                const SizedBox(height: 12),
                BigButton(
                  label: delivering ? tr('Доставил', 'Yetkazdim') : tr('Забрал заказ', 'Buyurtmani oldim'),
                  icon: delivering ? Icons.check_circle_rounded : Icons.shopping_bag_rounded,
                  color: delivering ? AppColors.success : AppColors.primary,
                  height: 48,
                  busy: _busy,
                  onPressed: () => _action(delivering ? 'delivered' : 'picked-up'),
                ),
              ],
            ]),
          ),
        ),
      ),
    );
  }

  static String _hmOf(Object? v) {
    final t = v == null ? null : DateTime.tryParse('$v')?.toLocal();
    return t == null ? '' : hm(t);
  }

  static String _storeSub(CourierOrder c) {
    final status = statusOf(c);
    final picked = c['picked_up_at'] == null ? null : DateTime.tryParse('${c['picked_up_at']}')?.toLocal();
    if (picked != null) return tr('забран в ${hm(picked)}', 'soat ${hm(picked)} da olindi');
    if (status == 'accepted' || status == 'picking') return tr('заказ ещё собирают', 'buyurtma hali yigʻilmoqda');
    return '${storeOf(c)['address'] ?? ''}';
  }
}

class _Line extends StatelessWidget {
  const _Line({required this.icon, required this.text, this.sub = ''});
  final IconData icon;
  final String text;
  final String sub;

  @override
  Widget build(BuildContext context) {
    return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Icon(icon, size: 20, color: AppColors.text2),
      const SizedBox(width: 10),
      Expanded(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(text, style: AppText.bodyStrong.copyWith(fontWeight: FontWeight.w500)),
          if (sub.isNotEmpty) Text(sub, style: AppText.small),
        ]),
      ),
    ]);
  }
}

/// Плашка статуса заказа.
Widget statusChip(String status) => switch (status) {
      'delivering' => StatusChip(tr('В пути', 'Yoʻlda'), tone: ChipTone.blue, icon: Icons.delivery_dining_rounded),
      'picked' => StatusChip(tr('Собран', 'Yigʻildi'), tone: ChipTone.green, icon: Icons.inventory_2_rounded),
      'delivered' => StatusChip(tr('Доставлен', 'Yetkazildi'), tone: ChipTone.green, icon: Icons.check_rounded),
      'cancelled' => StatusChip(tr('Отменён', 'Bekor qilindi'), tone: ChipTone.red, icon: Icons.block_rounded),
      _ => StatusChip(statusTitle(status), tone: ChipTone.amber, icon: Icons.hourglass_top_rounded),
    };

/// «Наличными 125 000 сум» или «Оплачен».
Widget paymentChip(CourierOrder c) => c['cash'] == true
    ? StatusChip(tr('Наличными ${money(orderOf(c)['total'])}', 'Naqd ${money(orderOf(c)['total'])}'), tone: ChipTone.amber, icon: Icons.payments_rounded)
    : StatusChip(tr('Оплачен', 'Toʻlandi'), tone: ChipTone.green, icon: Icons.check_rounded);
