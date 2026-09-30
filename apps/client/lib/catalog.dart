import 'package:flutter/material.dart';

/// Категория каталога магазина с подкатегориями и числом товаров.
class CatalogCategory {
  CatalogCategory(this.id, this.name, this.ownCount, {this.imageUrl});
  final String id;
  final String name;
  final int ownCount;

  /// Картинка плитки (загружает супер-админ); null — иконка.
  final String? imageUrl;
  final List<CatalogCategory> children = [];
  int get count => ownCount + children.fold<int>(0, (s, c) => s + c.count);
}

/// Дерево из плоского списка: корни — без родителя или с родителем, которого нет в списке.
/// Пустые разделы (без товаров и подкатегорий с товарами) отбрасываются.
List<CatalogCategory> buildCategoryTree(List<Map<String, dynamic>> raw) {
  String? img(Object? v) => v is String && v.isNotEmpty ? v : null;
  final byId = {
    for (final c in raw)
      c['id'] as String: CatalogCategory(c['id'] as String, c['name'] as String, (c['products_count'] as num?)?.toInt() ?? 0,
          imageUrl: img(c['image_url'])),
  };
  final roots = <CatalogCategory>[];
  for (final c in raw) {
    final node = byId[c['id']]!;
    final parent = byId[c['parent_id']];
    if (parent == null) {
      roots.add(node);
    } else {
      parent.children.add(node);
    }
  }
  void prune(List<CatalogCategory> list) {
    list.removeWhere((c) => c.count == 0);
    for (final c in list) {
      prune(c.children);
    }
  }

  prune(roots);
  return roots;
}

/// Разделы для витрины: раздел с подкатегориями — заголовок и плитки
/// подкатегорий (идут первыми); разделы без подкатегорий собираются в общий
/// блок «Каталог» в конце.
List<({String? id, String title, List<CatalogCategory> tiles})> catalogSections(List<CatalogCategory> roots) {
  final leaves = roots.where((c) => c.children.isEmpty).toList();
  return [
    for (final c in roots.where((c) => c.children.isNotEmpty)) (id: c.id, title: c.name, tiles: c.children),
    if (leaves.isNotEmpty) (id: null, title: 'Каталог', tiles: leaves),
  ];
}

/// Иконка плитки по названию категории (если нет картинки).
IconData categoryIcon(String name) {
  final n = name.toLowerCase();
  const map = <String, IconData>{
    'молоч': Icons.local_drink_outlined,
    'сыр': Icons.local_pizza_outlined,
    'овощ': Icons.eco_outlined,
    'фрукт': Icons.apple,
    'ягод': Icons.eco_outlined,
    'мяс': Icons.set_meal_outlined,
    'колбас': Icons.lunch_dining_outlined,
    'птиц': Icons.egg_alt_outlined,
    'рыб': Icons.phishing_outlined,
    'хлеб': Icons.bakery_dining_outlined,
    'выпеч': Icons.bakery_dining_outlined,
    'напит': Icons.local_cafe_outlined,
    'сок': Icons.local_drink_outlined,
    'вод': Icons.water_drop_outlined,
    'сладо': Icons.cake_outlined,
    'конди': Icons.cake_outlined,
    'морож': Icons.icecream_outlined,
    'замор': Icons.ac_unit_rounded,
    'бакал': Icons.rice_bowl_outlined,
    'крупы': Icons.rice_bowl_outlined,
    'снек': Icons.fastfood_outlined,
    'хими': Icons.cleaning_services_outlined,
    'чист': Icons.cleaning_services_outlined,
    'быт': Icons.cleaning_services_outlined,
    'гигиен': Icons.soap_outlined,
    'дет': Icons.child_friendly_outlined,
    'кош': Icons.pets_outlined,
    'соба': Icons.pets_outlined,
    'живот': Icons.pets_outlined,
    'чай': Icons.emoji_food_beverage_outlined,
    'кофе': Icons.coffee_outlined,
    'яйц': Icons.egg_outlined,
    'кухн': Icons.kitchen_outlined,
    'электр': Icons.electrical_services_outlined,
    'канцел': Icons.edit_outlined,
  };
  for (final e in map.entries) {
    if (n.contains(e.key)) return e.value;
  }
  return Icons.shopping_basket_outlined;
}
