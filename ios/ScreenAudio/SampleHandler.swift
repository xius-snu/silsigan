import ReplayKit
import CoreMedia
import AVFoundation

/// ReplayKit Broadcast Upload Extension. Consumes `audioApp` sample buffers
/// (system / other-app audio) and writes PCM16 / 24 kHz / mono into the App
/// Group ring that the Flutter isolate polls via readLoopback.
///
/// Video buffers are dropped immediately so we stay under the extension
/// memory limit. `audioMic` is ignored on purpose: the main app already
/// records the microphone through flutter_sound when the user picks Both.
/// The system picker mic button is hidden from the main app; if a user
/// still enables Mic from Control Center, that path would double-capture.
class SampleHandler: RPBroadcastSampleHandler {
  private let ring = AudioRingBuffer()
  private let resampler = PcmResampler()
  private var lastBeat: Date = .distantPast

  override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {
    BroadcastIPC.clearStop()
    _ = ring.open(create: true)
    ring.reset()
    BroadcastIPC.setRunning(true)
    BroadcastIPC.post(BroadcastIPC.startedNotification)
  }

  override func broadcastPaused() {}

  override func broadcastResumed() {}

  override func broadcastFinished() {
    BroadcastIPC.setRunning(false)
    BroadcastIPC.post(BroadcastIPC.stoppedNotification)
    ring.close()
  }

  override func processSampleBuffer(_ sampleBuffer: CMSampleBuffer, with sampleBufferType: RPSampleBufferType) {
    if BroadcastIPC.stopRequested() {
      finishQuietly()
      return
    }
    let now = Date()
    if now.timeIntervalSince(lastBeat) > 0.8 {
      BroadcastIPC.beat()
      lastBeat = now
    }
    switch sampleBufferType {
    case .video:
      break
    case .audioApp:
      writeAudio(sampleBuffer)
    case .audioMic:
      break
    @unknown default:
      break
    }
  }

  private func finishQuietly() {
    BroadcastIPC.setRunning(false)
    BroadcastIPC.post(BroadcastIPC.stoppedNotification)
    let error = NSError(
      domain: "com.silsigan.app.ScreenAudio",
      code: 0,
      userInfo: [NSLocalizedDescriptionKey: "Stopped"]
    )
    finishBroadcastWithError(error)
  }

  private func writeAudio(_ sampleBuffer: CMSampleBuffer) {
    guard let format = CMSampleBufferGetFormatDescription(sampleBuffer),
          let asbdPtr = CMAudioFormatDescriptionGetStreamBasicDescription(format)
    else { return }
    let asbd = asbdPtr.pointee
    guard let block = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }
    let length = CMBlockBufferGetDataLength(block)
    if length <= 0 { return }
    var bytes = Data(count: length)
    let copy = bytes.withUnsafeMutableBytes { raw -> OSStatus in
      guard let base = raw.baseAddress else { return -1 }
      return CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: base)
    }
    guard copy == noErr else { return }

    let channels = max(1, Int(asbd.mChannelsPerFrame))
    let srcRate = asbd.mSampleRate > 0 ? asbd.mSampleRate : 44_100
    let isFloat = (asbd.mFormatFlags & kAudioFormatFlagIsFloat) != 0
    let bits = Int(asbd.mBitsPerChannel)
    let floats = Self.monoFloats(
      bytes: bytes,
      channels: channels,
      isFloat: isFloat,
      bits: bits
    )
    let pcm = resampler.convert(floats, srcRate: srcRate)
    if !pcm.isEmpty {
      ring.write(pcm)
    }
  }

  private static func monoFloats(
    bytes: Data,
    channels: Int,
    isFloat: Bool,
    bits: Int
  ) -> [Float] {
    if isFloat && bits == 32 {
      let count = bytes.count / 4
      if count == 0 { return [] }
      return bytes.withUnsafeBytes { raw in
        let ptr = raw.bindMemory(to: Float.self)
        if channels <= 1 {
          return Array(ptr.prefix(count))
        }
        let frames = count / channels
        var out = [Float](repeating: 0, count: frames)
        for i in 0..<frames {
          var sum: Float = 0
          for c in 0..<channels {
            sum += ptr[i * channels + c]
          }
          out[i] = sum / Float(channels)
        }
        return out
      }
    }
    if bits == 16 {
      let count = bytes.count / 2
      if count == 0 { return [] }
      return bytes.withUnsafeBytes { raw in
        let ptr = raw.bindMemory(to: Int16.self)
        func s(_ v: Int16) -> Float { Float(v) / 32768.0 }
        if channels <= 1 {
          var out = [Float](repeating: 0, count: count)
          for i in 0..<count { out[i] = s(ptr[i]) }
          return out
        }
        let frames = count / channels
        var out = [Float](repeating: 0, count: frames)
        for i in 0..<frames {
          var sum: Float = 0
          for c in 0..<channels {
            sum += s(ptr[i * channels + c])
          }
          out[i] = sum / Float(channels)
        }
        return out
      }
    }
    return []
  }
}

/// Linear-interpolation resampler to 24 kHz PCM16 mono.
final class PcmResampler {
  private let dstRate: Double = 24_000
  private var srcRate: Double = 44_100
  private var prev: Float = 0
  private var phase: Double = 1
  private var hasPrev = false

  func convert(_ samples: [Float], srcRate: Double) -> Data {
    if samples.isEmpty { return Data() }
    if abs(self.srcRate - srcRate) > 0.5 {
      self.srcRate = srcRate
      phase = 1
      hasPrev = false
    }
    let step = srcRate / dstRate
    var out = [Int16]()
    out.reserveCapacity(max(1, Int(Double(samples.count) * dstRate / srcRate) + 2))
    var idx = 0
    var current = samples[0]
    if !hasPrev {
      prev = current
      hasPrev = true
      idx = 1
      if idx >= samples.count {
        return int16Data([Self.q(current)])
      }
      current = samples[idx]
    }
    while true {
      while phase >= 1 {
        prev = current
        idx += 1
        if idx >= samples.count {
          phase -= 1
          // Keep leftover phase for the next buffer.
          return int16Data(out)
        }
        current = samples[idx]
        phase -= 1
      }
      let mixed = prev + Float(phase) * (current - prev)
      out.append(Self.q(mixed))
      phase += step
    }
  }

  private func int16Data(_ samples: [Int16]) -> Data {
    if samples.isEmpty { return Data() }
    return samples.withUnsafeBufferPointer { Data(buffer: $0) }
  }

  private static func q(_ v: Float) -> Int16 {
    let clipped = max(-1.0, min(1.0, v))
    let scaled = Int(clipped * 32767.0)
    return Int16(clamping: scaled)
  }
}
