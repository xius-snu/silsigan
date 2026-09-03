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
  private var converter = Pcm24kConverter()
  private var lastBeat: Date = .distantPast
  private var finishing = false
  private var stopPoll: DispatchSourceTimer?
  private var stopObserver: UnsafeRawPointer?

  override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {
    BroadcastIPC.clearStop()
    _ = ring.open(create: true)
    ring.reset()
    converter.reset()
    finishing = false
    BroadcastIPC.setRunning(true)
    BroadcastIPC.post(BroadcastIPC.startedNotification)
    installStopObserver()
    startStopPoll()
  }

  override func broadcastPaused() {}

  override func broadcastResumed() {}

  override func broadcastFinished() {
    tearDownIpc()
  }

  override func processSampleBuffer(_ sampleBuffer: CMSampleBuffer, with sampleBufferType: RPSampleBufferType) {
    if shouldStop() {
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

  private func shouldStop() -> Bool {
    finishing || ring.isStopRequested() || BroadcastIPC.stopRequested()
  }

  private func finishQuietly() {
    let work = { [self] in
      if finishing { return }
      finishing = true
      tearDownIpc()
      // userDeclined dismisses the broadcast without a red error banner.
      let error = NSError(
        domain: RPRecordingErrorDomain,
        code: RPRecordingErrorCode.userDeclined.rawValue,
        userInfo: [NSLocalizedDescriptionKey: "Stopped"]
      )
      finishBroadcastWithError(error)
    }
    if Thread.isMainThread {
      work()
    } else {
      DispatchQueue.main.async(execute: work)
    }
  }

  private func tearDownIpc() {
    stopPoll?.cancel()
    stopPoll = nil
    removeStopObserver()
    BroadcastIPC.setRunning(false)
    BroadcastIPC.post(BroadcastIPC.stoppedNotification)
    ring.close()
  }

  private func installStopObserver() {
    guard stopObserver == nil else { return }
    let callback: CFNotificationCallback = { _, observer, _, _, _ in
      guard let observer else { return }
      let me = Unmanaged<SampleHandler>.fromOpaque(observer).takeUnretainedValue()
      me.finishQuietly()
    }
    let ptr = Unmanaged.passUnretained(self).toOpaque()
    stopObserver = UnsafeRawPointer(ptr)
    CFNotificationCenterAddObserver(
      CFNotificationCenterGetDarwinNotifyCenter(),
      ptr,
      callback,
      BroadcastIPC.stopNotification,
      nil,
      .deliverImmediately
    )
  }

  private func removeStopObserver() {
    guard let ptr = stopObserver else { return }
    CFNotificationCenterRemoveEveryObserver(
      CFNotificationCenterGetDarwinNotifyCenter(),
      ptr
    )
    stopObserver = nil
  }

  private func startStopPoll() {
    stopPoll?.cancel()
    let timer = DispatchSource.makeTimerSource(queue: .main)
    timer.schedule(deadline: .now() + 0.1, repeating: 0.1)
    timer.setEventHandler { [weak self] in
      guard let self, self.shouldStop() else { return }
      self.finishQuietly()
    }
    timer.resume()
    stopPoll = timer
  }

  /// ReplayKit `audioApp` is typically stereo Float32 *non-interleaved*.
  /// `CMSampleBufferGetDataBuffer` is often nil for that layout — use the
  /// AudioBufferList path (same as the macOS ScreenCaptureKit reader).
  private func writeAudio(_ sampleBuffer: CMSampleBuffer) {
    guard let format = CMSampleBufferGetFormatDescription(sampleBuffer),
          let asbdPtr = CMAudioFormatDescriptionGetStreamBasicDescription(format)
    else { return }
    let asbd = asbdPtr.pointee
    let frames = CMSampleBufferGetNumSamples(sampleBuffer)
    guard frames > 0 else { return }

    var sizeNeeded = 0
    _ = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
      sampleBuffer,
      bufferListSizeNeededOut: &sizeNeeded,
      bufferListOut: nil,
      bufferListSize: 0,
      blockBufferAllocator: nil,
      blockBufferMemoryAllocator: nil,
      flags: 0,
      blockBufferOut: nil
    )
    if sizeNeeded > 0 {
      let raw = UnsafeMutableRawPointer.allocate(byteCount: sizeNeeded, alignment: 16)
      defer { raw.deallocate() }
      raw.initializeMemory(as: UInt8.self, repeating: 0, count: sizeNeeded)
      let abl = raw.bindMemory(to: AudioBufferList.self, capacity: 1)
      var blockBuffer: CMBlockBuffer?
      let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
        sampleBuffer,
        bufferListSizeNeededOut: nil,
        bufferListOut: abl,
        bufferListSize: sizeNeeded,
        blockBufferAllocator: kCFAllocatorDefault,
        blockBufferMemoryAllocator: kCFAllocatorDefault,
        flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
        blockBufferOut: &blockBuffer
      )
      guard status == noErr else { return }
      _ = blockBuffer
      var pcm = Data()
      pcm.reserveCapacity(frames * 2)
      converter.convert(
        abl: UnsafeMutableAudioBufferListPointer(abl),
        frames: frames,
        asbd: asbd,
        into: &pcm
      )
      if !pcm.isEmpty {
        ring.write(pcm)
      }
      return
    }

    // Rare interleaved fallback when the list query reports no size.
    guard let block = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }
    let length = CMBlockBufferGetDataLength(block)
    if length <= 0 { return }
    var bytes = Data(count: length)
    let copy = bytes.withUnsafeMutableBytes { raw -> OSStatus in
      guard let base = raw.baseAddress else { return -1 }
      return CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: base)
    }
    guard copy == noErr else { return }
    let pcm = converter.convertPacked(bytes: bytes, frames: frames, asbd: asbd)
    if !pcm.isEmpty {
      ring.write(pcm)
    }
  }
}

/// Linear-interpolation resampler to 24 kHz PCM16 mono. Handles the ReplayKit
/// layouts we actually see: Float32/Int16/Int32, interleaved or not.
private struct Pcm24kConverter {
  private let dstRate: Double = 24_000
  private var srcRate: Double = 44_100
  private var frac: Double = 0
  private var prev: Float = 0
  private var hasPrev = false

  mutating func reset() {
    srcRate = 44_100
    frac = 0
    prev = 0
    hasPrev = false
  }

  mutating func convert(
    abl: UnsafeMutableAudioBufferListPointer,
    frames: Int,
    asbd: AudioStreamBasicDescription,
    into out: inout Data
  ) {
    srcRate = asbd.mSampleRate > 0 ? asbd.mSampleRate : 44_100
    let channels = max(Int(asbd.mChannelsPerFrame), 1)
    var bits = Int(asbd.mBitsPerChannel)
    let isFloat = (asbd.mFormatFlags & kAudioFormatFlagIsFloat) != 0
    let nonInterleaved = (asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0
      || abl.count > 1
    if bits <= 0 {
      bits = isFloat ? 32 : 16
    }
    let bytesPer = max(bits / 8, 1)

    var mono = [Float](repeating: 0, count: frames)
    if nonInterleaved {
      let nBuf = min(abl.count, channels)
      guard nBuf > 0 else { return }
      for f in 0..<frames {
        var acc: Float = 0
        for c in 0..<nBuf {
          guard let data = abl[c].mData else { continue }
          acc += Self.readSample(
            data: data,
            byteOffset: f * bytesPer,
            isFloat: isFloat,
            bits: bits
          )
        }
        mono[f] = acc / Float(nBuf)
      }
    } else {
      guard abl.count > 0, let data = abl[0].mData else { return }
      for f in 0..<frames {
        var acc: Float = 0
        for c in 0..<channels {
          acc += Self.readSample(
            data: data,
            byteOffset: (f * channels + c) * bytesPer,
            isFloat: isFloat,
            bits: bits
          )
        }
        mono[f] = acc / Float(channels)
      }
    }
    resample(mono, into: &out)
  }

  mutating func convertPacked(
    bytes: Data,
    frames: Int,
    asbd: AudioStreamBasicDescription
  ) -> Data {
    srcRate = asbd.mSampleRate > 0 ? asbd.mSampleRate : 44_100
    let channels = max(Int(asbd.mChannelsPerFrame), 1)
    var bits = Int(asbd.mBitsPerChannel)
    let isFloat = (asbd.mFormatFlags & kAudioFormatFlagIsFloat) != 0
    if bits <= 0 { bits = isFloat ? 32 : 16 }
    let bytesPer = max(bits / 8, 1)
    var mono = [Float](repeating: 0, count: frames)
    bytes.withUnsafeBytes { raw in
      guard let base = raw.baseAddress else { return }
      for f in 0..<frames {
        var acc: Float = 0
        for c in 0..<channels {
          let offset = (f * channels + c) * bytesPer
          if offset + bytesPer > bytes.count { break }
          acc += Self.readSample(
            data: UnsafeMutableRawPointer(mutating: base),
            byteOffset: offset,
            isFloat: isFloat,
            bits: bits
          )
        }
        mono[f] = acc / Float(channels)
      }
    }
    var out = Data()
    out.reserveCapacity(frames * 2)
    resample(mono, into: &out)
    return out
  }

  private static func readSample(
    data: UnsafeMutableRawPointer,
    byteOffset: Int,
    isFloat: Bool,
    bits: Int
  ) -> Float {
    let ptr = data.advanced(by: byteOffset)
    if isFloat && bits == 32 {
      return ptr.load(as: Float.self)
    }
    if bits == 16 {
      return Float(ptr.load(as: Int16.self)) / 32768.0
    }
    if bits == 32 && !isFloat {
      return Float(ptr.load(as: Int32.self)) / 2_147_483_648.0
    }
    if bits == 24 {
      let p = ptr.assumingMemoryBound(to: UInt8.self)
      var s = Int32(p[0]) | (Int32(p[1]) << 8) | (Int32(p[2]) << 16)
      if (s & 0x800000) != 0 {
        s |= Int32(bitPattern: 0xFF00_0000)
      }
      return Float(s) / 8_388_608.0
    }
    return 0
  }

  private mutating func resample(_ mono: [Float], into out: inout Data) {
    if mono.isEmpty { return }
    if abs(srcRate - dstRate) < 0.5 {
      for s in mono {
        appendS16(Self.q(s), into: &out)
      }
      return
    }
    let step = srcRate / dstRate
    let n = mono.count
    while true {
      let srcIndex = frac
      let i0 = Int(srcIndex.rounded(.towardZero))
      let t = srcIndex - Double(i0)
      var s0: Float = 0
      var s1: Float = 0
      var have1 = false
      if i0 < 0 {
        if !hasPrev { break }
        s0 = prev
        if n > 0 {
          s1 = mono[0]
          have1 = true
        }
      } else if i0 >= n {
        break
      } else {
        s0 = mono[i0]
        if i0 + 1 < n {
          s1 = mono[i0 + 1]
          have1 = true
        }
      }
      if !have1 { break }
      appendS16(Self.q(s0 + Float(t) * (s1 - s0)), into: &out)
      frac += step
    }
    prev = mono[n - 1]
    hasPrev = true
    frac -= Double(n)
  }

  private func appendS16(_ v: Int16, into out: inout Data) {
    var le = v.littleEndian
    withUnsafeBytes(of: &le) { out.append(contentsOf: $0) }
  }

  private static func q(_ v: Float) -> Int16 {
    let clipped = max(-1.0, min(1.0, v))
    return Int16(clipped * 32767.0)
  }
}
