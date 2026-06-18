import 'dart:typed_data';

/// Binary HTTP message framing (RFC 9292).
///
/// Encodes HTTP requests/responses into a binary format suitable for
/// OHTTP encapsulation.
class BinaryHttp {
  /// Encode an HTTP request into Binary HTTP format (Known-Length Request).
  ///
  /// Format:
  ///   Framing Indicator (1 byte, 0x00 for known-length request)
  ///   Method Length (variable-length int) | Method
  ///   Scheme Length (variable-length int) | Scheme
  ///   Authority Length (variable-length int) | Authority
  ///   Path Length (variable-length int) | Path
  ///   Headers (length-prefixed block)
  ///   Content (length-prefixed block)
  static Uint8List encodeRequest({
    required String method,
    required Uri uri,
    Map<String, String> headers = const {},
    Uint8List? body,
  }) {
    final builder = BytesBuilder();

    // Framing indicator: 0x00 = Known-Length Request
    builder.addByte(0x00);

    // Method
    _writeVarLenString(builder, method);

    // Scheme
    _writeVarLenString(builder, uri.scheme);

    // Authority (host:port)
    final authority = uri.hasPort && uri.port != 443 && uri.port != 80
        ? '${uri.host}:${uri.port}'
        : uri.host;
    _writeVarLenString(builder, authority);

    // Path (including query)
    final path = uri.hasQuery ? '${uri.path}?${uri.query}' : uri.path;
    _writeVarLenString(builder, path.isEmpty ? '/' : path);

    // Headers as a length-prefixed block
    final headerBytes = _encodeHeaders(headers);
    _writeVarLenBytes(builder, headerBytes);

    // Content (body)
    _writeVarLenBytes(builder, body ?? Uint8List(0));

    // Known-Length Trailers (empty)
    _writeVarInt(builder, 0);

    return Uint8List.fromList(builder.toBytes());
  }

  /// Decode a Binary HTTP response (Known-Length Response).
  ///
  /// Returns status code, headers, and body.
  static BinaryHttpResponse decodeResponse(Uint8List data) {
    int offset = 0;

    // Framing indicator: should be 0x01 for known-length response
    // But some implementations use informational responses (1xx) first.
    // Skip any informational responses.
    while (offset < data.length) {
      final framing = data[offset];
      offset += 1;

      if (framing == 0x01) {
        // Known-Length Response — read status and fields
        final (statusCode, o1) = _readVarInt(data, offset);
        offset = o1;

        // Headers
        final (headerBytes, o2) = _readVarLenBytes(data, offset);
        offset = o2;
        final headers = _decodeHeaders(headerBytes);

        // Content
        final (body, o3) = _readVarLenBytes(data, offset);
        offset = o3;

        return BinaryHttpResponse(
          statusCode: statusCode,
          headers: headers,
          body: body,
        );
      } else if (framing == 0x00) {
        // This is a request, not a response
        throw const FormatException('Expected response, got request framing');
      } else {
        // Unknown framing, skip
        throw FormatException('Unknown framing indicator: $framing');
      }
    }

    throw const FormatException('Empty Binary HTTP response');
  }

  // =========================================================================
  // Private helpers
  // =========================================================================

  static void _writeVarLenString(BytesBuilder builder, String value) {
    final bytes = Uint8List.fromList(value.codeUnits);
    _writeVarInt(builder, bytes.length);
    builder.add(bytes);
  }

  static void _writeVarLenBytes(BytesBuilder builder, Uint8List bytes) {
    _writeVarInt(builder, bytes.length);
    builder.add(bytes);
  }

  /// Write a variable-length integer (QUIC encoding).
  static void _writeVarInt(BytesBuilder builder, int value) {
    if (value < 0x40) {
      builder.addByte(value);
    } else if (value < 0x4000) {
      builder.addByte(0x40 | (value >> 8));
      builder.addByte(value & 0xFF);
    } else if (value < 0x40000000) {
      builder.addByte(0x80 | (value >> 24));
      builder.addByte((value >> 16) & 0xFF);
      builder.addByte((value >> 8) & 0xFF);
      builder.addByte(value & 0xFF);
    } else {
      throw ArgumentError('Value too large for variable-length int: $value');
    }
  }

  /// Read a variable-length integer (QUIC encoding).
  static (int, int) _readVarInt(Uint8List data, int offset) {
    if (offset >= data.length) {
      throw const FormatException('Unexpected end of data reading varint');
    }
    final first = data[offset];
    final prefix = first >> 6;

    switch (prefix) {
      case 0: // 1 byte
        return (first, offset + 1);
      case 1: // 2 bytes
        if (offset + 2 > data.length) {
          throw const FormatException('Truncated 2-byte varint');
        }
        final value = ((first & 0x3F) << 8) | data[offset + 1];
        return (value, offset + 2);
      case 2: // 4 bytes
        if (offset + 4 > data.length) {
          throw const FormatException('Truncated 4-byte varint');
        }
        final value =
            ((first & 0x3F) << 24) |
            (data[offset + 1] << 16) |
            (data[offset + 2] << 8) |
            data[offset + 3];
        return (value, offset + 4);
      default: // 8 bytes - not supported for our use case
        throw const FormatException('8-byte varint not supported');
    }
  }

  static (Uint8List, int) _readVarLenBytes(Uint8List data, int offset) {
    final (length, newOffset) = _readVarInt(data, offset);
    if (newOffset + length > data.length) {
      throw FormatException(
        'Truncated field: expected $length bytes at offset $newOffset',
      );
    }
    return (
      Uint8List.fromList(data.sublist(newOffset, newOffset + length)),
      newOffset + length,
    );
  }

  static Uint8List _encodeHeaders(Map<String, String> headers) {
    final builder = BytesBuilder();
    for (final entry in headers.entries) {
      final name = entry.key.toLowerCase().codeUnits;
      final value = entry.value.codeUnits;
      _writeVarInt(builder, name.length);
      builder.add(name);
      _writeVarInt(builder, value.length);
      builder.add(value);
    }
    return Uint8List.fromList(builder.toBytes());
  }

  static Map<String, String> _decodeHeaders(Uint8List data) {
    final headers = <String, String>{};
    int offset = 0;
    while (offset < data.length) {
      final (nameBytes, o1) = _readVarLenBytes(data, offset);
      offset = o1;
      final (valueBytes, o2) = _readVarLenBytes(data, offset);
      offset = o2;
      headers[String.fromCharCodes(nameBytes)] = String.fromCharCodes(
        valueBytes,
      );
    }
    return headers;
  }
}

/// Decoded Binary HTTP response.
class BinaryHttpResponse {
  final int statusCode;
  final Map<String, String> headers;
  final Uint8List body;

  BinaryHttpResponse({
    required this.statusCode,
    required this.headers,
    required this.body,
  });
}
