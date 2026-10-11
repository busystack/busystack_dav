// Streaming transfer behavior extracted from BusyFiles (Apache-2.0).
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../dav_errors.dart';
import '../dav_provider_profile.dart';
import 'dav_http_transport.dart';

/// Caller may inspect status/headers and parse a bounded XML body incrementally.
/// Consume the body once, or close it explicitly to release the request.
final class DavStreamResponse {
  DavStreamResponse({
    required this.statusCode,
    required this.headers,
    required this.requestUri,
    required this.body,
    required Future<void> Function() close,
  }) : _close = close;
  final int statusCode;
  final Map<String, String> headers;
  final Uri requestUri;
  final Stream<List<int>> body;
  final Future<void> Function() _close;
  Future<void> close() => _close();
}

/// File-sized transfers have no contact/XML body ceiling and no retries.
/// The supplied client and credentials remain caller owned.
final class DavTransferClient {
  DavTransferClient({
    required this.client,
    required this.authority,
    this.profile = const DavProviderProfile(),
    this.headerTimeout = const Duration(seconds: 30),
    this.idleTimeout = const Duration(seconds: 60),
  });
  final http.Client client;
  final Uri authority;
  final DavProviderProfile profile;
  final Duration headerTimeout, idleTimeout;

  void _validate(Uri uri, Map<String, String> headers) {
    if (!profile.isTrustedCredentialDestination(
      uri,
      accountAuthority: authority,
    )) {
      throw const DavException(
        kind: DavErrorKind.redirectRejected,
        code: 'DavUntrustedTransfer',
        safeMessage: 'Untrusted transfer destination.',
      );
    }
    if (headers.keys.any(
      (name) => const {'authorization', 'host'}.contains(name.toLowerCase()),
    )) {
      throw ArgumentError('Transport-owned header');
    }
  }

  Stream<List<int>> download(
    Uri uri, {
    required DavBasicCredential credential,
    required DavCancellationToken cancellation,
    Map<String, String> headers = const {},
  }) async* {
    final response = await openRead(
      uri,
      credential: credential,
      cancellation: cancellation,
      headers: headers,
    );
    try {
      _checkStatus(response.statusCode, response.headers);
      yield* response.body;
    } finally {
      await response.close();
    }
  }

  Future<DavStreamResponse> openRead(
    Uri uri, {
    required DavBasicCredential credential,
    required DavCancellationToken cancellation,
    String method = 'GET',
    List<int>? bodyBytes,
    Map<String, String> headers = const {},
  }) async {
    if (!const {
      'GET',
      'HEAD',
      'OPTIONS',
      'PROPFIND',
      'REPORT',
      'SEARCH',
    }.contains(method)) {
      throw ArgumentError('Use upload for a streaming mutation');
    }
    if ((bodyBytes?.length ?? 0) > 1024 * 1024)
      throw RangeError('Read request body limit');
    _validate(uri, headers);
    cancellation.throwIfCancelled();
    final abort = Completer<void>();
    final sub = cancellation.cancellations.listen((_) {
      if (!abort.isCompleted) abort.complete();
    });
    final request =
        http.AbortableRequest(method, uri, abortTrigger: abort.future)
          ..followRedirects = false
          ..headers.addAll({
            ...headers,
            'authorization': credential.authorizationValue,
          });
    if (bodyBytes != null) request.bodyBytes = bodyBytes;
    var closed = false;
    Future<void> close() async {
      if (closed) return;
      closed = true;
      if (!abort.isCompleted) abort.complete();
      await sub.cancel();
    }

    try {
      final response = await _await(
        client.send(request).timeout(headerTimeout),
        abort.future,
      );
      Stream<List<int>> body() async* {
        try {
          await for (final chunk in _chunks(response.stream, abort.future)) {
            cancellation.throwIfCancelled();
            yield chunk;
          }
        } catch (error) {
          throw _transferFailure(error, mutation: false);
        } finally {
          await close();
        }
      }

      return DavStreamResponse(
        statusCode: response.statusCode,
        headers: response.headers,
        requestUri: uri,
        body: body(),
        close: close,
      );
    } catch (error) {
      await close();
      if (error is DavException) rethrow;
      throw _transferFailure(error, mutation: false);
    }
  }

  Future<DavResponse> upload(
    Uri uri, {
    required Stream<List<int>> source,
    required int length,
    required DavBasicCredential credential,
    required DavCancellationToken cancellation,
    String method = 'PUT',
    Map<String, String> headers = const {},
    int maximumResponseBytes = 1024 * 1024,
    bool mutationMayHaveCommitted = true,
  }) async {
    _validate(uri, headers);
    cancellation.throwIfCancelled();
    if (length < 0) throw RangeError.value(length);
    final abort = Completer<void>();
    final sub = cancellation.cancellations.listen((_) {
      if (!abort.isCompleted) abort.complete();
    });
    final request =
        http.AbortableStreamedRequest(method, uri, abortTrigger: abort.future)
          ..followRedirects = false
          ..contentLength = length
          ..headers.addAll({
            ...headers,
            'authorization': credential.authorizationValue,
          });
    var count = 0;
    final sending = _await(
      client.send(request).timeout(headerTimeout),
      abort.future,
    );
    final pumping = (() async {
      try {
        await request.sink.addStream(
          _chunks(source, abort.future).map((chunk) {
            cancellation.throwIfCancelled();
            count += chunk.length;
            if (count > length)
              throw const FormatException('Upload length mismatch');
            return chunk;
          }),
        );
        if (count != length)
          throw const FormatException('Upload length mismatch');
        await request.sink.close();
      } catch (_) {
        if (!abort.isCompleted) abort.complete();
        rethrow;
      }
    })();
    try {
      final results = await Future.wait<Object?>([
        sending,
        pumping,
      ], eagerError: true);
      final response = results.first as http.StreamedResponse;
      _checkResponse(response);
      final bytes = BytesBuilder(copy: false);
      await for (final chunk in _chunks(response.stream, abort.future)) {
        cancellation.throwIfCancelled();
        if (bytes.length + chunk.length > maximumResponseBytes)
          throw const FormatException('Oversized response');
        bytes.add(chunk);
      }
      return DavResponse(
        statusCode: response.statusCode,
        headers: response.headers,
        bodyBytes: bytes.takeBytes(),
        requestUri: uri,
        correlationId: 'transfer',
      );
    } catch (error) {
      if (error is DavException &&
          error.statusCode != null &&
          error.statusCode! < 500)
        rethrow;
      throw _transferFailure(error, mutation: mutationMayHaveCommitted);
    } finally {
      if (!abort.isCompleted) abort.complete();
      await sub.cancel();
    }
  }

  Future<T> _await<T>(Future<T> pending, Future<void> abort) => Future.any([
    pending,
    abort.then<T>((_) => throw http.RequestAbortedException()),
  ]);

  Stream<List<int>> _chunks(
    Stream<List<int>> source,
    Future<void> abort,
  ) async* {
    final iterator = StreamIterator(source);
    try {
      while (await _await(iterator.moveNext().timeout(idleTimeout), abort)) {
        yield iterator.current;
      }
    } finally {
      await iterator.cancel();
    }
  }

  void _checkResponse(http.StreamedResponse response) {
    _checkStatus(response.statusCode, response.headers);
  }

  void _checkStatus(int status, Map<String, String> headers) {
    if (status >= 200 && status < 300) return;
    throw DavException(
      kind: status >= 300 && status < 400
          ? DavErrorKind.redirectRejected
          : switch (status) {
              401 => DavErrorKind.authentication,
              403 => DavErrorKind.authorization,
              404 => DavErrorKind.notFound,
              409 => DavErrorKind.conflict,
              412 => DavErrorKind.preconditionFailed,
              429 => DavErrorKind.rateLimited,
              _ => DavErrorKind.server,
            },
      code: 'DavTransferRejected',
      safeMessage: 'DAV transfer was rejected.',
      statusCode: status,
      retryAfter: parseDavRetryAfter(headers['retry-after']),
    );
  }

  DavException _transferFailure(Object error, {required bool mutation}) =>
      DavException(
        kind: mutation
            ? DavErrorKind.unknownOutcome
            : error is HandshakeException || error is TlsException
            ? DavErrorKind.tls
            : error is TimeoutException
            ? DavErrorKind.timeout
            : error is http.RequestAbortedException
            ? DavErrorKind.cancelled
            : DavErrorKind.network,
        code: mutation ? 'DavUnknownTransferOutcome' : 'DavTransferFailed',
        safeMessage: mutation
            ? 'Reconcile the remote resource before retrying.'
            : 'DAV transfer failed.',
      );
}
