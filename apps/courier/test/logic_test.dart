import 'package:flutter_test/flutter_test.dart';
import 'package:sm_courier/logic.dart';

Map<String, dynamic> c(String id, String status, {Map<String, dynamic> order = const {}}) => {
      'order': {'id': id, 'status': status, ...order},
      'store': {'name': 'Baraka'},
    };

void main() {
  test('группы заказов: везу, забрать (собранные первыми), доставлены', () {
    final g = groupOrders([c('1', 'picking'), c('2', 'delivering'), c('3', 'picked'), c('4', 'delivered'), c('5', 'cancelled')]);
    expect(g.delivering.map(idOf), ['2']);
    expect(g.toPick.map(idOf), ['3', '1']);
    expect(g.done.map(idOf), ['4']);
  });

  test('адрес: подъезд, этаж, квартира', () {
    expect(flatDetails({'entrance': '2', 'floor': '5', 'apartment': '45'}), 'Подъезд 2 · этаж 5 · кв. 45');
    expect(flatDetails({'apartment': '3'}), 'Кв. 3');
    expect(flatDetails({}), '');
  });

  test('когда доставить', () {
    final from = DateTime(2026, 10, 2, 14).toUtc().toIso8601String();
    final to = DateTime(2026, 10, 2, 15).toUtc().toIso8601String();
    expect(whenText({'delivery_from': from, 'delivery_to': to}), '14:00–15:00');
    expect(whenText({'eta_at': DateTime(2026, 10, 2, 14, 40).toUtc().toIso8601String()}), 'к 14:40');
    expect(whenText({}), 'как можно скорее');
  });

  test('склонения и расстояния', () {
    expect(itemsText(1), '1 товар');
    expect(itemsText(3), '3 товара');
    expect(itemsText(11), '11 товаров');
    expect(itemsText(22), '22 товара');
    expect(distanceText(450), '450 м');
    expect(distanceText(1234), '1,2 км');
    expect(distanceText(null), '');
  });

  test('новые заказы — только незнакомые и не доставленные', () {
    final before = [c('1', 'picked')];
    final after = [c('1', 'picked'), c('2', 'accepted'), c('3', 'delivered')];
    expect(newOrderIds(before, after), {'2'});
  });

  test('подписи статусов и транспорта', () {
    expect(statusTitle('picked'), 'Собран');
    expect(statusTitle('weird'), 'weird');
    expect(vehicleTitles['scooter'], 'Самокат');
  });

  test('запрос на удаление: причина необязательна, до 500 символов', () {
    expect(deletionRequestBody(null), isEmpty);
    expect(deletionRequestBody('  '), isEmpty);
    expect(deletionRequestBody(' Другое: уезжаю '), {'reason': 'Другое: уезжаю'});
    expect((deletionRequestBody('я' * 600)['reason'] as String).length, 500);
    expect(deletionReasons, contains('Больше здесь не работаю'));
    expect(privacyUrl, 'https://super-market.uz/privacy');
    expect(courierTermsUrl, 'https://super-market.uz/courier-terms');
  });
}
