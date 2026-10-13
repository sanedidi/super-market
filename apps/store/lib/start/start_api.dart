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

  /// Варианты из каталога ИКПУ: названия по правилам каталога и отметки
  /// «уже есть в базе» / «уже добавлен» (records — записи tasnif как есть).
  Future<List<Map<String, dynamic>>> tasnifPreview(List<Map<String, dynamic>> records) async {
    final r = await api.post('/store/start/tasnif/preview', {'store_id': storeId, 'items': records}) as Map<String, dynamic>;
    return ((r['items'] as List?) ?? const []).cast<Map<String, dynamic>>();
  }

  /// Добавить вариант из каталога ИКПУ: {status: added | need_category, …}.
  Future<Map<String, dynamic>> tasnifAdd(Map<String, dynamic> body) async =>
      await api.post('/store/start/tasnif', {'store_id': storeId, ...body}) as Map<String, dynamic>;

  /// Очередь «Новые», страница: {items, counts {processing, ready, failed}, total};
  /// counts и total — по всей очереди.
  Future<Map<String, dynamic>> newItems({int limit = 50, int offset = 0}) async =>
      await api.get('/store/start/new-items', {'store_id': storeId, 'limit': limit, 'offset': offset}) as Map<String, dynamic>;

  /// Фото нового товара → Super Market заполняет карточку в фоне.
  Future<Map<String, dynamic>> createNewItem(List<String> images, {String? barcode}) async => await api.post('/store/start/new-items', {
        'store_id': storeId,
        'images': images,
        if (barcode != null && barcode.isNotEmpty) 'barcode': barcode,
      }) as Map<String, dynamic>;

  /// Подтвердить карточку: новый товар или {product_id} — «Это он».
  Future<Map<String, dynamic>> confirmNewItem(String id, Map<String, dynamic> body) async =>
      await api.post('/store/start/new-items/$id/confirm', {'store_id': storeId, ...body}) as Map<String, dynamic>;

  /// «Провести все»: карточки, которые Super Market заполнил, — в «Мои товары»
  /// как есть. dryRun — только посчитать: {ready, existing, added, remaining,
  /// left {no_category, duplicate, barcode, processing, failed, other}}.
  /// Сервер проводит до 100 за вызов — зовите, пока remaining > 0.
  Future<Map<String, dynamic>> confirmAllNewItems({bool dryRun = false}) async =>
      await api.post('/store/start/new-items/confirm-all', {'store_id': storeId, 'dry_run': dryRun}) as Map<String, dynamic>;

  Future<void> retryNewItem(String id) => api.post('/store/start/new-items/$id/retry');

  /// Карточка в «Новых» с этим штрихкодом (null — нет): сканер проверяет её,
  /// прежде чем предлагать «Новый товар» — второй раз тот же товар не заводим.
  Future<Map<String, dynamic>?> newItemByBarcode(String code) async {
    final r = await api.get('/store/start/new-items/by-barcode', {'store_id': storeId, 'code': code}) as Map<String, dynamic>;
    return r['item'] as Map<String, dynamic>?;
  }

  /// «Это он»: карточка [id] — тот же товар, что [into]; фото переходят туда, [id] убирается.
  Future<Map<String, dynamic>> mergeNewItem(String id, String into) async =>
      await api.post('/store/start/new-items/$id/merge', {'store_id': storeId, 'into': into}) as Map<String, dynamic>;

  Future<void> deleteNewItem(String id) => api.delete('/store/start/new-items/$id');

  /// Шаг 2 «Инвентаризация»: что нашлось по штрихкоду —
  /// {status: line | product | none, line, product}. line — товар уже в «Моих
  /// товарах» (сразу количество и цены), product — есть в центральной базе, но
  /// не добавлен, none — нет нигде (дальше каталог ИКПУ или новый товар).
  Future<Map<String, dynamic>> scan(String code) async =>
      await api.get('/store/start/scan', {'store_id': storeId, 'code': code}) as Map<String, dynamic>;

  /// Запомнить шаг (1 — выбор товаров, 2 — инвентаризация). Шаг общий с
  /// веб-панелью: от него зависит, что делает «Штрихкод» на главной.
  Future<void> setStep(int step) => api.post('/store/start/step', {'store_id': storeId, 'step': step});

  /// Фото товару, у которого его нет, — прямо из инвентаризации.
  Future<Map<String, dynamic>> setPhoto(String productId, List<String> images) async =>
      await api.post('/store/start/lines/$productId/photo', {'store_id': storeId, 'images': images}) as Map<String, dynamic>;

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
