#!/usr/bin/env python3
"""Create an original, modest-level instrumental for hardware listening tests."""
from pathlib import Path
import argparse
import wave
import numpy as np

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('output', type=Path)
args = parser.parse_args()
rate = 44100
beat = 0.375
# Original repeating melody, MIDI pitches; zero means a rest.
melody = [64, 67, 71, 69, 67, 64, 62, 0, 60, 64, 67, 71, 69, 67, 64, 0,
          65, 69, 72, 71, 69, 65, 64, 0, 62, 67, 71, 74, 71, 67, 64, 0] * 2
signal = np.zeros(int((len(melody) * beat + 1) * rate), dtype=np.float64)
def note(pitch, start, duration, amplitude):
    if not pitch:
        return
    time = np.arange(int(duration * rate)) / rate
    frequency = 440 * 2 ** ((pitch - 69) / 12)
    envelope = np.minimum(time / .012, 1) * np.minimum((duration - time) / .07, 1)
    tone = (np.sin(2*np.pi*frequency*time) + .18*np.sin(4*np.pi*frequency*time)) / 1.18
    first = int(start * rate)
    signal[first:first + len(time)] += amplitude * envelope * tone
for index, pitch in enumerate(melody):
    note(pitch, .35 + index * beat, beat * .9, .23)
    if index % 4 == 0:
        note([48, 45, 53, 43][(index // 8) % 4], .35 + index * beat, beat * 3.5, .10)
assert np.max(np.abs(signal)) < .5
args.output.parent.mkdir(parents=True, exist_ok=True)
pcm = np.rint(signal * 32767).astype('<i2')
with wave.open(str(args.output), 'wb') as stream:
    stream.setnchannels(1)
    stream.setsampwidth(2)
    stream.setframerate(rate)
    stream.writeframes(pcm.tobytes())
print(f'{args.output}: {len(pcm)/rate:.2f}s, peak {np.max(np.abs(signal)):.3f}')
