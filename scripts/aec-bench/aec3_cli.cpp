#include "modules/audio_processing/include/audio_processing.h"
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <vector>

static std::vector<int16_t> rd(const char* f) {
  FILE* F = fopen(f, "rb");
  fseek(F, 0, SEEK_END);
  long n = ftell(F) / 2;
  rewind(F);
  std::vector<int16_t> b(n);
  fread(b.data(), 2, n, F);
  fclose(F);
  return b;
}

int main(int argc, char** argv) {
  if (argc < 5) {
    fprintf(stderr, "usage: delay_ms far mic out\n");
    return 1;
  }
  int delay = atoi(argv[1]);
  auto far = rd(argv[2]);
  auto mic = rd(argv[3]);
  size_t n = far.size() < mic.size() ? far.size() : mic.size();
  const int R = 48000, F = R / 100;

  rtc::scoped_refptr<webrtc::AudioProcessing> apm = webrtc::AudioProcessingBuilder().Create();
  webrtc::AudioProcessing::Config cfg;
  cfg.echo_canceller.enabled = true;
  cfg.echo_canceller.mobile_mode = false;
  cfg.echo_canceller.enforce_high_pass_filtering = argc > 5 ? atoi(argv[5]) != 0 : true;
  cfg.noise_suppression.enabled = false;
  cfg.gain_controller1.enabled = false;
  cfg.gain_controller2.enabled = false;
  cfg.high_pass_filter.enabled = false;
  cfg.transient_suppression.enabled = false;
  cfg.pipeline.multi_channel_render = false;
  cfg.pipeline.multi_channel_capture = false;
  apm->ApplyConfig(cfg);

  webrtc::StreamConfig sc(R, 1);
  std::vector<int16_t> out(n, 0);
  int16_t rf[F], cf[F];
  auto t0 = std::chrono::steady_clock::now();
  for (size_t i = 0; i + F <= n; i += F) {
    std::copy(&far[i], &far[i] + F, rf);
    std::copy(&mic[i], &mic[i] + F, cf);
    apm->ProcessReverseStream(rf, sc, sc, rf);
    apm->set_stream_delay_ms(delay);
    apm->ProcessStream(cf, sc, sc, cf);
    std::copy(cf, cf + F, &out[i]);
  }
  double s = std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count();
  FILE* O = fopen(argv[4], "wb");
  fwrite(out.data(), 2, n, O);
  fclose(O);
  auto st = apm->GetStatistics();
  printf("wall %.3fs for %.2fs audio -> %.2f ms/s", s, n / 48000.0, 1000 * s / (n / 48000.0));
  if (st.delay_ms) printf("  est_delay=%dms", *st.delay_ms);
  if (st.echo_return_loss_enhancement) printf("  erle_stat=%.1f", *st.echo_return_loss_enhancement);
  printf("\n");
  return 0;
}
