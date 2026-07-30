import 'package:backend/src/notifications/webhook_url.dart';
import 'package:shared/shared.dart';
import 'package:test/test.dart';

void main() {
  const slack = NotificationChannel.slack;
  const teams = NotificationChannel.teams;

  group('what is accepted', () {
    test('a Slack incoming webhook', () {
      expect(
        WebhookUrl.isValid(
          'https://hooks.slack.com/services/T000/B000/XXXXXXXX',
          slack,
        ),
        isTrue,
      );
    });

    test('a Teams connector and a Power Automate workflow', () {
      expect(
        WebhookUrl.isValid(
          'https://acme.webhook.office.com/webhookb2/abc/IncomingWebhook/def',
          teams,
        ),
        isTrue,
      );
      expect(
        WebhookUrl.isValid(
          'https://prod-12.westeurope.logic.azure.com/workflows/abc/triggers/x',
          teams,
        ),
        isTrue,
      );
    });

    test('surrounding whitespace is forgiven', () {
      expect(
        WebhookUrl.isValid(
          '  https://hooks.slack.com/services/T/B/X  ',
          slack,
        ),
        isTrue,
      );
    });
  });

  group('what is refused', () {
    // The whole point of the allowlist. This server makes an outbound request
    // to whatever is stored here, from inside its own network.
    test('anything not on the list', () {
      expect(WebhookUrl.isValid('https://attacker.test/hook', slack), isFalse);
      expect(WebhookUrl.isValid('https://example.com/hook', teams), isFalse);
    });

    test('the other channel\'s host', () {
      // A Slack URL in a Teams target would be delivered to Slack in a payload
      // Slack cannot read, which is a confusing failure rather than a useful
      // one.
      expect(
        WebhookUrl.isValid('https://hooks.slack.com/services/T/B/X', teams),
        isFalse,
      );
    });

    test('a lookalike host that merely ends the right way', () {
      // The leading dot in the suffix is what makes these fail.
      expect(
        WebhookUrl.isValid('https://evilwebhook.office.com/x', teams),
        isFalse,
      );
      expect(
        WebhookUrl.isValid('https://nothooks.slack.com/x', slack),
        isFalse,
      );
    });

    test('a host with the allowed one as a prefix', () {
      expect(
        WebhookUrl.isValid('https://hooks.slack.com.attacker.test/x', slack),
        isFalse,
      );
      expect(
        WebhookUrl.isValid('https://acme.webhook.office.com.evil.test/x', teams),
        isFalse,
      );
    });

    test('userinfo that makes an attacker\'s host read as Slack\'s', () {
      // `https://hooks.slack.com@attacker.test/` has a host of attacker.test.
      expect(
        WebhookUrl.isValid('https://hooks.slack.com@attacker.test/x', slack),
        isFalse,
      );
    });

    test('plaintext http', () {
      // The URL is a bearer credential; it does not travel in the clear.
      expect(
        WebhookUrl.isValid('http://hooks.slack.com/services/T/B/X', slack),
        isFalse,
      );
    });

    test('a non-default port', () {
      expect(
        WebhookUrl.isValid('https://hooks.slack.com:8443/services/T/B/X', slack),
        isFalse,
      );
    });

    test('the loopback address in any spelling', () {
      for (final host in const [
        'https://127.0.0.1/x',
        'https://localhost/x',
        'https://[::1]/x',
        'https://169.254.169.254/latest/meta-data/',
        'https://0.0.0.0/x',
      ]) {
        expect(
          WebhookUrl.isValid(host, slack),
          isFalse,
          reason: '$host must not be deliverable',
        );
      }
    });

    test('other schemes', () {
      expect(WebhookUrl.isValid('file:///etc/passwd', slack), isFalse);
      expect(WebhookUrl.isValid('gopher://hooks.slack.com/x', slack), isFalse);
    });

    test('nothing at all', () {
      expect(WebhookUrl.isValid('', slack), isFalse);
      expect(WebhookUrl.isValid('   ', slack), isFalse);
    });
  });

  group('the refusal says what to fix', () {
    test('and names the hosts it would take', () {
      expect(
        () => WebhookUrl.parse('https://attacker.test/x', slack),
        throwsA(
          isA<WebhookUrlError>().having(
            (e) => e.message,
            'message',
            contains('hooks.slack.com'),
          ),
        ),
      );
    });

    test('scheme, port and userinfo each get their own reason', () {
      String reasonFor(String url) {
        try {
          WebhookUrl.parse(url, slack);
          fail('$url should not have parsed');
        } on WebhookUrlError catch (e) {
          return e.message;
        }
      }

      expect(reasonFor('http://hooks.slack.com/x'), contains('https'));
      expect(reasonFor('https://hooks.slack.com:8443/x'), contains('port'));
      expect(
        reasonFor('https://user:pw@hooks.slack.com/x'),
        contains('username'),
      );
    });
  });

  group('redaction', () {
    test('keeps enough to tell two targets apart and no more', () {
      final redacted = WebhookUrl.redact(
        'https://hooks.slack.com/services/T00000/B00000/abcdefghijkl',
      );

      expect(redacted, 'hooks.slack.com/…ijkl');
      // The parts that make it usable are gone.
      expect(redacted, isNot(contains('T00000')));
      expect(redacted, isNot(contains('abcdefgh')));
    });

    test('a short final segment is not padded out', () {
      expect(WebhookUrl.redact('https://hooks.slack.com/ab'), contains('ab'));
    });

    test('a URL with no path is just its host', () {
      expect(WebhookUrl.redact('https://hooks.slack.com'), 'hooks.slack.com');
    });
  });
}
