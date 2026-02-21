#!/usr/bin/env python3
"""
Compare our Swift mel spectrogram implementation against HuggingFace WhisperFeatureExtractor.
Generates a known signal (440 Hz sine), runs it through Python reference, and prints
the values for side-by-side comparison with Swift debug logs.

Usage:
    python3 scripts/compare_mel.py

Requirements:
    pip install transformers numpy
"""

import numpy as np

# ---------------------------------------------------------------------------
# Parameters (must match MelSpectrogram.swift)
# ---------------------------------------------------------------------------
SAMPLE_RATE = 16000
N_FFT = 400
HOP_LENGTH = 160
N_MELS = 128
F_MIN = 0.0
F_MAX = SAMPLE_RATE / 2.0
DURATION = 1.0  # seconds

# ---------------------------------------------------------------------------
# Generate test signal: 440 Hz sine wave, 1 second
# ---------------------------------------------------------------------------
t = np.linspace(0, DURATION, int(SAMPLE_RATE * DURATION), endpoint=False)
signal = np.sin(2 * np.pi * 440 * t).astype(np.float32)
print(f"Signal: {len(signal)} samples, 440 Hz sine, 1 second")
print(f"Signal range: min={signal.min():.4f}, max={signal.max():.4f}")
print()

# ---------------------------------------------------------------------------
# Method 1: HuggingFace WhisperFeatureExtractor
# ---------------------------------------------------------------------------
try:
    from transformers import WhisperFeatureExtractor

    fe = WhisperFeatureExtractor(
        feature_size=N_MELS,
        sampling_rate=SAMPLE_RATE,
        hop_length=HOP_LENGTH,
        chunk_length=30,
        n_fft=N_FFT,
    )
    inputs = fe(signal, sampling_rate=SAMPLE_RATE, return_tensors="np")
    hf_mel = inputs["input_features"][0]  # shape: (128, T)
    # Transpose to (T, 128) to match our layout
    hf_mel = hf_mel.T
    print(f"HuggingFace WhisperFeatureExtractor output shape: {hf_mel.shape}")
    print(
        f"HF mel range: min={hf_mel.min():.4f}, max={hf_mel.max():.4f}, mean={hf_mel.mean():.4f}"
    )
    print(f"HF mel first frame: {hf_mel[0, :8]}")
    print(f"HF mel second frame: {hf_mel[1, :8]}")
    print()
    HF_AVAILABLE = True
except ImportError:
    print("transformers not installed — skipping HuggingFace comparison")
    print("Install: pip install transformers")
    print()
    HF_AVAILABLE = False


# ---------------------------------------------------------------------------
# Method 2: Manual Python implementation (mirrors what Swift should do)
# ---------------------------------------------------------------------------
def hz_to_mel(hz):
    return 2595.0 * np.log10(1.0 + hz / 700.0)


def mel_to_hz(mel):
    return 700.0 * (10.0 ** (mel / 2595.0) - 1.0)


def create_mel_filterbank(n_fft, n_mels, sample_rate, f_min, f_max):
    """Matches librosa/HuggingFace mel filterbank exactly."""
    n_freqs = n_fft // 2 + 1

    mel_min = hz_to_mel(f_min)
    mel_max = hz_to_mel(f_max)

    # n_mels + 2 evenly-spaced points in mel space
    mel_points = np.linspace(mel_min, mel_max, n_mels + 2)
    hz_points = mel_to_hz(mel_points)

    # Convert hz to FFT bin numbers using n_fft (NOT n_fft+1)
    bin_points = np.floor((n_fft + 1) * hz_points / sample_rate).astype(int)
    # NOTE: HuggingFace/librosa use (n_fft + 1) here for the bin calculation,
    # which differs from raw nFft. Let's print both for comparison.

    filterbank = np.zeros((n_mels, n_freqs))
    for i in range(n_mels):
        left = bin_points[i]
        center = bin_points[i + 1]
        right = bin_points[i + 2]

        if center > left:
            for j in range(max(0, left), min(n_freqs, center)):
                filterbank[i, j] = (j - left) / (center - left)
        if right > center:
            for j in range(max(0, center), min(n_freqs, right)):
                filterbank[i, j] = (right - j) / (right - center)

    return filterbank


def compute_mel_manual(
    signal,
    sample_rate=SAMPLE_RATE,
    n_fft=N_FFT,
    hop_length=HOP_LENGTH,
    n_mels=N_MELS,
    f_min=F_MIN,
    f_max=F_MAX,
    hann_type="periodic",
):
    """
    Manual mel spectrogram matching WhisperFeatureExtractor.
    hann_type: "periodic" = numpy hanning (peak=1, what Whisper uses)
               "symmetric" = scipy hann symmetric window
    """
    # Reflect pad
    pad = n_fft // 2
    padded = np.pad(signal, pad, mode="reflect")

    # Hann window
    if hann_type == "periodic":
        # numpy.hanning(N) gives a periodic Hann of length N (peak = 1)
        window = np.hanning(n_fft).astype(np.float32)
    else:
        # symmetric
        window = np.hanning(n_fft + 1)[:-1].astype(np.float32)

    n_frames = (len(padded) - n_fft) // hop_length + 1
    mel_filterbank = create_mel_filterbank(n_fft, n_mels, sample_rate, f_min, f_max)

    mel_spec = []
    for i in range(n_frames):
        frame = padded[i * hop_length : i * hop_length + n_fft]
        windowed = frame * window
        spectrum = np.fft.rfft(windowed, n=n_fft)
        power = np.abs(spectrum) ** 2
        mel = mel_filterbank @ power
        mel = np.maximum(mel, 1e-10)
        mel = np.log10(mel)
        mel_spec.append(mel)

    mel_spec = np.array(mel_spec, dtype=np.float32)  # (T, n_mels)

    # Global normalization
    global_max = mel_spec.max()
    mel_spec = np.maximum(mel_spec, global_max - 8.0)
    mel_spec = (mel_spec + 4.0) / 4.0

    return mel_spec


print("--- Manual Python (periodic Hann, n_fft+1 bin calc) ---")
mel_periodic = compute_mel_manual(signal, hann_type="periodic")
print(f"Shape: {mel_periodic.shape}")
print(
    f"Range: min={mel_periodic.min():.4f}, max={mel_periodic.max():.4f}, mean={mel_periodic.mean():.4f}"
)
print(f"First frame: {mel_periodic[0, :8]}")
print(f"Second frame: {mel_periodic[1, :8]}")
print()

# ---------------------------------------------------------------------------
# Compare HF vs Manual if both available
# ---------------------------------------------------------------------------
if HF_AVAILABLE:
    T = min(hf_mel.shape[0], mel_periodic.shape[0])
    diff = hf_mel[:T] - mel_periodic[:T]
    print(f"--- HF vs Manual Python diff (first {T} frames) ---")
    print(f"Max absolute diff: {np.abs(diff).max():.6f}")
    print(f"Mean absolute diff: {np.abs(diff).mean():.6f}")
    print(f"First frame diff: {diff[0, :8]}")
    print()

# ---------------------------------------------------------------------------
# Print filterbank diagnostic
# ---------------------------------------------------------------------------
print("--- Mel filterbank bin points (first 10 filters) ---")
mel_min = hz_to_mel(F_MIN)
mel_max = hz_to_mel(F_MAX)
mel_pts = np.linspace(mel_min, mel_max, N_MELS + 2)
hz_pts = mel_to_hz(mel_pts)

bins_nfft_plus1 = np.floor((N_FFT + 1) * hz_pts / SAMPLE_RATE).astype(int)
bins_nfft = np.floor(N_FFT * hz_pts / SAMPLE_RATE).astype(int)

print(f"{'mel_idx':>8}  {'hz':>8}  {'bin(nFft+1)':>12}  {'bin(nFft)':>10}")
for i in range(min(12, N_MELS + 2)):
    print(f"{i:>8}  {hz_pts[i]:>8.2f}  {bins_nfft_plus1[i]:>12}  {bins_nfft[i]:>10}")
print("...")

# ---------------------------------------------------------------------------
# Print Hann window comparison
# ---------------------------------------------------------------------------
print()
print("--- Hann window comparison (first 10 samples of 400-length window) ---")
hann_numpy = np.hanning(N_FFT).astype(np.float32)  # periodic, peak=1
hann_vdsp = np.hanning(N_FFT + 1)[:-1].astype(
    np.float32
)  # symmetric (what vDSP_HANN_NORM gives)

# vDSP_HANN_NORM normalizes so that the sum = 1 (energy-preserving), amplitude ≠ 1
# Let's simulate: symmetric window scaled by 2/N
hann_vdsp_norm = (
    hann_vdsp * 2.0 / N_FFT
)  # typical NORM scaling (sum ≈ 1 instead of N/2)

print(f"{'i':>4}  {'numpy (periodic)':>18}  {'vDSP_HANN_NORM approx':>22}")
for i in range(10):
    print(f"{i:>4}  {hann_numpy[i]:>18.6f}  {hann_vdsp_norm[i]:>22.6f}")
print(
    f"  Sum: {hann_numpy.sum():.4f} (numpy)  vs  {hann_vdsp_norm.sum():.4f} (vDSP_NORM approx)"
)
print(
    f"  Max: {hann_numpy.max():.4f} (numpy)  vs  {hann_vdsp_norm.max():.4f} (vDSP_NORM approx)"
)
print()
print(
    "=> numpy hanning peaks at 1.0, vDSP_HANN_NORM peaks at 2/N ≈ 0.005 (400-pt window)"
)
print("=> This is a factor of 500x amplitude difference!")
print("=> Power spectrum will differ by 500^2 = 250,000x !!!")
