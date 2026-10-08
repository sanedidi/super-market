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
      StatusChip(blocked ? tr('Заблокирован', 'Bloklangan') : tr('Не верифицирован', 'Tasdiqlanmagan'), icon: blocked ? Icons.block_rounded : Icons.hourglass_top_rounded, tone: ChipTone.amber),
      const SizedBox(height: 8),
      Text(tr('Привет!', 'Salom!'), style: AppText.h1),
      const SizedBox(height: 16),
      Container(
        padding: const EdgeInsets.all(22),
        decoration: BoxDecoration(color: AppColors.white, borderRadius: BorderRadius.circular(24)),
        child: Column(children: [
          Text(tr('Покажите этот код продавцу', 'Bu kodni sotuvchiga koʻrsating'), style: AppText.title, textAlign: TextAlign.center),
          const SizedBox(height: 8),
          Text(
              tr('В любом магазине Super Market из списка ниже. Возьмите паспорт или ID-карту — продавец сверит документ, копию мы не храним.',
                  'Quyidagi roʻyxatdagi istalgan Super Market doʻkonida. Pasport yoki ID-kartani oling — sotuvchi hujjatni tekshiradi, nusxasini saqlamaymiz.'),
              style: AppText.small.copyWith(fontSize: 14), textAlign: TextAlign.center),
          const SizedBox(height: 16),
          QrImageView(data: courierQr(code), size: 200, backgroundColor: AppColors.white),
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            decoration: BoxDecoration(color: AppColors.soft, borderRadius: BorderRadius.circular(12)),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Text(tr('Код курьера', 'Kuryer kodi'), style: AppText.small.copyWith(fontWeight: FontWeight.w500)),
              const SizedBox(width: 8),
              Text(code, style: AppText.bodyStrong),
            ]),
          ),
        ]),
      ),
      const SizedBox(height: 20),
      Row(children: [
        Expanded(child: Text(tr('Ближайшие точки проверки', 'Eng yaqin tekshiruv joylari'), style: AppText.title)),
        if (st.lastPosition == null)
          TextButton.icon(
            onPressed: () => st.locateOnce().catchError((Object e) {
              if (context.mounted) showMessage(context, e);
            }),
            icon: const Icon(Icons.my_location_rounded, size: 18),
            label: Text(tr('Рядом со мной', 'Yaqinimda')),
          ),
      ]),
      const SizedBox(height: 10),
      if (st.points.isEmpty)
        EmptyState(
          icon: Icons.storefront_rounded,
          title: tr('Пока нет магазинов', 'Hozircha doʻkonlar yoʻq'),
          text: tr('Скоро магазины Super Market начнут проверять курьеров', 'Tez orada Super Market doʻkonlari kuryerlarni tekshirishni boshlaydi'),
        )
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
        Expanded(child: Text(tr('По пути', 'Yoʻlakay'), style: AppText.h1)),
        _OnlineChip(online: st.online, onChanged: (v) => st.setOnline(v).catchError((Object e) {
              if (context.mounted) showMessage(context, e);
            })),
      ]),
      const SizedBox(height: 14),
      if (st.locationProblem != null && st.online) ...[
        _Banner(
          icon: Icons.location_off_rounded,
          text: tr('${st.locationProblem}. Без геопозиции лента не подберёт заказы рядом.',
              '${st.locationProblem}. Joylashuvsiz lenta yaqindagi buyurtmalarni topa olmaydi.'),
          action: tr('Настройки', 'Sozlamalar'),
          onAction: st.openLocationSettings,
        ),
        const SizedBox(height: 12),
      ],
      if (st.activeOrders.isNotEmpty) ...[
        Text(tr('Мои заказы', 'Mening buyurtmalarim'), style: AppText.title),
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
                  Text(
                      dest == null
                          ? tr('Просто рядом', 'Shunchaki yaqinda')
                          : tr('Иду: ${placeTitle(dest['title'])}', 'Yoʻnalish: ${placeTitle(dest['title'])}'),
                      style: AppText.bodyStrong),
                  Text(
                      dest == null
                          ? tr('Заказы рядом с вами', 'Yaqiningizdagi buyurtmalar')
                          : tr('Показываем заказы с небольшим крюком', 'Yoʻl ustidagi va biroz chetdagi buyurtmalar'),
                      style: AppText.small),
                ]),
              ),
              Text(tr('Изменить', 'Oʻzgartirish'), style: AppText.bodyStrong.copyWith(color: AppColors.primary, fontSize: 14)),
            ]),
          ),
        ),
      ),
      const SizedBox(height: 18),
      Row(children: [
        Expanded(
            child: Text(
                st.offers.isEmpty
                    ? tr('Заказы по пути', 'Yoʻlakay buyurtmalar')
                    : tr('${st.offers.length} ${_ordersWord(st.offers.length)} по пути', '${st.offers.length} ta yoʻlakay buyurtma'),
                style: AppText.title)),
        Text(tr('${level['title'] ?? ''} · до ${money(level['limit'])}', '${level['title'] ?? ''} · ${money(level['limit'])} gacha'), style: AppText.small.copyWith(fontWeight: FontWeight.w500)),
      ]),
      const SizedBox(height: 10),
      if (state == 'offline')
        EmptyState(
          icon: Icons.pause_circle_rounded,
          title: tr('Вы не ищете заказы', 'Siz buyurtma qidirmayapsiz'),
          text: tr('Включите «Ищу заказы» — покажем собранные заказы рядом и по пути',
              '«Buyurtma qidiryapman»ni yoqing — yaqindagi va yoʻlingizdagi yigʻilgan buyurtmalarni koʻrsatamiz'),
          action: tr('Искать заказы', 'Buyurtma qidirish'),
          onAction: () => st.setOnline(true).catchError((Object e) {
            if (context.mounted) showMessage(context, e);
          }),
        )
      else if (state == 'busy')
        EmptyState(
          icon: Icons.local_shipping_rounded,
          title: tr('Сначала доставьте текущий заказ', 'Avval joriy buyurtmani yetkazing'),
          text: tr('На вашем уровне можно везти ограниченное число заказов сразу',
              'Darajangizda bir vaqtda cheklangan miqdordagi buyurtmani olib borish mumkin'),
        )
      else if (state == 'no_location')
        EmptyState(
          icon: Icons.my_location_rounded,
          title: tr('Определяем, где вы', 'Joylashuvingiz aniqlanmoqda'),
          text: tr('Разрешите доступ к геопозиции — без неё лента не подберёт заказы',
              'Joylashuvga ruxsat bering — usiz lenta buyurtmalarni topa olmaydi'),
          action: tr('Повторить', 'Qayta urinish'),
          onAction: st.retryLocation,
        )
      else if (st.offers.isEmpty)
        EmptyState(
          icon: Icons.near_me_rounded,
          title: tr('Пока нет заказов по пути', 'Hozircha yoʻlakay buyurtmalar yoʻq'),
          text: tr('Как только магазин рядом соберёт заказ, он появится здесь — телефон завибрирует',
              'Yaqindagi doʻkon buyurtmani yigʻishi bilan u shu yerda chiqadi — telefon tebranadi'),
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

/// Название сохранённой точки на текущем языке: «Дом»/«Uy», «Работа»/«Ish»
/// (точка могла сохраниться при другом языке). Остальное — как есть.
String placeTitle(Object? title) => switch ('${title ?? ''}') {
      'Дом' || 'Uy' => tr('Дом', 'Uy'),
      'Работа' || 'Ish' => tr('Работа', 'Ish'),
      final t => t,
    };

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
        title: Text(p == null ? title : tr('Иду: $title', 'Yoʻnalish: $title'), style: AppText.bodyStrong),
        subtitle: Text(
            p == null
                ? tr('Нажмите, когда будете там — запомним это место', 'U yerda boʻlganingizda bosing — joyni eslab qolamiz')
                : tr('Заказы с небольшим крюком по дороге', 'Yoʻl ustidagi va biroz chetdagi buyurtmalar'),
            style: AppText.small),
        trailing: p == null ? const Icon(Icons.add_location_alt_rounded, color: AppColors.primary) : null,
        onTap: () => _run(() async {
          final target = p ?? await st.saveHere(key, title);
          if (target == null) {
            throw ApiError(0, 'location', tr('Не удалось определить место — включите геопозицию', 'Joyni aniqlab boʻlmadi — joylashuvni yoqing'));
          }
          await st.setDest(target);
        }),
      );
    }

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 0, 8, 12),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Padding(padding: const EdgeInsets.fromLTRB(16, 0, 16, 8), child: Text(tr('Куда идёте?', 'Qayerga ketyapsiz?'), style: AppText.h3)),
          ListTile(
            enabled: !_busy,
            leading: const Icon(Icons.near_me_rounded, color: AppColors.ink),
            title: Text(tr('Просто рядом', 'Shunchaki yaqinda'), style: AppText.bodyStrong),
            subtitle: Text(tr('Заказы в радиусе пары километров', 'Bir-ikki kilometr radiusdagi buyurtmalar'), style: AppText.small),
            onTap: () => _run(() => st.setDest(null)),
          ),
          place('home', tr('Дом', 'Uy'), Icons.home_rounded),
          place('work', tr('Работа', 'Ish'), Icons.work_rounded),
          if (st.places.isNotEmpty)
            TextButton(
              onPressed: _busy
                  ? null
                  : () => _run(() async {
                        for (final k in st.places.keys.toList()) {
                          await st.saveHere(k, placeTitle(st.places[k]!.title));
                        }
                      }),
              child: Text(tr('Обновить сохранённое место на текущее', 'Saqlangan joyni hozirgisiga yangilash')),
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
            Text(online ? tr('Ищу заказы', 'Buyurtma qidiryapman') : tr('Не ищу', 'Qidirmayapman'), style: AppText.bodyStrong.copyWith(fontSize: 14, color: online ? AppColors.successInk : AppColors.text2)),
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
          StatusChip(tr('~${o['minutes']} мин', '~${o['minutes']} daq.'), icon: Icons.schedule_rounded),
          StatusChip(tr('Оплачен', 'Toʻlandi'), icon: Icons.check_circle_rounded, tone: ChipTone.green),
        ]),
        const SizedBox(height: 14),
        _Line(icon: Icons.storefront_rounded, color: AppColors.primary, title: '${o['store_name']}${o['to_store_m'] == null ? '' : tr(' — ${meters(o['to_store_m'] as num)} от вас', ' — sizdan ${meters(o['to_store_m'] as num)}')}', sub: '${o['store_address'] ?? ''}'),
        const SizedBox(height: 10),
        _Line(
          icon: Icons.home_rounded,
          color: AppColors.success,
          title: tr('Покупатель — ${meters(o['to_customer_m'] as num?)} от магазина', 'Xaridor — doʻkondan ${meters(o['to_customer_m'] as num?)}'),
          sub: tr('Адрес откроется после принятия', 'Manzil qabul qilingandan keyin ochiladi'),
        ),
        const SizedBox(height: 10),
        Text(
            tr('${o['items_count']} ${_itemsWord((o['items_count'] as num?)?.toInt() ?? 0)} · заказ № ${o['number']}',
                '${o['items_count']} ta mahsulot · buyurtma № ${o['number']}'),
            style: AppText.small),
        const SizedBox(height: 14),
        BigButton(label: tr('Взять заказ', 'Buyurtmani olish'), icon: Icons.bolt_rounded, busy: _busy, onPressed: _take, height: 52),
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
                  Text(
                      delivering
                          ? tr('№ ${o['number']} · везу покупателю', '№ ${o['number']} · xaridorga yetkazyapman')
                          : tr('№ ${o['number']} · забрать в магазине', '№ ${o['number']} · doʻkondan olish'),
                      style: AppText.bodyStrong),
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
