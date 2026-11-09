import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:sm_core/sm_core.dart';
import 'package:url_launcher/url_launcher.dart';

import 'logic.dart';
import 'ui.dart';

// Продажник сам подключает магазин и выдаёт владельцу логин и пароль
// (Figma «SM Продажник · выдача логина», П15–П17).

Future<void> _copy(BuildContext context, String text, String what) async {
  await Clipboard.setData(ClipboardData(text: text));
  if (context.mounted) showSnack(context, tr('$what скопирован', '$what nusxalandi'));
}

/// Отправить текст в Telegram (выбор чата — в самом Telegram).
Future<void> shareTelegram(BuildContext context, String text) async {
  final uri = Uri.parse('https://t.me/share/url?url=${Uri.encodeComponent('https://super-market.uz')}&text=${Uri.encodeComponent(text)}');
  if (!await launchUrl(uri, mode: LaunchMode.externalApplication) && context.mounted) {
    showSnack(context, tr('Не удалось открыть Telegram', 'Telegram ochilmadi'));
  }
}

/// SMS владельцу с готовым текстом.
Future<void> shareSms(BuildContext context, String phone, String text) async {
  final uri = Uri.parse('sms:$phone?body=${Uri.encodeComponent(text)}');
  if (!await launchUrl(uri) && context.mounted) {
    showSnack(context, tr('Не удалось открыть SMS', 'SMS ochilmadi'));
  }
}

/// П15 — «Магазин подключён»: логин и временный пароль крупно, отправить
/// владельцу, как войти. [place] — ответ POST /field/visits (с полем owner).
class OwnerLoginScreen extends StatelessWidget {
  const OwnerLoginScreen({super.key, required this.place});

  final Map<String, dynamic> place;

  @override
  Widget build(BuildContext context) {
    final owner = (place['owner'] as Map?)?.cast<String, dynamic>() ?? const {};
    final name = '${place['name'] ?? ''}';
    final login = '${owner['login'] ?? ''}';
    final pass = '${owner['temp_password'] ?? ''}';
    final phone = '${owner['phone'] ?? ''}';
    final msg = ownerMessage(name, login, pass);
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) Navigator.of(context).pop(true);
      },
      child: Scaffold(
        body: SafeArea(
          child: ListView(padding: const EdgeInsets.fromLTRB(16, 20, 16, 16), children: [
            Center(
              child: Container(
                width: 72,
                height: 72,
                decoration: const BoxDecoration(color: AppColors.successSoft, shape: BoxShape.circle),
                child: const Icon(Icons.check_circle_rounded, color: AppColors.success, size: 44),
              ),
            ),
            const SizedBox(height: 14),
            Text(tr('«$name» подключён', '«$name» ulandi'), style: AppText.h2, textAlign: TextAlign.center),
            const SizedBox(height: 6),
            Text(
              tr('Отдайте владельцу логин и пароль — он войдёт в «SM Магазин» и сразу придумает свой пароль.',
                  'Login va parolni egasiga bering — u «SM Magazin»ga kiradi va darhol oʻz parolini oʻylab topadi.'),
              style: AppText.small.copyWith(fontSize: 14),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            OwnerCredentials(login: login, password: pass, big: true),
            const SizedBox(height: 14),
            BigButton(label: tr('Отправить владельцу в Telegram', 'Egasiga Telegram’da yuborish'), icon: Icons.send_rounded, onPressed: () => shareTelegram(context, msg)),
            const SizedBox(height: 10),
            Row(children: [
              if (phone.isNotEmpty) ...[
                Expanded(child: GrayButton(label: 'SMS', icon: Icons.sms_rounded, height: 52, onPressed: () => shareSms(context, phone, msg))),
                const SizedBox(width: 10),
              ],
              Expanded(
                child: GrayButton(
                  label: tr('Всё сразу', 'Hammasi'),
                  icon: Icons.content_copy_rounded,
                  height: 52,
                  onPressed: () => _copy(context, msg, tr('Текст', 'Matn')),
                ),
              ),
            ]),
            const SizedBox(height: 14),
            const _HowToEnter(),
            const SizedBox(height: 8),
            TextButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: Text(tr('Готово — продолжить обход', 'Tayyor — aylanishni davom ettirish'), style: AppText.bodyStrong.copyWith(color: AppColors.primary)),
            ),
          ]),
        ),
      ),
    );
  }
}

/// Логин и пароль с кнопками «Копировать». [password] пустой — владелец уже
/// сменил пароль (П17).
class OwnerCredentials extends StatelessWidget {
  const OwnerCredentials({super.key, required this.login, required this.password, this.big = false});

  final String login;
  final String password;
  final bool big;

  @override
  Widget build(BuildContext context) {
    Widget row(String label, String value, {bool large = false, bool copy = true, bool muted = false}) => Padding(
          padding: EdgeInsets.fromLTRB(16, big ? 14 : 10, 12, big ? 14 : 10),
          child: Row(children: [
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(label, style: AppText.small.copyWith(fontSize: 12)),
                const SizedBox(height: 2),
                Text(
                  value,
                  style: muted
                      ? AppText.small.copyWith(fontSize: 14)
                      : AppText.title.copyWith(fontSize: large ? 28 : (big ? 20 : 17), letterSpacing: large ? 2 : 0),
                ),
              ]),
            ),
            if (copy)
              OutlinedButton.icon(
                onPressed: () => _copy(context, value.replaceAll(' ', ''), label),
                icon: const Icon(Icons.content_copy_rounded, size: 16),
                label: Text(tr('Копировать', 'Nusxalash')),
                style: OutlinedButton.styleFrom(
                  foregroundColor: AppColors.ink,
                  backgroundColor: AppColors.white,
                  side: const BorderSide(color: AppColors.line),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                  visualDensity: VisualDensity.compact,
                ),
              ),
          ]),
        );
    return Container(
      decoration: BoxDecoration(color: AppColors.bg, borderRadius: BorderRadius.circular(16), border: Border.all(color: AppColors.line)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        row(tr('Логин', 'Login'), login),
        const Divider(height: 1, color: AppColors.line, indent: 16, endIndent: 16),
        if (password.isNotEmpty)
          row(tr('Временный пароль', 'Vaqtinchalik parol'), spacedPassword(password), large: big)
        else
          row(tr('Пароль', 'Parol'), tr('Владелец сменил — Super Market его не знает', 'Egasi almashtirgan — Super Market uni bilmaydi'), copy: false, muted: true),
        if (big && password.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
            child: Row(children: [
              const Icon(Icons.info_outline_rounded, size: 16, color: AppColors.text2),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  tr('Пароль виден в карточке магазина, пока владелец ни разу не вошёл.', 'Egasi bir marta ham kirmaguncha parol doʻkon kartasida koʻrinadi.'),
                  style: AppText.small.copyWith(fontSize: 12),
                ),
              ),
            ]),
          ),
      ]),
    );
  }
}

class _HowToEnter extends StatelessWidget {
  const _HowToEnter();

  @override
  Widget build(BuildContext context) {
    final steps = [
      tr('Скачать «SM Магазин» — App Store или Google Play', '«SM Magazin»ni yuklab olish — App Store yoki Google Play'),
      tr('Ввести логин и пароль', 'Login va parolni kiritish'),
      tr('Придумать свой пароль — временный перестанет работать', 'Oʻz parolini oʻylab topish — vaqtinchalik parol ishlamay qoladi'),
    ];
    return AppCard(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(tr('Как владельцу войти', 'Egasi qanday kiradi'), style: AppText.bodyStrong),
        const SizedBox(height: 8),
        for (final (i, s) in steps.indexed)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Row(children: [
              Container(
                width: 22,
                height: 22,
                alignment: Alignment.center,
                decoration: const BoxDecoration(color: AppColors.primarySoft, shape: BoxShape.circle),
                child: Text('${i + 1}', style: AppText.caption.copyWith(color: AppColors.primary)),
              ),
              const SizedBox(width: 10),
              Expanded(child: Text(s, style: AppText.body.copyWith(fontSize: 14))),
            ]),
          ),
      ]),
    );
  }
}

/// П16–П17 — в карточке магазина, который подключил этот продажник: вошёл ли
/// владелец, логин и пароль, «Отправить ещё раз», «Новый пароль».
/// [onChanged] — карточка с новым паролем (ответ сервера).
class OwnerLoginCard extends StatefulWidget {
  const OwnerLoginCard({super.key, required this.place, required this.onChanged});

  final Map<String, dynamic> place;
  final ValueChanged<Map<String, dynamic>> onChanged;

  @override
  State<OwnerLoginCard> createState() => _OwnerLoginCardState();
}

class _OwnerLoginCardState extends State<OwnerLoginCard> {
  bool _busy = false;

  Future<void> _newPassword(bool loggedIn) async {
    final ok = await confirmSheet(
      context,
      title: loggedIn ? tr('Сбросить пароль владельца?', 'Egasining paroli tashlansinmi?') : tr('Новый пароль?', 'Yangi parol?'),
      text: tr('Старый пароль сразу перестанет работать, все входы владельца закроются. Покажем новый временный пароль.',
          'Eski parol darhol ishlamay qoladi, egasining barcha kirishlari yopiladi. Yangi vaqtinchalik parolni koʻrsatamiz.'),
      confirm: tr('Дать новый пароль', 'Yangi parol berish'),
      icon: Icons.lock_reset_rounded,
    );
    if (!ok || !mounted) return;
    setState(() => _busy = true);
    try {
      final p = await context.read<Api>().post('/field/places/${widget.place['id']}/owner-password') as Map<String, dynamic>;
      if (!mounted) return;
      widget.onChanged(p);
      showSnack(context, tr('Новый пароль готов — отправьте его владельцу', 'Yangi parol tayyor — uni egasiga yuboring'));
    } on ApiError catch (e) {
      if (mounted) showSnack(context, e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final owner = (widget.place['owner'] as Map).cast<String, dynamic>();
    final login = '${owner['login'] ?? ''}';
    final pass = '${owner['temp_password'] ?? ''}';
    final phone = '${owner['phone'] ?? ''}';
    final loggedIn = pass.isEmpty;
    final name = '${widget.place['name'] ?? ''}';
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      if ('${owner['name'] ?? ''}'.isNotEmpty) ...[
        Row(children: [
          const Icon(Icons.person_rounded, size: 18, color: AppColors.text2),
          const SizedBox(width: 6),
          Expanded(child: Text('${owner['name']} · ${formatPhone(phone)}', style: AppText.small)),
        ]),
        const SizedBox(height: 10),
      ],
      Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(color: loggedIn ? AppColors.successSoft : AppColors.warningSoft, borderRadius: BorderRadius.circular(14)),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(loggedIn ? Icons.verified_user_rounded : Icons.schedule_rounded, color: loggedIn ? AppColors.success : AppColors.warning, size: 22),
          const SizedBox(width: 10),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(
                loggedIn
                    ? tr('Владелец вошёл${owner['last_login_at'] != null ? ' · ${dateTime(owner['last_login_at'])}' : ''}',
                        'Egasi kirdi${owner['last_login_at'] != null ? ' · ${dateTime(owner['last_login_at'])}' : ''}')
                    : tr('Владелец ещё не входил', 'Egasi hali kirmagan'),
                style: AppText.bodyStrong,
              ),
              Text(
                loggedIn
                    ? tr('Пароль сменил сам — магазин работает в «SM Магазин».', 'Parolni oʻzi almashtirdi — doʻkon «SM Magazin»da ishlayapti.')
                    : tr('Логин и пароль видны здесь до его первого входа.', 'Login va parol uning birinchi kirishigacha shu yerda koʻrinadi.'),
                style: AppText.small,
              ),
            ]),
          ),
        ]),
      ),
      const SizedBox(height: 10),
      OwnerCredentials(login: login, password: pass),
      const SizedBox(height: 10),
      if (!loggedIn) ...[
        BigButton(
          label: tr('Отправить ещё раз в Telegram', 'Telegram’da qayta yuborish'),
          icon: Icons.send_rounded,
          onPressed: () => shareTelegram(context, ownerMessage(name, login, pass)),
        ),
        const SizedBox(height: 10),
      ],
      GrayButton(
        label: loggedIn ? tr('Сбросить пароль — владелец забыл', 'Parolni tashlash — egasi unutgan') : tr('Новый пароль', 'Yangi parol'),
        icon: Icons.lock_reset_rounded,
        height: 52,
        busy: _busy,
        onPressed: () => _newPassword(loggedIn),
      ),
      const SizedBox(height: 6),
      Text(
        loggedIn
            ? tr('Покажем новый временный пароль, все входы владельца закроются.', 'Yangi vaqtinchalik parolni koʻrsatamiz, egasining barcha kirishlari yopiladi.')
            : tr('«Новый пароль» — если владелец потерял этот: старый сразу перестанет работать.',
                '«Yangi parol» — egasi buni yoʻqotgan boʻlsa: eskisi darhol ishlamay qoladi.'),
        style: AppText.small.copyWith(fontSize: 12),
      ),
    ]);
  }
}
