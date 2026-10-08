import CoreAudio
import CoreGraphics
import CoreMedia
import FlutterMacOS
import Foundation
import ScreenCaptureKit

/// WASAPI-compatible MethodChannel for macOS.
/// Channel `com.silsigan.app/desktop_audio` — listDevices / startLoopback /
/// stopLoopback / readLoopback. Dart pulls PCM16 / 24 kHz / mono via
/// readLoopback (not an EventSink), matching windows/runner/desktop_audio_capture.cpp.
///
/// System audio uses ScreenCaptureKit (macOS 13+) with capturesAudio. There is
/// no per-output-device loopback, so outputs is a single "System audio" entry.

private let kChannelName = "com.silsigan.app/desktop_audio"
private let kDstRate: Double = 24_000
private let kMaxPendingBytes = Int(kDstRate) * 2 * 2  // 2 seconds of PCM16 mono
private let kSystemAudioId = "system"
private let kSystemAudioLabel = "System audio"

private var gPlugin: DesktopAudioCapturePlugin?

func RegisterDesktopAudioCapture(messenger: FlutterBinaryMessenger) {
  UnregisterDesktopAudioCapture()
  gPlugin = DesktopAudioCapturePlugin(messenger: messenger)
}

func UnregisterDesktopAudioCapture() {
  gPlugin?.shutdown()
  gPlugin = nil
}

private final class DesktopAudioCapturePlugin: NSObject {
  private var channel: FlutterMethodChannel?
  private let session = LoopbackSession()
  // Held while a recording runs. A hands-off session (a lecture, a meeting
  // in another window) gives macOS no reason to keep the app awake, and App
  // Nap then throttles its timers and sockets: audio reached the server in
  // bursts with gaps long enough for the stream to time out.
  private var keepAwake: NSObjectProtocol?

  init(messenger: FlutterBinaryMessenger) {
    super.init()
    let channel = FlutterMethodChannel(
      name: kChannelName,
      binaryMessenger: messenger
    )
    channel.setMethodCallHandler { [weak self] call, result in
      self?.handle(call, result: result)
    }
    self.channel = channel
  }

  func shutdown() {
    session.stop()
    setKeepAwake(false)
    channel?.setMethodCallHandler(nil)
    channel = nil
  }

  private func setKeepAwake(_ on: Bool) {
    if on {
      guard keepAwake == nil else { return }
      keepAwake = ProcessInfo.processInfo.beginActivity(
        options: [.userInitiated, .idleSystemSleepDisabled],
        reason: "Recording and translating audio"
      )
    } else if let activity = keepAwake {
      ProcessInfo.processInfo.endActivity(activity)
      keepAwake = nil
    }
  }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "listDevices":
      result(listDevices())
    case "startLoopback":
      let args = call.arguments as? [String: Any]
      let deviceId = args?["deviceId"] as? String
      session.start(deviceId: deviceId, result: result)
    case "stopLoopback":
      session.stop()
      result(nil)
    case "readLoopback":
      result(FlutterStandardTypedData(bytes: session.takePending()))
    case "setKeepAwake":
      let args = call.arguments as? [String: Any]
      setKeepAwake(args?["on"] as? Bool ?? false)
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func listDevices() -> [String: Any] {
    [
      "inputs": listInputDevices(),
      "outputs": [
        [
          "id": kSystemAudioId,
          "label": kSystemAudioLabel,
          "isDefault": true,
        ],
      ],
    ]
  }
}

// MARK: - Core Audio inputs

private func listInputDevices() -> [[String: Any]] {
  var address = AudioObjectPropertyAddress(
    mSelector: kAudioHardwarePropertyDevices,
    mScope: kAudioObjectPropertyScopeGlobal,
    mElement: kAudioObjectPropertyElementMain
  )
  var dataSize: UInt32 = 0
  let sys = AudioObjectID(kAudioObjectSystemObject)
  guard AudioObjectGetPropertyDataSize(sys, &address, 0, nil, &dataSize) == noErr,
        dataSize > 0
  else {
    return []
  }
  let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
  var ids = [AudioDeviceID](repeating: 0, count: count)
  guard AudioObjectGetPropertyData(sys, &address, 0, nil, &dataSize, &ids) == noErr else {
    return []
  }

  var defaultId: AudioDeviceID = 0
  var defaultAddress = AudioObjectPropertyAddress(
    mSelector: kAudioHardwarePropertyDefaultInputDevice,
    mScope: kAudioObjectPropertyScopeGlobal,
    mElement: kAudioObjectPropertyElementMain
  )
  var defaultSize = UInt32(MemoryLayout<AudioDeviceID>.size)
  _ = AudioObjectGetPropertyData(sys, &defaultAddress, 0, nil, &defaultSize, &defaultId)

  var devices: [[String: Any]] = []
  for id in ids {
    guard inputChannelCount(id) > 0 else { continue }
    let uid = stringProperty(id, kAudioDevicePropertyDeviceUID) ?? "id-\(id)"
    let label = stringProperty(id, kAudioDevicePropertyDeviceNameCFString) ?? uid
    devices.append([
      "id": uid,
      "label": label,
      "isDefault": id == defaultId,
    ])
  }
  return devices
}

private func stringProperty(_ device: AudioDeviceID, _ selector: AudioObjectPropertySelector)
  -> String?
{
  var address = AudioObjectPropertyAddress(
    mSelector: selector,
    mScope: kAudioObjectPropertyScopeGlobal,
    mElement: kAudioObjectPropertyElementMain
  )
  var dataSize: UInt32 = 0
  guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &dataSize) == noErr,
        dataSize > 0
  else {
    return nil
  }
  var cf: CFString?
  var size = UInt32(MemoryLayout<CFString?>.size)
  guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &cf) == noErr,
        let cf
  else {
    return nil
  }
  return cf as String
}

private func inputChannelCount(_ device: AudioDeviceID) -> Int {
  var address = AudioObjectPropertyAddress(
    mSelector: kAudioDevicePropertyStreamConfiguration,
    mScope: kAudioDevicePropertyScopeInput,
    mElement: kAudioObjectPropertyElementMain
  )
  var dataSize: UInt32 = 0
  guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &dataSize) == noErr,
        dataSize > 0
  else {
    return 0
  }
  let raw = UnsafeMutableRawPointer.allocate(
    byteCount: Int(dataSize),
    alignment: MemoryLayout<AudioBufferList>.alignment
  )
  defer { raw.deallocate() }
  guard AudioObjectGetPropertyData(device, &address, 0, nil, &dataSize, raw) == noErr else {
    return 0
  }
  let abl = UnsafeMutableAudioBufferListPointer(
    raw.bindMemory(to: AudioBufferList.self, capacity: 1)
  )
  return abl.reduce(0) { $0 + Int($1.mNumberChannels) }
}

// MARK: - Loopback session (ScreenCaptureKit)

private enum LoopbackError: LocalizedError {
  case unsupported
  case permission
  case failed(String)

  var errorDescription: String? {
    switch self {
    case .unsupported:
      return "System audio capture requires macOS 13 or later."
    case .permission:
      return
        "Screen Recording permission is required to capture system audio. Enable Silsigan in System Settings → Privacy & Security → Screen Recording, then start again."
    case .failed(let message):
      return message
    }
  }
}

private final class LoopbackSession: NSObject, SCStreamOutput, SCStreamDelegate {
  private let lock = NSLock()
  private let audioQueue = DispatchQueue(label: "com.silsigan.app.desktop-audio")
  private var stream: SCStream?
  private var pending = Data()
  private var converter = LoopbackConverter()
  // Main thread only, like start() and stop().
  private var startGeneration = 0
  // Between start and stop the capture should be running. ScreenCaptureKit
  // can stop a stream on its own (display reconfigured or asleep, capture
  // service interrupted). That used to end system audio silently for the
  // rest of the recording; the session now restarts it.
  private var wantRunning = false
  private var restartScheduled = false
  private var restartDelay: TimeInterval = 1

  /// SCStreamError.userStopped (macOS 14+): the user ended the capture from
  /// the menu bar. That one is theirs to make, so it isn't undone.
  private static let userStoppedCode = -3817

  func start(deviceId _: String?, result: @escaping FlutterResult) {
    if #unavailable(macOS 13.0) {
      result(
        FlutterError(
          code: "loopback_start_failed",
          message: LoopbackError.unsupported.localizedDescription,
          details: nil
        )
      )
      return
    }
    stop()
    startGeneration += 1
    let gen = startGeneration
    wantRunning = true
    restartDelay = 1
    Task {
      do {
        let started = try await self.beginCapture(requestAccess: true)
        DispatchQueue.main.async {
          // Stopped while starting: don't leave this stream running.
          if gen != self.startGeneration { self.discard(started) }
          result(nil)
        }
      } catch {
        DispatchQueue.main.async {
          if gen != self.startGeneration {
            result(nil)
            return
          }
          self.wantRunning = false
          result(
            FlutterError(
              code: "loopback_start_failed",
              message: error.localizedDescription,
              details: nil
            )
          )
        }
      }
    }
  }

  func stop() {
    startGeneration += 1
    wantRunning = false
    lock.lock()
    let existing = stream
    stream = nil
    pending = Data()
    converter.reset()
    lock.unlock()
    existing?.stopCapture { _ in }
  }

  private func discard(_ stream: SCStream) {
    lock.lock()
    if self.stream === stream { self.stream = nil }
    lock.unlock()
    stream.stopCapture { _ in }
  }

  /// Main thread. Retries with a growing delay (1 s up to 10 s) until a
  /// restart works or the session stops.
  private func scheduleRestart() {
    guard wantRunning, !restartScheduled else { return }
    restartScheduled = true
    let gen = startGeneration
    let delay = restartDelay
    restartDelay = min(restartDelay * 2, 10)
    DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
      guard let self else { return }
      self.restartScheduled = false
      guard self.wantRunning, gen == self.startGeneration else { return }
      self.lock.lock()
      let running = self.stream != nil
      self.lock.unlock()
      guard !running else { return }
      Task {
        do {
          // No permission prompt from here: the user is mid-recording.
          let started = try await self.beginCapture(requestAccess: false)
          DispatchQueue.main.async {
            if gen != self.startGeneration || !self.wantRunning {
              self.discard(started)
            } else {
              self.restartDelay = 1
            }
          }
        } catch {
          DispatchQueue.main.async { self.scheduleRestart() }
        }
      }
    }
  }

  func takePending() -> Data {
    lock.lock()
    defer { lock.unlock() }
    let out = pending
    pending = Data()
    return out
  }

  @available(macOS 13.0, *)
  private func beginCapture(requestAccess: Bool) async throws -> SCStream {
    if requestAccess && !CGPreflightScreenCaptureAccess() {
      _ = CGRequestScreenCaptureAccess()
    }

    let content: SCShareableContent
    do {
      content = try await SCShareableContent.excludingDesktopWindows(
        false,
        onScreenWindowsOnly: true
      )
    } catch {
      throw LoopbackError.permission
    }
    guard let display = content.displays.first else {
      throw LoopbackError.failed("No display available for system-audio capture.")
    }

    let filter = SCContentFilter(display: display, excludingWindows: [])
    let config = SCStreamConfiguration()
    config.capturesAudio = true
    config.excludesCurrentProcessAudio = true
    config.sampleRate = 48_000
    config.channelCount = 2
    // Dummy video surface — ScreenCaptureKit is a screen API; we only keep audio.
    config.width = 2
    config.height = 2
    config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
    config.showsCursor = false
    config.queueDepth = 3

    let stream = SCStream(filter: filter, configuration: config, delegate: self)
    try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: audioQueue)

    lock.lock()
    self.stream = stream
    converter.reset()
    pending = Data()
    lock.unlock()

    do {
      try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
        stream.startCapture { error in
          if let error {
            cont.resume(throwing: error)
          } else {
            cont.resume()
          }
        }
      }
    } catch {
      lock.lock()
      if self.stream === stream { self.stream = nil }
      lock.unlock()
      stream.stopCapture { _ in }
      if !CGPreflightScreenCaptureAccess() {
        throw LoopbackError.permission
      }
      throw LoopbackError.failed(error.localizedDescription)
    }
    return stream
  }

  func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
    guard type == .audio else { return }
    append(sampleBuffer: sampleBuffer)
  }

  func stream(_ stream: SCStream, didStopWithError error: Error) {
    lock.lock()
    let current = self.stream === stream
    if current { self.stream = nil }
    lock.unlock()
    guard current, (error as NSError).code != Self.userStoppedCode else { return }
    DispatchQueue.main.async { [weak self] in self?.scheduleRestart() }
  }

  private func append(sampleBuffer: CMSampleBuffer) {
    guard let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer),
          let asbdPtr = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc)
    else {
      return
    }
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
    guard sizeNeeded > 0 else { return }

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
    _ = blockBuffer  // retain until the list is consumed

    var converted = Data()
    converted.reserveCapacity(frames * 2)
    lock.lock()
    converter.convert(
      abl: UnsafeMutableAudioBufferListPointer(abl),
      frames: frames,
      asbd: asbd,
      into: &converted
    )
    if !converted.isEmpty {
      pending.append(converted)
      if pending.count > kMaxPendingBytes {
        let drop = pending.count - kMaxPendingBytes
        let evenDrop = drop + (drop % 2)
        if evenDrop < pending.count {
          pending.removeSubrange(0..<evenDrop)
        }
      }
    }
    lock.unlock()
  }
}

// MARK: - PCM converter (float/int → 24 kHz mono s16)

private struct LoopbackConverter {
  private var srcRate: Double = 48_000
  private var frac: Double = 0
  private var prev: Float = 0
  private var hasPrev = false

  mutating func reset() {
    srcRate = 48_000
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
    srcRate = asbd.mSampleRate > 0 ? asbd.mSampleRate : 48_000
    let channels = max(Int(asbd.mChannelsPerFrame), 1)
    let bits = Int(asbd.mBitsPerChannel)
    let isFloat = (asbd.mFormatFlags & kAudioFormatFlagIsFloat) != 0
    let nonInterleaved = (asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0
    let bytesPer = max(bits / 8, 1)

    var mono = [Float](repeating: 0, count: frames)
    if nonInterleaved {
      let nBuf = min(abl.count, channels)
      guard nBuf > 0 else { return }
      for f in 0..<frames {
        var acc: Float = 0
        for c in 0..<nBuf {
          guard let data = abl[c].mData else { continue }
          acc += readSample(
            data: data,
            byteOffset: f * bytesPer,
            isFloat: isFloat,
            bits: bits
          )
        }
        mono[f] = acc / Float(nBuf)
      }
    } else {
      guard abl.count > 0, let data = abl[0].mData else {
        mono = [Float](repeating: 0, count: frames)
        resample(mono, into: &out)
        return
      }
      for f in 0..<frames {
        var acc: Float = 0
        for c in 0..<channels {
          acc += readSample(
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

  private func readSample(data: UnsafeMutableRawPointer, byteOffset: Int, isFloat: Bool, bits: Int)
    -> Float
  {
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
    if srcRate == kDstRate {
      for s in mono {
        appendS16(floatToS16(s), into: &out)
      }
      return
    }
    let step = srcRate / kDstRate
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
      appendS16(floatToS16(s0 + Float(t) * (s1 - s0)), into: &out)
      frac += step
    }
    prev = mono[n - 1]
    hasPrev = true
    frac -= Double(n)
  }

  private func floatToS16(_ x: Float) -> Int16 {
    let c = max(-1.0, min(1.0, x))
    return Int16(c * 32767.0)
  }

  private func appendS16(_ v: Int16, into out: inout Data) {
    var le = v.littleEndian
    withUnsafeBytes(of: &le) { out.append(contentsOf: $0) }
  }
}