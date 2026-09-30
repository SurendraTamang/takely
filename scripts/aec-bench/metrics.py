import numpy as np, glob, os, sys
SR = 48000
W = SR // 2  # 0.5 s analysis windows
D = os.path.dirname(os.path.abspath(__file__))


def ld(p):
    return np.fromfile(p, np.int16).astype(np.float64) / 32768.0


def db(p):
    return 10 * np.log10(p + 1e-20)


def xcorr_max(a, b, lo_ms=0, hi_ms=100):
    n = min(len(a), len(b)); a, b = a[:n], b[:n]
    N = 1 << (2 * n).bit_length()
    c = np.fft.irfft(np.fft.rfft(a, N) * np.conj(np.fft.rfft(b, N)), N)
    c /= (np.linalg.norm(a) * np.linalg.norm(b) + 1e-20)
    L = np.arange(int(lo_ms * SR / 1000), int(hi_ms * SR / 1000) + 1)
    k = np.argmax(np.abs(c[L])); return abs(c[L[k]]), L[k] * 1000 / SR


def echo_path_pred(s, m, taps=4096):
    F = 2 * taps; win = np.hanning(F); Sss = np.zeros(F // 2 + 1); Sms = np.zeros(F // 2 + 1, complex)
    for st in range(0, len(s) - F, taps):
        S = np.fft.rfft(s[st:st + F] * win); M = np.fft.rfft(m[st:st + F] * win)
        Sss += np.abs(S) ** 2; Sms += M * np.conj(S)
    h = np.fft.irfft(Sms / (Sss + 1e-6 * Sss.max()), F)[:taps]
    N = 1 << (len(s) + taps).bit_length()
    return np.fft.irfft(np.fft.rfft(s, N) * np.fft.rfft(h, N), N)[:len(s)]


def wpow(x):
    k = len(x) // W; return np.mean(x[:k * W].reshape(k, W) ** 2, axis=1)


res = {}
for seg in (0, 1):
    s = ld(f"{D}/seg{seg}_sys.s16"); m = ld(f"{D}/seg{seg}_mic.s16")
    n = min(len(s), len(m)); s, m = s[:n], m[:n]
    e = echo_path_pred(s, m)
    ps, pm, pr = wpow(s), wpow(m), wpow(m - e)
    expl = 1 - pr / (pm + 1e-20)   # fraction of mic power explained by linear echo of system
    far = (db(ps) > -40) & (expl > 0.5)
    silent = db(ps) < -60
    silent = silent & np.r_[False, silent[:-1]]   # drop the first window after playback stops (echo tail)
    voice = silent & (db(pm) > -55)
    print(f"seg{seg}: {len(ps)} windows, sys>-40dBFS: {(db(ps)>-40).sum()}, far-only picked: {far.sum()}, sys-silent: {silent.sum()} (voice-active {voice.sum()})")
    print("   far-only windows (s):", (np.where(far)[0] * 0.5).tolist())
    print("   silent windows (s):", (np.where(silent)[0] * 0.5).tolist())
    r0, l0 = xcorr_max(m, s)
    print(f"   raw corr {r0:.3f} @ {l0:.1f} ms")
    rows = []
    for p in sorted(glob.glob(f"{D}/out/seg{seg}_*.s16")):
        o = ld(p)[:n]; po = wpow(o)
        erle = db(pm[far].sum()) - db(po[far].sum())
        # skip first 2 s (convergence) for a steady-state ERLE
        f2 = far.copy(); f2[:4] = False
        erle_ss = db(pm[f2].sum()) - db(po[f2].sum()) if f2.any() else float('nan')
        r, l = xcorr_max(o, s)
        ne = db(po[silent].sum()) - db(pm[silent].sum()) if silent.any() else float('nan')
        nv = db(po[voice].sum()) - db(pm[voice].sum()) if voice.any() else float('nan')
        name = os.path.basename(p)[5:-4]
        extra = ""
        q = f"{D}/out/seg1dt_{name}.s16"
        if seg == 1 and os.path.exists(q):
            v = ld(f"{D}/seg1dt_near.s16")[:n]; od = ld(q)[:n]
            nd = od - o   # near-end contribution (dt output minus echo-only output)
            lags = range(0, 1200, 2); lag = max(lags, key=lambda L: abs(np.dot(nd[L:L+SR*10], v[:SR*10])))
            od = np.r_[od[lag:], np.zeros(lag)]
            k = n // W; vv = v[:k*W].reshape(k, W); oo = od[:k*W].reshape(k, W)
            num = (vv * oo).sum(1); den = (vv * vv).sum(1)
            play = db(ps) > -40
            g_sil = 20*np.log10(num[silent].sum()/den[silent].sum()); g_play = 20*np.log10(max(num[play].sum(),1e-9)/den[play].sum())
            extra = f"  | lat {lag/48:.1f}ms synth-voice gain: sys-silent {g_sil:+5.1f} dB, during playback {g_play:+5.1f} dB"
        print(f"   {name:22s} ERLE {erle:5.1f} dB (ss {erle_ss:5.1f})  corr {r:.3f}@{l:.0f}ms  silent dP {ne:+5.1f} dB{extra}")
