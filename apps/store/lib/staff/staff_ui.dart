import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:sm_core/sm_core.dart';
import 'package:url_launcher/url_launcher.dart';

import '../ui/theme.dart';
import 'staff_logic.dart';

// Общие части экранов «Сотрудники», «Роли» и «Кассы».

void snack(BuildContext context, String text) => ScaffoldMessenger.of(context)
  ..hideCurrentSnackBar()
  ..showSnackBar(SnackBar(content: Text(text)));

Future<void> copyText(BuildContext context, String text, String what) async {
  await Clipboard.setData(ClipboardData(text: text));
  if (context.mounted) snack(context, tr('$what скопирован', '$what nusxalandi'));
}

/// Отправить текст в Telegram (чат выбирают в самом Telegram).
Future<void> shareTelegram(BuildContext context, String text) async {
  final uri = Uri.parse('https://t.me/share/url?url=${Uri.encodeComponent('https://super-market.uz')}&text=${Uri.encodeComponent(text)}');
  if (!await launchUrl(uri, mode: LaunchMode.externalApplication) && context.mounted) {
    snack(context, tr('Не удалось открыть Telegram', 'Telegram ochilmadi'));
  }
}

/// Строка «Логин / Временный пароль» с кнопкой «Копировать».
class CredentialRow extends StatelessWidget {
  const CredentialRow({super.key, required this.label, required this.value, this.big = false, this.copy = true});

  final String label;
  final String value;
  final bool big;
  final bool copy;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 12, 10),
      child: Row(children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(label, style: AppText.small.copyWith(fontSize: 12)),
            const SizedBox(height: 2),
            Text(big ? spacedPassword(value) : value, style: AppText.title.copyWith(fontSize: big ? 24 : 18, letterSpacing: big ? 2 : 0)),
          ]),
        ),
        if (copy)
          IconButton.outlined(
            onPressed: () => copyText(context, value, label),
            icon: const Icon(Icons.content_copy_rounded, size: 18),
            style: IconButton.styleFrom(side: const BorderSide(color: AppColors.line), backgroundColor: AppColors.white),
          ),
      ]),
    );
  }
}

/// Логин и пароль в серой рамке (С4, С5). [password] пустой — не показываем.
class CredentialsBox extends StatelessWidget {
  const CredentialsBox({super.key, required this.login, required this.password, this.header, this.note});

  final String login;
  final String password;
  final String? header;
  final String? note;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(color: AppColors.bg, borderRadius: BorderRadius.circular(16), border: Border.all(color: AppColors.line)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        if (header != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
            child: Row(children: [
              const Icon(Icons.smartphone_rounded, size: 18, color: AppColors.text2),
              const SizedBox(width: 6),
              Text(header!, style: AppText.caption.copyWith(fontSize: 13)),
            ]),
          ),
        CredentialRow(label: tr('Логин', 'Login'), value: login),
        if (password.isNotEmpty) CredentialRow(label: tr('Временный пароль', 'Vaqtinchalik parol'), value: password, big: true),
        if (note != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: Row(children: [
              const Icon(Icons.info_outline_rounded, size: 16, color: AppColors.text2),
              const SizedBox(width: 6),
              Expanded(child: Text(note!, style: AppText.small.copyWith(fontSize: 12))),
            ]),
          ),
      ]),
    );
  }
}

/// Шторка ввода ПИНа для кассы (4 цифры). null — передумали.
Future<String?> askPin(BuildContext context, {required String name}) async {
  final v = await promptSheet(
    context,
    title: tr('ПИН для кассы · $name', 'Kassa uchun PIN · $name'),
    text: tr('4 цифры — сотрудник вводит его при входе на кассу. У двух сотрудников ПИН не может совпадать.',
        '4 ta raqam — xodim uni kassaga kirishda kiritadi. Ikki xodimning PIN-kodi bir xil boʻlolmaydi.'),
    hint: '••••',
    keyboardType: TextInputType.number,
    maxLength: 4,
    confirm: tr('Сохранить', 'Saqlash'),
  );
  if (v == null) return null;
  final pin = v.trim();
  if (!validPin(pin)) {
    if (context.mounted) snack(context, tr('ПИН — ровно 4 цифры', 'PIN — aynan 4 ta raqam'));
    return null;
  }
  return pin;
}
