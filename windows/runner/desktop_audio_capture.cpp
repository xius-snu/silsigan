#include "desktop_audio_capture.h"

#include <windows.h>

#include <audioclient.h>
#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>
#include <mmdeviceapi.h>
#include <mmreg.h>
#include <propidl.h>

#include <atomic>
#include <cstring>
#include <memory>
#include <mutex>
#include <string>
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
