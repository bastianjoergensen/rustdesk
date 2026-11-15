import 'package:flutter_hbb/models/quick_share.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('a free name is kept', () {
    expect(uniqueFileName('photo.jpg', ['other.jpg']), 'photo.jpg');
  });

  test('a taken name gets the next free number before the extension', () {
    expect(uniqueFileName('photo.jpg', ['photo.jpg']), 'photo (2).jpg');
    expect(uniqueFileName('photo.jpg', ['photo.jpg', 'photo (2).jpg']),
        'photo (3).jpg');
  });

  test('names compare without case, as on Windows', () {
    expect(uniqueFileName('Report.PDF', ['report.pdf']), 'Report (2).PDF');
  });

  test('names without or with only a leading dot keep their shape', () {
    expect(uniqueFileName('Makefile', ['makefile']), 'Makefile (2)');
    expect(uniqueFileName('.env', ['.env']), '.env (2)');
    expect(uniqueFileName('a.tar.gz', ['a.tar.gz']), 'a.tar (2).gz');
  });
}
