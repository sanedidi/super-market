import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:sm_core/sm_core.dart';

import '../family_ui.dart';
import '../main.dart';
import '../state.dart';
import '../ui/theme.dart';
import '../ui/widgets.dart';
import 'root_shell.dart' show itemsWord;

/// Строка будущей просьбы: товар каталога или текст.
class _Line {
  _Line({this.productId, required this.name, this.unit = '', this.fractional = false});
  final String? productId;
  final String name;
  final String unit;
  final bool fractional;
  num qty = 1;

  Map<String, dynamic> toJson() => {
        if (productId != null) 'product_id': productId,
        if (productId == null) 'text': name,
        'qty': qty.toString(),
      };
}

enum _When { now, today18, tomorrow8 }

/// «Попросить купить» по макету Figma: кого попросить, что купить (поиск по
/// каталогу или своими словами, частые покупки), когда напомнить,
/// комментарий, предложение доставки, если не купит.
class FamilyAskScreen extends StatefulWidget {
  const FamilyAskScreen({super.key, this.assigneeId});
  final String? assigneeId;

  @override
  State<FamilyAskScreen> createState() => _FamilyAskScreenState();
}

class _FamilyAskScreenState extends State<FamilyAskScreen> {
  final _search = TextEditingController();
  final _comment = TextEditingController();
  final _lines = <_Line>[];
  List<Map<String, dynamic>> _found = [];
  List<Map<String, dynamic>> _suggestions = [];
  Timer? _debounce;
  int _gen = 0;

  /// null — всей семье.
  String? _assignee;
  _When _when = _When.today18;
  bool _atStore = false;
  bool _offer = true;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    final f = context.read<AppState>().family;
    final others = _others(f);
    _assignee = widget.assigneeId ?? (others.length == 1 ? others.first['user_id'] as String : null);
    if (DateTime.now().hour >= 18) _when = _When.now;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      try {
        final s = await context.read<Api>().list('/client/family/suggestions');
        if (mounted) setState(() => _suggestions = s);
      } catch (_) {
        // Подсказки не обязательны.
      }
    });
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _search.dispose();
    _comment.dispose();
    super.dispose();
  }

  List<Map<String, dynamic>> _others(Map<String, dynamic>? f) =>
      ((f?['members'] as List?) ?? const []).cast<Map<String, dynamic>>().where((m) => m['is_me'] != true).toList();

  // ------------------------------------------------------------ товары

  void _onSearch(String q) {
    setState(() {});
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 300), () => _find(q.trim()));
  }

  Future<void> _find(String q) async {
    final store = context.read<AppState>().catalogStore;
    final gen = ++_gen;
    if (q.length < 2 || store == null) {
      setState(() => _found = []);
      return;
    }
    try {
      final items = await context.read<Api>().list('/client/stores/${store.id}/products', {'q': q, 'limit': 6});
      if (mounted && gen == _gen) setState(() => _found = items);
    } catch (_) {
      if (mounted && gen == _gen) setState(() => _found = []);
    }
  }

  void _add(_Line l) {
    final same = _lines.where((x) => l.productId != null ? x.productId == l.productId : x.productId == null && x.name.toLowerCase() == l.name.toLowerCase());
    setState(() {
      if (same.isNotEmpty) {
        same.first.qty += same.first.fractional ? 0.5 : 1;
      } else if (_lines.length < 50) {
        _lines.add(l);
      }
      _search.clear();
      _found = [];
    });
  }

  void _addText() {
    final t = _search.text.trim();
    if (t.isEmpty) return;
    _add(_Line(name: t.length > 100 ? t.substring(0, 100) : t));
  }

  void _addProduct(Map<String, dynamic> p) => _add(_Line(
        productId: p['id'] as String,
        name: p['name'] as String,
        unit: (p['unit_short'] as String?) ?? '',
        fractional: p['is_fractional'] == true,
      ));

  Future<void> _editQty(_Line l) async {
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppColors.white,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, set) {
          final step = l.fractional ? 0.5 : 1;
          void change(num d) {
            final v = l.qty + d;
            if (v <= 0) return;
            set(() => l.qty = v);
            setState(() {});
          }

          return SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
              child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Text(l.name, style: AppText.title),
                const SizedBox(height: 16),
                Center(
                  child: QtyStepper(
                    height: 48,
                    label: qty(l.qty, l.unit.isEmpty ? 'шт' : l.unit),
                    onMinus: () => change(-step),
                    onPlus: () => change(step),
                  ),
                ),
                const SizedBox(height: 16),
                AppButton(label: 'Готово', onPressed: () => Navigator.pop(ctx)),
              ]),
            ),
          );
        },
      ),
    );
  }

  // ------------------------------------------------------------ время

  DateTime? get _remindAt {
    final now = DateTime.now();
    return switch (_when) {
      _When.now => null,
      _When.today18 => DateTime(now.year, now.month, now.day, 18),
      _When.tomorrow8 => DateTime(now.year, now.month, now.day + 1, 8),
    };
  }

  /// Предложить доставку через 2 часа после напоминания (не раньше 20:00 для «сегодня»).
  DateTime get _offerAt {
    final base = _remindAt ?? DateTime.now();
    final t = base.add(const Duration(hours: 2));
    return DateTime(t.year, t.month, t.day, t.hour, t.minute < 30 ? 0 : 30);
  }

  // ------------------------------------------------------------ отправка

  Future<void> _send() async {
    if (_lines.isEmpty) {
      showError(context, 'Добавьте хотя бы один товар');
      return;
    }
    setState(() => _busy = true);
    try {
      await context.read<Api>().post('/client/family/requests', {
        'assignee_id': _assignee,
        'comment': _comment.text.trim(),
        if (_remindAt != null) 'remind_at': _remindAt!.toUtc().toIso8601String(),
        'remind_at_store': _atStore,
        if (_offer) 'deliver_offer_at': _offerAt.toUtc().toIso8601String(),
        'items': _lines.map((l) => l.toJson()).toList(),
      });
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Просьба отправлена')));
      Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // ------------------------------------------------------------ экран

  @override
  Widget build(BuildContext context) {
    final f = context.watch<AppState>().family;
    final others = _others(f);
    final assigneeName = others.where((m) => m['user_id'] == _assignee).map(memberName).firstOrNull;
    final notYet = _suggestions.where((s) => !_lines.any((l) => l.productId == s['product_id'])).take(3).toList();

    return Scaffold(
      backgroundColor: AppColors.bg,
      body: SafeArea(
        bottom: false,
        child: Column(children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: Row(children: [
              RoundIconButton(icon: Icons.close_rounded, bg: AppColors.white, onTap: () => Navigator.of(context).pop()),
              const SizedBox(width: 12),
              const Expanded(child: Text('Попросить купить', style: AppText.h3)),
            ]),
          ),
          Expanded(
            child: ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 24), children: [
              const _Label('Кого попросить'),
              SizedBox(
                height: 96,
                child: ListView(scrollDirection: Axis.horizontal, children: [
                  for (final m in others)
                    _PersonTile(
                      avatar: MemberAvatar(id: '${m['user_id']}', name: memberName(m), size: 40),
                      name: memberName(m).split(' ').first,
                      selected: _assignee == m['user_id'],
                      onTap: () => setState(() => _assignee = m['user_id'] as String),
                    ),
                  _PersonTile(
                    avatar: const IconBox(Icons.groups_outlined, size: 40, radius: 20),
                    name: 'Всем',
                    selected: _assignee == null,
                    onTap: () => setState(() => _assignee = null),
                  ),
                ]),
              ),
              const SizedBox(height: 20),
              const _Label('Что купить'),
              TextField(
                controller: _search,
                onChanged: _onSearch,
                onSubmitted: (_) => _addText(),
                textInputAction: TextInputAction.done,
                textCapitalization: TextCapitalization.sentences,
                style: AppText.body,
                decoration: InputDecoration(
                  hintText: 'Товар или своими словами',
                  isDense: true,
                  prefixIcon: const Icon(Icons.search_rounded, color: AppColors.text2),
                  prefixIconConstraints: const BoxConstraints(minWidth: 44, minHeight: 44),
                  contentPadding: const EdgeInsets.symmetric(vertical: 12),
                  suffixIcon: _search.text.trim().isEmpty
                      ? null
                      : IconButton(icon: const Icon(Icons.add_circle_rounded, color: AppColors.primary), onPressed: _addText),
                ),
              ),
              if (_search.text.trim().isNotEmpty) ...[
                const SizedBox(height: 8),
                AppCard(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: Column(children: [
                    for (final p in _found)
                      _FoundRow(
                        name: p['name'] as String,
                        subtitle: money(p['price']),
                        image: ((p['images'] as List?) ?? const []).cast<String>().firstOrNull,
                        onTap: () => _addProduct(p),
                      ),
                    _FoundRow(name: '«${_search.text.trim()}»', subtitle: 'Добавить своими словами', onTap: _addText, last: true),
                  ]),
                ),
              ],
              if (_lines.isNotEmpty) ...[
                const SizedBox(height: 12),
                Wrap(spacing: 8, runSpacing: 8, children: [
                  for (final l in _lines)
                    _ItemChip(
                      label: '${l.name} ${l.unit.isNotEmpty && l.unit != 'шт' ? qty(l.qty, l.unit) : '×${qty(l.qty)}'}',
                      onTap: () => _editQty(l),
                      onRemove: () => setState(() => _lines.remove(l)),
                    ),
                ]),
              ],
              if (notYet.isNotEmpty) ...[
                const SizedBox(height: 12),
                InkWell(
                  onTap: () {
                    for (final s in notYet) {
                      _add(_Line(productId: s['product_id'] as String, name: s['name'] as String));
                    }
                  },
                  child: Row(children: [
                    const Icon(Icons.add_rounded, size: 20, color: AppColors.ink),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text('Часто покупаете: ${notYet.map((s) => '${s['name']}'.toLowerCase()).join(', ')}',
                          maxLines: 2, overflow: TextOverflow.ellipsis, style: AppText.smallStrong.copyWith(color: AppColors.primary, fontWeight: FontWeight.w500)),
                    ),
                  ]),
                ),
              ],
              const SizedBox(height: 20),
              const _Label('Когда напомнить'),
              Wrap(spacing: 8, runSpacing: 8, children: [
                if (DateTime.now().hour < 18)
                  AppChip(label: 'Сегодня в 18:00', selected: _when == _When.today18, onTap: () => setState(() => _when = _When.today18)),
                AppChip(label: 'Завтра в 8:00', selected: _when == _When.tomorrow8, onTap: () => setState(() => _when = _When.tomorrow8)),
                AppChip(label: 'Рядом с магазином', selected: _atStore, onTap: () => setState(() => _atStore = !_atStore)),
                AppChip(label: 'Сейчас', selected: _when == _When.now, onTap: () => setState(() => _when = _When.now)),
              ]),
              const SizedBox(height: 20),
              const _Label('Комментарий'),
              TextField(
                controller: _comment,
                minLines: 2,
                maxLines: 4,
                maxLength: 500,
                textCapitalization: TextCapitalization.sentences,
                decoration: const InputDecoration(hintText: 'Например: хлеб только бородинский', counterText: '', fillColor: AppColors.white),
              ),
              const SizedBox(height: 16),
              AppCard(
                child: Row(children: [
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text('Если не купит до ${hhmm(_offerAt)}${_offerAt.day != DateTime.now().day ? ' завтра' : ''}', style: AppText.bodyStrong),
                      const SizedBox(height: 2),
                      Text(
                        assigneeName == null ? 'Предложим заказать доставку домой' : 'Предложим: $assigneeName — заказать доставку домой',
                        style: AppText.small,
                      ),
                    ]),
                  ),
                  Switch(value: _offer, onChanged: (v) => setState(() => _offer = v)),
                ]),
              ),
            ]),
          ),
        ]),
      ),
      bottomNavigationBar: BottomActionBar(
        child: AppButton(
          label: _lines.isEmpty ? 'Отправить' : 'Отправить · ${itemsWord(_lines.length)}',
          loading: _busy,
          onPressed: _lines.isEmpty ? null : _send,
        ),
      ),
    );
  }
}

class _Label extends StatelessWidget {
  const _Label(this.text);
  final String text;

  @override
  Widget build(BuildContext context) =>
      Padding(padding: const EdgeInsets.only(bottom: 10), child: Text(text, style: AppText.bodyStrong));
}

class _PersonTile extends StatelessWidget {
  const _PersonTile({required this.avatar, required this.name, required this.selected, required this.onTap});
  final Widget avatar;
  final String name;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(right: 10),
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          width: 84,
          padding: const EdgeInsets.symmetric(vertical: 12),
          decoration: BoxDecoration(
            color: selected ? AppColors.primarySoft : AppColors.white,
            borderRadius: BorderRadius.circular(AppRadius.lg),
            border: Border.all(color: selected ? AppColors.primary : AppColors.line, width: selected ? 2 : 1),
          ),
          child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
            avatar,
            const SizedBox(height: 6),
            Text(name, maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.caption.copyWith(color: AppColors.ink, fontWeight: FontWeight.w600)),
          ]),
        ),
      ),
    );
  }
}

class _ItemChip extends StatelessWidget {
  const _ItemChip({required this.label, required this.onTap, required this.onRemove});
  final String label;
  final VoidCallback onTap;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppColors.white,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppRadius.md), side: const BorderSide(color: AppColors.line)),
      child: InkWell(
        borderRadius: BorderRadius.circular(AppRadius.md),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 6, 8),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 240),
              child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.smallStrong.copyWith(fontWeight: FontWeight.w500, fontSize: 14)),
            ),
            const SizedBox(width: 4),
            GestureDetector(onTap: onRemove, child: const Padding(padding: EdgeInsets.all(2), child: Icon(Icons.close_rounded, size: 18))),
          ]),
        ),
      ),
    );
  }
}

class _FoundRow extends StatelessWidget {
  const _FoundRow({required this.name, required this.subtitle, required this.onTap, this.image, this.last = false});
  final String name;
  final String subtitle;
  final String? image;
  final VoidCallback onTap;
  final bool last;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 10),
        decoration: BoxDecoration(border: last ? null : const Border(bottom: BorderSide(color: AppColors.line))),
        child: Row(children: [
          SizedBox(
            width: 36,
            height: 36,
            child: image == null && last
                ? const IconBox(Icons.edit_note_rounded, size: 36)
                : ProductImage(url: image, radius: AppRadius.sm, iconSize: 18),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(name, maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.bodyMedium.copyWith(fontSize: 14)),
              Text(subtitle, style: AppText.caption),
            ]),
          ),
          const Icon(Icons.add_rounded, color: AppColors.primary),
        ]),
      ),
    );
  }
}
