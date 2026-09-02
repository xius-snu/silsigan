import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:silsigan/utils/pcm_mixer.dart';

void main() {
  int16Bytes(int sample) {
    final u = sample & 0xFFFF;
    return [u & 0xFF, (u >> 8) & 0xFF];
  }

  test('mixPcm16Le adds samples and saturates', () {
    final a = Uint8List.fromList([...int16Bytes(20000), ...int16Bytes(-20000)]);
    final b = Uint8List.fromList([...int16Bytes(20000), ...int16Bytes(-20000)]);
    final mixed = mixPcm16Le(a, b);
    expect(mixed.length, 4);
    final s0 = mixed[0] | (mixed[1] << 8);
    final s1 = mixed[2] | (mixed[3] << 8);
    expect(s0 >= 0x8000 ? s0 - 0x10000 : s0, 32767);
    expect(s1 >= 0x8000 ? s1 - 0x10000 : s1, -32768);
  });

  test('mixPcm16Le pads the shorter stream with silence', () {
    final a = Uint8List.fromList(int16Bytes(1000));
    final b = Uint8List.fromList([...int16Bytes(500), ...int16Bytes(200)]);
    final mixed = mixPcm16Le(a, b);
    expect(mixed.length, 4);
    final s0 = mixed[0] | (mixed[1] << 8);
    final s1 = mixed[2] | (mixed[3] << 8);
    expect(s0 >= 0x8000 ? s0 - 0x10000 : s0, 1500);
    expect(s1 >= 0x8000 ? s1 - 0x10000 : s1, 200);
  });
}
