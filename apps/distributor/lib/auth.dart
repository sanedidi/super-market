import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';
import 'package:sm_core/sm_core.dart';
import 'package:sm_store/main.dart' show showMessage;
import 'package:sm_store/ui/theme.dart';
import 'package:sm_store/ui/widgets.dart';
import 'package:url_launcher/url_launcher.dart';

// Вход и регистрация «SM Агент» (Figma «SM Агент · регистрация сам»):
// А1 телефон → А2 код из SMS → (новый номер) А3 имя → А4 бренд из каталога
// (нет — А5 заявка на новый бренд) → склад (PointSetupScreen после входа).
// Кнопки всегда внизу экрана.

/// Данные регистрации между шагами.
class AgentReg {
  AgentReg({required this.phone, required this.ticket});

  final String phone;
  final String ticket;
  String fullName = '';
  String company = '';
}

/// Войти с токенами из ответа: закрыть шаги входа и сохранить токены —
/// приложение само откроет склад или главную.
Future<void> _signIn(BuildContext context, Map<String, dynamic> tokens) async {
  final api = context.read<Api>();
  Navigator.of(context).popUntil((r) => r.isFirst);
  await api.setTokens(tokens);
}

/// Страница шага: заголовок, полоска «шаг N из 3», контент и кнопка внизу.
class StepPage extends StatelessWidget {
  const StepPage({super.key, required this.title, this.subtitle, this.step, required this.children, required this.bottom});

  final String title;
  final String? subtitle;
  final int? step;
  final List<Widget> children;
  final Widget bottom;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(
        backgroundColor: AppColors.bg,
        title: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(title, style: AppText.title),
          if (subtitle != null) Text(subtitle!, style: AppText.small),
        ]),
      ),
      body: SafeArea(
        child: Column(children: [
          if (step != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Row(children: [
                for (var i = 1; i <= 3; i++) ...[
                  if (i > 1) const SizedBox(width: 6),
                  Expanded(
                    child: Container(
                      height: 4,
                      decoration: BoxDecoration(color: i <= step! ? AppColors.primary : AppColors.line, borderRadius: BorderRadius.circular(2)),
                    ),
                  ),
                ],
              ]),
            ),
          Expanded(child: ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 16), children: children)),
          Padding(padding: const EdgeInsets.fromLTRB(16, 8, 16, 12), child: bottom),
        ]),
      ),
    );
  }
}

/// Плашка-подсказка с иконкой.
class HintBox extends StatelessWidget {
  const HintBox({super.key, required this.text, this.icon = Icons.info_rounded, this.bg = AppColors.blueSoft, this.fg = AppColors.blue});

  final String text;
  final IconData icon;
  final Color bg;
  final Color fg;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(14)),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(icon, size: 18, color: fg),
        const SizedBox(width: 8),
        Expanded(child: Text(text, style: AppText.small.copyWith(color: fg))),
      ]),
    );
  }
}

// ------------------------------------------------------------------ А1

/// А1 · Вход по телефону — вход и регистрация одним экраном (как у курьера).
class AgentLoginScreen extends StatefulWidget {
  const AgentLoginScreen({super.key});

  @override
  State<AgentLoginScreen> createState() => _AgentLoginScreenState();
}

class _AgentLoginScreenState extends State<AgentLoginScreen> {
  final _phone = TextEditingController();
  bool _agree = false;
  bool _busy = false;
  String? _error;
  String _termsUrl = '';
  String _privacyUrl = '';

  @override
  void initState() {
    super.initState();
    _loadLinks();
  }

  @override
  void dispose() {
    _phone.dispose();
    super.dispose();
  }

  Future<void> _loadLinks() async {
    try {
      final c = await context.read<Api>().get('/client/config') as Map<String, dynamic>;
      if (!mounted) return;
      setState(() {
        _termsUrl = '${c['offer_url'] ?? ''}';
        _privacyUrl = '${c['privacy_url'] ?? ''}';
      });
    } catch (_) {
      // без ссылок вход всё равно работает
    }
  }

  Future<void> _open(String url) async {
    if (url.isEmpty) return;
    await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
  }

  Future<void> _submit() async {
    final phone = normalizeUzPhone(_phone.text);
    if (phone == null) {
      setState(() => _error = tr('Введите номер полностью: 9 цифр', 'Raqamni toʻliq kiriting: 9 ta raqam'));
      return;
    }
    FocusScope.of(context).unfocus();
    setState(() {
      _busy = true;
      _error = null;
    });
    var resendIn = 60;
    try {
      final r = await context.read<Api>().post('/auth/agent/otp/request', {'phone': phone}) as Map<String, dynamic>;
      resendIn = (r['resend_in'] as num?)?.toInt() ?? 60;
    } on ApiError catch (e) {
      if (e.code != 'too_many_requests') {
        if (mounted) setState(() => _error = e.message);
        if (mounted) setState(() => _busy = false);
        return;
      }
      // Код уже отправлен недавно — сразу на ввод кода.
      resendIn = (e.details['retry_after'] as num?)?.toInt() ?? 60;
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
      if (mounted) setState(() => _busy = false);
      return;
    }
    if (!mounted) return;
    setState(() => _busy = false);
    await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => AgentCodeScreen(phone: phone, resendIn: resendIn)));
  }

  @override
  Widget build(BuildContext context) {
    final link = AppText.small.copyWith(color: AppColors.primary, fontSize: 14, fontWeight: FontWeight.w600, decoration: TextDecoration.underline);
    final top = MediaQuery.paddingOf(context).top;
    return Scaffold(
      backgroundColor: AppColors.bg,
      body: Column(children: [
        // Красная шапка: Super Market + бейдж «Агент».
        Container(
          width: double.infinity,
          padding: EdgeInsets.fromLTRB(24, top + 28, 24, 28),
          decoration: const BoxDecoration(
            color: AppColors.primary,
            borderRadius: BorderRadius.vertical(bottom: Radius.circular(28)),
          ),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Expanded(
                child: Text('Super\nMarket',
                    style: TextStyle(fontFamily: 'Inter', fontSize: 44, height: 1.0, fontWeight: FontWeight.w800, color: AppColors.white, letterSpacing: -1)),
              ),
              const LangSwitch(),
            ]),
            const SizedBox(height: 14),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(color: AppColors.white.withValues(alpha: 0.2), borderRadius: BorderRadius.circular(16)),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                const Icon(Icons.local_shipping_rounded, size: 18, color: AppColors.white),
                const SizedBox(width: 6),
                Text(tr('Агент', 'Agent'), style: AppText.bodyStrong.copyWith(color: AppColors.white)),
              ]),
            ),
            const SizedBox(height: 14),
            Text(tr('Магазины, заказы и оплаты', 'Doʻkonlar, buyurtmalar va toʻlovlar'),
                style: AppText.body.copyWith(color: AppColors.white.withValues(alpha: 0.9), fontSize: 16)),
          ]),
        ),
        Expanded(
          child: SafeArea(
            top: false,
            child: Column(children: [
              Expanded(
                child: ListView(padding: const EdgeInsets.fromLTRB(20, 24, 20, 16), children: [
                  Text(tr('Вход по телефону', 'Telefon orqali kirish'), style: AppText.h2),
                  const SizedBox(height: 6),
                  Text(tr('Пришлём код по SMS. Новый номер — зарегистрируем за минуту', 'Kodni SMS orqali yuboramiz. Yangi raqamni bir daqiqada roʻyxatdan oʻtkazamiz'),
                      style: AppText.small.copyWith(fontSize: 14)),
                  const SizedBox(height: 18),
                  Text(tr('Номер телефона', 'Telefon raqami'), style: AppText.small),
                  const SizedBox(height: 6),
                  PhoneField(controller: _phone, errorText: _error, enabled: !_busy, onSubmitted: (_) => _agree ? _submit() : null),
                  const SizedBox(height: 16),
                  InkWell(
                    onTap: _busy ? null : () => setState(() => _agree = !_agree),
                    borderRadius: BorderRadius.circular(8),
                    child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Icon(_agree ? Icons.check_box_rounded : Icons.check_box_outline_blank_rounded, color: _agree ? AppColors.primary : AppColors.muted, size: 26),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text.rich(TextSpan(style: AppText.small.copyWith(color: AppColors.ink, fontSize: 14), children: [
                          TextSpan(text: tr('Я прочитал и согласен с ', 'Men Super Marketning ')),
                          TextSpan(text: tr('Условиями для агентов', 'agentlar uchun shartlari'), style: link, recognizer: TapGestureRecognizer()..onTap = () => _open(_termsUrl)),
                          TextSpan(text: tr(' и ', ' va ')),
                          TextSpan(text: tr('Политикой конфиденциальности', 'maxfiylik siyosati'), style: link, recognizer: TapGestureRecognizer()..onTap = () => _open(_privacyUrl)),
                          TextSpan(text: tr(' Super Market', ' bilan tanishdim va roziman')),
                        ])),
                      ),
                    ]),
                  ),
                  const SizedBox(height: 16),
                  HintBox(
                    icon: Icons.info_rounded,
                    bg: AppColors.white,
                    fg: AppColors.text2,
                    text: tr('Вход и регистрация — одним номером. Номер уже есть — сразу в приложение; новый — имя, бренд и склад.',
                        'Kirish va roʻyxatdan oʻtish — bitta raqam bilan. Raqam bor boʻlsa — darhol ilovaga; yangi boʻlsa — ism, brend va ombor.'),
                  ),
                ]),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
                child: BigButton(label: tr('Получить код', 'Kodni olish'), icon: Icons.arrow_forward_rounded, busy: _busy, onPressed: _agree ? _submit : null),
              ),
            ]),
          ),
        ),
      ]),
    );
  }
}

// ------------------------------------------------------------------ А2

/// А2 · Код из SMS — 6 цифр.
class AgentCodeScreen extends StatefulWidget {
  const AgentCodeScreen({super.key, required this.phone, required this.resendIn});

  final String phone;
  final int resendIn;

  @override
  State<AgentCodeScreen> createState() => _AgentCodeScreenState();
}

class _AgentCodeScreenState extends State<AgentCodeScreen> {
  final _code = TextEditingController();
  final _focus = FocusNode();
  Timer? _timer;
  late int _left = widget.resendIn;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _tick();
  }

  void _tick() {
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) return;
      setState(() => _left = _left > 0 ? _left - 1 : 0);
      if (_left == 0) t.cancel();
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    _code.dispose();
    _focus.dispose();
    super.dispose();
  }

  String get _mmss => '${_left ~/ 60}:${(_left % 60).toString().padLeft(2, '0')}';

  Future<void> _resend() async {
    try {
      final r = await context.read<Api>().post('/auth/agent/otp/request', {'phone': widget.phone}) as Map<String, dynamic>;
      if (!mounted) return;
      setState(() {
        _left = (r['resend_in'] as num?)?.toInt() ?? 60;
        _error = null;
      });
      _tick();
    } on ApiError catch (e) {
      if (!mounted) return;
      if (e.code == 'too_many_requests') {
        setState(() => _left = (e.details['retry_after'] as num?)?.toInt() ?? 60);
        _tick();
      } else {
        showMessage(context, e);
      }
    }
  }

  Future<void> _verify() async {
    final code = _code.text;
    if (code.length != 6 || _busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final r = await context.read<Api>().post('/auth/agent/otp/verify', {'phone': widget.phone, 'code': code}) as Map<String, dynamic>;
      if (!mounted) return;
      if (r['status'] == 'login') {
        await _signIn(context, (r['tokens'] as Map).cast<String, dynamic>());
        return;
      }
      final reg = AgentReg(phone: widget.phone, ticket: '${r['ticket']}');
      setState(() => _busy = false);
      await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => AgentNameScreen(reg: reg)));
    } on ApiError catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _code.clear();
      });
      if (e.code == 'store_employee') {
        await infoSheet(context, icon: Icons.storefront_rounded, title: tr('Это номер сотрудника магазина', 'Bu doʻkon xodimining raqami'), text: e.message);
      } else {
        setState(() => _error = e.message);
      }
    } catch (e) {
      if (mounted) {
        setState(() => _busy = false);
        showMessage(context, e);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(backgroundColor: AppColors.bg),
      body: SafeArea(
        child: Column(children: [
          Expanded(
            child: ListView(padding: const EdgeInsets.fromLTRB(20, 8, 20, 16), children: [
              Text(tr('Введите код', 'Kodni kiriting'), style: AppText.h1.copyWith(fontSize: 30)),
              const SizedBox(height: 8),
              Text(tr('Отправили SMS на ${formatPhone(widget.phone)}', '${formatPhone(widget.phone)} raqamiga SMS yubordik'),
                  style: AppText.body.copyWith(color: AppColors.text2, fontSize: 16)),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  style: TextButton.styleFrom(padding: EdgeInsets.zero, foregroundColor: AppColors.primary),
                  onPressed: () => Navigator.of(context).pop(),
                  icon: const Icon(Icons.edit_rounded, size: 18),
                  label: Text(tr('Изменить номер', 'Raqamni oʻzgartirish')),
                ),
              ),
              const SizedBox(height: 12),
              CodeBoxes(
                controller: _code,
                focusNode: _focus,
                error: _error != null,
                onChanged: (_) => setState(() => _error = null),
                onCompleted: (_) => _verify(),
              ),
              if (_error != null) ...[
                const SizedBox(height: 10),
                Text(_error!, style: AppText.small.copyWith(color: AppColors.error)),
              ],
              const SizedBox(height: 16),
              if (_left > 0)
                Row(children: [
                  const Icon(Icons.schedule_rounded, size: 18, color: AppColors.muted),
                  const SizedBox(width: 6),
                  Text(tr('Отправить код ещё раз через $_mmss', 'Kodni $_mmss dan keyin qayta yuborish'), style: AppText.small.copyWith(fontSize: 14)),
                ])
              else
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton(
                    style: TextButton.styleFrom(padding: EdgeInsets.zero, foregroundColor: AppColors.primary),
                    onPressed: _resend,
                    child: Text(tr('Отправить код ещё раз', 'Kodni qayta yuborish'), style: AppText.bodyStrong.copyWith(color: AppColors.primary)),
                  ),
                ),
              const SizedBox(height: 16),
              HintBox(
                icon: Icons.lock_rounded,
                bg: AppColors.white,
                fg: AppColors.text2,
                text: tr('Код действует 5 минут. После 5 неверных попыток вход на этот номер блокируется на 15 минут.',
                    'Kod 5 daqiqa amal qiladi. 5 marta notoʻgʻri kiritilsa, bu raqam bilan kirish 15 daqiqaga bloklanadi.'),
              ),
            ]),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
            child: ListenableBuilder(
              listenable: _code,
              builder: (context, _) => BigButton(label: tr('Подтвердить', 'Tasdiqlash'), busy: _busy, onPressed: _code.text.length == 6 ? _verify : null),
            ),
          ),
        ]),
      ),
    );
  }
}

// ------------------------------------------------------------------ А3

/// А3 · Как вас зовут — имя и компания (необязательно) · шаг 1 из 3.
class AgentNameScreen extends StatefulWidget {
  const AgentNameScreen({super.key, required this.reg});

  final AgentReg reg;

  @override
  State<AgentNameScreen> createState() => _AgentNameScreenState();
}

class _AgentNameScreenState extends State<AgentNameScreen> {
  late final _name = TextEditingController(text: widget.reg.fullName);
  late final _company = TextEditingController(text: widget.reg.company);

  @override
  void dispose() {
    _name.dispose();
    _company.dispose();
    super.dispose();
  }

  void _next() {
    if (_name.text.trim().isEmpty) {
      showMessage(context, tr('Как вас зовут?', 'Ismingiz qanday?'));
      return;
    }
    widget.reg
      ..fullName = _name.text.trim()
      ..company = _company.text.trim();
    Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => AgentBrandScreen(reg: widget.reg)));
  }

  @override
  Widget build(BuildContext context) {
    return StepPage(
      title: tr('Регистрация', 'Roʻyxatdan oʻtish'),
      subtitle: tr('Шаг 1 из 3 · о вас', '1-qadam / 3 · siz haqingizda'),
      step: 1,
      bottom: ListenableBuilder(
        listenable: _name,
        builder: (context, _) => BigButton(label: tr('Дальше', 'Keyingi'), onPressed: _name.text.trim().isEmpty ? null : _next),
      ),
      children: [
        Text(tr('Как вас зовут?', 'Ismingiz qanday?'), style: AppText.h2),
        const SizedBox(height: 6),
        Text(tr('Имя увидят магазины в запросах и заказах', 'Ismingizni doʻkonlar soʻrov va buyurtmalarda koʻradi'), style: AppText.small),
        const SizedBox(height: 18),
        TextField(
          controller: _name,
          autofocus: true,
          textCapitalization: TextCapitalization.words,
          textInputAction: TextInputAction.next,
          decoration: InputDecoration(labelText: tr('Имя и фамилия', 'Ism va familiya')),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _company,
          textCapitalization: TextCapitalization.sentences,
          decoration: InputDecoration(labelText: tr('Компания или ИП · необязательно', 'Kompaniya yoki YaTT · ixtiyoriy')),
        ),
        const SizedBox(height: 16),
        HintBox(
          text: tr('Если компании нет — магазины увидят ваше имя и бренд: «Алишер · Hydrolife Eco»',
              'Kompaniya boʻlmasa — doʻkonlar ismingiz va brendingizni koʻradi: «Alisher · Hydrolife Eco»'),
        ),
      ],
    );
  }
}

// ------------------------------------------------------------------ А4

/// А4 · Ваш бренд — поиск по каталогу Super Market · шаг 2 из 3.
/// [reg] — регистрация; без него — добавить бренды уже в приложении.
class AgentBrandScreen extends StatefulWidget {
  const AgentBrandScreen({super.key, this.reg});

  final AgentReg? reg;

  @override
  State<AgentBrandScreen> createState() => _AgentBrandScreenState();
}

class _AgentBrandScreenState extends State<AgentBrandScreen> {
  final _q = TextEditingController();
  final Map<String, String> _selected = {};
  List<Map<String, dynamic>> _items = [];
  Timer? _debounce;
  bool _loading = true;
  bool _busy = false;
  Object? _error;

  bool get _reg => widget.reg != null;

  @override
  void initState() {
    super.initState();
    _search();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _q.dispose();
    super.dispose();
  }

  void _changed(String _) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 300), _search);
    setState(() {});
  }

  Future<void> _search() async {
    setState(() => _loading = true);
    try {
      final api = context.read<Api>();
      final items = _reg
          ? await api.list('/auth/agent/brands', {'q': _q.text.trim(), 'ticket': widget.reg!.ticket})
          : await api.list('/store/supply/brands/search', {'q': _q.text.trim()});
      if (mounted) {
        setState(() {
          _items = items;
          _error = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = e);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _finish() async {
    if (_selected.isEmpty) return;
    setState(() => _busy = true);
    final api = context.read<Api>();
    try {
      if (_reg) {
        final reg = widget.reg!;
        final t = await api.post('/auth/agent/register', {
          'ticket': reg.ticket,
          'full_name': reg.fullName,
          'company': reg.company,
          'brand_ids': _selected.keys.toList(),
        }) as Map<String, dynamic>;
        if (!mounted) return;
        await _signIn(context, t);
        return;
      }
      await api.post('/store/supply/brands', {'brand_ids': _selected.keys.toList()});
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) {
        setState(() => _busy = false);
        showMessage(context, e);
      }
    }
  }

  Future<void> _request() async {
    final done = await Navigator.of(context).push<bool>(MaterialPageRoute(builder: (_) => BrandRequestScreen(reg: widget.reg, name: _q.text.trim())));
    if (done == true && mounted && !_reg) Navigator.of(context).pop(true);
  }

  String _label() {
    final n = _selected.length;
    if (_reg) return n == 0 ? tr('Выберите бренд', 'Brendni tanlang') : tr('Дальше · $n ${_brands(n)}', 'Keyingi · $n ta brend');
    return n == 0 ? tr('Выберите бренд', 'Brendni tanlang') : tr('Добавить · $n ${_brands(n)}', 'Qoʻshish · $n ta brend');
  }

  static String _brands(int n) {
    final m = n % 100;
    if (m >= 11 && m <= 14) return 'брендов';
    return switch (n % 10) { 1 => 'бренд', 2 || 3 || 4 => 'бренда', _ => 'брендов' };
  }

  @override
  Widget build(BuildContext context) {
    return StepPage(
      title: _reg ? tr('Регистрация', 'Roʻyxatdan oʻtish') : tr('Добавить бренд', 'Brend qoʻshish'),
      subtitle: _reg ? tr('Шаг 2 из 3 · бренд', '2-qadam / 3 · brend') : null,
      step: _reg ? 2 : null,
      bottom: BigButton(label: _label(), busy: _busy, onPressed: _selected.isEmpty ? null : _finish),
      children: [
        Text(tr('Какой бренд вы возите?', 'Qaysi brendni yetkazasiz?'), style: AppText.h2),
        const SizedBox(height: 14),
        TextField(
          controller: _q,
          onChanged: _changed,
          textInputAction: TextInputAction.search,
          decoration: InputDecoration(
            hintText: tr('Название бренда', 'Brend nomi'),
            prefixIcon: const Icon(Icons.search_rounded),
            suffixIcon: _q.text.isEmpty
                ? null
                : IconButton(
                    icon: const Icon(Icons.close_rounded),
                    onPressed: () {
                      _q.clear();
                      _changed('');
                    },
                  ),
          ),
        ),
        if (_selected.isNotEmpty) ...[
          const SizedBox(height: 10),
          Wrap(spacing: 6, runSpacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: [
            Text(tr('Выбрано:', 'Tanlandi:'), style: AppText.small),
            for (final e in _selected.entries)
              InputChip(
                label: Text(e.value),
                backgroundColor: AppColors.ink,
                labelStyle: AppText.small.copyWith(color: AppColors.white, fontWeight: FontWeight.w600),
                deleteIconColor: AppColors.white,
                onDeleted: () => setState(() => _selected.remove(e.key)),
              ),
          ]),
        ],
        const SizedBox(height: 12),
        if (_error != null && _items.isEmpty)
          Padding(padding: const EdgeInsets.all(16), child: Text('$_error', style: AppText.small.copyWith(color: AppColors.error)))
        else if (_loading && _items.isEmpty)
          const Padding(padding: EdgeInsets.all(24), child: Center(child: CircularProgressIndicator()))
        else if (_items.isNotEmpty)
          AppCard(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            child: Column(children: [
              for (var i = 0; i < _items.length; i++) ...[
                if (i > 0) const Divider(height: 1),
                _BrandRow(
                  brand: _items[i],
                  selected: _selected.containsKey('${_items[i]['id']}'),
                  onTap: () => setState(() {
                    final id = '${_items[i]['id']}';
                    if (_selected.containsKey(id)) {
                      _selected.remove(id);
                    } else {
                      _selected[id] = '${_items[i]['name']}';
                    }
                  }),
                ),
              ],
            ]),
          )
        else
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Text(tr('Такого бренда в каталоге нет — запросите новый.', 'Bunday brend katalogda yoʻq — yangisini soʻrang.'), style: AppText.small),
          ),
        const SizedBox(height: 12),
        _NoBrandCard(onTap: _request),
        const SizedBox(height: 10),
        Text(tr('Один бренд могут возить несколько агентов — каждый видит только свои магазины', 'Bitta brendni bir nechta agent yetkazishi mumkin — har biri faqat oʻz doʻkonlarini koʻradi'),
            style: AppText.small),
      ],
    );
  }
}

/// Цветной кружок с инициалами бренда.
class BrandAvatar extends StatelessWidget {
  const BrandAvatar(this.name, {super.key, this.size = 40, this.logo});

  final String name;
  final double size;
  final String? logo;

  static const _palette = [
    (Color(0xFFDBEAFE), Color(0xFF1D4ED8)),
    (Color(0xFFDCFCE7), Color(0xFF15803D)),
    (Color(0xFFFEF3C7), Color(0xFFB45309)),
    (Color(0xFFEDE9FE), Color(0xFF6D28D9)),
    (Color(0xFFFCE7F3), Color(0xFFBE185D)),
    (Color(0xFFE0F2FE), Color(0xFF0369A1)),
  ];

  @override
  Widget build(BuildContext context) {
    final words = name.trim().split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();
    final ini = words.isEmpty ? '?' : (words.length == 1 ? words[0].substring(0, words[0].length >= 2 ? 2 : 1) : '${words[0][0]}${words[1][0]}').toUpperCase();
    final c = _palette[name.hashCode.abs() % _palette.length];
    final url = logo ?? '';
    return ClipRRect(
      borderRadius: BorderRadius.circular(size / 2),
      child: Container(
        width: size,
        height: size,
        color: c.$1,
        alignment: Alignment.center,
        child: url.isNotEmpty
            ? Image.network(url, width: size, height: size, fit: BoxFit.cover, errorBuilder: (_, __, ___) => Text(ini, style: AppText.bodyStrong.copyWith(color: c.$2)))
            : Text(ini, style: AppText.bodyStrong.copyWith(color: c.$2, fontSize: size * 0.36)),
      ),
    );
  }
}

class _BrandRow extends StatelessWidget {
  const _BrandRow({required this.brand, required this.selected, required this.onTap});

  final Map<String, dynamic> brand;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final products = (brand['products'] as num?)?.toInt() ?? 0;
    final agents = (brand['agents'] as num?)?.toInt() ?? 0;
    final sub = [
      if ('${brand['category'] ?? ''}'.isNotEmpty) '${brand['category']}',
      if (products > 0) tr('$products товаров в каталоге', 'katalogda $products ta mahsulot'),
      if (agents > 0) tr('агентов: $agents', 'agentlar: $agents'),
    ].join(' · ');
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Row(children: [
          BrandAvatar('${brand['name']}'),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('${brand['name']}', style: AppText.bodyStrong),
              if (sub.isNotEmpty) Text(sub, style: AppText.small),
            ]),
          ),
          Icon(selected ? Icons.check_circle_rounded : Icons.radio_button_unchecked_rounded, color: selected ? AppColors.primary : AppColors.muted),
        ]),
      ),
    );
  }
}

class _NoBrandCard extends StatelessWidget {
  const _NoBrandCard({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppColors.white,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(borderRadius: BorderRadius.circular(16), border: Border.all(color: AppColors.muted, width: 1)),
          child: Row(children: [
            const IconBox(Icons.add_rounded, bg: AppColors.primarySoft, fg: AppColors.primary, size: 40, iconSize: 22, radius: 12),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(tr('Нет моего бренда', 'Mening brendim yoʻq'), style: AppText.bodyStrong),
                Text(tr('Запросить новый — Super Market рассмотрит заявку', 'Yangisini soʻrash — Super Market arizani koʻrib chiqadi'), style: AppText.small),
              ]),
            ),
            const Icon(Icons.chevron_right_rounded, color: AppColors.muted),
          ]),
        ),
      ),
    );
  }
}

// ------------------------------------------------------------------ А5

/// А5 · Нет бренда — заявка на новый: название, логотип, категория,
/// производитель, комментарий. [reg] — заявка при регистрации; [edit] —
/// исправить заявку (ждёт проверки или отклонена).
class BrandRequestScreen extends StatefulWidget {
  const BrandRequestScreen({super.key, this.reg, this.edit, this.name = ''});

  final AgentReg? reg;
  final Map<String, dynamic>? edit;
  final String name;

  @override
  State<BrandRequestScreen> createState() => _BrandRequestScreenState();
}

class _BrandRequestScreenState extends State<BrandRequestScreen> {
  late final _name = TextEditingController(text: '${widget.edit?['name'] ?? widget.name}');
  late final _maker = TextEditingController(text: '${widget.edit?['manufacturer'] ?? ''}');
  late final _comment = TextEditingController(text: '${widget.edit?['comment'] ?? ''}');
  List<Map<String, dynamic>> _cats = [];
  String? _cat;
  Uint8List? _logo;
  late String _logoUrl = '${widget.edit?['logo_url'] ?? ''}';
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _cat = widget.edit?['category_id'] as String?;
    _loadCats();
  }

  @override
  void dispose() {
    _name.dispose();
    _maker.dispose();
    _comment.dispose();
    super.dispose();
  }

  Future<void> _loadCats() async {
    try {
      final api = context.read<Api>();
      final reg = widget.reg;
      final items = reg != null ? await api.list('/auth/agent/categories', {'ticket': reg.ticket}) : await api.list('/store/supply/categories');
      if (mounted) setState(() => _cats = items);
    } catch (_) {
      // категория необязательна
    }
  }

  Future<void> _pickLogo() async {
    final source = await showSheet<ImageSource>(
      context,
      (ctx) => Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        SheetHeader(title: tr('Логотип или фото упаковки', 'Logotip yoki qadoq rasmi')),
        const SizedBox(height: 16),
        SheetButton(label: tr('Снять камерой', 'Kamerada olish'), onPressed: () => Navigator.pop(ctx, ImageSource.camera)),
        const SizedBox(height: 10),
        SheetButton(label: tr('Выбрать из галереи', 'Galereyadan tanlash'), primary: false, onPressed: () => Navigator.pop(ctx, ImageSource.gallery)),
      ]),
    );
    if (source == null) return;
    try {
      final x = await ImagePicker().pickImage(source: source, maxWidth: 1200, maxHeight: 1200, imageQuality: 85);
      if (x == null) return;
      final bytes = await x.readAsBytes();
      if (mounted) setState(() => _logo = bytes);
    } catch (e) {
      if (mounted) showMessage(context, e);
    }
  }

  Future<void> _send() async {
    if (_name.text.trim().isEmpty) {
      showMessage(context, tr('Название бренда', 'Brend nomi'));
      return;
    }
    setState(() => _busy = true);
    final api = context.read<Api>();
    final reg = widget.reg;
    try {
      // При регистрации сначала создаём аккаунт: фото и заявка — уже с токеном.
      if (reg != null) {
        final t = await api.post('/auth/agent/register', {
          'ticket': reg.ticket,
          'full_name': reg.fullName,
          'company': reg.company,
          'brand_ids': <String>[],
        }) as Map<String, dynamic>;
        await api.setTokens(t);
      }
      var logoUrl = _logoUrl;
      if (_logo != null) {
        try {
          final up = await api.upload('/store/uploads', _logo!, 'brand.jpg') as Map<String, dynamic>;
          logoUrl = '${up['url'] ?? ''}';
        } catch (_) {
          // без логотипа заявку всё равно отправим
        }
      }
      final body = {
        'name': _name.text.trim(),
        'category_id': _cat,
        'manufacturer': _maker.text.trim(),
        'comment': _comment.text.trim(),
        'logo_url': logoUrl,
      };
      final edit = widget.edit;
      if (edit != null) {
        await api.put('/store/supply/brand-requests/${edit['id']}', body);
      } else {
        await api.post('/store/supply/brand-requests', body);
      }
      if (!mounted) return;
      if (reg != null) {
        Navigator.of(context).popUntil((r) => r.isFirst);
      } else {
        Navigator.of(context).pop(true);
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      showMessage(context, e);
      // Аккаунт уже создан — дальше из приложения («Мои бренды»).
      if (reg != null && api.loggedIn) Navigator.of(context).popUntil((r) => r.isFirst);
    }
  }

  @override
  Widget build(BuildContext context) {
    return StepPage(
      title: widget.edit != null ? tr('Исправить заявку', 'Arizani tuzatish') : tr('Новый бренд', 'Yangi brend'),
      subtitle: tr('Заявка в Super Market', 'Super Market uchun ariza'),
      bottom: BigButton(label: tr('Отправить заявку', 'Arizani yuborish'), icon: Icons.send_rounded, busy: _busy, onPressed: _send),
      children: [
        Material(
          color: AppColors.white,
          borderRadius: BorderRadius.circular(16),
          child: InkWell(
            borderRadius: BorderRadius.circular(16),
            onTap: _pickLogo,
            child: Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(borderRadius: BorderRadius.circular(16), border: Border.all(color: AppColors.muted)),
              child: Row(children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: Container(
                    width: 56,
                    height: 56,
                    color: AppColors.soft,
                    child: _logo != null
                        ? Image.memory(_logo!, fit: BoxFit.cover)
                        : _logoUrl.isNotEmpty
                            ? Image.network(_logoUrl, fit: BoxFit.cover, errorBuilder: (_, __, ___) => const Icon(Icons.photo_camera_rounded, color: AppColors.text2))
                            : const Icon(Icons.photo_camera_rounded, color: AppColors.text2),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(tr('Логотип или фото упаковки', 'Logotip yoki qadoq rasmi'), style: AppText.bodyStrong),
                    Text(tr('Снять камерой или выбрать из галереи', 'Kamerada oling yoki galereyadan tanlang'), style: AppText.small),
                  ]),
                ),
              ]),
            ),
          ),
        ),
        const SizedBox(height: 14),
        TextField(controller: _name, textCapitalization: TextCapitalization.words, decoration: InputDecoration(labelText: tr('Название бренда', 'Brend nomi'))),
        const SizedBox(height: 12),
        DropdownButtonFormField<String>(
          value: _cats.any((c) => c['id'] == _cat) ? _cat : null,
          isExpanded: true,
          decoration: InputDecoration(labelText: tr('Категория', 'Kategoriya')),
          items: [for (final c in _cats) DropdownMenuItem(value: '${c['id']}', child: Text('${c['name']}'))],
          onChanged: (v) => setState(() => _cat = v),
        ),
        const SizedBox(height: 12),
        TextField(controller: _maker, decoration: InputDecoration(labelText: tr('Производитель · необязательно', 'Ishlab chiqaruvchi · ixtiyoriy'))),
        const SizedBox(height: 12),
        TextField(
          controller: _comment,
          minLines: 2,
          maxLines: 4,
          decoration: InputDecoration(labelText: tr('Комментарий для Super Market', 'Super Market uchun izoh')),
        ),
        const SizedBox(height: 14),
        HintBox(
          icon: Icons.hourglass_top_rounded,
          bg: AppColors.warningSoft,
          fg: AppColors.warningInk,
          text: tr('Пока бренд на рассмотрении, можно вводить свои товары. Магазины откроются после одобрения — обычно в течение дня.',
              'Brend koʻrib chiqilayotganda mahsulotlaringizni kiritishingiz mumkin. Doʻkonlar tasdiqlangach ochiladi — odatda bir kun ichida.'),
        ),
      ],
    );
  }
}
