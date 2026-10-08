import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:sm_core/sm_core.dart';
import 'package:url_launcher/url_launcher.dart';

import '../state.dart';
import '../ui/theme.dart';
import '../ui/widgets.dart';

/// Сотрудники магазина: кто работает, роль, отключить, добавить нового.
/// Роли и права настраиваются в панели магазина.
class StaffScreen extends StatefulWidget {
  const StaffScreen({super.key});

  @override
  State<StaffScreen> createState() => _StaffScreenState();
}

/// Есть ли у сотрудника доступ к магазину.
bool worksIn(Map<String, dynamic> e, String? storeId) =>
    e['all_stores'] == true || ((e['store_ids'] as List?) ?? const []).contains(storeId);

class _StaffScreenState extends State<StaffScreen> {
  List<Map<String, dynamic>>? _staff;
  List<Map<String, dynamic>> _roles = const [];
  bool _showOff = false;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final api = context.read<Api>();
    try {
      final res = await Future.wait([api.list('/store/employees'), api.list('/store/roles')]);
      if (!mounted) return;
      setState(() {
        _staff = res[0];
        _roles = res[1];
        _error = null;
      });
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  Future<void> _edit([Map<String, dynamic>? e]) async {
    final done = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      backgroundColor: AppColors.white,
      builder: (_) => _EmployeeSheet(employee: e, roles: _roles),
    );
    if (done == true) await _load();
  }

  @override
  Widget build(BuildContext context) {
    final st = context.watch<StoreState>();
    final all = [for (final e in _staff ?? const <Map<String, dynamic>>[]) if (worksIn(e, st.storeId)) e];
    final active = all.where((e) => e['status'] == 'active').toList();
    final off = all.where((e) => e['status'] != 'active').toList();
    final list = _showOff ? off : active;
    return Scaffold(
      appBar: AppBar(title: Text(tr('Сотрудники', 'Xodimlar'))),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _roles.isEmpty ? null : () => _edit(),
        backgroundColor: AppColors.primary,
        foregroundColor: AppColors.white,
        icon: const Icon(Icons.person_add_alt_1_rounded),
        label: Text(tr('Добавить', 'Qoʻshish')),
      ),
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 96), children: [
          Wrap(spacing: 8, children: [
            for (final (i, title) in [(false, tr('Работают · ${active.length}', 'Ishlaydi · ${active.length}')), (true, tr('Отключены · ${off.length}', 'Oʻchirilgan · ${off.length}'))])
              ChoiceChip(
                label: Text(title),
                selected: _showOff == i,
                showCheckmark: false,
                selectedColor: AppColors.primarySoft,
                labelStyle: AppText.bodyStrong.copyWith(color: _showOff == i ? AppColors.primary : AppColors.ink),
                onSelected: (_) => setState(() => _showOff = i),
              ),
          ]),
          const SizedBox(height: 12),
          if (_error != null && _staff == null)
            EmptyState(icon: Icons.wifi_off_rounded, title: tr('Не удалось загрузить', 'Yuklab boʻlmadi'), text: '$_error', action: tr('Повторить', 'Qayta urinish'), onAction: _load)
          else if (_staff == null)
            const Padding(padding: EdgeInsets.only(top: 40), child: Center(child: CircularProgressIndicator()))
          else if (list.isEmpty)
            EmptyState(icon: Icons.people_outline_rounded, title: _showOff ? tr('Отключённых нет', 'Oʻchirilganlar yoʻq') : tr('Сотрудников пока нет', 'Hozircha xodimlar yoʻq'))
          else
            AppCard(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
              child: Column(children: [
                for (final e in list)
                  ListTile(
                    onTap: e['is_owner'] == true ? null : () => _edit(e),
                    leading: CircleAvatar(
                      backgroundColor: e['is_owner'] == true ? AppColors.primarySoft : AppColors.soft,
                      foregroundColor: e['is_owner'] == true ? AppColors.primary : AppColors.ink,
                      child: Text(_initials('${e['full_name']}'), style: const TextStyle(fontWeight: FontWeight.w600)),
                    ),
                    title: Text('${e['full_name']}', style: AppText.bodyStrong),
                    subtitle: Text(
                      '${e['role_name']} · ${formatPhone(e['phone'])}\n'
                      '${(e['login'] as String?)?.isNotEmpty == true ? tr('логин ${e['login']}', 'login ${e['login']}') : tr('нет входа — выдайте логин в панели', 'kirish yoʻq — panelda login bering')}',
                      style: AppText.small,
                    ),
                    isThreeLine: true,
                    trailing: IconButton(
                      icon: const Icon(Icons.call_rounded, color: AppColors.successInk),
                      onPressed: () => launchUrl(Uri.parse('tel:${e['phone']}')),
                    ),
                  ),
              ]),
            ),
          const SizedBox(height: 12),
          Text(tr('Роли, права и логины для входа настраиваются в панели магазина.', 'Rollar, huquqlar va kirish loginlari doʻkon panelida sozlanadi.'), style: AppText.small, textAlign: TextAlign.center),
        ]),
      ),
    );
  }
}

String _initials(String name) {
  final parts = name.trim().split(RegExp(r'\s+')).where((p) => p.isNotEmpty).toList();
  if (parts.isEmpty) return '?';
  return parts.take(2).map((p) => p.characters.first.toUpperCase()).join();
}

class _EmployeeSheet extends StatefulWidget {
  const _EmployeeSheet({required this.employee, required this.roles});

  final Map<String, dynamic>? employee;
  final List<Map<String, dynamic>> roles;

  @override
  State<_EmployeeSheet> createState() => _EmployeeSheetState();
}

class _EmployeeSheetState extends State<_EmployeeSheet> {
  late final _name = TextEditingController(text: '${widget.employee?['full_name'] ?? ''}');
  final _phone = TextEditingController();
  late String? _roleId = widget.employee?['role_id'] as String?;
  late bool _active = (widget.employee?['status'] ?? 'active') == 'active';
  bool _busy = false;
  String? _error;

  List<Map<String, dynamic>> get _roles => [for (final r in widget.roles) if (r['is_owner'] != true) r];

  @override
  void dispose() {
    _name.dispose();
    _phone.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final e = widget.employee;
    final String? err = _name.text.trim().isEmpty
        ? tr('Укажите имя', 'Ismni kiriting')
        : _roleId == null
            ? tr('Выберите роль', 'Rolni tanlang')
            : e == null && normalizeUzPhone(_phone.text) == null
                ? tr('Введите номер полностью: 9 цифр после +998', 'Raqamni toʻliq kiriting: +998 dan keyin 9 ta raqam')
                : null;
    if (err != null) {
      setState(() => _error = err);
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    final api = context.read<Api>();
    final storeId = context.read<StoreState>().storeId;
    try {
      if (e == null) {
        await api.post('/store/employees', {
          'phone': normalizeUzPhone(_phone.text),
          'full_name': _name.text.trim(),
          'role_id': _roleId,
          'store_ids': [storeId],
        });
      } else {
        await api.patch('/store/employees/${e['id']}', {
          'full_name': _name.text.trim(),
          'role_id': _roleId,
          'status': _active ? 'active' : 'inactive',
        });
      }
      if (!mounted) return;
      final messenger = ScaffoldMessenger.of(context);
      Navigator.of(context).pop(true);
      messenger.showSnackBar(SnackBar(content: Text(e == null
          ? tr('Сотрудник добавлен. Логин и пароль для входа выдайте в панели магазина → Сотрудники', 'Xodim qoʻshildi. Kirish uchun login va parolni doʻkon panelida bering → Xodimlar')
          : tr('Сохранено', 'Saqlandi'))));
    } catch (ex) {
      if (mounted) setState(() => _error = ex.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final e = widget.employee;
    return Padding(
      padding: EdgeInsets.fromLTRB(16, 0, 16, 16 + MediaQuery.of(context).viewInsets.bottom),
      child: SafeArea(
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(e == null ? tr('Новый сотрудник', 'Yangi xodim') : '${e['full_name']}', style: AppText.h3),
            if (e != null) Text(formatPhone(e['phone']), style: AppText.small),
            const SizedBox(height: 16),
            if (e == null) ...[
              PhoneField(controller: _phone, label: tr('Телефон', 'Telefon'), autofocus: true),
              const SizedBox(height: 12),
            ],
            TextField(controller: _name, textCapitalization: TextCapitalization.words, decoration: InputDecoration(labelText: tr('Имя и фамилия', 'Ism va familiya'))),
            const SizedBox(height: 16),
            Text(tr('РОЛЬ', 'ROL'), style: AppText.caption),
            const SizedBox(height: 8),
            Wrap(spacing: 8, runSpacing: 8, children: [
              for (final r in _roles)
                ChoiceChip(
                  label: Text('${r['name']}'),
                  selected: _roleId == r['id'],
                  showCheckmark: false,
                  selectedColor: AppColors.primarySoft,
                  labelStyle: AppText.bodyStrong.copyWith(color: _roleId == r['id'] ? AppColors.primary : AppColors.ink),
                  onSelected: (_) => setState(() => _roleId = r['id'] as String),
                ),
            ]),
            if (e != null) ...[
              const SizedBox(height: 12),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                value: _active,
                onChanged: (v) => setState(() => _active = v),
                title: Text(tr('Работает', 'Ishlaydi'), style: AppText.bodyStrong),
                subtitle: Text(tr('Отключённый сотрудник сразу выходит из всех приложений', 'Oʻchirilgan xodim barcha ilovalardan darhol chiqariladi'), style: AppText.small),
              ),
            ],
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(_error!, style: AppText.small.copyWith(color: AppColors.error)),
            ],
            const SizedBox(height: 20),
            BigButton(label: e == null ? tr('Добавить', 'Qoʻshish') : tr('Сохранить', 'Saqlash'), busy: _busy, onPressed: _save),
          ]),
        ),
      ),
    );
  }
}
