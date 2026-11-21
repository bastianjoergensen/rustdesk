import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_hbb/models/remote_qr.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zxing2/qrcode.dart';

/// A grey RGBA screen with some window-like boxes, and each code drawn at
/// (x, y) with [px] pixels per module, light on dark if inverted.
Uint8List screen(int width, int height,
    List<(String text, int x, int y, int px, bool inverted)> codes) {
  final rgba = Uint8List(width * height * 4);
  void fill(int x0, int y0, int w, int h, int v) {
    for (var y = max(0, y0); y < min(height, y0 + h); y++) {
      for (var x = max(0, x0); x < min(width, x0 + w); x++) {
        final p = (y * width + x) * 4;
        rgba[p] = rgba[p + 1] = rgba[p + 2] = v;
        rgba[p + 3] = 255;
      }
    }
  }

  fill(0, 0, width, height, 0x80);
  final rnd = Random(7);
  for (var i = 0; i < 40; i++) {
    fill(rnd.nextInt(width), rnd.nextInt(height), 20 + rnd.nextInt(300),
        10 + rnd.nextInt(200), rnd.nextInt(256));
  }
  for (final (text, x0, y0, px, inverted) in codes) {
    final m = Encoder.encode(text, ErrorCorrectionLevel.m).matrix!;
    for (var y = -4; y < m.height + 4; y++) {
      for (var x = -4; x < m.width + 4; x++) {
        final dark =
            x >= 0 && y >= 0 && x < m.width && y < m.height && m.get(x, y) == 1;
        fill(x0 + x * px, y0 + y * px, px, px, dark != inverted ? 0x12 : 0xee);
      }
    }
  }
  return rgba;
}

void main() {
  test('finds a QR code on a busy 1080p screen at a glance', () {
    const text = 'https://discord.com/ra/l2ZbWZ0Ch5g8sOaK2tOqL3FqFJ6Zr1mQ';
    final hits = findQrCodes(
        screen(1920, 1080, [(text, 1400, 600, 4, false)]), 1920, 1080);
    expect(hits.map((h) => h.text), [text]);
    final h = hits.single;
    expect(h.left <= 1400 && h.top <= 600, isTrue);
    expect(h.right >= 1400 + 33 * 4 && h.bottom >= 600 + 33 * 4, isTrue);
    expect(h.thumbnail, isNotNull);
  });

  test('a thorough look finds several codes, light on dark ones too', () {
    const a = 'tg://login?token=AQAAAABn3s9fVb2kq1dLx7cT0yQ';
    const b = 'WIFI:T:WPA;S:Home;P:hunter2;;';
    final hits = findQrCodes(
        screen(2560, 1440, [(a, 300, 300, 5, true), (b, 1800, 900, 6, false)]),
        2560,
        1440,
        thorough: true);
    expect(hits.map((h) => h.text).toSet(), {a, b});
    expect(hits.firstWhere((h) => h.text == a).inverted, isTrue);
  });

  test('tells what a code is for', () {
    final wifi = QrContent.parse(r'WIFI:S:My\;Net;T:WPA;P:"p@ss:word";;');
    expect(wifi.kind, QrKind.wifi);
    expect(wifi.wifiName, 'My;Net');
    expect(wifi.wifiPassword, 'p@ss:word');

    final otp = QrContent.parse(
        'otpauth://totp/ACME%20Co:jo@example.com?secret=JBSWY3DPEHPK3PXP&issuer=ACME%20Co');
    expect(otp.kind, QrKind.otp);
    expect(otp.otpIssuer, 'ACME Co');
    expect(otp.otpAccount, 'jo@example.com');
    expect(otp.otpSecret, 'JBSWY3DPEHPK3PXP');
    expect(otp.canOpen, isTrue);

    expect(QrContent.parse('FIDO:/1234567890123').kind, QrKind.passkey);
    expect(
        QrContent.parse('2@Ab+c/d=,Ef+g=,Hi/j=,Kl+m=').kind, QrKind.whatsapp);
    final link = QrContent.parse('https://www.example.com/a?b=c');
    expect((link.kind, link.label), (QrKind.link, 'example.com'));
    final app = QrContent.parse('tg://login?token=abc');
    expect((app.kind, app.label), (QrKind.app, 'tg://login'));
    final text = QrContent.parse('Hello there: general Kenobi');
    expect((text.kind, text.canOpen), (QrKind.text, false));
  });
}
