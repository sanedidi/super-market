import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../main.dart';
import '../state.dart';
import '../ui/theme.dart';
import '../ui/widgets.dart';

/// «Помощь и поддержка»: поддержка в Telegram, политика конфиденциальности.
class HelpScreen extends StatelessWidget {
  const HelpScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final p = context.watch<AppState>().profile;
    final support = '${p?['support_url'] ?? ''}';
    final privacy = '${p?['privacy_url'] ?? ''}';
    Widget card(IconData icon, Color color, String title, VoidCallback onTap) => Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: Material(
            color: AppColors.white,
            elevation: 3,
            shadowColor: const Color(0x22000000),
            borderRadius: BorderRadius.circular(AppRadius.xl),
            child: InkWell(
              borderRadius: BorderRadius.circular(AppRadius.xl),
              onTap: onTap,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 22),
                child: Row(children: [
                  Icon(icon, color: color, size: 28),
                  const SizedBox(width: 16),
                  Expanded(child: Text(title, style: AppText.body.copyWith(fontSize: 18))),
                ]),
              ),
            ),
          ),
        );
    Future<void> go(String url) async {
      try {
        await openUrl(url);
      } catch (e) {
        if (context.mounted) showError(context, e);
      }
    }

    return Scaffold(
      backgroundColor: AppColors.white,
      body: SafeArea(
        child: Column(children: [
          const PageHeader(title: 'Помощь и поддержка'),
          Expanded(
            child: ListView(padding: const EdgeInsets.fromLTRB(16, 16, 16, 24), children: [
              if (support.isNotEmpty) ...[
                card(Icons.headset_mic_rounded, AppColors.dark, 'Служба поддержки', () => go(support)),
                card(Icons.send_rounded, const Color(0xFF2AABEE), 'Телеграм бот', () => go(support)),
              ],
              if (privacy.isNotEmpty) card(Icons.description_rounded, AppColors.dark, 'Политика конфиденциальности', () => go(privacy)),
              if (support.isEmpty && privacy.isEmpty)
                const EmptyState(icon: Icons.help_outline_rounded, title: 'Скоро здесь будет помощь', text: 'Пока напишите нам через магазин или курьера.'),
            ]),
          ),
        ]),
      ),
    );
  }
}
