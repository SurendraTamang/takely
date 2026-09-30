#include "WebRTCAEC.h"

#include <algorithm>
#include <new>
#include <vector>

#include "api/audio/audio_processing.h"

struct WebRTCAEC {
  rtc::scoped_refptr<webrtc::AudioProcessing> apm;
  webrtc::StreamConfig stream;
  std::vector<float> render;
};

// No C++ exception may cross into C or Swift: every entry point is noexcept and reports failure by value.

extern "C" WebRTCAEC *webrtc_aec_create(int sample_rate) noexcept try {
  if (sample_rate != 16000 && sample_rate != 32000 && sample_rate != 48000) return nullptr;
  auto apm = webrtc::AudioProcessingBuilder().Create();
  if (!apm) return nullptr;
  webrtc::AudioProcessing::Config config;
  config.echo_canceller.enabled = true;
  config.echo_canceller.mobile_mode = false;
  config.echo_canceller.enforce_high_pass_filtering = false;
  config.noise_suppression.enabled = false;
  config.gain_controller1.enabled = false;
  config.gain_controller2.enabled = false;
  config.high_pass_filter.enabled = false;
  config.transient_suppression.enabled = false;
  apm->ApplyConfig(config);
  return new (std::nothrow) WebRTCAEC{apm, webrtc::StreamConfig(sample_rate, 1), std::vector<float>(sample_rate / 100)};
} catch (...) {
  return nullptr;
}

extern "C" int webrtc_aec_analyze_render(WebRTCAEC *aec, const float *frame) noexcept try {
  // ProcessReverseStream writes its (unused) output; keep the caller's frame const.
  std::copy(frame, frame + aec->render.size(), aec->render.begin());
  const float *src = aec->render.data();
  float *dest = aec->render.data();
  return aec->apm->ProcessReverseStream(&src, aec->stream, aec->stream, &dest);
} catch (...) {
  return -1;
}

extern "C" int webrtc_aec_process_capture(WebRTCAEC *aec, float *frame) noexcept try {
  aec->apm->set_stream_delay_ms(0);
  const float *src = frame;
  return aec->apm->ProcessStream(&src, aec->stream, aec->stream, &frame);
} catch (...) {
  return -1;
}

extern "C" void webrtc_aec_destroy(WebRTCAEC *aec) noexcept { delete aec; }
