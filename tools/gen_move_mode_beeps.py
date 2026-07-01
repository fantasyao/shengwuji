"""Generate failure beep sound for move mode.

Output:
  assets/sounds/failure.wav  - 220Hz + 224Hz 拍频"嗡"声, 280ms

注：assets/sounds/success.mp3 由用户提供（nextEditSuggestion.mp3 改名），
本脚本不再生成 success 音效。

Pure NumPy + 16-bit PCM WAV writer (no scipy/external deps).
"""
import struct
from pathlib import Path
import numpy as np


def write_wav(path: Path, samples: np.ndarray, sample_rate: int = 44100) -> None:
    """Write mono 16-bit PCM WAV."""
    n = len(samples)
    # Clip + convert float [-1, 1] to int16
    ints = np.clip(samples, -1.0, 1.0)
    ints = (ints * 32767).astype('<i2')
    data = ints.tobytes()
    with open(path, 'wb') as f:
        f.write(b'RIFF')
        f.write(struct.pack('<I', 36 + len(data)))
        f.write(b'WAVE')
        f.write(b'fmt ')
        # subchunk1 size=16, audio_format=1 (PCM), channels=1,
        # sample_rate, byte_rate=sr*2, block_align=2, bits=16
        f.write(struct.pack('<IHHIIHH', 16, 1, 1, sample_rate,
                            sample_rate * 2, 2, 16))
        f.write(b'data')
        f.write(struct.pack('<I', len(data)))
        f.write(data)


def envelope(n: int, fade_frac: float = 0.15) -> np.ndarray:
    """Attack + release envelope to avoid clicks at start/end."""
    fade_n = max(1, int(n * fade_frac))
    env = np.ones(n, dtype=np.float32)
    env[:fade_n] = np.linspace(0, 1, fade_n, dtype=np.float32)
    env[-fade_n:] = np.linspace(1, 0, fade_n, dtype=np.float32)
    return env


def main() -> None:
    sr = 44100
    # 脚本在 tools/，输出到 ../assets/sounds/（被 pubspec 注册打包进 APK）
    out_dir = Path(__file__).parent.parent / 'assets' / 'sounds'
    out_dir.mkdir(parents=True, exist_ok=True)

    # ── failure.wav: 220Hz + 224Hz beat (low "uhn-uhn"), 280ms ──
    dur_f = 0.28
    nf = int(sr * dur_f)
    tf = np.linspace(0, dur_f, nf, endpoint=False, dtype=np.float32)
    envf = envelope(nf, fade_frac=0.10)
    # Beat between 220 and 224 Hz gives a ~4Hz wobble, feels "wrong"
    wave_f = (
        0.5 * np.sin(2 * np.pi * 220 * tf)
        + 0.5 * np.sin(2 * np.pi * 224 * tf)
    )
    failure = envf * wave_f * 0.55
    write_wav(out_dir / 'failure.wav', failure, sr)
    print(f'OK failure.wav  {nf} samples ({dur_f*1000:.0f}ms)')


if __name__ == '__main__':
    main()

