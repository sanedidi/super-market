import 'package:flutter/foundation.dart';
import 'package:sm_core/sm_core.dart';

import 'catalog.dart';
import 'my_qr.dart';

/// id точки гостя: адрес не сохранён на сервере, это только координаты
/// (геолокация или точка на карте), чтобы показать магазины рядом.
const guestPointId = 'guest';

/// Политика конфиденциальности, если сервер не прислал ссылку.
const defaultPrivacyUrl = 'https://super-market.uz/privacy';

/// Адрес доставки покупателя.
class Address {
  Address(this.json);
  final Map<String, dynamic> json;

  String get id => json['id'] as String;
  String get label => (json['label'] as String?) ?? '';
  String get address => (json['address'] as String?) ?? '';
  double get lat => (json['lat'] as num).toDouble();
  double get lng => (json['lng'] as num).toDouble();
  String get title => label.isNotEmpty ? label : address;

  /// Точка гостя, а не сохранённый адрес: заказать на неё нельзя.
  bool get isGuestPoint => id == guestPointId;
}

/// Товар в каталоге магазина.
class Product {
  Product(this.json);
  final Map<String, dynamic> json;

  String get id => json['id'] as String;
  String get name => json['name'] as String;
  String get price => json['price'] as String;
  String get available => json['available'] as String;
  String get unit => (json['unit_short'] as String?) ?? '';
  bool get fractional => json['is_fractional'] == true;
  String? get image {
    final images = (json['images'] as List?) ?? const [];
    return images.isEmpty ? null : images.first as String;
  }
  String? get brand => json['brand_name'] as String?;
  String get description => (json['description'] as String?) ?? '';
  List<String> get images => ((json['images'] as List?) ?? const []).cast<String>();

  /// Цена до скидки, если действует акция.
  String? get oldPrice => json['old_price'] as String?;
  int? get discountPercent => (json['discount_percent'] as num?)?.toInt();
  bool get isNew => json['is_new'] == true;

  /// Шаг количества: 1 шт или 0,5 кг.
  num get step => fractional ? 0.5 : 1;

  /// Вариации (вес и вкус) — только в полной карточке товара, иначе null.
  ProductVariants? get variants {
    final v = json['variants'];
    return v is Map<String, dynamic> ? ProductVariants(v) : null;
  }
}

/// Группа вариаций товара: один товар разного веса и вкуса («Чипсы Lay's»:
/// 90 г и 150 г; «Сметана и лук», «Сыр»). Каждая вариация — отдельный товар.
/// В [options] — только то, что есть в наличии в этом магазине, по весу и
/// порядку в группе. Подписи сервер отдаёт на языке запроса.
class ProductVariants {
  ProductVariants(this.json);
  final Map<String, dynamic> json;

  String get groupId => (json['group_id'] as String?) ?? '';
  String get name => (json['name'] as String?) ?? '';

  /// Вес и вкус открытого товара («150 г», «Пицца Пепперони»); могут быть пустыми.
  String get weight => (json['weight'] as String?) ?? '';
  String get flavor => (json['flavor'] as String?) ?? '';

  /// Названия переключателей группы на языке запроса: «Вес» / «Объём» /
  /// «Размер»… и «Вкус» / «Цвет» / «Аромат». Пустая строка — такого
  /// переключателя у группы нет (у вазы нет веса); null — старый ответ без
  /// поля, тогда подписи прежние («Вес», «Вкус»).
  String? get weightLabel => json['weight_label'] as String?;
  String? get flavorLabel => json['flavor_label'] as String?;

  /// Веса по возрастанию — только те, у которых есть вариации в наличии.
  List<String> get weights => ((json['weights'] as List?) ?? const []).map((e) => '$e').toList();
  List<VariantOption> get options => ((json['options'] as List?) ?? const []).whereType<Map<String, dynamic>>().map(VariantOption.new).toList();

  /// Вариации одного веса.
  List<VariantOption> inWeight(String weight) => options.where((o) => o.weight == weight).toList();

  /// Вариация товара [productId], если она есть в наличии.
  VariantOption? byProduct(String productId) => options.where((o) => o.productId == productId).firstOrNull;

  /// Выбрали вес: тот же вкус в этом весе ([exact]), а если его нет —
  /// первая вариация веса. null — у веса нет вариаций.
  ({VariantOption option, bool exact})? pickForWeight(String weight, String flavor) {
    final list = inWeight(weight);
    if (list.isEmpty) return null;
    final key = flavorKey(flavor);
    final same = list.where((o) => flavorKey(o.flavor) == key).firstOrNull;
    return same != null ? (option: same, exact: true) : (option: list.first, exact: false);
  }

  /// Вкусы сравниваем без регистра и пробелов по краям.
  static String flavorKey(String s) => s.trim().toLowerCase();
}

/// Вариация из [ProductVariants.options]: товар, его вес, вкус, фото и цена.
class VariantOption {
  VariantOption(this.json);
  final Map<String, dynamic> json;

  String get productId => json['product_id'] as String;
  String get weight => (json['weight'] as String?) ?? '';
  String get flavor => (json['flavor'] as String?) ?? '';
  String? get image {
    final u = json['image'] as String?;
    return u == null || u.isEmpty ? null : u;
  }

  String get price => '${json['price'] ?? '0'}';
  String? get oldPrice => json['old_price'] as String?;
  int? get discountPercent => (json['discount_percent'] as num?)?.toInt();
}

/// Магазин из /client/home: доставка считается для выбранного адреса.
/// Магазины из `others` по адресу не доставляют — товары можно посмотреть,
/// заказать нельзя (у них нет `delivery`).
class Store {
  Store(this.json);
  final Map<String, dynamic> json;

  String get id => json['id'] as String;
  String get name => json['name'] as String;
  String get networkName => (json['network_name'] as String?) ?? '';
  String get address => (json['address'] as String?) ?? '';
  double get lat => (json['lat'] as num).toDouble();
  double get lng => (json['lng'] as num).toDouble();
  bool get recommended => json['recommended'] == true;
  Map<String, dynamic> get delivery => (json['delivery'] as Map<String, dynamic>?) ?? const {};

  /// Доставляет по выбранному адресу (иначе — только посмотреть товары).
  bool get delivers => json['delivery'] is Map;

  /// Почему не доставляет: not_online — нет онлайн-заказов, out_of_zone — адрес вне зоны.
  String get reason => (json['reason'] as String?) ?? '';
  bool get isOpen => delivers ? delivery['is_open'] == true : json['is_open'] == true;
  int get distanceM => ((delivers ? delivery['distance_m'] : json['distance_m']) as num?)?.toInt() ?? 0;
  String get deliveryFee => '${delivery['delivery_fee'] ?? '0'}';
  String get minOrder => '${delivery['min_order_amount'] ?? '0'}';
  String? get freeFrom => delivery['free_from'] as String?;
  bool get freeDelivery => (num.tryParse(deliveryFee) ?? 0) == 0;
  String? get logoUrl {
    final u = json['logo_url'] as String?;
    return u == null || u.isEmpty ? null : u;
  }

  int? get etaMin => (json['eta_min'] as num?)?.toInt();
  int? get etaMax => (json['eta_max'] as num?)?.toInt();

  /// «25–35 мин» или null.
  String? get etaText {
    if (etaMin == null && etaMax == null) return null;
    if (etaMin != null && etaMax != null && etaMin != etaMax) return tr('$etaMin–$etaMax мин', '$etaMin–$etaMax daq');
    return tr('${etaMax ?? etaMin} мин', '${etaMax ?? etaMin} daq');
  }

  String get distanceText => distanceM < 1000 ? tr('$distanceM м', '$distanceM m') : tr('${(distanceM / 1000).toStringAsFixed(1)} км', '${(distanceM / 1000).toStringAsFixed(1)} km');
}

class CartLine {
  CartLine(this.product, this.qty, {this.blockId});
  final Product product;
  num qty;

  /// Блок главной, из которого товар добавили (статистика витрины).
  String? blockId;
}

/// Состояние приложения: адреса, выбранный адрес, корзина одного магазина.
class AppState extends ChangeNotifier {
  AppState(this.api) {
    api.addListener(() {
      if (!api.loggedIn) {
        addresses = [];
        address = null;
        addressesLoaded = false;
        cart.clear();
        cartStoreId = null;
        cartStoreName = null;
        stores = [];
        others = [];
        wishes = {};
        _storesFor = null;
        catalogStoreId = null;
        _categories.clear();
        tab = 0;
        banners = [];
        deals = null;
        favorites = {};
        profile = null;
        stats = null;
        debts = null;
        forgetQrKey().ignore(); // QR прежнего покупателя на телефоне не оставляем
        family = null;
        familyRequestId = null;
        unread = 0;
        pendingBlock = null;
      }
    });
    Lang.instance.addListener(_onLangChanged);
  }
  final Api api;

  /// Сменили язык: названия магазинов, категорий и товаров сервер отдаёт на
  /// языке запроса — перезагружаем то, что закэшировано.
  void _onLangChanged() {
    _categories.clear();
    if (address != null) loadStores(force: true);
  }

  @override
  void dispose() {
    Lang.instance.removeListener(_onLangChanged);
    super.dispose();
  }

  /// Гость: вход не выполнен. Можно смотреть магазины и товары и собирать
  /// корзину; оформление, избранное, семья и разделы профиля — после входа
  /// (requireLogin в guest.dart). Запросы, которым нужен вход, гость не шлёт.
  bool get isGuest => !api.loggedIn;

  /// Настройки до входа (/client/config): ссылки на поддержку, оферту, политику.
  Map<String, dynamic>? config;

  Future<void> loadConfig() async {
    if (config != null) return;
    try {
      config = await api.get('/client/config') as Map<String, dynamic>;
      notifyListeners();
    } catch (_) {
      // Ссылки необязательны.
    }
  }

  /// Ссылка из профиля, иначе из /client/config: support_url, privacy_url, offer_url, bot_url.
  String link(String key) {
    for (final m in [profile, config]) {
      final v = '${m?[key] ?? ''}';
      if (v.isNotEmpty) return v;
    }
    return '';
  }

  String get privacyUrl {
    final u = link('privacy_url');
    return u.isEmpty ? defaultPrivacyUrl : u;
  }

  List<Address> addresses = [];
  Address? address;

  /// Адреса загружены хотя бы раз (до этого не показываем «добавьте адрес»).
  bool addressesLoaded = false;

  /// Непрочитанные уведомления — точка на колокольчике.
  int unread = 0;

  Future<void> loadUnread() async {
    if (isGuest) return;
    try {
      final r = await api.get('/client/notifications/unread') as Map<String, dynamic>;
      unread = (r['count'] as num?)?.toInt() ?? 0;
      notifyListeners();
    } catch (_) {
      // Колокольчик не критичен.
    }
  }

  /// Отметить все уведомления прочитанными.
  Future<void> markAllRead() async {
    unread = 0;
    notifyListeners();
    await api.post('/client/notifications/read', {'all': true});
  }

  /// Вкладка нижнего меню: 0 главная, 1 каталог, 2 карта, 4 профиль (корзина открывается поверх).
  int tab = 0;

  /// Магазины, которые доставляют по выбранному адресу.
  List<Store> stores = [];

  /// Магазины до 10 км, которые по адресу не доставляют (можно попросить доставку).
  List<Store> others = [];

  /// Магазины, у которых покупатель нажал «Хочу доставку».
  Set<String> wishes = {};

  /// Магазин по id — и доставляющий, и нет.
  Store? storeById(String? id) => id == null ? null : (stores.where((s) => s.id == id).firstOrNull ?? others.where((s) => s.id == id).firstOrNull);

  /// Из магазина можно заказать (он доставляет по выбранному адресу).
  bool canOrder(String storeId) => stores.any((s) => s.id == storeId);

  /// Сколько магазинов рядом доставляют и самое быстрое время доставки.
  String? get fastestEta {
    int? best;
    for (final s in stores) {
      final m = s.etaMin ?? s.etaMax;
      if (m != null && (best == null || m < best)) best = m;
    }
    return best == null ? null : tr('$best мин', '$best daq');
  }
  bool storesLoading = false;
  Object? storesError;
  String? _storesFor;

  /// Баннеры и «Скидки недели» для главной (из /client/home).
  List<Map<String, dynamic>> banners = [];
  Map<String, dynamic>? deals;

  /// Избранные товары (id).
  Set<String> favorites = {};

  /// Магазин, чей каталог открыт во вкладке «Каталог».
  String? catalogStoreId;

  Store? get catalogStore {
    return storeById(catalogStoreId) ??
        storeById(cartStoreId) ??
        stores.where((s) => s.recommended && s.isOpen).firstOrNull ??
        stores.where((s) => s.isOpen).firstOrNull ??
        stores.firstOrNull ??
        // Никто не доставляет — показываем ближайший магазин: товары и «Хочу доставку».
        others.firstOrNull;
  }

  void setTab(int i) {
    tab = i;
    notifyListeners();
  }

  /// Блок главной, к которому прокрутить (переход из уведомления).
  String? pendingBlock;

  void focusBlock(String id) {
    pendingBlock = id.isEmpty ? null : id;
    notifyListeners();
  }

  /// Выбрать магазин витрины на главной.
  void openCatalog(Store s) {
    catalogStoreId = s.id;
    notifyListeners();
  }

  final Map<String, Future<List<CatalogCategory>>> _categories = {};

  /// Категории магазина (кэш на время сессии; [force] — перезагрузить).
  Future<List<CatalogCategory>> categoriesOf(Store s, {bool force = false}) {
    if (force) _categories.remove(s.id);
    return _categories.putIfAbsent(s.id, () {
      final f = api.list('/client/stores/${s.id}/categories').then(buildCategoryTree);
      f.catchError((_) {
        _categories.remove(s.id);
        return <CatalogCategory>[];
      });
      return f;
    });
  }

  Future<void> loadStores({bool force = false}) async {
    final a = address;
    if (a == null) {
      stores = [];
      others = [];
      _storesFor = null;
      notifyListeners();
      return;
    }
    // Ключ — и id, и точка: у гостя id один, а точка меняется.
    final key = '${a.id}@${a.lat},${a.lng}';
    if (!force && _storesFor == key && storesError == null) return;
    _storesFor = key;
    storesLoading = true;
    storesError = null;
    notifyListeners();
    try {
      final home = await api.get('/client/home', {'lat': a.lat, 'lng': a.lng}) as Map<String, dynamic>;
      if (_storesFor != key) return;
      stores = ((home['stores'] as List?) ?? const []).cast<Map<String, dynamic>>().map(Store.new).toList();
      others = ((home['others'] as List?) ?? const []).cast<Map<String, dynamic>>().map(Store.new).toList();
      if (api.loggedIn) loadWishes();
      banners = ((home['banners'] as List?) ?? const []).cast<Map<String, dynamic>>();
      deals = home['deals'] as Map<String, dynamic>?;
    } catch (e) {
      storesError = e;
    } finally {
      storesLoading = false;
      notifyListeners();
    }
  }

  Future<void> loadWishes() async {
    if (isGuest) return;
    try {
      final items = await api.get('/client/wishes') as Map<String, dynamic>;
      wishes = ((items['items'] as List?) ?? const []).cast<String>().toSet();
      notifyListeners();
    } catch (_) {
      // Не критично: кнопка покажет «Хочу доставку».
    }
  }

  /// «Хочу доставку» / снять. Голос привязан к точке выбранного адреса.
  Future<void> toggleWish(Store s) async {
    final a = address;
    if (a == null) return;
    final on = !wishes.contains(s.id);
    on ? wishes.add(s.id) : wishes.remove(s.id);
    notifyListeners();
    try {
      if (on) {
        await api.post('/client/stores/${s.id}/wish', {'lat': a.lat, 'lng': a.lng});
      } else {
        await api.delete('/client/stores/${s.id}/wish');
      }
    } catch (_) {
      on ? wishes.remove(s.id) : wishes.add(s.id);
      notifyListeners();
      rethrow;
    }
  }

  String? cartStoreId;
  String? cartStoreName;
  final Map<String, CartLine> cart = {};

  /// Точка гостя: магазины рядом с ней (адрес на сервере не сохраняется).
  void setGuestPoint(double lat, double lng) {
    address = Address({'id': guestPointId, 'label': '', 'address': '', 'lat': lat, 'lng': lng});
    addressesLoaded = true;
    notifyListeners();
    loadStores(force: true);
  }

  Future<void> loadAddresses() async {
    if (isGuest) return;
    final List<Map<String, dynamic>> items;
    try {
      items = await api.list('/client/addresses');
    } catch (_) {
      addressesLoaded = true;
      notifyListeners();
      rethrow;
    }
    addresses = items.map(Address.new).toList();
    addressesLoaded = true;
    if (address == null || !addresses.any((a) => a.id == address!.id)) {
      // Вошли из гостя без сохранённых адресов — витрина остаётся у точки гостя.
      final keep = address?.isGuestPoint == true ? address : null;
      address = addresses.isEmpty ? keep : addresses.first;
    } else {
      address = addresses.firstWhere((a) => a.id == address!.id);
    }
    notifyListeners();
    await loadStores();
  }

  void selectAddress(Address a) {
    address = a;
    notifyListeners();
    loadStores();
  }

  num qtyOf(String productId) => cart[productId]?.qty ?? 0;

  int get cartCount => cart.length;

  String get cartTotal => addMoney(cart.values.map((l) => mulMoney(l.product.price, '${l.qty}')));

  /// Изменить количество. Корзина — одного магазина; товар другого магазина
  /// очищает её (UI спрашивает подтверждение заранее).
  void setQty(String storeId, String storeName, Product p, num qty, {String? blockId}) {
    if (cartStoreId != null && cartStoreId != storeId) {
      cart.clear();
      familyRequestId = null;
    }
    cartStoreId = storeId;
    cartStoreName = storeName;
    final max = num.tryParse(p.available) ?? 0;
    if (qty > max) qty = max;
    if (qty <= 0) {
      cart.remove(p.id);
    } else {
      final line = cart.putIfAbsent(p.id, () => CartLine(p, qty, blockId: blockId))..qty = qty;
      line.blockId ??= blockId;
    }
    if (cart.isEmpty) {
      cartStoreId = null;
      cartStoreName = null;
    }
    notifyListeners();
  }

  void clearCart() {
    cart.clear();
    familyRequestId = null;
    cartStoreId = null;
    cartStoreName = null;
    notifyListeners();
  }

  List<Map<String, dynamic>> get cartItems =>
      cart.values.map((l) => {'product_id': l.product.id, 'qty': l.qty.toString(), if (l.blockId != null) 'block_id': l.blockId}).toList();

  /// Профиль покупателя (/client/me) и статистика (/client/me/stats).
  Map<String, dynamic>? profile;
  Map<String, dynamic>? stats;

  Future<void> loadProfile() async {
    if (isGuest) return;
    loadDebts().catchError((_) {}); // долги не мешают профилю загрузиться
    final results = await Future.wait([api.get('/client/me'), api.get('/client/me/stats')]);
    profile = results[0] as Map<String, dynamic>;
    stats = results[1] as Map<String, dynamic>;
    notifyListeners();
    syncLanguage();
  }

  /// Только статистика (в ней текущий заказ) — для частого обновления главной.
  Future<void> loadStats() async {
    if (isGuest) return;
    stats = await api.get('/client/me/stats') as Map<String, dynamic>;
    notifyListeners();
  }

  /// Язык приложения — главный: если в профиле на сервере другой (сменили
  /// до входа или на другом устройстве), записываем туда язык приложения —
  /// на нём сервер шлёт уведомления.
  Future<void> syncLanguage() async {
    final p = profile;
    if (isGuest || p == null || p['language'] == Lang.instance.code) return;
    try {
      await updateProfile({'language': Lang.instance.code});
    } catch (_) {
      // Не критично: попробуем при следующей загрузке профиля.
    }
  }

  /// Долги покупателя в магазинах (/client/debts): итог, магазины, ближайший срок.
  /// Магазин записывает долг, когда покупатель берёт товар без оплаты.
  Map<String, dynamic>? debts;

  Future<void> loadDebts() async {
    if (isGuest) return;
    debts = await api.get('/client/debts') as Map<String, dynamic>;
    notifyListeners();
  }

  /// Долг в магазине, если есть (для плашки на странице магазина).
  Map<String, dynamic>? debtAt(String storeId) {
    for (final d in ((debts?['stores'] as List?) ?? const []).cast<Map<String, dynamic>>()) {
      if (d['store_id'] == storeId) return d;
    }
    return null;
  }

  /// Изменить профиль: имя, язык, город, настройки уведомлений.
  Future<void> updateProfile(Map<String, dynamic> patch) async {
    profile = await api.patch('/client/me', patch) as Map<String, dynamic>;
    notifyListeners();
  }

  bool isFavorite(String productId) => favorites.contains(productId);

  Future<void> loadFavorites() async {
    if (isGuest) return;
    try {
      final r = await api.get('/client/favorites') as Map<String, dynamic>;
      favorites = ((r['product_ids'] as List?) ?? const []).cast<String>().toSet();
      notifyListeners();
    } catch (_) {
      // Избранное не критично для запуска.
    }
  }

  /// Добавить или убрать из избранного; при ошибке возвращает прежнее состояние.
  Future<void> toggleFavorite(String productId) async {
    final had = favorites.contains(productId);
    had ? favorites.remove(productId) : favorites.add(productId);
    notifyListeners();
    try {
      final r = had
          ? await api.delete('/client/favorites/$productId')
          : await api.post('/client/favorites', {'product_id': productId});
      if (r is Map<String, dynamic>) {
        favorites = ((r['product_ids'] as List?) ?? const []).cast<String>().toSet();
      }
    } catch (_) {
      had ? favorites.add(productId) : favorites.remove(productId);
      rethrow;
    } finally {
      notifyListeners();
    }
  }

  /// Семья (/client/family) или null, если пользователь ещё не в семье.
  Map<String, dynamic>? family;
  bool familyLoaded = false;

  /// Просьбы «для меня» — бейдж в профиле.
  int get familyForMe => (family?['requests_for_me'] as num?)?.toInt() ?? 0;

  Future<void> loadFamily() async {
    if (isGuest) return;
    final r = await api.get('/client/family') as Map<String, dynamic>;
    family = r['family'] as Map<String, dynamic>?;
    familyLoaded = true;
    notifyListeners();
  }

  /// Просьба семьи, товары которой сейчас в корзине: после оформления заказа
  /// она отмечается «заказана».
  String? familyRequestId;

  /// «Заказать домой»: корзина заполняется найденными товарами просьбы.
  void fillCartFromRequest(String requestId, Store store, List<(Product, num)> lines) {
    cart.clear();
    cartStoreId = store.id;
    cartStoreName = store.name;
    for (final (p, q) in lines) {
      final max = num.tryParse(p.available) ?? 0;
      final qty = q > max ? max : q;
      if (qty > 0) cart[p.id] = CartLine(p, qty);
    }
    if (cart.isEmpty) {
      cartStoreId = null;
      cartStoreName = null;
    }
    familyRequestId = cart.isEmpty ? null : requestId;
    notifyListeners();
  }
}
