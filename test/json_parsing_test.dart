import 'package:flutter_test/flutter_test.dart';
import 'package:qfli_git/qfli_git.dart';

void main() {
  group('parseConflictPaths', () {
    test('reads a list of paths', () {
      expect(parseConflictPaths('["a.txt","dir/b.txt"]'), [
        'a.txt',
        'dir/b.txt',
      ]);
    });

    test('returns an empty list for JSON null', () {
      expect(parseConflictPaths('null'), isEmpty);
    });

    test('keeps UTF-8 paths intact', () {
      expect(parseConflictPaths('["文档/说明.md"]'), ['文档/说明.md']);
    });

    test('rejects an object', () {
      expect(() => parseConflictPaths('{"path":"a"}'), throwsFormatException);
    });

    test('rejects a non-string entry', () {
      expect(() => parseConflictPaths('[1]'), throwsFormatException);
    });
  });

  group('parseStatusEntries', () {
    test('reads path and status pairs', () {
      final entries = parseStatusEntries(
        '[{"path":"a.txt","status":"modified"},{"path":"b.txt","status":"deleted"}]',
      );
      expect(entries, hasLength(2));
      expect(entries.first.path, 'a.txt');
      expect(entries.first.status, 'modified');
      expect(entries.last.status, 'deleted');
    });

    test('defaults a missing status to an empty string', () {
      final entries = parseStatusEntries('[{"path":"a.txt"}]');
      expect(entries.single.status, isEmpty);
    });

    test('returns an empty list for JSON null', () {
      expect(parseStatusEntries('null'), isEmpty);
    });

    test('rejects an entry without a path', () {
      expect(
        () => parseStatusEntries('[{"status":"modified"}]'),
        throwsFormatException,
      );
    });

    test('rejects a path that is not a string', () {
      expect(() => parseStatusEntries('[{"path":7}]'), throwsFormatException);
    });
  });

  group('parseHead', () {
    test('reads branch, oid and state', () {
      final head = parseHead(
        '{"branch":"main","oid":"abc123","state":"clean"}',
      );
      expect(head.branch, 'main');
      expect(head.oid, 'abc123');
      expect(head.state, 'clean');
    });

    test('treats an empty branch as detached', () {
      final head = parseHead('{"branch":"","oid":"abc123","state":"clean"}');
      expect(head.branch, isNull);
    });

    test('treats a missing branch as detached', () {
      final head = parseHead('{"oid":"abc123"}');
      expect(head.branch, isNull);
      expect(head.state, isEmpty);
    });

    test('rejects a payload without an oid', () {
      expect(() => parseHead('{"branch":"main"}'), throwsFormatException);
    });

    test('rejects a JSON null payload', () {
      expect(() => parseHead('null'), throwsFormatException);
    });
  });

  group('MergeOutcome.fromCode', () {
    test('maps every documented result', () {
      expect(MergeOutcome.fromCode(0), MergeOutcome.upToDate);
      expect(MergeOutcome.fromCode(1), MergeOutcome.fastForward);
      expect(MergeOutcome.fromCode(2), MergeOutcome.merged);
      expect(MergeOutcome.fromCode(3), MergeOutcome.conflicts);
    });

    test('rejects an unknown result', () {
      expect(
        () => MergeOutcome.fromCode(9),
        throwsA(isA<GitException>().having((e) => e.code, 'code', qgEInvalid)),
      );
    });
  });
}
