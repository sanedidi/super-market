import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:sm_core/sm_core.dart';

import '../main.dart';
import '../map_view.dart';
import '../state.dart';
import '../ui/theme.dart';
import '../ui/widgets.dart';

/// Открыть редактор нового адреса и обновить список после сохранения.
/// [point] — где поставить метку нового адреса (например, точка гостя).
Future<void> openAddressEditor(BuildContext context, [Address? address, ({double lat, double lng})? point]) async {
  await Navigator.of(context).push(MaterialPageRoute(builder: (_) => AddressEditScreen(address: address, point: point)));
  if (context.mounted) await context.read<AppState>().loadAddresses();
}

/// Мои адреса: выбрать, изменить, добавить.
class AddressesScreen extends StatelessWidget {
  const AddressesScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    return Scaffold(
      appBar: AppBar(
        leading: Padding(padding: const EdgeInsets.only(left: 12), child: Center(child: RoundIconButton(icon: Icons.arrow_back_rounded, onTap: () => Navigator.of(context).pop()))),
        leadingWidth: 64,
        title: const Text('Куда доставить?'),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
        children: [
          for (final a in state.addresses) ...[
            _AddressCard(
              address: a,
              selected: state.address?.id == a.id,
              onTap: () {
                state.selectAddress(a);
                Navigator.of(context).pop();
              },
              onEdit: () => openAddressEditor(context, a),
            ),
            const SizedBox(height: 10),
          ],
          InkWell(
            borderRadius: BorderRadius.circular(AppRadius.lg),
            onTap: () => openAddressEditor(context),
            child: const Padding(
              padding: EdgeInsets.symmetric(vertical: 12, horizontal: 14),
              child: Row(children: [
                IconBox(Icons.add_rounded),
                SizedBox(width: 12),
                Text('Новый адрес на карте', style: TextStyle(fontFamily: 'Inter', fontSize: 15, fontWeight: FontWeight.w600, color: AppColors.primary)),
              ]),
            ),
          ),
        ],
      ),
    );
  }
}

class _AddressCard extends StatelessWidget {
  const _AddressCard({required this.address, required this.selected, required this.onTap, required this.onEdit});
  final Address address;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback onEdit;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: selected ? AppColors.primarySoft : AppColors.white,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.lg),
        side: BorderSide(color: selected ? AppColors.primary : AppColors.line, width: selected ? 2 : 1),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(AppRadius.lg),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 4, 12),
          child: Row(children: [
            IconBox(Icons.location_on_outlined, bg: selected ? AppColors.white : AppColors.primarySoft),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(address.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.bodyStrong),
                if (address.label.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(address.address, maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.small),
                ],
              ]),
            ),
            IconButton(onPressed: onEdit, icon: const Icon(Icons.edit_outlined, color: AppColors.text2)),
            Icon(selected ? Icons.radio_button_checked_rounded : Icons.radio_button_off_rounded,
                color: selected ? AppColors.primary : AppColors.muted),
            const SizedBox(width: 8),
          ]),
        ),
      ),
    );
  }
}

/// Новый адрес или правка: точка на карте + подъезд, этаж, квартира.
class AddressEditScreen extends StatefulWidget {
  const AddressEditScreen({super.key, this.address, this.point});
  final Address? address;

  /// Начальная точка нового адреса; null — геолокация.
  final ({double lat, double lng})? point;

  @override
  State<AddressEditScreen> createState() => _AddressEditScreenState();
}

class _AddressEditScreenState extends State<AddressEditScreen> {
  late final Map<String, TextEditingController> _f;
  ({double lat, double lng})? _point;
  bool _busy = false;

  /// Улицу вписали руками — перемещение карты её не перезаписывает
  /// (кнопка «где я» перезаписывает всегда).
  late bool _addressTyped = widget.address != null;
  int _geoSeq = 0;

  Future<void> _onPoint(double lat, double lng, {bool located = false}) async {
    _point = (lat: lat, lng: lng);
    if (_addressTyped && !located) return;
    final seq = ++_geoSeq;
    final a = await addressAt(lat, lng);
    if (!mounted || seq != _geoSeq || a == null) return;
    setState(() {
      _f['address']!.text = a;
      _addressTyped = false;
    });
  }

  @override
  void initState() {
    super.initState();
    final j = widget.address?.json ?? const {};
    _f = {
      for (final k in ['label', 'address', 'entrance', 'floor', 'apartment', 'comment'])
        k: TextEditingController(text: '${j[k] ?? ''}'),
    };
    if (widget.address != null) {
      _point = (lat: widget.address!.lat, lng: widget.address!.lng);
    } else if (widget.point != null) {
      _point = widget.point;
    } else {
      // Страховка: если геолокация не ответила, показываем карту с центром Ташкента.
      currentLocation().timeout(const Duration(seconds: 8), onTimeout: () => null).then((loc) {
        if (mounted && _point == null) setState(() => _point = loc ?? tashkent);
      });
    }
  }

  @override
  void dispose() {
    for (final c in _f.values) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    if (_f['address']!.text.trim().isEmpty) {
      showError(context, 'Укажите улицу и дом');
      return;
    }
    setState(() => _busy = true);
    final body = {for (final e in _f.entries) e.key: e.value.text.trim(), 'lat': _point!.lat, 'lng': _point!.lng};
    final api = context.read<Api>();
    try {
      if (widget.address == null) {
        await api.post('/client/addresses', body);
      } else {
        await api.put('/client/addresses/${widget.address!.id}', body);
      }
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _delete() async {
    try {
      await context.read<Api>().delete('/client/addresses/${widget.address!.id}');
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Widget _field(String key, String label, {int flex = 1, TextInputType? type}) => Expanded(
        flex: flex,
        child: Padding(
          padding: const EdgeInsets.all(4),
          child: TextField(
            controller: _f[key],
            keyboardType: type,
            onChanged: key == 'address' ? (_) => _addressTyped = true : null,
            decoration: InputDecoration(labelText: label, isDense: true),
          ),
        ),
      );

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.address == null ? 'Новый адрес' : 'Адрес'),
        actions: [
          if (widget.address != null) IconButton(icon: const Icon(Icons.delete_outline), onPressed: _delete),
        ],
      ),
      body: _point == null
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                Expanded(
                  child: PointPicker(
                    initial: _point!,
                    onChanged: _onPoint,
                  ),
                ),
                SafeArea(
                  child: Padding(
                    padding: const EdgeInsets.all(8),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Row(children: [_field('address', 'Улица, дом', flex: 3), _field('label', 'Название')]),
                        Row(children: [
                          _field('apartment', 'Квартира', type: TextInputType.number),
                          _field('entrance', 'Подъезд', type: TextInputType.number),
                          _field('floor', 'Этаж', type: TextInputType.number),
                        ]),
                        Row(children: [_field('comment', 'Комментарий курьеру')]),
                        const SizedBox(height: 8),
                        AppButton(label: 'Сохранить адрес', loading: _busy, onPressed: _save),
                      ],
                    ),
                  ),
                ),
              ],
            ),
    );
  }
}
