# Offline echo-cancellation benchmark

To check Takely's own canceller on a local recording, run the opt-in test instead:
`TAKELY_AEC_SEGMENT=~/Movies/Takely/<recording>.takely/segments/segment-000.mov swift test --package-path Packages/TakelyKit --filter EchoRecordingTests`.
The steps below reproduce the engine comparison with the plain AEC3 library.

Measures how much speaker echo AEC3 removes from a local Takely recording. Used to choose the engine for P1b-2 (see `docs/superpowers/specs/2026-09-30-takely-p1b2-echo-cancellation-design.md`). Recordings stay local; don't commit them.

1. Build `webrtc-audio-processing` with `scripts/build-webrtc-apm.sh` (it leaves an install prefix in `build/webrtc-apm/install`).
2. Build the CLI:

   ```bash
   P=build/webrtc-apm
   clang++ -std=c++17 -O2 -DWEBRTC_POSIX -DWEBRTC_MAC \
     -I $P/install/include/webrtc-audio-processing-2 -I $P/src/subprojects/abseil-cpp-20240722.0 \
     scripts/aec-bench/aec3_cli.cpp $P/install/lib/libwebrtc-audio-processing-2.a \
     -framework CoreFoundation -framework Foundation -o build/aec3_cli
   ```

3. Decode one segment (system audio = `0:a:0`, microphone = `0:a:1`) to 48 kHz mono 16-bit, aligned by timestamps, next to `metrics.py`:

   ```bash
   SEG=~/Movies/Takely/<recording>.takely/segments/segment-000.mov
   D=scripts/aec-bench
   ffmpeg -copyts -i "$SEG" -map 0:a:0 -af "aresample=async=1:first_pts=0" -ac 1 -ar 48000 -f s16le $D/seg0_sys.s16
   ffmpeg -copyts -i "$SEG" -map 0:a:1 -af "aresample=async=1:first_pts=0" -ac 1 -ar 48000 -f s16le $D/seg0_mic.s16
   ```

4. Run AEC3 (delay hint 0 ms, high-pass filter off) and score it:

   ```bash
   mkdir -p $D/out
   build/aec3_cli 0 $D/seg0_sys.s16 $D/seg0_mic.s16 $D/out/seg0_aec3.s16 0
   python3 $D/metrics.py   # needs numpy; reads seg{0,1}_*.s16 and out/
   ```

`metrics.py` reports ERLE over windows where system audio plays, the mic-vs-system correlation before and after (target < 0.05), and the level change while nothing plays (voice preservation).
