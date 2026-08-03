import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/api/api_client.dart';
import 'package:frontend/api/api_config.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('validating a base URL', () {
    test('accepts an ordinary address', () {
      expect(ApiConfig.validate('https://depcontrol-api.fly.dev'), isNull);
      expect(ApiConfig.validate('http://localhost:8080'), isNull);
    });

    test('refuses one with no scheme', () {
      // `Uri.parse` is happy with this and every request built from it would
      // fail in a way that looks like the server is down.
      expect(ApiConfig.validate('depcontrol-api.fly.dev'), isNotNull);
    });

    test('refuses a scheme that is not http', () {
      expect(ApiConfig.validate('ftp://example.com'), isNotNull);
      expect(ApiConfig.validate('postgres://example.com'), isNotNull);
    });

    test('refuses a query or a fragment', () {
      expect(ApiConfig.validate('https://example.com?token=x'), isNotNull);
      expect(ApiConfig.validate('https://example.com#top'), isNotNull);
    });

    test('drops a trailing slash, which every call site would double up', () {
      expect(ApiConfig.normalize('https://example.com/'), 'https://example.com');
      expect(
        ApiConfig.normalize('https://example.com///'),
        'https://example.com',
      );
    });
  });

  group('pointing a device somewhere else', () {
    test('starts on whatever the build was compiled with', () async {
      final config = ApiConfig();
      await config.load();

      expect(config.isCustom, isFalse);
      expect(config.baseUrl, config.compiledDefault);
    });

    test('remembers an override across a restart', () async {
      final first = ApiConfig();
      await first.load();
      expect(await first.setBaseUrl('https://staging.example.com'), isNull);

      // A second instance is what the next launch sees.
      final next = ApiConfig();
      await next.load();

      expect(next.isCustom, isTrue);
      expect(next.baseUrl, 'https://staging.example.com');
    });

    test('a refused address changes nothing', () async {
      final config = ApiConfig();
      await config.load();

      expect(await config.setBaseUrl('not a url'), isNotNull);
      expect(config.isCustom, isFalse);
      expect(config.baseUrl, config.compiledDefault);
    });

    test('clearing it goes back to the compiled default', () async {
      final config = ApiConfig();
      await config.load();
      await config.setBaseUrl('https://staging.example.com');

      await config.setBaseUrl(null);

      expect(config.isCustom, isFalse);
      expect(config.baseUrl, config.compiledDefault);
    });
  });

  group('what a client talks to', () {
    tearDown(() => ApiConfig.instance.reset());

    test('follows the setting without being rebuilt', () async {
      // Resolved per read rather than captured at construction, so changing it
      // in settings takes effect on the next request instead of next launch.
      final client = ApiClient();
      final before = client.baseUrl;

      await ApiConfig.instance.setBaseUrl('https://staging.example.com');

      expect(before, isNot('https://staging.example.com'));
      expect(client.baseUrl, 'https://staging.example.com');
    });

    test('a client pinned to an address ignores the setting', () async {
      // Which is what every test in this suite relies on.
      final client = ApiClient(baseUrl: 'http://test');
      await ApiConfig.instance.setBaseUrl('https://staging.example.com');

      expect(client.baseUrl, 'http://test');
    });
  });
}
