import 'dart:async';
import 'dart:convert';

import 'package:busystack_dav/carddav.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

final _authority = Uri.parse('https://dav.example.test/');
final _collection = _authority.resolve('/book/');
const _limitError =
    '<d:error xmlns:d="DAV:"><d:number-of-matches-within-limits/></d:error>';
final _credential = DavBasicCredential(username: 'fixture', password: 'secret');

String _changed(String name) =>
    '<d:response><d:href>/book/$name.vcf</d:href><d:propstat><d:prop>'
    '<d:getetag>"revision"</d:getetag></d:prop>'
    '<d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>';

String _page(String content, {String token = 'urn:sync:next'}) =>
    '<d:multistatus xmlns:d="DAV:">$content'
    '<d:sync-token>$token</d:sync-token></d:multistatus>';

DavResourceClient _api(
  http.Client client, {
  required bool streaming,
  DavTransportLimits transportLimits = const DavTransportLimits(),
  DavXmlParser parser = const DavXmlParser(),
  DavCredentialProvider? credentialProvider,
}) => DavResourceClient(
  transport: DavHttpTransport(
    client: client,
    profile: const DavProviderProfile(),
    accountAuthority: _authority,
    limits: transportLimits,
  ),
  credentialProvider: credentialProvider ?? () async => _credential,
  authority: _authority,
  accountId: 'fixture-account',
  parser: parser,
  streaming: streaming
      ? DavTransferClient(client: client, authority: _authority)
      : null,
);

void main() {
  for (final streaming in [false, true]) {
    group(streaming ? 'streaming sync limit' : 'buffered sync limit', () {
      test('normal 207 returns one complete page without fallback', () async {
        var requests = 0;
        final api = _api(
          MockClient((request) async {
            requests++;
            expect(request.body, contains('<d:nresults>7</d:nresults>'));
            expect(request.body, contains('urn:sync:old&lt;&amp;'));
            return http.Response(_page(_changed('a')), 207);
          }),
          streaming: streaming,
        );
        final result = await api.syncCollection(
          _collection,
          'urn:sync:old<&',
          maximumResults: 7,
        );
        expect(requests, 1);
        expect(result.changed, {_collection.resolve('a.vcf'): '"revision"'});
        expect(result.syncToken, 'urn:sync:next');
        expect(result.truncated, isFalse);
      });

      test('207 request-URI 507 retains partial token and never drops limit', () async {
        var requests = 0;
        final api = _api(
          MockClient((request) async {
            requests++;
            expect(request.body, contains('<d:limit>'));
            return http.Response(
              _page(
                _changed('a') +
                    '<d:response><d:href>/book/</d:href>'
                        '<d:status>HTTP/1.1 507 Insufficient Storage</d:status>'
                        '<d:error><d:number-of-matches-within-limits/></d:error>'
                        '</d:response>',
                token: 'urn:sync:partial',
              ),
              207,
            );
          }),
          streaming: streaming,
        );
        final result = await api.syncCollection(_collection, 'urn:sync:old');
        expect(requests, 1);
        expect(result.changed, hasLength(1));
        expect(result.truncated, isTrue);
        expect(result.syncToken, 'urn:sync:partial');
      });

      test(
        '207 member 507 fails without treating it as collection truncation',
        () async {
          var requests = 0;
          final api = _api(
            MockClient((_) async {
              requests++;
              return http.Response(
                _page(
                  '<d:response><d:href>/book/broken.vcf</d:href>'
                  '<d:status>HTTP/1.1 507 Insufficient Storage</d:status>'
                  '<d:error><d:number-of-matches-within-limits/></d:error>'
                  '</d:response>',
                ),
                207,
              );
            }),
            streaming: streaming,
          );
          await expectLater(
            api.syncCollection(_collection, 'urn:sync:old'),
            throwsA(
              isA<DavException>().having(
                (error) => error.code,
                'code',
                'DavSyncResourceFailed',
              ),
            ),
          );
          expect(requests, 1);
        },
      );

      test(
        'top-level limit 507 retries once without limit and with same token',
        () async {
          var requests = 0;
          final api = _api(
            MockClient((request) async {
              requests++;
              expect(request.method, 'REPORT');
              expect(request.url, _collection);
              expect(request.followRedirects, isFalse);
              expect(request.headers['depth'], '0');
              expect(
                request.headers['authorization'],
                _credential.authorizationValue,
              );
              expect(
                request.body,
                contains('<d:sync-token>urn:sync:old</d:sync-token>'),
              );
              if (requests == 1) {
                expect(request.body, contains('<d:nresults>1</d:nresults>'));
                return http.Response(_limitError, 507);
              }
              expect(request.body, isNot(contains('<d:limit>')));
              expect(request.body, contains('<d:sync-level>1</d:sync-level>'));
              expect(request.body, contains('<d:prop><d:getetag/></d:prop>'));
              return http.Response(_page(_changed('a') + _changed('b')), 207);
            }),
            streaming: streaming,
          );
          final result = await api.syncCollection(
            _collection,
            'urn:sync:old',
            maximumResults: 1,
          );
          expect(requests, 2);
          expect(result.changed, hasLength(2));
          expect(result.syncToken, 'urn:sync:next');
          expect(result.truncated, isFalse);
        },
      );

      for (final body in [
        '<d:error xmlns:d="DAV:"><d:quota-not-exceeded/></d:error>',
        '<d:error xmlns:d="DAV:"><d:number-of-matches-within-limits>',
        '<d:error xmlns:d="urn:untrusted"><d:number-of-matches-within-limits/></d:error>',
        '<html>Insufficient storage</html>',
        _page(''),
      ]) {
        test('unrelated or malformed 507 has no fallback: $body', () async {
          var requests = 0;
          final api = _api(
            MockClient((_) async {
              requests++;
              return http.Response(body, 507);
            }),
            streaming: streaming,
          );
          await expectLater(
            api.syncCollection(_collection, 'urn:sync:old'),
            throwsA(
              isA<DavException>()
                  .having((error) => error.code, 'code', 'DavHttp507')
                  .having((error) => error.statusCode, 'status', 507),
            ),
          );
          expect(requests, 1);
        });
      }

      test('repeated top-level limit 507 stops after one fallback', () async {
        var requests = 0;
        final api = _api(
          MockClient((_) async {
            requests++;
            return http.Response(_limitError, 507);
          }),
          streaming: streaming,
        );
        await expectLater(
          api.syncCollection(_collection, 'urn:sync:old'),
          throwsA(
            isA<DavException>().having(
              (error) => error.code,
              'code',
              'DavSyncLimitRejected',
            ),
          ),
        );
        expect(requests, 2);
      });

      test(
        'fallback still reports expired cursor instead of returning a token',
        () async {
          var requests = 0;
          final api = _api(
            MockClient((_) async {
              requests++;
              return requests == 1
                  ? http.Response(_limitError, 507)
                  : http.Response(
                      '<d:error xmlns:d="DAV:"><d:valid-sync-token/></d:error>',
                      403,
                    );
            }),
            streaming: streaming,
          );
          await expectLater(
            api.syncCollection(_collection, 'urn:sync:old'),
            throwsA(
              isA<DavException>().having(
                (error) => error.kind,
                'kind',
                DavErrorKind.invalidSyncToken,
              ),
            ),
          );
          expect(requests, 2);
        },
      );

      test(
        'fallback still rejects credential destinations in response hrefs',
        () async {
          var requests = 0;
          final api = _api(
            MockClient((request) async {
              requests++;
              expect(request.url.host, _authority.host);
              return requests == 1
                  ? http.Response(_limitError, 507)
                  : http.Response(
                      _page(
                        '<d:response><d:href>https://evil.example.test/book/a.vcf</d:href>'
                        '<d:propstat><d:prop><d:getetag>"revision"</d:getetag></d:prop>'
                        '<d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>',
                      ),
                      207,
                    );
            }),
            streaming: streaming,
          );
          await expectLater(
            api.syncCollection(_collection, 'urn:sync:old'),
            throwsA(
              isA<DavException>().having(
                (error) => error.kind,
                'kind',
                DavErrorKind.redirectRejected,
              ),
            ),
          );
          expect(requests, 2);
        },
      );

      test(
        'cancellation fences fallback authorization before second dispatch',
        () async {
          var requests = 0, credentials = 0;
          final pending = Completer<DavBasicCredential>();
          final fallbackAuthorization = Completer<void>();
          final cancellation = DavCancellationToken();
          final api = _api(
            MockClient((_) async {
              requests++;
              return http.Response(_limitError, 507);
            }),
            streaming: streaming,
            credentialProvider: () {
              if (++credentials == 1) return Future.value(_credential);
              fallbackAuthorization.complete();
              return pending.future;
            },
          );
          final result = api.syncCollection(
            _collection,
            'urn:sync:old',
            cancellation: cancellation,
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
          await fallbackAuthorization.future.timeout(
            const Duration(seconds: 1),
          );
          cancellation.cancel();
          await assertion.timeout(const Duration(seconds: 1));
          pending.complete(_credential);
          expect(requests, 1);
          expect(credentials, 2);
        },
      );
    });
  }

  test('buffered fallback retains transport response byte bound', () async {
    var requests = 0;
    final api = _api(
      MockClient((_) async {
        requests++;
        return requests == 1
            ? http.Response(_limitError, 507)
            : http.Response(_page(_changed('a')), 207);
      }),
      streaming: false,
      transportLimits: const DavTransportLimits(maximumResponseBytes: 128),
    );
    await expectLater(
      api.syncCollection(_collection, 'urn:sync:old'),
      throwsA(
        isA<DavException>().having(
          (error) => error.kind,
          'kind',
          DavErrorKind.responseTooLarge,
        ),
      ),
    );
    expect(requests, 2);
  });

  test('buffered fallback retains XML element bound', () async {
    var requests = 0;
    final api = _api(
      MockClient((_) async {
        requests++;
        return requests == 1
            ? http.Response(_limitError, 507)
            : http.Response(_page(_changed('a')), 207);
      }),
      streaming: false,
      parser: const DavXmlParser(limits: DavXmlLimits(maximumElements: 3)),
    );
    await expectLater(
      api.syncCollection(_collection, 'urn:sync:old'),
      throwsA(isA<DavException>()),
    );
    expect(requests, 2);
  });

  test(
    'streaming fallback stays incremental and retains 32MiB byte bound',
    () async {
      var requests = 0, tailSent = false;
      final client = MockClient.streaming((request, body) async {
        final xml = utf8.decode(await body.expand((chunk) => chunk).toList());
        requests++;
        if (requests == 1) {
          expect(xml, contains('<d:limit>'));
          return http.StreamedResponse(
            Stream.value(utf8.encode(_limitError)),
            507,
          );
        }
        expect(xml, isNot(contains('<d:limit>')));
        Stream<List<int>> oversized() async* {
          yield utf8.encode('<d:multistatus xmlns:d="DAV:"><!--');
          // The incoming chunk itself crosses the global ceiling, so it must
          // be rejected before decoding or accumulating the comment body.
          yield List.filled(32 * 1024 * 1024, 32);
          tailSent = true;
          yield utf8.encode(
            '--><d:sync-token>urn:sync:unused</d:sync-token></d:multistatus>',
          );
        }

        return http.StreamedResponse(oversized(), 207);
      });
      final api = _api(client, streaming: true);
      await expectLater(
        api.syncCollection(_collection, 'urn:sync:old'),
        throwsA(
          isA<FormatException>().having(
            (error) => error.message,
            'message',
            'DAV stream byte limit',
          ),
        ),
      );
      expect(requests, 2);
      expect(tailSent, isFalse);
    },
  );

  test(
    'cancelling idle streamed fallback releases the response without a token',
    () async {
      var requests = 0, closed = false;
      final cancellation = DavCancellationToken();
      final fallbackStarted = Completer<void>();
      final idle = StreamController<List<int>>(
        onListen: fallbackStarted.complete,
        onCancel: () => closed = true,
      );
      final api = _api(
        MockClient.streaming((_, body) async {
          await body.drain<void>();
          if (++requests == 1)
            return http.StreamedResponse(
              Stream.value(utf8.encode(_limitError)),
              507,
            );
          return http.StreamedResponse(idle.stream, 207);
        }),
        streaming: true,
      );
      final result = api.syncCollection(
        _collection,
        'urn:sync:old',
        cancellation: cancellation,
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
      await fallbackStarted.future.timeout(const Duration(seconds: 1));
      cancellation.cancel();
      await assertion.timeout(const Duration(seconds: 1));
      expect(requests, 2);
      expect(closed, isTrue);
      await idle.close();
    },
  );
}
