import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sm_core/sm_core.dart';

import '../ui/theme.dart';
import '../ui/widgets.dart';
import 'assistant_logic.dart';

/// М1 · подсказка на главной «Скажите „пришли товары“» — пока владелец не
/// открыл Шахзода [hintOpens] раза.
class AssistantHomeHint extends StatefulWidget {
  const AssistantHomeHint({super.key, required this.onTap});

  final VoidCallback onTap;

  @override
  State<AssistantHomeHint> createState() => _AssistantHomeHintState();
}

class _AssistantHomeHintState extends State<AssistantHomeHint> {
  bool _show = false;

  @override
  void initState() {
    super.initState();
    SharedPreferences.getInstance().then((p) {
      if (mounted) setState(() => _show = (p.getInt('assistant_opens') ?? 0) < hintOpens);
    }).catchError((_) {});
  }

  @override
  Widget build(BuildContext context) {
    if (!_show) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: AppCard(
        onTap: () {
          setState(() => _show = false);
          widget.onTap();
        },
        child: Row(children: [
          const IconBox(Icons.forum_rounded, bg: AppColors.primarySoft, fg: AppColors.primary),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(tr('Скажите «пришли товары»', '«Tovarlar keldi» deb ayting'), style: AppText.bodyStrong),
              Text(
                tr('Шахзод сделает приход, покажет остатки и что заказать', 'Shahzod kirim qiladi, qoldiqlarni va nima buyurtma qilishni koʻrsatadi'),
                style: AppText.small,
              ),
            ]),
          ),
          const Icon(Icons.chevron_right_rounded, color: AppColors.muted),
        ]),
      ),
    );
  }
}
