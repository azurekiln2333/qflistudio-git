import 'dart:convert';
import 'dart:ffi';

import 'package:ffi/ffi.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qfli_git/src/bindings.dart';
import 'package:qfli_git/src/repository.dart';

/// Writes [text] into the `message` field of [error] and terminates it with NUL.
void writeMessage(Pointer<QgError> error, String text) {
  final bytes = error.cast<Uint8>().asTypedList(sizeOf<QgError>());
  final offset = sizeOf<QgError>() - qgErrorMessageBytes;
  final encoded = utf8.encode(text);
  bytes.setRange(offset, offset + encoded.length, encoded);
}

void main() {
  group('qg_error layout', () {
    test('keeps the two int fields in front of the 512 byte message', () {
      expect(sizeOf<QgError>(), 2 * sizeOf<Int32>() + qgErrorMessageBytes);
    });
  });

  group('NativeError.read', () {
    test('copies code, klass and message', () {
      final error = calloc<QgError>();
      try {
        error.ref.code = -3;
        error.ref.klass = 12;
        writeMessage(error, 'reference not found');

        final native = NativeError.read(error, -1);

        expect(native.code, -3);
        expect(native.klass, 12);
        expect(native.message, 'reference not found');
      } finally {
        calloc.free(error);
      }
    });

    test('falls back to the return code when the block is empty', () {
      final error = calloc<QgError>();
      try {
        final native = NativeError.read(error, qgEInvalid);

        expect(native.code, qgEInvalid);
        expect(native.klass, 0);
        expect(native.message, 'native call failed with code $qgEInvalid');
      } finally {
        calloc.free(error);
      }
    });

    test('stops the message at the first NUL', () {
      final error = calloc<QgError>();
      try {
        error.ref.code = -1;
        writeMessage(error, 'short');

        expect(NativeError.read(error, 0).message, 'short');
      } finally {
        calloc.free(error);
      }
    });
  });

  group('GitException.fromNative', () {
    test('keeps code, klass and message', () {
      final exception = GitException.fromNative(
        const NativeError(
          code: -12,
          klass: 4,
          message: 'authentication required',
        ),
      );

      expect(exception.code, -12);
      expect(exception.klass, 4);
      expect(exception.message, 'authentication required');
      expect(exception.isCanceled, isFalse);
      expect(exception.isConflict, isFalse);
    });

    test('recognises a canceled operation', () {
      const exception = GitException(qgECanceled, 0, 'canceled');

      expect(exception.isCanceled, isTrue);
      expect(exception.isConflict, isFalse);
    });

    test('recognises an unresolved merge', () {
      const exception = GitException(qgEConflict, 0, 'conflicts remain');

      expect(exception.isConflict, isTrue);
      expect(exception.isCanceled, isFalse);
    });

    test('prints the code and the message', () {
      const exception = GitException(qgEInvalid, 0, 'bad argument');

      expect(exception.toString(), contains('-1002'));
      expect(exception.toString(), contains('bad argument'));
    });
  });

  group('CancelToken', () {
    test('accepts repeated cancel and dispose calls', () {
      final token = CancelToken();
      addTearDown(token.dispose);

      token.cancel();
      token.cancel();
      token.dispose();
      token.dispose();
    });

    test('ignores cancel after dispose', () {
      final token = CancelToken()..dispose();

      token.cancel();
    });
  });
}
