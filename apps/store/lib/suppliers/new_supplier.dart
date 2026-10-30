import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:sm_core/sm_core.dart';

import '../main.dart';
import '../state.dart';
import '../ui/theme.dart';
import '../ui/widgets.dart';

/// Нового поставщика заводит владелец и тот, кто принимает товар (право «Склад»):
/// прямо в выборе поставщика — в приходе, накладной, возврате; в SM Магазин и SM Сотрудник.
bool canCreateSupplier(BuildContext context) {
  final st = context.read<StoreState>();
  return st.can('counterparties.manage') || st.can('inventory.manage');
}

/// Завести поставщика. [name] — то, что уже набрали в поиске: создаём сразу;
/// пусто — спросим название. Вернёт поставщика или null.
Future<Map<String, dynamic>?> createSupplier(BuildContext context, {String? name}) async {
  final api = context.read<Api>();
  var n = name?.trim() ?? '';
  if (n.isEmpty) {
    final v = await promptSheet(context,
        title: tr('Новый поставщик', 'Yangi yetkazib beruvchi'),
        text: tr('Название фирмы или имя агента', 'Firma nomi yoki agent ismi'),
        confirm: tr('Добавить', 'Qoʻshish'),
        hint: tr('Например, Coca-Cola Bottlers', 'Masalan, Coca-Cola Bottlers'));
    n = v?.trim() ?? '';
  }
  if (n.isEmpty || !context.mounted) return null;
  try {
    return await api.post('/store/finance/counterparties', {'name': n}) as Map<String, dynamic>;
  } catch (e) {
    if (context.mounted) showMessage(context, e);
    return null;
  }
}

/// Строка «Новый поставщик» / «Добавить «Lay's»» в выборе поставщика.
class NewSupplierTile extends StatelessWidget {
  const NewSupplierTile({super.key, required this.query, required this.onTap, this.enabled = true});

  /// Текст поиска: есть — поставщик заведётся сразу с этим названием.
  final String query;
  final VoidCallback onTap;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final q = query.trim();
    return ListTile(
      contentPadding: EdgeInsets.zero,
      enabled: enabled,
      leading: const IconBox(Icons.add_business_rounded, bg: AppColors.primarySoft, fg: AppColors.primary, size: 40, iconSize: 22, radius: 12),
      title: Text(q.isEmpty ? tr('Новый поставщик', 'Yangi yetkazib beruvchi') : tr('Добавить «$q»', '«$q»ni qoʻshish'),
          style: AppText.bodyStrong.copyWith(color: AppColors.primary)),
      subtitle: q.isEmpty ? null : Text(tr('новый поставщик', 'yangi yetkazib beruvchi'), style: AppText.small),
      onTap: onTap,
    );
  }
}
