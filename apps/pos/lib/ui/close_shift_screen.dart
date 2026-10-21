import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:sm_core/sm_core.dart' show tr;

import '../core/money.dart';
import '../state/pos.dart';
import 'kit.dart';
import 'theme.dart';
import 'widgets.dart';

/// Закрытие смены (Figma «Касса · Закрытие смены — одна сумма, без купюр»):
/// кассир пересчитывает ящик и набирает одну сумму — купюры по отдельности не
/// вводятся. Пересчёт «слепой»: сколько должно быть, касса показывает только
/// после Enter. Расхождение — с причиной (F2/F3/F4).
class CloseShiftScreen extends StatefulWidget {
  const CloseShiftScreen({super.key});

  @override
  State<CloseShiftScreen> createState() => _CloseShiftScreenState();
}

Map<LogicalKeyboardKey, String> get _reasons => {
      LogicalKeyboardKey.f2: tr('Сдача без мелочи', 'Qaytim mayda pulsiz berildi'),
      LogicalKeyboardKey.f3: tr('Ошибка в чеке', 'Chekdagi xato'),
      LogicalKeyboardKey.f4: tr('Другое', 'Boshqa'),
    };

class _CloseShiftScreenState extends State<CloseShiftScreen> {
  /// Сумма в ящике цифрами, без пробелов (сумы).
  String _input = '';
  bool _revealed = false;
  String? _reason;
  bool _busy = false;
  String? _error;

  int get _counted => parseMoney(_input);

  void _type(String d) {
    if (_input.length + d.length > 11) return;
    if ((_input.isEmpty || _input == '0') && d.startsWith('0')) {
      if (d == '0' && _input.isEmpty) _edited(() => _input = '0');
      return;
    }
    _edited(() => _input = _input == '0' ? d : _input + d);
  }

  void _erase() {
    if (_input.isNotEmpty) _edited(() => _input = _input.substring(0, _input.length - 1));
  }

  /// Сумму поправили после сверки — причину расхождения выбрать заново.
  void _edited(VoidCallback change) => setState(() {
        change();
        _error = null;
        if (_revealed) _reason = null;
      });

  void _reveal() {
    if (_input.isEmpty) {
      setState(() => _error = tr('Наберите, сколько наличных в ящике (пусто — 0)', 'Gʻaladonda qancha naqd pul borligini tering (boʻsh — 0)'));
      return;
    }
    setState(() {
      _revealed = true;
      _error = null;
    });
  }

  Future<void> _close() async {
    final pos = context.read<PosController>();
    final diff = _counted - pos.report.expectedCash;
    if (diff != 0 && _reason == null) {
      setState(() => _error = tr('Расхождение ${fmtMoney(diff)} — выберите причину: F2, F3 или F4', 'Farq ${fmtMoney(diff)} — sababni tanlang: F2, F3 yoki F4'));
      return;
    }
    setState(() => _busy = true);
    try {
      await pos.closeShift(_counted, diff == 0 ? '' : _reason!);
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = '$e';
        });
      }
      return;
    }
    if (mounted) Navigator.of(context).popUntil((r) => r.isFirst);
  }

  bool _onKey(KeyEvent e) {
    if (_busy) return true;
    final k = e.logicalKey;
    final ch = printable(e);
    if (k == LogicalKeyboardKey.escape) {
      Navigator.of(context).pop();
      return true;
    }
    if (_revealed && _reasons.containsKey(k)) {
      setState(() {
        _reason = _reasons[k];
        _error = null;
      });
      return true;
    }
    if (isEnter(e)) {
      if (_revealed) {
        _close();
      } else {
        _reveal();
      }
      return true;
    }
    if (k == LogicalKeyboardKey.backspace) {
      _erase();
      return true;
    }
    if (ch != null && RegExp(r'^[0-9]$').hasMatch(ch)) {
      _type(ch);
      return true;
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    final pos = context.watch<PosController>();
    if (pos.shift == null) return const Scaffold();
    final expected = pos.report.expectedCash;
    final diff = _counted - expected;
    final extra = Padding(
      padding: const EdgeInsets.all(6),
      child: Material(
        color: C.surface,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: () => _type('000'),
          child: SizedBox(width: 76, height: 52, child: Center(child: Text('000', style: t(22, w: FontWeight.w500)))),
        ),
      ),
    );
    return Scaffold(
      body: KeyCatcher(
        onKey: _onKey,
        child: Column(children: [
          const TopBar(),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Expanded(
                  child: Panel(
                    padding: const EdgeInsets.fromLTRB(28, 24, 28, 24),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                      Text(tr('Закрытие смены №${pos.shift!.number ?? '·'}', 'Smena №${pos.shift!.number ?? '·'} yopilmoqda'), style: t(24, w: FontWeight.w700)),
                      const SizedBox(height: 4),
                      Text(
                          tr('Пересчитайте наличные в ящике и наберите сумму. Купюры по отдельности вводить не нужно.',
                              'Gʻaladondagi naqd pulni sanang va summani tering. Kupyuralarni alohida kiritish shart emas.'),
                          style: t(14, c: C.ts)),
                      const SizedBox(height: 14),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 14),
                        decoration: BoxDecoration(
                          color: C.surface,
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(color: _revealed ? C.borderStrong : C.brand, width: _revealed ? 1 : 2),
                        ),
                        child: Row(children: [
                          Expanded(child: Text(tr('Наличных в ящике', 'Gʻaladondagi naqd pul'), style: t(16, w: FontWeight.w500, c: C.ts))),
                          Flexible(
                            flex: 2,
                            child: FitText(_input.isEmpty ? '0' : fmtMoney(_counted),
                                textAlign: TextAlign.right, style: tb(44, c: _input.isEmpty ? C.td : C.tp)),
                          ),
                        ]),
                      ),
                      const SizedBox(height: 8),
                      Text(
                          _revealed
                              ? tr('Сумму можно поправить: цифры и ⌫ — сверка обновится', 'Summani tuzatish mumkin: raqamlar va ⌫ — solishtirish yangilanadi')
                              : tr('Цифры — сумма · ⌫ — стереть · 000 — три нуля · Enter — сверить с кассой',
                                  'Raqamlar — summa · ⌫ — oʻchirish · 000 — uchta nol · Enter — kassa bilan solishtirish'),
                          style: t(13, c: C.ts)),
                      const Spacer(),
                      Center(child: NumPad(onDigit: _type, onBackspace: _erase, extra: extra)),
                      const Spacer(),
                    ]),
                  ),
                ),
                const SizedBox(width: 16),
                SizedBox(
                  width: 480,
                  child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                    Panel(
                      color: C.dark,
                      padding: const EdgeInsets.all(24),
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text(tr('Посчитано в ящике', 'Gʻaladonda sanaldi'), style: t(15, c: Colors.white70)),
                        Text(fmtMoney(_counted), style: t(56, w: FontWeight.w800, c: Colors.white)),
                        Text(
                            _revealed
                                ? tr('сверено с кассой — ниже результат', 'kassa bilan solishtirildi — natija pastda')
                                : tr('после пересчёта Enter — сверить с кассой', 'sanagach Enter — kassa bilan solishtirish'),
                            style: t(13, c: Colors.white60)),
                      ]),
                    ),
                    const SizedBox(height: 12),
                    if (_revealed) _Result(expected: expected, diff: diff, reason: _reason),
                    const SizedBox(height: 12),
                    _QueueNote(queue: pos.queue, failed: pos.failed),
                    const Spacer(),
                    if (_error != null) Padding(padding: const EdgeInsets.only(bottom: 8), child: Text(_error!, style: t(14, c: C.error))),
                    KeyCard(
                      keyLabel: 'Enter',
                      title: _revealed ? tr('Закрыть смену', 'Smenani yopish') : tr('Сверить с кассой', 'Kassa bilan solishtirish'),
                      subtitle: _revealed
                          ? (pos.printer.enabled
                              ? tr('и напечатать Z-отчёт', 'va Z-hisobotni chop etish')
                              : tr('Z-отчёт — когда подключите принтер', 'Z-hisobot — printer ulanganda'))
                          : tr('покажем, сколько должно быть', 'qancha boʻlishi kerakligini koʻrsatamiz'),
                      style: KeyCardStyle.primary,
                      onTap: () {
                        if (_revealed) {
                          _close();
                        } else {
                          _reveal();
                        }
                      },
                    ),
                    const SizedBox(height: 10),
                    KeyCard(
                      keyLabel: 'Esc',
                      title: tr('Назад', 'Orqaga'),
                      subtitle: tr('смена останется открытой', 'smena ochiq qoladi'),
                      onTap: () => Navigator.of(context).pop(),
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
}

class _Result extends StatelessWidget {
  const _Result({required this.expected, required this.diff, required this.reason});

  final int expected;
  final int diff;
  final String? reason;

  @override
  Widget build(BuildContext context) {
    if (diff == 0) {
      return Panel(
        color: C.successSoft,
        child: Text(tr('✓ Должно быть ${fmtMoney(expected)} — сходится', '✓ Boʻlishi kerak: ${fmtMoney(expected)} — mos keldi'), style: t(16, w: FontWeight.w600, c: C.success)),
      );
    }
    final short = diff < 0;
    return Panel(
      color: C.errorSoft,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          Expanded(child: Text(tr('Должно быть ${fmtMoney(expected)}', 'Boʻlishi kerak: ${fmtMoney(expected)}'), style: t(15, c: C.error))),
          Text('${short ? '' : '+'}${fmtMoney(diff)}', style: t(32, w: FontWeight.w800, c: C.error)),
        ]),
        const SizedBox(height: 6),
        Text(
          reason == null
              ? tr('${short ? 'Недостача' : 'Излишек'}. Причина обязательна: F2 — сдача без мелочи · F3 — ошибка в чеке · F4 — другое',
                  '${short ? 'Kamomad' : 'Ortiqcha'}. Sabab majburiy: F2 — qaytim mayda pulsiz · F3 — chekdagi xato · F4 — boshqa')
              : tr('Причина: $reason · Enter — закрыть смену', 'Sabab: $reason · Enter — smenani yopish'),
          style: t(13, c: C.error),
        ),
      ]),
    );
  }
}

class _QueueNote extends StatelessWidget {
  const _QueueNote({required this.queue, required this.failed});

  final int queue;
  final int failed;

  @override
  Widget build(BuildContext context) {
    final ok = queue == 0 && failed == 0;
    return Panel(
      color: ok ? C.successSoft : C.warningSoft,
      padding: const EdgeInsets.all(14),
      child: Text(
        ok
            ? tr('✓ Все чеки отправлены — неотправленных нет', '✓ Barcha cheklar yuborildi — yuborilmagan chek yoʻq')
            : tr('В очереди $queue${failed > 0 ? ', не принято сервером $failed' : ''} — отправятся сами, когда будет связь',
                'Navbatda $queue${failed > 0 ? ', server qabul qilmagan: $failed' : ''} — aloqa paydo boʻlganda oʻzi yuboriladi'),
        style: t(13, c: ok ? C.success : C.warning),
      ),
    );
  }
}
