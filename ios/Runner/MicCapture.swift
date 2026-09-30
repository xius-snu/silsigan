import AVFoundation
import Flutter
import UIKit

private let kMicMethodChannel = "com.silsigan.app/mic_capture"
private let kMicEventChannel = "com.silsigan.app/mic_capture/pcm"
/// AVAudioSession's '!pri': another app (a call, a recorder) holds higher
/// recording priority. Compared as the raw OSStatus so this never depends on
/// how the SDK names the error enum.
private let kInsufficientPriority = 0x2170_7269

private var gMicCapture: MicCapture?

func RegisterMicCapture(messenger: FlutterBinaryMessenger) {
  gMicCapture?.shutdown()
  gMicCapture = MicCapture(messenger: messenger)
}

/// iPhone / iPad microphone capture: AVAudioEngine input converted to
/// interleaved PCM16 at the rate Dart asks for, streamed on an EventChannel.
///
/// Replaces flutter_sound's iOS stream recorder, which failed silently and
/// left the record button on Stop with no audio behind it (seen on iPad). It
/// ignored `AVAudioEngine.start` errors and reported success anyway. It built
/// its sample-rate converter from an input format read before the engine
/// started, so when the hardware settled on another format every buffer
/// failed conversion and was dropped. It also never handled configuration
/// changes, interruptions or media-services resets, after which the engine
/// had stopped itself and the tap stayed quiet for good. Here each of those
/// is healed in place or reported:
///
/// - start failures (session activation, engine start, no input route)
///   throw back through the method channel;
/// - the converter follows every tap buffer's own format;
/// - a configuration change, an ended interruption, a media-services reset,
///   or a tap that goes quiet for `stallTimeout` rebuilds the engine, at most
///   `maxRebuilds` times per `rebuildWindow`;
/// - past that, `MIC_LOST` goes to Dart, which restarts capture or ends the
///   session with a message.
final class MicCapture: NSObject, FlutterStreamHandler {
  /// 100 ms at 48 kHz — the floor of AVAudioNode's supported tap range.
  private static let tapBufferFrames: AVAudioFrameCount = 4800
  private static let stallTimeout: CFTimeInterval = 2.0
  private static let rebuildWindow: CFTimeInterval = 10
  private static let maxRebuilds = 3

  private var methodChannel: FlutterMethodChannel?
  private var eventChannel: FlutterEventChannel?
  private var sink: FlutterEventSink?
  private var observers: [NSObjectProtocol] = []

  private var engine: AVAudioEngine?
  private var outputFormat: AVAudioFormat?
  /// Dart started capture and has not stopped it (also cleared on give-up).
  private var wantRunning = false
  /// An interruption (call, Siri, alarm) holds the session. The system has
  /// already stopped the engine, and a rebuild only fails until it ends.
  private var interrupted = false
  /// Bumped per engine and on stop, so buffers an old engine already queued
  /// to the main thread never reach Dart after a stop or a rebuild.
  private var generation = 0
  /// Main-thread time of the last delivered buffer (or of the last start).
  private var lastBufferAt: CFTimeInterval = 0
  private var rebuildTimes: [CFTimeInterval] = []
  private var pendingRebuild: DispatchWorkItem?
  private var watchdog: Timer?

  init(messenger: FlutterBinaryMessenger) {
    super.init()
    let methods = FlutterMethodChannel(name: kMicMethodChannel, binaryMessenger: messenger)
    methods.setMethodCallHandler { [weak self] call, result in
      self?.handle(call, result: result)
    }
    methodChannel = methods
    let events = FlutterEventChannel(name: kMicEventChannel, binaryMessenger: messenger)
    events.setStreamHandler(self)
    eventChannel = events
    observeSession()
  }

  func shutdown() {
    stopCapture()
    for observer in observers {
      NotificationCenter.default.removeObserver(observer)
    }
    observers.removeAll()
    methodChannel?.setMethodCallHandler(nil)
    methodChannel = nil
    eventChannel?.setStreamHandler(nil)
    eventChannel = nil
    sink = nil
  }

  // MARK: - FlutterStreamHandler

  func onListen(
    withArguments arguments: Any?,
    eventSink events: @escaping FlutterEventSink
  ) -> FlutterError? {
    sink = events
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    sink = nil
    return nil
  }

  // MARK: - Method channel

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "start":
      let args = call.arguments as? [String: Any]
      let sampleRate = (args?["sampleRate"] as? NSNumber)?.doubleValue ?? 24_000
      let channels = (args?["channels"] as? NSNumber)?.uint32Value ?? 1
      do {
        try start(sampleRate: sampleRate, channels: channels, route: args)
        result(nil)
      } catch {
        result(Self.flutterError(error))
      }
    case "stop":
      stopCapture()
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private static func flutterError(_ error: Error) -> FlutterError {
    if let capture = error as? MicCaptureError {
      return FlutterError(
        code: capture == .noInput ? "MIC_UNAVAILABLE" : "MIC_START_FAILED",
        message: capture.errorDescription,
        details: nil
      )
    }
    let ns = error as NSError
    return FlutterError(
      code: ns.code == kInsufficientPriority ? "MIC_BUSY" : "MIC_START_FAILED",
      message: ns.localizedDescription,
      details: "\(ns.domain) \(ns.code)"
    )
  }

  // MARK: - Lifecycle

  private func start(sampleRate: Double, channels: UInt32, route: [String: Any]?) throws {
    stopCapture()
    guard let format = AVAudioFormat(
      commonFormat: .pcmFormatInt16,
      sampleRate: sampleRate,
      channels: AVAudioChannelCount(channels),
      interleaved: true
    ) else {
      throw MicCaptureError.unsupportedFormat
    }
    outputFormat = format
    CaptureAudioRoute.updatePreferences(route)
    do {
      // Session first: the engine has to be built against the input route
      // it will actually capture from.
      try CaptureAudioRoute.prepareForCapture(checkRoute: true)
      try startEngine()
    } catch {
      teardownEngine()
      throw error
    }
    wantRunning = true
    rebuildTimes.removeAll()
    startWatchdog()
  }

  private func stopCapture() {
    wantRunning = false
    interrupted = false
    pendingRebuild?.cancel()
    pendingRebuild = nil
    watchdog?.invalidate()
    watchdog = nil
    teardownEngine()
  }

  // MARK: - Engine

  private func startEngine() throws {
    guard let outputFormat else { throw MicCaptureError.unsupportedFormat }
    guard AVAudioSession.sharedInstance().isInputAvailable else {
      throw MicCaptureError.noInput
    }
    let engine = AVAudioEngine()
    let input = engine.inputNode
    let hardware = input.outputFormat(forBus: 0)
    // 0 Hz / 0 channels: no usable input route. A tap on it never fires.
    guard hardware.sampleRate > 0, hardware.channelCount > 0 else {
      throw MicCaptureError.noInput
    }
    generation += 1
    let gen = generation
    let converter = PcmConverter(output: outputFormat)
    // format: nil taps whatever the hardware delivers. PcmConverter follows
    // each buffer's own format, so there is no format snapshot to go stale.
    input.installTap(onBus: 0, bufferSize: Self.tapBufferFrames, format: nil) { [weak self] buffer, _ in
      guard let data = converter.convert(buffer) else { return }
      DispatchQueue.main.async {
        self?.deliver(data, generation: gen)
      }
    }
    engine.prepare()
    do {
      try engine.start()
    } catch {
      input.removeTap(onBus: 0)
      throw error
    }
    self.engine = engine
    lastBufferAt = CACurrentMediaTime()
  }

  private func teardownEngine() {
    generation += 1
    guard let engine else { return }
    self.engine = nil
    engine.inputNode.removeTap(onBus: 0)
    engine.stop()
  }

  private func deliver(_ data: Data, generation gen: Int) {
    guard gen == generation, wantRunning else { return }
    lastBufferAt = CACurrentMediaTime()
    // A rebuild that brought audio back for good stops counting against the
    // budget. Only rebuilds that keep failing to deliver should run it out,
    // not a headset that flaps its route a few times in a minute.
    if let last = rebuildTimes.last, lastBufferAt - last > Self.stallTimeout {
      rebuildTimes.removeAll()
    }
    if interrupted {
      // Buffers flowing means the interruption is over, even if iOS never
      // posted its .ended.
      interrupted = false
      sink?(["interrupted": false])
    }
    sink?(FlutterStandardTypedData(bytes: data))
  }

  // MARK: - Recovery

  /// Every observer runs on the posting thread (`queue: nil`) and hops to
  /// main itself. With `queue: .main`, NotificationCenter blocks the posting
  /// thread until the block has run on main. For the engine notification
  /// that thread is AVAudioEngine's internal queue, while main may be inside
  /// that engine's stop / start / dealloc waiting on the same queue, which
  /// deadlocks. AVAudioEngine.h warns about exactly this.
  private func observeSession() {
    let center = NotificationCenter.default
    observers.append(center.addObserver(
      forName: .AVAudioEngineConfigurationChange,
      object: nil,
      queue: nil
    ) { [weak self] note in
      // The hardware sample rate or channel count changed (headset, AirPods,
      // a route re-pin) and the engine has already stopped itself.
      let changed = note.object as? AVAudioEngine
      DispatchQueue.main.async {
        guard let self, let changed, changed === self.engine else { return }
        self.scheduleRebuild(after: 0.25)
      }
    })
    observers.append(center.addObserver(
      forName: AVAudioSession.interruptionNotification,
      object: nil,
      queue: nil
    ) { [weak self] note in
      let info = note.userInfo
      DispatchQueue.main.async {
        self?.handleInterruption(info)
      }
    })
    observers.append(center.addObserver(
      forName: AVAudioSession.mediaServicesWereResetNotification,
      object: nil,
      queue: nil
    ) { [weak self] _ in
      DispatchQueue.main.async {
        // mediaserverd restarted: every engine is invalid. Drop ours without
        // calling into it and build a fresh one.
        guard let self, self.wantRunning else { return }
        self.generation += 1
        self.engine = nil
        self.interrupted = false
        self.scheduleRebuild(after: 0.5)
      }
    })
  }

  /// Dart hears about interruptions (as `{"interrupted": Bool}` events on the
  /// PCM stream) so its own stall check leaves recovery to .ended instead of
  /// restarting into a call that still holds the mic.
  private func handleInterruption(_ info: [AnyHashable: Any]?) {
    guard wantRunning,
          let raw = info?[AVAudioSessionInterruptionTypeKey] as? UInt,
          let type = AVAudioSession.InterruptionType(rawValue: raw)
    else { return }
    switch type {
    case .began:
      interrupted = true
      pendingRebuild?.cancel()
      pendingRebuild = nil
      sink?(["interrupted": true])
    case .ended:
      interrupted = false
      rebuildTimes.removeAll()
      sink?(["interrupted": false])
      scheduleRebuild(after: 0.3)
    @unknown default:
      break
    }
  }

  private func scheduleRebuild(after delay: TimeInterval) {
    guard wantRunning, !interrupted else { return }
    pendingRebuild?.cancel()
    let work = DispatchWorkItem { [weak self] in
      self?.rebuild()
    }
    pendingRebuild = work
    DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
  }

  private var isHealthy: Bool {
    guard let engine, engine.isRunning else { return false }
    return CACurrentMediaTime() - lastBufferAt <= Self.stallTimeout
  }

  private func rebuild() {
    pendingRebuild = nil
    guard wantRunning, !interrupted else { return }
    // Stale triggers must not tear down capture that works: a watchdog tick
    // that ran ahead of buffers queued behind a busy main thread, or an
    // .ended for an interruption that never stopped the engine. A real
    // configuration change or media reset has already stopped or dropped
    // the engine, so it still rebuilds.
    if isHealthy { return }
    let now = CACurrentMediaTime()
    rebuildTimes = rebuildTimes.filter { now - $0 < Self.rebuildWindow }
    if rebuildTimes.count >= Self.maxRebuilds {
      giveUp()
      return
    }
    rebuildTimes.append(now)
    teardownEngine()
    do {
      // No live-route re-pin here: a re-pin can itself change the hardware
      // format and post the next configuration change.
      try CaptureAudioRoute.prepareForCapture(checkRoute: false)
      try startEngine()
    } catch {
      scheduleRebuild(after: 1.0)
    }
  }

  /// Out of in-place retries. Dart restarts capture from scratch or ends the
  /// session with a message, instead of leaving it "recording" silence.
  private func giveUp() {
    wantRunning = false
    pendingRebuild?.cancel()
    pendingRebuild = nil
    watchdog?.invalidate()
    watchdog = nil
    teardownEngine()
    sink?(FlutterError(
      code: "MIC_LOST",
      message: "The microphone stopped delivering audio.",
      details: nil
    ))
  }

  private func startWatchdog() {
    watchdog?.invalidate()
    let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
      self?.checkStall()
    }
    RunLoop.main.add(timer, forMode: .common)
    watchdog = timer
  }

  /// A tap that stops firing with no notification at all (reported after
  /// interruptions on some devices), or an engine that is no longer running,
  /// gets the same rebuild as a configuration change.
  private func checkStall() {
    guard wantRunning, !interrupted, pendingRebuild == nil, !isHealthy else { return }
    scheduleRebuild(after: 0.1)
  }
}

private enum MicCaptureError: LocalizedError {
  case unsupportedFormat
  case noInput

  var errorDescription: String? {
    switch self {
    case .unsupportedFormat:
      return "Unsupported capture format"
    case .noInput:
      return "No microphone input is available"
    }
  }
}

/// Converts tap buffers (whatever the hardware delivers, usually Float32 at
/// 44.1 or 48 kHz with one or more channels) to interleaved PCM16 at the
/// requested rate. The converter is rebuilt whenever the incoming format
/// changes. Runs on the tap thread.
private final class PcmConverter {
  private let output: AVAudioFormat
  private var converter: AVAudioConverter?
  private var inputFormat: AVAudioFormat?
  private let lock = NSLock()

  init(output: AVAudioFormat) {
    self.output = output
  }

  func convert(_ buffer: AVAudioPCMBuffer) -> Data? {
    lock.lock()
    defer { lock.unlock() }
    let frames = buffer.frameLength
    guard frames > 0, buffer.format.sampleRate > 0 else { return nil }
    if converter == nil || inputFormat != buffer.format {
      guard let fresh = AVAudioConverter(from: buffer.format, to: output) else {
        return nil
      }
      converter = fresh
      inputFormat = buffer.format
    }
    guard let converter else { return nil }
    let ratio = output.sampleRate / buffer.format.sampleRate
    let capacity = AVAudioFrameCount((Double(frames) * ratio).rounded(.up)) + 32
    guard let out = AVAudioPCMBuffer(pcmFormat: output, frameCapacity: capacity) else {
      return nil
    }
    // Hand the buffer over once, then report "no data now" rather than end
    // of stream, so the resampler keeps its state across tap callbacks.
    var consumed = false
    var error: NSError?
    let status = converter.convert(to: out, error: &error) { _, outStatus in
      if consumed {
        outStatus.pointee = .noDataNow
        return nil
      }
      consumed = true
      outStatus.pointee = .haveData
      return buffer
    }
    guard status != .error, out.frameLength > 0, let samples = out.int16ChannelData else {
      return nil
    }
    let byteCount = Int(out.frameLength) * Int(output.channelCount) * MemoryLayout<Int16>.size
    return Data(bytes: samples[0], count: byteCount)
  }
}
