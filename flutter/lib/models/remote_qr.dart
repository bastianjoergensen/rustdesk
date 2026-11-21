import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;
import 'package:zxing2/qrcode.dart';

/// A QR code found on the remote screen.
class QrHit {
  const QrHit(this.text, this.left, this.top, this.right, this.bottom,
      {this.inverted = false, this.thumbnail});

  final String text;

  /// Where the code is, in pixels of the frame it was found in.
  final int left, top, right, bottom;

  /// Light modules on a dark background.
  final bool inverted;

  /// The code as the screen shows it, as PNG.
  final Uint8List? thumbnail;
}

/// Finds up to [maxCodes] QR codes in an RGBA frame. [thorough] takes several
/// times longer: it looks harder, and then at overlapping parts of the frame
/// on their own, which finds codes the whole frame hides among lookalikes.
List<QrHit> findQrCodes(Uint8List rgba, int width, int height,
    {bool thorough = false, int maxCodes = 4}) {
  if (width < 21 || height < 21 || rgba.length < width * height * 4) {
    return const [];
  }
  // The quick look halves frames above 1080p; a QR code on a screen that big
  // still has several pixels per module.
  final f = !thorough && width * height > 1920 * 1088 ? 2 : 1;
  final w = width ~/ f, h = height ~/ f;
  final lum = _luminance(rgba, width, height, f);
  final hints = DecodeHints();
  if (thorough) hints.put(DecodeHintType.tryHarder);
  final found = <_Found>[];
  void add(_Found hit) {
    if (!found.any((e) => e.text == hit.text)) found.add(hit);
  }

  for (final inverted in const [false, true]) {
    final bitmap =
        BinaryBitmap(HybridBinarizer(_source(lum, w, 0, 0, w, h, inverted)));
    for (var i = 0; i < maxCodes; i++) {
      final hit = _decode(bitmap, hints, 0, 0, inverted);
      if (hit == null) break;
      // Blank it out, so the next try finds the next code.
      final m = bitmap.getBlackMatrix();
      final x0 = math.max(0, hit.left.floor()),
          x1 = math.min(w, hit.right.ceil());
      final y0 = math.max(0, hit.top.floor()),
          y1 = math.min(h, hit.bottom.ceil());
      for (var y = y0; y < y1; y++) {
        for (var x = x0; x < x1; x++) {
          m.unset(x, y);
        }
      }
      add(hit);
    }
  }
  if (found.isEmpty && thorough) {
    final tw = w ~/ 2, th = h ~/ 2;
    for (var ty = 0; ty < 3; ty++) {
      for (var tx = 0; tx < 3; tx++) {
        final left = tx * w ~/ 4, top = ty * h ~/ 4;
        for (final inverted in const [false, true]) {
          final hit = _decode(
              BinaryBitmap(HybridBinarizer(
                  _source(lum, w, left, top, tw, th, inverted))),
              hints,
              left,
              top,
              inverted);
          if (hit != null) {
            add(hit);
            break;
          }
        }
      }
    }
  }
  return [for (final e in found) e.toHit(rgba, width, height, f)];
}

/// Looks for QR codes in [image] away from the UI thread. [image] stays the
/// caller's: a clone is read, so a newer frame may dispose it meanwhile.
Future<List<QrHit>> scanImage(ui.Image image, {bool thorough = false}) async {
  final copy = image.clone();
  final width = copy.width, height = copy.height;
  ByteData? data;
  try {
    data = await copy.toByteData(format: ui.ImageByteFormat.rawRgba);
  } finally {
    copy.dispose();
  }
  if (data == null) return const [];
  return compute(
      _scanJob,
      _ScanJob(data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
          width, height, thorough));
}

/// Looks for QR codes in a PNG, as thoroughly as it can.
Future<List<QrHit>> scanPng(Uint8List png) => compute(_scanPngJob, png);

class _ScanJob {
  const _ScanJob(this.rgba, this.width, this.height, this.thorough);
  final Uint8List rgba;
  final int width, height;
  final bool thorough;
}

List<QrHit> _scanJob(_ScanJob job) =>
    findQrCodes(job.rgba, job.width, job.height, thorough: job.thorough);

List<QrHit> _scanPngJob(Uint8List png) {
  final image = img.decodePng(png);
  if (image == null) return const [];
  return findQrCodes(
      image.getBytes(order: img.ChannelOrder.rgba), image.width, image.height,
      thorough: true);
}

class _Found {
  _Found(this.text, this.left, this.top, this.right, this.bottom, this.module,
      this.inverted);

  final String text;
  // The code up to the outer edge of its finder patterns, in the frame that
  // was scanned, which may be halved.
  final double left, top, right, bottom, module;
  final bool inverted;

  QrHit toHit(Uint8List rgba, int width, int height, int f) {
    // Two modules of the quiet zone around it.
    final q = module * 2;
    final l = ((left - q) * f).floor().clamp(0, width - 1).toInt();
    final t = ((top - q) * f).floor().clamp(0, height - 1).toInt();
    final r = ((right + q) * f).ceil().clamp(l + 1, width).toInt();
    final b = ((bottom + q) * f).ceil().clamp(t + 1, height).toInt();
    return QrHit(text, l, t, r, b,
        inverted: inverted, thumbnail: _thumbnail(rgba, width, l, t, r, b));
  }
}

_Found? _decode(
    BinaryBitmap bitmap, DecodeHints hints, int left, int top, bool inverted) {
  try {
    final r = QRCodeReader().decode(bitmap, hints: hints);
    final p = r.resultPoints;
    if (r.text.isEmpty || p.length < 3) return null;
    // Finder pattern centres: one corner and its two neighbours. The fourth
    // corner completes the square.
    final a = p[0], c = p[1], d = p[2];
    final xs = [a.x, c.x, d.x, a.x + d.x - c.x];
    final ys = [a.y, c.y, d.y, a.y + d.y - c.y];
    final side = (_dist(a.x, a.y, c.x, c.y) + _dist(d.x, d.y, c.x, c.y)) / 2;
    // Centre to centre is the side less 7 modules.
    final module = side / (17 + 4 * (r.version ?? 1) - 7);
    // The centre is 3.5 modules in from the edge.
    final e = module * 4;
    return _Found(
        r.text,
        left + xs.reduce(math.min) - e,
        top + ys.reduce(math.min) - e,
        left + xs.reduce(math.max) + e,
        top + ys.reduce(math.max) + e,
        module,
        inverted);
  } catch (_) {
    return null;
  }
}

double _dist(double x0, double y0, double x1, double y1) =>
    math.sqrt((x1 - x0) * (x1 - x0) + (y1 - y0) * (y1 - y0));

LuminanceSource _source(Int8List lum, int dataWidth, int left, int top,
    int width, int height, bool inverted) {
  final s = _Luminance(lum, dataWidth, left, top, width, height);
  return inverted ? s.invert() : s;
}

Int8List _luminance(Uint8List rgba, int width, int height, int f) {
  final w = width ~/ f, h = height ~/ f;
  final out = Int8List(w * h);
  if (f == 1) {
    for (var i = 0, p = 0; i < out.length; i++, p += 4) {
      out[i] = (rgba[p] * 77 + rgba[p + 1] * 150 + rgba[p + 2] * 29) >> 8;
    }
    return out;
  }
  final stride = width * 4;
  for (var y = 0; y < h; y++) {
    final row = 2 * y * stride;
    for (var x = 0; x < w; x++) {
      var p = row + 8 * x;
      var s = 0;
      for (var k = 0; k < 2; k++, p += stride) {
        s += rgba[p] * 77 + rgba[p + 1] * 150 + rgba[p + 2] * 29;
        s += rgba[p + 4] * 77 + rgba[p + 5] * 150 + rgba[p + 6] * 29;
      }
      out[y * w + x] = s >> 10;
    }
  }
  return out;
}

class _Luminance extends LuminanceSource {
  _Luminance(
      this._data, this._dataWidth, this._left, this._top, int width, int height)
      : super(width, height);

  final Int8List _data;
  final int _dataWidth, _left, _top;

  @override
  Int8List getRow(int y, Int8List? row) {
    if (row == null || row.length < width) row = Int8List(width);
    final o = (y + _top) * _dataWidth + _left;
    row.setRange(0, width, _data, o);
    return row;
  }

  @override
  Int8List getMatrix() {
    if (_left == 0 && _top == 0 && width == _dataWidth) return _data;
    final out = Int8List(width * height);
    for (var y = 0; y < height; y++) {
      out.setRange(
          y * width, (y + 1) * width, _data, (y + _top) * _dataWidth + _left);
    }
    return out;
  }
}

Uint8List? _thumbnail(Uint8List rgba, int width, int l, int t, int r, int b) {
  final cw = r - l, ch = b - t;
  if (cw < 8 || ch < 8) return null;
  final crop = Uint8List(cw * ch * 4);
  for (var y = 0; y < ch; y++) {
    crop.setRange(
        y * cw * 4, (y + 1) * cw * 4, rgba, ((t + y) * width + l) * 4);
  }
  var image = img.Image.fromBytes(
      width: cw, height: ch, bytes: crop.buffer, numChannels: 4);
  const maxSide = 240;
  final side = math.max(cw, ch);
  if (side > maxSide) {
    image = img.copyResize(image,
        width: math.max(1, cw * maxSide ~/ side),
        height: math.max(1, ch * maxSide ~/ side),
        interpolation: img.Interpolation.average);
  }
  return img.encodePng(image, level: 1);
}

enum QrKind {
  link,
  app,
  wifi,
  otp,
  passkey,
  whatsapp,
  email,
  phone,
  sms,
  location,
  text
}

/// What a QR code holds, as far as the phone can act on it.
class QrContent {
  QrContent._(this.text, this.kind,
      {String? label,
      this.wifiName,
      this.wifiPassword,
      this.otpIssuer,
      this.otpAccount,
      this.otpSecret})
      : label = label == null || label.isEmpty ? _short(text) : label;

  final String text;
  final QrKind kind;

  /// A few words for where there is no room for [text].
  final String label;

  final String? wifiName, wifiPassword;
  final String? otpIssuer, otpAccount, otpSecret;

  /// Android has something to hand it to, like the camera app would.
  bool get canOpen => const {
        QrKind.link,
        QrKind.app,
        QrKind.otp,
        QrKind.passkey,
        QrKind.email,
        QrKind.phone,
        QrKind.sms,
        QrKind.location,
      }.contains(kind);

  static final _scheme = RegExp(r'^([a-zA-Z][a-zA-Z0-9+.\-]+):\S+$');
  static final _whatsApp = RegExp(r'^\d+@[^,\s]+(,[^,\s]+){3,}$');

  static QrContent parse(String raw) {
    final t = raw.trim();
    final u = t.toUpperCase();
    if (u.startsWith('WIFI:')) {
      final f = _fields(t.substring(5));
      return QrContent._(t, QrKind.wifi,
          label: f['S'], wifiName: f['S'], wifiPassword: f['P']);
    }
    if (u.startsWith('FIDO:/')) {
      return QrContent._(t, QrKind.passkey, label: 'Passkey');
    }
    if (u.startsWith('OTPAUTH://') || u.startsWith('OTPAUTH-MIGRATION://')) {
      final uri = Uri.tryParse(t);
      var name = '';
      try {
        name = Uri.decodeComponent(uri?.path ?? '');
      } catch (_) {}
      if (name.startsWith('/')) name = name.substring(1);
      final i = name.indexOf(':');
      final issuer = uri?.queryParameters['issuer'] ??
          (i > 0 ? name.substring(0, i).trim() : null);
      final account = (i >= 0 ? name.substring(i + 1) : name).trim();
      return QrContent._(t, QrKind.otp,
          label: issuer ?? account,
          otpIssuer: issuer,
          otpAccount: account.isEmpty ? null : account,
          otpSecret: uri?.queryParameters['secret']);
    }
    if (_whatsApp.hasMatch(t)) {
      return QrContent._(t, QrKind.whatsapp, label: 'WhatsApp');
    }
    final scheme = _scheme.firstMatch(t)?.group(1)?.toLowerCase();
    if (scheme != null) {
      final uri = Uri.tryParse(t);
      final rest = t.substring(scheme.length + 1);
      switch (scheme) {
        case 'http':
        case 'https':
          var host = uri?.host ?? '';
          if (host.startsWith('www.')) host = host.substring(4);
          return QrContent._(t, QrKind.link, label: host);
        case 'mailto':
          return QrContent._(t, QrKind.email, label: rest.split('?').first);
        case 'tel':
          return QrContent._(t, QrKind.phone, label: rest);
        case 'sms':
        case 'smsto':
        case 'mms':
        case 'mmsto':
          return QrContent._(t, QrKind.sms, label: rest.split(':').first);
        case 'geo':
          return QrContent._(t, QrKind.location, label: rest.split('?').first);
        default:
          final host = uri?.host ?? '';
          return QrContent._(t, QrKind.app,
              label: host.isEmpty ? null : '${uri!.scheme}://$host');
      }
    }
    return QrContent._(t, QrKind.text);
  }

  // The `K:value;` fields of a Wi-Fi code, with `\` escapes.
  static Map<String, String> _fields(String body) {
    final out = <String, String>{};
    final buf = StringBuffer();
    String? key;
    void end() {
      if (key != null) {
        var v = buf.toString();
        if (v.length > 1 && v.startsWith('"') && v.endsWith('"')) {
          v = v.substring(1, v.length - 1);
        }
        out.putIfAbsent(key!, () => v);
      }
      key = null;
      buf.clear();
    }

    for (var i = 0; i < body.length; i++) {
      final c = body[i];
      if (c == '\\' && i + 1 < body.length) {
        buf.write(body[++i]);
      } else if (key == null && c == ':') {
        key = buf.toString().trim().toUpperCase();
        buf.clear();
      } else if (c == ';') {
        end();
      } else {
        buf.write(c);
      }
    }
    end();
    return out;
  }

  static String _short(String s) {
    final one = s.replaceAll(RegExp(r'\s+'), ' ').trim();
    return one.length <= 28 ? one : '${one.substring(0, 27)}…';
  }
}

bool sameQrTexts(List<QrHit> a, List<QrHit> b) =>
    a.length == b.length &&
    Iterable.generate(a.length).every((i) => a[i].text == b[i].text);
