#ifndef RUNNER_AUDIO_DEFAULT_DEVICE_H_
#define RUNNER_AUDIO_DEFAULT_DEVICE_H_

#include <string>

// Queries the OS default audio endpoint through Windows CoreAudio.
//
// Why this exists: WebRTC's Windows audio device module defaults to the
// "default communication device", which on many machines is a DIFFERENT
// physical endpoint than the user's normal "default device". That makes remote
// voice render into the wrong output (e.g. onboard speakers instead of the
// user's headphones) while the rest of the system still uses the right one.
//
// role: 0 = eConsole, 1 = eMultimedia (the normal "default device"),
//       2 = eCommunications (the "default communication device").
// Returns an empty string when the query fails.
std::string AylaDefaultAudioDeviceId(bool capture, int role);
std::string AylaDefaultAudioDeviceName(bool capture, int role);

#endif  // RUNNER_AUDIO_DEFAULT_DEVICE_H_
