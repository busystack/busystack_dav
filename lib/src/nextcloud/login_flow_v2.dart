// Login Flow v2 mechanics adapted from BusyFiles (Apache-2.0).
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../dav_errors.dart';
import '../dav_provider_profile.dart';
import '../http/dav_http_transport.dart';

final class NextcloudLoginCredential {
  const NextcloudLoginCredential({
    required this.server,
    required this.loginName,
    required this.appPassword,
  });
  final Uri server;
  final String loginName, appPassword;
  @override
  String toString() => 'NextcloudLoginCredential([REDACTED])';
}

Uri normalizeNextcloudServer(String input) {
  final parsed = Uri.parse(input.trim());
  if (parsed.scheme != 'https' ||
      parsed.host.isEmpty ||
      parsed.userInfo.isNotEmpty ||
      parsed.hasQuery ||
      parsed.hasFragment)
    throw const FormatException('An HTTPS server URL is required');
  return parsed.replace(
    path: parsed.path.endsWith('/') ? parsed.path : parsed.path + '/',
  );
}

/// Browser UI, protected storage and account coordination are injected/app-owned.
final class NextcloudLoginFlowV2 {
  NextcloudLoginFlowV2({
    required Uri server,
    required this.launchBrowser,
    http.Client? client,
    this.pollInterval = const Duration(seconds: 1),
    this.maximumDuration = const Duration(minutes: 20),
    Future<void> Function(Duration)? delay,
    DateTime Function()? nowUtc,
  }) : server = normalizeNextcloudServer(server.toString()),
       _client = client ?? http.Client(),
       _ownsClient = client == null,
       _delay = delay ?? Future<void>.delayed,
       _now = nowUtc ?? (() => DateTime.now().toUtc());
  final Uri server;
  final Future<bool> Function(Uri) launchBrowser;
  final http.Client _client;
  final bool _ownsClient;
  final Duration pollInterval, maximumDuration;
  final Future<void> Function(Duration) _delay;
  final DateTime Function() _now;
  bool _active = false;
  Future<NextcloudLoginCredential> authenticate(
    DavCancellationToken cancellation,
  ) async {
    if (_active) throw StateError('Only one login attempt may be active');
    _active = true;
    try {
      cancellation.throwIfCancelled();
      final initial = await _send(
        server.resolve('index.php/login/v2'),
        {},
        cancellation,
      );
      if (initial.$1 != 200) throw _failure(initial.$1);
      final login = _trusted(initial.$2['login']);
      final poll = initial.$2['poll'];
      if (poll is! Map) throw const FormatException('Missing poll object');
      final endpoint = _trusted(poll['endpoint']);
      final token = poll['token'];
      if (token is! String || token.isEmpty || token.length > 16384)
        throw const FormatException('Invalid poll token');
      if (!await launchBrowser(login))
        throw const DavException(
          kind: DavErrorKind.protocol,
          code: 'NextcloudBrowserUnavailable',
          safeMessage: 'The system browser could not be opened.',
        );
      final deadline = _now().add(maximumDuration);
      while (_now().isBefore(deadline)) {
        cancellation.throwIfCancelled();
        final response = await _send(endpoint, {'token': token}, cancellation);
        if (response.$1 == 404) {
          await Future.any([
            _delay(pollInterval),
            cancellation.whenCancelled.then(
              (_) => cancellation.throwIfCancelled(),
            ),
          ]);
          continue;
        }
        if (response.$1 != 200) throw _failure(response.$1);
        final returnedServer = normalizeNextcloudServer(
          response.$2['server'] as String,
        );
        if (!sameDavOrigin(server, returnedServer) ||
            returnedServer.normalizePath().path != server.normalizePath().path)
          throw const FormatException('Untrusted returned server');
        final loginName = response.$2['loginName'],
            password = response.$2['appPassword'];
        if (loginName is! String ||
            password is! String ||
            loginName.isEmpty ||
            password.isEmpty ||
            loginName.length > 4096 ||
            password.length > 16384)
          throw const FormatException('Invalid credential handoff');
        cancellation.throwIfCancelled();
        return NextcloudLoginCredential(
          server: returnedServer,
          loginName: loginName,
          appPassword: password,
        );
      }
      throw const DavException(
        kind: DavErrorKind.timeout,
        code: 'NextcloudLoginExpired',
        safeMessage: 'The login attempt expired.',
      );
    } finally {
      _active = false;
    }
  }

  Uri _trusted(Object? input) {
    if (input is! String)
      throw const FormatException('Invalid login destination');
    final uri = Uri.parse(input);
    if (!sameDavOrigin(server, uri) ||
        uri.userInfo.isNotEmpty ||
        uri.fragment.isNotEmpty ||
        uri.scheme != 'https' ||
        !uri.normalizePath().path.startsWith(server.normalizePath().path)) {
      throw const FormatException('Untrusted login destination');
    }
    return uri;
  }

  Future<(int, Map<String, dynamic>)> _send(
    Uri uri,
    Map<String, String> fields,
    DavCancellationToken token,
  ) async {
    final abort = Completer<void>();
    final sub = token.cancellations.listen((_) {
      if (!abort.isCompleted) abort.complete();
    });
    final request =
        http.AbortableRequest('POST', uri, abortTrigger: abort.future)
          ..followRedirects = false
          ..headers['accept'] = 'application/json'
          ..bodyFields = fields;
    try {
      final response = await Future.any([
        _client.send(request).timeout(const Duration(seconds: 30)),
        token.whenCancelled.then<http.StreamedResponse>((_) {
          token.throwIfCancelled();
          throw StateError('unreachable');
        }),
      ]);
      if (response.statusCode >= 300 && response.statusCode < 400)
        throw _failure(response.statusCode);
      final bytes = BytesBuilder(copy: false);
      final iterator = StreamIterator(response.stream);
      try {
        while (await Future.any([
          iterator.moveNext().timeout(const Duration(seconds: 30)),
          abort.future.then<bool>((_) {
            token.throwIfCancelled();
            return false;
          }),
        ])) {
          token.throwIfCancelled();
          final chunk = iterator.current;
          if (bytes.length + chunk.length > 65536)
            throw const FormatException('Oversized login response');
          bytes.add(chunk);
        }
      } finally {
        await iterator.cancel();
      }
      if (response.statusCode == 404) return (404, <String, dynamic>{});
      final value = jsonDecode(utf8.decode(bytes.takeBytes()));
      if (value is! Map<String, dynamic>)
        throw const FormatException('Invalid login JSON');
      return (response.statusCode, value);
    } on http.RequestAbortedException {
      token.throwIfCancelled();
      rethrow;
    } finally {
      if (!abort.isCompleted) abort.complete();
      await sub.cancel();
    }
  }

  DavException _failure(int code) => DavException(
    kind: code >= 300 && code < 400
        ? DavErrorKind.redirectRejected
        : code == HttpStatus.unauthorized
        ? DavErrorKind.authentication
        : DavErrorKind.protocol,
    code: 'NextcloudLoginRejected',
    safeMessage: 'The Nextcloud login request was rejected.',
    statusCode: code,
  );
  void close() {
    if (_ownsClient) _client.close();
  }
}
