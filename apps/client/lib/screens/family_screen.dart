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
    final name = await _askText(context, title: 'Название семьи', hint: 'Например, Каримовы', action: 'Создать');
    if (name == null || name.isEmpty || !mounted) return;
    final api = context.read<Api>();
    await _run(() async {
      await api.post('/client/family', {'name': name});
      await _load();
    });
  }

  Future<void> _join() async {
    final code = await _askText(context,
        title: 'Код приглашения', hint: '8 букв и цифр', action: 'Вступить', caps: true, maxLength: 8);
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
                  Text('${m['phone'] ?? ''}', style: AppText.small),
                ]),
              ),
            ]),
            const SizedBox(height: 16),
            AppListRow(icon: Icons.edit_outlined, title: 'Подпись', subtitle: '${m['label']}'.isEmpty ? 'Мама, муж, дочь…' : '${m['label']}', onTap: () => Navigator.pop(ctx, 'label')),
            if (!me)
              AppListRow(icon: Icons.shopping_bag_outlined, title: 'Попросить купить', onTap: () => Navigator.pop(ctx, 'ask')),
            if (me)
              AppListRow(icon: Icons.logout_rounded, iconColor: AppColors.error, title: 'Выйти из семьи', divider: false, onTap: () => Navigator.pop(ctx, 'leave'))
            else if (iAmOwner)
              AppListRow(icon: Icons.person_remove_outlined, iconColor: AppColors.error, title: 'Исключить из семьи', divider: false, onTap: () => Navigator.pop(ctx, 'remove')),
          ]),
        ),
      ),
    );
    if (!mounted || action == null) return;
    final api = context.read<Api>();
    final id = m['user_id'];
    switch (action) {
      case 'label':
        final label = await _askText(context, title: 'Подпись', hint: 'Мама, муж, дочь…', action: 'Сохранить', initial: '${m['label']}', maxLength: 40);
        if (label == null) return;
        await _run(() async {
          await api.patch('/client/family/members/$id', {'label': label});
          await _load();
        });
      case 'ask':
        await _open(FamilyAskScreen(assigneeId: id as String));
      case 'leave':
        if (await _confirm('Выйти из семьи?', 'Общие просьбы перестанут приходить. Вернуться можно по новому приглашению.', 'Выйти')) {
          await _run(() async {
            await api.post('/client/family/leave');
            await _load();
          });
        }
      case 'remove':
        if (await _confirm('Исключить ${memberName(m)}?', 'Человек перестанет видеть просьбы семьи.', 'Исключить')) {
          await _run(() async {
            await api.delete('/client/family/members/$id');
            await _load();
          });
        }
    }
  }

  Future<bool> _confirm(String title, String text, String action) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Text(text),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Отмена')),
          TextButton(
            style: TextButton.styleFrom(foregroundColor: AppColors.error),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(action),
          ),
        ],
      ),
    );
    return ok == true;
  }

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
      body = EmptyState(icon: Icons.wifi_off_rounded, title: 'Не удалось загрузить', text: _error.toString(), action: 'Повторить', onAction: _load);
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
              const Expanded(child: Text('Моя семья', style: AppText.h2)),
            ]),
          ),
          Expanded(child: body),
        ]),
      ),
      bottomNavigationBar: f == null
          ? null
          : BottomActionBar(
              child: AppButton(label: 'Попросить купить', onPressed: () => _open(const FamilyAskScreen())),
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
          title: _history ? 'История' : 'Просьбы',
          action: _history ? 'Активные' : 'История',
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
              _history ? 'Здесь появятся выполненные просьбы.' : 'Просьб пока нет. Нажмите «Попросить купить» — мы напомним в нужное время.',
              style: AppText.small.copyWith(fontSize: 14),
            ),
          ),
        for (final r in requests) ...[
          RequestCard(request: r, onTap: () => _open(FamilyRequestScreen(id: r['id'] as String))),
          const SizedBox(height: 12),
        ],
        const SizedBox(height: 12),
        const SectionHeader(title: 'Участники', padding: EdgeInsets.zero),
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
                      Text('Пригласить в семью', style: AppText.bodyStrong.copyWith(color: AppColors.primary)),
                      const Text('Отправим ссылку в Telegram', style: AppText.caption),
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
            Text('Общий список покупок', style: AppText.title.copyWith(color: AppColors.white)),
            const SizedBox(height: 4),
            Text('Попросите купить — мы напомним в нужное время, а если забыли, привезём домой.',
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
        ? (owner ? 'Вы · владелец' : 'Вы')
        : [if (label.isNotEmpty) label, if (owner) 'владелец'].join(' · ');
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
          const Text('Как это работает', style: AppText.title),
          const SizedBox(height: 12),
          for (final (icon, text) in const [
            (Icons.group_add_outlined, 'Создайте семью и пригласите близких ссылкой в Telegram'),
            (Icons.shopping_bag_outlined, 'Попросите купить по дороге — список придёт уведомлением'),
            (Icons.notifications_active_outlined, 'Напомним в нужное время, а если не успели — привезём домой'),
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
      AppButton(label: 'Создать семью', loading: busy, onPressed: onCreate),
      const SizedBox(height: 10),
      AppButton(label: 'У меня есть код приглашения', type: AppButtonType.secondary, onPressed: busy ? null : onJoin),
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
    final text = 'Присоединяйся к нашей семье в Super Market — будем вместе вести список покупок. Код: $code';
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          const Text('Пригласить в семью', style: AppText.h3),
          const SizedBox(height: 8),
          const Text('Отправьте ссылку близкому. Она откроет нашего бота в Telegram и добавит в семью. Или продиктуйте код — его вводят в разделе «Моя семья».',
              style: AppText.small),
          const SizedBox(height: 16),
          GestureDetector(
            onTap: () {
              Clipboard.setData(ClipboardData(text: code));
              ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Код скопирован')));
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
          const Text('Код действует 7 дней и подходит одному человеку.', textAlign: TextAlign.center, style: AppText.caption),
          const SizedBox(height: 16),
          AppButton(
            label: 'Отправить в Telegram',
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
            label: 'Скопировать ссылку',
            type: AppButtonType.secondary,
            onPressed: () {
              Clipboard.setData(ClipboardData(text: '$text\n$url'));
              ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Ссылка скопирована')));
            },
          ),
        ]),
      ),
    );
  }
}

/// Нижний лист с одним полем ввода.
Future<String?> _askText(BuildContext context,
    {required String title, required String hint, required String action, String initial = '', bool caps = false, int maxLength = 60}) async {
  final ctrl = TextEditingController(text: initial);
  final v = await showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    backgroundColor: AppColors.white,
    builder: (ctx) => Padding(
      padding: EdgeInsets.fromLTRB(20, 0, 20, 20 + MediaQuery.viewInsetsOf(ctx).bottom),
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text(title, style: AppText.h3),
        const SizedBox(height: 16),
        TextField(
          controller: ctrl,
          autofocus: true,
          maxLength: maxLength,
          textCapitalization: caps ? TextCapitalization.characters : TextCapitalization.sentences,
          decoration: InputDecoration(hintText: hint, counterText: ''),
          onSubmitted: (v) => Navigator.pop(ctx, v.trim()),
        ),
        const SizedBox(height: 16),
        AppButton(label: action, onPressed: () => Navigator.pop(ctx, ctrl.text.trim())),
      ]),
    ),
  );
  ctrl.dispose();
  return v;
}
