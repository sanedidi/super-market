// «Свои деньги (владелец)» в оплате поставщику (Figma «Правки 10 нояб» Б4):
// владелец заплатил из своего кармана — кассы не меняются, долг поставщику
// уменьшается. «Вклад в бизнес» — просто записываем; «Вернуть мне позже» —
// магазин должен владельцу (в «Долгах поставщикам» — «Владелец · вернуть себе»).
import 'package:flutter/material.dart';
import 'package:sm_core/sm_core.dart';

import '../ui/theme.dart';
import '../ui/widgets.dart';

/// Значения owner_funds для API.
const ownerContribution = 'contribution';
const ownerLoan = 'loan';

/// Строка «Свои деньги (владелец)» и под ней — «Вклад в бизнес» / «Вернуть мне позже».
class OwnerFundsOption extends StatelessWidget {
  const OwnerFundsOption({super.key, required this.selected, required this.mode, required this.amount, required this.onSelect, required this.onMode});

  final bool selected;

  /// ownerContribution или ownerLoan.
  final String mode;

  /// Сумма из поля — для подсказки «магазин будет должен вам …».
  final num? amount;
  final VoidCallback onSelect;
  final ValueChanged<String> onMode;

  @override
  Widget build(BuildContext context) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      AppCard(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        border: selected ? AppColors.primary : AppColors.line,
        onTap: onSelect,
        child: Row(children: [
          const IconBox(Icons.account_balance_wallet_rounded, bg: AppColors.primarySoft, fg: AppColors.primary, size: 40, iconSize: 20, radius: 12),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(tr('Свои деньги (владелец)', 'Oʻz pulim (egasi)'), style: AppText.bodyStrong.copyWith(fontWeight: FontWeight.w500)),
              Text(tr('Заплатил из своего кармана — кассы не меняются', 'Oʻz choʻntagimdan toʻladim — kassalar oʻzgarmaydi'), style: AppText.small),
            ]),
          ),
          const SizedBox(width: 8),
          Icon(selected ? Icons.radio_button_checked_rounded : Icons.radio_button_unchecked_rounded, color: selected ? AppColors.primary : AppColors.muted),
        ]),
      ),
      if (selected) ...[
        const SizedBox(height: 8),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(color: AppColors.primarySoft, borderRadius: BorderRadius.circular(18)),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(tr('Эти деньги…', 'Bu pul…'), style: AppText.bodyStrong.copyWith(fontSize: 14)),
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.all(4),
              decoration: BoxDecoration(color: AppColors.white, borderRadius: BorderRadius.circular(14), border: Border.all(color: AppColors.line)),
              child: Row(children: [
                _Seg(label: tr('Вклад в бизнес', 'Biznesga hissa'), on: mode == ownerContribution, onTap: () => onMode(ownerContribution)),
                const SizedBox(width: 4),
                _Seg(label: tr('Вернуть мне позже', 'Keyin qaytaraman'), on: mode == ownerLoan, onTap: () => onMode(ownerLoan)),
              ]),
            ),
            const SizedBox(height: 8),
            Text(
              mode == ownerLoan
                  ? tr('Магазин будет должен вам ${amount == null ? '' : '${money(amount)} '}— видно в «Долгах поставщикам» как «Владелец · вернуть себе». Вернёте себе из кассы, когда будут деньги.',
                      'Doʻkon sizga ${amount == null ? '' : '${money(amount)} '}qarzdor boʻladi — «Yetkazib beruvchilarga qarzlar»da «Egasi · oʻziga qaytarish» deb koʻrinadi. Pul boʻlganda kassadan oʻzingizga qaytarasiz.')
                  : tr('Записываем как ваш вклад в бизнес — возвращать не нужно.', 'Biznesga hissangiz sifatida yozamiz — qaytarish shart emas.'),
              style: AppText.small,
            ),
          ]),
        ),
      ],
    ]);
  }
}

class _Seg extends StatelessWidget {
  const _Seg({required this.label, required this.on, required this.onTap});

  final String label;
  final bool on;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Material(
        color: on ? AppColors.primary : Colors.transparent,
        borderRadius: BorderRadius.circular(10),
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 6),
            child: Text(label,
                textAlign: TextAlign.center,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppText.bodyStrong.copyWith(fontSize: 14, color: on ? AppColors.white : AppColors.ink)),
          ),
        ),
      ),
    );
  }
}
