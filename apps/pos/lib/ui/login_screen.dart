import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:sm_core/sm_core.dart' show LangSwitch, tr;

import '../core/catalog.dart';
import '../state/pos.dart';
import 'theme.dart';
import 'widgets.dart';

/// «Кто на кассе?» — кассир выбирает себя (стрелками или касанием) и вводит ПИН.
class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  int _sel = 0;
  String _pin = '';
  String? _error;

  List<Cashier> get _cashiers => context.read<PosController>().catalog.cashiers;

  void _digit(String d) {
    if (_pin.length >= 4) return;
    setState(() {
      _pin += d;
      _error = null;
    });
    // ПИН — строго 4 цифры: на 4-й цифре касса сразу проверяет его.
    if (_pin.length == 4) _submit();
  }

  void _submit() {
    final list = _cashiers;
    if (list.isEmpty || _pin.isEmpty) return;
    if (_pin.length != 4) {
      setState(() => _error = tr('ПИН — 4 цифры', 'PIN-kod — 4 ta raqam'));
      return;
    }
    final c = list[_sel.clamp(0, list.length - 1)];
    final err = context.read<PosController>().login(c, _pin);
    setState(() {
      _pin = '';
      _error = err;
    });
  }

  void _back() {
    if (_pin.isNotEmpty) setState(() => _pin = _pin.substring(0, _pin.length - 1));
  }

  bool _onKey(KeyEvent e) {
    final list = _cashiers;
    final k = e.logicalKey;
    if (k == LogicalKeyboardKey.arrowRight || k == LogicalKeyboardKey.arrowDown) {
      setState(() {
        _sel = list.isEmpty ? 0 : (_sel + 1) % list.length;
        _pin = '';
      });
      return true;
    }
    if (k == LogicalKeyboardKey.arrowLeft || k == LogicalKeyboardKey.arrowUp) {
      setState(() {
        _sel = list.isEmpty ? 0 : (_sel - 1 + list.length) % list.length;
        _pin = '';
      });
      return true;
    }
    if (k == LogicalKeyboardKey.backspace) {
      _back();
      return true;
    }
    if (k == LogicalKeyboardKey.escape) {
      setState(() => _pin = '');
      return true;
    }
    if (isEnter(e)) {
      _submit();
      return true;
    }
    final ch = printable(e);
    if (ch != null && RegExp(r'^[0-9]$').hasMatch(ch)) {
      _digit(ch);
      return true;
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    final pos = context.watch<PosController>();
    final s = pos.catalog.settings;
    final list = pos.catalog.cashiers;
    final sel = list.isEmpty ? null : list[_sel.clamp(0, list.length - 1)];
    return Scaffold(
      body: KeyCatcher(
        onKey: _onKey,
        child: Row(children: [
          Container(
            width: 560,
            color: C.brand,
            padding: const EdgeInsets.all(56),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                const Logo(size: 56),
                const SizedBox(width: 16),
                Text(tr('Касса', 'Kassa'), style: t(22, w: FontWeight.w700, c: Colors.white)),
              ]),
              const Spacer(),
              Text(s.networkName.isEmpty ? s.storeName : s.networkName, style: t(40, w: FontWeight.w700, c: Colors.white)),
              const SizedBox(height: 12),
              Text('${s.storeName} · ${s.deviceName}', style: t(18, c: Colors.white)),
              const SizedBox(height: 32),
              for (final line in [
                if (pos.shift != null) tr('Смена №${pos.shift!.number ?? '·'} открыта · ${pos.shift!.openedByName}', 'Smena №${pos.shift!.number ?? '·'} ochiq · ${pos.shift!.openedByName}'),
                pos.online ? tr('Онлайн', 'Onlayn') : tr('Нет связи — касса работает, чеки отправятся позже', 'Aloqa yoʻq — kassa ishlayapti, cheklar keyinroq yuboriladi'),
                pos.fiscalMode ? tr('Фискальный модуль готов', 'Fiskal modul tayyor') : tr('Тестовый режим: чеки не фискальные', 'Test rejimi: cheklar fiskal emas'),
                if (pos.catalogAt != null)
                  tr('Каталог: ${pos.catalog.length} товаров, обновлён ${_ago(pos.catalogAt!)}',
                      'Katalog: ${pos.catalog.length} ta mahsulot, yangilandi: ${_ago(pos.catalogAt!)}'),
              ])
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Row(children: [
                    const Icon(Icons.circle, size: 8, color: Colors.white),
                    const SizedBox(width: 12),
                    Expanded(child: Text(line, style: t(14, c: Colors.white))),
                  ]),
                ),
            ]),
          ),
          Expanded(
            child: Stack(children: [
              Center(
                child: SingleChildScrollView(
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                    Text(tr('Кто на кассе?', 'Kassada kim?'), style: t(28, w: FontWeight.w700)),
                    const SizedBox(height: 24),
                    if (list.isEmpty)
                      SizedBox(
                        width: 420,
                        child: Text(
                          tr('Нет кассиров с ПИНом. Владелец задаёт ПИН в панели магазина → Касса → Кассы и ПИНы.',
                              'PIN-kodli kassirlar yoʻq. Egasi PIN-kodni doʻkon panelida beradi → Kassa → Kassalar va PIN-kodlar.'),
                          textAlign: TextAlign.center,
                          style: t(15, c: C.ts),
                        ),
                      ),
                    Wrap(spacing: 12, runSpacing: 12, alignment: WrapAlignment.center, children: [
                      for (var i = 0; i < list.length; i++)
                        _CashierTile(
                          cashier: list[i],
                          selected: i == _sel,
                          onTap: () => setState(() {
                            _sel = i;
                            _pin = '';
                          }),
                        ),
                    ]),
                    if (sel != null) ...[
                      const SizedBox(height: 28),
                      Text(tr('ПИН-код · ${sel.name}', 'PIN-kod · ${sel.name}'), style: t(14, c: C.ts)),
                      const SizedBox(height: 12),
                      Row(mainAxisSize: MainAxisSize.min, children: [
                        for (var i = 0; i < 4; i++)
                          Container(
                            width: 14,
                            height: 14,
                            margin: const EdgeInsets.symmetric(horizontal: 6),
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: i < _pin.length ? C.tp : Colors.transparent,
                              border: Border.all(color: i < _pin.length ? C.tp : C.borderStrong, width: 2),
                            ),
                          ),
                      ]),
                      SizedBox(height: 28, child: Center(child: Text(_error ?? '', style: t(14, c: C.error)))),
                      NumPad(onDigit: _digit, onBackspace: _back),
                      const SizedBox(height: 16),
                      Text(
                          tr('Забыли ПИН? Владелец меняет его в панели магазина → Касса → Кассы и ПИНы',
                              'PIN-kodni unutdingizmi? Egasi uni doʻkon panelida oʻzgartiradi → Kassa → Kassalar va PIN-kodlar'),
                          style: t(12, c: C.ts)),
                    ],
                  ]),
                ),
              ),
              const Positioned(top: 24, right: 24, child: LangSwitch()),
            ]),
          ),
        ]),
      ),
    );
  }
}

String _ago(DateTime at) {
  final m = DateTime.now().difference(at).inMinutes;
  if (m < 1) return tr('только что', 'hozirgina');
  if (m < 60) return tr('$m мин назад', '$m daqiqa oldin');
  final h = m ~/ 60;
  if (h < 24) return tr('$h ч назад', '$h soat oldin');
  return tr('${h ~/ 24} дн назад', '${h ~/ 24} kun oldin');
}

class _CashierTile extends StatelessWidget {
  const _CashierTile({required this.cashier, required this.selected, required this.onTap});

  final Cashier cashier;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final role = cashier.can(Perm.returns) ? tr('Старший кассир', 'Katta kassir') : tr('Кассир', 'Kassir');
    return Material(
      color: C.surface,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          width: 140,
          padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 8),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: selected ? C.brand : C.border, width: selected ? 2 : 1),
          ),
          child: Column(children: [
            CircleAvatar(
              radius: 28,
              backgroundColor: selected ? C.brand : C.brandSoft,
              child: Text(cashier.name.isEmpty ? '?' : cashier.name.characters.first.toUpperCase(),
                  style: t(22, w: FontWeight.w700, c: selected ? Colors.white : C.brand)),
            ),
            const SizedBox(height: 12),
            Text(cashier.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: t(14, w: FontWeight.w600)),
            Text(role, style: t(12, c: C.ts)),
          ]),
        ),
      ),
    );
  }
}
