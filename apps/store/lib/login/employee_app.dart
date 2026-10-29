import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:sm_core/sm_core.dart';
import 'package:url_launcher/url_launcher.dart';

import '../lock/pin_screens.dart';
import '../ui/theme.dart';
import '../ui/widgets.dart';

/// Сотрудник (не владелец) вошёл в «SM Магазин»: для работы — «SM Сотрудник»
/// (Figma «Super Market · SM Сотрудник»). Тот же логин и пароль.
class EmployeeAppScreen extends StatefulWidget {
  const EmployeeAppScreen({super.key});

  @override
  State<EmployeeAppScreen> createState() => _EmployeeAppScreenState();
}

class _EmployeeAppScreenState extends State<EmployeeAppScreen> {
  String? _url;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    final platform = switch (defaultTargetPlatform) {
      TargetPlatform.iOS => 'ios',
      TargetPlatform.android => 'android',
      _ => null,
    };
    if (kIsWeb || platform == null) return;
    try {
      final r = await context.read<Api>().get('/public/app-version', {'app': 'employee', 'platform': platform, 'version': '0.0.0'}) as Map<String, dynamic>;
      final url = '${r['store_url'] ?? ''}';
      if (mounted && url.isNotEmpty) setState(() => _url = url);
    } catch (_) {
      // нет ссылки — только текст
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              const IconBox(Icons.badge_rounded, bg: AppColors.primary, fg: AppColors.white, size: 72, iconSize: 38, radius: 22),
              const SizedBox(height: 20),
              Text(tr('Для сотрудников — «SM Сотрудник»', 'Xodimlar uchun — «SM Xodim»'), style: AppText.h2, textAlign: TextAlign.center),
              const SizedBox(height: 10),
              Text(
                tr('«SM Магазин» — приложение владельца. Продажа, приход, пересчёт, списание и сборка заказов — в приложении «SM Сотрудник». Войдите в него тем же логином и паролем.',
                    '«SM Doʻkon» — egasining ilovasi. Sotish, kirim, qayta sanash, hisobdan chiqarish va buyurtma yigʻish — «SM Xodim» ilovasida. Unga shu login va parol bilan kiring.'),
                style: AppText.body.copyWith(color: AppColors.text2),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 24),
              if (_url != null) ...[
                BigButton(
                  label: tr('Скачать «SM Сотрудник»', '«SM Xodim» ni yuklab olish'),
                  icon: Icons.download_rounded,
                  onPressed: () => launchUrl(Uri.parse(_url!), mode: LaunchMode.externalApplication),
                ),
                const SizedBox(height: 10),
              ],
              BigButton(label: tr('Выйти', 'Chiqish'), icon: Icons.logout_rounded, color: AppColors.soft, foreground: AppColors.ink, onPressed: () => signOut(context)),
            ]),
          ),
        ),
      ),
    );
  }
}
