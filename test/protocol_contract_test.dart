import 'dart:async';
import 'dart:convert';

import 'package:busystack_dav/carddav.dart';
import 'package:busystack_dav/caldav.dart';
import 'package:busystack_dav/nextcloud.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

final authority = Uri.parse('https://dav.example.test/');
final credential = DavBasicCredential(
  username: ' user ',
  password: ' password ',
);
String multi(String content) =>
    '<d:multistatus xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:carddav" '
        'xmlns:k="urn:ietf:params:xml:ns:caldav">' +
    content +
    '</d:multistatus>';
String entry(String href, String properties) =>
    '<d:response><d:href>' +
    davText(href) +
    '</d:href><d:propstat><d:prop>' +
    properties +
    '</d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>';
http.Response xml(String content) => http.Response(
  multi(content),
  207,
  headers: {'content-type': 'application/xml; charset=utf-8'},
);
DavResourceClient resources(
  http.Client client, {
  DavTransportLimits limits = const DavTransportLimits(),
}) => DavResourceClient(
  transport: DavHttpTransport(
    client: client,
    profile: const DavProviderProfile(),
    accountAuthority: authority,
    limits: limits,
  ),
  credentialProvider: () async => credential,
  authority: authority,
  accountId: 'a',
);
void main() {
  test(
    'cancellation fences a pending authorization callback before dispatch',
    () async {
      final client = MockClient(
        (_) async => throw StateError('Must not dispatch'),
      );
      final base = resources(client);
      for (final streaming in [false, true]) {
        final pending = Completer<DavBasicCredential>();
        final token = DavCancellationToken();
        final api = DavResourceClient(
          transport: base.transport,
          credentialProvider: () => pending.future,
          authority: authority,
          accountId: 'fixture',
          streaming: streaming
              ? DavTransferClient(client: client, authority: authority)
              : null,
        );
        final result = api.enumerateEtags(
          authority.resolve('/books/'),
          cancellation: token,
        );
        final assertion = expectLater(
          result,
          throwsA(
            isA<DavException>().having(
              (error) => error.kind,
              'kind',
              DavErrorKind.cancelled,
            ),
          ),
        );
        token.cancel();
        await assertion.timeout(const Duration(seconds: 1));
        pending.complete(credential);
      }
    },
  );
  test('production streaming enumeration exceeds small-resource limits and decodes 20001 complete entries', () async {
    final client = MockClient(
      (request) async => xml(
        [
          for (var index = 0; index < 20001; index++)
            entry(
              '/books/' + index.toString() + '.vcf',
              '<d:getetag>"revision"</d:getetag>',
            ),
        ].join(),
      ),
    );
    final base = resources(
      client,
      limits: const DavTransportLimits(maximumResponseBytes: 128),
    );
    final streamed = DavResourceClient(
      transport: base.transport,
      credentialProvider: () async => credential,
      authority: authority,
      accountId: 'fixture',
      streaming: DavTransferClient(client: client, authority: authority),
    );
    final inventory = await streamed.enumerateEtags(
      authority.resolve('/books/'),
    );
    expect(inventory, hasLength(20001));
    expect(inventory.keys.last.path, '/books/20000.vcf');
  });
  test('streamed report retains expired-token conditions and HTTP authentication errors', () async {
    var status = 403;
    final client = MockClient(
      (_) async => http.Response(
        status == 403
            ? '<d:error xmlns:d="DAV:"><d:valid-sync-token/></d:error>'
            : 'Authentication required',
        status,
      ),
    );
    final base = resources(client);
    final streamed = DavResourceClient(
      transport: base.transport,
      credentialProvider: () async => credential,
      authority: authority,
      accountId: 'fixture',
      streaming: DavTransferClient(client: client, authority: authority),
    );
    await expectLater(
      streamed.syncCollection(authority.resolve('/books/'), 'expired'),
      throwsA(
        isA<DavException>().having(
          (e) => e.kind,
          'kind',
          DavErrorKind.invalidSyncToken,
        ),
      ),
    );
    status = 401;
    await expectLater(
      streamed.syncCollection(authority.resolve('/books/'), 'token'),
      throwsA(
        isA<DavException>().having(
          (e) => e.kind,
          'kind',
          DavErrorKind.authentication,
        ),
      ),
    );
  });
  test('donor-derived MKCALENDAR stays distinct, escapes titles and never replays ambiguous creation', () async {
    var calls = 0, status = 201;
    final client = MockClient((request) async {
      calls++;
      expect(request.method, 'MKCALENDAR');
      expect(request.body, contains('<c:mkcalendar'));
      expect(request.body, contains('Work &amp; home'));
      expect(request.body, contains('name="VEVENT"'));
      return http.Response('', status);
    });
    final calendar = CalDavClient(resources(client));
    await calendar.createCalendar(
      authority.resolve('/calendars/'),
      authority.resolve('/calendars/new/'),
      displayName: 'Work & home',
    );
    status = 503;
    await expectLater(
      calendar.createCalendar(
        authority.resolve('/calendars/'),
        authority.resolve('/calendars/new2/'),
        displayName: 'Work & home',
      ),
      throwsA(
        isA<DavException>().having(
          (e) => e.kind,
          'kind',
          DavErrorKind.unknownOutcome,
        ),
      ),
    );
    expect(calls, 2);
  });
  for (final card in [true, false]) {
    test('${card ? "CardDAV" : "CalDAV"} discovery uses distinct namespace, homes and collection types', () async {
      final namespace = card ? 'c' : 'k',
          home = card ? 'addressbook-home-set' : 'calendar-home-set',
          type = card ? 'addressbook' : 'calendar';
      final calls = <http.Request>[];
      final client = MockClient((request) async {
        calls.add(request);
        if (request.method == 'OPTIONS')
          return http.Response(
            '',
            200,
            headers: {
              'allow': 'GET, PROPFIND, REPORT',
              'dav': '1, 3, extended-mkcol',
            },
          );
        if (request.url.path.startsWith('/.well-known'))
          return xml(
            entry(
              request.url.path,
              '<d:current-user-principal><d:href>/principals/u/</d:href></d:current-user-principal>',
            ),
          );
        if (request.url.path == '/principals/u/') {
          expect(request.body, contains(home));
          expect(
            request.body,
            isNot(
              contains(card ? 'calendar-home-set' : 'addressbook-home-set'),
            ),
          );
          return xml(
            entry(
              '/principals/u/',
              '<' +
                  namespace +
                  ':' +
                  home +
                  '><d:href>/homes/u/</d:href></' +
                  namespace +
                  ':' +
                  home +
                  '>',
            ),
          );
        }
        expect(request.headers['depth'], '1');
        return xml(
          entry(
                '/homes/u/',
                '<d:resourcetype><d:collection/></d:resourcetype>',
              ) +
              entry(
                '/homes/u/one/',
                '<d:displayname>One</d:displayname><d:resourcetype><d:collection/><' +
                    namespace +
                    ':' +
                    type +
                    '/></d:resourcetype><d:current-user-privilege-set><d:privilege><d:read/></d:privilege><d:privilege><d:write/></d:privilege></d:current-user-privilege-set>' +
                    '<d:supported-report-set><d:supported-report><d:report><d:sync-collection/></d:report></d:supported-report></d:supported-report-set>',
              ) +
              entry(
                '/homes/u/read-only/',
                '<d:resourcetype><d:collection/><' +
                    namespace +
                    ':' +
                    type +
                    '/></d:resourcetype>' +
                    '<d:current-user-privilege-set><d:privilege><d:read/></d:privilege></d:current-user-privilege-set>',
              ),
        );
      });
      final r = resources(client);
      final discovery = card
          ? await CardDavClient(r).discover()
          : await CalDavClient(r).discover();
      expect(discovery.principal.path, '/principals/u/');
      expect(discovery.collections, hasLength(2));
      expect(discovery.collections.first.canCreate, isTrue);
      expect(discovery.collections.last.canUpdate, isFalse);
      expect(discovery.collections.first.supportsSync, isTrue);
      expect(
        calls.every(
          (r) =>
              !r.followRedirects &&
              r.headers['authorization'] == credential.authorizationValue,
        ),
        isTrue,
      );
    });
  }
  test(
    'CardDAV v3 baseline, advertised v4 and selected-property completeness',
    () async {
      final book = Uri.parse('https://dav.example.test/book/');
      late String body;
      final client = CardDavClient(
        resources(
          MockClient((request) async {
            body = request.body;
            return xml(
              entry(
                '/book/a%2Fb.vcf',
                '<d:getetag>"one"</d:getetag><c:address-data>' +
                    davText(
                      'BEGIN:VCARD\r\nVERSION:3.0\r\nFN:Zoë\r\nN:;Zoë;;;\r\nEND:VCARD\r\n',
                    ) +
                    '</c:address-data>',
              ),
            );
          }),
        ),
      );
      final partial = await client.query(
        book,
        text: '李<&',
        selectedProperties: ['FN', 'EMAIL'],
      );
      expect(body, contains('addressbook-query'));
      expect(body, contains('李&lt;&amp;'));
      expect(body, contains('version="3.0"'));
      expect(partial.single.complete, isFalse);
      expect(partial.single.uri.path, '/book/a%2Fb.vcf');
      final full = await client.multiget(book, [
        partial.single.uri,
      ], version: '4.0');
      expect(body, contains('addressbook-multiget'));
      expect(body, contains('version="4.0"'));
      expect(full.single.complete, isTrue);
      await expectLater(
        client.multiget(book, [Uri.parse('https://evil.test/a.vcf')]),
        throwsA(isA<DavException>()),
      );
    },
  );
  test('CalDAV query, component/time ranges and multiget preserve iCalendar resource', () async {
    late String body;
    final collection = Uri.parse('https://dav.example.test/cal/');
    final client = CalDavClient(
      resources(
        MockClient((request) async {
          body = request.body;
          return xml(
            entry(
              '/cal/a.ics',
              '<d:getetag>"one"</d:getetag><k:calendar-data>BEGIN:VCALENDAR\nEND:VCALENDAR</k:calendar-data>',
            ),
          );
        }),
      ),
    );
    final items = await client.query(
      collection,
      component: 'VTODO',
      start: DateTime.utc(2026, 1, 1),
      end: DateTime.utc(2027, 1, 1),
    );
    expect(body, contains('calendar-query'));
    expect(body, contains('name="VTODO"'));
    expect(body, contains('20260101T000000Z'));
    expect(items.single.data, contains('VCALENDAR'));
    await client.multiget(collection, items.map((v) => v.uri));
    expect(body, contains('calendar-multiget'));
    await expectLater(
      client.query(collection, component: 'VCARD'),
      throwsArgumentError,
    );
  });
  test('generic RFC6578 records tombstones, escaped tokens and truncation separately', () async {
    final r = resources(
      MockClient((request) async {
        expect(
          request.body,
          contains('<d:sync-token>old&lt;&amp;</d:sync-token>'),
        );
        return xml(
          entry('/book/a.vcf', '<d:getetag>"two"</d:getetag>') +
              '<d:response><d:href>/book/gone.vcf</d:href><d:status>HTTP/1.1 404 Not Found</d:status></d:response>' +
              '<d:response><d:href>/book/</d:href><d:status>HTTP/1.1 507 Insufficient Storage</d:status></d:response><d:sync-token>next-opaque</d:sync-token>',
        );
      }),
    );
    final result = await r.syncCollection(
      Uri.parse('https://dav.example.test/book/'),
      'old<&',
    );
    expect(result.changed.values, ['"two"']);
    expect(result.deleted.single.path, '/book/gone.vcf');
    expect(result.syncToken, 'next-opaque');
    expect(result.truncated, isTrue);
  });
  test('expired optional sync token is distinct from denied access', () async {
    final r = resources(
      MockClient(
        (_) async => http.Response(
          '<d:error xmlns:d="DAV:"><d:valid-sync-token/></d:error>',
          403,
        ),
      ),
    );
    await expectLater(
      r.syncCollection(Uri.parse('https://dav.example.test/book/'), 'expired'),
      throwsA(
        isA<DavException>().having(
          (e) => e.kind,
          'kind',
          DavErrorKind.invalidSyncToken,
        ),
      ),
    );
  });
  test('conditional replacement obtains normalized full data and never retries failed confirmation', () async {
    var puts = 0;
    final r = resources(
      MockClient((request) async {
        if (request.method == 'PUT') {
          puts++;
          expect(request.headers['if-match'], '"base"');
          expect(request.body, 'complete resource');
          return http.Response('', 204);
        }
        return http.Response(
          'normalized resource',
          200,
          headers: {'etag': '"new"'},
        );
      }),
    );
    final item = await r.put(
      authority.resolve('/book/a.vcf'),
      'complete resource',
      contentType: 'text/vcard',
      etag: '"base"',
    );
    expect(puts, 1);
    expect(item.data, 'normalized resource');
    expect(item.etag, '"new"');
  });
  test(
    'conditional conflicts retain the resource and do not emit a second PUT',
    () async {
      var requests = 0;
      final r = resources(
        MockClient((request) async {
          requests++;
          return http.Response('', 412);
        }),
      );
      await expectLater(
        r.put(
          authority.resolve('/book/a.vcf'),
          'complete',
          contentType: 'text/vcard',
          etag: '"old"',
        ),
        throwsA(
          isA<DavException>().having(
            (e) => e.kind,
            'kind',
            DavErrorKind.preconditionFailed,
          ),
        ),
      );
      expect(requests, 1);
    },
  );
  test('operations never redirect; bounded discovery follows trusted redirects only', () async {
    var calls = 0;
    final r = resources(
      MockClient((_) async {
        calls++;
        return http.Response('', 302, headers: {'location': '/destination'});
      }),
    );
    await expectLater(
      r.get(authority.resolve('/book/a.vcf')),
      throwsA(isA<DavException>()),
    );
    expect(calls, 1);
    await expectLater(
      r.propfind(
        authority.resolve('/.well-known/carddav'),
        [],
        discovery: true,
      ),
      throwsA(isA<DavException>()),
    );
    expect(calls, 3); // First discovery hop and its detected loop.
  });
  test('credential scopes normalize origins and protect Nextcloud installation and iCloud family', () {
    const cloud = DavProviderProfile.nextcloud(),
        apple = DavProviderProfile.iCloudCalDav();
    final server = Uri.parse('https://cloud.test:443/nextcloud/');
    expect(
      cloud.isTrustedCredentialDestination(
        Uri.parse('https://CLOUD.test/nextcloud/book/'),
        accountAuthority: server,
      ),
      isTrue,
    );
    expect(
      cloud.isTrustedCredentialDestination(
        Uri.parse('https://cloud.test/other/'),
        accountAuthority: server,
      ),
      isFalse,
    );
    expect(
      cloud.isTrustedCredentialDestination(
        Uri.parse('https://cloud.test/.well-known/carddav'),
        accountAuthority: server,
      ),
      isTrue,
    );
    const fixtureCloud = DavProviderProfile.nextcloud(
      allowInsecureLoopback: true,
    );
    expect(
      fixtureCloud.isTrustedCredentialDestination(
        Uri.parse('http://127.0.0.1:8080/nextcloud/remote.php/dav/'),
        accountAuthority: Uri.parse('http://127.0.0.1:8080/nextcloud/'),
      ),
      isTrue,
    );
    expect(
      fixtureCloud.isTrustedCredentialDestination(
        Uri.parse('http://example.test/nextcloud/remote.php/dav/'),
        accountAuthority: Uri.parse('http://example.test/nextcloud/'),
      ),
      isFalse,
    );
    expect(
      apple.isTrustedCredentialDestination(
        Uri.parse('https://p4-caldav.icloud.com/'),
        accountAuthority: Uri.parse('https://caldav.icloud.com/'),
      ),
      isTrue,
    );
    expect(
      apple.isTrustedCredentialDestination(
        Uri.parse('https://p4-caldav.icloud.com.evil.test/'),
        accountAuthority: Uri.parse('https://caldav.icloud.com/'),
      ),
      isFalse,
    );
    expect(
      utf8.decode(base64Decode(credential.authorizationValue.substring(6))),
      ' user : password ',
    );
  });
  test('streaming PROPFIND retains headers and uses incremental XML rather than file buffering', () async {
    final text = multi(entry('/book/a.vcf', '<d:getetag>"etag"</d:getetag>'));
    final bytes = utf8.encode(text);
    final transport = DavTransferClient(
      client: _StreamClient((request) async {
        expect(request.method, 'PROPFIND');
        expect(request.followRedirects, isFalse);
        return http.StreamedResponse(
          Stream.fromIterable(bytes.map((b) => [b])),
          207,
          headers: {'x-fixture': 'stream'},
        );
      }),
      authority: authority,
    );
    final token = DavCancellationToken();
    final response = await transport.openRead(
      authority,
      credential: credential,
      cancellation: token,
      method: 'PROPFIND',
    );
    expect(response.headers['x-fixture'], 'stream');
    final parsed = await parseDavMultistatusStream(
      response.body,
      cancellation: token,
    );
    expect(parsed.responses.single.href, '/book/a.vcf');
    await response.close();
  });
  test('streaming SEARCH retains its query body, credentials and multistatus response', () async {
    final query = utf8.encode(
      '<d:searchrequest xmlns:d="DAV:"><d:basicsearch/></d:searchrequest>',
    );
    final responseBytes = utf8.encode(
      multi(entry('/files/user/report.txt', '<d:getetag>"search"</d:getetag>')),
    );
    final transport = DavTransferClient(
      client: _StreamClient((request) async {
        expect(request.method, 'SEARCH');
        expect(request.followRedirects, isFalse);
        expect(request.headers['authorization'], credential.authorizationValue);
        expect(request.headers['content-type'], 'text/xml');
        expect(
          await request.finalize().expand((chunk) => chunk).toList(),
          query,
        );
        return http.StreamedResponse(
          Stream.fromIterable(responseBytes.map((byte) => [byte])),
          207,
        );
      }),
      authority: authority,
    );
    final cancellation = DavCancellationToken();
    final response = await transport.openRead(
      authority.resolve('/remote.php/dav/'),
      credential: credential,
      cancellation: cancellation,
      method: 'SEARCH',
      bodyBytes: query,
      headers: const {'content-type': 'text/xml'},
    );
    final parsed = await parseDavMultistatusStream(
      response.body,
      cancellation: cancellation,
    );
    expect(parsed.responses.single.href, '/files/user/report.txt');
    await response.close();
  });
  test('idle streaming cancellation terminates consumption promptly', () async {
    final started = Completer<void>();
    final body = StreamController<List<int>>(
      onListen: () => started.complete(),
    );
    final t = DavTransferClient(
      client: _StreamClient(
        (_) async => http.StreamedResponse(body.stream, 200),
      ),
      authority: authority,
    );
    final token = DavCancellationToken();
    final result = t
        .download(authority, credential: credential, cancellation: token)
        .drain<void>();
    await started.future;
    token.cancel();
    await expectLater(
      result.timeout(const Duration(seconds: 1)),
      throwsA(
        isA<DavException>().having(
          (e) => e.kind,
          'kind',
          DavErrorKind.cancelled,
        ),
      ),
    );
    await body.close();
  });
  test('streamed uploads retain backpressure, conditional headers and no response-size file limit', () async {
    var produced = 0, consumed = 0, maxAhead = 0;
    final t = DavTransferClient(
      authority: authority,
      client: _StreamClient((request) async {
        expect(request.headers['if-match'], '"base"');
        expect(request.headers['authorization'], credential.authorizationValue);
        await for (final chunk in request.finalize()) {
          consumed += chunk.length;
          maxAhead = maxAhead > produced - consumed
              ? maxAhead
              : produced - consumed;
          await Future<void>.delayed(Duration.zero);
        }
        return http.StreamedResponse(const Stream.empty(), 201);
      }),
    );
    Stream<List<int>> source() async* {
      for (var i = 0; i < 256; i++) {
        produced += 65536;
        yield List.filled(65536, 0);
      }
    }

    final response = await t.upload(
      authority,
      source: source(),
      length: 16 * 1024 * 1024,
      credential: credential,
      cancellation: DavCancellationToken(),
      headers: {'if-match': '"base"'},
    );
    expect(response.statusCode, 201);
    expect(consumed, 16 * 1024 * 1024);
    expect(maxAhead, lessThanOrEqualTo(65536));
  });
  test('5xx after uploading is unknown; a confirmed 429 rejection remains throttled', () async {
    for (final status in [503, 429]) {
      final t = DavTransferClient(
        authority: authority,
        client: _StreamClient((request) async {
          await request.finalize().drain<void>();
          return http.StreamedResponse(const Stream.empty(), status);
        }),
      );
      await expectLater(
        t.upload(
          authority,
          source: Stream.value([1]),
          length: 1,
          credential: credential,
          cancellation: DavCancellationToken(),
        ),
        throwsA(
          isA<DavException>().having(
            (e) => e.kind,
            'kind',
            status == 503
                ? DavErrorKind.unknownOutcome
                : DavErrorKind.rateLimited,
          ),
        ),
      );
    }
    expect(
      const DavException(
        kind: DavErrorKind.unknownOutcome,
        code: 'unknown',
        safeMessage: 'review',
        statusCode: 503,
      ).retryable,
      isFalse,
    );
  });
  test(
    'caller can classify an undispatched upload failure as retryable',
    () async {
      final t = DavTransferClient(
        authority: authority,
        client: _StreamClient((_) async {
          throw http.ClientException('not dispatched');
        }),
      );
      await expectLater(
        t.upload(
          authority,
          source: Stream.value([1]),
          length: 1,
          credential: credential,
          cancellation: DavCancellationToken(),
          mutationMayHaveCommitted: false,
        ),
        throwsA(
          isA<DavException>().having(
            (error) => error.kind,
            'kind',
            DavErrorKind.network,
          ),
        ),
      );
    },
  );
  test('incremental XML rejects entities, incomplete documents, depth and entry limits', () async {
    for (final text in [
      '<!DOCTYPE d:multistatus [<!ENTITY x "secret">]>' + multi(''),
      multi(entry('/a', '<d:getetag>x</d:getetag>'))
          .replaceFirst('</d:multistatus>', ''),
    ]) {
      await expectLater(
        parseDavMultistatusStream(
          Stream.value(utf8.encode(text)),
          cancellation: DavCancellationToken(),
        ),
        throwsA(isA<Exception>()),
      );
    }
    await expectLater(
      parseDavMultistatusStream(
        Stream.value(utf8.encode(multi(entry('/a', '') + entry('/b', '')))),
        cancellation: DavCancellationToken(),
        maximumEntries: 1,
      ),
      throwsFormatException,
    );
    await expectLater(
      parseDavMultistatusStream(
        Stream.value(utf8.encode(multi(entry('/a', '')))),
        cancellation: DavCancellationToken(),
        maximumDepth: 1,
      ),
      throwsFormatException,
    );
  });
  test('Nextcloud browser/poll credential handoff respects loginName, server and cancellation', () async {
    var polls = 0;
    Uri? browser;
    final flow = NextcloudLoginFlowV2(
      server: Uri.parse('https://dav.example.test/nextcloud'),
      launchBrowser: (uri) async {
        browser = uri;
        return true;
      },
      delay: (_) async {},
      client: MockClient((request) async {
        expect(request.headers.containsKey('authorization'), isFalse);
        expect(request.followRedirects, isFalse);
        if (request.url.path.endsWith('/v2'))
          return http.Response(
            jsonEncode({
              'login': 'https://dav.example.test/nextcloud/login',
              'poll': {
                'token': 'fixture',
                'endpoint': 'https://dav.example.test/nextcloud/poll',
              },
            }),
            200,
          );
        expect(request.bodyFields['token'], 'fixture');
        if (++polls == 1) return http.Response('', 404);
        return http.Response(
          jsonEncode({
            'server': 'https://dav.example.test/nextcloud',
            'loginName': 'actual-user',
            'appPassword': ' test password ',
          }),
          200,
        );
      }),
    );
    final result = await flow.authenticate(DavCancellationToken());
    expect(browser!.path, '/nextcloud/login');
    expect(result.loginName, 'actual-user');
    expect(result.appPassword, ' test password ');
    expect(result.toString(), isNot(contains('password')));
  });
  for (final field in ['login', 'endpoint', 'server']) {
    test(
      'Nextcloud rejects cross-origin $field before credential handoff',
      () async {
        final flow = NextcloudLoginFlowV2(
          server: authority,
          launchBrowser: (_) async => true,
          client: MockClient(
            (request) async => http.Response(
              jsonEncode(
                request.url.path.endsWith('/v2')
                    ? {
                        'login': field == 'login'
                            ? 'https://evil.test/login'
                            : authority.resolve('/login').toString(),
                        'poll': {
                          'token': 'fixture',
                          'endpoint': field == 'endpoint'
                              ? 'https://evil.test/poll'
                              : authority.resolve('/poll').toString(),
                        },
                      }
                    : {
                        'server': field == 'server'
                            ? 'https://evil.test'
                            : authority.toString(),
                        'loginName': 'user',
                        'appPassword': 'fixture',
                      },
              ),
              200,
            ),
          ),
        );
        await expectLater(
          flow.authenticate(DavCancellationToken()),
          throwsFormatException,
        );
      },
    );
  }
}

final class _StreamClient extends http.BaseClient {
  _StreamClient(this.handler);
  final Future<http.StreamedResponse> Function(http.BaseRequest) handler;
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) =>
      handler(request);
}
