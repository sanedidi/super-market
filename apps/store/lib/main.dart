import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:provider/provider.dart';
import 'package:sm_core/sm_core.dart';
import 'package:url_launcher/url_launcher.dart';

import 'lock/app_lock.dart';
import 'lock/pin_screens.dart';
import 'push.dart';
import 'screens/shell.dart';
import 'state.dart';
import 'ui/theme.dart';
import 'ui/widgets.dart';

/// Адрес API задаётся при сборке: flutter run --dart-define=API_URL=http://localhost:8080/api/v1
const apiUrl = String.fromEnvironment('API_URL', defaultValue: 'https://api.super-market.uz/api/v1');

/// Версия для экрана «Ещё» (совпадает с pubspec.yaml).
const appVersion = '0.6.1';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
  await Push.init();
  final api = Api(baseUrl: apiUrl, app: 'store');
  await api.init();
  final lock = AppLock();
  await lock.init();
  // Вышли из аккаунта (сами или сессия истекла) — код этого входа больше не нужен.
  if (!api.loggedIn && lock.hasPin) await lock.clear();
  api.addListener(() {
    if (!api.loggedIn && lock.hasPin) lock.clear();
  });
  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: api),
        ChangeNotifierProvider.value(value: lock),
        ChangeNotifierProvider(create: (_) => StoreState(api)),
      ],
      child: const StoreApp(),
    ),
  );
}

class StoreApp extends StatefulWidget {
  const StoreApp({super.key});

  @override
  State<StoreApp> createState() => _StoreAppState();
}

class _StoreAppState extends State<StoreApp> with WidgetsBindingObserver {
  late final AppLifecycleListener _life;

  @override
  void initState() {
    super.initState();
    final lock = context.read<AppLock>();
    // Свернули и вернулись позже «Спрашивать код» — снова просим код или Face ID.
    _life = AppLifecycleListener(onPause: lock.paused, onResume: lock.resumed);
    WidgetsBinding.instance.addObserver(this);
  }

  // Под замком кнопка «Назад» на Android не закрывает экраны под ним.
  @override
  Future<bool> didPopRoute() async {
    final lock = context.read<AppLock>();
    return lock.hasPin && lock.locked && context.read<Api>().loggedIn;
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _life.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final api = context.read<Api>();
    final loggedIn = context.select<Api, bool>((a) => a.loggedIn);
    final hasPin = context.select<AppLock, bool>((l) => l.hasPin);
    final locked = context.select<AppLock, bool>((l) => l.locked);
    final Widget home;
    if (!loggedIn) {
      home = LoginScreen(
        api: api,
        title: 'Вход в магазин',
        subtitle: 'Введите номер сотрудника — пришлём код в Telegram-бот Super Market.',
        logo: const IconBox(Icons.storefront_rounded, bg: AppColors.primary, fg: AppColors.white, size: 56, iconSize: 30, radius: 18),
        note: 'Код из Telegram нужен только при первом входе на телефоне. Дальше — свой код из 4 цифр или Face ID.',
        onOpenUrl: (url) => launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication),
      );
    } else if (!hasPin) {
      home = const PinSetupScreen();
    } else {
      home = const _Gate();
    }
    final showLock = loggedIn && hasPin && locked;
    return MaterialApp(
      navigatorKey: navigatorKey,
      title: 'Super Market Магазин',
      debugShowCheckedModeBanner: false,
      theme: buildTheme(),
      locale: const Locale('ru'),
      supportedLocales: const [Locale('ru'), Locale('uz'), Locale('en')],
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      home: home,
      // Экран кода — поверх всего, что было открыто (заказ, шторка, push):
      // после кода человек возвращается туда же.
      builder: (context, child) => Stack(children: [
        ExcludeSemantics(excluding: showLock, child: child!),
        if (showLock) const Positioned.fill(child: _LockLayer()),
      ]),
    );
  }
}

/// Свой навигатор для экрана кода — чтобы работали шторки «Забыли код?».
class _LockLayer extends StatelessWidget {
  const _LockLayer();

  @override
  Widget build(BuildContext context) => Navigator(onGenerateRoute: (_) => MaterialPageRoute<void>(builder: (_) => const LockScreen()));
}

/// После входа: ждём профиль и список магазинов.
class _Gate extends StatelessWidget {
  const _Gate();

  @override
  Widget build(BuildContext context) {
    final st = context.watch<StoreState>();
    if (st.me == null) {
      return Scaffold(
        body: Center(
          child: st.error == null
              ? const CircularProgressIndicator()
              : EmptyState(
                  icon: Icons.wifi_off_rounded,
                  title: 'Не удалось загрузить данные',
                  text: st.error.toString(),
                  action: 'Повторить',
                  onAction: st.load,
                ),
        ),
      );
    }
    if (st.storeId == null) {
      return Scaffold(
        body: Center(
          child: EmptyState(
            icon: Icons.storefront_outlined,
            title: 'Нет доступных магазинов',
            text: 'Попросите владельца сети дать вам доступ к магазину в панели магазина.',
            action: 'Выйти',
            onAction: () => signOut(context),
          ),
        ),
      );
    }
    return const Shell();
  }
}

/// Сообщение внизу экрана.
void showMessage(BuildContext context, Object e) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(e.toString())));
}
