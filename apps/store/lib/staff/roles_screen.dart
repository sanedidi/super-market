import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:sm_core/sm_core.dart';

import '../plan/plan_ui.dart';
import '../ui/theme.dart';
import '../ui/widgets.dart';
import 'staff_logic.dart';
import 'staff_ui.dart';

/// С6 · Роли и права: сколько прав и у скольких сотрудников; «+» — новая
/// роль. Роль владельца — все права, не меняется.
class RolesScreen extends StatefulWidget {
  const RolesScreen({super.key});

  @override
  State<RolesScreen> createState() => _RolesScreenState();
}

class _RolesScreenState extends State<RolesScreen> {
  List<Map<String, dynamic>>? _roles;
  Map<String, int> _count = const {};
  Map<String, List<String>> _names = const {};
  Object? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final api = context.read<Api>();
    try {
      final res = await Future.wait([api.list('/store/roles', {'limit': 200}), api.list('/store/employees', {'limit': 500})]);
      final count = <String, int>{};
      final names = <String, List<String>>{};
      for (final e in res[1]) {
        if (e['status'] != 'active') continue;
        final r = '${e['role_id']}';
        count[r] = (count[r] ?? 0) + 1;
        (names[r] ??= []).add('${e['full_name']}');
      }
      if (!mounted) return;
      setState(() {
        _roles = res[0];
        _count = count;
        _names = names;
        _error = null;
      });
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  Future<void> _open([Map<String, dynamic>? r]) async {
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => RoleScreen(role: r, staff: r == null ? const [] : (_names['${r['id']}'] ?? const [])),
    ));
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final roles = _roles;
    return Scaffold(
      appBar: AppBar(
        title: Text(tr('Роли и права', 'Rollar va huquqlar')),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: IconButton.filled(
              onPressed: () => _open(),
              icon: const Icon(Icons.add_rounded),
              style: IconButton.styleFrom(backgroundColor: AppColors.primary, foregroundColor: AppColors.white),
              tooltip: tr('Новая роль', 'Yangi rol'),
            ),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 32), children: [
          if (_error != null && roles == null)
            ErrorView(error: _error, onRetry: _load)
          else if (roles == null)
            const Padding(padding: EdgeInsets.only(top: 40), child: Center(child: CircularProgressIndicator()))
          else
            AppCard(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
              child: Column(children: [
                for (final (i, r) in roles.indexed) ...[
                  if (i > 0) const Divider(height: 1, indent: 68, color: AppColors.line),
                  ListTile(
                    leading: r['is_owner'] == true
                        ? const IconBox(Icons.workspace_premium_rounded, bg: AppColors.warningSoft, fg: AppColors.warningInk, size: 40, iconSize: 22, radius: 12)
                        : const IconBox(Icons.badge_outlined, size: 40, iconSize: 22, radius: 12),
                    title: Text('${r['name']}', style: AppText.bodyStrong),
                    subtitle: Text(
                      '${r['is_owner'] == true ? tr('все права', 'barcha huquqlar') : rightsCount(((r['permissions'] as List?) ?? const []).length)} · ${staffCount(_count['${r['id']}'] ?? 0)}',
                      style: AppText.small,
                    ),
                    trailing: r['is_owner'] == true
                        ? const Icon(Icons.lock_outline_rounded, size: 18, color: AppColors.muted)
                        : const Icon(Icons.chevron_right_rounded, color: AppColors.muted),
                    onTap: r['is_owner'] == true ? null : () => _open(r),
                  ),
                ],
              ]),
            ),
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(color: AppColors.blueSoft, borderRadius: BorderRadius.circular(16)),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Icon(Icons.info_outline_rounded, size: 18, color: AppColors.blue),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  tr('Права роли сразу действуют у всех сотрудников с этой ролью — в приложениях, в панели и на кассах.',
                      'Rol huquqlari shu roldagi barcha xodimlarda darhol amal qiladi — ilovalarda, panelda va kassalarda.'),
                  style: AppText.small.copyWith(color: AppColors.ink),
                ),
              ),
            ]),
          ),
        ]),
      ),
    );
  }
}

/// С7 · Роль: название и права переключателями по группам. [role] == null —
/// новая роль; после сохранения экран закрывается и возвращает роль.
class RoleScreen extends StatefulWidget {
  const RoleScreen({super.key, this.role, this.staff = const []});

  final Map<String, dynamic>? role;
  // Сотрудники с этой ролью (имена).
  final List<String> staff;

  @override
  State<RoleScreen> createState() => _RoleScreenState();
}

class _RoleScreenState extends State<RoleScreen> {
  late final _name = TextEditingController(text: '${widget.role?['name'] ?? ''}');
  late final Set<String> _perms = {...((widget.role?['permissions'] as List?) ?? const []).map((e) => '$e')};
  List<Map<String, dynamic>>? _all;
  Object? _error;
  bool _busy = false;

  bool get _isNew => widget.role == null;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final all = await context.read<Api>().list('/store/permissions');
      if (mounted) setState(() => _all = all);
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  Future<void> _save() async {
    final name = _name.text.trim();
    if (name.isEmpty) {
      snack(context, tr('Введите название роли', 'Rol nomini kiriting'));
      return;
    }
    setState(() => _busy = true);
    final api = context.read<Api>();
    final body = {'name': name, 'permissions': _perms.toList()};
    try {
      final r = _isNew ? await api.post('/store/roles', body) : await api.patch('/store/roles/${widget.role!['id']}', body);
      if (!mounted) return;
      snack(context, tr('Роль сохранена', 'Rol saqlandi'));
      Navigator.of(context).pop(r is Map<String, dynamic> ? r : null);
    } on ApiError catch (e) {
      if (!mounted) return;
      if (e.isPlan) {
        await showPlanSheet(context, error: e);
      } else {
        snack(context, e.message);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _delete() async {
    if (widget.staff.isNotEmpty) {
      await infoSheet(
        context,
        title: tr('Роль занята', 'Rol band'),
        text: tr('У роли есть сотрудники: ${widget.staff.join(', ')}. Сначала назначьте им другую роль.',
            'Bu rolda xodimlar bor: ${widget.staff.join(', ')}. Avval ularga boshqa rol bering.'),
        icon: Icons.badge_outlined,
      );
      return;
    }
    final ok = await confirmSheet(
      context,
      title: tr('Удалить роль «${widget.role!['name']}»?', '«${widget.role!['name']}» roli oʻchirilsinmi?'),
      confirm: tr('Удалить', 'Oʻchirish'),
      icon: Icons.delete_outline_rounded,
    );
    if (!ok || !mounted) return;
    setState(() => _busy = true);
    try {
      await context.read<Api>().delete('/store/roles/${widget.role!['id']}');
      if (!mounted) return;
      snack(context, tr('Роль удалена', 'Rol oʻchirildi'));
      Navigator.of(context).pop();
    } on ApiError catch (e) {
      if (mounted) snack(context, e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final all = _all;
    return Scaffold(
      appBar: AppBar(title: Text(_isNew ? tr('Новая роль', 'Yangi rol') : '${widget.role!['name']}')),
      body: Column(children: [
        Expanded(
          child: ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 16), children: [
            TextField(
              controller: _name,
              autofocus: _isNew,
              textCapitalization: TextCapitalization.sentences,
              decoration: InputDecoration(labelText: tr('Название роли *', 'Rol nomi *'), hintText: tr('например, Кассир', 'masalan, Kassir')),
            ),
            if (widget.staff.isNotEmpty) ...[
              const SizedBox(height: 6),
              Text(tr('${staffCount(widget.staff.length)}: ${widget.staff.join(', ')}', '${staffCount(widget.staff.length)}: ${widget.staff.join(', ')}'), style: AppText.small),
            ],
            const SizedBox(height: 8),
            if (all == null)
              _error != null
                  ? ErrorView(error: _error, onRetry: _load)
                  : const Padding(padding: EdgeInsets.only(top: 40), child: Center(child: CircularProgressIndicator()))
            else
              for (final (group, items) in groupPermissions(all)) ...[
                Padding(padding: const EdgeInsets.fromLTRB(4, 14, 4, 6), child: Text(group.toUpperCase(), style: AppText.caption)),
                AppCard(
                  padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                  child: Column(children: [
                    for (final p in items)
                      SwitchListTile(
                        dense: true,
                        value: _perms.contains('${p['code']}'),
                        activeTrackColor: AppColors.success,
                        onChanged: (v) => setState(() => v ? _perms.add('${p['code']}') : _perms.remove('${p['code']}')),
                        title: Text('${p['title']}', style: AppText.body),
                      ),
                  ]),
                ),
              ],
          ]),
        ),
        SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              BigButton(label: tr('Сохранить · ${rightsCount(_perms.length)}', 'Saqlash · ${rightsCount(_perms.length)}'), busy: _busy, onPressed: _save),
              if (!_isNew)
                TextButton.icon(
                  onPressed: _busy ? null : _delete,
                  icon: const Icon(Icons.delete_outline_rounded, color: AppColors.primary, size: 18),
                  label: Text(tr('Удалить роль', 'Rolni oʻchirish'), style: AppText.bodyStrong.copyWith(color: AppColors.primary)),
                ),
            ]),
          ),
        ),
      ]),
    );
  }
}
