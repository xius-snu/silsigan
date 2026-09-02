#ifndef RUNNER_DESKTOP_AUDIO_CAPTURE_H_
#define RUNNER_DESKTOP_AUDIO_CAPTURE_H_

#include <flutter/binary_messenger.h>

// WASAPI device listing + render-device loopback. Dart pulls converted
// PCM16/24kHz/mono via readLoopback so the capture thread never has to
// touch Flutter's UI-thread EventSink.
void RegisterDesktopAudioCapture(flutter::BinaryMessenger* messenger);
void UnregisterDesktopAudioCapture();

#endif  // RUNNER_DESKTOP_AUDIO_CAPTURE_H_
