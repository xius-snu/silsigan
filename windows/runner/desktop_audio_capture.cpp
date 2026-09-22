#include "desktop_audio_capture.h"

#include <windows.h>
#include <mmsystem.h>

#include <audioclient.h>
#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>
#include <mmdeviceapi.h>
#include <mmreg.h>
#include <propidl.h>

#include <atomic>
#include <cstdint>
#include <cstring>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

#include "utils.h"

namespace {

using flutter::EncodableList;
using flutter::EncodableMap;
using flutter::EncodableValue;
using flutter::MethodCall;
using flutter::MethodChannel;
using flutter::MethodResult;

constexpr UINT32 kDstRate = 24000;
constexpr size_t kMaxPendingBytes = static_cast<size_t>(kDstRate) * 2 * 2;

// PKEY_Device_FriendlyName — defined here so we don't pull
// functiondiscoverykeys_devpkey.h (it needs INITGUID/DEFINE_PROPERTYKEY).
static const PROPERTYKEY kPkeyDeviceFriendlyName = {
    {0xa45c254e,
     0xdf1c,
     0x4efd,
     {0x80, 0x20, 0x67, 0xd1, 0x46, 0xa8, 0x50, 0xe0}},
    14};

#ifndef KSDATAFORMAT_SUBTYPE_IEEE_FLOAT
// {00000003-0000-0010-8000-00aa00389b71}
static const GUID kSubtypeIeeeFloat = {
    0x00000003,
    0x0000,
    0x0010,
    {0x80, 0x00, 0x00, 0xaa, 0x00, 0x38, 0x9b, 0x71}};
#else
static const GUID kSubtypeIeeeFloat = KSDATAFORMAT_SUBTYPE_IEEE_FLOAT;
#endif

std::wstring Utf16FromUtf8(const std::string& utf8) {
  if (utf8.empty()) {
    return std::wstring();
  }
  const int len = ::MultiByteToWideChar(CP_UTF8, 0, utf8.c_str(), -1, nullptr, 0);
  if (len <= 1) {
    return std::wstring();
  }
  std::wstring wide(static_cast<size_t>(len - 1), L'\0');
  ::MultiByteToWideChar(CP_UTF8, 0, utf8.c_str(), -1, wide.data(), len);
  return wide;
}

bool GetStringFromMap(const EncodableMap* map, const char* key, std::string* out) {
  if (map == nullptr) {
    return false;
  }
  const auto it = map->find(EncodableValue(key));
  if (it == map->end()) {
    return false;
  }
  if (const auto* s = std::get_if<std::string>(&it->second)) {
    *out = *s;
    return true;
  }
  return false;
}

std::string HresultMessage(HRESULT hr) {
  wchar_t* text = nullptr;
  const DWORD n = ::FormatMessageW(
      FORMAT_MESSAGE_ALLOCATE_BUFFER | FORMAT_MESSAGE_FROM_SYSTEM |
          FORMAT_MESSAGE_IGNORE_INSERTS,
      nullptr, static_cast<DWORD>(hr), MAKELANGID(LANG_NEUTRAL, SUBLANG_DEFAULT),
      reinterpret_cast<LPWSTR>(&text), 0, nullptr);
  std::string msg = "HRESULT 0x" + std::to_string(static_cast<unsigned long>(hr));
  if (n > 0 && text != nullptr) {
    msg = Utf8FromUtf16(text);
    while (!msg.empty() && (msg.back() == '\n' || msg.back() == '\r')) {
      msg.pop_back();
    }
  }
  if (text != nullptr) {
    ::LocalFree(text);
  }
  return msg;
}

bool IsFloatFormat(const WAVEFORMATEX* wfx) {
  if (wfx == nullptr) {
    return false;
  }
  if (wfx->wFormatTag == WAVE_FORMAT_IEEE_FLOAT) {
    return true;
  }
  if (wfx->wFormatTag == WAVE_FORMAT_EXTENSIBLE && wfx->cbSize >= 22) {
    const auto* ext = reinterpret_cast<const WAVEFORMATEXTENSIBLE*>(wfx);
    return ext->SubFormat == kSubtypeIeeeFloat;
  }
  return false;
}

int16_t FloatToS16(float x) {
  if (x > 1.0f) {
    x = 1.0f;
  } else if (x < -1.0f) {
    x = -1.0f;
  }
  return static_cast<int16_t>(x * 32767.0f);
}

// Convert one WASAPI packet to 24 kHz mono s16, keeping resampler state
// across packets so a 44.1 kHz mix format doesn't click at boundaries.
class LoopbackConverter {
 public:
  void Configure(const WAVEFORMATEX* wfx) {
    src_rate_ = wfx != nullptr ? wfx->nSamplesPerSec : 48000;
    if (src_rate_ == 0) {
      src_rate_ = 48000;
    }
    channels_ = wfx != nullptr ? wfx->nChannels : 2;
    if (channels_ == 0) {
      channels_ = 2;
    }
    bits_ = wfx != nullptr ? wfx->wBitsPerSample : 32;
    is_float_ = IsFloatFormat(wfx);
    frac_ = 0.0;
    prev_ = 0.0f;
    has_prev_ = false;
  }

  void Convert(const BYTE* data, UINT32 frames, bool silent,
               std::vector<uint8_t>* out) {
    if (frames == 0) {
      return;
    }
    mono_.clear();
    mono_.reserve(frames);
    if (silent || data == nullptr) {
      mono_.assign(frames, 0.0f);
    } else {
      for (UINT32 i = 0; i < frames; i++) {
        mono_.push_back(SampleAt(data, i));
      }
    }
    ResampleTo(out);
  }

 private:
  float SampleAt(const BYTE* data, UINT32 frame) const {
    float acc = 0.0f;
    const UINT32 ch = channels_;
    for (UINT32 c = 0; c < ch; c++) {
      if (is_float_ && bits_ == 32) {
        float s = 0.0f;
        std::memcpy(&s, data + (frame * ch + c) * 4, sizeof(float));
        acc += s;
      } else if (bits_ == 16) {
        int16_t s = 0;
        std::memcpy(&s, data + (frame * ch + c) * 2, sizeof(int16_t));
        acc += static_cast<float>(s) / 32768.0f;
      } else if (bits_ == 32) {
        int32_t s = 0;
        std::memcpy(&s, data + (frame * ch + c) * 4, sizeof(int32_t));
        acc += static_cast<float>(s) / 2147483648.0f;
      } else if (bits_ == 24) {
        const BYTE* p = data + (frame * ch + c) * 3;
        int32_t s = (static_cast<int32_t>(p[0])) |
                    (static_cast<int32_t>(p[1]) << 8) |
                    (static_cast<int32_t>(p[2]) << 16);
        if (s & 0x800000) {
          s |= static_cast<int32_t>(0xFF000000);
        }
        acc += static_cast<float>(s) / 8388608.0f;
      }
    }
    return acc / static_cast<float>(ch);
  }

  void ResampleTo(std::vector<uint8_t>* out) {
    if (mono_.empty()) {
      return;
    }
    if (src_rate_ == kDstRate) {
      for (float s : mono_) {
        const int16_t v = FloatToS16(s);
        out->push_back(static_cast<uint8_t>(v & 0xFF));
        out->push_back(static_cast<uint8_t>((v >> 8) & 0xFF));
      }
      return;
    }
    // Linear interpolation. frac_ is the source-domain cursor into the
    // previous packet's last sample (prev_) plus the current packet.
    const double step = static_cast<double>(src_rate_) / static_cast<double>(kDstRate);
    const size_t n = mono_.size();
    while (true) {
      const double src_index = frac_;
      const int i0 = static_cast<int>(src_index);
      const double t = src_index - static_cast<double>(i0);
      float s0 = 0.0f;
      float s1 = 0.0f;
      bool have1 = false;
      if (i0 < 0) {
        if (!has_prev_) {
          break;
        }
        s0 = prev_;
        if (n > 0) {
          s1 = mono_[0];
          have1 = true;
        }
      } else if (static_cast<size_t>(i0) >= n) {
        break;
      } else {
        s0 = mono_[static_cast<size_t>(i0)];
        if (static_cast<size_t>(i0) + 1 < n) {
          s1 = mono_[static_cast<size_t>(i0) + 1];
          have1 = true;
        } else {
          have1 = false;
        }
      }
      if (!have1) {
        // Need the next packet to interpolate the last interval.
        break;
      }
      const float s = s0 + static_cast<float>(t) * (s1 - s0);
      const int16_t v = FloatToS16(s);
      out->push_back(static_cast<uint8_t>(v & 0xFF));
      out->push_back(static_cast<uint8_t>((v >> 8) & 0xFF));
      frac_ += step;
    }
    // Keep the last source sample and rewind frac_ into [-step, n).
    prev_ = mono_.back();
    has_prev_ = true;
    frac_ -= static_cast<double>(n);
  }

  UINT32 src_rate_ = 48000;
  UINT32 channels_ = 2;
  UINT16 bits_ = 32;
  bool is_float_ = true;
  double frac_ = 0.0;
  float prev_ = 0.0f;
  bool has_prev_ = false;
  std::vector<float> mono_;
};

class LoopbackSession {
 public:
  ~LoopbackSession() { Stop(); }

  HRESULT Start(const std::string& device_id) {
    Stop();
    stop_event_ = ::CreateEventW(nullptr, TRUE, FALSE, nullptr);
    started_event_ = ::CreateEventW(nullptr, TRUE, FALSE, nullptr);
    if (stop_event_ == nullptr || started_event_ == nullptr) {
      Stop();
      return E_FAIL;
    }
    start_hr_ = E_FAIL;
    device_id_ = device_id;
    thread_ = ::CreateThread(nullptr, 0, &LoopbackSession::ThreadProc, this, 0,
                             nullptr);
    if (thread_ == nullptr) {
      Stop();
      return E_FAIL;
    }
    const DWORD wait = ::WaitForSingleObject(started_event_, 4000);
    if (wait != WAIT_OBJECT_0) {
      Stop();
      return HRESULT_FROM_WIN32(ERROR_TIMEOUT);
    }
    return start_hr_;
  }

  void Stop() {
    if (stop_event_ != nullptr) {
      ::SetEvent(stop_event_);
    }
    if (thread_ != nullptr) {
      ::WaitForSingleObject(thread_, 3000);
      ::CloseHandle(thread_);
      thread_ = nullptr;
    }
    if (stop_event_ != nullptr) {
      ::CloseHandle(stop_event_);
      stop_event_ = nullptr;
    }
    if (started_event_ != nullptr) {
      ::CloseHandle(started_event_);
      started_event_ = nullptr;
    }
    std::lock_guard<std::mutex> lock(mutex_);
    pending_.clear();
    start_hr_ = S_OK;
  }

  std::vector<uint8_t> TakePending() {
    std::lock_guard<std::mutex> lock(mutex_);
    std::vector<uint8_t> out;
    out.swap(pending_);
    return out;
  }

 private:
  static DWORD WINAPI ThreadProc(LPVOID param) {
    auto* self = static_cast<LoopbackSession*>(param);
    self->Run();
    return 0;
  }

  void SignalStarted(HRESULT hr) {
    start_hr_ = hr;
    if (started_event_ != nullptr) {
      ::SetEvent(started_event_);
    }
  }

  void AppendBytes(const std::vector<uint8_t>& bytes) {
    if (bytes.empty()) {
      return;
    }
    std::lock_guard<std::mutex> lock(mutex_);
    pending_.insert(pending_.end(), bytes.begin(), bytes.end());
    if (pending_.size() > kMaxPendingBytes) {
      const size_t drop = pending_.size() - kMaxPendingBytes;
      pending_.erase(pending_.begin(), pending_.begin() + static_cast<std::ptrdiff_t>(drop));
    }
  }

  void Run() {
    HRESULT hr = ::CoInitializeEx(nullptr, COINIT_MULTITHREADED);
    const bool com_ok = SUCCEEDED(hr) || hr == RPC_E_CHANGED_MODE;
    if (!com_ok) {
      SignalStarted(hr);
      return;
    }

    IMMDeviceEnumerator* enumerator = nullptr;
    hr = ::CoCreateInstance(__uuidof(MMDeviceEnumerator), nullptr, CLSCTX_ALL,
                            __uuidof(IMMDeviceEnumerator),
                            reinterpret_cast<void**>(&enumerator));
    IMMDevice* device = nullptr;
    if (SUCCEEDED(hr)) {
      if (device_id_.empty()) {
        hr = enumerator->GetDefaultAudioEndpoint(eRender, eConsole, &device);
      } else {
        const std::wstring wide = Utf16FromUtf8(device_id_);
        hr = enumerator->GetDevice(wide.c_str(), &device);
      }
    }
    IAudioClient* client = nullptr;
    WAVEFORMATEX* mix = nullptr;
    if (SUCCEEDED(hr)) {
      hr = device->Activate(__uuidof(IAudioClient), CLSCTX_ALL, nullptr,
                            reinterpret_cast<void**>(&client));
    }
    if (SUCCEEDED(hr)) {
      hr = client->GetMixFormat(&mix);
    }
    if (SUCCEEDED(hr)) {
      hr = client->Initialize(AUDCLNT_SHAREMODE_SHARED,
                              AUDCLNT_STREAMFLAGS_LOOPBACK,
                              10000000, 0, mix, nullptr);
    }
    IAudioCaptureClient* capture = nullptr;
    if (SUCCEEDED(hr)) {
      hr = client->GetService(__uuidof(IAudioCaptureClient),
                              reinterpret_cast<void**>(&capture));
    }
    if (SUCCEEDED(hr)) {
      converter_.Configure(mix);
      hr = client->Start();
    }
    SignalStarted(hr);
    if (FAILED(hr)) {
      if (capture != nullptr) {
        capture->Release();
      }
      if (mix != nullptr) {
        ::CoTaskMemFree(mix);
      }
      if (client != nullptr) {
        client->Release();
      }
      if (device != nullptr) {
        device->Release();
      }
      if (enumerator != nullptr) {
        enumerator->Release();
      }
      if (com_ok) {
        ::CoUninitialize();
      }
      return;
    }

    std::vector<uint8_t> converted;
    converted.reserve(4096);
    while (::WaitForSingleObject(stop_event_, 10) == WAIT_TIMEOUT) {
      UINT32 packet = 0;
      HRESULT packet_hr = capture->GetNextPacketSize(&packet);
      if (FAILED(packet_hr)) {
        break;
      }
      while (packet > 0) {
        BYTE* data = nullptr;
        UINT32 frames = 0;
        DWORD flags = 0;
        HRESULT buf_hr =
            capture->GetBuffer(&data, &frames, &flags, nullptr, nullptr);
        if (FAILED(buf_hr)) {
          break;
        }
        converted.clear();
        const bool silent = (flags & AUDCLNT_BUFFERFLAGS_SILENT) != 0;
        converter_.Convert(data, frames, silent, &converted);
        AppendBytes(converted);
        capture->ReleaseBuffer(frames);
        if (FAILED(capture->GetNextPacketSize(&packet))) {
          break;
        }
      }
    }

    client->Stop();
    capture->Release();
    ::CoTaskMemFree(mix);
    client->Release();
    device->Release();
    enumerator->Release();
    ::CoUninitialize();
  }

  std::string device_id_;
  HANDLE stop_event_ = nullptr;
  HANDLE thread_ = nullptr;
  HANDLE started_event_ = nullptr;
  std::atomic<HRESULT> start_hr_{S_OK};
  std::mutex mutex_;
  std::vector<uint8_t> pending_;
  LoopbackConverter converter_;
};

uint16_t ReadLe16(const uint8_t* p) {
  return static_cast<uint16_t>(p[0] | (static_cast<uint16_t>(p[1]) << 8));
}

uint32_t ReadLe32(const uint8_t* p) {
  return static_cast<uint32_t>(p[0]) | (static_cast<uint32_t>(p[1]) << 8) |
         (static_cast<uint32_t>(p[2]) << 16) | (static_cast<uint32_t>(p[3]) << 24);
}

bool ReadExact(HANDLE file, void* dst, DWORD n) {
  DWORD got = 0;
  return ::ReadFile(file, dst, n, &got, nullptr) && got == n;
}

// Streams a PCM WAV with waveOut. Media Foundation (audioplayers on Windows)
// refuses these 24 kHz recordings, so history playback cannot go through it.
class WavPlayback {
 public:
  ~WavPlayback() { Stop(); }

  bool Play(const std::wstring& path, std::string* error) {
    Stop();
    if (path.empty()) {
      *error = "Recording file is missing";
      return false;
    }
    file_ = ::CreateFileW(path.c_str(), GENERIC_READ, FILE_SHARE_READ, nullptr,
                          OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
    if (file_ == INVALID_HANDLE_VALUE) {
      *error = "Recording file is missing";
      return false;
    }
    std::string parse_error;
    if (!Parse(&parse_error)) {
      ::CloseHandle(file_);
      file_ = INVALID_HANDLE_VALUE;
      *error = parse_error.empty() ? "This recording isn't a playable WAV"
                                   : parse_error;
      return false;
    }
    const uint64_t dur_ms = data_bytes_ * 1000ull / byte_rate_;
    duration_ms_.store(ClampMs(dur_ms));
    position_ms_.store(0);
    finished_.store(false);
    paused_.store(false);
    playing_.store(false);
    stop_.store(false);
    accept_finish_.store(true);
    transport_.store(0);
    seek_req_.store(false);
    origin_ = 0;
    read_pos_ = 0;
    eof_ = false;
    thread_paused_ = false;

    LARGE_INTEGER at;
    at.QuadPart = static_cast<LONGLONG>(data_offset_);
    if (!::SetFilePointerEx(file_, at, nullptr, FILE_BEGIN)) {
      ::CloseHandle(file_);
      file_ = INVALID_HANDLE_VALUE;
      *error = "This recording isn't a playable WAV";
      return false;
    }

    // Open on this thread. Doing it on the playback thread and then waiting
    // here deadlocks drivers that send a window message during waveOutOpen.
    WAVEFORMATEX wfx;
    std::memset(&wfx, 0, sizeof(wfx));
    wfx.wFormatTag = WAVE_FORMAT_PCM;
    wfx.nChannels = static_cast<WORD>(block_align_ / 2);
    wfx.nSamplesPerSec = byte_rate_ / block_align_;
    wfx.wBitsPerSample = 16;
    wfx.nBlockAlign = block_align_;
    wfx.nAvgBytesPerSec = byte_rate_;
    HWAVEOUT hwo = nullptr;
    const MMRESULT opened =
        ::waveOutOpen(&hwo, WAVE_MAPPER, &wfx, 0, 0, CALLBACK_NULL);
    if (opened != MMSYSERR_NOERROR) {
      ::CloseHandle(file_);
      file_ = INVALID_HANDLE_VALUE;
      *error = "Couldn't open playback";
      return false;
    }
    hwo_ = hwo;
    PrepareBuffers();
    playing_.store(true);
    thread_ = std::thread([this] { Run(); });
    return true;
  }

  void Pause() { transport_.store(1); }

  void Resume() { transport_.store(2); }

  void SeekMs(int32_t ms) {
    if (byte_rate_ == 0 || block_align_ == 0) return;
    if (ms < 0) ms = 0;
    uint64_t bytes = static_cast<uint64_t>(ms) * byte_rate_ / 1000ull;
    bytes -= bytes % block_align_;
    if (bytes > data_bytes_) bytes = data_bytes_ - (data_bytes_ % block_align_);
    seek_bytes_.store(bytes);
    seek_req_.store(true);
  }

  void Stop() {
    accept_finish_.store(false);
    stop_.store(true);
    if (thread_.joinable()) thread_.join();
    CloseDevice();
    playing_.store(false);
    paused_.store(false);
    finished_.store(false);
    stop_.store(false);
    transport_.store(0);
    seek_req_.store(false);
  }

  void Status(int32_t* pos, int32_t* dur, bool* playing, bool* paused,
              bool* finished) const {
    *pos = position_ms_.load();
    *dur = duration_ms_.load();
    *playing = playing_.load();
    *paused = paused_.load();
    *finished = finished_.load();
  }

 private:
  static int32_t ClampMs(uint64_t ms) {
    return ms > 0x7fffffff ? 0x7fffffff : static_cast<int32_t>(ms);
  }

  bool Parse(std::string* error) {
    uint8_t riff[12];
    if (!ReadExact(file_, riff, 12) || std::memcmp(riff, "RIFF", 4) != 0 ||
        std::memcmp(riff + 8, "WAVE", 4) != 0) {
      *error = "This recording isn't a playable WAV";
      return false;
    }
    bool have_fmt = false;
    uint16_t format = 0;
    uint16_t channels = 0;
    uint32_t rate = 0;
    uint16_t bits = 0;
    bool have_data = false;
    for (;;) {
      uint8_t chunk[8];
      if (!ReadExact(file_, chunk, 8)) break;
      const uint32_t size = ReadLe32(chunk + 4);
      if (std::memcmp(chunk, "fmt ", 4) == 0) {
        if (size < 16 || size > 4096) {
          *error = "This recording isn't a playable WAV";
          return false;
        }
        std::vector<uint8_t> fmt(size);
        if (!ReadExact(file_, fmt.data(), size)) {
          *error = "This recording isn't a playable WAV";
          return false;
        }
        if ((size & 1u) != 0) {
          uint8_t pad = 0;
          ReadExact(file_, &pad, 1);
        }
        format = ReadLe16(fmt.data());
        channels = ReadLe16(fmt.data() + 2);
        rate = ReadLe32(fmt.data() + 4);
        bits = ReadLe16(fmt.data() + 14);
        have_fmt = true;
      } else if (std::memcmp(chunk, "data", 4) == 0) {
        LARGE_INTEGER zero;
        zero.QuadPart = 0;
        LARGE_INTEGER cur;
        cur.QuadPart = 0;
        if (!::SetFilePointerEx(file_, zero, &cur, FILE_CURRENT)) {
          *error = "This recording isn't a playable WAV";
          return false;
        }
        data_offset_ = static_cast<uint64_t>(cur.QuadPart);
        data_bytes_ = size;
        have_data = true;
        break;
      } else {
        uint64_t skip = static_cast<uint64_t>(size) + (size & 1u);
        LARGE_INTEGER dist;
        dist.QuadPart = static_cast<LONGLONG>(skip);
        if (!::SetFilePointerEx(file_, dist, nullptr, FILE_CURRENT)) {
          *error = "This recording isn't a playable WAV";
          return false;
        }
      }
    }
    if (!have_fmt || !have_data || format != 1 || bits != 16 ||
        (channels != 1 && channels != 2) || rate < 8000 || rate > 192000) {
      *error = "This recording isn't a playable WAV";
      return false;
    }
    block_align_ = static_cast<uint16_t>(channels * 2);
    byte_rate_ = rate * block_align_;
    LARGE_INTEGER file_size;
    file_size.QuadPart = 0;
    if (!::GetFileSizeEx(file_, &file_size)) {
      *error = "This recording isn't a playable WAV";
      return false;
    }
    const uint64_t file_bytes = static_cast<uint64_t>(file_size.QuadPart);
    if (data_offset_ >= file_bytes) {
      *error = "Recording is empty";
      return false;
    }
    const uint64_t remain = file_bytes - data_offset_;
    if (data_bytes_ > remain) data_bytes_ = remain;
    data_bytes_ -= data_bytes_ % block_align_;
    if (data_bytes_ == 0 || byte_rate_ == 0) {
      *error = "Recording is empty";
      return false;
    }
    return true;
  }

  void Run() {
    for (;;) {
      if (stop_.load()) break;
      ApplyTransport();
      if (!thread_paused_ && !eof_) Fill();
      UpdatePosition();
      if (eof_ && !AnyQueued()) {
        position_ms_.store(duration_ms_.load());
        playing_.store(false);
        paused_.store(false);
        if (accept_finish_.load()) finished_.store(true);
        break;
      }
      ::Sleep(10);
    }
  }

  void PrepareBuffers() {
    uint32_t chunk = byte_rate_ / 10;
    if (chunk < block_align_) chunk = block_align_;
    chunk -= chunk % block_align_;
    if (chunk > 16384 && block_align_ < 16384) {
      chunk = 16384 - (16384 % block_align_);
    }
    bufs_.clear();
    bufs_.reserve(4);
    for (int i = 0; i < 4; i++) {
      bufs_.emplace_back();
      Buf& buf = bufs_.back();
      buf.bytes.resize(chunk);
      std::memset(&buf.hdr, 0, sizeof(buf.hdr));
      buf.hdr.lpData = reinterpret_cast<LPSTR>(buf.bytes.data());
      buf.hdr.dwBufferLength = static_cast<DWORD>(buf.bytes.size());
      ::waveOutPrepareHeader(hwo_, &buf.hdr, sizeof(buf.hdr));
    }
  }

  void ApplyTransport() {
    if (seek_req_.exchange(false)) {
      ApplySeek(seek_bytes_.load());
    }
    const int transport = transport_.exchange(0);
    if (transport == 1 && hwo_ != nullptr) {
      ::waveOutPause(hwo_);
      thread_paused_ = true;
      paused_.store(true);
    } else if (transport == 2 && hwo_ != nullptr) {
      thread_paused_ = false;
      paused_.store(false);
      ::waveOutRestart(hwo_);
    }
  }

  void ApplySeek(uint64_t bytes) {
    if (hwo_ == nullptr || file_ == INVALID_HANDLE_VALUE) return;
    if (bytes > data_bytes_) bytes = data_bytes_;
    bytes -= bytes % block_align_;
    ::waveOutReset(hwo_);
    LARGE_INTEGER dist;
    dist.QuadPart = static_cast<LONGLONG>(data_offset_ + bytes);
    ::SetFilePointerEx(file_, dist, nullptr, FILE_BEGIN);
    origin_ = bytes;
    read_pos_ = bytes;
    eof_ = bytes >= data_bytes_;
    const uint64_t ms = byte_rate_ == 0 ? 0 : bytes * 1000ull / byte_rate_;
    position_ms_.store(ClampMs(ms));
    if (thread_paused_) ::waveOutPause(hwo_);
  }

  void Fill() {
    if (hwo_ == nullptr || file_ == INVALID_HANDLE_VALUE || eof_) return;
    for (auto& buf : bufs_) {
      if ((buf.hdr.dwFlags & WHDR_INQUEUE) != 0) continue;
      if (read_pos_ >= data_bytes_) {
        eof_ = true;
        return;
      }
      uint64_t remain = data_bytes_ - read_pos_;
      DWORD want = static_cast<DWORD>(buf.bytes.size());
      if (remain < want) want = static_cast<DWORD>(remain);
      if (block_align_ > 1) want -= want % block_align_;
      if (want == 0) {
        eof_ = true;
        return;
      }
      DWORD got = 0;
      if (!::ReadFile(file_, buf.bytes.data(), want, &got, nullptr) || got == 0) {
        eof_ = true;
        return;
      }
      if (block_align_ > 1) got -= got % block_align_;
      if (got == 0) {
        eof_ = true;
        return;
      }
      buf.hdr.dwBufferLength = got;
      if (::waveOutWrite(hwo_, &buf.hdr, sizeof(buf.hdr)) != MMSYSERR_NOERROR) {
        eof_ = true;
        return;
      }
      read_pos_ += got;
      if (read_pos_ >= data_bytes_) eof_ = true;
    }
  }

  bool AnyQueued() const {
    for (const auto& buf : bufs_) {
      if ((buf.hdr.dwFlags & WHDR_INQUEUE) != 0) return true;
    }
    return false;
  }

  void UpdatePosition() {
    if (hwo_ == nullptr || byte_rate_ == 0) return;
    MMTIME tm;
    std::memset(&tm, 0, sizeof(tm));
    tm.wType = TIME_BYTES;
    if (::waveOutGetPosition(hwo_, &tm, sizeof(tm)) != MMSYSERR_NOERROR) return;
    uint64_t bytes = origin_;
    if (tm.wType == TIME_BYTES) {
      bytes += tm.u.cb;
    } else if (tm.wType == TIME_MS) {
      bytes += static_cast<uint64_t>(tm.u.ms) * byte_rate_ / 1000ull;
    } else if (tm.wType == TIME_SAMPLES) {
      bytes += static_cast<uint64_t>(tm.u.sample) * block_align_;
    } else {
      return;
    }
    if (bytes > data_bytes_) bytes = data_bytes_;
    position_ms_.store(ClampMs(bytes * 1000ull / byte_rate_));
  }

  void CloseDevice() {
    if (hwo_ != nullptr) {
      ::waveOutReset(hwo_);
      for (auto& buf : bufs_) {
        if ((buf.hdr.dwFlags & WHDR_PREPARED) != 0) {
          ::waveOutUnprepareHeader(hwo_, &buf.hdr, sizeof(buf.hdr));
        }
      }
      ::waveOutClose(hwo_);
      hwo_ = nullptr;
    }
    bufs_.clear();
    if (file_ != INVALID_HANDLE_VALUE) {
      ::CloseHandle(file_);
      file_ = INVALID_HANDLE_VALUE;
    }
  }

  struct Buf {
    std::vector<uint8_t> bytes;
    WAVEHDR hdr;
  };

  std::thread thread_;
  HANDLE file_ = INVALID_HANDLE_VALUE;
  HWAVEOUT hwo_ = nullptr;
  std::vector<Buf> bufs_;

  std::atomic<bool> stop_{false};
  std::atomic<bool> accept_finish_{false};
  std::atomic<int> transport_{0};
  std::atomic<bool> seek_req_{false};
  std::atomic<uint64_t> seek_bytes_{0};
  std::atomic<int32_t> position_ms_{0};
  std::atomic<int32_t> duration_ms_{0};
  std::atomic<bool> playing_{false};
  std::atomic<bool> paused_{false};
  std::atomic<bool> finished_{false};

  uint64_t data_offset_ = 0;
  uint64_t data_bytes_ = 0;
  uint32_t byte_rate_ = 0;
  uint16_t block_align_ = 2;
  uint64_t origin_ = 0;
  uint64_t read_pos_ = 0;
  bool eof_ = false;
  bool thread_paused_ = false;
};

class DesktopAudioPlugin {
 public:
  explicit DesktopAudioPlugin(flutter::BinaryMessenger* messenger) {
    channel_ = std::make_unique<MethodChannel<EncodableValue>>(
        messenger, "com.silsigan.app/desktop_audio",
        &flutter::StandardMethodCodec::GetInstance());
    channel_->SetMethodCallHandler(
        [this](const MethodCall<EncodableValue>& call,
               std::unique_ptr<MethodResult<EncodableValue>> result) {
          Handle(call, std::move(result));
        });
  }

  ~DesktopAudioPlugin() {
    wav_.Stop();
    loopback_.Stop();
    if (channel_) {
      channel_->SetMethodCallHandler(nullptr);
    }
  }

 private:
  void Handle(const MethodCall<EncodableValue>& call,
              std::unique_ptr<MethodResult<EncodableValue>> result) {
    const std::string& method = call.method_name();
    if (method == "listDevices") {
      ListDevices(*result);
      return;
    }
    if (method == "startLoopback") {
      std::string device_id;
      if (const auto* args = std::get_if<EncodableMap>(call.arguments())) {
        GetStringFromMap(args, "deviceId", &device_id);
      }
      const HRESULT hr = loopback_.Start(device_id);
      if (FAILED(hr)) {
        result->Error("loopback_start_failed", HresultMessage(hr));
        return;
      }
      result->Success();
      return;
    }
    if (method == "stopLoopback") {
      loopback_.Stop();
      result->Success();
      return;
    }
    if (method == "readLoopback") {
      std::vector<uint8_t> bytes = loopback_.TakePending();
      result->Success(EncodableValue(std::move(bytes)));
      return;
    }
    if (method == "playWav") {
      std::string path;
      if (const auto* args = std::get_if<EncodableMap>(call.arguments())) {
        GetStringFromMap(args, "path", &path);
      }
      std::string err;
      if (!wav_.Play(Utf16FromUtf8(path), &err)) {
        result->Error("wav_play_failed", err);
        return;
      }
      result->Success();
      return;
    }
    if (method == "pauseWav") {
      wav_.Pause();
      result->Success();
      return;
    }
    if (method == "resumeWav") {
      wav_.Resume();
      result->Success();
      return;
    }
    if (method == "stopWav") {
      wav_.Stop();
      result->Success();
      return;
    }
    if (method == "seekWav") {
      int32_t ms = 0;
      if (const auto* args = std::get_if<EncodableMap>(call.arguments())) {
        const auto it = args->find(EncodableValue("positionMs"));
        if (it != args->end()) {
          if (const auto* i = std::get_if<int32_t>(&it->second)) {
            ms = *i;
          } else if (const auto* i64 = std::get_if<int64_t>(&it->second)) {
            ms = static_cast<int32_t>(*i64);
          }
        }
      }
      wav_.SeekMs(ms);
      result->Success();
      return;
    }
    if (method == "wavStatus") {
      int32_t pos = 0;
      int32_t dur = 0;
      bool playing = false;
      bool paused = false;
      bool finished = false;
      wav_.Status(&pos, &dur, &playing, &paused, &finished);
      EncodableMap map;
      map[EncodableValue("positionMs")] = EncodableValue(pos);
      map[EncodableValue("durationMs")] = EncodableValue(dur);
      map[EncodableValue("playing")] = EncodableValue(playing);
      map[EncodableValue("paused")] = EncodableValue(paused);
      map[EncodableValue("finished")] = EncodableValue(finished);
      result->Success(EncodableValue(std::move(map)));
      return;
    }
    result->NotImplemented();
  }

  static void ListDevices(MethodResult<EncodableValue>& result) {
    IMMDeviceEnumerator* enumerator = nullptr;
    HRESULT hr = ::CoCreateInstance(__uuidof(MMDeviceEnumerator), nullptr,
                                    CLSCTX_ALL, __uuidof(IMMDeviceEnumerator),
                                    reinterpret_cast<void**>(&enumerator));
    if (FAILED(hr)) {
      result.Error("list_failed", HresultMessage(hr));
      return;
    }
    EncodableList inputs;
    EncodableList outputs;
    hr = CollectEndpoints(enumerator, eCapture, &inputs);
    HRESULT out_hr = CollectEndpoints(enumerator, eRender, &outputs);
    enumerator->Release();
    if (FAILED(hr)) {
      result.Error("list_failed", HresultMessage(hr));
      return;
    }
    if (FAILED(out_hr)) {
      result.Error("list_failed", HresultMessage(out_hr));
      return;
    }
    EncodableMap map;
    map[EncodableValue("inputs")] = EncodableValue(std::move(inputs));
    map[EncodableValue("outputs")] = EncodableValue(std::move(outputs));
    result.Success(EncodableValue(std::move(map)));
  }

  static HRESULT CollectEndpoints(IMMDeviceEnumerator* enumerator,
                                  EDataFlow flow, EncodableList* out) {
    LPWSTR default_id = nullptr;
    IMMDevice* default_device = nullptr;
    if (SUCCEEDED(enumerator->GetDefaultAudioEndpoint(flow, eConsole,
                                                      &default_device))) {
      default_device->GetId(&default_id);
      default_device->Release();
    }

    IMMDeviceCollection* collection = nullptr;
    HRESULT hr = enumerator->EnumAudioEndpoints(flow, DEVICE_STATE_ACTIVE,
                                                &collection);
    if (FAILED(hr)) {
      if (default_id != nullptr) {
        ::CoTaskMemFree(default_id);
      }
      return hr;
    }
    UINT count = 0;
    collection->GetCount(&count);
    for (UINT i = 0; i < count; i++) {
      IMMDevice* device = nullptr;
      if (FAILED(collection->Item(i, &device))) {
        continue;
      }
      LPWSTR id = nullptr;
      device->GetId(&id);
      std::string id_utf8 = id != nullptr ? Utf8FromUtf16(id) : std::string();
      std::string label = id_utf8;
      IPropertyStore* props = nullptr;
      if (SUCCEEDED(device->OpenPropertyStore(STGM_READ, &props))) {
        PROPVARIANT name;
        PropVariantInit(&name);
        if (SUCCEEDED(props->GetValue(kPkeyDeviceFriendlyName, &name)) &&
            name.vt == VT_LPWSTR && name.pwszVal != nullptr) {
          label = Utf8FromUtf16(name.pwszVal);
        }
        PropVariantClear(&name);
        props->Release();
      }
      const bool is_default =
          default_id != nullptr && id != nullptr && wcscmp(default_id, id) == 0;
      EncodableMap entry;
      entry[EncodableValue("id")] = EncodableValue(id_utf8);
      entry[EncodableValue("label")] = EncodableValue(label);
      entry[EncodableValue("isDefault")] = EncodableValue(is_default);
      out->push_back(EncodableValue(std::move(entry)));
      if (id != nullptr) {
        ::CoTaskMemFree(id);
      }
      device->Release();
    }
    collection->Release();
    if (default_id != nullptr) {
      ::CoTaskMemFree(default_id);
    }
    return S_OK;
  }

  std::unique_ptr<MethodChannel<EncodableValue>> channel_;
  LoopbackSession loopback_;
  WavPlayback wav_;
};

std::unique_ptr<DesktopAudioPlugin> g_plugin;

}  // namespace

void RegisterDesktopAudioCapture(flutter::BinaryMessenger* messenger) {
  UnregisterDesktopAudioCapture();
  if (messenger != nullptr) {
    g_plugin = std::make_unique<DesktopAudioPlugin>(messenger);
  }
}

void UnregisterDesktopAudioCapture() { g_plugin.reset(); }
