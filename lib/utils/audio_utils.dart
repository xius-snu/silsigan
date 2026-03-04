import 'dart:typed_data';

class AudioUtils {
  static bool verifyPcm16Format(Uint8List data) {
    // PCM16 should have even number of bytes (2 bytes per sample)
    return data.length % 2 == 0;
  }

  static int calculateChunkSize(int sampleRate, int intervalMs) {
    // PCM16 = 2 bytes per sample, mono = 1 channel
    return (sampleRate * 2 * intervalMs) ~/ 1000;
  }
}
