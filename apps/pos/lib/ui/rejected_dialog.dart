import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:sm_core/sm_core.dart' show tr;

import '../core/journal.dart';
import '../core/money.dart';
import '../data/api.dart';
import '../data/outbox.dart';
import '../state/pos.dart';
import 'kit.dart';
import 'theme.dart';
import 'widgets.dart';

// «Не принято N» (Figma «Касса · «Не принято N» и зависшая смена на сервере»):
// НП1 — список операций, которые сервер отклонил, с причиной; НП2 — закрыть
// старую смену, оставшуюся открытой на сервере; НП3 — итог; НП4 — то же
// при открытии смены (open_shift_screen.dart).

/// НП1: плашка «Не принято N» в шапке или F11 → 0.
Future<void> showRejectedDialog(BuildContext context) async {
  final pos = context.read<PosController>();
  if (pos.failed == 0) return;
  final note = await showDialog<String>(context: context, barrierDismissible: false, builder: (_) => const _RejectedDialog());
  if (note != null && context.mounted) showPosNote(context, note);
}

/// НП3: короткое уведомление внизу экрана.
void showPosNote(BuildContext context, String text) {
  ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(
    behavior: SnackBarBehavior.floating,
    width: 520,
    backgroundColor: C.surface,
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12), side: const BorderSide(color: C.success, width: 1.5)),
    duration: const Duration(seconds: 6),
    content: Row(children: [
      Container(
        width: 30,
        height: 30,
        alignment: Alignment.center,
        decoration: const BoxDecoration(color: C.success, shape: BoxShape.circle),
        child: const Icon(Icons.check_rounded, color: Colors.white, size: 20),
      ),
      const SizedBox(width: 12),
      Expanded(child: Text(text, style: t(14, w: FontWeight.w600))),
    ]),
  ));
}

String _two(int v) => v.toString().padLeft(2, '0');

/// «20.10 в 18:02».
String fmtWhen(DateTime d) {
  final l = d.toLocal();
  return tr('${_two(l.day)}.${_two(l.month)} в ${_two(l.hour)}:${_two(l.minute)}', '${_two(l.day)}.${_two(l.month)} ${_two(l.hour)}:${_two(l.minute)} da');
}

String _time(DateTime d) {
  final l = d.toLocal();
  final n = DateTime.now();
  final hm = '${_two(l.hour)}:${_two(l.minute)}';
  return l.year == n.year && l.month == n.month && l.day == n.day ? hm : '${_two(l.day)}.${_two(l.month)} $hm';
}

/// Что за операция и на какую сумму.
(String, int?) describeOutboxItem(OutboxItem i) {
  final b = i.body;
  try {
    switch (i.kind) {
      case 'shift_open':
        return (tr('Открытие смены', 'Smenani ochish'), parseMoney(b['opening_cash']));
      case 'shift_close':
        return (tr('Закрытие смены · Z-отчёт', 'Smenani yopish · Z-hisobot'), (b['counted_cash'] as num?)?.toInt());
      case 'cash_move':
        final reason = '${b['reason'] ?? ''}'.trim();
        final name = b['kind'] == 'in' ? tr('Внесение', 'Kiritish') : tr('Изъятие', 'Olish');
        return (reason.isEmpty ? name : '$name · $reason', (b['amount'] as num?)?.toInt());
      case 'sale':
        final r = SaleRecord.fromJson(b);
        return (tr('Чек №${r.seq}', 'Chek №${r.seq}'), r.total);
      case 'debt_payment':
        final r = DebtPaymentRecord.fromJson(b);
        return (tr('Погашение долга · ${r.name}', 'Qarzni toʻlash · ${r.name}'), r.amount);
    }
  } catch (_) {}
  return (i.kind, null);
}

/// Операция ждёт только смену: уйдёт следом, когда сервер примет открытие смены
/// (после «Закрыть смену №N» или «Повторить все»).
bool waitsForShift(OutboxItem i) => i.errorCode == 'shift_not_sent';

/// Главная причина: сервер не принял открытие смены, потому что открыта другая.
bool isStaleShiftCause(OutboxItem i) => i.kind == 'shift_open' && i.errorCode == 'shift_open';

class _RejectedDialog extends StatefulWidget {
  const _RejectedDialog();

  @override
  State<_RejectedDialog> createState() => _RejectedDialogState();
}

class _RejectedDialogState extends State<_RejectedDialog> {
  ServerShift? _stale;
  bool _loading = false;
  bool _staleGone = false;
  String? _loadError;
  bool _busy = false;
  String? _error;

  PosController get pos => context.read<PosController>();

  /// Есть главная причина (при открытии окна или появилась, пока оно открыто) —
  /// узнать на сервере, какая смена открыта. Запрос — после кадра, не из build.
  void _loadIfNeeded(PosController pos) {
    if (pos.staleShiftBlocks && _stale == null && !_loading && !_staleGone && _loadError == null) {
      _loading = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _load();
      });
    }
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _loadError = null;
    });
    try {
      final sh = await pos.staleServerShift();
      if (!mounted) return;
      setState(() {
        _stale = sh;
        _staleGone = sh == null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _loadError = e is ApiError && e.isNetwork
          ? tr('Нет связи с сервером — не узнать, какая смена там открыта. Проверьте интернет.', 'Server bilan aloqa yoʻq — u yerda qaysi smena ochiqligini bilib boʻlmaydi. Internetni tekshiring.')
          : (e is ApiError ? e.message : tr('Сервер ответил непонятно — попробуйте ещё раз', 'Server tushunarsiz javob berdi — yana urinib koʻring')));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  /// НП2 → закрыть старую смену → всё заново.
  Future<void> _closeStale() async {
    final sh = _stale;
    if (sh == null || _busy) return;
    final total = pos.failed;
    final ok = await showDialog<bool>(context: context, barrierDismissible: false, builder: (_) => StaleShiftConfirm(shift: sh, resend: total));
    if (ok != true || !mounted) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    final err = await pos.closeServerShift(sh);
    if (!mounted) return;
    if (err != null) {
      setState(() {
        _busy = false;
        _error = err;
      });
      return;
    }
    final left = pos.failed + pos.queue;
    final sent = (total - left).clamp(0, total);
    Navigator.of(context).pop(tr('Смена №${sh.number} закрыта на сервере · отправлено $sent из $total',
        'Smena №${sh.number} serverda yopildi · $total tadan $sent tasi yuborildi'));
  }

  Future<void> _retryAll() async {
    if (_busy) return;
    final total = pos.failed;
    setState(() {
      _busy = true;
      _error = null;
    });
    await pos.retryFailed();
    if (!mounted) return;
    final left = pos.failed;
    if (left == 0) {
      Navigator.of(context).pop(pos.queue == 0
          ? tr('Отправлено $total из $total', '$total tadan $total tasi yuborildi')
          : tr('Операции снова в очереди — уйдут, когда будет связь', 'Amallar yana navbatda — aloqa boʻlganda yuboriladi'));
      return;
    }
    setState(() {
      _busy = false;
      if (!pos.staleShiftBlocks) {
        _stale = null;
        _staleGone = false;
        _loadError = null;
      }
      _error = left == total
          ? tr('Сервер снова не принял операции — причина в списке', 'Server amallarni yana qabul qilmadi — sabab roʻyxatda')
          : tr('Отправлено ${total - left}, не принято $left — причина в списке', '${total - left} ta yuborildi, $left tasi qabul qilinmadi — sabab roʻyxatda');
    });
  }

  KeyEventResult _onKey(FocusNode _, KeyEvent e) {
    if (e is! KeyDownEvent) return KeyEventResult.ignored;
    if (e.logicalKey == LogicalKeyboardKey.escape) {
      if (!_busy) Navigator.of(context).pop();
      return KeyEventResult.handled;
    }
    if (isEnter(e)) {
      // Пока старая смена открыта, «повторить» бессмысленно — Enter только по делу.
      if (_stale != null && pos.staleShiftBlocks) {
        _closeStale();
      } else if (_staleGone || !pos.staleShiftBlocks) {
        _retryAll();
      }
      return KeyEventResult.handled;
    }
    if (e.logicalKey == LogicalKeyboardKey.f5) {
      _retryAll();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final pos = context.watch<PosController>();
    _loadIfNeeded(pos);
    final items = pos.outbox.failed;
    final size = MediaQuery.sizeOf(context);
    return Focus(
      autofocus: true,
      onKeyEvent: _onKey,
      child: Dialog(
        backgroundColor: C.surface,
        insetPadding: const EdgeInsets.all(16),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: 1080, maxHeight: size.height - 48),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(28, 24, 28, 24),
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(tr('Не принято сервером · ${items.length}', 'Server qabul qilmagan · ${items.length}'), style: tb(26)),
                    const SizedBox(height: 6),
                    Text(
                      tr('Касса отправила эти операции, а сервер их отклонил. Они не потеряны — хранятся на кассе и уйдут, когда причина будет устранена.',
                          'Kassa bu amallarni yubordi, server esa rad etdi. Ular yoʻqolmagan — kassada saqlanadi va sabab bartaraf etilgach yuboriladi.'),
                      style: t(14, c: C.ts, h: 1.35),
                    ),
                  ]),
                ),
                const SizedBox(width: 16),
                SizedBox(
                  width: 150,
                  height: 46,
                  child: PosButton(label: tr('Закрыть', 'Yopish'), hint: 'Esc', center: true, onTap: _busy ? null : () => Navigator.of(context).pop()),
                ),
              ]),
              if (pos.staleShiftBlocks) ...[const SizedBox(height: 18), _cause()],
              const SizedBox(height: 18),
              Flexible(child: _table(items)),
              if (_error != null) ...[
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                  decoration: BoxDecoration(color: C.errorSoft, borderRadius: BorderRadius.circular(10)),
                  child: Text(_error!, style: t(13, w: FontWeight.w600, c: C.error)),
                ),
              ],
              const SizedBox(height: 16),
              Row(children: [
                Expanded(
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                    decoration: BoxDecoration(color: C.warningSoft, borderRadius: BorderRadius.circular(10)),
                    child: Text(
                      tr('Чеки уже пробиты покупателям. Пока их нет на сервере, выручка и остатки в панели не совпадают с кассой.',
                          'Cheklar xaridorlarga allaqachon berilgan. Ular serverda boʻlmaguncha, paneldagi tushum va qoldiqlar kassa bilan mos kelmaydi.'),
                      style: t(13, w: FontWeight.w500, c: C.warning),
                    ),
                  ),
                ),
                const SizedBox(width: 16),
                SizedBox(
                  width: 210,
                  height: 46,
                  child: PosButton(
                    label: _busy ? tr('Отправляю…', 'Yuborilmoqda…') : tr('Повторить все', 'Hammasini qayta'),
                    hint: 'F5',
                    center: true,
                    onTap: _busy ? null : _retryAll,
                  ),
                ),
              ]),
            ]),
          ),
        ),
      ),
    );
  }

  /// Баннер «Главная причина» (НП1).
  Widget _cause() {
    final sh = _stale;
    final String title;
    final String text;
    Widget? action;
    if (_loading) {
      title = tr('Главная причина: на сервере не закрыта прошлая смена', 'Asosiy sabab: serverda oldingi smena yopilmagan');
      text = tr('Узнаю на сервере, какая смена открыта…', 'Serverda qaysi smena ochiqligini aniqlayapman…');
    } else if (_loadError != null) {
      title = tr('Главная причина: на сервере не закрыта прошлая смена', 'Asosiy sabab: serverda oldingi smena yopilmagan');
      text = _loadError!;
      action = SizedBox(height: 46, child: PosButton(label: tr('Проверить снова', 'Qayta tekshirish'), center: true, onTap: _load));
    } else if (_staleGone) {
      title = tr('Прошлая смена уже закрыта на сервере', 'Oldingi smena serverda allaqachon yopilgan');
      text = tr('Например, в панели. Нажмите «Повторить все» — касса отправит всё заново.', 'Masalan, panelda. «Hammasini qayta» ni bosing — kassa hammasini qayta yuboradi.');
      action = SizedBox(
        height: 46,
        child: PosButton(label: tr('Отправить всё', 'Hammasini yuborish'), hint: 'Enter', center: true, bg: C.brand, fg: Colors.white, hintColor: C.brandLine, border: null, onTap: _busy ? null : _retryAll),
      );
    } else if (sh != null) {
      title = tr('Главная причина: на сервере не закрыта смена №${sh.number}', 'Asosiy sabab: serverda №${sh.number} smena yopilmagan');
      final who = sh.openedByName.isEmpty ? '' : ' · ${sh.openedByName}';
      text = tr(
          '${pos.catalog.settings.deviceName} · открыта ${fmtWhen(sh.openedAt)}$who · ${sh.salesCount} чеков на ${fmtMoney(sh.salesTotal)}. Пока она открыта, сервер не принимает новую смену — а следом и все операции этой смены.',
          '${pos.catalog.settings.deviceName} · ${fmtWhen(sh.openedAt)} ochilgan$who · ${sh.salesCount} ta chek, ${fmtMoney(sh.salesTotal)}. U ochiq ekan, server yangi smenani qabul qilmaydi — undan keyin esa shu smenadagi barcha amallarni ham.');
      action = SizedBox(
        height: 46,
        child: PosButton(
          label: _busy ? tr('Закрываю…', 'Yopilmoqda…') : tr('Закрыть смену №${sh.number} и отправить всё', '№${sh.number} smenani yopish va hammasini yuborish'),
          hint: 'Enter',
          center: true,
          bg: C.brand,
          fg: Colors.white,
          hintColor: C.brandLine,
          border: null,
          onTap: _busy ? null : _closeStale,
        ),
      );
    } else {
      return const SizedBox.shrink();
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
      decoration: BoxDecoration(color: C.errorSoft, borderRadius: BorderRadius.circular(12), border: Border.all(color: C.error.withValues(alpha: 0.35))),
      child: Row(children: [
        Container(
          width: 36,
          height: 36,
          alignment: Alignment.center,
          decoration: const BoxDecoration(color: C.error, shape: BoxShape.circle),
          child: Text('!', style: t(20, w: FontWeight.w700, c: Colors.white)),
        ),
        const SizedBox(width: 16),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title, style: t(17, w: FontWeight.w700)),
            const SizedBox(height: 4),
            Text(text, style: t(14, c: C.t2, h: 1.35)),
          ]),
        ),
        if (action != null) ...[const SizedBox(width: 16), ConstrainedBox(constraints: const BoxConstraints(maxWidth: 420), child: action)],
      ]),
    );
  }

  Widget _table(List<OutboxItem> items) {
    Widget head(String s, {TextAlign a = TextAlign.start}) => Text(s.toUpperCase(), textAlign: a, style: t(11, w: FontWeight.w600, c: C.ts));
    Widget row(int n, OutboxItem i) {
      final (name, amount) = describeOutboxItem(i);
      final main = isStaleShiftCause(i);
      final wait = waitsForShift(i);
      final reason = wait ? tr('Ждёт открытия смены', 'Smena ochilishini kutmoqda') : (i.error ?? '');
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        decoration: BoxDecoration(color: main ? C.brandSoft : C.surface, border: const Border(top: BorderSide(color: C.border))),
        child: Row(children: [
          SizedBox(width: 36, child: Text('$n', style: t(14, c: C.td))),
          Expanded(flex: 5, child: Text(name, style: t(14, w: FontWeight.w600))),
          SizedBox(width: 90, child: Text(_time(i.at), style: t(14))),
          SizedBox(width: 110, child: Text(amount == null ? '—' : fmtMoney(amount), textAlign: TextAlign.right, style: t(14))),
          const SizedBox(width: 16),
          Expanded(flex: 7, child: Text(reason, style: t(14, w: main ? FontWeight.w600 : FontWeight.w400, c: main ? C.error : (wait ? C.ts : C.tp)))),
          const SizedBox(width: 12),
          SizedBox(
            width: 140,
            child: Align(
              alignment: Alignment.centerRight,
              child: main
                  ? _Tag(tr('главная причина', 'asosiy sabab'), C.errorSoft, C.error)
                  : wait
                      ? _Tag(tr('уйдёт следом', 'keyin ketadi'), C.page, C.ts)
                      : const SizedBox.shrink(),
            ),
          ),
        ]),
      );
    }

    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(borderRadius: BorderRadius.circular(12), border: Border.all(color: C.border)),
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Container(
          color: C.subtle,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          child: Row(children: [
            SizedBox(width: 36, child: head('#')),
            Expanded(flex: 5, child: head(tr('Операция', 'Amal'))),
            SizedBox(width: 90, child: head(tr('Время', 'Vaqt'))),
            SizedBox(width: 110, child: head(tr('Сумма', 'Summa'), a: TextAlign.right)),
            const SizedBox(width: 16),
            Expanded(flex: 7, child: head(tr('Причина от сервера', 'Server sababi'))),
            const SizedBox(width: 152),
          ]),
        ),
        Flexible(
          child: ScrollConfiguration(
            behavior: const NoBarScroll(),
            child: ListView.builder(
              shrinkWrap: true,
              padding: EdgeInsets.zero,
              itemCount: items.length,
              itemBuilder: (_, k) => row(k + 1, items[k]),
            ),
          ),
        ),
      ]),
    );
  }
}

class _Tag extends StatelessWidget {
  const _Tag(this.label, this.bg, this.fg);
  final String label;
  final Color bg;
  final Color fg;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(999)),
        child: Text(label, style: t(12, w: FontWeight.w600, c: fg)),
      );
}

/// НП2: подтверждение — закрыть на сервере старую смену этой кассы.
/// Пересчёта нет: сумма в ящике — по расчёту сервера. Enter — да, Esc — нет.
class StaleShiftConfirm extends StatelessWidget {
  const StaleShiftConfirm({super.key, required this.shift, required this.resend});

  final ServerShift shift;

  /// Сколько операций касса отправит после закрытия; 0 — не писать.
  final int resend;

  @override
  Widget build(BuildContext context) {
    final pos = context.read<PosController>();
    Widget line(String a, String b, {bool bold = false, bool first = false}) => Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
          decoration: BoxDecoration(border: first ? null : const Border(top: BorderSide(color: C.border))),
          child: Row(children: [
            Expanded(child: Text(a, style: t(14, c: C.ts))),
            Text(b, style: t(14, w: bold ? FontWeight.w700 : FontWeight.w600)),
          ]),
        );
    final who = shift.openedByName.isEmpty ? '' : ' · ${shift.openedByName}';
    return Focus(
      autofocus: true,
      onKeyEvent: (_, e) {
        // Только нажатие: удержанный Enter с прошлого экрана не выбирает за кассира.
        if (e is! KeyDownEvent) return KeyEventResult.ignored;
        if (isEnter(e)) {
          Navigator.of(context).pop(true);
          return KeyEventResult.handled;
        }
        if (e.logicalKey == LogicalKeyboardKey.escape) {
          Navigator.of(context).pop(false);
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: Dialog(
        backgroundColor: C.surface,
        insetPadding: const EdgeInsets.all(16),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 620),
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(28, 26, 28, 24),
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Text(tr('Закрыть смену №${shift.number} на сервере?', '№${shift.number} smena serverda yopilsinmi?'), style: tb(24)),
              const SizedBox(height: 18),
              Container(
                clipBehavior: Clip.antiAlias,
                decoration: BoxDecoration(borderRadius: BorderRadius.circular(12), border: Border.all(color: C.border)),
                child: Column(children: [
                  line(tr('Касса', 'Kassa'), pos.catalog.settings.deviceName, first: true),
                  line(tr('Открыта', 'Ochilgan'), '${fmtWhen(shift.openedAt)}$who'),
                  line(tr('Чеков на сервере', 'Serverdagi cheklar'), '${shift.salesCount} · ${fmtMoney(shift.salesTotal)}'),
                  line(tr('Наличных по расчёту', 'Hisob boʻyicha naqd'), fmtMoney(shift.expectedCash), bold: true),
                ]),
              ),
              const SizedBox(height: 18),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                decoration: BoxDecoration(color: C.warningSoft, borderRadius: BorderRadius.circular(10)),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(tr('Пересчитывать ящик не нужно', 'Gʻaladonni qayta sanash shart emas'), style: t(14, w: FontWeight.w700, c: C.warning)),
                  const SizedBox(height: 6),
                  Text(
                    tr('Наличные этой смены уже лежат в ящике текущей. Смена закроется с суммой по расчёту, без расхождения. В панели у неё будет пометка «закрыта с кассы».',
                        'Bu smenaning naqd puli joriy smena gʻaladonida. Smena hisob boʻyicha summa bilan, farqsiz yopiladi. Panelda «kassadan yopilgan» belgisi boʻladi.'),
                    style: t(13, w: FontWeight.w500, c: C.warning, h: 1.35),
                  ),
                ]),
              ),
              if (resend > 0) ...[
                const SizedBox(height: 14),
                Text(
                    tr('После закрытия касса сама отправит $resend операций, которые сервер не принял.',
                        'Yopilgach, kassa server qabul qilmagan $resend ta amalni oʻzi yuboradi.'),
                    style: t(14, c: C.ts)),
              ],
              const SizedBox(height: 18),
              Row(mainAxisAlignment: MainAxisAlignment.end, children: [
                SizedBox(width: 160, height: 48, child: PosButton(label: tr('Отмена', 'Bekor qilish'), hint: 'Esc', center: true, onTap: () => Navigator.of(context).pop(false))),
                const SizedBox(width: 12),
                SizedBox(
                  width: 280,
                  height: 48,
                  child: PosButton(
                    label: tr('Закрыть смену №${shift.number}', '№${shift.number} smenani yopish'),
                    hint: 'Enter',
                    center: true,
                    bg: C.brand,
                    fg: Colors.white,
                    hintColor: C.brandLine,
                    border: null,
                    onTap: () => Navigator.of(context).pop(true),
                  ),
                ),
              ]),
            ]),
          ),
        ),
      ),
    );
  }
}

/// НП4: при открытии смены на сервере уже открыта смена этой кассы.
/// Enter — закрыть её и открыть новую, 2 — продолжить её, Esc — назад.
class StaleShiftOnOpen extends StatelessWidget {
  const StaleShiftOnOpen({super.key, required this.shift});

  final ServerShift shift;

  @override
  Widget build(BuildContext context) {
    final pos = context.read<PosController>();
    final who = shift.openedByName.isEmpty ? '' : ' · ${shift.openedByName}';
    return Focus(
      autofocus: true,
      onKeyEvent: (_, e) {
        // Только нажатие: удержанный Enter с прошлого экрана не выбирает за кассира.
        if (e is! KeyDownEvent) return KeyEventResult.ignored;
        if (isEnter(e)) {
          Navigator.of(context).pop('close');
          return KeyEventResult.handled;
        }
        if (printable(e) == '2') {
          Navigator.of(context).pop('continue');
          return KeyEventResult.handled;
        }
        if (e.logicalKey == LogicalKeyboardKey.escape) {
          Navigator.of(context).pop();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: Dialog(
        backgroundColor: C.surface,
        insetPadding: const EdgeInsets.all(16),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720),
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(28, 26, 28, 24),
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Text(tr('На сервере не закрыта смена №${shift.number}', 'Serverda №${shift.number} smena yopilmagan'), style: tb(24)),
              const SizedBox(height: 8),
              Text(
                tr('${pos.catalog.settings.deviceName} · открыта ${fmtWhen(shift.openedAt)}$who · ${shift.salesCount} чеков. Новую смену сервер не примет, пока эта открыта.',
                    '${pos.catalog.settings.deviceName} · ${fmtWhen(shift.openedAt)} ochilgan$who · ${shift.salesCount} ta chek. Bu smena ochiq ekan, server yangisini qabul qilmaydi.'),
                style: t(15, c: C.ts, h: 1.35),
              ),
              const SizedBox(height: 18),
              KeyCard(
                keyLabel: 'Enter',
                title: tr('Закрыть смену №${shift.number} и открыть новую', '№${shift.number} smenani yopib, yangisini ochish'),
                subtitle: tr('Обычный случай: прошлый Z-отчёт не дошёл до сервера. Наличные уже в ящике — смена закроется по расчёту, без пересчёта.',
                    'Odatiy holat: oldingi Z-hisobot serverga yetmagan. Naqd pul gʻaladonda — smena hisob boʻyicha, qayta sanamasdan yopiladi.'),
                style: KeyCardStyle.active,
                onTap: () => Navigator.of(context).pop('close'),
              ),
              const SizedBox(height: 10),
              KeyCard(
                keyLabel: '2',
                title: tr('Продолжить смену №${shift.number}', '№${shift.number} smenani davom ettirish'),
                subtitle: tr('Если это та же смена — например, касса переустановлена или данные очищены. Продажи пойдут в №${shift.number}.',
                    'Agar bu oʻsha smena boʻlsa — masalan, kassa qayta oʻrnatilgan. Sotuvlar №${shift.number} ga yoziladi.'),
                onTap: () => Navigator.of(context).pop('continue'),
              ),
              const SizedBox(height: 16),
              Align(
                alignment: Alignment.centerRight,
                child: SizedBox(width: 160, height: 46, child: PosButton(label: tr('Отмена', 'Bekor qilish'), hint: 'Esc', center: true, onTap: () => Navigator.of(context).pop())),
              ),
            ]),
          ),
        ),
      ),
    );
  }
}
