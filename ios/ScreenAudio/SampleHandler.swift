import AVFoundation
import CoreMedia
import ReplayKit

/// ReplayKit Broadcast Upload Extension. Converts `audioApp` sample buffers
/// (what the device is playing) to PCM16 / 24 kHz / mono and writes them into
/// the App Group ring the app drains through readLoopback.
///
/// ReplayKit hands app audio over as big-endian signed 16-bit PCM (1–2
/// channels, usually 44.1 kHz), unlike the mic's little-endian; Twilio's and
/// HaishinKit's ReplayKit notes document the same. The earlier hand-rolled
/// reader loaded those samples as little-endian, which turns any app's audio
/// into full-scale noise, so iPhone / iPad speaker capture never
/// transcribed anything. `AppAudioConverter` now builds the input format
/// from each buffer's own description and leaves endianness, sample type,
/// downmix and resampling to AVAudioConverter (the same route LiveKit's
/// broadcast audio takes).
///
/// Video buffers are ignored (the extension has a 50 MB memory limit).
/// `audioMic` is ignored too: the app records the microphone itself in Both
/// mode, and the picker's mic button is hidden.
class SampleHandler: RPBroadcastSampleHandler {
  /// Nobody reading the ring for this long means the app is gone (killed,
  /// or its session ended without a stop). End the broadcast rather than
  /// leave the red status-bar pill up with no one listening.
  private static let orphanTimeoutMs: UInt64 = 60_000

  private let ring = AudioRingBuffer()
  private let converter = AppAudioConverter()
  private var finishing = false
  private var startedAt = Date()
  private var tick: DispatchSourceTimer?
  private var stopObserver: UnsafeRawPointer?

  override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {
    _ = ring.open(create: true)
    ring.reset()
    ring.markRunning(true)
    finishing = false
    startedAt = Date()
    BroadcastIPC.post(BroadcastIPC.startedNotification)
    installStopObserver()
    startTick()
  }

  /// ReplayKit pauses the broadcast while the screen is locked, and this
  /// process may not get to beat meanwhile. The flag keeps the app from
  /// reading the silence as "the broadcast ended".
  override func broadcastPaused() {
    ring.markPaused(true)
  }

  override func broadcastResumed() {
    ring.markPaused(false)
  }

  override func broadcastFinished() {
    tearDownIpc()
  }

  override func processSampleBuffer(
    _ sampleBuffer: CMSampleBuffer,
    with sampleBufferType: RPSampleBufferType
  ) {
    guard sampleBufferType == .audioApp, !finishing else { return }
    if let pcm = converter.convert(sampleBuffer), !pcm.isEmpty {
      ring.write(pcm)
    }
  }

  /// Heartbeat + stop / orphan checks, off the sample path. Samples stop
  /// arriving entirely while nothing plays and the screen is static, so a
  /// beat tied to them made a live broadcast look dead to the app.
  private func startTick() {
    tick?.cancel()
    let timer = DispatchSource.makeTimerSource(queue: .main)
    timer.schedule(deadline: .now() + 0.1, repeating: 0.1)
    timer.setEventHandler { [weak self] in
      guard let self, !self.finishing else { return }
      self.ring.producerBeat()
      if self.ring.isStopRequested() {
        self.finishQuietly()
        return
      }
      if Date().timeIntervalSince(self.startedAt) > 60,
         self.ring.msSinceConsumerBeat() > Self.orphanTimeoutMs {
        self.finishQuietly()
      }
    }
    timer.resume()
    tick = timer
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
    tick?.cancel()
    tick = nil
    removeStopObserver()
    ring.markRunning(false)
    BroadcastIPC.post(BroadcastIPC.stoppedNotification)
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
}

/// ReplayKit app audio → interleaved PCM16 little-endian mono at 24 kHz.
/// The input format comes from each buffer's own stream description, and
/// the converter is rebuilt only when that description changes, so the
/// resampler keeps its state across buffers.
private final class AppAudioConverter {
  private let output = AVAudioFormat(
    commonFormat: .pcmFormatInt16,
    sampleRate: Double(BroadcastIPC.sampleRate),
    channels: 1,
    interleaved: true
  )
  private var inputFormat: AVAudioFormat?
  /// The description the converter was built from. Compared as ReplayKit
  /// reported it, not as AVAudioFormat may normalise it, so a steady stream
  /// never looks like a format change.
  private var inputDescription: AudioStreamBasicDescription?
  private var converter: AVAudioConverter?

  func convert(_ sampleBuffer: CMSampleBuffer) -> Data? {
    guard let output,
          let description = CMSampleBufferGetFormatDescription(sampleBuffer),
          let asbdPointer = CMAudioFormatDescriptionGetStreamBasicDescription(description)
    else { return nil }
    var asbd = asbdPointer.pointee
    guard asbd.mFormatID == kAudioFormatLinearPCM,
          asbd.mSampleRate > 0,
          asbd.mChannelsPerFrame > 0
    else { return nil }
    let frames = CMSampleBufferGetNumSamples(sampleBuffer)
    guard frames > 0 else { return nil }

    if converter == nil || inputDescription.map({ !Self.same($0, asbd) }) ?? true {
      guard let format = Self.makeFormat(&asbd),
            let fresh = AVAudioConverter(from: format, to: output)
      else { return nil }
      // Mix stereo down rather than keeping only the left channel.
      fresh.downmix = true
      inputFormat = format
      inputDescription = asbd
      converter = fresh
    }
    guard let inputFormat, let converter,
          let input = AVAudioPCMBuffer(
            pcmFormat: inputFormat,
            frameCapacity: AVAudioFrameCount(frames)
          )
    else { return nil }
    input.frameLength = AVAudioFrameCount(frames)
    // Raw copy in ReplayKit's own layout and byte order; the converter
    // interprets it through inputFormat.
    let copied = CMSampleBufferCopyPCMDataIntoAudioBufferList(
      sampleBuffer,
      at: 0,
      frameCount: Int32(frames),
      into: input.mutableAudioBufferList
    )
    guard copied == noErr else { return nil }

    let ratio = output.sampleRate / inputFormat.sampleRate
    let capacity = AVAudioFrameCount((Double(frames) * ratio).rounded(.up)) + 32
    guard let converted = AVAudioPCMBuffer(pcmFormat: output, frameCapacity: capacity) else {
      return nil
    }
    // Hand the buffer over once, then report "no data now" rather than end
    // of stream, so the resampler carries its state into the next buffer.
    var consumed = false
    var error: NSError?
    let status = converter.convert(to: converted, error: &error) { _, outStatus in
      if consumed {
        outStatus.pointee = .noDataNow
        return nil
      }
      consumed = true
      outStatus.pointee = .haveData
      return input
    }
    guard status != .error, converted.frameLength > 0,
          let samples = converted.int16ChannelData
    else { return nil }
    return Data(
      bytes: samples[0],
      count: Int(converted.frameLength) * MemoryLayout<Int16>.size
    )
  }

  /// More than two channels needs an explicit layout, or AVAudioFormat
  /// refuses the description.
  private static func makeFormat(
    _ asbd: inout AudioStreamBasicDescription
  ) -> AVAudioFormat? {
    if asbd.mChannelsPerFrame <= 2 {
      return AVAudioFormat(streamDescription: &asbd)
    }
    guard let layout = AVAudioChannelLayout(
      layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | asbd.mChannelsPerFrame
    ) else { return nil }
    return AVAudioFormat(streamDescription: &asbd, channelLayout: layout)
  }

  private static func same(
    _ a: AudioStreamBasicDescription,
    _ b: AudioStreamBasicDescription
  ) -> Bool {
    a.mSampleRate == b.mSampleRate
      && a.mFormatID == b.mFormatID
      && a.mFormatFlags == b.mFormatFlags
      && a.mBytesPerPacket == b.mBytesPerPacket
      && a.mFramesPerPacket == b.mFramesPerPacket
      && a.mBytesPerFrame == b.mBytesPerFrame
      && a.mChannelsPerFrame == b.mChannelsPerFrame
      && a.mBitsPerChannel == b.mBitsPerChannel
  }
}
