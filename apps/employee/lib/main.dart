import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:provider/provider.dart';
import 'package:sm_core/sm_core.dart';
import 'package:sm_store/lock/app_lock.dart';
import 'package:sm_store/lock/pin_screens.dart';
import 'package:sm_store/login/password_login.dart' show ChangePasswordScreen;
import 'package:sm_store/push.dart' show Push, navigatorKey;
import 'package:sm_store/state.dart';
import 'package:sm_store/ui/theme.dart';
import 'package:sm_store/ui/widgets.dart';

import 'firebase_options.dart';
import 'login.dart';
import 'push_open.dart';
import 'shell.dart';
import 'version.dart';

// «SM Сотрудник» (Figma «Super Market · SM Сотрудник», С1–С13) — приложение
// для продавцов, кассиров, кладовщиков и сборщиков онлайн-заказов. Владелец
// остаётся в «SM Магазин». Вход — логином и паролем от владельца
// («Сотрудники» в панели), разделы — по правам роли.

export 'version.dart' show appVersion;

/// Адрес API задаётся при сборке: flutter run --dart-define=API_URL=http://localhost:8080/api/v1
const apiUrl = String.fromEnvironment('API_URL', defaultValue: 'https://api.super-market.uz/api/v1');

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Lang.instance.init();
  await SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
  // Тот же логин, что и в панель магазина: токен приложения магазина (/store/*).
  final api = Api(baseUrl: apiUrl, app: 'store');
  await api.init();
  // Пуши: своё приложение Firebase (пока не зарегистрировано — выключены).
  Push.onOpen = openEmployeePush;
  final firebase = EmployeeFirebaseOptions.currentPlatform;
  if (firebase != null) await Push.init(options: firebase);
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
      child: const EmployeeApp(),
    ),
  );
}

class EmployeeApp extends StatefulWidget {
  const EmployeeApp({super.key});

  @override
  State<EmployeeApp> createState() => _EmployeeAppState();
}

class _EmployeeAppState extends State<EmployeeApp> with WidgetsBindingObserver {
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
      // С1 · логин и пароль от владельца.
      home = const EmployeeLoginScreen();
    } else if (mustChange) {
      // С2 · первый вход по временному паролю — свой пароль.
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
        title: tr('SM Сотрудник', 'SM Xodim'),
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

/// После входа: профиль и магазины сотрудника.
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
    if (kind == 'distributor') {
      return _Blocked(
        title: tr('Это аккаунт агента', 'Bu agent akkaunti'),
        text: tr('Войдите в приложение «SM Агент».', '«SM Agent» ilovasiga kiring.'),
      );
    }
    if (st.storeId == null) {
      return _Blocked(
        title: tr('Нет доступных магазинов', 'Mavjud doʻkonlar yoʻq'),
        text: tr('Попросите владельца дать вам доступ к магазину: Сотрудники → ваш профиль → Магазины.',
            'Egasidan sizga doʻkonga kirish huquqini berishini soʻrang: Xodimlar → profilingiz → Doʻkonlar.'),
      );
    }
    return Shell(key: ValueKey('shell-${st.storeId}'));
  }
}

class _Blocked extends StatelessWidget {
  const _Blocked({required this.title, required this.text});

  final String title;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: EmptyState(
            icon: Icons.storefront_outlined,
            title: title,
            text: text,
            action: tr('Выйти', 'Chiqish'),
            onAction: () => signOut(context),
          ),
        ),
      ),
    );
  }
}
