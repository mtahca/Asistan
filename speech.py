"""Speech-to-text back ends besides Whisper: Deepgram Nova-3 (cloud) and Apple's on-device
dictation model through the bundled asistan-speech helper. Both take 16 kHz mono float audio
of one finished utterance and return its Turkish text."""
from __future__ import annotations
import io
import json
import os
import queue
import subprocess
import tempfile
import threading
import wave
from pathlib import Path

DEEPGRAM_URL = 'https://api.deepgram.com/v1/listen'
DEEPGRAM_MODEL = 'nova-3'


class SpeechError(RuntimeError):
    """Credential-free messages that may reach the UI."""


def wav_bytes(audio, np, rate=16000) -> bytes:
    pcm = (np.clip(audio, -1, 1) * 32767).astype('<i2').tobytes()
    out = io.BytesIO()
    with wave.open(out, 'wb') as w:
        w.setnchannels(1); w.setsampwidth(2); w.setframerate(rate); w.writeframes(pcm)
    return out.getvalue()


def deepgram_text(body) -> str:
    try:
        return body['results']['channels'][0]['alternatives'][0]['transcript'].strip()
    except (KeyError, IndexError, TypeError, AttributeError):
        raise SpeechError('Deepgram yanıtı okunamadı.') from None


class DeepgramSTT:
    """One HTTP request per utterance; the connection is kept alive between turns."""
    def __init__(self, key: str, np, client=None, timeout=10.0):
        if len(key.strip()) <= 20:
            raise SpeechError('Deepgram için API anahtarı girin.')
        import httpx
        self.np = np
        self.client = client or httpx.Client(timeout=timeout)
        self.headers = {'Authorization': 'Token ' + key.strip(), 'Content-Type': 'audio/wav'}
        self.params = {'model': DEEPGRAM_MODEL, 'language': 'tr', 'smart_format': 'true', 'punctuate': 'true'}

    def transcribe(self, audio) -> str:
        try:
            r = self.client.post(DEEPGRAM_URL, params=self.params, headers=self.headers, content=wav_bytes(audio, self.np))
        except Exception:
            raise SpeechError('Deepgram\'a ulaşılamadı. İnternet bağlantısını kontrol edin.') from None
        if r.status_code == 401: raise SpeechError('Deepgram anahtarı kabul edilmedi.')
        if r.status_code == 402: raise SpeechError('Deepgram hesabında kredi kalmadı.')
        if r.status_code == 429: raise SpeechError('Deepgram hız sınırı. Hesap kullanımını kontrol edin.')
        if r.status_code >= 400: raise SpeechError(f'Deepgram isteği kabul edilmedi ({r.status_code}).')
        try: body = r.json()
        except ValueError: raise SpeechError('Deepgram yanıtı okunamadı.') from None
        return deepgram_text(body)

    def close(self):
        try: self.client.close()
        except Exception: pass


def helper_path() -> Path:
    """The app bundle sets ASISTAN_SPEECH_HELPER; a source checkout falls back to Asistan.app."""
    configured = os.getenv('ASISTAN_SPEECH_HELPER', '')
    if configured: return Path(configured)
    return Path(__file__).resolve().parent.parent / 'MacOS' / 'asistan-speech'


class AppleSTT:
    """Talks to the asistan-speech helper: one JSON line in ({"path": wav}), one JSON line out
    ({"text": …} or {"error": …}). The helper prints {"ready": true} once the Turkish model is
    installed, which can take a while on first use."""
    def __init__(self, np, path: Path | None = None, ready_timeout=180.0, popen=subprocess.Popen):
        self.np = np
        path = path or helper_path()
        if not path.exists():
            raise SpeechError('Apple konuşma tanıma yardımcısı bulunamadı. Asistan\'ı yeniden derleyin.')
        self.lines: queue.Queue = queue.Queue()
        self.lock = threading.Lock()
        self.proc = popen([str(path)], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True, bufsize=1)
        threading.Thread(target=self._read, daemon=True).start()
        first = self._next(ready_timeout)
        if not first.get('ready'):
            self.close()
            raise SpeechError(first.get('error') or 'Apple konuşma tanıma başlatılamadı.')

    def _read(self):
        for line in self.proc.stdout:
            try: self.lines.put(json.loads(line))
            except ValueError: continue
        self.lines.put({'error': 'Apple konuşma tanıma yardımcısı kapandı.'})

    def _next(self, timeout):
        try: return self.lines.get(timeout=timeout)
        except queue.Empty:
            raise SpeechError('Apple konuşma tanıma zamanında yanıt vermedi.') from None

    def transcribe(self, audio) -> str:
        with self.lock, tempfile.NamedTemporaryFile(suffix='.wav') as f:
            f.write(wav_bytes(audio, self.np)); f.flush()
            try:
                self.proc.stdin.write(json.dumps({'path': f.name}) + '\n'); self.proc.stdin.flush()
            except (BrokenPipeError, OSError):
                raise SpeechError('Apple konuşma tanıma yardımcısı kapandı.') from None
            reply = self._next(20)
        if 'error' in reply: raise SpeechError(str(reply['error'])[:200])
        return str(reply.get('text', '')).strip()

    def close(self):
        try:
            self.proc.stdin.close(); self.proc.wait(timeout=2)
        except Exception:
            try: self.proc.kill()
            except Exception: pass
