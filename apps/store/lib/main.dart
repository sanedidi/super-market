import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:provider/provider.dart';
import 'package:sm_core/sm_core.dart';

import 'lock/app_lock.dart';
import 'lock/pin_screens.dart';
import 'login/employee_app.dart';
import 'login/password_login.dart';
import 'push.dart';
import 'screens/shell.dart';
import 'setup/setup_screens.dart';
import 'state.dart';
import 'ui/theme.dart';
import 'ui/widgets.dart';
import 'version.dart';
import 'waiter/waiter_shell.dart';

// Версия для экранов «Ещё» / профиля — одна на приложение, в version.dart.
export 'version.dart' show appVersion;

/// Адрес API задаётся при сборке: flutter run --dart-define=API_URL=http://localhost:8080/api/v1
const apiUrl = String.fromEnvironment('API_URL', defaultValue: 'https://api.super-market.uz/api/v1');


Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Lang.instance.init();
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
    final loggedIn = context.select<Api, bool>((a) => a.loggedIn);
    final hasPin = context.select<AppLock, bool>((l) => l.hasPin);
    final locked = context.select<AppLock, bool>((l) => l.locked);
    final mustChange = context.select<StoreState, bool>((s) => s.mustChangePassword);
    final meReady = context.select<StoreState, bool>((s) => s.me != null);
    final Widget home;
    if (!loggedIn) {
      // Вход по логину и паролю (код из Telegram для магазина отключён).
      home = const PasswordLoginScreen();
    } else if (mustChange) {
      // Временный пароль от Super Market — сначала свой пароль, потом код из 4 цифр.
      home = const ChangePasswordScreen();
    } else if (!hasPin && !meReady) {
      // Ждём профиль: вдруг пароль временный.
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
        title: tr('Super Market Магазин', 'Super Market Doʻkon'),
        debugShowCheckedModeBanner: false,
        theme: buildTheme(),
        locale: Lang.instance.locale,
        supportedLocales: Lang.locales,
        localizationsDelegates: const [
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        // ОБ1 · «Есть обновление» — шторка поверх главного экрана.
        home: UpdateCheck(api: context.read<Api>(), app: appId, version: appVersion, open: openStore, child: home),
        // Экран кода — поверх всего, что было открыто (заказ, шторка, push):
        // после кода человек возвращается туда же.
        // Без замка дерево приложения — как раньше, без обёрток.
        builder: (context, child) => showLock
            ? Stack(fit: StackFit.expand, children: [
                ExcludeSemantics(child: child!),
                const _LockLayer(),
              ])
            : child!,
      ),
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
                  title: tr('Не удалось загрузить данные', 'Maʼlumotlarni yuklab boʻlmadi'),
                  text: st.error.toString(),
                  action: tr('Повторить', 'Qayta urinish'),
                  onAction: st.load,
                ),
        ),
      );
    }
    // Первая настройка: пока у сети нет магазина с точкой и часами — только мастер.
    final setup = st.setup;
    if (setup != null && setup.required) {
      return setup.canSetup ? SetupFlow(key: const ValueKey('setup'), initial: setup, required: true) : const SetupWaitingScreen();
    }
    if (st.storeId == null) {
      return Scaffold(
        body: Center(
          child: EmptyState(
            icon: Icons.storefront_outlined,
            title: tr('Нет доступных магазинов', 'Mavjud doʻkonlar yoʻq'),
            text: tr('Попросите владельца сети дать вам доступ к магазину в панели магазина.', 'Tarmoq egasidan doʻkon panelida sizga doʻkonga kirish huquqini berishini soʻrang.'),
            action: tr('Выйти', 'Chiqish'),
            onAction: () => signOut(context),
          ),
        ),
      );
    }
    // Кафе: режим «Официант» — свои вкладки (Столы · Готово · Брони · Ещё).
    if (st.waiterMode && st.canWaiter) return WaiterShell(key: ValueKey('waiter-${st.storeId}'));
    // «SM Магазин» — только для владельца: сотрудники работают в «SM Сотрудник».
    // Официанты кафе пока остаются здесь (режим «Официант»).
    if (!st.ownerApp) return const EmployeeAppScreen();
    return const Shell();
  }
}

/// Сообщение внизу экрана.
void showMessage(BuildContext context, Object e) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(e.toString())));
}
