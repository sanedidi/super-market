// Агент добавляет магазин (Figma «SM Агент · Добавить магазин», АМ1–АМ6):
// магазина нет в Super Market → агент вносит название, владельца, телефон и
// точку на карте → магазин закреплён за ним 30 дней → супер-админ подключает →
// с первого оплаченного счёта подписки магазина агенту 50% на баланс.
// Сумму до оплаты не показываем: она зависит от тарифа, который выберет магазин.
import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';
import 'package:provider/provider.dart';
import 'package:sm_core/sm_core.dart';
import 'package:sm_store/finance/balance_screen.dart';
import 'package:sm_store/main.dart' show showMessage;
import 'package:sm_store/setup/setup_map.dart';
import 'package:sm_store/ui/theme.dart';
import 'package:sm_store/ui/widgets.dart';

import 'logic.dart';
import 'ui.dart';

ChipTone leadTone(LeadStatus s) => switch (s) {
      LeadStatus.pending => ChipTone.gray,
      LeadStatus.connected => ChipTone.amber,
      LeadStatus.paid => ChipTone.green,
      LeadStatus.rejected => ChipTone.red,
      LeadStatus.expired => ChipTone.gray,
    };

IconData leadIcon(LeadStatus s) => switch (s) {
      LeadStatus.pending => Icons.hourglass_top_rounded,
      LeadStatus.rejected => Icons.block_rounded,
      LeadStatus.expired => Icons.event_busy_rounded,
      _ => Icons.storefront_rounded,
    };

// ------------------------------------------------------------- АМ1

/// АМ1 · Баннер на «Магазинах»: магазина нет в Super Market — добавить.
class AddStoreBanner extends StatefulWidget {
  const AddStoreBanner({super.key});

  @override
  State<AddStoreBanner> createState() => _AddStoreBannerState();
}

class _AddStoreBannerState extends State<AddStoreBanner> {
  int? _mine;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final r = await context.read<Api>().get('/store/supply/leads', {'limit': 1}) as Map<String, dynamic>;
      if (mounted) setState(() => _mine = leadFilterCount(r['counts'] as Map<String, dynamic>?, ''));
    } catch (_) {
      // Баннер работает и без счётчика.
    }
  }

  Future<void> _open(Widget w) async {
    await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => w));
    if (mounted) _load();
  }

  @override
  Widget build(BuildContext context) {
    final mine = _mine ?? 0;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(color: AppColors.primary, borderRadius: BorderRadius.circular(20)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          const IconBox(Icons.add_business_rounded, bg: AppColors.white, fg: AppColors.primary, size: 40, iconSize: 22, radius: 12),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(tr('Магазина нет в Super Market?', 'Doʻkon Super Market’da yoʻqmi?'), style: AppText.bodyStrong.copyWith(color: AppColors.white)),
              Text(tr('Добавьте — и получите 50% от его первой оплаты', 'Qoʻshing — birinchi toʻlovining 50% sizniki'),
                  style: AppText.small.copyWith(color: const Color(0xFFFFE4E6))),
            ]),
          ),
        ]),
        const SizedBox(height: 12),
        Row(children: [
          Expanded(
            child: Material(
              color: AppColors.white,
              borderRadius: BorderRadius.circular(12),
              child: InkWell(
                borderRadius: BorderRadius.circular(12),
                onTap: () => _open(const LeadFormScreen()),
                child: SizedBox(
                  height: 40,
                  child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                    const Icon(Icons.add_rounded, color: AppColors.primary, size: 20),
                    const SizedBox(width: 6),
                    Text(tr('Добавить магазин', 'Doʻkon qoʻshish'), style: AppText.bodyStrong.copyWith(color: AppColors.primary, fontSize: 14)),
                  ]),
                ),
              ),
            ),
          ),
          if (mine > 0) ...[
            const SizedBox(width: 8),
            Material(
              color: AppColors.white.withValues(alpha: 0.18),
              borderRadius: BorderRadius.circular(12),
              child: InkWell(
                borderRadius: BorderRadius.circular(12),
                onTap: () => _open(const LeadsScreen()),
                child: SizedBox(
                  height: 40,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    child: Row(children: [
                      Text(tr('Мои · $mine', 'Meniki · $mine'), style: AppText.bodyStrong.copyWith(color: AppColors.white, fontSize: 14)),
                      const Icon(Icons.chevron_right_rounded, color: AppColors.white, size: 18),
                    ]),
                  ),
                ),
              ),
            ),
          ],
        ]),
      ]),
    );
  }
}

// ------------------------------------------------------------- АМ2, АМ3

/// АМ2 · Новый магазин: название, владелец, телефон, точка на карте.
class LeadFormScreen extends StatefulWidget {
  const LeadFormScreen({super.key});

  @override
  State<LeadFormScreen> createState() => _LeadFormScreenState();
}

class _LeadFormScreenState extends State<LeadFormScreen> {
  final _name = TextEditingController();
  final _owner = TextEditingController();
  final _phone = TextEditingController();
  String _address = '';
  LatLng? _point;
  String? _phoneError;
  bool _busy = false;

  @override
  void dispose() {
    _name.dispose();
    _owner.dispose();
    _phone.dispose();
    super.dispose();
  }

  Future<void> _pick() async {
    FocusScope.of(context).unfocus();
    final r = await Navigator.of(context).push<PickedPoint>(MaterialPageRoute(builder: (_) => MapPickerScreen(initial: _point, address: _address)));
    if (r == null || !mounted) return;
    setState(() {
      _point = r.point;
      _address = r.address ?? _address;
    });
  }

  Future<void> _here() async {
    FocusScope.of(context).unfocus();
    final p = await currentPoint();
    if (!mounted) return;
    if (p == null) {
      showMessage(context, tr('Не удалось определить геопозицию', 'Geojoylashuvni aniqlab boʻlmadi'));
      return;
    }
    setState(() => _point = p);
    final a = await addressAt(p);
    if (mounted && a != null) setState(() => _address = a);
  }

  Future<void> _send() async {
    FocusScope.of(context).unfocus();
    final phone = normalizeUzPhone(_phone.text);
    if (_name.text.trim().isEmpty || _owner.text.trim().isEmpty) {
      showMessage(context, tr('Укажите название магазина и имя владельца', 'Doʻkon nomi va egasining ismini kiriting'));
      return;
    }
    if (phone == null) {
      setState(() => _phoneError = tr('Номер в формате 90 123 45 67', 'Raqam 90 123 45 67 formatida'));
      return;
    }
    if (_point == null) {
      showMessage(context, tr('Поставьте магазин на карте', 'Doʻkonni xaritada belgilang'));
      return;
    }
    setState(() {
      _busy = true;
      _phoneError = null;
    });
    final api = context.read<Api>();
    try {
      final lead = await api.post('/store/supply/leads', {
        'name': _name.text.trim(),
        'owner_name': _owner.text.trim(),
        'owner_phone': phone,
        'address': _address,
        'lat': _point!.latitude,
        'lng': _point!.longitude,
      }) as Map<String, dynamic>;
      if (!mounted) return;
      await Navigator.of(context).pushReplacement(MaterialPageRoute<void>(builder: (_) => LeadSentScreen(lead: lead)));
    } on ApiError catch (e) {
      if (!mounted) return;
      if (e.code == 'store_exists') {
        if (e.details['reason'] == 'phone') setState(() => _phoneError = tr('Этот номер уже есть в Super Market', 'Bu raqam Super Market’da bor'));
        await _duplicate(e.details);
      } else {
        showMessage(context, e);
      }
    } catch (e) {
      if (mounted) showMessage(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// АМ3 · Магазин уже в Super Market или закреплён за агентом.
  Future<void> _duplicate(Map<String, dynamic> d) {
    final lead = d['kind'] == 'lead';
    final mine = d['mine'] == true;
    final nearby = d['reason'] == 'nearby';
    final dist = (d['distance_m'] as num?)?.toInt();
    final text = nearby
        ? tr('Рядом с этой точкой (${dist ?? 0} м) уже есть магазин. Добавить его второй раз нельзя.',
            'Bu nuqta yonida (${dist ?? 0} m) doʻkon bor. Uni ikkinchi marta qoʻshib boʻlmaydi.')
        : tr('Магазин с таким номером владельца уже есть. Добавить его второй раз нельзя.',
            'Bunday egasi raqamli doʻkon allaqachon bor. Uni ikkinchi marta qoʻshib boʻlmaydi.');
    final (String pill, ChipTone tone) = !lead
        ? (tr('Уже подключён к Super Market', 'Super Market’ga allaqachon ulangan'), ChipTone.gray)
        : mine
            ? (tr('Уже закреплён за вами до ${dayMonth(d['until'])}', '${dayMonth(d['until'])} gacha sizga biriktirilgan'), ChipTone.green)
            : (tr('Закреплён за другим агентом', 'Boshqa agentga biriktirilgan'), ChipTone.amber);
    return showSheet<void>(
      context,
      (ctx) => Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        SheetHeader(icon: Icons.storefront_rounded, title: tr('Этот магазин уже в Super Market', 'Bu doʻkon allaqachon Super Market’da'), text: text),
        const SizedBox(height: 14),
        AppCard(
          color: AppColors.bg,
          padding: const EdgeInsets.all(12),
          child: Row(children: [
            const IconBox(Icons.storefront_rounded, bg: AppColors.white, fg: AppColors.text2, size: 40, iconSize: 20, radius: 12),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('${d['name'] ?? ''}', style: AppText.bodyStrong),
                if (nearby) Text(tr('${dist ?? 0} м от точки', 'nuqtadan ${dist ?? 0} m'), style: AppText.small),
              ]),
            ),
          ]),
        ),
        const SizedBox(height: 12),
        StatusChip(pill, tone: tone),
        if (lead && !mine) ...[
          const SizedBox(height: 10),
          Text(tr('Если другой агент не подключит его за 30 дней — магазин снова можно будет добавить.',
              'Agar boshqa agent uni 30 kun ichida ulamasa — doʻkonni yana qoʻshish mumkin boʻladi.'), style: AppText.small),
        ],
        const SizedBox(height: 16),
        SheetButton(label: tr('Понятно', 'Tushunarli'), primary: false, onPressed: () => Navigator.pop(ctx)),
      ]),
    );
  }

  @override
  Widget build(BuildContext context) {
    final p = _point;
    return Scaffold(
      backgroundColor: AppColors.white,
      appBar: AppBar(backgroundColor: AppColors.white, title: Text(tr('Новый магазин', 'Yangi doʻkon'), style: AppText.title)),
      body: ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 24), children: [
        TextField(
          controller: _name,
          textCapitalization: TextCapitalization.sentences,
          textInputAction: TextInputAction.next,
          decoration: InputDecoration(labelText: tr('Название магазина *', 'Doʻkon nomi *')),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _owner,
          textCapitalization: TextCapitalization.words,
          textInputAction: TextInputAction.next,
          decoration: InputDecoration(labelText: tr('Имя владельца *', 'Egasining ismi *')),
        ),
        const SizedBox(height: 12),
        PhoneField(
          controller: _phone,
          label: tr('Телефон владельца *', 'Egasining telefoni *'),
          errorText: _phoneError,
          onChanged: (_) {
            if (_phoneError != null) setState(() => _phoneError = null);
          },
        ),
        if (_phoneError == null)
          Padding(
            padding: const EdgeInsets.only(top: 6, left: 4),
            child: Text(tr('На этот номер супер-админ позвонит и выдаст логин', 'Super-admin shu raqamga qoʻngʻiroq qilib, login beradi'), style: AppText.small),
          ),
        const SizedBox(height: 16),
        Text(tr('Точка на карте *', 'Xaritadagi nuqta *'), style: AppText.small.copyWith(fontWeight: FontWeight.w500)),
        const SizedBox(height: 6),
        GestureDetector(
          onTap: _pick,
          child: p == null
              ? Container(
                  height: 150,
                  decoration: BoxDecoration(color: AppColors.soft, borderRadius: BorderRadius.circular(16)),
                  child: Center(
                    child: Column(mainAxisSize: MainAxisSize.min, children: [
                      const Icon(Icons.place_rounded, color: AppColors.primary, size: 32),
                      Text(tr('Отметить на карте', 'Xaritada belgilash'), style: AppText.bodyStrong.copyWith(color: AppColors.primary)),
                    ]),
                  ),
                )
              : MapPreview(
                  point: p,
                  height: 180,
                  overlay: Container(
                    constraints: const BoxConstraints(maxWidth: 300),
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                    decoration: BoxDecoration(color: AppColors.white, borderRadius: BorderRadius.circular(999)),
                    child: Text(_address.isEmpty ? tr('изменить точку', 'nuqtani oʻzgartirish') : _address,
                        maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.caption.copyWith(color: AppColors.ink)),
                  ),
                ),
        ),
        TextButton.icon(
          onPressed: _here,
          style: TextButton.styleFrom(foregroundColor: AppColors.primary, padding: EdgeInsets.zero, alignment: Alignment.centerLeft),
          icon: const Icon(Icons.my_location_rounded, size: 18),
          label: Text(tr('Поставить по моей геопозиции', 'Mening joylashuvim boʻyicha')),
        ),
        const SizedBox(height: 8),
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(color: AppColors.primarySoft, borderRadius: BorderRadius.circular(14)),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Icon(Icons.handshake_rounded, color: AppColors.primary, size: 20),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                tr('Магазин закрепится за вами на 30 дней. Когда его подключат и он оплатит первый счёт — вам 50% от этой оплаты.',
                    'Doʻkon sizga 30 kunga biriktiriladi. U ulanib, birinchi hisobni toʻlaganda — shu toʻlovning 50% sizga.'),
                style: AppText.small.copyWith(color: AppColors.primary),
              ),
            ),
          ]),
        ),
      ]),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
          child: BigButton(label: tr('Отправить заявку', 'Arizani yuborish'), icon: Icons.send_rounded, busy: _busy, onPressed: _send),
        ),
      ),
    );
  }
}

// ------------------------------------------------------------- АМ4

/// АМ4 · Заявка отправлена: что будет дальше.
class LeadSentScreen extends StatelessWidget {
  const LeadSentScreen({super.key, required this.lead});

  final Map<String, dynamic> lead;

  @override
  Widget build(BuildContext context) {
    Widget step(String n, String title, String sub, {bool accent = false}) => Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Container(
            width: 28,
            height: 28,
            alignment: Alignment.center,
            decoration: BoxDecoration(color: accent ? AppColors.primary : AppColors.white, shape: BoxShape.circle),
            child: Text(n, style: AppText.bodyStrong.copyWith(fontSize: 14, color: accent ? AppColors.white : AppColors.ink)),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title, style: AppText.bodyStrong.copyWith(color: accent ? AppColors.primary : AppColors.ink)),
              Text(sub, style: AppText.small),
            ]),
          ),
        ]);
    return Scaffold(
      backgroundColor: AppColors.white,
      body: SafeArea(
        child: ListView(padding: const EdgeInsets.fromLTRB(16, 60, 16, 24), children: [
          Center(
            child: Container(
              width: 80,
              height: 80,
              decoration: const BoxDecoration(color: AppColors.successSoft, shape: BoxShape.circle),
              child: const Icon(Icons.check_circle_rounded, color: AppColors.successInk, size: 44),
            ),
          ),
          const SizedBox(height: 16),
          Text(tr('Заявка отправлена', 'Ariza yuborildi'), style: AppText.h2, textAlign: TextAlign.center),
          const SizedBox(height: 8),
          Text(
            tr('${lead['name']} закреплён за вами до ${dayMonth(lead['expires_at'])}. Супер-админ позвонит владельцу и подключит магазин.',
                '${lead['name']} ${dayMonth(lead['expires_at'])} gacha sizga biriktirildi. Super-admin egasiga qoʻngʻiroq qilib, doʻkonni ulaydi.'),
            style: AppText.body.copyWith(color: AppColors.text2),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 20),
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(color: AppColors.bg, borderRadius: BorderRadius.circular(20)),
            child: Column(children: [
              step('1', tr('Супер-админ подключает магазин', 'Super-admin doʻkonni ulaydi'), tr('Владельцу выдают логин и пароль', 'Egasiga login va parol beriladi')),
              const SizedBox(height: 14),
              step('2', tr('Магазин оплачивает первый счёт', 'Doʻkon birinchi hisobni toʻlaydi'),
                  tr('По тарифу, который выберет магазин', 'Doʻkon tanlagan tarif boʻyicha')),
              const SizedBox(height: 14),
              step('3', tr('Вам 50% от первой оплаты', 'Birinchi toʻlovning 50% sizga'), tr('Сразу на баланс Super Market', 'Darhol Super Market balansiga'), accent: true),
            ]),
          ),
        ]),
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            BigButton(label: tr('Готово', 'Tayyor'), onPressed: () => Navigator.of(context).pop()),
            TextButton(
              onPressed: () => Navigator.of(context).pushReplacement(MaterialPageRoute<void>(builder: (_) => const LeadFormScreen())),
              child: Text(tr('Добавить ещё магазин', 'Yana doʻkon qoʻshish'), style: AppText.bodyStrong.copyWith(color: AppColors.primary)),
            ),
          ]),
        ),
      ),
    );
  }
}

// ------------------------------------------------------------- АМ5

/// АМ5 · Добавленные мной: статусы заявок и сколько заработано.
class LeadsScreen extends StatefulWidget {
  const LeadsScreen({super.key});

  @override
  State<LeadsScreen> createState() => _LeadsScreenState();
}

class _LeadsScreenState extends State<LeadsScreen> {
  String _filter = '';
  Map<String, dynamic>? _data;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final r = await context.read<Api>().get('/store/supply/leads', {'status': _filter, 'limit': 200}) as Map<String, dynamic>;
      if (mounted) {
        setState(() {
          _data = r;
          _error = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  Future<void> _open(Widget w) async {
    await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => w));
    if (mounted) _load();
  }

  @override
  Widget build(BuildContext context) {
    final d = _data;
    final counts = d?['counts'] as Map<String, dynamic>?;
    final items = (d?['items'] as List?)?.cast<Map<String, dynamic>>();
    final waiting = leadFilterCount(counts, 'connected');
    return Scaffold(
      appBar: AppBar(title: Text(tr('Добавленные мной', 'Men qoʻshganlar'))),
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 24), children: [
          AppCard(
            child: Column(children: [
              Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Expanded(
                  child: _Stat(
                    label: tr('Заработано', 'Ishlab topildi'),
                    value: money(d?['earned'] ?? '0', suffix: false),
                    unit: tr('сум', 'soʻm'),
                    note: tr('${leadFilterCount(counts, 'paid')} оплатили', '${leadFilterCount(counts, 'paid')} ta toʻladi'),
                    color: AppColors.successInk,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _Stat(
                    label: tr('Ждём оплату', 'Toʻlov kutilmoqda'),
                    value: '$waiting',
                    unit: tr('маг.', 'ta'),
                    note: tr('подключены, ещё не платили', 'ulangan, hali toʻlamagan'),
                    color: AppColors.warningInk,
                  ),
                ),
              ]),
              const Divider(height: 20),
              InkWell(
                onTap: () => _open(const BalanceScreen()),
                child: Row(children: [
                  const Icon(Icons.account_balance_wallet_rounded, color: AppColors.primary, size: 18),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(tr('Начисления — на баланс: гасят подписку, остаток можно вывести', 'Hisoblanganlar balansga: obunani yopadi, qolganini yechib olish mumkin'),
                        style: AppText.small.copyWith(color: AppColors.ink, fontWeight: FontWeight.w500)),
                  ),
                  const Icon(Icons.chevron_right_rounded, color: AppColors.muted, size: 18),
                ]),
              ),
            ]),
          ),
          const SizedBox(height: 12),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(children: [
              for (final f in leadFilters) ...[
                ChipButton(
                  label: '${leadFilterLabel(f)} · ${leadFilterCount(counts, f)}',
                  color: _filter == f ? AppColors.ink : AppColors.white,
                  foreground: _filter == f ? AppColors.white : AppColors.ink,
                  onPressed: () {
                    setState(() {
                      _filter = f;
                      _data = null;
                    });
                    _load();
                  },
                ),
                const SizedBox(width: 6),
              ],
            ]),
          ),
          const SizedBox(height: 12),
          if (_error != null && items == null)
            LoadError(_error!, onRetry: _load)
          else if (items == null)
            const Padding(padding: EdgeInsets.only(top: 40), child: Center(child: CircularProgressIndicator()))
          else if (items.isEmpty)
            EmptyState(
              icon: Icons.add_business_outlined,
              title: _filter.isEmpty ? tr('Вы ещё не добавили магазины', 'Siz hali doʻkon qoʻshmagansiz') : tr('Здесь пусто', 'Bu yer boʻsh'),
              text: _filter.isEmpty
                  ? tr('Нашли магазин, которого нет в Super Market? Добавьте его — и получите 50% от его первой оплаты.',
                      'Super Market’da yoʻq doʻkon topdingizmi? Uni qoʻshing — birinchi toʻlovining 50% sizniki.')
                  : null,
            )
          else
            AppCard(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
              child: Column(children: [
                for (var i = 0; i < items.length; i++) ...[
                  if (i > 0) const Divider(height: 1),
                  _LeadRow(l: items[i], onTap: () => _open(LeadScreen(id: '${items[i]['id']}'))),
                ],
              ]),
            ),
        ]),
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
          child: BigButton(label: tr('Добавить магазин', 'Doʻkon qoʻshish'), icon: Icons.add_rounded, onPressed: () => _open(const LeadFormScreen())),
        ),
      ),
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat({required this.label, required this.value, required this.unit, required this.note, required this.color});

  final String label, value, unit, note;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(label, style: AppText.caption),
      const SizedBox(height: 2),
      Row(crossAxisAlignment: CrossAxisAlignment.baseline, textBaseline: TextBaseline.alphabetic, children: [
        Flexible(child: Text(value, style: AppText.h3.copyWith(color: color), maxLines: 1, overflow: TextOverflow.ellipsis)),
        const SizedBox(width: 4),
        Text(unit, style: AppText.small),
      ]),
      Text(note, style: AppText.small.copyWith(fontSize: 12)),
    ]);
  }
}

/// Вторая и третья строка заявки в списке.
(String, String) leadLines(Map<String, dynamic> l, DateTime now) {
  final s = leadStatus(l['status']);
  return switch (s) {
    LeadStatus.pending => (
        tr('отправлена ${dayMonth(l['created_at'])}', '${dayMonth(l['created_at'])} yuborildi'),
        tr('Закреплён ещё ${daysWord(leadDaysLeft(l['expires_at'], now))}', 'Yana ${daysWord(leadDaysLeft(l['expires_at'], now))} biriktirilgan'),
      ),
    LeadStatus.connected => (
        tr('подключён ${dayMonth(l['decided_at'])}', '${dayMonth(l['decided_at'])} ulandi'),
        l['invoice_due'] != null
            ? tr('Счёт выставлен · оплатить до ${dayMonth(l['invoice_due'])}', 'Hisob chiqarildi · ${dayMonth(l['invoice_due'])} gacha')
            : tr('Ждём первую оплату', 'Birinchi toʻlov kutilmoqda'),
      ),
    LeadStatus.paid => (
        tr('оплатил ${dayMonth(l['rewarded_at'])}', '${dayMonth(l['rewarded_at'])} toʻladi'),
        tr('Начислено на баланс', 'Balansga hisoblandi'),
      ),
    LeadStatus.rejected => (
        tr('отклонена ${dayMonth(l['decided_at'])}', '${dayMonth(l['decided_at'])} rad etildi'),
        '${l['reason'] ?? ''}',
      ),
    LeadStatus.expired => (
        tr('не подключили за 30 дней', '30 kunda ulanmadi'),
        tr('Магазин снова свободен', 'Doʻkon yana boʻsh'),
      ),
  };
}

class _LeadRow extends StatelessWidget {
  const _LeadRow({required this.l, required this.onTap});

  final Map<String, dynamic> l;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final s = leadStatus(l['status']);
    final tone = leadTone(s);
    final (bg, fg) = StatusChip.colors(tone);
    final (line2, line3) = leadLines(l, DateTime.now());
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Row(children: [
          IconBox(leadIcon(s), bg: bg, fg: fg, size: 40, iconSize: 20, radius: 12),
          const SizedBox(width: 10),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('${l['name']}', style: AppText.bodyStrong),
              Text(line2, style: AppText.small, maxLines: 1, overflow: TextOverflow.ellipsis),
              if (line3.isNotEmpty)
                Text(line3, style: AppText.small.copyWith(fontWeight: FontWeight.w500, color: s == LeadStatus.pending || s == LeadStatus.expired ? AppColors.text2 : fg),
                    maxLines: 2, overflow: TextOverflow.ellipsis),
            ]),
          ),
          const SizedBox(width: 8),
          StatusChip(leadLabel(s, reward: l['reward_amount']), tone: tone),
        ]),
      ),
    );
  }
}

// ------------------------------------------------------------- АМ6

/// АМ6 · Заявка: владелец, адрес и путь заявки до начисления.
class LeadScreen extends StatefulWidget {
  const LeadScreen({super.key, required this.id});

  final String id;

  @override
  State<LeadScreen> createState() => _LeadScreenState();
}

class _LeadScreenState extends State<LeadScreen> {
  Map<String, dynamic>? _l;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final r = await context.read<Api>().get('/store/supply/leads/${widget.id}') as Map<String, dynamic>;
      if (mounted) {
        setState(() {
          _l = r;
          _error = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = _l;
    if (l == null) {
      return Scaffold(
        appBar: AppBar(),
        body: _error != null ? LoadError(_error!, onRetry: _load) : const Center(child: CircularProgressIndicator()),
      );
    }
    final s = leadStatus(l['status']);
    return Scaffold(
      appBar: AppBar(
        title: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('${l['name']}', style: AppText.title),
          Text(tr('Добавлен вами ${dayMonth(l['created_at'])}', '${dayMonth(l['created_at'])} siz qoʻshgansiz'), style: AppText.small),
        ]),
      ),
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 24), children: [
          _StatusBanner(l: l),
          const SizedBox(height: 12),
          AppCard(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
            child: Column(children: [
              _InfoRow(icon: Icons.person_rounded, label: tr('Владелец', 'Egasi'), value: '${l['owner_name']}'),
              const Divider(height: 1),
              _InfoRow(
                icon: Icons.call_rounded,
                label: tr('Телефон', 'Telefon'),
                value: formatPhone(l['owner_phone']),
                action: IconButton(
                  onPressed: () => callPhone(l['owner_phone']),
                  style: IconButton.styleFrom(backgroundColor: AppColors.primarySoft),
                  icon: const Icon(Icons.call_rounded, color: AppColors.primary, size: 18),
                ),
              ),
              const Divider(height: 1),
              _InfoRow(
                icon: Icons.place_rounded,
                label: tr('Адрес', 'Manzil'),
                value: '${l['address'] ?? ''}'.isEmpty ? tr('Открыть на карте', 'Xaritada ochish') : '${l['address']}',
                onTap: () => openYandexMap(l['lat'], l['lng']),
              ),
            ]),
          ),
          const SizedBox(height: 12),
          AppCard(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(tr('Путь заявки', 'Ariza yoʻli'), style: AppText.bodyStrong),
              const SizedBox(height: 12),
              ..._steps(l, s),
            ]),
          ),
        ]),
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
          child: BigButton(
            label: tr('Позвонить владельцу', 'Egasiga qoʻngʻiroq qilish'),
            icon: Icons.call_rounded,
            color: AppColors.soft,
            foreground: AppColors.ink,
            onPressed: () => callPhone(l['owner_phone']),
          ),
        ),
      ),
    );
  }

  List<Widget> _steps(Map<String, dynamic> l, LeadStatus s) {
    final sent = _Step(tr('Заявка отправлена', 'Ariza yuborildi'), dateTime(l['created_at']), _StepState.done);
    final list = switch (s) {
      LeadStatus.rejected => [
          sent,
          _Step(tr('Отклонена', 'Rad etildi'), '${tr('Причина', 'Sabab')}: ${l['reason'] ?? ''}', _StepState.failed),
        ],
      LeadStatus.expired => [
          sent,
          _Step(tr('Срок истёк', 'Muddati tugadi'), tr('Не подключили за 30 дней — магазин снова свободен', '30 kunda ulanmadi — doʻkon yana boʻsh'), _StepState.failed),
        ],
      _ => [
          sent,
          s == LeadStatus.pending
              ? _Step(tr('Подключение супер-админом', 'Super-admin ulashi'),
                  tr('Закреплён за вами до ${dayMonth(l['expires_at'])}', '${dayMonth(l['expires_at'])} gacha sizga biriktirilgan'), _StepState.current)
              : _Step(tr('Подключён супер-админом', 'Super-admin uladi'),
                  [dateTime(l['decided_at']), if ('${l['plan_name'] ?? ''}'.isNotEmpty) tr('тариф «${l['plan_name']}»', '«${l['plan_name']}» tarifi')].join(' · '),
                  _StepState.done),
          s == LeadStatus.paid
              ? _Step(tr('Первая оплата', 'Birinchi toʻlov'), dateTime(l['paid_at'] ?? l['rewarded_at']), _StepState.done)
              : _Step(
                  tr('Первая оплата', 'Birinchi toʻlov'),
                  l['invoice_due'] != null
                      ? tr('Счёт выставлен · оплатить до ${dayMonth(l['invoice_due'])}', 'Hisob chiqarildi · ${dayMonth(l['invoice_due'])} gacha')
                      : tr('По тарифу, который выберет магазин', 'Doʻkon tanlagan tarif boʻyicha'),
                  s == LeadStatus.connected ? _StepState.current : _StepState.todo),
          s == LeadStatus.paid
              ? _Step(tr('Вам начислено ${money(l['reward_amount'])}', 'Sizga ${money(l['reward_amount'])} hisoblandi'),
                  tr('50% первой оплаты — на балансе Super Market', 'Birinchi toʻlovning 50% — Super Market balansida'), _StepState.reward)
              : _Step(tr('Вам 50% от первой оплаты', 'Birinchi toʻlovning 50% sizga'), tr('На баланс Super Market', 'Super Market balansiga'), _StepState.todo),
        ],
    };
    return [
      for (var i = 0; i < list.length; i++) _StepRow(step: list[i], last: i == list.length - 1, nextDone: i + 1 < list.length && list[i + 1].state.isDone),
    ];
  }
}

class _StatusBanner extends StatelessWidget {
  const _StatusBanner({required this.l});

  final Map<String, dynamic> l;

  @override
  Widget build(BuildContext context) {
    final s = leadStatus(l['status']);
    final (bg, fg) = StatusChip.colors(leadTone(s));
    final (IconData icon, String title, String text) = switch (s) {
      LeadStatus.pending => (
          Icons.hourglass_top_rounded,
          tr('На рассмотрении', 'Koʻrib chiqilmoqda'),
          tr('Магазин закреплён за вами ещё ${daysWord(leadDaysLeft(l['expires_at'], DateTime.now()))}. Супер-админ позвонит владельцу и подключит магазин.',
              'Doʻkon yana ${daysWord(leadDaysLeft(l['expires_at'], DateTime.now()))} sizga biriktirilgan. Super-admin egasiga qoʻngʻiroq qilib, doʻkonni ulaydi.'),
        ),
      LeadStatus.connected => (
          Icons.schedule_rounded,
          tr('Подключён — ждём первую оплату', 'Ulandi — birinchi toʻlov kutilmoqda'),
          tr('Как только магазин оплатит первый счёт, 50% от оплаты придут на ваш баланс', 'Doʻkon birinchi hisobni toʻlashi bilan toʻlovning 50% balansingizga tushadi'),
        ),
      LeadStatus.paid => (
          Icons.check_circle_rounded,
          tr('Магазин оплатил — вам ${money(l['reward_amount'])}', 'Doʻkon toʻladi — sizga ${money(l['reward_amount'])}'),
          tr('Деньги на балансе Super Market: гасят вашу подписку, остаток можно вывести', 'Pul Super Market balansida: obunangizni yopadi, qolganini yechib olish mumkin'),
        ),
      LeadStatus.rejected => (Icons.block_rounded, tr('Заявка отклонена', 'Ariza rad etildi'), '${tr('Причина', 'Sabab')}: ${l['reason'] ?? ''}'),
      LeadStatus.expired => (
          Icons.event_busy_rounded,
          tr('Срок истёк', 'Muddati tugadi'),
          tr('Магазин не подключили за 30 дней — он снова свободен. Можно добавить его заново.', 'Doʻkon 30 kunda ulanmadi — u yana boʻsh. Uni qayta qoʻshish mumkin.'),
        ),
    };
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(20)),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(icon, color: fg, size: 24),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title, style: AppText.bodyStrong.copyWith(color: fg)),
            const SizedBox(height: 2),
            Text(text, style: AppText.small.copyWith(color: fg)),
          ]),
        ),
      ]),
    );
  }
}

class _InfoRow extends StatelessWidget {
  const _InfoRow({required this.icon, required this.label, required this.value, this.action, this.onTap});

  final IconData icon;
  final String label, value;
  final Widget? action;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Row(children: [
          Icon(icon, color: AppColors.text2, size: 20),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(label, style: AppText.small.copyWith(fontSize: 12)),
              Text(value, style: AppText.body.copyWith(fontWeight: FontWeight.w500)),
            ]),
          ),
          if (action != null) action!,
        ]),
      ),
    );
  }
}

enum _StepState {
  done,
  current,
  todo,
  failed,
  reward;

  bool get isDone => this == _StepState.done || this == _StepState.reward;
}

class _Step {
  const _Step(this.title, this.sub, this.state);

  final String title, sub;
  final _StepState state;
}

class _StepRow extends StatelessWidget {
  const _StepRow({required this.step, required this.last, required this.nextDone});

  final _Step step;
  final bool last;
  final bool nextDone;

  @override
  Widget build(BuildContext context) {
    final (Color dot, Color title) = switch (step.state) {
      _StepState.done => (AppColors.successInk, AppColors.ink),
      _StepState.reward => (AppColors.successInk, AppColors.successInk),
      _StepState.current => (AppColors.warningInk, AppColors.warningInk),
      _StepState.failed => (AppColors.primary, AppColors.primary),
      _StepState.todo => (AppColors.line, AppColors.text2),
    };
    final filled = step.state.isDone || step.state == _StepState.failed;
    return IntrinsicHeight(
      child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Column(children: [
          Container(
            width: 16,
            height: 16,
            margin: const EdgeInsets.only(top: 2),
            decoration: BoxDecoration(
              color: filled ? dot : AppColors.white,
              shape: BoxShape.circle,
              border: filled ? null : Border.all(color: dot, width: 3),
            ),
          ),
          if (!last) Expanded(child: Container(width: 2, color: nextDone ? AppColors.successInk : AppColors.line)),
        ]),
        const SizedBox(width: 12),
        Expanded(
          child: Padding(
            padding: EdgeInsets.only(bottom: last ? 0 : 14),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(step.title, style: AppText.bodyStrong.copyWith(fontSize: 14, color: title)),
              Text(step.sub, style: AppText.small.copyWith(fontSize: 12)),
            ]),
          ),
        ),
      ]),
    );
  }
}
