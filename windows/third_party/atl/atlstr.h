#pragma once

// Minimal ATL string conversion so flutter_tts can call CW2A without ATL.
#ifndef __ATLSTR_H__
#define __ATLSTR_H__

#include <windows.h>
#include <string>

class CW2A {
 public:
  CW2A(LPCWSTR wide) {
    if (wide == nullptr) {
      return;
    }
    const int n =
        WideCharToMultiByte(CP_ACP, 0, wide, -1, nullptr, 0, nullptr, nullptr);
    if (n <= 0) {
      return;
    }
    buf_.assign(static_cast<size_t>(n), '\0');
    WideCharToMultiByte(CP_ACP, 0, wide, -1, buf_.data(), n, nullptr, nullptr);
  }

  operator LPCSTR() const { return buf_.c_str(); }

 private:
  std::string buf_;
};

#endif
