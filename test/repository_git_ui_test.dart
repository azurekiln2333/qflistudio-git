import 'package:flutter_test/flutter_test.dart';
import 'package:qfli_git/qfli_git.dart';

void main() {
  group('parseDiff', () {
    test('reads patch, binary and truncation flags', () {
      final diff = parseDiff(
        '{"patch":"@@ -1 +1 @@\\n-old\\n+new\\n",'
        '"binary":true,"truncated":true}',
      );
      expect(diff.patch, contains('+new'));
      expect(diff.binary, isTrue);
      expect(diff.truncated, isTrue);
      expect(diff.isEmpty, isFalse);
    });

    test('defaults missing fields', () {
      final diff = parseDiff('{}');
      expect(diff.patch, isEmpty);
      expect(diff.binary, isFalse);
      expect(diff.truncated, isFalse);
      expect(diff.isEmpty, isTrue);
    });

    test('rejects a non-object payload', () {
      expect(() => parseDiff('[]'), throwsFormatException);
      expect(() => parseDiff('null'), throwsFormatException);
    });

    test('rejects a non-string patch', () {
      expect(() => parseDiff('{"patch":42}'), throwsFormatException);
    });
  });

  group('parseLog', () {
    test('reads commits and converts Unix seconds to UTC', () {
      final commits = parseLog(
        '[{"oid":"abc123","message":"subject\\n\\nbody",'
        '"authorName":"Ada","authorEmail":"ada@example.com","time":1700000000}]',
      );
      expect(commits, hasLength(1));
      final commit = commits.single;
      expect(commit.oid, 'abc123');
      expect(commit.message, 'subject\n\nbody');
      expect(commit.authorName, 'Ada');
      expect(commit.authorEmail, 'ada@example.com');
      expect(commit.time.isUtc, isTrue);
      expect(
        commit.time,
        DateTime.fromMillisecondsSinceEpoch(1700000000 * 1000, isUtc: true),
      );
    });

    test('keeps Unicode commit text intact', () {
      final commits = parseLog(
        '[{"oid":"abc","message":"修复：提交","authorName":"张三",'
        '"authorEmail":"zhang@example.com","time":1}]',
      );
      expect(commits.single.message, '修复：提交');
      expect(commits.single.authorName, '张三');
    });

    test('defaults missing optional text', () {
      final commit = parseLog('[{"oid":"abc","time":1}]').single;
      expect(commit.message, isEmpty);
      expect(commit.authorName, isEmpty);
      expect(commit.authorEmail, isEmpty);
    });

    test('returns an empty list for JSON null', () {
      expect(parseLog('null'), isEmpty);
      expect(parseLog('[]'), isEmpty);
    });

    test('rejects an entry without an oid or time', () {
      expect(() => parseLog('[{"time":1}]'), throwsFormatException);
      expect(() => parseLog('[{"oid":"abc"}]'), throwsFormatException);
    });

    test('rejects a non-array payload', () {
      expect(() => parseLog('{}'), throwsFormatException);
    });
  });

  group('parseBranches', () {
    test('reads local and remote branches with upstream', () {
      final branches = parseBranches(
        '[{"name":"main","current":true,"remote":false,'
        '"upstream":"origin/main"},'
        '{"name":"origin/main","current":false,"remote":true}]',
      );
      expect(branches, hasLength(2));
      expect(branches.first.name, 'main');
      expect(branches.first.current, isTrue);
      expect(branches.first.remote, isFalse);
      expect(branches.first.upstream, 'origin/main');
      expect(branches.last.remote, isTrue);
      expect(branches.last.upstream, isNull);
    });

    test('defaults flags and upstream', () {
      final branch = parseBranches('[{"name":"dev"}]').single;
      expect(branch.current, isFalse);
      expect(branch.remote, isFalse);
      expect(branch.upstream, isNull);
    });

    test('keeps Unicode branch names intact', () {
      expect(parseBranches('[{"name":"功能/登录"}]').single.name, '功能/登录');
    });

    test('rejects an entry without a name', () {
      expect(() => parseBranches('[{"current":true}]'), throwsFormatException);
    });
  });

  group('parseRemotes', () {
    test('reads remote names and URLs', () {
      final remotes = parseRemotes(
        '[{"name":"origin","url":"https://example.com/repo.git"},'
        '{"name":"backup","url":"ssh://git@example.com/backup.git"}]',
      );
      expect(remotes, hasLength(2));
      expect(remotes.first.name, 'origin');
      expect(remotes.first.url, 'https://example.com/repo.git');
      expect(remotes.last.name, 'backup');
      expect(remotes.last.url, 'ssh://git@example.com/backup.git');
    });

    test('defaults a missing URL to an empty string', () {
      expect(parseRemotes('[{"name":"origin"}]').single.url, isEmpty);
    });

    test('returns an empty list for JSON null', () {
      expect(parseRemotes('null'), isEmpty);
    });

    test('rejects an entry without a name', () {
      expect(
        () => parseRemotes('[{"url":"https://example.com"}]'),
        throwsFormatException,
      );
    });
  });
}
