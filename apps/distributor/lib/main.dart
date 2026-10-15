import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:provider/provider.dart';
import 'package:sm_core/sm_core.dart';
import 'package:sm_store/lock/app_lock.dart';
import 'package:sm_store/lock/pin_screens.dart';
import 'package:sm_store/login/password_login.dart' show ChangePasswordScreen;
import 'package:sm_store/push.dart' show navigatorKey;
import 'package:sm_store/start/start_logic.dart' show sellPriceWord;
import 'package:sm_store/state.dart';
import 'package:sm_store/ui/theme.dart';
import 'package:sm_store/ui/widgets.dart';

import 'login_screen.dart';
import 'point_setup.dart';
import 'shell.dart';

/// Адрес API задаётся при сборке: flutter run --dart-define=API_URL=http://localhost:8080/api/v1
const apiUrl = String.fromEnvironment('API_URL', defaultValue: 'https://api.super-market.uz/api/v1');

/// Версия для экрана «Ещё» (совпадает с pubspec.yaml).
const appVersion = '0.1.0';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Lang.instance.init();
  await SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
  // В «Начале работы» цена продажи дистрибьютора — отпускная цена для магазинов.
  sellPriceWord = () => tr('Отпускная цена', 'Ulgurji narx');
  // Вход тем же логином, что и в панель: токен приложения магазина (/store/*).
  final api = Api(baseUrl: apiUrl, app: 'store');
  await api.init();
  final lock = AppLock();
  await lock.init();
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
      child: const DistributorApp(),
    ),
  );
}

class DistributorApp extends StatefulWidget {
  const DistributorApp({super.key});

  @override
  State<DistributorApp> createState() => _DistributorAppState();
}

class _DistributorAppState extends State<DistributorApp> with WidgetsBindingObserver {
  late final AppLifecycleListener _life;

  @override
  void initState() {
    super.initState();
    final lock = context.read<AppLock>();
    _life = AppLifecycleListener(onPause: lock.paused, onResume: lock.resumed);
    WidgetsBinding.instance.addObserver(this);
  }

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
    final loggedIn = context.select<Api, bool>((a) => a.loggedIn);
    final hasPin = context.select<AppLock, bool>((l) => l.hasPin);
    final locked = context.select<AppLock, bool>((l) => l.locked);
    final mustChange = context.select<StoreState, bool>((s) => s.mustChangePassword);
    final meReady = context.select<StoreState, bool>((s) => s.me != null);
    final Widget home;
    if (!loggedIn) {
      home = const DistributorLoginScreen();
    } else if (mustChange) {
      home = const ChangePasswordScreen();
    } else if (!hasPin && !meReady) {
      home = const _Gate();
    } else if (!hasPin) {
      home = const PinSetupScreen();
    } else {
      home = const _Gate();
    }
    final showLock = loggedIn && hasPin && locked;
    return ListenableBuilder(
      listenable: Lang.instance,
      builder: (context, _) => MaterialApp(
        navigatorKey: navigatorKey,
        title: tr('Super Market Агент', 'Super Market Agent'),
        debugShowCheckedModeBanner: false,
        theme: buildTheme(),
        locale: Lang.instance.locale,
        supportedLocales: Lang.locales,
        localizationsDelegates: const [
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        home: home,
        builder: (context, child) => showLock
            ? Stack(fit: StackFit.expand, children: [
                ExcludeSemantics(child: child!),
                Navigator(onGenerateRoute: (_) => MaterialPageRoute<void>(builder: (_) => const LockScreen())),
              ])
            : child!,
      ),
    );
  }
}

/// После входа: профиль, проверка, что это дистрибьютор, точка склада.
class _Gate extends StatelessWidget {
  const _Gate();

  @override
  Widget build(BuildContext context) {
    final st = context.watch<StoreState>();
    final me = st.me;
    if (me == null) {
      return Scaffold(
        body: Center(
          child: st.error == null
              ? const CircularProgressIndicator()
              : EmptyState(
                  icon: Icons.wifi_off_rounded,
                  title: tr('Не удалось загрузить данные', 'Maʼlumotlarni yuklab boʻlmadi'),
                  text: st.error.toString(),
                  action: tr('Повторить', 'Qayta urinish'),
                  onAction: st.load,
                ),
        ),
      );
    }
    final kind = (me['network'] as Map<String, dynamic>?)?['kind'];
    if (kind != 'distributor') {
      return Scaffold(
        body: SafeArea(
          child: Center(
            child: EmptyState(
              icon: Icons.storefront_outlined,
              title: tr('Это аккаунт магазина', 'Bu doʻkon akkaunti'),
              text: tr('Войдите в приложение «SM Магазин». «SM Агент» — для поставщиков, которые возят товар в магазины.',
                  '«SM Doʻkon» ilovasiga kiring. «SM Agent» — doʻkonlarga mahsulot yetkazuvchilar uchun.'),
              action: tr('Выйти', 'Chiqish'),
              onAction: () => signOut(context),
            ),
          ),
        ),
      );
    }
    if (st.stores.isEmpty || st.storeId == null) {
      // Точка склада — где стоит склад дистрибьютора (от неё — магазины рядом).
      return st.can('stores.manage')
          ? const PointSetupScreen()
          : Scaffold(
              body: Center(
                child: EmptyState(
                  icon: Icons.warehouse_outlined,
                  title: tr('Склад ещё не настроен', 'Ombor hali sozlanmagan'),
                  text: tr('Попросите владельца войти и указать адрес склада.', 'Egasidan kirib, ombor manzilini koʻrsatishini soʻrang.'),
                  action: tr('Выйти', 'Chiqish'),
                  onAction: () => signOut(context),
                ),
              ),
            );
    }
    return const Shell();
  }
}
