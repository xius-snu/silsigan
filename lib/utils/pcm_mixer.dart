import 'dart:math' as math;
import 'dart:typed_data';

/// Mix two PCM16-LE streams. The shorter side is treated as silence for the
/// leftover samples so a slightly-late stream doesn't stall the other.
Uint8List mixPcm16Le(Uint8List a, Uint8List b) {
  final n = math.max(a.length, b.length) & ~1;
  if (n == 0) return Uint8List(0);
  final out = Uint8List(n);
  for (int i = 0; i < n; i += 2) {
    int sa = 0;
    int sb = 0;
    if (i + 1 < a.length) {
      final u = a[i] | (a[i + 1] << 8);
      sa = u >= 0x8000 ? u - 0x10000 : u;
    }
    if (i + 1 < b.length) {
      final u = b[i] | (b[i + 1] << 8);
      sb = u >= 0x8000 ? u - 0x10000 : u;
    }
    int sum = sa + sb;
    if (sum > 32767) sum = 32767;
    if (sum < -32768) sum = -32768;
    out[i] = sum & 0xFF;
    out[i + 1] = (sum >> 8) & 0xFF;
  }
  return out;
}
