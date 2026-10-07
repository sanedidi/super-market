import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:sm_core/sm_core.dart' show tr;

import '../printer/transport.dart';
import '../state/pos.dart';
import 'theme.dart';
import 'widgets.dart';

/// Оборудование (Figma «POS v2 · Оборудование»): чековый принтер, сканер,
/// денежный ящик, фискальный модуль.
class EquipmentScreen extends StatefulWidget {
  const EquipmentScreen({super.key});

  @override
  State<EquipmentScreen> createState() => _EquipmentScreenState();
}

class _EquipmentScreenState extends State<EquipmentScreen> {
  late PrinterConfig _cfg;
  late final _host = TextEditingController(text: _cfg.host);
  final _hostFocus = FocusNode();
  List<String> _winPrinters = const [];
  String? _note;
  bool _busy = false;
  String _lastScan = '';

  @override
  void initState() {
    super.initState();
    _cfg = context.read<PosController>().printer;
    if (Platform.isWindows) {
      try {
        _winPrinters = windowsPrinters();
      } catch (_) {
        _winPrinters = const [];
      }
    }
  }

  @override
  void dispose() {
    _host.dispose();
    _hostFocus.dispose();
    super.dispose();
  }

  PosController get pos => context.read<PosController>();

  Future<void> _save(PrinterConfig c) async {
    setState(() => _cfg = c);
    await pos.savePrinter(c);
  }

  Future<void> _run(Future<bool> Function() f, String ok) async {
    setState(() {
      _busy = true;
      _note = null;
    });
    if (_cfg.kind == 'network' && _host.text.trim() != _cfg.host) await _save(_cfg.copyWith(host: _host.text.trim()));
    final res = await f();
    if (!mounted) return;
    setState(() {
      _busy = false;
      _note = res ? ok : (pos.printError ?? tr('Принтер не выбран', 'Printer tanlanmagan'));
    });
  }

  bool _onKey(KeyEvent e) {
    if (_hostFocus.hasFocus) return false;
    if (e.logicalKey == LogicalKeyboardKey.escape || isEnter(e)) {
      Navigator.of(context).pop();
      return true;
    }
    // Сканер работает «как клавиатура»: просто показываем, что он прислал.
    final ch = printable(e);
    if (ch != null) {
      setState(() => _lastScan = (_lastScan.length > 40 ? '' : _lastScan) + ch);
      return true;
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    final p = context.watch<PosController>();
    final fs = p.fiscalStatus;
    final printerOk = _cfg.enabled && p.printError == null;
    return Scaffold(
      body: KeyCatcher(
        onKey: _onKey,
        child: Center(
          child: Container(
            width: 900,
            padding: const EdgeInsets.fromLTRB(40, 36, 40, 32),
            decoration: BoxDecoration(color: C.surface, borderRadius: BorderRadius.circular(24)),
            child: SingleChildScrollView(
              child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(tr('Оборудование', 'Uskunalar'), style: t(30, w: FontWeight.w700)),
                const SizedBox(height: 4),
                Text(tr('Проверьте каждое устройство — это займёт минуту.', 'Har bir qurilmani tekshiring — bu bir daqiqa oladi.'), style: t(15, c: C.ts)),
                const SizedBox(height: 20),
                _Row(
                  title: tr('Чековый принтер', 'Chek printeri'),
                  status: !_cfg.enabled ? (tr('не выбран', 'tanlanmagan'), C.warning) : (printerOk ? (tr('выбран', 'tanlangan'), C.success) : (tr('ошибка', 'xatolik'), C.error)),
                  subtitle: _cfg.enabled ? tr('${_cfg.title} · ESC/POS · бумага ${_cfg.paperMm} мм', '${_cfg.title} · ESC/POS · qogʻoz ${_cfg.paperMm} mm') : tr('Выберите принтер Windows или укажите IP сетевого принтера', 'Windows printerini tanlang yoki tarmoq printerining IP manzilini kiriting'),
                  actions: [
                    _Dropdown<int>(
                      value: _cfg.paperMm,
                      items: {80: tr('Бумага 80 мм', 'Qogʻoz 80 mm'), 58: tr('Бумага 58 мм', 'Qogʻoz 58 mm')},
                      onChanged: (v) => _save(_cfg.copyWith(paperMm: v)),
                    ),
                    _Btn(tr('Пробная печать', 'Sinov chop etish'), _busy ? null : () => _run(pos.testPrint, tr('Пробная страница отправлена на принтер', 'Sinov sahifasi printerga yuborildi'))),
                  ],
                  extra: Wrap(spacing: 12, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
                    _Dropdown<String>(
                      value: _cfg.kind,
                      items: {
                        'none': tr('Без принтера', 'Printersiz'),
                        if (Platform.isWindows) 'windows': tr('Принтер Windows (USB)', 'Windows printeri (USB)'),
                        'network': tr('Сетевой принтер (IP)', 'Tarmoq printeri (IP)'),
                      },
                      onChanged: (v) => _save(_cfg.copyWith(kind: v)),
                    ),
                    if (_cfg.kind == 'windows')
                      _Dropdown<String>(
                        value: _winPrinters.contains(_cfg.name) ? _cfg.name : '',
                        items: {'': tr('Выберите принтер…', 'Printerni tanlang…'), for (final n in _winPrinters) n: n},
                        onChanged: (v) => _save(_cfg.copyWith(name: v)),
                      ),
                    if (_cfg.kind == 'network')
                      SizedBox(
                        width: 220,
                        child: TextField(
                          controller: _host,
                          focusNode: _hostFocus,
                          decoration: InputDecoration(hintText: '192.168.1.50', labelText: tr('IP принтера (порт 9100)', 'Printer IP manzili (port 9100)')),
                          onSubmitted: (v) => _save(_cfg.copyWith(host: v.trim())),
                        ),
                      ),
                  ]),
                ),
                _Row(
                  title: tr('Сканер штрихкодов', 'Shtrix-kod skaneri'),
                  status: _lastScan.isEmpty ? (tr('отсканируйте товар', 'mahsulotni skanerlang'), C.ts) : (tr('работает', 'ishlayapti'), C.success),
                  subtitle: _lastScan.isEmpty ? tr('Режим «как клавиатура» — отсканируйте любой штрихкод, он появится здесь', '«Klaviatura kabi» rejimi — istalgan shtrix-kodni skanerlang, u shu yerda paydo boʻladi') : tr('Последний скан: $_lastScan', 'Oxirgi skan: $_lastScan'),
                  actions: [_Btn(tr('Проверить ещё раз', 'Yana tekshirish'), () => setState(() => _lastScan = ''))],
                ),
                _Row(
                  title: tr('Денежный ящик', 'Pul gʻaladoni'),
                  status: (tr('через принтер', 'printer orqali'), C.ts),
                  subtitle: tr('Открывается командой принтера при оплате наличными', 'Naqd toʻlovda printer buyrugʻi bilan ochiladi'),
                  actions: [
                    _Dropdown<bool>(
                      value: _cfg.drawer,
                      items: {true: tr('Открывать при наличных', 'Naqd toʻlovda ochish'), false: tr('Не открывать', 'Ochmaslik')},
                      onChanged: (v) => _save(_cfg.copyWith(drawer: v)),
                    ),
                    _Btn(tr('Открыть ящик', 'Gʻaladonni ochish'), _busy ? null : () => _run(pos.openDrawer, tr('Команда открытия отправлена', 'Ochish buyrugʻi yuborildi'))),
                  ],
                ),
                _Row(
                  title: tr('Фискальный модуль', 'Fiskal modul'),
                  status: p.fiscalMode && (fs?.ready ?? false) ? (tr('работает', 'ishlayapti'), C.success) : (tr('не подключён', 'ulanmagan'), C.warning),
                  subtitle: p.fiscalMode
                      ? '${fs?.title ?? ''}${fs != null && fs.pending > 0 ? tr(' · ждут отправки в ОФД: ${fs.pending}', ' · OFDga yuborilishini kutmoqda: ${fs.pending}') : ''}'
                      : tr('Тестовый режим: чеки не фискальные. Модуль подключим по протоколу ОФД, когда касса будет в госреестре.', 'Test rejimi: cheklar fiskal emas. Kassa davlat reyestriga kiritilgach, modulni OFD protokoli boʻyicha ulaymiz.'),
                  actions: const [],
                ),
                if (_note != null) ...[
                  const SizedBox(height: 8),
                  Text(_note!, style: t(14, c: p.printError != null && _note == p.printError ? C.error : C.success)),
                ],
                const SizedBox(height: 16),
                Row(children: [
                  Expanded(
                    child: Text(tr('Принтер печатает напрямую командами ESC/POS. Кириллица — кодовая страница 866.', 'Printer toʻgʻridan-toʻgʻri ESC/POS buyruqlari bilan chop etadi. Kirill yozuvi — 866 kod sahifasi.'), style: t(13, c: C.ts)),
                  ),
                  Material(
                    color: C.brand,
                    borderRadius: BorderRadius.circular(12),
                    child: InkWell(
                      borderRadius: BorderRadius.circular(12),
                      onTap: () => Navigator.of(context).pop(),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                        child: Text(tr('Готово · Enter', 'Tayyor · Enter'), style: t(15, w: FontWeight.w600, c: Colors.white)),
                      ),
                    ),
                  ),
                ]),
              ]),
            ),
          ),
        ),
      ),
    );
  }
}

class _Row extends StatelessWidget {
  const _Row({required this.title, required this.status, required this.subtitle, required this.actions, this.extra});

  final String title;
  final (String, Color) status;
  final String subtitle;
  final List<Widget> actions;
  final Widget? extra;

  @override
  Widget build(BuildContext context) {
    final (label, color) = status;
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(border: Border.all(color: C.border), borderRadius: BorderRadius.circular(14)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Text(title, style: t(17, w: FontWeight.w700)),
                const SizedBox(width: 8),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(color: color.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(10)),
                  child: Text(label, style: t(12, w: FontWeight.w600, c: color)),
                ),
              ]),
              const SizedBox(height: 4),
              Text(subtitle, style: t(13, c: C.ts)),
            ]),
          ),
          for (final a in actions) ...[const SizedBox(width: 12), a],
        ]),
        if (extra != null) ...[const SizedBox(height: 12), extra!],
      ]),
    );
  }
}

class _Btn extends StatelessWidget {
  const _Btn(this.label, this.onTap);

  final String label;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => OutlinedButton(
        onPressed: onTap,
        style: OutlinedButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          side: const BorderSide(color: C.borderStrong),
        ),
        child: Text(label, style: t(15, w: FontWeight.w600)),
      );
}

class _Dropdown<T> extends StatelessWidget {
  const _Dropdown({required this.value, required this.items, required this.onChanged});

  final T value;
  final Map<T, String> items;
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(border: Border.all(color: C.borderStrong), borderRadius: BorderRadius.circular(10)),
        child: DropdownButtonHideUnderline(
          child: DropdownButton<T>(
            value: items.containsKey(value) ? value : items.keys.first,
            items: [for (final e in items.entries) DropdownMenuItem<T>(value: e.key, child: Text(e.value, style: t(14)))],
            onChanged: (v) {
              if (v != null) onChanged(v);
            },
          ),
        ),
      );
}
