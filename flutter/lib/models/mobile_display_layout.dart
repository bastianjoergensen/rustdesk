import 'dart:convert';
import 'dart:math';
import 'dart:ui';

/// Where each remote display sits in the all-displays view on mobile.
///
/// The view works in "layout" coordinates: every display keeps its size but
/// may be moved away from where it is on the remote, e.g. stacked below the
/// other one on a portrait phone. Positions going to the remote are mapped
/// back with [toRemote], cursor positions coming from it with [toLayout].
/// Until the user moves a display both spaces are the same.
class MobileDisplayLayout {
  MobileDisplayLayout(this.remote, [List<Offset>? offsets])
      : offsets = offsets ?? [for (final r in remote) r.topLeft] {
    assert(this.offsets.length == remote.length);
  }

  /// The displays as the remote arranges them.
  final List<Rect> remote;

  /// Top left corner of each display in the layout.
  final List<Offset> offsets;

  int get length => remote.length;

  Rect layoutRect(int i) => offsets[i] & remote[i].size;

  Rect get bounds {
    var r = layoutRect(0);
    for (var i = 1; i < length; i++) {
      r = r.expandToInclude(layoutRect(i));
    }
    return r;
  }

  bool get isIdentity {
    for (var i = 0; i < length; i++) {
      if (offsets[i] != remote[i].topLeft) return false;
    }
    return true;
  }

  /// The display under the layout point [p], if any.
  int? displayAt(Offset p) {
    for (var i = length - 1; i >= 0; i--) {
      if (_contains(layoutRect(i), p)) return i;
    }
    return null;
  }

  Offset toRemote(Offset p) {
    final i = displayAt(p) ?? _nearest(p, layoutRect);
    return remote[i].topLeft + (_clampTo(layoutRect(i), p) - offsets[i]);
  }

  Offset toLayout(Offset p) {
    var i = -1;
    for (var j = 0; j < length; j++) {
      if (_contains(remote[j], p)) {
        i = j;
        break;
      }
    }
    if (i < 0) i = _nearest(p, (j) => remote[j]);
    return offsets[i] + (_clampTo(remote[i], p) - remote[i].topLeft);
  }

  void move(int i, Offset delta) => offsets[i] += delta;

  /// Puts display [i] where it was dropped, but lined up with the others: an
  /// edge within [snap] of another display's edge sticks to it, and it is
  /// pushed out of any display it overlaps.
  void settle(int i, double snap) {
    for (var pass = 0; pass < 4; pass++) {
      var moved = false;
      for (var j = 0; j < length; j++) {
        if (j == i) continue;
        final push = _pushOut(layoutRect(i), layoutRect(j));
        if (push != Offset.zero) {
          offsets[i] += push;
          moved = true;
        }
      }
      if (!moved) break;
    }
    offsets[i] += _snapDelta(i, snap);
    // A snap must not push it back into another display.
    for (var j = 0; j < length; j++) {
      if (j != i && _overlaps(layoutRect(i), layoutRect(j))) {
        offsets[i] += _pushOut(layoutRect(i), layoutRect(j));
      }
    }
  }

  // The shortest move that takes [a] out of [b].
  static Offset _pushOut(Rect a, Rect b) {
    if (!_overlaps(a, b)) return Offset.zero;
    final left = b.left - a.right;
    final right = b.right - a.left;
    final up = b.top - a.bottom;
    final down = b.bottom - a.top;
    final dx = left.abs() < right.abs() ? left : right;
    final dy = up.abs() < down.abs() ? up : down;
    return dx.abs() <= dy.abs() ? Offset(dx, 0) : Offset(0, dy);
  }

  Offset _snapDelta(int i, double snap) {
    final a = layoutRect(i);
    double? bestX;
    double? bestY;
    void tryX(double d) {
      if (d.abs() <= snap && (bestX == null || d.abs() < bestX!.abs())) {
        bestX = d;
      }
    }

    void tryY(double d) {
      if (d.abs() <= snap && (bestY == null || d.abs() < bestY!.abs())) {
        bestY = d;
      }
    }

    for (var j = 0; j < length; j++) {
      if (j == i) continue;
      final b = layoutRect(j);
      for (final x in [b.left, b.right]) {
        tryX(x - a.left);
        tryX(x - a.right);
      }
      for (final y in [b.top, b.bottom]) {
        tryY(y - a.top);
        tryY(y - a.bottom);
      }
    }
    return Offset(bestX ?? 0, bestY ?? 0);
  }

  static bool _overlaps(Rect a, Rect b) =>
      a.left < b.right - 0.5 &&
      b.left < a.right - 0.5 &&
      a.top < b.bottom - 0.5 &&
      b.top < a.bottom - 0.5;

  static bool _contains(Rect r, Offset p) =>
      p.dx >= r.left && p.dx < r.right && p.dy >= r.top && p.dy < r.bottom;

  static Offset _clampTo(Rect r, Offset p) => Offset(
      p.dx.clamp(r.left, max(r.left, r.right - 1)).toDouble(),
      p.dy.clamp(r.top, max(r.top, r.bottom - 1)).toDouble());

  int _nearest(Offset p, Rect Function(int) rectOf) {
    var best = 0;
    var bestDistance = double.infinity;
    for (var i = 0; i < length; i++) {
      final d = (_clampTo(rectOf(i), p) - p).distanceSquared;
      if (d < bestDistance) {
        bestDistance = d;
        best = i;
      }
    }
    return best;
  }

  /// Identifies the remote display setup a saved layout belongs to.
  String get signature => [
        for (final r in remote)
          '${r.left.round()},${r.top.round()},${r.width.round()}x${r.height.round()}'
      ].join(';');

  String encode() => jsonEncode({
        'displays': signature,
        'offsets': [
          for (final o in offsets) [o.dx.round(), o.dy.round()]
        ],
      });

  /// The layout saved with [encode], if it was made for the same displays.
  static MobileDisplayLayout restore(List<Rect> remote, String saved) {
    final layout = MobileDisplayLayout(remote);
    try {
      final m = jsonDecode(saved) as Map<String, dynamic>;
      final offsets = m['offsets'] as List<dynamic>;
      if (m['displays'] != layout.signature ||
          offsets.length != remote.length) {
        return layout;
      }
      return MobileDisplayLayout(remote, [
        for (final o in offsets)
          Offset((o[0] as num).toDouble(), (o[1] as num).toDouble())
      ]);
    } catch (_) {
      return layout;
    }
  }
}
