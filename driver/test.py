"""Sanal ses hattını sınar: "Asistan Sanal Çıkış"a 440 Hz ton çalar, aynı anda
"Asistan Sanal Mikrofon"dan kaydeder ve tonun geri gelip gelmediğini söyler.
Terminal ilk seferde mikrofon izni isteyebilir."""
import sys
import unicodedata

import numpy as np
import sounddevice as sd

OUT, IN, RATE, SECONDS, FREQ = "Asistan Sanal Çıkış", "Asistan Sanal Mikrofon", 48000, 2.0, 440.0


def find(name, kind):
    wanted = unicodedata.normalize("NFC", name).casefold()
    for index, device in enumerate(sd.query_devices()):
        if unicodedata.normalize("NFC", device["name"]).casefold() == wanted and device[f"max_{kind}_channels"] > 0:
            return index
    sys.exit(f"Bulunamadı: {name}. Sürücü kurulu mu? (bash driver/install.sh)")


out_idx, in_idx = find(OUT, "output"), find(IN, "input")
t = np.arange(int(RATE * SECONDS)) / RATE
tone = (0.3 * np.sin(2 * np.pi * FREQ * t)).astype("float32")
recorded = []


def on_input(data, frames, time, status):
    recorded.append(data[:, 0].copy())


with sd.InputStream(device=in_idx, channels=2, samplerate=RATE, dtype="float32", callback=on_input):
    sd.play(np.column_stack([tone, tone]), RATE, device=out_idx, blocking=True)

audio = np.concatenate(recorded) if recorded else np.zeros(1, dtype="float32")
rms = float(np.sqrt(np.mean(audio ** 2)))
spectrum = np.abs(np.fft.rfft(audio))
peak = float(np.fft.rfftfreq(len(audio), 1 / RATE)[int(np.argmax(spectrum))]) if audio.size > 1 else 0.0
print(f"Kaydedilen: {audio.size / RATE:.1f} sn, seviye (RMS) {rms:.3f}, baskın frekans {peak:.0f} Hz")
if rms > 0.05 and abs(peak - FREQ) < 5:
    print("BAŞARILI: Çıkışa çalınan ses mikrofondan geri geldi.")
else:
    sys.exit("BAŞARISIZ: Ton mikrofondan gelmedi (ya da Terminal'in mikrofon izni yok).")
