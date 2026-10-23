import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

/// Открытые источники по штрихкоду (Figma «Касса · Штрихкода нет нигде —
/// ищем в открытых источниках»):
///
/// - каталог ИКПУ tasnif.soliq.uz — название, ИКПУ, единица. Сервер Super
///   Market до tasnif не достаёт, поэтому спрашивает касса (она в Узбекистане);
/// - Open Food Facts — название, бренд, объём, фото, без ИКПУ.
///
/// Оба запроса идут одновременно; ждём не дольше [openSourcesLimit]
/// (обычно отвечают за 0,05 и 0,3 секунды). Источник не ответил — значит,
/// там не нашли.
const openSourcesLimit = Duration(seconds: 2);

const _tasnif = 'https://tasnif.soliq.uz/api/cls-api/mxik/search/by-params';
const _off = 'https://world.openfoodfacts.org/api/v2/product';

/// Находки как есть: записи tasnif (поля, которые понимает сервер) и товар
/// Open Food Facts.
class OpenRaw {
  const OpenRaw(this.tasnif, this.off);
  final List<Map<String, dynamic>> tasnif;
  final Map<String, dynamic>? off;
}

Future<OpenRaw> searchOpen(String code, {http.Client? client}) async {
  final c = client ?? http.Client();
  try {
    final r = await Future.wait([_searchTasnif(c, code), _searchOff(c, code)]);
    return OpenRaw(r[0] as List<Map<String, dynamic>>, r[1] as Map<String, dynamic>?);
  } finally {
    if (client == null) c.close();
  }
}

Future<List<Map<String, dynamic>>> _searchTasnif(http.Client c, String code) async {
  try {
    final uri = Uri.parse(_tasnif).replace(queryParameters: {'lang': 'ru', 'size': '10', 'page': '0', 'gtin': code});
    final res = await c.get(uri).timeout(openSourcesLimit);
    if (res.statusCode != 200) return const [];
    final j = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
    final data = (j['data'] as Map<String, dynamic>?) ?? const {};
    return ((data['content'] as List?) ?? const [])
        .whereType<Map<String, dynamic>>()
        .where((r) => RegExp(r'^\d{17}$').hasMatch('${r['mxikCode'] ?? ''}'))
        .map(_pickTasnif)
        .toList();
  } catch (_) {
    return const [];
  }
}

Map<String, dynamic> _pickTasnif(Map<String, dynamic> r) {
  String s(String k) => r[k] == null ? '' : '${r[k]}';
  return {
    for (final k in const ['mxikCode', 'mxikName', 'groupCode', 'classCode', 'groupName', 'className', 'positionName', 'subPositionName', 'brandName', 'attributeName', 'internationalCode']) k: s(k),
    'label': r['label'] ?? 0,
  };
}

Future<Map<String, dynamic>?> _searchOff(http.Client c, String code) async {
  try {
    final uri = Uri.parse('$_off/$code.json').replace(queryParameters: {'fields': 'product_name,product_name_ru,brands,quantity,image_front_small_url'});
    final res = await c.get(uri, headers: {'User-Agent': 'SuperMarketPOS/1.0 (super-market.uz)'}).timeout(openSourcesLimit);
    if (res.statusCode != 200) return null;
    final j = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
    if (j['status'] != 1) return null;
    final p = (j['product'] as Map<String, dynamic>?) ?? const {};
    String s(String k) => p[k] == null ? '' : '${p[k]}'.trim();
    final name = s('product_name_ru').isNotEmpty ? s('product_name_ru') : s('product_name');
    if (name.isEmpty) return null;
    return {'product_name': name, 'brands': s('brands'), 'quantity': s('quantity'), 'image': s('image_front_small_url')};
  } catch (_) {
    return null;
  }
}

/// Вариант для окна (сервер привёл название к правилам каталога).
class FoundCandidate {
  const FoundCandidate({required this.source, required this.index, required this.name, this.ikpu = '', this.unit = '', this.brand = '', this.image = '', this.marked = false});

  /// tasnif или off.
  final String source;

  /// Номер записи tasnif в [FoundGoods.tasnif] (у off — -1).
  final int index;
  final String name;
  final String ikpu;
  final String unit;
  final String brand;
  final String image;
  final bool marked;

  bool get fromTasnif => source == 'tasnif';

  factory FoundCandidate.fromJson(Map<String, dynamic> j) => FoundCandidate(
        source: j['source'] as String? ?? '',
        index: (j['index'] as num?)?.toInt() ?? -1,
        name: j['name'] as String? ?? '',
        ikpu: j['ikpu'] as String? ?? '',
        unit: j['unit'] as String? ?? '',
        brand: j['brand'] as String? ?? '',
        image: j['image'] as String? ?? '',
        marked: j['marked'] == true,
      );
}

/// Что нашли по штрихкоду: варианты для окна и записи как есть (для «Это он»).
class FoundGoods {
  const FoundGoods(this.barcode, this.items, this.tasnif, this.off);
  final String barcode;
  final List<FoundCandidate> items;
  final List<Map<String, dynamic>> tasnif;
  final Map<String, dynamic>? off;
}
