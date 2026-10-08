import 'package:sm_core/sm_core.dart';

import 'start_logic.dart';

/// Запросы «Начала работы» (/store/start, docs/api.md). Черновик общий с
/// панелью магазина: всё, что добавлено здесь, видно и там.
class StartApi {
  StartApi(this.api, this.storeId);

  final Api api;
  final String storeId;

  Future<Map<String, dynamic>> draft({String? only, String? q, int limit = 200, int offset = 0}) async =>
      await api.get('/store/start', {'store_id': storeId, 'only': only, 'q': q, 'limit': limit, 'offset': offset}) as Map<String, dynamic>;

  /// Добавить или изменить строки (add — в «Мои товары»; то, что уже там, в
  /// пакете пропускается — ответ skipped).
  Future<Map<String, dynamic>> setLines(List<Map<String, dynamic>> items) async {
    Map<String, dynamic> last = const {};
    // Сервер принимает до 500 строк за раз.
    for (var i = 0; i < items.length; i += 500) {
      final part = items.sublist(i, i + 500 > items.length ? items.length : i + 500);
      last = await api.post('/store/start/lines', {'store_id': storeId, 'items': part}) as Map<String, dynamic>;
    }
    return last;
  }

  Future<void> deleteLine(String productId) => api.delete('/store/start/lines/$productId?store_id=$storeId');

  Future<Map<String, dynamic>> post() async => await api.post('/store/start/post', {'store_id': storeId}) as Map<String, dynamic>;

  /// Добавить один товар в «Мои товары». Повтор и похожий товар — не ошибка,
  /// а исход (сервер отвечает 409 already_added / similar_exists).
  Future<AddOutcome> add(String productId, {String source = 'search', bool confirmSimilar = false, String? bind}) async {
    try {
      await api.post('/store/start/lines', {
        'store_id': storeId,
        'items': [
          {'product_id': productId, 'add': true, 'source': source, if (confirmSimilar) 'confirm_similar': true, if (bind != null) 'barcode': bind},
        ],
      });
      return const AddOutcome(AddKind.added);
    } on ApiError catch (e) {
      final o = AddOutcome.fromError(e.code, e.details);
      if (o == null) rethrow;
      return o;
    }
  }

  /// Поиск по центральной базе: название (uz / ru) или штрихкод; added — уже в «Моих товарах».
  Future<List<Map<String, dynamic>>> searchBase(String q) => api.list('/store/start/search', {'store_id': storeId, 'q': q, 'limit': 30});

  Future<Map<String, dynamic>> createPhoto(List<String> images) async =>
      await api.post('/store/start/photos', {'store_id': storeId, 'images': images}) as Map<String, dynamic>;

  Future<Map<String, dynamic>> photo(String id) async => await api.get('/store/start/photos/$id') as Map<String, dynamic>;

  Future<void> retryPhoto(String id) => api.post('/store/start/photos/$id/retry');

  /// Товар по штрихкоду (центральная база и свои товары сети).
  Future<ProductRef?> byBarcode(String code) async {
    final l = await api.list('/store/products', {'barcode': code, 'store_id': storeId, 'limit': 1});
    return l.isEmpty ? null : ProductRef.fromProduct(l.first);
  }

  Future<List<ProductRef>> search(String q) async {
    final l = await api.list('/store/products', {'q': q, 'store_id': storeId, 'limit': 30});
    return l.where((p) => p['is_active'] != false).map(ProductRef.fromProduct).toList();
  }
}
