import 'package:busystack_dav/nextcloud.dart' as nextcloud;

import 'dart:convert';
import 'dart:io';

import 'package:busystack_dav/busystack_dav.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

final class CertificateRejected extends DavException
    implements DavRequestNotDispatchedException {
  CertificateRejected()
    : super(
        kind: DavErrorKind.tls,
        code: 'SyntheticCertificateRejected',
        safeMessage: 'Synthetic TLS rejection',
      );
}

void main() {
  for (final method in ['PUT', 'DELETE', 'PROPFIND']) {
    test(
      'proven pre-dispatch $method failure retains identity and is never retried',
      () async {
        final failure = CertificateRejected();
        var attempts = 0;
        final transport = DavHttpTransport(
          client: MockClient((request) async {
            attempts++;
            throw failure;
          }),
          profile: const DavProviderProfile.nextcloud(),
          accountAuthority: Uri.parse('https://cloud.test/nextcloud/'),
        );
        await expectLater(
          transport.send(
            DavRequest(
              method: method,
              uri: Uri.parse(
                'https://cloud.test/nextcloud/remote.php/dav/item',
              ),
              accountId: 'synthetic',
              correlationId: 'synthetic',
              retryClass: DavRetryClass.safeRead,
            ),
            credential: DavBasicCredential(
              username: 'synthetic',
              password: 'synthetic',
            ),
          ),
          throwsA(same(failure)),
        );
        expect(attempts, 1);
      },
    );
  }
  test('unproven connection loss preserves unknown mutation outcome', () async {
    final transport = DavHttpTransport(
      client: MockClient((request) async {
        throw const SocketException('synthetic post-dispatch loss');
      }),
      profile: const DavProviderProfile.nextcloud(),
      accountAuthority: Uri.parse('https://cloud.test/'),
    );
    await expectLater(
      transport.send(
        DavRequest(
          method: 'PUT',
          uri: Uri.parse('https://cloud.test/item'),
          accountId: 'synthetic',
          correlationId: 'synthetic',
        ),
        credential: DavBasicCredential(
          username: 'synthetic',
          password: 'synthetic',
        ),
      ),
      throwsA(
        isA<DavException>().having(
          (e) => e.kind,
          'kind',
          DavErrorKind.unknownOutcome,
        ),
      ),
    );
  });
  for (final phase in ['login', 'poll', 'server']) {
    test(
      'Nextcloud refuses same-origin installation escape in $phase',
      () async {
        final server = Uri.parse('https://cloud.test/nextcloud/');
        var attempts = 0;
        var launched = false;
        final flow = nextcloud.NextcloudLoginFlowV2(
          server: server,
          client: MockClient((request) async {
            attempts++;
            return http.Response(
              jsonEncode(
                attempts == 1
                    ? {
                        'login': phase == 'login'
                            ? 'https://cloud.test/other/login'
                            : 'https://cloud.test/nextcloud/login',
                        'poll': {
                          'endpoint': phase == 'poll'
                              ? 'https://cloud.test/other/poll'
                              : 'https://cloud.test/nextcloud/poll',
                          'token': 'synthetic',
                        },
                      }
                    : {
                        'server': 'https://cloud.test/other/',
                        'loginName': 'synthetic',
                        'appPassword': 'synthetic',
                      },
              ),
              200,
            );
          }),
          launchBrowser: (_) async {
            launched = true;
            return true;
          },
        );
        await expectLater(
          flow.authenticate(DavCancellationToken()),
          throwsFormatException,
        );
        expect(launched, phase == 'server');
        expect(attempts, phase == 'server' ? 2 : 1);
        flow.close();
      },
    );
  }
  test(
    'streamed upload retains proven pre-send certificate rejection',
    () async {
      final failure = CertificateRejected();
      final transfer = DavTransferClient(
        client: MockClient((_) async => throw failure),
        authority: Uri.parse('https://cloud.test/'),
      );
      await expectLater(
        transfer.upload(
          Uri.parse('https://cloud.test/item'),
          source: const Stream<List<int>>.empty(),
          length: 0,
          credential: DavBasicCredential(
            username: 'synthetic',
            password: 'synthetic',
          ),
          cancellation: DavCancellationToken(),
        ),
        throwsA(same(failure)),
      );
    },
  );
}
