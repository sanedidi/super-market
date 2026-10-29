import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:sm_core/sm_core.dart';
import 'package:sm_store/income/income_entry.dart' show openIncomeChooser;
import 'package:sm_store/kassa/kassa_screen.dart';
import 'package:sm_store/screens/store_picker.dart';
import 'package:sm_store/state.dart';
import 'package:sm_store/ui/theme.dart';
import 'package:sm_store/ui/widgets.dart';

import 'customer_return.dart';
import 'logic.dart';
import 'recount.dart';
import 'scanner.dart';
import 'tasks.dart';
import 'ui.dart';
import 'write_off.dart';

/// С3 · Главная — разделы по правам роли (продавец · кладовщик · сборщик);
/// С4 · у роли «Кассир» только продажа и цена, «Мои продажи сегодня».
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key, required this.onTab, required this.refresh});

  /// Переключить вкладку: 1 — заказы, 2 — задачи.
  final ValueChanged<int> onTab;
  final ValueNotifier<int> refresh;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  List<Map<String, dynamic>>? _waiting;
  Map<String, dynamic>? _tasks;
  Map<String, dynamic>? _day;

  @override
  void initState() {
    super.initState();
    widget.refresh.addListener(_load);
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  @override
  void dispose() {
    widget.refresh.removeListener(_load);
    super.dispose();
  }

  Future<void> _load() async {
    final st = context.read<StoreState>();
    final api = context.read<Api>();
    final store = st.storeId;
    if (store == null) return;
    Future<void> safe(Future<void> Function() f) async {
      try {
        await f();
      } catch (_) {
        // блок без данных просто не показывается
      }
    }

    await Future.wait([
      if (st.can('orders.manage'))
        safe(() async {
          final paid = await api.list('/store/orders', {'store_id': store, 'status': 'paid', 'sort': 'delivery', 'limit': 100});
          final accepted = await api.list('/store/orders', {'store_id': store, 'status': 'accepted', 'sort': 'delivery', 'limit': 100});
          if (mounted) setState(() => _waiting = [...paid, ...accepted.where((o) => o['picker_id'] == null)]);
        }),
      safe(() async {
        final t = await api.get('/store/staff/tasks', {'store_id': store}) as Map<String, dynamic>;
        if (mounted) setState(() => _tasks = t);
      }),
      if (st.can('sales.pos'))
        safe(() async {
          final d = await api.get('/store/staff/day', {'store_id': store}) as Map<String, dynamic>;
          if (mounted) setState(() => _day = d);
        }),
    ]);
  }

  Future<void> _open(Section s) async {
    final nav = Navigator.of(context);
    switch (s) {
      case Section.sell:
        await nav.push(MaterialPageRoute<void>(builder: (_) => const KassaScreen()));
      case Section.income:
        await openIncomeChooser(context);
      case Section.glance:
        await openGlanceScanner(context);
      case Section.recount:
        await nav.push(MaterialPageRoute<void>(builder: (_) => const RecountScreen()));
      case Section.writeOff:
        await openWriteOff(context);
      case Section.returns:
        await nav.push(MaterialPageRoute<void>(builder: (_) => const CustomerReturnScreen()));
    }
    widget.refresh.value++;
  }

  @override
  Widget build(BuildContext context) {
    final st = context.watch<StoreState>();
    final me = st.me ?? const {};
    final name = '${me['full_name'] ?? ''}';
    final sections = sectionsFor(st.can);
    final cashier = cashierOnly(st.can);
    final entries = _tasks == null ? const <TaskEntry>[] : taskEntries(_tasks!);
    final waiting = _waiting ?? const [];
    final now = DateTime.now();
    return SafeArea(
      child: RefreshIndicator(
        onRefresh: _load,
        child: ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 24), children: [
          // Магазин (несколько — выбрать) и приветствие.
          InkWell(
            onTap: st.stores.length > 1 ? () => pickStore(context) : null,
            child: Row(children: [
              const Icon(Icons.storefront_rounded, size: 18, color: AppColors.text2),
              const SizedBox(width: 6),
              Flexible(child: Text(tr('Магазин «${st.store?['name'] ?? ''}»', '«${st.store?['name'] ?? ''}» doʻkoni'), style: AppText.small, overflow: TextOverflow.ellipsis)),
              if (st.stores.length > 1) const Icon(Icons.expand_more_rounded, size: 20, color: AppColors.text2),
            ]),
          ),
          const SizedBox(height: 6),
          Row(children: [
            Expanded(child: Text(tr('Салом, ${firstName(name)}!', 'Salom, ${firstName(name)}!'), style: AppText.h2)),
            Avatar(name),
          ]),
          if (cashier && '${me['role_name'] ?? ''}'.isNotEmpty) ...[
            const SizedBox(height: 8),
            Align(alignment: Alignment.centerLeft, child: StatusChip('${me['role_name']}', icon: Icons.badge_rounded)),
          ],
          const SizedBox(height: 16),
          // Онлайн-заказы ждут сборки.
          if (waiting.isNotEmpty) ...[
            AppCard(
              color: AppColors.ink,
              onTap: () => widget.onTab(1),
              child: Row(children: [
                const IconBox(Icons.shopping_bag_rounded, bg: AppColors.primary, fg: AppColors.white),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(tr('${ordersWord(waiting.length)} ждут сборки', '${ordersWord(waiting.length)} yigʻishni kutmoqda'),
                        style: AppText.bodyStrong.copyWith(color: AppColors.white, fontSize: 16)),
                    Text(
                        tr('Самый старый ждёт ${waitingMinutes(waiting.first, now)} мин · ${deliveryWhen(waiting.first)}',
                            'Eng eskisi ${waitingMinutes(waiting.first, now)} daqiqa kutmoqda · ${deliveryWhen(waiting.first)}'),
                        style: AppText.small.copyWith(color: AppColors.white)),
                  ]),
                ),
                const Icon(Icons.chevron_right_rounded, color: AppColors.white),
              ]),
            ),
            const SizedBox(height: 16),
          ],
          // С4 · кассир: свои продажи за сегодня.
          if (cashier && _day != null) ...[
            AppCard(
              color: AppColors.ink,
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(tr('Мои продажи сегодня', 'Bugungi sotuvlarim'), style: AppText.small.copyWith(color: AppColors.muted)),
                const SizedBox(height: 4),
                Text(money(_day!['sales']), style: AppText.h1.copyWith(fontSize: 30, color: AppColors.white)),
                const SizedBox(height: 4),
                Text(
                    tr('${_day!['receipts'] ?? 0} чеков · средний чек ${money(_day!['average'])}',
                        '${_day!['receipts'] ?? 0} ta chek · oʻrtacha chek ${money(_day!['average'])}'),
                    style: AppText.small.copyWith(color: AppColors.muted)),
              ]),
            ),
            const SizedBox(height: 16),
          ],
          // Разделы — плитки одного размера.
          GridView.count(
            crossAxisCount: 2,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            mainAxisSpacing: 10,
            crossAxisSpacing: 10,
            childAspectRatio: 174 / 116,
            children: [for (final s in sections) _Tile(section: s, onTap: () => _open(s))],
          ),
          if (cashier) ...[
            const SizedBox(height: 12),
            InfoNote(
              tr('Остальные разделы закрыты. Приход, списание, пересчёт и сборку заказов включает владелец: Сотрудники → Роли.',
                  'Qolgan boʻlimlar yopiq. Kirim, hisobdan chiqarish, qayta sanash va buyurtma yigʻishni egasi yoqadi: Xodimlar → Rollar.'),
              icon: Icons.lock_rounded,
            ),
          ],
          // Задачи на сегодня.
          if (entries.isNotEmpty) ...[
            const SizedBox(height: 20),
            Row(children: [
              Text(tr('Задачи на сегодня', 'Bugungi vazifalar'), style: AppText.title),
              const SizedBox(width: 8),
              StatusChip('${entries.length}', tone: ChipTone.red),
              const Spacer(),
              TextButton(onPressed: () => widget.onTab(2), child: Text(tr('Все', 'Hammasi'))),
            ]),
            for (final e in entries.take(3)) ...[
              TaskTile(entry: e, onDone: () => widget.refresh.value++),
              const SizedBox(height: 8),
            ],
          ],
        ]),
      ),
    );
  }
}

class _Tile extends StatelessWidget {
  const _Tile({required this.section, required this.onTap});

  final Section section;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    // Белые плитки, иконка — в своём цвете (Figma С3).
    final (IconData icon, String title, String sub, Color bg, Color fg) = switch (section) {
      Section.sell => (Icons.point_of_sale_rounded, tr('Продать', 'Sotish'), tr('Касса в телефоне', 'Telefondagi kassa'), AppColors.primarySoft, AppColors.primary),
      Section.income => (Icons.move_to_inbox_rounded, tr('Приход', 'Kirim'), tr('Сканер или накладная', 'Skaner yoki nakladnoy'), AppColors.blueSoft, AppColors.blue),
      Section.glance => (Icons.sell_rounded, tr('Цена и остаток', 'Narx va qoldiq'), tr('Наведите камеру', 'Kamerani qarating'), AppColors.soft, AppColors.ink),
      Section.recount => (Icons.fact_check_rounded, tr('Пересчёт', 'Qayta sanash'), tr('Полка или товар', 'Javon yoki mahsulot'), AppColors.warningSoft, AppColors.warningInk),
      Section.writeOff => (Icons.delete_sweep_rounded, tr('Списание', 'Hisobdan chiqarish'), tr('Брак, просрочка', 'Nuqson, muddati oʻtgan'), AppColors.soft, AppColors.ink),
      Section.returns => (Icons.assignment_return_rounded, tr('Возврат', 'Qaytarish'), tr('Покупатель вернул', 'Xaridor qaytardi'), AppColors.soft, AppColors.ink),
    };
    return AppCard(
      onTap: onTap,
      padding: const EdgeInsets.all(14),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        IconBox(icon, bg: bg, fg: fg, size: 40, iconSize: 22, radius: 12),
        const Spacer(),
        Text(title, style: AppText.bodyStrong, maxLines: 1, overflow: TextOverflow.ellipsis),
        Text(sub, style: AppText.small.copyWith(fontSize: 12), maxLines: 1, overflow: TextOverflow.ellipsis),
      ]),
    );
  }
}
