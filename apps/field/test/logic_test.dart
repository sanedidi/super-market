import 'package:flutter_test/flutter_test.dart';
import 'package:sm_core/sm_core.dart';
import 'package:sm_field/logic.dart';

void main() {
  setUpAll(() => Lang.instance.debugUse(Lang.ru));

  test('сетка: клетка ≈ 100 м, границы клетки содержат точку', () {
    const g = Grid.tashkent;
    final (cx, cy) = g.cellOf(41.311, 69.279);
    final (s, w, n, e) = g.bounds(cx, cy);
    expect(41.311, inInclusiveRange(s, n));
    expect(69.279, inInclusiveRange(w, e));
    expect(distanceM(s, w, n, w), closeTo(100, 1));
    expect(distanceM(s, w, s, e), closeTo(100, 2));
    // Как на сервере (field/grid.go): номер клетки — floor(координата / размер).
    expect(cx, (69.279 / g.lng).floor());
    expect(Grid.from({'lat': 0.001, 'lng': 0.002}).lat, 0.001);
    expect(Grid.from(null).lat, Grid.tashkent.lat);
  });

  test('форматирование', () {
    expect(formatDistance(384), '380 м');
    expect(formatDistance(3840), '3,8 км');
    expect(formatDistance(4000), '4 км');
    expect(formatClock(5050), '1:24:10');
    expect(formatClock(65), '1:05');
    expect(formatDuration(4 * 3600 + 12 * 60), '4 ч 12 мин');
    expect(formatDuration(45 * 60), '45 мин');
    expect(formatPct(38.44), '38,4%');
    expect(formatPct(41), '41%');
    expect(storesCount(1), '1 магазин');
    expect(storesCount(3), '3 магазина');
    expect(storesCount(11), '11 магазинов');
    expect(storesCount(22), '22 магазина');
  });

  test('прийти позже: сегодня, завтра, просрочено', () {
    final now = DateTime(2026, 11, 7, 15);
    expect(remindLabel('2026-11-07', now: now), 'сегодня');
    expect(remindLabel('2026-11-08', now: now), 'завтра');
    expect(remindLabel('2026-11-12', now: now), '12 ноя');
    expect(remindLabel('2026-11-01', now: now), startsWith('просрочено'));
    expect(remindLabel(null), '');
  });

  test('подписи результатов и причин', () {
    expect(resultLabel('refused'), 'Отказ');
    expect(reasonLabel('has_program'), 'Уже есть программа');
    expect(programLabel('billz'), 'BILLZ');
    expect(directionLabel('e'), 'на восток');
    expect(refuseReasons, contains('owner_against'));
  });

  test('очередь точек: по времени, пачки, сохранение', () {
    final q = PointQueue();
    final t0 = DateTime.utc(2026, 11, 7, 10);
    for (var i = 0; i < 700; i++) {
      expect(q.add(TrackPoint(at: t0.add(Duration(seconds: i)), lat: 41.3 + i * 1e-5, lng: 69.2, accuracy: 5)), isTrue);
    }
    // Та же или более ранняя по времени — не добавляется.
    expect(q.add(TrackPoint(at: t0, lat: 41, lng: 69, accuracy: 5)), isFalse);
    expect(q.next().length, PointQueue.batch);
    q.sent(PointQueue.batch);
    expect(q.length, 200);
    final back = PointQueue.decode(q.encode());
    expect(back.length, 200);
    expect(back.points.first.at, t0.add(const Duration(seconds: 500)));
    expect(back.points.first.toJson()['at'], '2026-11-07T10:08:20.000Z');
    expect(PointQueue.decode('not json').isEmpty, isTrue);
    expect(PointQueue.decode(null).isEmpty, isTrue);
  });

  test('баннер «Здесь уже прошёл»', () {
    final here = {'state': 'other', 'cx': 1, 'cy': 2, 'rep_name': 'Азиз'};
    expect(showOtherBanner(here, dismissed: false), isTrue);
    expect(showOtherBanner(here, dismissed: true), isFalse);
    expect(showOtherBanner({'state': 'mine'}, dismissed: false), isFalse);
    expect(showOtherBanner(null, dismissed: false), isFalse);
    expect(cellKey(here), '1:2');
  });
}
