import 'package:flutter_test/flutter_test.dart';
import 'package:qfli_git_example/flow.dart';

void main() {
  group('sanitizeRemoteUrl', () {
    test('drops userinfo', () {
      expect(
        sanitizeRemoteUrl('https://user:token@example.com/org/repo.git'),
        'https://example.com/org/repo.git',
      );
    });

    test('keeps a URL without userinfo', () {
      const url = 'https://example.com/org/repo.git';
      expect(sanitizeRemoteUrl(url), url);
    });

    test('keeps a local path', () {
      const url = '/tmp/source';
      expect(sanitizeRemoteUrl(url), url);
    });
  });

  group('displayRemoteUrl', () {
    test('shows host and path', () {
      expect(
        displayRemoteUrl('https://example.com/org/repo.git'),
        'example.com/org/repo.git',
      );
    });

    test('never shows userinfo', () {
      final text = displayRemoteUrl('https://user:token@example.com/o/r.git');
      expect(text, 'example.com/o/r.git');
      expect(text, isNot(contains('token')));
    });
  });
  group('FlowStep', () {
    test('a cancelled step is not a failure', () {
      const step = FlowStep(
        name: 'clone',
        succeeded: false,
        cancelled: true,
        elapsed: Duration(milliseconds: 5),
      );

      expect(step.cancelled, isTrue);
      expect(step.error, isNull);
      expect(step.toString(), contains('cancelled'));
      expect(step.toString(), isNot(contains('failed')));
    });
  });
}
