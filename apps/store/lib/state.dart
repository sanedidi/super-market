import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sm_core/sm_core.dart';

import 'setup/setup_logic.dart';

/// Кто вошёл (сеть, права) и выбранный магазин.
class StoreState extends ChangeNotifier {
  StoreState(this.api) {
    api.addListener(_onAuth);
    _onAuth();
  }

  final Api api;

  Map<String, dynamic>? me;
  List<Map<String, dynamic>> stores = const [];
  String? storeId;

  /// Первая настройка магазина (null — сервер не ответил, мастер не показываем).
  SetupState? setup;

  /// Вошли по временному паролю: сначала «Свой пароль», остальное сервер не отдаёт.
  bool mustChangePassword = false;
  bool loading = false;
  Object? error;
  bool _wasIn = false;

  static const _storeKey = 'sm_store_selected';
  static const _waiterKey = 'sm_waiter_mode';

  /// Режим «Официант» (кафе): столы и заказы вместо магазина.
  bool waiterMode = false;

  void _onAuth() {
    if (api.loggedIn && !_wasIn) {
      _wasIn = true;
      load();
    } else if (!api.loggedIn && _wasIn) {
      _wasIn = false;
      me = null;
      stores = const [];
      storeId = null;
      setup = null;
      waiterMode = false;
      mustChangePassword = false;
      notifyListeners();
    }
  }

  Future<void> load() async {
    loading = true;
    error = null;
    notifyListeners();
    try {
      me = await api.get('/store/me') as Map<String, dynamic>;
      mustChangePassword = me!['must_change_password'] == true;
      if (mustChangePassword) return;
      stores = await api.list('/store/stores');
      try {
        setup = SetupState(await api.get('/store/setup') as Map<String, dynamic>);
      } catch (_) {
        setup = null;
        // Новому владельцу без магазинов без мастера делать нечего — пусть будет «Повторить».
        if (stores.isEmpty) {
          me = null;
          rethrow;
        }
      }
      final prefs = await SharedPreferences.getInstance();
      // Официант кафе без других прав — сразу в режим «Официант»; остальные
      // переключаются в «Ещё» (выбор запоминается на телефоне).
      final savedMode = prefs.getBool(_waiterKey);
      waiterMode = canWaiter && (savedMode ?? onlyWaiter);
      final saved = prefs.getString(_storeKey);
      storeId = stores.any((s) => s['id'] == saved) ? saved : (stores.isEmpty ? null : stores.first['id'] as String);
    } catch (e) {
      error = e;
    } finally {
      loading = false;
      notifyListeners();
    }
  }

  Future<void> setStore(String id) async {
    storeId = id;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_storeKey, id);
  }

  Map<String, dynamic>? get store {
    for (final s in stores) {
      if (s['id'] == storeId) return s;
    }
    return null;
  }

  /// Сеть работает как кафе (тип бизнеса из супер-админа).
  bool get isCafe => (me?['network'] as Map<String, dynamic>?)?['business_type'] == 'cafe';

  /// Может работать официантом: кафе и право cafe.waiter (у владельца — все).
  bool get canWaiter => isCafe && can('cafe.waiter');

  /// Только официант: других прав, кроме кассы, нет — режим магазина не нужен.
  bool get onlyWaiter {
    if (!canWaiter || me?['is_owner'] == true) return false;
    const waiterish = {'cafe.waiter', 'sales.pos', 'sales.discount', 'sales.return', 'debts.give'};
    final perms = (me?['permissions'] as List?) ?? const [];
    return perms.every((p) => waiterish.contains(p));
  }

  Future<void> setWaiterMode(bool on) async {
    waiterMode = on && canWaiter;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_waiterKey, waiterMode);
  }

  /// Можно работать в «SM Магазин»: владелец сети или официант кафе. Остальным
  /// сотрудникам — приложение «SM Сотрудник».
  bool get ownerApp => me?['is_owner'] == true || canWaiter;

  String get networkName => '${(me?['network'] as Map<String, dynamic>?)?['name'] ?? ''}';

  /// Есть ли право (владелец может всё).
  bool can(String perm) {
    if (me?['is_owner'] == true) return true;
    final perms = (me?['permissions'] as List?) ?? const [];
    return perms.contains(perm);
  }

  @override
  void dispose() {
    api.removeListener(_onAuth);
    super.dispose();
  }
}
