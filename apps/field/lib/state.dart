import 'package:flutter/foundation.dart';
import 'package:sm_core/sm_core.dart';

import 'logic.dart';

/// Профиль продажника и П1 «Обход» (GET /field/me).
class FieldState extends ChangeNotifier {
  FieldState(this.api) {
    api.addListener(_onAuth);
    if (api.loggedIn) load();
  }

  final Api api;

  Map<String, dynamic>? me;
  Object? error;
  bool loading = false;
  bool _wasLoggedIn = false;

  Grid get grid => Grid.from(me?['grid']);
  Map<String, dynamic>? get rep => me?['rep'] as Map<String, dynamic>?;
  Map<String, dynamic>? get district => me?['district'] as Map<String, dynamic>?;
  Map<String, dynamic>? get openWalk => me?['walk'] as Map<String, dynamic>?;

  void _onAuth() {
    if (api.loggedIn && !_wasLoggedIn) {
      _wasLoggedIn = true;
      load();
    } else if (!api.loggedIn && _wasLoggedIn) {
      _wasLoggedIn = false;
      me = null;
      error = null;
      notifyListeners();
    }
  }

  Future<void> load() async {
    _wasLoggedIn = api.loggedIn;
    if (!api.loggedIn) return;
    loading = true;
    notifyListeners();
    try {
      me = await api.get('/field/me') as Map<String, dynamic>;
      error = null;
    } catch (e) {
      error = e;
    } finally {
      loading = false;
      notifyListeners();
    }
  }

  @override
  void dispose() {
    api.removeListener(_onAuth);
    super.dispose();
  }
}
