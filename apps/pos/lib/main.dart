import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:provider/provider.dart';
import 'package:sm_core/sm_core.dart';

import 'pos_state.dart';
import 'screens/sale_screen.dart';

/// Адрес API задаётся при сборке: flutter run --dart-define=API_URL=http://localhost:8080/api/v1
const apiUrl = String.fromEnvironment('API_URL', defaultValue: 'https://api.super-market.uz/api/v1');

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final api = Api(baseUrl: apiUrl, app: 'store');
  await api.init();
  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: api),
        ChangeNotifierProvider(create: (_) => PosState(api)),
      ],
      child: const PosApp(),
    ),
  );
}

class PosApp extends StatelessWidget {
  const PosApp({super.key});

  @override
  Widget build(BuildContext context) {
    final api = context.watch<Api>();
    return MaterialApp(
      title: 'Касса',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(colorSchemeSeed: const Color(0xFF16A34A), useMaterial3: true),
      locale: const Locale('ru'),
      supportedLocales: const [Locale('ru'), Locale('uz'), Locale('en')],
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      home: api.loggedIn
          ? const PosHome()
          : LoginScreen(api: api, title: 'Касса', subtitle: 'Вход сотрудника магазина'),
    );
  }
}

void showError(BuildContext context, Object e) {
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.toString())));
}

/// Загрузка профиля и выбор магазина, затем экран продажи.
class PosHome extends StatefulWidget {
  const PosHome({super.key});

  @override
  State<PosHome> createState() => _PosHomeState();
}

class _PosHomeState extends State<PosHome> {
  Object? _error;
  bool _ready = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _start());
  }

  Future<void> _start() async {
    setState(() => _error = null);
    try {
      await context.read<PosState>().start();
      if (mounted) setState(() => _ready = true);
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final pos = context.watch<PosState>();
    if (_error != null) {
      return Scaffold(
        body: Center(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Text(_error.toString()),
            const SizedBox(height: 12),
            FilledButton(onPressed: _start, child: const Text('Повторить')),
            TextButton(onPressed: () => context.read<Api>().logout(), child: const Text('Выйти')),
          ]),
        ),
      );
    }
    if (!_ready) return const Scaffold(body: Center(child: CircularProgressIndicator()));
    if (!pos.can('sales.pos')) {
      return Scaffold(
        body: Center(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Text('У вас нет права работать на кассе (sales.pos)'),
            TextButton(onPressed: () => context.read<Api>().logout(), child: const Text('Выйти')),
          ]),
        ),
      );
    }
    if (pos.storeId == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Выберите магазин')),
        body: ListView(children: [
          for (final s in pos.stores)
            ListTile(
              leading: const Icon(Icons.storefront_outlined),
              title: Text(s['name'] as String),
              subtitle: Text((s['address'] as String?) ?? ''),
              onTap: () => pos.selectStore(s['id'] as String),
            ),
        ]),
      );
    }
    return const SaleScreen();
  }
}
