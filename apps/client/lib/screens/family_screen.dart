import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:sm_core/sm_core.dart';

import '../family_ui.dart';
import '../main.dart';
import '../state.dart';
import '../ui/theme.dart';
import '../ui/widgets.dart';
import 'family_ask_screen.dart';
import 'family_request_screen.dart';

/// «Моя семья» по макету Figma: баннер, просьбы, участники, приглашение,
/// кнопка «Попросить купить». Без семьи — создать или вступить по коду.
class FamilyScreen extends StatefulWidget {
  const FamilyScreen({super.key});

  @override
  State<FamilyScreen> createState() => _FamilyScreenState();
}

class _FamilyScreenState extends State<FamilyScreen> {
  List<Map<String, dynamic>>? _requests;
  Object? _error;
  bool _history = false;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    final state = context.read<AppState>();
    final api = context.read<Api>();
    try {
      await state.loadFamily();
      final items = state.family == null
          ? <Map<String, dynamic>>[]
          : await api.list('/client/family/requests', {if (_history) 'status': 'history', 'limit': 100});
      if (mounted) {
        setState(() {
          _requests = items;
          _error = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  Future<void> _open(Widget screen) async {
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => screen));
    if (mounted) _load();
  }

  Future<void> _run(Future<void> Function() f) async {
    setState(() => _busy = true);
    try {
      await f();
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // ------------------------------------------------------------ действия

  Future<void> _create() async {
    final name = await _askText(context,
        title: tr('Название семьи', 'Oila nomi'), hint: tr('Например, Каримовы', 'Masalan, Karimovlar'), action: tr('Создать', 'Yaratish'));
    if (name == null || name.isEmpty || !mounted) return;
    final api = context.read<Api>();
    await _run(() async {
      await api.post('/client/family', {'name': name});
      await _load();
    });
  }

  Future<void> _join() async {
    final code = await _askText(context,
        title: tr('Код приглашения', 'Taklif kodi'),
        hint: tr('8 букв и цифр', '8 ta harf va raqam'),
        action: tr('Вступить', 'Qoʻshilish'),
        caps: true,
        maxLength: 8);
    if (code == null || code.isEmpty || !mounted) return;
    final api = context.read<Api>();
    await _run(() async {
      await api.post('/client/family/join', {'code': code.toUpperCase()});
      await _load();
    });
  }

  Future<void> _invite() async {
    final api = context.read<Api>();
    await _run(() async {
      final inv = await api.post('/client/family/invites') as Map<String, dynamic>;
      if (!mounted) return;
      await showModalBottomSheet<void>(
        context: context,
        backgroundColor: AppColors.white,
        builder: (ctx) => _InviteSheet(invite: inv),
      );
    });
  }

  Future<void> _member(Map<String, dynamic> m, bool iAmOwner) async {
    final me = m['is_me'] == true;
    final action = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: AppColors.white,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Row(children: [
              MemberAvatar(id: '${m['user_id']}', name: memberName(m), me: me, size: 48),
              const SizedBox(width: 12),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(memberName(m), style: AppText.title),
                  Text(formatPhone(m['phone']), style: AppText.small),
                ]),
              ),
            ]),
            const SizedBox(height: 16),
            AppListRow(
                icon: Icons.edit_outlined,
                title: tr('Подпись', 'Yorliq'),
                subtitle: '${m['label']}'.isEmpty ? tr('Мама, муж, дочь…', 'Onam, erim, qizim…') : '${m['label']}',
                onTap: () => Navigator.pop(ctx, 'label')),
            if (!me)
              AppListRow(icon: Icons.shopping_bag_outlined, title: tr('Попросить купить', 'Xarid qilishni soʻrash'), onTap: () => Navigator.pop(ctx, 'ask')),
            if (me)
              AppListRow(
                  icon: Icons.logout_rounded,
                  iconColor: AppColors.error,
                  title: tr('Выйти из семьи', 'Oiladan chiqish'),
                  divider: false,
                  onTap: () => Navigator.pop(ctx, 'leave'))
            else if (iAmOwner)
              AppListRow(
                  icon: Icons.person_remove_outlined,
                  iconColor: AppColors.error,
                  title: tr('Исключить из семьи', 'Oiladan chiqarish'),
                  divider: false,
                  onTap: () => Navigator.pop(ctx, 'remove')),
          ]),
        ),
      ),
    );
    if (!mounted || action == null) return;
    final api = context.read<Api>();
    final id = m['user_id'];
    switch (action) {
      case 'label':
        final label = await _askText(context,
            title: tr('Подпись', 'Yorliq'),
            hint: tr('Мама, муж, дочь…', 'Onam, erim, qizim…'),
            action: tr('Сохранить', 'Saqlash'),
            initial: '${m['label']}',
            maxLength: 40);
        if (label == null) return;
        await _run(() async {
          await api.patch('/client/family/members/$id', {'label': label});
          await _load();
        });
      case 'ask':
        await _open(FamilyAskScreen(assigneeId: id as String));
      case 'leave':
        if (await _confirm(tr('Выйти из семьи?', 'Oiladan chiqasizmi?'),
            tr('Общие просьбы перестанут приходить. Вернуться можно по новому приглашению.', 'Umumiy iltimoslar kelmay qoladi. Yangi taklif orqali qaytish mumkin.'),
            tr('Выйти', 'Chiqish'))) {
          await _run(() async {
            await api.post('/client/family/leave');
            await _load();
          });
        }
      case 'remove':
        if (await _confirm(tr('Исключить ${memberName(m)}?', '${memberName(m)} oiladan chiqarilsinmi?'),
            tr('Человек перестанет видеть просьбы семьи.', 'U oila iltimoslarini koʻrmay qoladi.'), tr('Исключить', 'Chiqarish'))) {
          await _run(() async {
            await api.delete('/client/family/members/$id');
            await _load();
          });
        }
    }
  }

  Future<bool> _confirm(String title, String text, String action) => confirmSheet(context, title: title, text: text, confirm: action);

  // ------------------------------------------------------------ экран

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final f = state.family;
    final loaded = state.familyLoaded && _requests != null;

    Widget body;
    if (!loaded && _error == null) {
      body = const Center(child: CircularProgressIndicator());
    } else if (!loaded) {
      body = EmptyState(
          icon: Icons.wifi_off_rounded,
          title: tr('Не удалось загрузить', 'Yuklab boʻlmadi'),
          text: _error.toString(),
          action: tr('Повторить', 'Qayta urinish'),
          onAction: _load);
    } else if (f == null) {
      body = _NoFamily(busy: _busy, onCreate: _create, onJoin: _join);
    } else {
      body = _familyBody(f);
    }

    return Scaffold(
      backgroundColor: AppColors.bg,
      body: SafeArea(
        bottom: false,
        child: Column(children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: Row(children: [
              RoundIconButton(icon: Icons.arrow_back_ios_new_rounded, bg: AppColors.white, onTap: () => Navigator.of(context).pop()),
              const SizedBox(width: 12),
              Expanded(child: Text(tr('Моя семья', 'Mening oilam'), style: AppText.h2)),
            ]),
          ),
          Expanded(child: body),
        ]),
      ),
      bottomNavigationBar: f == null
          ? null
          : BottomActionBar(
              child: AppButton(label: tr('Попросить купить', 'Xarid qilishni soʻrash'), onPressed: () => _open(const FamilyAskScreen())),
            ),
    );
  }

  Widget _familyBody(Map<String, dynamic> f) {
    final members = ((f['members'] as List?) ?? const []).cast<Map<String, dynamic>>();
    final iAmOwner = f['my_role'] == 'owner';
    final requests = _requests ?? const [];
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 24), children: [
        const _Banner(),
        const SizedBox(height: 24),
        SectionHeader(
          title: _history ? tr('История', 'Tarix') : tr('Просьбы', 'Iltimoslar'),
          action: _history ? tr('Активные', 'Faollar') : tr('История', 'Tarix'),
          padding: EdgeInsets.zero,
          onAction: () {
            setState(() {
              _history = !_history;
              _requests = null;
            });
            _load();
          },
        ),
        const SizedBox(height: 12),
        if (requests.isEmpty)
          AppCard(
            child: Text(
              _history
                  ? tr('Здесь появятся выполненные просьбы.', 'Bu yerda bajarilgan iltimoslar paydo boʻladi.')
                  : tr('Просьб пока нет. Нажмите «Попросить купить» — мы напомним в нужное время.',
                      'Hozircha iltimoslar yoʻq. «Xarid qilishni soʻrash» tugmasini bosing — kerakli vaqtda eslatamiz.'),
              style: AppText.small.copyWith(fontSize: 14),
            ),
          ),
        for (final r in requests) ...[
          RequestCard(request: r, onTap: () => _open(FamilyRequestScreen(id: r['id'] as String))),
          const SizedBox(height: 12),
        ],
        const SizedBox(height: 12),
        SectionHeader(title: tr('Участники', 'Ishtirokchilar'), padding: EdgeInsets.zero),
        const SizedBox(height: 12),
        AppCard(
          padding: const EdgeInsets.symmetric(horizontal: 14),
          child: Column(children: [
            for (final m in members) _MemberRow(member: m, onTap: () => _member(m, iAmOwner)),
            InkWell(
              onTap: _busy ? null : _invite,
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Row(children: [
                  const IconBox(Icons.add_rounded, size: 40, bg: AppColors.soft, fg: AppColors.ink, radius: 20),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(tr('Пригласить в семью', 'Oilaga taklif qilish'), style: AppText.bodyStrong.copyWith(color: AppColors.primary)),
                      Text(tr('Отправим ссылку в Telegram', 'Havolani Telegramda yuboramiz'), style: AppText.caption),
                    ]),
                  ),
                  if (_busy) const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
                ]),
              ),
            ),
          ]),
        ),
      ]),
    );
  }
}

class _Banner extends StatelessWidget {
  const _Banner();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(color: AppColors.primary, borderRadius: BorderRadius.circular(AppRadius.lg)),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const IconBox(Icons.checklist_rounded, size: 52, bg: Color(0x2EFFFFFF), fg: AppColors.white),
        const SizedBox(width: 14),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(tr('Общий список покупок', 'Umumiy xaridlar roʻyxati'), style: AppText.title.copyWith(color: AppColors.white)),
            const SizedBox(height: 4),
            Text(
                tr('Попросите купить — мы напомним в нужное время, а если забыли, привезём домой.',
                    'Xarid qilishni soʻrang — kerakli vaqtda eslatamiz, unutilsa, uyga yetkazib beramiz.'),
                style: AppText.small.copyWith(color: const Color(0xDDFFFFFF))),
          ]),
        ),
      ]),
    );
  }
}

class _MemberRow extends StatelessWidget {
  const _MemberRow({required this.member, required this.onTap});
  final Map<String, dynamic> member;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final m = member;
    final me = m['is_me'] == true;
    final owner = m['role'] == 'owner';
    final label = '${m['label'] ?? ''}';
    final subtitle = me
        ? (owner ? tr('Вы · владелец', 'Siz · egasi') : tr('Вы', 'Siz'))
        : [if (label.isNotEmpty) label, if (owner) tr('владелец', 'egasi')].join(' · ');
    return InkWell(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 12),
        decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: AppColors.line))),
        child: Row(children: [
          MemberAvatar(id: '${m['user_id']}', name: memberName(m), me: me),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(memberName(m), style: AppText.bodyStrong),
              if (subtitle.isNotEmpty) Text(subtitle, style: AppText.caption),
            ]),
          ),
          const Icon(Icons.chevron_right_rounded, color: AppColors.ink),
        ]),
      ),
    );
  }
}

class _NoFamily extends StatelessWidget {
  const _NoFamily({required this.busy, required this.onCreate, required this.onJoin});
  final bool busy;
  final VoidCallback onCreate;
  final VoidCallback onJoin;

  @override
  Widget build(BuildContext context) {
    return ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 24), children: [
      const _Banner(),
      const SizedBox(height: 24),
      AppCard(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(tr('Как это работает', 'Bu qanday ishlaydi'), style: AppText.title),
          const SizedBox(height: 12),
          for (final (icon, text) in [
            (Icons.group_add_outlined, tr('Создайте семью и пригласите близких ссылкой в Telegram', 'Oila yarating va yaqinlaringizni Telegram havolasi orqali taklif qiling')),
            (Icons.shopping_bag_outlined, tr('Попросите купить по дороге — список придёт уведомлением', 'Yoʻl-yoʻlakay xarid qilishni soʻrang — roʻyxat bildirishnoma bilan keladi')),
            (Icons.notifications_active_outlined, tr('Напомним в нужное время, а если не успели — привезём домой', 'Kerakli vaqtda eslatamiz, ulgurmasangiz — uyga yetkazib beramiz')),
          ])
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Row(children: [
                IconBox(icon, size: 36),
                const SizedBox(width: 12),
                Expanded(child: Text(text, style: AppText.body.copyWith(fontSize: 14))),
              ]),
            ),
        ]),
      ),
      const SizedBox(height: 24),
      AppButton(label: tr('Создать семью', 'Oila yaratish'), loading: busy, onPressed: onCreate),
      const SizedBox(height: 10),
      AppButton(label: tr('У меня есть код приглашения', 'Menda taklif kodi bor'), type: AppButtonType.secondary, onPressed: busy ? null : onJoin),
    ]);
  }
}

class _InviteSheet extends StatelessWidget {
  const _InviteSheet({required this.invite});
  final Map<String, dynamic> invite;

  @override
  Widget build(BuildContext context) {
    final code = '${invite['code']}';
    final url = '${invite['url']}';
    final text = tr('Присоединяйся к нашей семье в Super Market — будем вместе вести список покупок. Код: $code',
        'Super Marketdagi oilamizga qoʻshil — xaridlar roʻyxatini birga yuritamiz. Kod: $code');
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(tr('Пригласить в семью', 'Oilaga taklif qilish'), style: AppText.h3),
          const SizedBox(height: 8),
          Text(
              tr('Отправьте ссылку близкому. Она откроет нашего бота в Telegram и добавит в семью. Или продиктуйте код — его вводят в разделе «Моя семья».',
                  'Havolani yaqiningizga yuboring. U Telegramdagi botimizni ochib, oilaga qoʻshadi. Yoki kodni ayting — u «Mening oilam» boʻlimida kiritiladi.'),
              style: AppText.small),
          const SizedBox(height: 16),
          GestureDetector(
            onTap: () {
              Clipboard.setData(ClipboardData(text: code));
              ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(tr('Код скопирован', 'Kod nusxalandi'))));
            },
            child: Container(
              padding: const EdgeInsets.symmetric(vertical: 16),
              decoration: BoxDecoration(color: AppColors.primarySoft, borderRadius: BorderRadius.circular(AppRadius.md)),
              child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                Text(code, style: AppText.h2.copyWith(color: AppColors.primary, letterSpacing: 4)),
                const SizedBox(width: 10),
                const Icon(Icons.copy_rounded, color: AppColors.primary, size: 20),
              ]),
            ),
          ),
          const SizedBox(height: 6),
          Text(tr('Код действует 7 дней и подходит одному человеку.', 'Kod 7 kun amal qiladi va faqat bir kishi uchun.'), textAlign: TextAlign.center, style: AppText.caption),
          const SizedBox(height: 16),
          AppButton(
            label: tr('Отправить в Telegram', 'Telegramda yuborish'),
            icon: Icons.send_rounded,
            onPressed: () async {
              try {
                await openUrl(Uri.https('t.me', '/share/url', {'url': url, 'text': text}).toString());
              } catch (e) {
                if (context.mounted) showError(context, e);
              }
            },
          ),
          const SizedBox(height: 10),
          AppButton(
            label: tr('Скопировать ссылку', 'Havolani nusxalash'),
            type: AppButtonType.secondary,
            onPressed: () {
              Clipboard.setData(ClipboardData(text: '$text\n$url'));
              ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(tr('Ссылка скопирована', 'Havola nusxalandi'))));
            },
          ),
        ]),
      ),
    );
  }
}

/// Нижний лист с одним полем ввода.
Future<String?> _askText(BuildContext context,
    {required String title, required String hint, required String action, String initial = '', bool caps = false, int maxLength = 60}) {
  return showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    backgroundColor: AppColors.white,
    builder: (ctx) => _AskTextSheet(title: title, hint: hint, action: action, initial: initial, caps: caps, maxLength: maxLength),
  );
}

/// Поле живёт вместе с листом: контроллер освобождается, когда лист
/// закрылся полностью (а не сразу после ответа, пока идёт анимация).
class _AskTextSheet extends StatefulWidget {
  const _AskTextSheet({required this.title, required this.hint, required this.action, required this.initial, required this.caps, required this.maxLength});
  final String title;
  final String hint;
  final String action;
  final String initial;
  final bool caps;
  final int maxLength;

  @override
  State<_AskTextSheet> createState() => _AskTextSheetState();
}

class _AskTextSheetState extends State<_AskTextSheet> {
  late final _ctrl = TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(20, 0, 20, 20 + MediaQuery.viewInsetsOf(context).bottom),
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text(widget.title, style: AppText.h3),
        const SizedBox(height: 16),
        TextField(
          controller: _ctrl,
          autofocus: true,
          maxLength: widget.maxLength,
          textCapitalization: widget.caps ? TextCapitalization.characters : TextCapitalization.sentences,
          decoration: InputDecoration(hintText: widget.hint, counterText: ''),
          onSubmitted: (v) => Navigator.pop(context, v.trim()),
        ),
        const SizedBox(height: 16),
        AppButton(label: widget.action, onPressed: () => Navigator.pop(context, _ctrl.text.trim())),
      ]),
    );
  }
}
