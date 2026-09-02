#pragma once

// Minimal ATL subset so Windows SDK <sphelper.h> (used by flutter_tts) can
// compile with VS Build Tools that don't include the ATL/MFC component.
#ifndef __ATLBASE_H__
#define __ATLBASE_H__

#include <objbase.h>
#include <unknwn.h>

template <class T>
class CComPtr {
 public:
  T* p;

  CComPtr() noexcept : p(nullptr) {}
  CComPtr(T* ptr) noexcept : p(ptr) {
    if (p) p->AddRef();
  }
  CComPtr(const CComPtr& other) noexcept : p(other.p) {
    if (p) p->AddRef();
  }
  CComPtr(CComPtr&& other) noexcept : p(other.p) { other.p = nullptr; }

  ~CComPtr() { Release(); }

  CComPtr& operator=(T* ptr) noexcept {
    if (p != ptr) {
      Release();
      p = ptr;
      if (p) p->AddRef();
    }
    return *this;
  }
  CComPtr& operator=(const CComPtr& other) noexcept {
    return *this = other.p;
  }
  CComPtr& operator=(CComPtr&& other) noexcept {
    if (this != &other) {
      Release();
      p = other.p;
      other.p = nullptr;
    }
    return *this;
  }

  T** operator&() noexcept { return &p; }
  T* operator->() const noexcept { return p; }
  operator T*() const noexcept { return p; }
  bool operator!() const noexcept { return p == nullptr; }

  void Release() noexcept {
    if (p) {
      p->Release();
      p = nullptr;
    }
  }

  T* Detach() noexcept {
    T* tmp = p;
    p = nullptr;
    return tmp;
  }

  HRESULT CoCreateInstance(REFCLSID rclsid, DWORD dwClsContext = CLSCTX_ALL) {
    Release();
    return ::CoCreateInstance(rclsid, nullptr, dwClsContext, __uuidof(T),
                              reinterpret_cast<void**>(&p));
  }
};

#endif
