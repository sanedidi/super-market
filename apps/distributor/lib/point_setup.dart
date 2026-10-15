import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';
import 'package:provider/provider.dart';
import 'package:sm_core/sm_core.dart';
import 'package:sm_store/main.dart' show showMessage;
import 'package:sm_store/setup/setup_map.dart';
import 'package:sm_store/state.dart';
import 'package:sm_store/ui/theme.dart';
import 'package:sm_store/ui/widgets.dart';

/// Первая настройка: где склад дистрибьютора. От этой точки считаются
/// расстояния до магазинов и «магазины рядом» на карте.
class PointSetupScreen extends StatefulWidget {
  const PointSetupScreen({super.key});

  @override
  State<PointSetupScreen> createState() => _PointSetupScreenState();
}

class _PointSetupScreenState extends State<PointSetupScreen> {
  final _name = TextEditingController();
  final _address = TextEditingController();
  final _phone = TextEditingController(text: '+998 ');
  LatLng? _point;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _name.text = context.read<StoreState>().networkName;
  }

  @override
  void dispose() {
    _name.dispose();
    _address.dispose();
    _phone.dispose();
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

  Future<void> _save() async {
    if (_name.text.trim().isEmpty) {
      showMessage(context, tr('Укажите название склада', 'Ombor nomini kiriting'));
      return;
    }
    if (_point == null) {
      showMessage(context, tr('Отметьте склад на карте — от него считаем расстояние до магазинов', 'Omborni xaritada belgilang — doʻkonlargacha masofa undan hisoblanadi'));
      return;
    }
    setState(() => _busy = true);
    final st = context.read<StoreState>();
    try {
      final phone = _phone.text.replaceAll(RegExp(r'[^0-9+]'), '');
      await context.read<Api>().post('/store/stores', {
        'name': _name.text.trim(),
        'address': _address.text.trim(),
        if (phone.length > 5) 'phone': phone,
        'lat': _point!.latitude,
        'lng': _point!.longitude,
      });
      await st.load();
    } catch (e) {
      if (mounted) showMessage(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = _point;
    return Scaffold(
      body: SafeArea(
        child: Column(children: [
          Expanded(
            child: ListView(padding: const EdgeInsets.fromLTRB(16, 16, 16, 16), children: [
          const IconBox(Icons.warehouse_rounded, bg: AppColors.primarySoft, fg: AppColors.primary, size: 56, iconSize: 30, radius: 18),
          const SizedBox(height: 16),
          Text(tr('Где ваш склад?', 'Omboringiz qayerda?'), style: AppText.h2),
          const SizedBox(height: 6),
          Text(tr('Покажем магазины рядом со складом и расстояние до каждого. Покупатели ваш склад не видят.',
              'Ombor yonidagi doʻkonlarni va har biriga masofani koʻrsatamiz. Xaridorlar omboringizni koʻrmaydi.'), style: AppText.small),
          const SizedBox(height: 20),
          TextField(controller: _name, decoration: InputDecoration(labelText: tr('Название склада', 'Ombor nomi'))),
          const SizedBox(height: 12),
          AppCard(
            onTap: _pick,
            child: Row(children: [
              IconBox(Icons.place_rounded, bg: p == null ? AppColors.primarySoft : AppColors.successSoft, fg: p == null ? AppColors.primary : AppColors.successInk),
              const SizedBox(width: 12),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(tr('Точка на карте *', 'Xaritadagi nuqta *'), style: AppText.small),
                  Text(p == null ? tr('Отметить', 'Belgilash') : tr('Отмечено', 'Belgilangan'),
                      style: AppText.bodyStrong.copyWith(color: p == null ? AppColors.primary : AppColors.ink)),
                ]),
              ),
              const Icon(Icons.chevron_right_rounded, color: AppColors.muted),
            ]),
          ),
          const SizedBox(height: 12),
          TextField(controller: _address, decoration: InputDecoration(labelText: tr('Адрес', 'Manzil'))),
          const SizedBox(height: 12),
          TextField(controller: _phone, keyboardType: TextInputType.phone, decoration: InputDecoration(labelText: tr('Телефон для магазинов', 'Doʻkonlar uchun telefon'))),
            ]),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
            child: BigButton(label: tr('Готово — войти в приложение', 'Tayyor — ilovaga kirish'), icon: Icons.check_rounded, busy: _busy, onPressed: _save),
          ),
        ]),
      ),
    );
  }
}
