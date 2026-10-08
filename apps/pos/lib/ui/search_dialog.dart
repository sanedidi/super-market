import 'package:flutter/material.dart';
import 'package:sm_core/sm_core.dart' show tr;
import 'package:flutter/services.dart';

import '../core/catalog.dart';
import '../core/money.dart';
import 'theme.dart';

/// F2 — поиск товара по названию. ↑↓ выбрать, Enter — в чек, Esc — закрыть.
class SearchDialog extends StatefulWidget {
  const SearchDialog({super.key, required this.catalog});

  final Catalog catalog;

  @override
  State<SearchDialog> createState() => _SearchDialogState();
}

class _SearchDialogState extends State<SearchDialog> {
  final _ctrl = TextEditingController();
  List<Product> _items = const [];
  int _sel = 0;

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  void _search(String q) => setState(() {
        _items = widget.catalog.search(q);
        _sel = 0;
      });

  void _pick() {
    if (_items.isNotEmpty) Navigator.of(context).pop(_items[_sel]);
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent e) {
    if (e is KeyUpEvent) return KeyEventResult.ignored;
    if (e.logicalKey == LogicalKeyboardKey.arrowDown) {
      setState(() => _sel = (_sel + 1).clamp(0, _items.isEmpty ? 0 : _items.length - 1));
      return KeyEventResult.handled;
    }
    if (e.logicalKey == LogicalKeyboardKey.arrowUp) {
      setState(() => _sel = (_sel - 1).clamp(0, _items.isEmpty ? 0 : _items.length - 1));
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: C.surface,
      insetPadding: const EdgeInsets.all(48),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: SizedBox(
        width: 760,
        height: 600,
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text(tr('Поиск товара', 'Mahsulot qidirish'), style: t(22, w: FontWeight.w700)),
            const SizedBox(height: 12),
            Focus(
              onKeyEvent: _onKey,
              child: TextField(
                controller: _ctrl,
                autofocus: true,
                style: t(20),
                decoration: InputDecoration(hintText: tr('Название или штрихкод', 'Nomi yoki shtrix-kod'), prefixIcon: const Icon(Icons.search)),
                onChanged: _search,
                onSubmitted: (_) => _pick(),
              ),
            ),
            const SizedBox(height: 12),
            Expanded(
              child: _items.isEmpty
                  ? Center(
                      child: Text(_ctrl.text.isEmpty ? tr('Начните вводить название', 'Nomini kiritishni boshlang') : tr('Ничего не найдено', 'Hech narsa topilmadi'), style: t(15, c: C.td)))
                  : ListView.builder(
                      itemCount: _items.length,
                      itemBuilder: (_, i) {
                        final p = _items[i];
                        return Material(
                          color: i == _sel ? C.brandSoft : Colors.transparent,
                          borderRadius: BorderRadius.circular(8),
                          child: ListTile(
                            dense: true,
                            title: Text(p.name, style: t(16, w: FontWeight.w500)),
                            subtitle: Text(
                              [
                                if (p.barcodes.isNotEmpty) p.barcodes.first,
                                if (p.plu != null) tr('код ${p.plu}', 'kod ${p.plu}'),
                                if (p.marked) tr('маркировка', 'markirovka'),
                                if (!p.active) tr('снят с продажи', 'sotuvdan olingan'),
                              ].join(' · '),
                              style: t(12, c: C.ts),
                            ),
                            trailing: Text('${fmtMoney(p.price)} / ${p.unit}', style: t(16, w: FontWeight.w700)),
                            onTap: () => Navigator.of(context).pop(p),
                          ),
                        );
                      },
                    ),
            ),
            const SizedBox(height: 8),
            Text(tr('↑↓ — выбрать · Enter — в чек · Esc — закрыть', '↑↓ — tanlash · Enter — chekka · Esc — yopish'), style: t(12, c: C.ts)),
          ]),
        ),
      ),
    );
  }
}
