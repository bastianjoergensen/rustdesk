import 'dart:ui';

import 'package:flutter_hbb/models/mobile_display_layout.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // A 2560x1440 display with a 1920x1080 one on its right.
  const remote = [
    Rect.fromLTWH(0, 0, 2560, 1440),
    Rect.fromLTWH(2560, 0, 1920, 1080),
  ];

  // The second display stacked below the first.
  MobileDisplayLayout stacked() =>
      MobileDisplayLayout(remote)..move(1, const Offset(-2560, 1440));

  test('until a display is moved, layout and remote are the same', () {
    final l = MobileDisplayLayout(remote);
    expect(l.isIdentity, isTrue);
    expect(l.bounds, const Rect.fromLTWH(0, 0, 4480, 1440));
    expect(l.toRemote(const Offset(3000, 500)), const Offset(3000, 500));
    expect(l.toLayout(const Offset(100, 1000)), const Offset(100, 1000));
  });

  test('a moved display maps back to where it is on the remote', () {
    final l = stacked();
    expect(l.isIdentity, isFalse);
    expect(l.bounds, const Rect.fromLTWH(0, 0, 2560, 2520));
    expect(l.displayAt(const Offset(100, 1500)), 1);
    expect(l.toRemote(const Offset(100, 1500)), const Offset(2660, 60));
    expect(l.toLayout(const Offset(2660, 60)), const Offset(100, 1500));
    expect(l.toRemote(const Offset(100, 100)), const Offset(100, 100));
    expect(l.toLayout(const Offset(100, 100)), const Offset(100, 100));
  });

  test('points between displays go to the nearest one', () {
    final l = stacked();
    expect(l.displayAt(const Offset(2300, 2000)), isNull);
    expect(l.toRemote(const Offset(2300, 2000)), const Offset(4479, 560));
  });

  test('a display dropped onto another is pushed out of it', () {
    final l = MobileDisplayLayout(remote)..move(1, const Offset(-2000, 700));
    expect(l.layoutRect(1).overlaps(l.layoutRect(0)), isTrue);
    l.settle(1, 0);
    expect(l.layoutRect(1).overlaps(l.layoutRect(0)), isFalse);
    expect(l.offsets[1], const Offset(560, 1440));
  });

  test('edges close to each other snap together', () {
    final l = MobileDisplayLayout(remote)..move(1, const Offset(-2550, 1460));
    l.settle(1, 30);
    expect(l.offsets[1], const Offset(0, 1440));
  });

  test('a saved layout only comes back for the same displays', () {
    final saved = stacked().encode();
    expect(MobileDisplayLayout.restore(remote, saved).offsets[1],
        const Offset(0, 1440));
    const other = [
      Rect.fromLTWH(0, 0, 2560, 1440),
      Rect.fromLTWH(2560, 0, 1280, 1024),
    ];
    expect(MobileDisplayLayout.restore(other, saved).isIdentity, isTrue);
    expect(MobileDisplayLayout.restore(remote, '').isIdentity, isTrue);
    expect(MobileDisplayLayout.restore(remote, 'garbage').isIdentity, isTrue);
  });
}
