import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:sm_core/sm_core.dart' show tr;

import '../core/catalog.dart';
import '../core/quick.dart';
import '../state/pos.dart';
import 'product_tile.dart';
import 'search_dialog.dart';
import 'theme.dart';
import 'widgets.dart';

/// Настройка быстрых кнопок (Figma «POS v4 · Настройка быстрых кнопок»).
///
/// Закреплённые товары — первыми на вкладке «Частые», в своём порядке;
/// остальные места касса заполняет самыми продаваемыми за 30 дней («авто»).
/// ✕ — открепить, 📌 на «авто» — закрепить, перетаскивание — порядок.
/// Сохраняется на сервере — общие для всех касс магазина.
class QuickKeysScreen extends StatefulWidget {
  const QuickKeysScreen({super.key});

  @override
  State<QuickKeysScreen> createState() => _QuickKeysScreenState();
}

class _QuickKeysScreenState extends State<QuickKeysScreen> {
  late List<String> _pinned;
  bool _saving = false;
  String? _error;

  PosController get pos => context.read<PosController>();

  @override
  void initState() {
    super.initState();
    final c = context.read<PosController>().catalog;
    _pinned = [for (final id in c.quickPinned) if (c.byId(id) != null) id];
  }

  bool _ok(Product? p) => p != null && p.active && !p.marked;

  /// «Авто»: самые продаваемые, которых нет среди закреплённых.
  List<Product> get _auto {
    final c = pos.catalog;
    final out = <Product>[];
    for (final id in c.quickTop) {
      if (_pinned.length + out.length >= quickFrequentMax) break;
      final p = c.byId(id);
      if (_ok(p) && !_pinned.contains(id) && !out.contains(p)) out.add(p!);
    }
    return out;
  }

  void _pin(String id) {
    if (_pinned.contains(id)) return;
    if (_pinned.length >= quickFrequentMax) {
      setState(() => _error = tr('Закрепить можно не больше $quickFrequentMax товаров', 'Koʻpi bilan $quickFrequentMax ta mahsulotni qadash mumkin'));
      return;
    }
    setState(() {
      _pinned.add(id);
      _error = null;
    });
  }

  void _unpin(String id) => setState(() => _pinned.remove(id));

  /// Перетащили закреплённый товар [from] на место товара [to].
  void _move(String from, String to) {
    if (from == to) return;
    setState(() {
      final i = _pinned.indexOf(to);
      _pinned.remove(from);
      _pinned.insert(i < 0 ? _pinned.length : i, from);
    });
  }

  Future<void> _add() async {
    final p = await showDialog<Product>(context: context, builder: (_) => SearchDialog(catalog: pos.catalog));
    if (p == null || !mounted) return;
    if (!_ok(p)) {
      setState(() => _error = p.marked ? tr('Маркированный товар нужно сканировать — на кнопку его не поставить', 'Markirovkali mahsulotni skanerlash kerak — uni tugmaga qoʻyib boʻlmaydi') : tr('Товар снят с продажи', 'Mahsulot sotuvdan olingan'));
      return;
    }
    _pin(p.id);
  }

  Future<void> _save() async {
    setState(() {
      _saving = true;
      _error = null;
    });
    final err = await pos.saveQuickKeys(List.of(_pinned));
    if (!mounted) return;
    if (err == null) {
      Navigator.of(context).pop();
    } else {
      setState(() {
        _saving = false;
        _error = err;
      });
    }
  }

  bool _onKey(KeyEvent e) {
    if (e.logicalKey == LogicalKeyboardKey.escape) {
      Navigator.of(context).pop();
      return true;
    }
    if (isEnter(e)) {
      if (!_saving) _save();
      return true;
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    final c = context.watch<PosController>().catalog;
    final pinned = [for (final id in _pinned) c.byId(id)].whereType<Product>().toList();
    final auto = _auto;
    return Scaffold(
      body: KeyCatcher(
        onKey: _onKey,
        child: Column(children: [
          const TopBar(),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                const Expanded(child: _Help()),
                const SizedBox(width: 16),
                SizedBox(
                  width: 620,
                  child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                    Row(children: [
                      Expanded(
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Text(tr('Быстрые кнопки · «Частые»', 'Tezkor tugmalar · «Ommabop»'), style: t(22, w: FontWeight.w700)),
                          Text(
                            tr('Закреплено ${pinned.length} · остальные — самые продаваемые за 30 дней', 'Qadalgan: ${pinned.length} · qolganlari — 30 kunda eng koʻp sotilganlar'),
                            style: t(13, c: C.ts),
                          ),
                        ]),
                      ),
                      TextButton(
                        onPressed: _saving ? null : () => Navigator.of(context).pop(),
                        child: Text(tr('Отмена · Esc', 'Bekor qilish · Esc'), style: t(14, w: FontWeight.w600, c: C.ts)),
                      ),
                      const SizedBox(width: 8),
                      FilledButton(
                        style: FilledButton.styleFrom(
                          backgroundColor: C.dark,
                          minimumSize: const Size(120, 48),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                        ),
                        onPressed: _saving ? null : _save,
                        child: Text(_saving ? tr('Сохраняю…', 'Saqlanmoqda…') : tr('Готово', 'Tayyor'), style: t(15, w: FontWeight.w700, c: Colors.white)),
                      ),
                    ]),
                    if (_error != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: Text(_error!, style: t(14, w: FontWeight.w500, c: C.error)),
                      ),
                    const SizedBox(height: 12),
                    Expanded(
                      child: GridView(
                        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: 3,
                          mainAxisExtent: 140,
                          crossAxisSpacing: 12,
                          mainAxisSpacing: 10,
                        ),
                        children: [
                          for (final p in pinned) _pinnedTile(p),
                          for (final p in auto)
                            ProductTile(
                              product: p,
                              dim: true,
                              onTap: () => _pin(p.id),
                              badge: _round(const Text('📌', style: TextStyle(fontSize: 11)), C.surface, border: true),
                            ),
                          _AddTile(onTap: _add),
                        ],
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      tr('Перетащите закреплённую плитку — порядок · ✕ — открепить · нажмите «авто» — закрепить', 'Qadalgan tugmani suring — tartib · ✕ — olib tashlash · «avto»ni bosing — qadash'),
                      style: t(12, c: C.ts),
                    ),
                  ]),
                ),
              ]),
            ),
          ),
        ]),
      ),
    );
  }

  Widget _pinnedTile(Product p) {
    final tile = ProductTile(
      product: p,
      pinned: true,
      border: C.brand,
      onTap: () {},
      badge: GestureDetector(
        onTap: () => _unpin(p.id),
        child: _round(Text('✕', style: t(12, w: FontWeight.w700, c: Colors.white)), C.dark),
      ),
    );
    return DragTarget<String>(
      onWillAcceptWithDetails: (d) => d.data != p.id,
      onAcceptWithDetails: (d) => _move(d.data, p.id),
      builder: (context, candidates, _) => LongPressDraggable<String>(
        data: p.id,
        delay: const Duration(milliseconds: 200),
        feedback: Material(
          color: Colors.transparent,
          child: SizedBox(width: 190, height: 140, child: Opacity(opacity: 0.9, child: tile)),
        ),
        childWhenDragging: Opacity(opacity: 0.3, child: tile),
        child: candidates.isEmpty
            ? tile
            : DecoratedBox(
                position: DecorationPosition.foreground,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: const Color(0xFF12B76A), width: 3),
                ),
                child: tile,
              ),
      ),
    );
  }

  static Widget _round(Widget child, Color color, {bool border = false}) => Container(
        width: 26,
        height: 26,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: color,
          shape: BoxShape.circle,
          border: border ? Border.all(color: C.borderStrong) : null,
        ),
        child: child,
      );
}

class _AddTile extends StatelessWidget {
  const _AddTile({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Material(
        color: C.surface,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: onTap,
          child: Container(
            decoration: BoxDecoration(borderRadius: BorderRadius.circular(12), border: Border.all(color: C.td, width: 1.5)),
            child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
              Text('+', style: t(32, w: FontWeight.w500, c: C.ts)),
              Text(tr('Закрепить товар', 'Mahsulotni qadash'), style: t(14, w: FontWeight.w600)),
            ]),
          ),
        ),
      );
}

class _Help extends StatelessWidget {
  const _Help();

  @override
  Widget build(BuildContext context) {
    Widget line(String s) => Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: Text('•  $s', style: t(15, h: 1.35)),
        );
    return Panel(
      padding: const EdgeInsets.all(24),
      child: SingleChildScrollView(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(tr('Как это работает', 'Bu qanday ishlaydi'), style: t(20, w: FontWeight.w700)),
          const SizedBox(height: 16),
          line(tr(
              '«Частые» — до $quickFrequentMax мест, на экране продажи 9, остальные прокруткой. '
                  'Сначала закреплённые, остальные — самые продаваемые в этом магазине за 30 дней.',
              '«Ommabop» — $quickFrequentMax tagacha joy, sotuv ekranida 9 ta, qolganlari aylantirib koʻriladi. '
                  'Avval qadalganlar, qolganlari — shu doʻkonda 30 kunda eng koʻp sotilganlar.')),
          line(tr('Вкладки разделов собираются сами: раньше тот раздел, чьи товары продаются чаще.', 'Boʻlim yorliqlari oʻzi tuziladi: mahsulotlari koʻproq sotiladigan boʻlim oldinroq turadi.')),
          line(tr('Весовой товар (кг): наберите вес на клавиатуре (например 1,25) и нажмите плитку.', 'Tortiladigan mahsulot (kg): klaviaturada vaznni tering (masalan, 1,25) va tugmani bosing.')),
          line(tr('Цифры, потом плитка — столько штук сразу.', 'Raqamlar, keyin tugma — shuncha dona birdaniga.')),
          line(tr('Маркированный товар на кнопку не ставится — его сканируют.', 'Markirovkali mahsulot tugmaga qoʻyilmaydi — u skanerlanadi.')),
          line(tr('Кнопки общие для всех касс магазина и сохраняются на сервере, нужна связь.', 'Tugmalar doʻkonning barcha kassalari uchun umumiy va serverda saqlanadi, aloqa kerak.')),
          line(tr('Настраивает владелец или сотрудник с правом «Настройка кассы».', 'Egasi yoki «Kassa sozlamalari» huquqiga ega xodim sozlaydi.')),
        ]),
      ),
    );
  }
}
