#!/usr/bin/env python3
"""Generate QuakeSignal-owned alert audio without official alert recordings.

Requires Python 3, pyopenjtalk==0.4.1, NumPy, and ffmpeg. pyopenjtalk's
bundled HTS Voice "Mei" is CC BY 3.0; see the bundled ATTRIBUTION.md.
"""

from __future__ import annotations

import argparse
import array
import math
from pathlib import Path
import subprocess
import tempfile
import wave

import numpy as np
import pyopenjtalk


SAMPLE_RATE = 22_050
JAPANESE_MESSAGE = "地震情報です。強い揺れに備え、身の安全を確保してください。"


def write_urgent_wave(path: Path) -> None:
    duration = 2.25
    segments = (
        (0.00, 0.34, 659.25),
        (0.42, 0.82, 880.00),
        (1.10, 1.44, 659.25),
        (1.52, 1.92, 880.00),
    )
    attack = 0.015
    release = 0.025
    samples = array.array("h")
    for index in range(round(duration * SAMPLE_RATE)):
        time = index / SAMPLE_RATE
        value = 0.0
        for start, end, frequency in segments:
            if start <= time < end:
                position = time - start
                remaining = end - time
                envelope = min(1.0, position / attack, remaining / release)
                fundamental = math.sin(2 * math.pi * frequency * position)
                harmonic = 0.14 * math.sin(4 * math.pi * frequency * position)
                value = 0.52 * envelope * (fundamental + harmonic)
                break
        samples.append(round(max(-1.0, min(1.0, value)) * 32767))

    with wave.open(str(path), "wb") as output:
        output.setnchannels(1)
        output.setsampwidth(2)
        output.setframerate(SAMPLE_RATE)
        output.writeframes(samples.tobytes())


def write_japanese_wave(path: Path) -> None:
    waveform, source_rate = pyopenjtalk.tts(JAPANESE_MESSAGE, speed=1.08)
    samples = np.clip(waveform, -32768, 32767).astype("<i2")
    with wave.open(str(path), "wb") as output:
        output.setnchannels(1)
        output.setsampwidth(2)
        output.setframerate(source_rate)
        output.writeframes(samples.tobytes())


def convert_to_caf(source: Path, destination: Path, voice: bool = False) -> None:
    command = [
        "ffmpeg", "-hide_banner", "-loglevel", "error", "-y",
        "-i", str(source),
    ]
    if voice:
        command += ["-af", "highpass=f=90,lowpass=f=9000,afade=t=in:st=0:d=0.02"]
    command += [
        "-ar", str(SAMPLE_RATE), "-ac", "1", "-c:a", "pcm_s16le",
        "-f", "caf", str(destination),
    ]
    subprocess.run(command, check=True)


def main() -> None:
    parser = argparse.ArgumentParser()
    default_output = (
        Path(__file__).resolve().parents[2]
        / "QuakeSignal" / "Resources" / "Audio"
    )
    parser.add_argument("--output-dir", type=Path, default=default_output)
    args = parser.parse_args()
    args.output_dir.mkdir(parents=True, exist_ok=True)

    if getattr(pyopenjtalk, "__version__", None) != "0.4.1":
        raise RuntimeError("Use the reviewed pyopenjtalk==0.4.1 release")

    with tempfile.TemporaryDirectory(prefix="quakesignal-alert-audio-") as temp:
        temp_dir = Path(temp)
        urgent_wave = temp_dir / "urgent.wav"
        japanese_wave = temp_dir / "japanese.wav"
        write_urgent_wave(urgent_wave)
        write_japanese_wave(japanese_wave)
        convert_to_caf(
            urgent_wave,
            args.output_dir / "quakesignal_urgent.caf",
        )
        convert_to_caf(
            japanese_wave,
            args.output_dir / "quakesignal_japanese_voice.caf",
            voice=True,
        )


if __name__ == "__main__":
    main()
