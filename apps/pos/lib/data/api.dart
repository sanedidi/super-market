import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:sm_core/sm_core.dart' show ApiError;

export 'package:sm_core/sm_core.dart' show ApiError;

/// API кассы: токен устройства + кассир в заголовке X-Cashier-ID.
class PosApi {
  PosApi(this.baseUrl, {http.Client? client, this.timeout = const Duration(seconds: 20)})
      : _http = client ?? http.Client();

  final String baseUrl;
  final Duration timeout;
  final http.Client _http;

  /// Токен устройства (pd_…), выдаётся при активации.
  String? token;

  Future<dynamic> get(String path, {Map<String, String>? query, String? cashier}) =>
      send('GET', path, query: query, cashier: cashier);

  Future<dynamic> post(String path, Object? body, {String? cashier}) =>
      send('POST', path, body: body ?? const {}, cashier: cashier);

  Future<dynamic> send(String method, String path, {Map<String, String>? query, Object? body, String? cashier}) async {
    var uri = Uri.parse('$baseUrl$path');
    if (query != null && query.isNotEmpty) uri = uri.replace(queryParameters: query);
    final req = http.Request(method, uri);
    if (token != null) req.headers['Authorization'] = 'Bearer $token';
    if (cashier != null) req.headers['X-Cashier-ID'] = cashier;
    if (body != null) {
      req.headers['Content-Type'] = 'application/json';
      req.body = jsonEncode(body);
    }
    http.Response res;
    try {
      res = await http.Response.fromStream(await _http.send(req).timeout(timeout));
    } on TimeoutException {
      throw ApiError(0, 'network', 'Сервер не отвечает');
    } catch (_) {
      throw ApiError(0, 'network', 'Нет связи с сервером');
    }
    dynamic data;
    if (res.bodyBytes.isNotEmpty) {
      try {
        data = jsonDecode(utf8.decode(res.bodyBytes));
      } on FormatException {
        data = null;
      }
    }
    if (res.statusCode >= 400) {
      final err = data is Map ? data['error'] as Map<String, dynamic>? : null;
      throw ApiError(
        res.statusCode,
        err?['code'] as String? ?? 'http_${res.statusCode}',
        err?['message'] as String? ?? 'Ошибка сервера ${res.statusCode}',
        (err?['details'] as Map<String, dynamic>?) ?? const {},
      );
    }
    return data;
  }
}
