import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

/// Ошибка API: {"error": {"code", "message", "details"}}.
class ApiError implements Exception {
  ApiError(this.status, this.code, this.message, [this.details = const {}]);

  final int status;
  final String code;
  final String message;
  final Map<String, dynamic> details;

  bool get isNetwork => status == 0;

  @override
  String toString() => message;
}

/// HTTP-клиент API с токенами и автообновлением access-токена.
///
/// [app] — приложение, на которое выдаётся токен: `client` или `store`.
class Api extends ChangeNotifier {
  Api({required this.baseUrl, required this.app, http.Client? client}) : _http = client ?? http.Client();

  /// Например, `https://api.super-market.uz/api/v1`.
  final String baseUrl;
  final String app;
  final http.Client _http;

  String? _access;
  String? _refresh;
  Future<bool>? _refreshing;

  bool get loggedIn => _refresh != null;

  String get _key => 'sm_${app}_tokens';

  /// Загрузить сохранённые токены (вызвать при старте).
  Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    if (raw != null) {
      final m = jsonDecode(raw) as Map<String, dynamic>;
      _access = m['access_token'] as String?;
      _refresh = m['refresh_token'] as String?;
    }
    notifyListeners();
  }

  Future<void> _save(Map<String, dynamic>? tokens) async {
    final prefs = await SharedPreferences.getInstance();
    if (tokens == null) {
      _access = null;
      _refresh = null;
      await prefs.remove(_key);
    } else {
      _access = tokens['access_token'] as String?;
      _refresh = tokens['refresh_token'] as String?;
      await prefs.setString(_key, jsonEncode({'access_token': _access, 'refresh_token': _refresh}));
    }
    notifyListeners();
  }

  /// Запросить код входа в Telegram-боте.
  Future<void> requestCode(String phone) => post('/auth/otp/request', {'phone': phone});

  /// Проверить код и войти.
  Future<void> verifyCode(String phone, String code) async {
    final tokens = await post('/auth/otp/verify', {'phone': phone, 'code': code.trim(), 'app': app});
    await _save(tokens as Map<String, dynamic>);
  }

  /// Забыть токены без запроса к серверу (например, после удаления аккаунта).
  Future<void> forget() => _save(null);

  Future<void> logout() async {
    try {
      await post('/auth/$app/logout');
    } catch (_) {
      // токен мог истечь — всё равно выходим
    }
    await _save(null);
  }

  Future<bool> _doRefresh() async {
    if (_refresh == null) return false;
    try {
      final res = await _http
          .post(Uri.parse('$baseUrl/auth/refresh'),
              headers: {'Content-Type': 'application/json'}, body: jsonEncode({'refresh_token': _refresh}))
          .timeout(const Duration(seconds: 20));
      if (res.statusCode != 200) return false;
      await _save(jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>);
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<dynamic> _send(String method, String path, {Map<String, dynamic>? query, Object? body, bool retry = true}) async {
    var uri = Uri.parse('$baseUrl$path');
    if (query != null) {
      final q = <String, String>{};
      query.forEach((k, v) {
        if (v != null && v.toString().isNotEmpty) q[k] = v.toString();
      });
      uri = uri.replace(queryParameters: q.isEmpty ? null : q);
    }
    final headers = <String, String>{};
    if (_access != null) headers['Authorization'] = 'Bearer $_access';
    if (body != null) headers['Content-Type'] = 'application/json';

    http.Response res;
    try {
      final req = http.Request(method, uri)..headers.addAll(headers);
      if (body != null) req.body = jsonEncode(body);
      res = await http.Response.fromStream(await _http.send(req).timeout(const Duration(seconds: 30)));
    } on TimeoutException {
      throw ApiError(0, 'network', 'Сервер не отвечает');
    } catch (_) {
      throw ApiError(0, 'network', 'Нет связи с сервером');
    }

    if (res.statusCode == 401 && retry && _refresh != null) {
      _refreshing ??= _doRefresh().whenComplete(() => _refreshing = null);
      if (await _refreshing!) return _send(method, path, query: query, body: body, retry: false);
      await _save(null);
    }
    if (res.statusCode == 204) return null;
    dynamic data;
    if (res.bodyBytes.isNotEmpty) {
      try {
        data = jsonDecode(utf8.decode(res.bodyBytes));
      } catch (_) {
        data = null;
      }
    }
    if (res.statusCode >= 400) {
      final err = data is Map ? data['error'] as Map<String, dynamic>? : null;
      throw ApiError(
        res.statusCode,
        err?['code'] as String? ?? 'http_${res.statusCode}',
        err?['message'] as String? ?? 'Ошибка ${res.statusCode}',
        (err?['details'] as Map<String, dynamic>?) ?? const {},
      );
    }
    return data;
  }

  Future<dynamic> get(String path, [Map<String, dynamic>? query]) => _send('GET', path, query: query);
  Future<dynamic> post(String path, [Object? body]) => _send('POST', path, body: body ?? const {});
  Future<dynamic> put(String path, Object body) => _send('PUT', path, body: body);
  Future<dynamic> patch(String path, Object body) => _send('PATCH', path, body: body);
  Future<dynamic> delete(String path) => _send('DELETE', path);

  /// GET списка: {"items": [...]}.
  Future<List<Map<String, dynamic>>> list(String path, [Map<String, dynamic>? query]) async {
    final data = await get(path, query) as Map<String, dynamic>;
    return ((data['items'] as List?) ?? const []).cast<Map<String, dynamic>>();
  }
}
