import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:silsigan/services/audio_service.dart';

// Error codes come from ios/Runner/MicCapture.swift. Keep them in step.
void main() {
  test('a mic held by a call or another recorder gets its own message', () {
    final e = PlatformException(
      code: 'MIC_BUSY',
      message:
          'The operation couldn’t be completed. (OSStatus error 561017449.)',
    );
    expect(recordingStartErrorMessage(e), contains('Another app is using'));
  });

  test('no input route gets its own message', () {
    final e = PlatformException(
      code: 'MIC_UNAVAILABLE',
      message: 'No microphone input is available',
    );
    expect(recordingStartErrorMessage(e), contains('No microphone'));
  });

  test('other native start failures keep the generic retry copy', () {
    final e = PlatformException(code: 'MIC_START_FAILED', message: 'what');
    expect(
      recordingStartErrorMessage(e),
      "Couldn't start recording. You can try again.",
    );
  });

  test('mic errors are never mistaken for a screen-audio cancel', () {
    for (final code in ['MIC_BUSY', 'MIC_UNAVAILABLE', 'MIC_LOST']) {
      final e = PlatformException(
        code: code,
        message: 'The microphone stopped delivering audio.',
      );
      expect(isScreenAudioDenied(e), isFalse, reason: code);
    }
  });
}
