import 'dart:convert';

/// XML's UTF-8 and UTF-16 encodings, without accepting
/// malformed byte sequences. Chunk boundaries may split BOMs or surrogate pairs.
final class DavXmlDecoder extends Converter<List<int>, String> {
  const DavXmlDecoder();

  @override
  String convert(List<int> input) {
    var result = '';
    final sink = startChunkedConversion(
      StringConversionSink.withCallback((s) => result = s),
    );
    sink.add(input);
    sink.close();
    return result;
  }

  @override
  ByteConversionSink startChunkedConversion(Sink<String> sink) =>
      _XmlByteSink(sink);
}

final class _XmlByteSink extends ByteConversionSinkBase {
  _XmlByteSink(this.output);
  final Sink<String> output;
  final prefix = <int>[];
  ByteConversionSink? utf8Sink;
  bool? littleEndian;
  int? pendingByte;
  int? highSurrogate;

  @override
  void add(List<int> chunk) {
    var offset = 0;
    if (littleEndian == null && utf8Sink == null) {
      while (prefix.length < 2 && offset < chunk.length) {
        prefix.add(chunk[offset++]);
      }
      if (prefix.length < 2) return;
      if (prefix[0] == 0xff && prefix[1] == 0xfe) {
        littleEndian = true;
      } else if (prefix[0] == 0xfe && prefix[1] == 0xff) {
        littleEndian = false;
      } else if (prefix[0] == 0 && prefix[1] != 0) {
        // UTF-16BE can omit the BOM when labelled as such (RFC 7303).
        // XML starts with ASCII markup or whitespace, so the NUL identifies
        // the byte order. NUL cannot occur in valid UTF-8 XML.
        littleEndian = false;
        output.add(String.fromCharCode(prefix[1]));
      } else if (prefix[1] == 0 && prefix[0] != 0) {
        littleEndian = true;
        output.add(String.fromCharCode(prefix[0]));
      } else {
        utf8Sink = const Utf8Decoder().startChunkedConversion(output);
        utf8Sink!.add(prefix);
      }
      prefix.clear();
    }
    if (utf8Sink case final sink?) {
      sink.add(chunk.sublist(offset));
      return;
    }
    final text = StringBuffer();
    for (; offset < chunk.length; offset++) {
      final byte = chunk[offset];
      if (pendingByte == null) {
        pendingByte = byte;
        continue;
      }
      final unit = littleEndian!
          ? pendingByte! | byte << 8
          : pendingByte! << 8 | byte;
      pendingByte = null;
      if (highSurrogate case final high?) {
        if (unit < 0xdc00 || unit > 0xdfff)
          throw const FormatException('Unpaired UTF-16 surrogate');
        text.writeCharCode(0x10000 + ((high - 0xd800) << 10) + unit - 0xdc00);
        highSurrogate = null;
      } else if (unit >= 0xd800 && unit <= 0xdbff) {
        highSurrogate = unit;
      } else if (unit >= 0xdc00 && unit <= 0xdfff) {
        throw const FormatException('Unpaired UTF-16 surrogate');
      } else {
        text.writeCharCode(unit);
      }
    }
    if (text.isNotEmpty) output.add(text.toString());
  }

  @override
  void close() {
    if (littleEndian == null && utf8Sink == null) {
      utf8Sink = const Utf8Decoder().startChunkedConversion(output);
      utf8Sink!.add(prefix);
    }
    if (utf8Sink case final sink?) {
      sink.close();
    } else {
      if (pendingByte != null || highSurrogate != null)
        throw const FormatException('Truncated UTF-16');
      output.close();
    }
  }
}
