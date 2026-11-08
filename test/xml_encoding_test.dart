import 'dart:convert';
import 'dart:typed_data';

import 'package:busystack_dav/busystack_dav.dart';
import 'package:busystack_dav/src/xml/dav_xml_encoding.dart';
import 'package:test/test.dart';

void main() {
  for (final little in [false, true]) {
    List<int> encode(String text) => [
      if (little) ...[255, 254] else ...[254, 255],
      for (final unit in text.codeUnits)
        if (little) ...[unit & 255, unit >> 8] else ...[unit >> 8, unit & 255],
    ];
    test('endian-specific UTF-16 without BOM, little=$little', () async {
      const xml = ' <?xml version="1.0"?><root/>';
      final bytes = encode(xml).sublist(2);
      expect(const DavXmlDecoder().convert(bytes), xml);
      expect(
        await Stream.fromIterable(bytes.map((b) => [b]))
            .transform(const DavXmlDecoder())
            .join(),
        xml,
      );
      final document = const DavXmlParser().parseDocument(
        Uint8List.fromList(encode('<root/>').sublist(2)),
      );
      expect(document.rootElement.name.local, 'root');
    });
    test('all UTF-16 chunk boundaries, little=$little', () async {
      final bytes = encode('Café 😀 text');
      for (var split = 0; split <= bytes.length; split++) {
        final actual = await Stream.fromIterable([
          bytes.sublist(0, split),
          bytes.sublist(split),
        ]).transform(const DavXmlDecoder()).join();
        expect(actual, 'Café 😀 text');
      }
    });
    for (final text in ['\ud800', '\udc00', '\ud800x']) {
      test(
        'reject malformed UTF-16 surrogate ${text.codeUnits}, little=$little',
        () {
          expect(
            () => const DavXmlDecoder().convert(encode(text)),
            throwsFormatException,
          );
        },
      );
    }
    test('reject truncated UTF-16 code unit, little=$little', () {
      expect(
        () => const DavXmlDecoder().convert([...encode('ok'), 0]),
        throwsFormatException,
      );
    });
    test('UTF-16 retains DTD and byte limits, little=$little', () {
      final bytes = Uint8List.fromList(
        encode('<!DOCTYPE x [<!ENTITY e "x">]><x/>'),
      );
      expect(
        () => const DavXmlParser().parseDocument(bytes),
        throwsA(
          isA<DavException>().having(
            (e) => e.code,
            'code',
            'DavXmlDtdForbidden',
          ),
        ),
      );
      expect(
        () =>
            const DavXmlParser(limits: DavXmlLimits(maximumBytes: 4))
                .parseDocument(bytes),
        throwsA(
          isA<DavException>().having(
            (e) => e.code,
            'code',
            'DavXmlResponseTooLarge',
          ),
        ),
      );
    });
  }
  test('UTF-8 BOM and split multibyte characters remain supported', () async {
    final bytes = [239, 187, 191, ...utf8.encode('Café 😀')];
    expect(
      await Stream.fromIterable(bytes.map((b) => [b]))
          .transform(const DavXmlDecoder())
          .join(),
      'Café 😀',
    );
    expect(() => const DavXmlDecoder().convert([255]), throwsFormatException);
  });
}
