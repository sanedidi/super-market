import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:sm_core/sm_core.dart';

import '../main.dart';
import '../map_view.dart';
import '../state.dart';

/// Мои адреса: выбрать, изменить, удалить, добавить.
class AddressesScreen extends StatelessWidget {
  const AddressesScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    return Scaffold(
      appBar: AppBar(title: const Text('Адреса доставки')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () async {
          await Navigator.of(context).push(MaterialPageRoute(builder: (_) => const AddressEditScreen()));
          if (context.mounted) await context.read<AppState>().loadAddresses();
        },
        icon: const Icon(Icons.add),
        label: const Text('Новый адрес'),
      ),
      body: ListView(
        children: [
          for (final a in state.addresses)
            ListTile(
              leading: Icon(state.address?.id == a.id ? Icons.radio_button_checked : Icons.radio_button_off),
              title: Text(a.title),
              subtitle: a.label.isNotEmpty ? Text(a.address) : null,
              onTap: () {
                state.selectAddress(a);
                Navigator.of(context).pop();
              },
              trailing: IconButton(
                icon: const Icon(Icons.edit_outlined),
                onPressed: () async {
                  await Navigator.of(context).push(MaterialPageRoute(builder: (_) => AddressEditScreen(address: a)));
                  if (context.mounted) await context.read<AppState>().loadAddresses();
                },
              ),
            ),
        ],
      ),
    );
  }
}

/// Новый адрес или правка: точка на карте + подъезд, этаж, квартира.
class AddressEditScreen extends StatefulWidget {
  const AddressEditScreen({super.key, this.address});
  final Address? address;

  @override
  State<AddressEditScreen> createState() => _AddressEditScreenState();
}

class _AddressEditScreenState extends State<AddressEditScreen> {
  late final Map<String, TextEditingController> _f;
  ({double lat, double lng})? _point;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    final j = widget.address?.json ?? const {};
    _f = {
      for (final k in ['label', 'address', 'entrance', 'floor', 'apartment', 'comment'])
        k: TextEditingController(text: (j[k] as String?) ?? ''),
    };
    if (widget.address != null) {
      _point = (lat: widget.address!.lat, lng: widget.address!.lng);
    } else {
      currentLocation().then((loc) {
        if (mounted) setState(() => _point = loc ?? tashkent);
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
            decoration: InputDecoration(labelText: label, border: const OutlineInputBorder(), isDense: true),
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
                    onChanged: (lat, lng) => _point = (lat: lat, lng: lng),
                  ),
                ),
                SafeArea(
                  child: Padding(
                    padding: const EdgeInsets.all(8),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Row(children: [_field('address', 'Улица, дом', flex: 3), _field('label', 'Название (Дом)')]),
                        Row(children: [
                          _field('apartment', 'Квартира', type: TextInputType.number),
                          _field('entrance', 'Подъезд', type: TextInputType.number),
                          _field('floor', 'Этаж', type: TextInputType.number),
                        ]),
                        Row(children: [_field('comment', 'Комментарий курьеру')]),
                        const SizedBox(height: 8),
                        FilledButton(
                          style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
                          onPressed: _busy ? null : _save,
                          child: const Text('Сохранить адрес'),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
    );
  }
}
