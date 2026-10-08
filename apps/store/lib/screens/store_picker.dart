import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:sm_core/sm_core.dart';

import '../state.dart';
import '../ui/theme.dart';

/// Выбор магазина (если их несколько).
Future<void> pickStore(BuildContext context) async {
  final st = context.read<StoreState>();
  final id = await showModalBottomSheet<String>(
    context: context,
    showDragHandle: true,
    backgroundColor: AppColors.white,
    builder: (ctx) => SafeArea(
      child: ListView(shrinkWrap: true, padding: const EdgeInsets.fromLTRB(16, 0, 16, 16), children: [
        Text(tr('Магазин', 'Doʻkon'), style: AppText.h3),
        const SizedBox(height: 8),
        for (final s in st.stores)
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.storefront_rounded),
            title: Text('${s['name']}', style: AppText.bodyStrong),
            subtitle: Text('${s['address'] ?? ''}', style: AppText.small),
            trailing: s['id'] == st.storeId ? const Icon(Icons.check_rounded, color: AppColors.primary) : null,
            onTap: () => Navigator.of(ctx).pop(s['id'] as String),
          ),
      ]),
    ),
  );
  if (id != null) await st.setStore(id);
}
