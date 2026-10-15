import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:sm_core/sm_core.dart';

import '../ui/theme.dart';
import '../ui/widgets.dart';
import 'kassa.dart';
import 'widgets.dart';

String _sum() => tr('сум', 'soʻm');

// ------------------------------------------------- К7 · способ оплаты

/// К7 · Способ оплаты: cash, card, qr, debt, mixed. null — назад к чеку.
Future<String?> methodSheet(BuildContext context, Kassa kassa, {required bool canDebt}) {
  final total = kassa.cart.total;
  bool has(String kind) => switch (kind) {
        'mixed' => kassa.method('cash') != null && kassa.method('card') != null,
        'debt' => canDebt,
        _ => kassa.method(kind) != null,
      };

  return showSheet<String>(context, (ctx) {
    Widget tile(String kind, IconData icon, String title, String sub, Color fg, Color bg) {
      final ok = has(kind);
      return Expanded(
        child: Opacity(
          opacity: ok ? 1 : 0.4,
          child: Material(
            color: AppColors.white,
            borderRadius: BorderRadius.circular(18),
            child: InkWell(
              borderRadius: BorderRadius.circular(18),
              onTap: ok ? () => Navigator.pop(ctx, kind) : null,
              child: Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(borderRadius: BorderRadius.circular(18), border: Border.all(color: AppColors.line)),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  IconBox(icon, bg: bg, fg: fg, size: 44, iconSize: 24, radius: 12),
                  const SizedBox(height: 10),
                  Text(title, style: AppText.title.copyWith(fontSize: 17)),
                  const SizedBox(height: 2),
                  Text(ok ? sub : tr('нет в магазине', 'doʻkonda yoʻq'), style: AppText.small.copyWith(fontSize: 12), maxLines: 2),
                ]),
              ),
            ),
          ),
        ),
      );
    }

    final mixed = has('mixed');
    return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(tr('Оплата', 'Toʻlov'), style: AppText.h2),
            Text(tr('${kassa.cart.count} поз. в чеке', 'Chekda ${kassa.cart.count} ta pozitsiya'), style: AppText.small),
          ]),
        ),
        Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
          Text(tr('К оплате', 'Toʻlovga'), style: AppText.caption),
          Text('${fmtMoney(total)} ${_sum()}', style: AppText.h2),
        ]),
      ]),
      const SizedBox(height: 16),
      Row(children: [
        tile('cash', Icons.payments_rounded, tr('Наличные', 'Naqd pul'), tr('сдача считается сама', 'qaytim oʻzi hisoblanadi'), AppColors.success, AppColors.successSoft),
        const SizedBox(width: 10),
        tile('card', Icons.credit_card_rounded, tr('Карта', 'Karta'), tr('терминал Uzcard · Humo', 'Uzcard · Humo terminali'), AppColors.blue, AppColors.blueSoft),
      ]),
      const SizedBox(height: 10),
      Row(children: [
        tile('qr', Icons.qr_code_2_rounded, 'Payme · Click', tr('по QR магазина', 'doʻkon QR kodi orqali'), AppColors.primary, AppColors.primarySoft),
        const SizedBox(width: 10),
        tile('debt', Icons.menu_book_rounded, tr('В долг', 'Qarzga'), tr('по номеру покупателя', 'xaridor raqami boʻyicha'), AppColors.warningInk, AppColors.warningSoft),
      ]),
      const SizedBox(height: 10),
      Opacity(
        opacity: mixed ? 1 : 0.4,
        child: AppCard(
          border: AppColors.line,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          onTap: mixed ? () => Navigator.pop(ctx, 'mixed') : null,
          child: Row(children: [
            const IconBox(Icons.call_split_rounded, size: 40, iconSize: 22, radius: 12),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(tr('Смешанная', 'Aralash'), style: AppText.bodyStrong.copyWith(fontSize: 16)),
                Text(tr('часть наличными, остаток картой', 'bir qismi naqd, qolgani karta bilan'), style: AppText.small.copyWith(fontSize: 12)),
              ]),
            ),
            const Icon(Icons.chevron_right_rounded, color: AppColors.muted),
          ]),
        ),
      ),
      const SizedBox(height: 6),
      TextButton(
        onPressed: () => Navigator.pop(ctx),
        child: Text(tr('Назад к чеку', 'Chekka qaytish'), style: AppText.bodyStrong.copyWith(color: AppColors.text2)),
      ),
    ]);
  });
}

// ------------------------------------------------------ К8 · наличные

/// К8 · Наличные: сколько дал покупатель, сдача сразу. Возвращает полученное (тийины).
class CashScreen extends StatefulWidget {
  const CashScreen({super.key, required this.total});

  final int total;

  @override
  State<CashScreen> createState() => _CashScreenState();
}

class _CashScreenState extends State<CashScreen> {
  String _input = '';

  /// Сумма с чипа («Ровно», купюры) — в тийинах, с копейками итога.
  int? _picked;

  int get _received => _picked ?? (_input.isEmpty ? 0 : parseMoney(_input));

  void _set(int tiyin) => setState(() {
        _picked = tiyin;
        _input = '';
      });

  @override
  Widget build(BuildContext context) {
    final total = widget.total;
    final received = _received;
    final change = received - total;
    final enough = received >= total;
    final quick = <(String, int)>[
      (tr('Ровно', 'Aniq'), total),
      for (final v in cashSuggestions(total)) (fmtMoney(v), v),
    ];
    return Scaffold(
      backgroundColor: AppColors.white,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Row(children: [
              RoundIcon(icon: Icons.arrow_back_rounded, onTap: () => Navigator.pop(context)),
              const SizedBox(width: 12),
              Expanded(child: Text(tr('Наличные', 'Naqd pul'), style: AppText.h3)),
              Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                Text(tr('К оплате', 'Toʻlovga'), style: AppText.caption),
                Text('${fmtMoney(total)} ${_sum()}', style: AppText.title),
              ]),
            ]),
            const SizedBox(height: 14),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              decoration: BoxDecoration(color: AppColors.soft, borderRadius: BorderRadius.circular(18), border: Border.all(color: AppColors.ink, width: 2)),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(tr('Получено от покупателя', 'Xaridordan olindi'), style: AppText.small.copyWith(fontWeight: FontWeight.w500)),
                Row(crossAxisAlignment: CrossAxisAlignment.baseline, textBaseline: TextBaseline.alphabetic, children: [
                  Text(fmtMoney(received), style: AppText.h1.copyWith(fontSize: 34)),
                  const SizedBox(width: 6),
                  Text(_sum(), style: AppText.bodyStrong.copyWith(color: AppColors.text2)),
                ]),
              ]),
            ),
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              decoration: BoxDecoration(color: enough ? AppColors.successSoft : AppColors.warningSoft, borderRadius: BorderRadius.circular(16)),
              child: Row(children: [
                Icon(enough ? Icons.change_circle_rounded : Icons.error_outline_rounded, color: enough ? AppColors.successInk : AppColors.warningInk),
                const SizedBox(width: 8),
                Text(enough ? tr('Сдача', 'Qaytim') : tr('Не хватает', 'Yetmaydi'),
                    style: AppText.bodyStrong.copyWith(color: enough ? AppColors.successInk : AppColors.warningInk)),
                const Spacer(),
                Text('${fmtMoney(change.abs())} ${_sum()}', style: AppText.h3.copyWith(color: enough ? AppColors.successInk : AppColors.warningInk)),
              ]),
            ),
            const SizedBox(height: 10),
            Wrap(spacing: 8, runSpacing: 8, children: [
              for (final (label, v) in quick)
                SizedBox(
                  width: (MediaQuery.sizeOf(context).width - 32 - 16) / 3,
                  child: PickChip(label: label, selected: _picked == v, onTap: () => _set(v)),
                ),
            ]),
            const Spacer(),
            Keypad(
              extra: '00',
              keyHeight: MediaQuery.sizeOf(context).height < 700 ? 42 : 50,
              onKey: (k) => setState(() {
                if (_picked != null) {
                  _picked = null;
                  _input = '';
                }
                _input = typeKey(_input, k, maxDigits: 10);
              }),
            ),
            const SizedBox(height: 10),
            BigButton(
              label: tr('Пробить чек', 'Chekni urish'),
              icon: Icons.receipt_long_rounded,
              onPressed: enough ? () => Navigator.pop(context, received) : null,
            ),
          ]),
        ),
      ),
    );
  }
}

// ---------------------------------------------- К9 · Payme · Click

/// К9 · Payme · Click по QR магазина: кассир видит, что оплата пришла, и
/// подтверждает. true — оплачено, false — другой способ.
class QrPayScreen extends StatelessWidget {
  const QrPayScreen({super.key, required this.total});

  final int total;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.white,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Row(children: [
              RoundIcon(icon: Icons.arrow_back_rounded, onTap: () => Navigator.pop(context, false)),
              const SizedBox(width: 12),
              const Text('Payme · Click', style: AppText.h3),
            ]),
            const Spacer(),
            const Center(child: IconBox(Icons.qr_code_2_rounded, bg: AppColors.primarySoft, fg: AppColors.primary, size: 96, iconSize: 60, radius: 28)),
            const SizedBox(height: 18),
            Text(tr('Покупатель платит по QR-коду магазина', 'Xaridor doʻkon QR kodi orqali toʻlaydi'), style: AppText.body.copyWith(color: AppColors.text2), textAlign: TextAlign.center),
            const SizedBox(height: 4),
            Text('${fmtMoney(total)} ${_sum()}', style: AppText.h1.copyWith(fontSize: 36), textAlign: TextAlign.center),
            const SizedBox(height: 18),
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(color: AppColors.warningSoft, borderRadius: BorderRadius.circular(14)),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Icon(Icons.hourglass_top_rounded, color: AppColors.warningInk),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    tr('Дождитесь уведомления Payme или Click о поступлении ${fmtMoney(total)} ${_sum()} и нажмите «Оплата пришла».',
                        'Payme yoki Click’dan ${fmtMoney(total)} ${_sum()} tushgani haqida xabarni kuting va «Toʻlov keldi»ni bosing.'),
                    style: AppText.small.copyWith(color: AppColors.warningInk),
                  ),
                ),
              ]),
            ),
            const Spacer(),
            BigButton(label: tr('Оплата пришла', 'Toʻlov keldi'), icon: Icons.check_rounded, onPressed: () => Navigator.pop(context, true)),
            const SizedBox(height: 10),
            BigButton(
              label: tr('Другой способ оплаты', 'Boshqa toʻlov usuli'),
              color: AppColors.soft,
              foreground: AppColors.ink,
              onPressed: () => Navigator.pop(context, false),
            ),
          ]),
        ),
      ),
    );
  }
}

// ---------------------------------------------------- смешанная оплата

/// Смешанная: сколько наличными, остаток — картой. Возвращает наличные (тийины).
Future<int?> mixedSheet(BuildContext context, int total) {
  var input = '';
  return showSheet<int>(
    context,
    (ctx) => StatefulBuilder(builder: (ctx, set) {
      final cash = input.isEmpty ? 0 : parseMoney(input);
      final ok = cash > 0 && cash < total;
      return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text(tr('Смешанная оплата', 'Aralash toʻlov'), style: AppText.h3),
        Text(tr('Итого ${fmtMoney(total)} ${_sum()}', 'Jami ${fmtMoney(total)} ${_sum()}'), style: AppText.small),
        const SizedBox(height: 12),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          decoration: BoxDecoration(color: AppColors.soft, borderRadius: BorderRadius.circular(16), border: Border.all(color: AppColors.ink, width: 2)),
          child: Row(children: [
            Text(tr('Наличными', 'Naqd'), style: AppText.bodyStrong.copyWith(color: AppColors.text2)),
            const Spacer(),
            Text('${input.isEmpty ? '0' : fmtMoney(cash)} ${_sum()}', style: AppText.h3),
          ]),
        ),
        const SizedBox(height: 8),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          decoration: BoxDecoration(color: AppColors.blueSoft, borderRadius: BorderRadius.circular(16)),
          child: Row(children: [
            Text(tr('Картой', 'Karta bilan'), style: AppText.bodyStrong.copyWith(color: AppColors.blue)),
            const Spacer(),
            Text('${fmtMoney(cash < total ? total - cash : 0)} ${_sum()}', style: AppText.h3.copyWith(color: AppColors.blue)),
          ]),
        ),
        const SizedBox(height: 8),
        Keypad(extra: '00', keyHeight: 50, onKey: (k) => set(() => input = typeKey(input, k, maxDigits: 10))),
        const SizedBox(height: 10),
        BigButton(label: tr('Пробить чек', 'Chekni urish'), icon: Icons.receipt_long_rounded, onPressed: ok ? () => Navigator.pop(ctx, cash) : null),
      ]);
    }),
  );
}

// ---------------------------------------------------------- в долг

/// В долг: покупатель по номеру, подтверждение кодом (по желанию), весь чек в долг.
Future<DebtPay?> debtSheet(BuildContext context, Kassa kassa) {
  return showSheet<DebtPay>(context, (ctx) => _DebtBody(kassa: kassa));
}

class _DebtBody extends StatefulWidget {
  const _DebtBody({required this.kassa});

  final Kassa kassa;

  @override
  State<_DebtBody> createState() => _DebtBodyState();
}

class _DebtBodyState extends State<_DebtBody> {
  final _phone = TextEditingController();
  final _name = TextEditingController();
  final _code = TextEditingController();
  DebtorView? _who;
  bool _busy = false;
  bool _codeSent = false;
  String? _err;

  int get _total => widget.kassa.cart.total;

  @override
  void dispose() {
    _phone.dispose();
    _name.dispose();
    _code.dispose();
    super.dispose();
  }

  Future<void> _run(Future<void> Function() f) async {
    setState(() {
      _busy = true;
      _err = null;
    });
    try {
      await f();
    } catch (e) {
      if (mounted) setState(() => _err = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _find() {
    final ph = uzPhone(_phone.text);
    if (ph == null) {
      setState(() => _err = tr('Номер: 9 цифр после +998', 'Raqam: +998 dan keyin 9 ta raqam'));
      return;
    }
    _run(() async {
      final w = await widget.kassa.lookupDebtor(ph);
      if (!mounted) return;
      setState(() {
        _who = w;
        _codeSent = false;
        if (w.name.isNotEmpty) _name.text = w.name;
      });
    });
  }

  void _sendCode() => _run(() async {
        await widget.kassa.sendDebtCode(_who!.phone);
        if (mounted) setState(() => _codeSent = true);
      });

  void _verify() => _run(() async {
        final w = await widget.kassa.verifyDebtCode(_who!.phone, _code.text.trim(), _name.text.trim());
        if (mounted) setState(() => _who = w);
      });

  @override
  Widget build(BuildContext context) {
    final w = _who;
    final children = <Widget>[
      Text(tr('В долг', 'Qarzga'), style: AppText.h3),
      Text(tr('Весь чек ${fmtMoney(_total)} ${_sum()} — в долг покупателю', 'Butun chek ${fmtMoney(_total)} ${_sum()} — xaridorga qarzga'), style: AppText.small),
      const SizedBox(height: 14),
      TextField(
        controller: _phone,
        keyboardType: TextInputType.phone,
        autofocus: w == null,
        inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(9)],
        decoration: InputDecoration(
          prefixText: '+998 ',
          hintText: '90 123 45 67',
          suffixIcon: IconButton(icon: const Icon(Icons.search_rounded), onPressed: _busy ? null : _find),
        ),
        onSubmitted: (_) => _find(),
        onChanged: (_) {
          if (_who != null) setState(() => _who = null);
        },
      ),
    ];
    if (w != null) {
      final enough = w.available >= _total;
      children.addAll([
        const SizedBox(height: 12),
        SectionCard(children: [
          Text(w.found && w.name.isNotEmpty ? w.name : tr('Новый покупатель', 'Yangi xaridor'), style: AppText.bodyStrong),
          const SizedBox(height: 4),
          Text(tr('Долг в магазине: ${fmtMoney(w.debt)} · лимит ${fmtMoney(w.limit)}', 'Doʻkondagi qarz: ${fmtMoney(w.debt)} · limit ${fmtMoney(w.limit)}'), style: AppText.small),
          Text(tr('Свободно: ${fmtMoney(w.available)} ${_sum()}', 'Boʻsh: ${fmtMoney(w.available)} ${_sum()}'),
              style: AppText.small.copyWith(color: enough ? AppColors.successInk : AppColors.warningInk, fontWeight: FontWeight.w600)),
          if (w.blocked) ...[
            const SizedBox(height: 4),
            Text(tr('Покупатель в стоп-листе — в долг не давать', 'Xaridor stop-roʻyxatda — qarzga bermang'), style: AppText.small.copyWith(color: AppColors.error)),
          ],
        ]),
        if (!w.found) ...[
          const SizedBox(height: 10),
          TextField(controller: _name, textCapitalization: TextCapitalization.words, decoration: InputDecoration(hintText: tr('Имя покупателя', 'Xaridor ismi'))),
        ],
        if (!w.verified && !w.blocked) ...[
          const SizedBox(height: 10),
          if (!_codeSent)
            Text(
              tr('Без подтверждения — до ${fmtMoney(w.unverifiedLimit)} ${_sum()}. С кодом лимит ${fmtMoney(w.defaultLimit)} ${_sum()}.',
                  'Tasdiqlashsiz — ${fmtMoney(w.unverifiedLimit)} ${_sum()} gacha. Kod bilan limit ${fmtMoney(w.defaultLimit)} ${_sum()}.'),
              style: AppText.small.copyWith(fontSize: 12),
            ),
          const SizedBox(height: 8),
          if (_codeSent)
            Row(children: [
              Expanded(
                child: TextField(
                  controller: _code,
                  keyboardType: TextInputType.number,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(6)],
                  decoration: InputDecoration(hintText: tr('Код от покупателя', 'Xaridordan kod')),
                ),
              ),
              const SizedBox(width: 8),
              ChipButton(label: tr('Подтвердить', 'Tasdiqlash'), onPressed: _busy ? null : _verify),
            ])
          else
            ChipButton(label: tr('Отправить код покупателю', 'Xaridorga kod yuborish'), onPressed: _busy ? null : _sendCode),
        ],
      ]);
    }
    if (_err != null) {
      children.addAll([const SizedBox(height: 8), Text(_err!, style: AppText.small.copyWith(color: AppColors.error))]);
    }
    final can = w != null && !w.blocked && w.available >= _total;
    children.addAll([
      const SizedBox(height: 14),
      BigButton(
        label: w == null ? tr('Найти покупателя', 'Xaridorni topish') : tr('В долг · ${fmtMoney(_total)} ${_sum()}', 'Qarzga · ${fmtMoney(_total)} ${_sum()}'),
        icon: w == null ? Icons.search_rounded : Icons.menu_book_rounded,
        busy: _busy,
        onPressed: w == null
            ? _find
            : can
                ? () => Navigator.pop(context, DebtPay(who: w, amount: _total, name: _name.text.trim().isNotEmpty ? _name.text.trim() : w.name))
                : null,
      ),
      if (w != null && !w.blocked && !can) ...[
        const SizedBox(height: 6),
        Text(tr('Не хватает лимита: свободно ${fmtMoney(w.available)} ${_sum()}', 'Limit yetmaydi: boʻsh ${fmtMoney(w.available)} ${_sum()}'),
            style: AppText.small.copyWith(color: AppColors.warningInk), textAlign: TextAlign.center),
      ],
    ]);
    return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: children);
  }
}

// ---------------------------------------------------------- К10 · оплачено

/// К10 · Оплачено: сумма, сдача, чек; «Новая продажа» — обратно к сканеру.
class DoneScreen extends StatelessWidget {
  const DoneScreen({super.key, required this.sale});

  final SaleDone sale;

  String _two(int n) => n.toString().padLeft(2, '0');

  @override
  Widget build(BuildContext context) {
    final s = sale;
    final t = s.soldAt;
    return Scaffold(
      backgroundColor: AppColors.white,
      body: SafeArea(
        child: Column(children: [
          Expanded(
            child: ListView(padding: const EdgeInsets.fromLTRB(16, 24, 16, 16), children: [
              Center(
                child: Container(
                  width: 80,
                  height: 80,
                  decoration: const BoxDecoration(color: AppColors.success, shape: BoxShape.circle),
                  child: const Icon(Icons.check_rounded, color: AppColors.white, size: 48),
                ),
              ),
              const SizedBox(height: 14),
              Text(tr('Оплачено', 'Toʻlandi'), style: AppText.h1.copyWith(fontSize: 28), textAlign: TextAlign.center),
              const SizedBox(height: 4),
              Text('${fmtMoney(s.total)} ${_sum()} · ${s.methodLabel}', style: AppText.body.copyWith(color: AppColors.text2), textAlign: TextAlign.center),
              if (s.change > 0) ...[
                const SizedBox(height: 10),
                Center(child: StatusChip(tr('Сдача ${fmtMoney(s.change)} ${_sum()}', 'Qaytim ${fmtMoney(s.change)} ${_sum()}'), icon: Icons.change_circle_rounded, tone: ChipTone.green)),
              ],
              if (s.debt != null) ...[
                const SizedBox(height: 10),
                Center(
                  child: StatusChip(
                    tr('Долг ${s.debt!.name.isEmpty ? s.debt!.who.phone : s.debt!.name}: ${fmtMoney(s.debt!.who.debt + s.debt!.amount)} ${_sum()}',
                        'Qarz ${s.debt!.name.isEmpty ? s.debt!.who.phone : s.debt!.name}: ${fmtMoney(s.debt!.who.debt + s.debt!.amount)} ${_sum()}'),
                    icon: Icons.menu_book_rounded,
                    tone: ChipTone.amber,
                  ),
                ),
              ],
              const SizedBox(height: 18),
              SectionCard(color: AppColors.bg, children: [
                Row(children: [
                  Text(s.number == null ? tr('Чек', 'Chek') : tr('Чек №${s.number}', 'Chek №${s.number}'), style: AppText.bodyStrong),
                  const Spacer(),
                  Text('${_two(t.day)}.${_two(t.month)} · ${_two(t.hour)}:${_two(t.minute)}', style: AppText.small.copyWith(fontSize: 12)),
                ]),
                const SizedBox(height: 8),
                for (final l in s.lines)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 3),
                    child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Expanded(
                        child: Text(l.fractional ? '${l.name} ${fmtQty(l.qty)} ${l.unit}' : '${l.name} × ${fmtQty(l.qty)}',
                            style: AppText.small.copyWith(color: AppColors.dark)),
                      ),
                      const SizedBox(width: 8),
                      Text(fmtMoney(l.total), style: AppText.small.copyWith(color: AppColors.ink, fontWeight: FontWeight.w500)),
                    ]),
                  ),
                const Divider(height: 18, color: AppColors.line),
                Row(children: [
                  Text(tr('Итого', 'Jami'), style: AppText.bodyStrong),
                  const Spacer(),
                  Text('${fmtMoney(s.total)} ${_sum()}', style: AppText.bodyStrong),
                ]),
                const SizedBox(height: 8),
                Text(
                  s.fiscal
                      ? tr('Фискальный чек пробит', 'Fiskal chek urildi')
                      : tr('Чек записан. Фискальный чек с телефона подключим позже — продажа ждёт фискализации.',
                          'Chek yozildi. Telefondan fiskal chekni keyinroq ulaymiz — sotuv fiskallashtirishni kutmoqda.'),
                  style: AppText.small.copyWith(fontSize: 12),
                ),
              ]),
            ]),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: BigButton(label: tr('Новая продажа', 'Yangi sotuv'), icon: Icons.qr_code_scanner_rounded, onPressed: () => Navigator.pop(context)),
          ),
        ]),
      ),
    );
  }
}
