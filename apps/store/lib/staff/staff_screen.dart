import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:sm_core/sm_core.dart';

import '../plan/plan_ui.dart';
import '../state.dart';
import '../ui/theme.dart';
import '../ui/widgets.dart';
import 'employee_screen.dart';
import 'roles_screen.dart';
import 'staff_logic.dart';
import 'staff_ui.dart';

export 'staff_logic.dart' show worksIn;

/// С2 · Сотрудники: роль, ПИН для кассы, вход в приложение; «+» — новый
/// сотрудник (С3), внизу — «Роли и права» (С6).
class StaffScreen extends StatefulWidget {
  const StaffScreen({super.key});

  @override
  State<StaffScreen> createState() => _StaffScreenState();
}

class _StaffScreenState extends State<StaffScreen> {
  List<Map<String, dynamic>>? _staff;
  List<Map<String, dynamic>> _roles = const [];
  // У кого есть ПИН для кассы (employee_id).
  Set<String> _pins = const {};
  bool _showOff = false;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final api = context.read<Api>();
    final storeId = context.read<StoreState>().storeId;
    try {
      final res = await Future.wait([
        api.list('/store/employees', {'limit': 500}),
        api.list('/store/roles', {'limit': 200}),
        api.list('/store/pos/pins', {if (storeId != null) 'store_id': storeId}).catchError((_) => <Map<String, dynamic>>[]),
      ]);
      if (!mounted) return;
      setState(() {
        _staff = res[0];
        _roles = res[1];
        _pins = {for (final p in res[2]) if (p['has_pin'] == true) '${p['employee_id']}'};
        _error = null;
      });
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  Future<void> _add() async {
    final created = await showSheet<Map<String, dynamic>>(context, (_) => NewEmployeeSheet(roles: _roles));
    await _load();
    if (created == null || !mounted) return;
    // С4: логин и временный пароль — сразу.
    await showSheet<void>(context, (_) => EmployeeAddedSheet(result: created));
  }

  Future<void> _open(Map<String, dynamic> e) async {
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => EmployeeScreen(employee: e, roles: _roles, hasPin: _pins.contains('${e['id']}'))));
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final st = context.watch<StoreState>();
    final all = [
      for (final e in _staff ?? const <Map<String, dynamic>>[])
        if (worksIn(e, st.storeId)) e,
    ];
    final active = all.where((e) => e['status'] == 'active').toList();
    final off = all.where((e) => e['status'] != 'active').toList();
    final list = _showOff ? off : active;
    final roleNames = [
      for (final r in _roles) '${r['name']}',
    ];
    return Scaffold(
      appBar: AppBar(
        title: Text(tr('Сотрудники', 'Xodimlar')),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: IconButton.filled(
              onPressed: _staff == null ? null : _add,
              icon: const Icon(Icons.person_add_alt_1_rounded),
              style: IconButton.styleFrom(backgroundColor: AppColors.primary, foregroundColor: AppColors.white),
              tooltip: tr('Новый сотрудник', 'Yangi xodim'),
            ),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 32), children: [
          Wrap(spacing: 8, children: [
            for (final (i, title) in [(false, tr('Работают · ${active.length}', 'Ishlaydi · ${active.length}')), (true, tr('Отключены · ${off.length}', 'Oʻchirilgan · ${off.length}'))])
              ChoiceChip(
                label: Text(title),
                selected: _showOff == i,
                showCheckmark: false,
                selectedColor: AppColors.ink,
                labelStyle: AppText.bodyStrong.copyWith(color: _showOff == i ? AppColors.white : AppColors.ink, fontSize: 13),
                onSelected: (_) => setState(() => _showOff = i),
              ),
          ]),
          const SizedBox(height: 12),
          if (_error != null && _staff == null)
            ErrorView(error: _error, onRetry: _load)
          else if (_staff == null)
            const Padding(padding: EdgeInsets.only(top: 40), child: Center(child: CircularProgressIndicator()))
          else if (list.isEmpty)
            EmptyState(icon: Icons.people_outline_rounded, title: _showOff ? tr('Отключённых нет', 'Oʻchirilganlar yoʻq') : tr('Сотрудников пока нет', 'Hozircha xodimlar yoʻq'))
          else
            AppCard(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
              child: Column(children: [
                for (final (i, e) in list.indexed) ...[
                  if (i > 0) const Divider(height: 1, indent: 72, color: AppColors.line),
                  _EmployeeTile(e: e, hasPin: _pins.contains('${e['id']}'), onTap: () => _open(e)),
                ],
              ]),
            ),
          const SizedBox(height: 12),
          AppCard(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: ListTile(
              leading: const IconBox(Icons.admin_panel_settings_outlined, size: 36, iconSize: 20, radius: 10),
              title: Text(tr('Роли и права', 'Rollar va huquqlar'), style: AppText.bodyStrong),
              subtitle: Text(roleNames.isEmpty ? tr('Кто что может делать', 'Kim nima qila oladi') : roleNames.join(', '),
                  style: AppText.small, maxLines: 1, overflow: TextOverflow.ellipsis),
              trailing: const Icon(Icons.chevron_right_rounded, color: AppColors.muted),
              onTap: () async {
                await Navigator.of(context).push(MaterialPageRoute(builder: (_) => const RolesScreen()));
                await _load();
              },
            ),
          ),
        ]),
      ),
    );
  }
}

class _EmployeeTile extends StatelessWidget {
  const _EmployeeTile({required this.e, required this.hasPin, required this.onTap});

  final Map<String, dynamic> e;
  final bool hasPin;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final owner = e['is_owner'] == true;
    final login = '${e['login'] ?? ''}';
    return ListTile(
      onTap: onTap,
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      leading: CircleAvatar(
        radius: 22,
        backgroundColor: owner ? AppColors.warningSoft : AppColors.soft,
        foregroundColor: owner ? AppColors.warningInk : AppColors.ink,
        child: Text(initials('${e['full_name']}'), style: const TextStyle(fontWeight: FontWeight.w700)),
      ),
      title: Text('${e['full_name']}', style: AppText.bodyStrong),
      subtitle: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(owner ? tr('Владелец · все права', 'Egasi · barcha huquqlar') : '${e['role_name']}', style: AppText.small),
        const SizedBox(height: 4),
        Wrap(spacing: 4, runSpacing: 4, children: [
          hasPin ? StatusChip(tr('ПИН', 'PIN'), tone: ChipTone.green) : StatusChip(tr('нет ПИНа', 'PIN yoʻq'), tone: ChipTone.red),
          login.isEmpty
              ? StatusChip(tr('без входа', 'kirishsiz'))
              : StatusChip(tr('вход · $login', 'kirish · $login'), tone: ChipTone.green),
        ]),
      ]),
      trailing: const Icon(Icons.chevron_right_rounded, color: AppColors.muted),
    );
  }
}

/// С3 · Новый сотрудник: телефон, имя, роль (+ новая роль), ПИН для кассы,
/// вход в «SM Сотрудник». Возвращает {employee, login?, pin_error?}.
class NewEmployeeSheet extends StatefulWidget {
  const NewEmployeeSheet({super.key, required this.roles});

  final List<Map<String, dynamic>> roles;

  @override
  State<NewEmployeeSheet> createState() => _NewEmployeeSheetState();
}

class _NewEmployeeSheetState extends State<NewEmployeeSheet> {
  final _name = TextEditingController();
  final _phone = TextEditingController();
  final _pin = TextEditingController();
  late List<Map<String, dynamic>> _roles = [
    for (final r in widget.roles)
      if (r['is_owner'] != true) r,
  ];
  String? _roleId;
  bool _withLogin = true;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    _phone.dispose();
    _pin.dispose();
    super.dispose();
  }

  Future<void> _newRole() async {
    final role = await Navigator.of(context).push<Map<String, dynamic>>(MaterialPageRoute(builder: (_) => const RoleScreen()));
    if (role == null || !mounted) return;
    setState(() {
      _roles = [..._roles, role];
      _roleId = '${role['id']}';
    });
  }

  Future<void> _save() async {
    final pin = _pin.text.trim();
    final phone = normalizeUzPhone(_phone.text);
    final String? err = phone == null
        ? tr('Введите номер полностью: 9 цифр после +998', 'Raqamni toʻliq kiriting: +998 dan keyin 9 ta raqam')
        : _name.text.trim().isEmpty
            ? tr('Укажите имя', 'Ismni kiriting')
            : _roleId == null
                ? tr('Выберите роль', 'Rolni tanlang')
                : pin.isNotEmpty && !validPin(pin)
                    ? tr('ПИН — ровно 4 цифры', 'PIN — aynan 4 ta raqam')
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
      final e = await api.post('/store/employees', {
        'phone': phone,
        'full_name': _name.text.trim(),
        'role_id': _roleId,
        if (storeId != null) 'store_ids': [storeId],
      }) as Map<String, dynamic>;
      final out = <String, dynamic>{'employee': e};
      // Сотрудник уже добавлен: ошибки ПИНа и входа показываем, но не теряем его.
      if (pin.isNotEmpty) {
        try {
          await api.put('/store/pos/pins/${e['id']}', {'pin': pin});
          out['pin_set'] = true;
        } on ApiError catch (pe) {
          out['pin_error'] = pe.message;
        }
      }
      if (_withLogin) {
        try {
          out['login'] = await api.put('/store/employees/${e['id']}/login', {'generate_password': true});
        } on ApiError catch (le) {
          out['login_error'] = le.message;
        }
      }
      if (mounted) Navigator.of(context).pop(out);
    } on ApiError catch (ex) {
      if (!mounted) return;
      if (ex.isPlan) {
        await showPlanSheet(context, error: ex);
      } else {
        setState(() => _error = ex.message);
      }
    } catch (ex) {
      if (mounted) setState(() => _error = '$ex');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Text(tr('Новый сотрудник', 'Yangi xodim'), style: AppText.h3),
      const SizedBox(height: 16),
      PhoneField(controller: _phone, label: tr('Телефон *', 'Telefon *'), autofocus: true),
      const SizedBox(height: 12),
      TextField(controller: _name, textCapitalization: TextCapitalization.words, decoration: InputDecoration(labelText: tr('Имя и фамилия *', 'Ism va familiya *'))),
      const SizedBox(height: 16),
      Text(tr('РОЛЬ *', 'ROL *'), style: AppText.caption),
      const SizedBox(height: 8),
      Wrap(spacing: 8, runSpacing: 8, children: [
        for (final r in _roles)
          ChoiceChip(
            label: Text('${r['name']}'),
            selected: _roleId == r['id'],
            showCheckmark: false,
            selectedColor: AppColors.primarySoft,
            labelStyle: AppText.bodyStrong.copyWith(color: _roleId == r['id'] ? AppColors.primary : AppColors.ink),
            onSelected: (_) => setState(() => _roleId = '${r['id']}'),
          ),
        ActionChip(
          avatar: const Icon(Icons.add_rounded, size: 18, color: AppColors.primary),
          label: Text(tr('Новая роль', 'Yangi rol'), style: AppText.bodyStrong.copyWith(color: AppColors.primary)),
          side: const BorderSide(color: AppColors.primary),
          backgroundColor: AppColors.white,
          onPressed: _newRole,
        ),
      ]),
      const SizedBox(height: 16),
      Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(borderRadius: BorderRadius.circular(14), border: Border.all(color: AppColors.line)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            const Icon(Icons.dialpad_rounded, size: 20),
            const SizedBox(width: 8),
            Expanded(child: Text(tr('ПИН для кассы', 'Kassa uchun PIN'), style: AppText.bodyStrong)),
            Text(tr('4 цифры', '4 ta raqam'), style: AppText.small),
          ]),
          const SizedBox(height: 8),
          TextField(
            controller: _pin,
            keyboardType: TextInputType.number,
            maxLength: 4,
            obscureText: true,
            textAlign: TextAlign.center,
            style: AppText.h3.copyWith(letterSpacing: 12),
            decoration: const InputDecoration(hintText: '••••', counterText: ''),
          ),
          const SizedBox(height: 4),
          Text(tr('Вводит его на кассе при входе. Нужен только тем, кто работает на кассе.', 'Uni kassaga kirishda kiritadi. Faqat kassada ishlaydiganlarga kerak.'),
              style: AppText.small.copyWith(fontSize: 12)),
        ]),
      ),
      const SizedBox(height: 12),
      Container(
        padding: const EdgeInsets.fromLTRB(14, 6, 6, 6),
        decoration: BoxDecoration(borderRadius: BorderRadius.circular(14), border: Border.all(color: AppColors.line)),
        child: SwitchListTile(
          contentPadding: EdgeInsets.zero,
          value: _withLogin,
          onChanged: (v) => setState(() => _withLogin = v),
          secondary: const Icon(Icons.smartphone_rounded),
          title: Text(tr('Вход в «SM Сотрудник»', '«SM Xodim»ga kirish'), style: AppText.bodyStrong),
          subtitle: Text(tr('Логин и пароль придумаем сами — покажем после «Добавить»', 'Login va parolni oʻzimiz oʻylab topamiz — «Qoʻshish»dan keyin koʻrsatamiz'), style: AppText.small),
        ),
      ),
      if (_error != null) ...[
        const SizedBox(height: 10),
        Text(_error!, style: AppText.small.copyWith(color: AppColors.error)),
      ],
      const SizedBox(height: 20),
      BigButton(label: tr('Добавить', 'Qoʻshish'), busy: _busy, onPressed: _save),
    ]);
  }
}

/// С4 · Сотрудник добавлен: логин и временный пароль для «SM Сотрудник»,
/// задан ли ПИН. [result] — ответ [NewEmployeeSheet].
class EmployeeAddedSheet extends StatelessWidget {
  const EmployeeAddedSheet({super.key, required this.result});

  final Map<String, dynamic> result;

  @override
  Widget build(BuildContext context) {
    final e = (result['employee'] as Map).cast<String, dynamic>();
    final login = (result['login'] as Map?)?.cast<String, dynamic>();
    final store = '${context.read<StoreState>().store?['name'] ?? ''}';
    final name = '${e['full_name']}';
    return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      const Center(child: IconBox(Icons.check_circle_rounded, bg: AppColors.successSoft, fg: AppColors.success, size: 60, iconSize: 36, radius: 30)),
      const SizedBox(height: 12),
      Text(tr('$name добавлен(а)', '$name qoʻshildi'), style: AppText.h3, textAlign: TextAlign.center),
      const SizedBox(height: 16),
      if (login != null && '${login['login'] ?? ''}'.isNotEmpty)
        CredentialsBox(
          header: tr('Вход в «SM Сотрудник»', '«SM Xodim»ga kirish'),
          login: '${login['login']}',
          password: '${login['temp_password'] ?? ''}',
          note: tr('При первом входе придумает свой пароль.', 'Birinchi kirishda oʻz parolini oʻylab topadi.'),
        ),
      if (result['login_error'] != null) _warn(tr('Вход не выдан: ${result['login_error']}', 'Kirish berilmadi: ${result['login_error']}')),
      if (result['pin_set'] == true) ...[
        const SizedBox(height: 12),
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(color: AppColors.successSoft, borderRadius: BorderRadius.circular(14)),
          child: Row(children: [
            const Icon(Icons.dialpad_rounded, color: AppColors.successInk),
            const SizedBox(width: 10),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(tr('ПИН для кассы задан', 'Kassa uchun PIN berildi'), style: AppText.bodyStrong),
                Text(tr('Кассы магазина получат его в течение минуты', 'Doʻkon kassalari uni bir daqiqa ichida oladi'), style: AppText.small),
              ]),
            ),
          ]),
        ),
      ],
      if (result['pin_error'] != null) _warn(tr('ПИН не сохранён: ${result['pin_error']} Задайте его в карточке сотрудника.', 'PIN saqlanmadi: ${result['pin_error']} Uni xodim kartasida bering.')),
      const SizedBox(height: 20),
      if (login != null && '${login['temp_password'] ?? ''}'.isNotEmpty) ...[
        BigButton(
          label: tr('Отправить в Telegram', 'Telegram’da yuborish'),
          icon: Icons.send_rounded,
          onPressed: () => shareTelegram(context, employeeLoginMessage(store, '${login['login']}', '${login['temp_password']}')),
        ),
        const SizedBox(height: 10),
      ],
      SheetButton(label: tr('Готово', 'Tayyor'), primary: false, onPressed: () => Navigator.of(context).pop()),
    ]);
  }

  Widget _warn(String text) => Padding(
        padding: const EdgeInsets.only(top: 12),
        child: Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(color: AppColors.warningSoft, borderRadius: BorderRadius.circular(14)),
          child: Text(text, style: AppText.small.copyWith(color: AppColors.warningInk)),
        ),
      );
}
