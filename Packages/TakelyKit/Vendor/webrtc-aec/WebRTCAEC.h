#ifndef WEBRTC_AEC_H
#define WEBRTC_AEC_H

#ifdef __cplusplus
#define WEBRTC_AEC_NOEXCEPT noexcept
extern "C" {
#else
#define WEBRTC_AEC_NOEXCEPT
#endif

/// WebRTC AEC3 echo canceller for one mono stream. Only echo cancellation is enabled
/// (no noise suppression, gain control or high-pass filter). Frames are 10 ms: sample_rate / 100 samples,
/// Float32 in [-1, 1]. Not thread-safe: use one instance from one thread at a time.
typedef struct WebRTCAEC WebRTCAEC;

/// Returns NULL if the sample rate isn't supported (use 16000, 32000 or 48000).
WebRTCAEC *webrtc_aec_create(int sample_rate) WEBRTC_AEC_NOEXCEPT;

/// Feeds 10 ms of far-end (loudspeaker) audio. Returns 0 on success.
int webrtc_aec_analyze_render(WebRTCAEC *aec, const float *frame) WEBRTC_AEC_NOEXCEPT;

/// Removes the echo from 10 ms of near-end (microphone) audio in place. Returns 0 on success.
int webrtc_aec_process_capture(WebRTCAEC *aec, float *frame) WEBRTC_AEC_NOEXCEPT;

void webrtc_aec_destroy(WebRTCAEC *aec) WEBRTC_AEC_NOEXCEPT;

#ifdef __cplusplus
}
#endif

#endif
