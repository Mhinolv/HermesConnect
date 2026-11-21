#!/usr/bin/env python3
"""Issue #149: render the Hands-Free thinking sound (owner pick: sample B "Heartbeat").

One loop: a soft low double pulse ("lub-dub", 78 Hz then 66 Hz), 1.6 s long.
The pulse ends in silence, so the loop has no click at the seam.
Output: HermesConnect/Resources/ThinkingSound/thinking-heartbeat.m4a (48 kHz mono AAC, like the ack clips).
Run on the Mac: python3 -I scripts/render_thinking_sound.py. It needs afconvert. Nothing goes to the network.
"""
import math
import os
import struct
import subprocess
import tempfile
import wave

SR = 48000
PERIOD = 1.6
PEAK_DB = -18.0
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "HermesConnect", "Resources", "ThinkingSound", "thinking-heartbeat.m4a")


def thump(dt, freq, amp):
    if dt < 0 or dt > 0.35:
        return 0.0
    attack = min(1.0, dt / 0.012)
    return amp * attack * math.exp(-dt / 0.07) * math.sin(2 * math.pi * freq * dt * (1 - 0.25 * dt))


def render():
    raw = [thump(i / SR, 78.0, 1.0) + thump(i / SR - 0.28, 66.0, 0.6) for i in range(int(SR * PERIOD))]
    # A gentle low-pass takes out the click of the attack.
    out, state = [], 0.0
    k = 1 - math.exp(-2 * math.pi * 400 / SR)
    for value in raw:
        state += k * (value - state)
        out.append(state)
    gain = 10 ** (PEAK_DB / 20) / max(abs(v) for v in out)
    return [v * gain for v in out]


def main():
    samples = render()
    with tempfile.TemporaryDirectory() as tmp:
        wav = os.path.join(tmp, "thinking-heartbeat.wav")
        with wave.open(wav, "wb") as w:
            w.setnchannels(1)
            w.setsampwidth(2)
            w.setframerate(SR)
            w.writeframes(b"".join(struct.pack("<h", int(max(-1, min(1, s)) * 32767)) for s in samples))
        subprocess.run(["afconvert", "-f", "m4af", "-d", "aac", "-b", "96000", wav, OUT], check=True)
    print(OUT)


if __name__ == "__main__":
    main()
