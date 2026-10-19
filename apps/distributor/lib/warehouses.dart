import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';
import 'package:provider/provider.dart';
import 'package:sm_core/sm_core.dart';
import 'package:sm_store/main.dart' show showMessage;
import 'package:sm_store/setup/setup_map.dart';
import 'package:sm_store/state.dart';
import 'package:sm_store/ui/theme.dart';
import 'package:sm_store/ui/widgets.dart';

// Склады агента (Figma «Правки 16 окт» → А2–А4): у каждого адрес и точка,
// магазины видны в 15 км от любого склада. Выбранный во вкладке «Склад»
// склад — склад новых приходов, инвентаризаций и списаний.

/// Склад, выбранный во вкладке «Склад» (null — основной); `point` — точка агента,
/// для которой выбран (другой вход — выбор не действует).
final selectedWarehouse = ValueNotifier<Map<String, dynamic>?>(null);

/// Склад для нового документа (не расхода): выбранный во вкладке «Склад» или основной.
String? warehouseForNewDoc(BuildContext context) {
  final st = context.read<StoreState>();
  final sel = selectedWarehouse.value;
  if (sel != null && sel['point'] == st.storeId) return sel['id'] as String?;
  return st.store?['default_warehouse_id'] as String?;
}

Future<List<Map<String, dynamic>>> loadWarehouses(Api api) => api.list('/store/supply/warehouses');

String whName(Map<String, dynamic> w) => w['is_default'] == true ? tr('${w['name']} — основной', '${w['name']} — asosiy') : '${w['name']}';

/// Выбор склада шторкой: [subtitle] — вторая строка (адрес, расстояние, наличие).
Future<Map<String, dynamic>?> pickWarehouse(
  BuildContext context, {
  required String title,
  required List<Map<String, dynamic>> items,
  String? selectedId,
  Widget Function(Map<String, dynamic>)? subtitle,
  VoidCallback? onManage,
}) {
  return showSheet<Map<String, dynamic>>(context, (ctx) {
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Text(title, style: AppText.h3),
      const SizedBox(height: 12),
      for (final w in items) ...[
        _WarehouseOption(w: w, selected: w['id'] == selectedId, subtitle: subtitle?.call(w), onTap: () => Navigator.of(ctx).pop(w)),
        const SizedBox(height: 8),
      ],
      if (onManage != null)
        TextButton(
          onPressed: () {
            Navigator.of(ctx).pop();
            onManage();
          },
          child: Text(tr('Склады — добавить или изменить', 'Omborlar — qoʻshish yoki oʻzgartirish')),
        ),
    ]);
  });
}

class _WarehouseOption extends StatelessWidget {
  const _WarehouseOption({required this.w, required this.selected, required this.onTap, this.subtitle});

  final Map<String, dynamic> w;
  final bool selected;
  final Widget? subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: selected ? AppColors.primarySoft : AppColors.white,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: selected ? const Color(0xFFF49097) : AppColors.line),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(children: [
            IconBox(Icons.warehouse_rounded,
                bg: selected ? AppColors.white : AppColors.soft, fg: selected ? AppColors.primary : AppColors.text2, size: 40, iconSize: 20, radius: 12),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(whName(w), style: AppText.bodyStrong),
                subtitle ?? Text('${w['address'] ?? ''}', style: AppText.small, maxLines: 1, overflow: TextOverflow.ellipsis),
              ]),
            ),
            Icon(selected ? Icons.radio_button_checked_rounded : Icons.radio_button_unchecked_rounded, color: selected ? AppColors.primary : AppColors.muted),
          ]),
        ),
      ),
    );
  }
}

/// А2 · «Склады» во вкладке «Склад»: карточки складов, «Добавить склад», подсказка.
class WarehousesSection extends StatelessWidget {
  const WarehousesSection({super.key, required this.items, required this.onChanged});

  final List<Map<String, dynamic>> items;
  final VoidCallback onChanged;

  Future<void> _edit(BuildContext context, [Map<String, dynamic>? w]) async {
    final changed = await Navigator.of(context).push<bool>(MaterialPageRoute(builder: (_) => WarehouseEditScreen(warehouse: w)));
    if (changed == true) onChanged();
  }

  @override
  Widget build(BuildContext context) {
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Text(tr('Склады', 'Omborlar'), style: AppText.h3),
      const SizedBox(height: 10),
      for (final w in items) ...[
        AppCard(
          onTap: () => _edit(context, w),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              IconBox(Icons.warehouse_rounded,
                  bg: w['is_default'] == true ? AppColors.primarySoft : AppColors.soft,
                  fg: w['is_default'] == true ? AppColors.primary : AppColors.text2,
                  size: 40,
                  iconSize: 20,
                  radius: 12),
              const SizedBox(width: 12),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Wrap(spacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
                    Text('${w['name']}', style: AppText.bodyStrong),
                    if (w['is_default'] == true) StatusChip(tr('основной', 'asosiy'), tone: ChipTone.green),
                    if (w['is_active'] == false) StatusChip(tr('отключён', 'oʻchirilgan')),
                  ]),
                  Text(
                    [if ('${w['address'] ?? ''}'.isNotEmpty) '${w['address']}', if (w['lat'] != null) tr('зона 15 км', 'zona 15 km') else tr('нет точки на карте', 'xaritada nuqta yoʻq')]
                        .join(' · '),
                    style: AppText.small,
                  ),
                ]),
              ),
              const Icon(Icons.chevron_right_rounded, color: AppColors.muted),
            ]),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(color: AppColors.soft, borderRadius: BorderRadius.circular(12)),
              child: Row(children: [
                _stat(tr('Магазинов в зоне', 'Zonadagi doʻkonlar'), '${w['stores_in_zone'] ?? 0}'),
                _stat(tr('Товаров', 'Mahsulotlar'), '${w['products'] ?? 0}'),
                _stat(tr('На сумму', 'Summasi'), money(w['stock_cost'], suffix: false)),
              ]),
            ),
          ]),
        ),
        const SizedBox(height: 10),
      ],
      OutlinedButton.icon(
        onPressed: () => _edit(context),
        style: OutlinedButton.styleFrom(
          foregroundColor: AppColors.primary,
          side: const BorderSide(color: Color(0xFFF49097)),
          minimumSize: const Size.fromHeight(50),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        ),
        icon: const Icon(Icons.add_rounded),
        label: Text(tr('Добавить склад', 'Ombor qoʻshish'), style: const TextStyle(fontWeight: FontWeight.w600)),
      ),
      const SizedBox(height: 10),
      Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(color: AppColors.blueSoft, borderRadius: BorderRadius.circular(14)),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Icon(Icons.info_rounded, size: 18, color: AppColors.blue),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              tr('Магазины видны в 15 км от любого вашего склада. Остатки, приходы и расходы — по каждому складу отдельно.',
                  'Doʻkonlar istalgan omboringizdan 15 km ichida koʻrinadi. Qoldiq, kirim va chiqim — har bir ombor boʻyicha alohida.'),
              style: AppText.small,
            ),
          ),
        ]),
      ),
    ]);
  }

  Widget _stat(String l, String v) => Expanded(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(l, style: AppText.small.copyWith(fontSize: 12)),
          Text(v, style: AppText.bodyStrong, maxLines: 1, overflow: TextOverflow.ellipsis),
        ]),
      );
}

/// А3 · Новый склад / склад: название, адрес, точка (от неё зона 15 км), основной.
class WarehouseEditScreen extends StatefulWidget {
  const WarehouseEditScreen({super.key, this.warehouse});

  final Map<String, dynamic>? warehouse;

  @override
  State<WarehouseEditScreen> createState() => _WarehouseEditScreenState();
}

class _WarehouseEditScreenState extends State<WarehouseEditScreen> {
  late final _w = widget.warehouse;
  late final _name = TextEditingController(text: '${_w?['name'] ?? ''}');
  late final _address = TextEditingController(text: '${_w?['address'] ?? ''}');
  late LatLng? _point = _w?['lat'] is num ? LatLng((_w!['lat'] as num).toDouble(), (_w['lng'] as num).toDouble()) : null;
  late bool _main = _w?['is_default'] == true;
  late bool _active = _w?['is_active'] != false;
  bool _busy = false;

  @override
  void dispose() {
    _name.dispose();
    _address.dispose();
    super.dispose();
  }

  Future<void> _pick() async {
    FocusScope.of(context).unfocus();
    final r = await Navigator.of(context).push<PickedPoint>(MaterialPageRoute(builder: (_) => MapPickerScreen(initial: _point, address: _address.text)));
    if (r == null || !mounted) return;
    setState(() {
      _point = r.point;
      if (_address.text.trim().isEmpty && r.address != null) _address.text = r.address!;
    });
  }

  Future<void> _here() async {
    final p = await currentPoint();
    if (!mounted) return;
    if (p == null) {
      showMessage(context, tr('Не удалось определить геопозицию', 'Geojoylashuvni aniqlab boʻlmadi'));
      return;
    }
    final a = await addressAt(p);
    if (!mounted) return;
    setState(() {
      _point = p;
      if (_address.text.trim().isEmpty && a != null) _address.text = a;
    });
  }

  Future<void> _save() async {
    if (_name.text.trim().isEmpty || _address.text.trim().isEmpty) {
      showMessage(context, tr('Укажите название и адрес склада', 'Ombor nomi va manzilini kiriting'));
      return;
    }
    if (_point == null) {
      showMessage(context, tr('Поставьте склад на карте — от него считается зона 15 км', 'Omborni xaritada belgilang — 15 km zona undan hisoblanadi'));
      return;
    }
    setState(() => _busy = true);
    final api = context.read<Api>();
    final st = context.read<StoreState>();
    final w = _w;
    try {
      final body = {
        'name': _name.text.trim(),
        'address': _address.text.trim(),
        'lat': _point!.latitude,
        'lng': _point!.longitude,
        if (_main && w?['is_default'] != true) 'is_default': true,
        if (w != null && _active != (w['is_active'] != false)) 'is_active': _active,
      };
      if (w == null) {
        await api.post('/store/supply/warehouses', body);
      } else {
        await api.patch('/store/supply/warehouses/${w['id']}', body);
      }
      // Основной склад — точка агента: обновить её в состоянии.
      if (_main) await st.load();
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) showMessage(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = _point;
    final w = _w;
    final isMain = w?['is_default'] == true;
    return Scaffold(
      backgroundColor: AppColors.white,
      appBar: AppBar(backgroundColor: AppColors.white, title: Text(w == null ? tr('Новый склад', 'Yangi ombor') : '${w['name']}', style: AppText.title)),
      body: ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 24), children: [
        TextField(controller: _name, textCapitalization: TextCapitalization.sentences, decoration: InputDecoration(labelText: tr('Название *', 'Nomi *'))),
        const SizedBox(height: 12),
        TextField(controller: _address, decoration: InputDecoration(labelText: tr('Адрес *', 'Manzil *'))),
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
                  radiusM: 15000,
                  height: 220,
                  overlay: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                    decoration: BoxDecoration(color: AppColors.white, borderRadius: BorderRadius.circular(999)),
                    child: Text(tr('зона 15 км · изменить', '15 km zona · oʻzgartirish'), style: AppText.caption.copyWith(color: AppColors.ink)),
                  ),
                ),
        ),
        TextButton.icon(
          onPressed: _here,
          style: TextButton.styleFrom(foregroundColor: AppColors.primary, padding: EdgeInsets.zero, alignment: Alignment.centerLeft),
          icon: const Icon(Icons.my_location_rounded, size: 18),
          label: Text(tr('Поставить по моей геопозиции', 'Mening joylashuvim boʻyicha')),
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          value: _main,
          onChanged: isMain ? null : (v) => setState(() => _main = v),
          title: Text(tr('Основной склад', 'Asosiy ombor'), style: AppText.bodyStrong.copyWith(fontWeight: FontWeight.w500)),
          subtitle: Text(
              isMain
                  ? tr('Чтобы сменить основной, сделайте основным другой склад', 'Asosiyni almashtirish uchun boshqa omborni asosiy qiling')
                  : tr('Приход и расход по умолчанию', 'Standart kirim va chiqim'),
              style: AppText.small),
        ),
        if (w != null && !isMain)
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: _active,
            onChanged: (v) => setState(() => _active = v),
            title: Text(tr('Склад работает', 'Ombor ishlayapti'), style: AppText.bodyStrong.copyWith(fontWeight: FontWeight.w500)),
            subtitle: Text(tr('Отключённый склад не даёт зону и не выбирается в расходе', 'Oʻchirilgan ombor zona bermaydi va chiqimda tanlanmaydi'), style: AppText.small),
          ),
      ]),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
          child: BigButton(label: tr('Сохранить склад', 'Omborni saqlash'), busy: _busy, onPressed: _save),
        ),
      ),
    );
  }
}
