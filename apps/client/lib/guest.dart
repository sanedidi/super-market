// Гостевой режим (Apple 5.1.1: смотреть без входа). Гость видит магазины
// рядом со своей точкой (геолокация или точка на карте), товары и акции и
// может собирать корзину. Вход нужен, чтобы оформить заказ, добавить в
// избранное, попросить доставку, открыть семью и разделы профиля — тогда
// requireLogin показывает шторку входа (Figma «Т2»), а после входа действие
// продолжается.
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sm_core/sm_core.dart' hide PhoneField;

import 'map_view.dart';
import 'screens/addresses_screen.dart';
import 'screens/auth_screen.dart';
import 'state.dart';
import 'ui/theme.dart';
import 'ui/widgets.dart';

/// Зачем нужен вход — заголовок и пояснение шторки.
enum LoginReason {
  checkout('Войдите, чтобы оформить заказ', 'Товары останутся в корзине.'),
  favorite('Войдите, чтобы добавить в избранное', 'Избранное сохранится на всех ваших устройствах.'),
  wish('Войдите, чтобы попросить доставку', 'Магазин узнает, что доставку ждут.'),
  family('Войдите, чтобы покупать вместе с семьёй', 'Списки покупок и просьбы для близких.'),
  orders('Войдите, чтобы увидеть заказы', 'История заказов и текущий заказ.'),
  addresses('Войдите, чтобы сохранять адреса', 'Адреса доставки будут под рукой.'),
  notifications('Войдите, чтобы получать уведомления', 'Статус заказа и ответы магазинов.'),
  debts('Войдите, чтобы увидеть долги', 'Покупки в долг в магазинах рядом.');

  const LoginReason(this.title, this.text);
  final String title;
  final String text;
}

/// Вход нужен для действия: залогинен — сразу true; гость — шторка входа,
/// затем код (и имя, если его нет). true — вошли, действие можно продолжать.
Future<bool> requireLogin(BuildContext context, LoginReason reason) async {
  final api = context.read<Api>();
  if (api.loggedIn) return true;
  final nav = Navigator.of(context, rootNavigator: true);
  final sent = await showSheet<OtpSent>(context, (_) => LoginSheet(reason: reason));
  if (sent == null || !nav.mounted) return false;
  final ok = await nav.push<bool>(MaterialPageRoute(builder: (_) => AuthScreen(sent: sent)));
  return ok == true && api.loggedIn;
}

/// Экран входа целиком (карточка «Войдите в Super Market» в профиле).
Future<bool> openLogin(BuildContext context) async {
  final api = context.read<Api>();
  if (api.loggedIn) return true;
  final ok = await Navigator.of(context, rootNavigator: true).push<bool>(MaterialPageRoute(builder: (_) => const AuthScreen()));
  return ok == true && api.loggedIn;
}

/// Шторка входа (Figma «Т2»): номер, «Получить код», согласие с офертой и
/// политикой, «Продолжить без входа». Возвращает [OtpSent], если код отправлен.
class LoginSheet extends StatefulWidget {
  const LoginSheet({super.key, required this.reason});
  final LoginReason reason;

  @override
  State<LoginSheet> createState() => _LoginSheetState();
}

class _LoginSheetState extends State<LoginSheet> {
  final _phone = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    context.read<AppState>().loadConfig();
  }

  @override
  void dispose() {
    _phone.dispose();
    super.dispose();
  }

  String get _digits => _phone.text.replaceAll(RegExp(r'\D'), '');
  bool get _ready => _digits.length == 9 && !_busy;

  Future<void> _send() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    final api = context.read<Api>();
    try {
      final sent = await requestOtp(api, '+998$_digits');
      if (mounted) Navigator.pop(context, sent);
    } on ApiError catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final legal = AppText.caption.copyWith(height: 1.45);
    return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      SheetHeader(title: widget.reason.title, text: '${widget.reason.text} Код придёт по SMS или в Telegram.'),
      const SizedBox(height: 20),
      PhoneField(
        controller: _phone,
        autofocus: true,
        error: _error != null,
        onChanged: () => setState(() => _error = null),
        onSubmit: _ready ? _send : null,
      ),
      if (_error != null) ...[
        const SizedBox(height: 8),
        Text(_error!, style: AppText.small.copyWith(color: AppColors.primary)),
      ],
      const SizedBox(height: 16),
      SheetButton(label: 'Получить код', busy: _busy, onPressed: _ready ? _send : null),
      const SizedBox(height: 12),
      Text.rich(
        TextSpan(style: legal, children: [
          const TextSpan(text: 'Нажимая «Получить код», вы соглашаетесь с '),
          ...legalSpans(legal, offerUrl: state.link('offer_url'), privacyUrl: state.privacyUrl),
        ]),
        textAlign: TextAlign.center,
      ),
      const SizedBox(height: 4),
      TextButton(
        onPressed: () => Navigator.pop(context),
        style: TextButton.styleFrom(foregroundColor: AppColors.dark, textStyle: AppText.bodyStrong),
        child: const Text('Продолжить без входа'),
      ),
    ]);
  }
}

const _pointKey = 'sm_client_guest_point';

/// Точка, которую гость выбрал на карте (сохраняется между запусками).
Future<({double lat, double lng})?> savedGuestPoint() async {
  try {
    final prefs = await SharedPreferences.getInstance();
    final parts = (prefs.getString(_pointKey) ?? '').split(',');
    if (parts.length != 2) return null;
    final lat = double.tryParse(parts[0]);
    final lng = double.tryParse(parts[1]);
    return lat == null || lng == null ? null : (lat: lat, lng: lng);
  } catch (_) {
    return null;
  }
}

Future<void> saveGuestPoint(double lat, double lng) async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.setString(_pointKey, '$lat,$lng');
}

/// Шапка «Укажите адрес доставки»: гостю — точка на карте, иначе — мои адреса.
Future<void> openAddressPicker(BuildContext context) async {
  final guest = context.read<AppState>().isGuest;
  await Navigator.of(context).push(MaterialPageRoute(builder: (_) => guest ? const GuestPointScreen() : const AddressesScreen()));
}

/// Точка гостя на карте: где показать магазины. Адрес не сохраняется —
/// подъезд и квартиру покупатель укажет при оформлении после входа.
class GuestPointScreen extends StatefulWidget {
  const GuestPointScreen({super.key});

  @override
  State<GuestPointScreen> createState() => _GuestPointScreenState();
}

class _GuestPointScreenState extends State<GuestPointScreen> {
  late ({double lat, double lng}) _point;

  @override
  void initState() {
    super.initState();
    final a = context.read<AppState>().address;
    _point = a == null ? tashkent : (lat: a.lat, lng: a.lng);
  }

  Future<void> _done() async {
    final state = context.read<AppState>();
    final nav = Navigator.of(context);
    state.setGuestPoint(_point.lat, _point.lng);
    await saveGuestPoint(_point.lat, _point.lng);
    nav.pop();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Куда доставить?')),
      body: Column(children: [
        Expanded(
          child: PointPicker(
            initial: _point,
            onChanged: (double lat, double lng, {bool located = false}) => _point = (lat: lat, lng: lng),
          ),
        ),
        SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Text('Покажем магазины, которые привезут продукты сюда. Точный адрес укажете при оформлении заказа.',
                  style: AppText.body.copyWith(color: AppColors.text2)),
              const SizedBox(height: 12),
              AppButton(label: 'Показать магазины рядом', onPressed: _done),
            ]),
          ),
        ),
      ]),
    );
  }
}
