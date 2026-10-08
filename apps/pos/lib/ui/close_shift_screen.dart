import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:sm_core/sm_core.dart' show tr;

import '../core/money.dart';
import '../state/pos.dart';
import 'theme.dart';
import 'widgets.dart';

/// Закрытие смены: «слепой» пересчёт купюр. Сколько должно быть в ящике,
/// касса показывает только после пересчёта.
class CloseShiftScreen extends StatefulWidget {
  const CloseShiftScreen({super.key});

  @override
  State<CloseShiftScreen> createState() => _CloseShiftScreenState();
}

/// Купюры сума; последняя строка — монеты и мелочь суммой.
const _notes = [200000, 100000, 50000, 20000, 10000, 5000, 2000, 1000];

Map<LogicalKeyboardKey, String> get _reasons => {
      LogicalKeyboardKey.f2: tr('Сдача без мелочи', 'Qaytim mayda pulsiz berildi'),
      LogicalKeyboardKey.f3: tr('Ошибка в чеке', 'Chekdagi xato'),
      LogicalKeyboardKey.f4: tr('Другое', 'Boshqa'),
    };

class _CloseShiftScreenState extends State<CloseShiftScreen> {
  final List<String> _counts = List.filled(_notes.length + 1, '');
  int _row = 0;
  bool _revealed = false;
  String? _reason;
  bool _busy = false;
  String? _error;

  int get _rowCount => _notes.length + 1;

  int _rowSum(int i) {
    if (i < _notes.length) return (int.tryParse(_counts[i]) ?? 0) * _notes[i] * 100;
    return parseMoney(_counts[i]);
  }

  int get _counted {
    var s = 0;
    for (var i = 0; i < _rowCount; i++) {
      s += _rowSum(i);
    }
    return s;
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
      if (!_revealed && _row < _rowCount - 1) {
        setState(() => _row++);
      } else if (!_revealed) {
        setState(() => _revealed = true);
      } else {
        _close();
      }
      return true;
    }
    if (k == LogicalKeyboardKey.arrowDown) {
      setState(() => _row = (_row + 1).clamp(0, _rowCount - 1));
      return true;
    }
    if (k == LogicalKeyboardKey.arrowUp) {
      setState(() => _row = (_row - 1).clamp(0, _rowCount - 1));
      return true;
    }
    if (k == LogicalKeyboardKey.backspace) {
      final v = _counts[_row];
      if (v.isNotEmpty) setState(() => _counts[_row] = v.substring(0, v.length - 1));
      return true;
    }
    if (ch != null && RegExp(r'^[0-9]$').hasMatch(ch) && _counts[_row].length < 9) {
      setState(() => _counts[_row] += ch);
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
                    child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                      Text(tr('Закрытие смены №${pos.shift!.number ?? '·'} · пересчитайте наличные', 'Smena №${pos.shift!.number ?? '·'} yopilmoqda · naqd pulni sanang'), style: t(24, w: FontWeight.w700)),
                      Text(
                          tr('Наберите количество купюр и Enter — курсор перейдёт ниже. ↑↓ — к другой строке.',
                              'Kupyuralar sonini tering va Enter — kursor pastga oʻtadi. ↑↓ — boshqa qatorga.'),
                          style: t(13, c: C.ts)),
                      const SizedBox(height: 12),
                      Expanded(
                        child: ListView(children: [
                          for (var i = 0; i < _rowCount; i++)
                            GestureDetector(
                              onTap: () => setState(() => _row = i),
                              child: Container(
                                height: 50,
                                padding: const EdgeInsets.symmetric(horizontal: 12),
                                decoration: BoxDecoration(
                                  color: i == _row ? C.brandSoft : null,
                                  borderRadius: BorderRadius.circular(8),
                                  border: const Border(bottom: BorderSide(color: C.border)),
                                ),
                                child: Row(children: [
                                  Expanded(
                                    child: Text(i < _notes.length ? fmtMoney(_notes[i] * 100) : tr('Монеты и мелочь (сумма)', 'Tangalar va mayda pul (summa)'),
                                        style: t(16)),
                                  ),
                                  Container(
                                    width: 110,
                                    height: 34,
                                    alignment: Alignment.centerRight,
                                    padding: const EdgeInsets.symmetric(horizontal: 10),
                                    decoration: BoxDecoration(
                                      color: C.surface,
                                      borderRadius: BorderRadius.circular(8),
                                      border: Border.all(color: i == _row ? C.brand : C.borderStrong, width: i == _row ? 2 : 1),
                                    ),
                                    child: Text(_counts[i].isEmpty ? '0' : _counts[i], style: t(16, w: FontWeight.w600)),
                                  ),
                                  SizedBox(
                                    width: 160,
                                    child: Text(fmtMoney(_rowSum(i)), textAlign: TextAlign.right, style: t(16, w: FontWeight.w700)),
                                  ),
                                ]),
                              ),
                            ),
                        ]),
                      ),
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
                          setState(() => _revealed = true);
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
