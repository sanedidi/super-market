import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:sm_core/sm_core.dart';

import '../plan/plan_ui.dart';
import '../state.dart';
import '../ui/theme.dart';
import '../ui/widgets.dart';
import 'staff_logic.dart';
import 'staff_ui.dart';

/// С8 · Кассы: сколько касс по тарифу, у каждой статус — подключена, ждёт
/// подключения (код), отключена; «+» — новая касса (С9 → С10).
class RegistersScreen extends StatefulWidget {
  const RegistersScreen({super.key});

  @override
  State<RegistersScreen> createState() => _RegistersScreenState();
}

class _RegistersScreenState extends State<RegistersScreen> {
  List<Map<String, dynamic>>? _items;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final st = context.read<StoreState>();
    try {
      final items = await context.read<Api>().list('/store/pos/devices', {if (st.storeId != null) 'store_id': st.storeId});
      if (!mounted) return;
      setState(() {
        // Касса в телефоне — отдельной строкой внизу, не в списке касс.
        _items = [
          for (final d in items)
            if (d['phone'] != true) d,
        ];
        _error = null;
      });
      await st.loadPlan();
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  /// Лимит касс по тарифу: (сколько есть, сколько можно; null — без лимита).
  (int?, int?) _limit(StoreState st) {
    final cur = st.plan?['current'] as Map<String, dynamic>?;
    for (final l in (cur?['limits'] as List?) ?? const []) {
      final m = l as Map;
      if (m['key'] == 'registers') return ((m['used'] as num?)?.toInt(), (m['value'] as num?)?.toInt());
    }
    return (null, null);
  }

  Future<void> _create() async {
    final st = context.read<StoreState>();
    final (used, value) = _limit(st);
    if (used != null && value != null && used >= value) {
      await showRegistersLimit(context, used: used, limit: value);
      return;
    }
    final d = await showSheet<Map<String, dynamic>>(context, (_) => _NewRegisterSheet(count: (_items?.length ?? 0) + 1, used: used, limit: value));
    await _load();
    if (d != null && mounted) await showRegisterCode(context, d);
  }

  Future<void> _open(Map<String, dynamic> d) async {
    if (d['status'] == 'revoked') return;
    await showSheet<void>(context, (_) => _RegisterSheet(device: d));
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final st = context.watch<StoreState>();
    final (used, value) = _limit(st);
    final items = _items;
    return Scaffold(
      appBar: AppBar(
        title: Text(tr('Кассы', 'Kassalar')),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: IconButton.filled(
              onPressed: items == null ? null : _create,
              icon: const Icon(Icons.add_rounded),
              style: IconButton.styleFrom(backgroundColor: AppColors.primary, foregroundColor: AppColors.white),
              tooltip: tr('Новая касса', 'Yangi kassa'),
            ),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 32), children: [
          if (used != null) ...[
            AppCard(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  Expanded(child: Text(tr('По тарифу «${st.planName ?? ''}»', '«${st.planName ?? ''}» tarifi boʻyicha'), style: AppText.bodyStrong)),
                  Text(value == null ? tr('$used · без лимита', '$used · cheklovsiz') : tr('$used из $value касс', '$value tadan $used ta kassa'), style: AppText.bodyStrong),
                ]),
                const SizedBox(height: 8),
                ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: LinearProgressIndicator(
                    minHeight: 8,
                    value: value == null || value == 0 ? 0.15 : (used / value).clamp(0, 1).toDouble(),
                    backgroundColor: AppColors.soft,
                    color: value != null && used >= value ? AppColors.error : AppColors.primary,
                  ),
                ),
                const SizedBox(height: 8),
                Text(tr('Касса в телефоне и экраны кухни не считаются.', 'Telefondagi kassa va oshxona ekranlari hisoblanmaydi.'), style: AppText.small),
              ]),
            ),
            const SizedBox(height: 12),
          ],
          if (_error != null && items == null)
            ErrorView(error: _error, onRetry: _load)
          else if (items == null)
            const Padding(padding: EdgeInsets.only(top: 40), child: Center(child: CircularProgressIndicator()))
          else if (items.isEmpty)
            EmptyState(
              icon: Icons.point_of_sale_rounded,
              title: tr('Касс пока нет', 'Hozircha kassalar yoʻq'),
              text: tr('Создайте кассу — покажем код, его вводят на компьютере или Android-кассе.', 'Kassa yarating — kod koʻrsatamiz, uni kompyuter yoki Android-kassada kiritishadi.'),
              action: tr('Новая касса', 'Yangi kassa'),
              onAction: _create,
            )
          else
            AppCard(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
              child: Column(children: [
                for (final (i, d) in items.indexed) ...[
                  if (i > 0) const Divider(height: 1, indent: 68, color: AppColors.line),
                  _RegisterTile(d: d, onTap: () => _open(d)),
                ],
              ]),
            ),
          const SizedBox(height: 12),
          AppCard(
            child: Row(children: [
              const Icon(Icons.smartphone_rounded),
              const SizedBox(width: 12),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(tr('Касса в телефоне', 'Telefondagi kassa'), style: AppText.bodyStrong),
                  Text(tr('Кнопка «Продать» на главной — бесплатно, без кода', 'Bosh sahifadagi «Sotish» tugmasi — bepul, kodsiz'), style: AppText.small),
                ]),
              ),
            ]),
          ),
        ]),
      ),
    );
  }
}

class _RegisterTile extends StatelessWidget {
  const _RegisterTile({required this.d, required this.onTap});

  final Map<String, dynamic> d;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final (label, tone) = registerStatus(d);
    final revoked = d['status'] == 'revoked';
    final sub = registerSubtitle(d);
    return ListTile(
      onTap: revoked ? null : onTap,
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      leading: IconBox(revoked ? Icons.desktop_access_disabled_rounded : Icons.point_of_sale_rounded, size: 40, iconSize: 22, radius: 12),
      title: Text('${d['name']}', style: AppText.bodyStrong.copyWith(color: revoked ? AppColors.text2 : AppColors.ink)),
      subtitle: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        if (sub.isNotEmpty) Text(sub, style: AppText.small),
        const SizedBox(height: 4),
        StatusChip(label, tone: switch (tone) { 'green' => ChipTone.green, 'amber' => ChipTone.amber, _ => ChipTone.gray }),
      ]),
      trailing: revoked ? null : const Icon(Icons.chevron_right_rounded, color: AppColors.muted),
    );
  }
}

/// С9 · Новая касса: название и магазин → создать и показать код.
class _NewRegisterSheet extends StatefulWidget {
  const _NewRegisterSheet({required this.count, required this.used, required this.limit});

  final int count;
  final int? used;
  final int? limit;

  @override
  State<_NewRegisterSheet> createState() => _NewRegisterSheetState();
}

class _NewRegisterSheetState extends State<_NewRegisterSheet> {
  late final _name = TextEditingController(text: tr('Касса ${widget.count}', 'Kassa ${widget.count}'));
  String? _storeId;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _storeId = context.read<StoreState>().storeId;
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final name = _name.text.trim();
    if (name.isEmpty || _storeId == null) {
      setState(() => _error = tr('Введите название кассы', 'Kassa nomini kiriting'));
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final d = await context.read<Api>().post('/store/pos/devices', {'store_id': _storeId, 'name': name}) as Map<String, dynamic>;
      if (mounted) Navigator.of(context).pop(d);
    } on ApiError catch (e) {
      if (!mounted) return;
      if (e.code == 'tariff_limit') {
        final nav = Navigator.of(context);
        nav.pop();
        await showRegistersLimit(nav.context, used: (e.details['used'] as num?)?.toInt(), limit: (e.details['limit'] as num?)?.toInt());
      } else if (e.isPlan) {
        await showPlanSheet(context, error: e);
      } else {
        setState(() => _error = e.message);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final st = context.watch<StoreState>();
    final next = widget.used == null ? null : widget.used! + 1;
    return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Text(tr('Новая касса', 'Yangi kassa'), style: AppText.h3),
      const SizedBox(height: 16),
      TextField(
        controller: _name,
        autofocus: true,
        maxLength: 60,
        decoration: InputDecoration(labelText: tr('Название *', 'Nomi *'), hintText: tr('например, Касса 2 · у входа', 'masalan, Kassa 2 · kirishda'), counterText: ''),
      ),
      if (st.stores.length > 1) ...[
        const SizedBox(height: 12),
        DropdownButtonFormField<String>(
          initialValue: _storeId,
          decoration: InputDecoration(labelText: tr('Магазин', 'Doʻkon')),
          items: [
            for (final s in st.stores) DropdownMenuItem(value: '${s['id']}', child: Text('${s['name']}')),
          ],
          onChanged: (v) => setState(() => _storeId = v),
        ),
      ],
      const SizedBox(height: 12),
      Text(
        [
          if (next != null && widget.limit != null) tr('Будет $next из ${widget.limit} касс по тарифу «${st.planName ?? ''}».', 'Tarif «${st.planName ?? ''}» boʻyicha ${widget.limit} tadan $next ta kassa boʻladi.'),
          tr('Код подключения покажем сразу — он действует сутки.', 'Ulanish kodini darhol koʻrsatamiz — u bir sutka amal qiladi.'),
        ].join(' '),
        style: AppText.small,
      ),
      if (_error != null) ...[
        const SizedBox(height: 8),
        Text(_error!, style: AppText.small.copyWith(color: AppColors.error)),
      ],
      const SizedBox(height: 20),
      BigButton(label: tr('Создать и показать код', 'Yaratish va kodni koʻrsatish'), icon: Icons.qr_code_2_rounded, busy: _busy, onPressed: _save),
    ]);
  }
}

/// С10 · Код подключения кассы: крупно, скопировать / поделиться, как
/// подключить. [d] — касса с activation_code.
Future<void> showRegisterCode(BuildContext context, Map<String, dynamic> d) {
  return showSheet<void>(context, (_) => _CodeView(device: d));
}

class _CodeView extends StatelessWidget {
  const _CodeView({required this.device});

  final Map<String, dynamic> device;

  @override
  Widget build(BuildContext context) {
    final code = formatActivationCode('${device['activation_code'] ?? ''}');
    final store = '${device['store_name'] ?? ''}';
    final text = tr('Код подключения кассы «${device['name']}» ($store): $code\nОткройте «Super Market Касса» на компьютере или Android-кассе и введите код. Код действует сутки.',
        '«${device['name']}» kassasini ulash kodi ($store): $code\nKompyuter yoki Android-kassada «Super Market Kassa»ni oching va kodni kiriting. Kod bir sutka amal qiladi.');
    final steps = [
      tr('На компьютере или Android-кассе откройте «Super Market Касса»', 'Kompyuter yoki Android-kassada «Super Market Kassa»ni oching'),
      tr('Введите код — касса подключится к «$store»', 'Kodni kiriting — kassa «$store»ga ulanadi'),
      tr('Кассир входит по ПИНу — ПИНы задаются в «Сотрудниках»', 'Kassir PIN bilan kiradi — PINlar «Xodimlar»da beriladi'),
    ];
    return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Text('${device['name']}', style: AppText.h3, textAlign: TextAlign.center),
      Text(tr('Код подключения', 'Ulanish kodi'), style: AppText.small, textAlign: TextAlign.center),
      const SizedBox(height: 12),
      Container(
        padding: const EdgeInsets.symmetric(vertical: 16),
        decoration: BoxDecoration(color: AppColors.bg, borderRadius: BorderRadius.circular(16), border: Border.all(color: AppColors.line)),
        child: Column(children: [
          Text(code, style: AppText.h1.copyWith(fontSize: 34, letterSpacing: 4)),
          if (device['activation_expires'] != null) Text(tr('действует до ${dateTime(device['activation_expires'])}', '${dateTime(device['activation_expires'])} gacha amal qiladi'), style: AppText.small),
        ]),
      ),
      const SizedBox(height: 12),
      Row(children: [
        Expanded(child: SmallButton(label: tr('Скопировать', 'Nusxalash'), icon: Icons.content_copy_rounded, onPressed: () => copyText(context, code, tr('Код', 'Kod')))),
        const SizedBox(width: 10),
        Expanded(child: SmallButton(label: tr('Поделиться', 'Ulashish'), icon: Icons.send_rounded, primary: true, onPressed: () => shareTelegram(context, text))),
      ]),
      const SizedBox(height: 14),
      Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(borderRadius: BorderRadius.circular(14), border: Border.all(color: AppColors.line)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(tr('Как подключить', 'Qanday ulash'), style: AppText.bodyStrong),
          for (final (i, s) in steps.indexed)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Row(children: [
                Container(
                  width: 22,
                  height: 22,
                  alignment: Alignment.center,
                  decoration: const BoxDecoration(color: AppColors.primarySoft, shape: BoxShape.circle),
                  child: Text('${i + 1}', style: AppText.caption.copyWith(color: AppColors.primary)),
                ),
                const SizedBox(width: 10),
                Expanded(child: Text(s, style: AppText.body.copyWith(fontSize: 14))),
              ]),
            ),
        ]),
      ),
      const SizedBox(height: 16),
      SheetButton(label: tr('Готово', 'Tayyor'), primary: false, onPressed: () => Navigator.of(context).pop()),
    ]);
  }
}

/// Карточка кассы: статус, «Показать код» / «Новый код», «Отключить кассу».
class _RegisterSheet extends StatefulWidget {
  const _RegisterSheet({required this.device});

  final Map<String, dynamic> device;

  @override
  State<_RegisterSheet> createState() => _RegisterSheetState();
}

class _RegisterSheetState extends State<_RegisterSheet> {
  bool _busy = false;

  Future<void> _code() async {
    setState(() => _busy = true);
    try {
      final d = await context.read<Api>().post('/store/pos/devices/${widget.device['id']}/code') as Map<String, dynamic>;
      if (!mounted) return;
      final nav = Navigator.of(context);
      nav.pop();
      await showRegisterCode(nav.context, d);
    } on ApiError catch (e) {
      if (mounted) snack(context, e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _revoke() async {
    final ok = await confirmSheet(
      context,
      title: tr('Отключить «${widget.device['name']}»?', '«${widget.device['name']}» oʻchirilsinmi?'),
      text: tr('Касса сразу перестанет работать и не будет считаться в лимите. Чтобы снова работать на ней, создайте новую кассу и введите код.',
          'Kassa darhol ishlashdan toʻxtaydi va limitda hisoblanmaydi. Unda yana ishlash uchun yangi kassa yarating va kodni kiriting.'),
      confirm: tr('Отключить', 'Oʻchirish'),
      icon: Icons.desktop_access_disabled_rounded,
    );
    if (!ok || !mounted) return;
    setState(() => _busy = true);
    try {
      await context.read<Api>().post('/store/pos/devices/${widget.device['id']}/revoke');
      if (!mounted) return;
      snack(context, tr('Касса отключена', 'Kassa oʻchirildi'));
      Navigator.of(context).pop();
    } on ApiError catch (e) {
      if (mounted) snack(context, e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final d = widget.device;
    final (label, tone) = registerStatus(d);
    final waiting = d['status'] == 'waiting';
    final sub = registerSubtitle(d);
    return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Row(children: [
        const IconBox(Icons.point_of_sale_rounded),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('${d['name']}', style: AppText.h3),
            Text('${d['store_name'] ?? ''}', style: AppText.small),
          ]),
        ),
        StatusChip(label, tone: tone == 'green' ? ChipTone.green : ChipTone.amber),
      ]),
      if (sub.isNotEmpty) ...[const SizedBox(height: 10), Text(sub, style: AppText.body)],
      if ('${d['app_version'] ?? ''}'.isNotEmpty) Text(tr('версия ${d['app_version']}', 'versiya ${d['app_version']}'), style: AppText.small),
      const SizedBox(height: 10),
      Text(
        waiting
            ? tr('Код показывается один раз. Потеряли — получите новый: старый перестанет действовать.', 'Kod bir marta koʻrsatiladi. Yoʻqotsangiz — yangisini oling: eskisi amal qilmay qoladi.')
            : tr('Новый код нужен, чтобы перенести кассу на другой компьютер: до ввода кода касса работает как раньше.',
                'Yangi kod kassani boshqa kompyuterga koʻchirish uchun kerak: kod kiritilguncha kassa avvalgidek ishlaydi.'),
        style: AppText.small,
      ),
      const SizedBox(height: 16),
      BigButton(label: waiting ? tr('Показать код', 'Kodni koʻrsatish') : tr('Новый код', 'Yangi kod'), icon: Icons.qr_code_2_rounded, busy: _busy, onPressed: _code),
      const SizedBox(height: 10),
      SheetButton(label: tr('Отключить кассу', 'Kassani oʻchirish'), primary: false, onPressed: _busy ? null : _revoke),
    ]);
  }
}

/// С11 · Касс уже столько, сколько разрешает тариф: перейти на тариф выше
/// или отключить ненужную кассу (доп. кассу отдельно не продаём).
Future<void> showRegistersLimit(BuildContext context, {int? used, int? limit}) {
  final st = context.read<StoreState>();
  final plan = st.planName ?? '';
  return showSheet<void>(
    context,
    (ctx) => Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      const Align(alignment: Alignment.centerLeft, child: IconBox(Icons.lock_rounded, bg: AppColors.warningSoft, fg: AppColors.warningInk)),
      const SizedBox(height: 14),
      Text(limit == null ? tr('Лимит касс по тарифу', 'Tarif boʻyicha kassalar limiti') : tr('На тарифе «$plan» — до $limit касс', '«$plan» tarifida — $limit tagacha kassa'), style: AppText.h3),
      const SizedBox(height: 8),
      Text(
        tr('${used != null ? 'Все $used уже используются. ' : ''}Чтобы подключить ещё одну, перейдите на тариф выше — там касс больше. Или отключите кассу, которой не пользуетесь: она перестанет считаться.',
            '${used != null ? 'Hammasi ($used) ishlatilmoqda. ' : ''}Yana bittasini ulash uchun yuqoriroq tarifga oʻting — u yerda kassalar koʻproq. Yoki foydalanmayotgan kassani oʻchiring: u hisoblanmay qoladi.'),
        style: AppText.body.copyWith(color: AppColors.text2),
      ),
      const SizedBox(height: 20),
      SheetButton(
        label: tr('Посмотреть тарифы', 'Tariflarni koʻrish'),
        onPressed: () {
          Navigator.of(ctx).pop();
          openPlan(context);
        },
      ),
      const SizedBox(height: 10),
      SheetButton(label: tr('Отключить ненужную кассу', 'Keraksiz kassani oʻchirish'), primary: false, onPressed: () => Navigator.of(ctx).pop()),
    ]),
  );
}
