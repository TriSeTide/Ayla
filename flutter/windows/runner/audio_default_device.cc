#include "audio_default_device.h"

#include <windows.h>
#include <mmdeviceapi.h>
#include <propsys.h>
#include <functiondiscoverykeys_devpkey.h>

#include <string>

namespace {

ERole ToRole(int role) {
  switch (role) {
    case 0:
      return eConsole;
    case 2:
      return eCommunications;
    default:
      return eMultimedia;
  }
}

std::string Utf8FromWide(const wchar_t* wide) {
  if (wide == nullptr) {
    return std::string();
  }
  const int size =
      ::WideCharToMultiByte(CP_UTF8, 0, wide, -1, nullptr, 0, nullptr, nullptr);
  if (size <= 0) {
    return std::string();
  }
  std::string out(static_cast<size_t>(size - 1), '\0');
  ::WideCharToMultiByte(CP_UTF8, 0, wide, -1, out.data(), size, nullptr,
                        nullptr);
  return out;
}

// Best-effort initialization; the Flutter platform thread may already have
// initialized COM in another apartment mode, which is fine for our usage.
void EnsureComInitialized() {
  const HRESULT hr = ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
  if (hr == RPC_E_CHANGED_MODE) {
    // Already initialized as MTA; CoCreateInstance still works.
    return;
  }
}

IMMDevice* GetDefaultDevice(bool capture, int role) {
  EnsureComInitialized();
  IMMDeviceEnumerator* enumerator = nullptr;
  const HRESULT hr = ::CoCreateInstance(
      __uuidof(MMDeviceEnumerator), nullptr, CLSCTX_ALL,
      IID_PPV_ARGS(&enumerator));
  if (FAILED(hr) || enumerator == nullptr) {
    return nullptr;
  }
  IMMDevice* device = nullptr;
  const HRESULT dev_hr = enumerator->GetDefaultAudioEndpoint(
      capture ? eCapture : eRender, ToRole(role), &device);
  enumerator->Release();
  if (FAILED(dev_hr)) {
    return nullptr;
  }
  return device;
}

}  // namespace

std::string AylaDefaultAudioDeviceId(bool capture, int role) {
  IMMDevice* device = GetDefaultDevice(capture, role);
  if (device == nullptr) {
    return std::string();
  }
  LPWSTR id = nullptr;
  std::string out;
  if (SUCCEEDED(device->GetId(&id)) && id != nullptr) {
    out = Utf8FromWide(id);
    ::CoTaskMemFree(id);
  }
  device->Release();
  return out;
}

std::string AylaDefaultAudioDeviceName(bool capture, int role) {
  IMMDevice* device = GetDefaultDevice(capture, role);
  if (device == nullptr) {
    return std::string();
  }
  std::string out;
  IPropertyStore* store = nullptr;
  if (SUCCEEDED(device->OpenPropertyStore(STGM_READ, &store)) &&
      store != nullptr) {
    PROPVARIANT value;
    ::PropVariantInit(&value);
    if (SUCCEEDED(store->GetValue(PKEY_Device_FriendlyName, &value)) &&
        value.vt == VT_LPWSTR && value.pwszVal != nullptr) {
      out = Utf8FromWide(value.pwszVal);
    }
    ::PropVariantClear(&value);
    store->Release();
  }
  device->Release();
  return out;
}
