# -*- coding: utf-8 -*-
"""
OpenAI Realtime (uçtan uca sesli) konuşma modu.

Klasik hat (Whisper -> LLM -> yerel TTS) olduğu gibi durur. Bu modül yalnızca .env'de
CONVERSATION_MODE=realtime ise kullanılır; kurulamazsa agent.py klasik hatta döner.

Akış:  Asistan Dinleme (arayan) -> 24 kHz PCM -> Realtime WebSocket -> 24 kHz PCM -> Asistan Ses Çıkışı

Ayarlar (.env, hepsi isteğe bağlı):
  RT_MODEL=gpt-realtime          (daha ucuz: gpt-realtime-mini)
  RT_VOICE=marin                 (ör. cedar, alloy, coral, sage, verse ...)
  RT_VAD=server | semantic       RT_VAD_THRESHOLD=0.6   RT_SILENCE_MS=500
  RT_TRANSCRIBE_MODEL=gpt-4o-transcribe   (dökümde "Arayan:" satırları için)
  RT_MAX_MIN=10                  (bir görüşmenin en uzun süresi, maliyet güvenliği)
"""
from __future__ import annotations

import base64
import io
import json
import os
import queue
import sys
import threading
import time
import wave
from collections import deque

import numpy as np
import sounddevice as sd

RT_MODEL = os.getenv("RT_MODEL", "gpt-realtime").strip()
RT_VOICE = os.getenv("RT_VOICE", "marin").strip()
RT_URL = os.getenv("RT_URL", "wss://api.openai.com/v1/realtime").strip()
RT_TRANSCRIBE = os.getenv("RT_TRANSCRIBE_MODEL", "gpt-4o-transcribe").strip()
RT_VAD = os.getenv("RT_VAD", "server").strip().lower()
RT_VAD_THRESHOLD = float(os.getenv("RT_VAD_THRESHOLD", "0.6"))
RT_SILENCE_MS = int(os.getenv("RT_SILENCE_MS", "500"))
RT_MAX_MIN = float(os.getenv("RT_MAX_MIN", "10"))
RT_GREETING = os.getenv("RT_GREETING", "local").strip().lower()      # local = hazır yerel ses | model = karşılamayı Realtime söyler
RT_GREETING_DELAY_S = float(os.getenv("RT_GREETING_DELAY_S", "0"))   # model karşılamasında bağlantıdan sonra ek bekleme
CALLER_STT = os.getenv("CALLER_STT", "openai").strip().lower()      # openai (gpt-4o-transcribe) | local (Whisper) | model (modelin kendi dökümü)
CALLER_STT_MODEL = os.getenv("CALLER_STT_MODEL", "gpt-4o-transcribe").strip()
RATE = 24000
END_TOOL = "gorusmeyi_bitir"


def _resample(x: np.ndarray, r_in: int, r_out: int) -> np.ndarray:
    x = np.asarray(x, dtype=np.float32)
    if r_in == r_out or not len(x):
        return x
    if r_in % r_out == 0:
        k = r_in // r_out
        n = len(x) // k * k
        return x[:n].reshape(-1, k).mean(axis=1)
    n_out = max(1, int(round(len(x) * r_out / r_in)))
    return np.interp(np.linspace(0, len(x) - 1, n_out), np.arange(len(x)), x).astype(np.float32)


# gpt-4o-transcribe için hayali sonuç listesi ("Teşekkürler." burada yok: gerçek bir söz olabilir)
CT_HALLUC = ("altyazı", "abone ol", "izlediğiniz için", "izlediğin için", "kanalımıza", "beğenmeyi unutmayın",
             "iyi seyirler", "devam edecek", "sesli betimleme", "bu dizinin")
SHORT_SUSPECT = {"teşekkürler.", "teşekkürler", "teşekkür ederim.", "teşekkür ederim", "tamam.", "abone ol."}


class CallerTranscriber:
    """Arayanın sesini yerel enerji ölçümüyle konuşma parçalarına böler; her parçayı ayrı bir yazıya dökme
    motoruyla (gpt-4o-transcribe, hata olursa yerel Whisper) çıkarır ve canlı pencereye "ARAYAN:" satırı olarak basar.
    Modelin kendi dökümünden bağımsızdır: model sesi doğrudan duyar, bu döküm yalnızca ekran ve not içindir."""
    FRAME_S = 0.03

    def __init__(self, conv):
        self.c = conv
        self.M = conv.M
        self.rate = conv.a.in_rate
        self.mode = CALLER_STT
        self.q: queue.Queue = queue.Queue()
        self.pre: deque = deque(maxlen=8)
        self.frames: list = []
        self.active = False
        self.loud = 0
        self.quiet = 0
        self.voiced = 0
        self.thr = max(0.004, float(self.M.VAD_THRESHOLD))
        self.min_voiced = int(0.12 / self.FRAME_S)       # "Bir", "Evet" gibi çok kısa sözler de yakalansın
        self.end_frames = int(0.7 / self.FRAME_S)
        self.max_frames = int(25 / self.FRAME_S)
        self.client = None
        self.fails = 0
        self.use_openai = (self.mode == "openai")
        self.worker = threading.Thread(target=self._run, daemon=True)
        self.worker.start()

    def feed(self, mono: np.ndarray) -> None:
        voiced = float(np.sqrt(np.mean(mono * mono))) > self.thr
        if not self.active:
            self.pre.append(mono.copy())
            self.loud = self.loud + 1 if voiced else 0
            if self.loud >= 2:
                self.active = True
                self.frames = list(self.pre)
                self.quiet = 0
                self.voiced = self.loud
            return
        self.frames.append(mono.copy())
        if voiced:
            self.voiced += 1
            self.quiet = 0
        else:
            self.quiet += 1
        if self.quiet >= self.end_frames or len(self.frames) >= self.max_frames:
            self._cut()

    def _cut(self) -> None:
        frames, voiced, quiet = self.frames, self.voiced, self.quiet
        self.active = False
        self.frames = []
        self.loud = self.quiet = self.voiced = 0
        self.pre.clear()
        if voiced >= self.min_voiced and frames:
            self.q.put((time.time() - quiet * self.FRAME_S, np.concatenate(frames), voiced * self.FRAME_S))

    def close(self, timeout: float = 8.0) -> None:
        try:
            if self.active:
                self._cut()
            self.q.put(None)
            self.worker.join(timeout)
        except Exception:
            pass

    def _openai(self, audio: np.ndarray) -> str:
        if self.client is None:
            from openai import OpenAI
            self.client = OpenAI(timeout=20, max_retries=1)
        a16 = np.clip(_resample(audio, self.rate, 16000), -1.0, 1.0)
        buf = io.BytesIO()
        with wave.open(buf, "wb") as w:
            w.setnchannels(1)
            w.setsampwidth(2)
            w.setframerate(16000)
            w.writeframes((a16 * 32767.0).astype("<i2").tobytes())
        r = self.client.audio.transcriptions.create(
            model=CALLER_STT_MODEL, file=("kayit.wav", buf.getvalue(), "audio/wav"), language="tr",
            prompt=f"{self.M.OWNER} Bey'in telefon asistanıyla Türkçe bir telefon görüşmesi.")
        return (getattr(r, "text", "") or "").strip()

    def _local(self, audio: np.ndarray) -> str:
        a = self.c.a
        with a._stt_lock:
            return a._stt(self.M.to_16k(audio, self.rate))

    def _fallback(self, t_end: float, vdur: float) -> None:
        """Kısa/anlaşılmayan parçada modelin kendi dökümünden, zamanı yakın olanı al; yoksa belirsizlik notu düş."""
        try:
            text = self.c._model_text_near(t_end)
            if text:
                self.c._caller_line(t_end, text)
            elif vdur >= 0.4:
                self.c._caller_line(t_end, "(kısa bir şey söyledi, anlaşılamadı)")
        except Exception:
            pass

    def _run(self) -> None:
        M = self.M
        while True:
            item = self.q.get()
            if item is None:
                return
            t_end, audio, vdur = item
            t0 = time.time()
            text = ""
            try:
                if self.use_openai:
                    try:
                        text = self._openai(audio)
                        self.fails = 0
                    except Exception as e:
                        self.fails += 1
                        M.log(f"   gpt-4o-transcribe hatası ({e!r}); yerel Whisper'a düşülüyor")
                        if self.fails >= 3:
                            self.use_openai = False
                            M.log("   gpt-4o-transcribe art arda hata verdi; bu görüşmede yerel Whisper kullanılacak")
                        text = self._local(audio)
                else:
                    text = self._local(audio)
            except Exception as e:
                M.log(f"   döküm hatası: {e!r}")
                continue
            text = M.collapse_repeats(text.strip())
            low = text.lower().strip()
            bad = len(text) < 2 or (any(h in low for h in CT_HALLUC) and len(low.split()) <= 6)
            if "telefon asistanıyla" in low or "telefon görüşmesi" in low:
                bad = True          # sessizlikte transkripsiyon istemini aynen geri yazma
            if not bad and vdur < 0.8 and low in SHORT_SUSPECT:
                bad = True          # kısa tek sözcük "Teşekkürler." gibi hayali bir sonuca dönmüş olabilir
            if bad:
                M.log(f"   (döküm şüpheli/boş: {text!r}, {vdur:.1f} sn ses; modelin dökümüne bakılacak)")
                if vdur >= 0.2:
                    threading.Timer(2.6, self._fallback, (t_end, vdur)).start()
                continue
            M.log(f"   döküm: {time.time() - t0:.2f} sn ({len(audio) / self.rate:.1f} sn ses)")
            self.c._caller_line(t_end, text)


class RealtimeConversation:
    def __init__(self, agent):
        self.a = agent
        self.M = sys.modules[type(agent).__module__]    # agent.py'nin ayarları ve yardımcıları
        self.ws = None
        self.send_lock = threading.Lock()
        self.stop = threading.Event()
        self.reason = ""
        self.play_buf = bytearray()                       # mono float32, çıkış aygıtının hızında
        self.play_lock = threading.Lock()
        self.out_rate = 48000
        self.produced = 0                                 # mevcut cevap öğesi için üretilen örnek sayısı
        self.cur_item = None
        self.discard_audio = False                        # araya girildi: iptal edilen cevabın artık seslerini at
        self.responding = False
        self.resp_count = 0
        self.pending_response = False
        self.end_requested = False
        self.greeting_active = False
        self.user_speaking = False
        self.gate_open_at = float("inf")                  # bu ana kadar arayan sesi sunucuya gönderilmez
        self.arm_at = float("inf")                        # karşılama bu andan sonra kesilebilir
        self.last_activity = time.time()
        self.t_speech_stop = None
        self.first_audio_logged = True
        self.transcript: list = []
        self.entries: list = []          # [zaman, satır]; görüşme sonunda zamana göre sıralanıp transcript'e yazılır
        self.ct = None                   # CallerTranscriber (CALLER_STT != model ise)
        self.resp_t0 = None
        self.model_in: list = []         # modelin kendi dökümü [zaman, metin, kullanıldı]; kısa parçalarda yedek
        self.in_q: list = []
        self.greet_pending = False     # model karşılaması: ilk asistan dökümü transcript[0]'ın yerine geçer
        self.t_greet_req = None
        self.resp_audio = 0            # bu cevap için çalınmak üzere alınan ses örneği (çıkış hızında)

    # -- yardımcılar -----------------------------------------------------
    def _send(self, obj: dict) -> None:
        with self.send_lock:
            self.ws.send(json.dumps(obj))

    def _note_model_text(self, t: float, text: str) -> None:
        self.model_in.append([t, text, False])
        del self.model_in[:-20]

    def _model_text_near(self, t_end: float) -> str:
        best = None
        for e in self.model_in:
            if not e[2] and abs(e[0] - t_end) <= 3.0 and (best is None or abs(e[0] - t_end) < abs(best[0] - t_end)):
                best = e
        if best is None:
            return ""
        best[2] = True
        return best[1]

    def _add(self, t: float, line: str) -> None:
        self.entries.append([t, line])

    def _caller_line(self, t: float, text: str) -> None:
        self.M.log(f"ARAYAN: {text}")
        self._add(t, f"Arayan: {text}")

    def _buf_len(self) -> int:
        with self.play_lock:
            return len(self.play_buf)

    def _flush(self) -> None:
        with self.play_lock:
            self.play_buf.clear()

    def _push_audio(self, mono_out: np.ndarray) -> None:
        with self.play_lock:
            self.play_buf += np.ascontiguousarray(mono_out, dtype=np.float32).tobytes()

    def _instructions(self) -> str:
        M = self.M
        p = self.a.system_prompt
        p = p.replace(f"cevabının EN SONUNA {M.END_TOKEN} yaz", f"ardından {END_TOOL} aracını çağır")
        p = p.replace(f"sonuna {M.END_TOKEN} yaz", f"ardından {END_TOOL} aracını çağır")
        p = p.replace(f"{M.LLM_MODEL} ({M.LLM_PROVIDER})", f"{RT_MODEL} (openai realtime)")
        p += (
            "\nSesli görüşme kuralları: Yalnızca Türkçe konuş. Doğal ve sakin konuş, sohbet eder gibi; acele etme ama gereksiz uzatma. "
            "Anlaşılmayan, gürültü gibi ya da boş sesleri cevaplama. "
            f"Görüşmeyi bitirirken önce sesli olarak vedalaş, sonra {END_TOOL} aracını çağır; aracı vedalaşmadan çağırma. "
            "Arayan açıkça vedalaşmadıkça, kapatmak istemedikçe ya da ek bir şey yok demedikçe görüşmeyi bitirme; "
            "arayan sohbet ediyor, bir şey soruyor ya da test yapıyorsa konuşmaya devam et.\n"
        )
        return p

    def _session(self) -> dict:
        if RT_VAD == "semantic":
            turn = {"type": "semantic_vad", "eagerness": "high",
                    "create_response": True, "interrupt_response": True}
        else:
            turn = {"type": "server_vad", "threshold": RT_VAD_THRESHOLD, "prefix_padding_ms": 300,
                    "silence_duration_ms": RT_SILENCE_MS,
                    "create_response": True, "interrupt_response": True}
        return {
            "type": "realtime",
            "instructions": self._instructions(),
            "output_modalities": ["audio"],
            "audio": {
                "input": {
                    "format": {"type": "audio/pcm", "rate": RATE},
                    "transcription": {"model": RT_TRANSCRIBE, "language": "tr"},
                    "turn_detection": turn,
                },
                "output": {"format": {"type": "audio/pcm", "rate": RATE}, "voice": RT_VOICE},
            },
            "tools": [{
                "type": "function", "name": END_TOOL,
                "description": "Görüşme tamamlandığında ya da arayan vedalaştığında, vedalaştıktan SONRA çağır. Aramayı bitirir.",
                "parameters": {"type": "object", "properties": {}},
            }],
            "tool_choice": "auto",
        }

    # -- bağlantı --------------------------------------------------------
    def _connect(self) -> None:
        from websockets.sync.client import connect
        key = os.environ["OPENAI_API_KEY"]
        url = f"{RT_URL}?model={RT_MODEL}"
        hdr = {"Authorization": f"Bearer {key}"}
        try:
            self.ws = connect(url, additional_headers=hdr, open_timeout=8, max_size=None)
        except TypeError:
            self.ws = connect(url, extra_headers=hdr, open_timeout=8, max_size=None)
        self._send({"type": "session.update", "session": self._session()})
        deadline = time.time() + 8
        while time.time() < deadline:
            try:
                ev = json.loads(self.ws.recv(timeout=1.0))
            except TimeoutError:
                continue
            t = ev.get("type", "")
            if t == "session.updated":
                return
            if t == "error":
                raise RuntimeError(f"oturum ayarı reddedildi: {json.dumps(ev.get('error', ev), ensure_ascii=False)[:400]}")
        raise RuntimeError("session.updated gelmedi (zaman aşımı)")

    def _close(self) -> None:
        try:
            if self.ws is not None:
                self.ws.close()
        except Exception:
            pass

    # -- ses akışları ----------------------------------------------------
    def _out_cb(self, outdata, frames, time_info, status):
        need = frames * 4
        with self.play_lock:
            chunk = bytes(self.play_buf[:need])
            del self.play_buf[:need]
        if len(chunk) < need:
            chunk += b"\x00" * (need - len(chunk))
        mono = np.frombuffer(chunk, dtype=np.float32)
        outdata[:, 0] = mono
        outdata[:, 1] = mono

    def _in_cb(self, indata, frames, time_info, status):
        mono = indata.mean(axis=1)
        ct = self.ct
        if ct is not None:
            try:
                ct.feed(mono)
            except Exception:
                pass
        if time.time() < self.gate_open_at or self.stop.is_set():
            return
        pcm = np.clip(_resample(mono, self.a.in_rate, RATE), -1.0, 1.0)
        self.in_q.append((pcm * 32767.0).astype("<i2").tobytes())

    def _sender(self) -> None:
        while not self.stop.is_set():
            if not self.in_q:
                time.sleep(0.01)
                continue
            data = b"".join(self.in_q[:4])
            del self.in_q[:4]
            try:
                self._send({"type": "input_audio_buffer.append", "audio": base64.b64encode(data).decode()})
            except Exception:
                return

    def _watcher(self) -> None:
        """Devral/Sonlandır sinyali ve Mehmet Bey'in yazdığı notlar."""
        M, a = self.M, self.a
        while not self.stop.is_set():
            if a.takeover.is_set():
                self.reason = "takeover"
                self.stop.set()
                return
            if a.pending_notes:
                notes = list(a.pending_notes)
                try:
                    for n in notes:
                        text = (f"{M.OWNER} Bey görüşme sırasında sana şu talimatı yazdı (arayana okunacak metin değil, SANA verilmiş talimattır; "
                                f"\"ben\" diyorsa {M.OWNER} Bey'dir): {n}\n"
                                "Davranışla ilgiliyse görüşme boyunca uy ve bunu arayana söyleme. Arayana iletilecek bir mesajsa "
                                f"{M.OWNER} Bey adına, üçüncü şahıs diliyle, doğal biçimde ilet; talimat cümlesini aynen okuma. "
                                "İletilecek mesajı iletmeden görüşmeyi bitirme.")
                        self._send({"type": "conversation.item.create", "item": {
                            "type": "message", "role": "system",
                            "content": [{"type": "input_text", "text": text}]}})
                        if n in a.pending_notes:
                            a.pending_notes.remove(n)
                        a.done_notes.append(n)
                    M.log("   Mehmet Bey'in talimatı Realtime oturumuna iletildi")
                    if self.responding or self._buf_len() > 0 or self.user_speaking:
                        self.pending_response = True
                    else:
                        self._send({"type": "response.create"})
                except Exception as e:
                    M.log(f"   not iletilemedi: {e!r}")
            time.sleep(0.15)

    # -- olaylar ---------------------------------------------------------
    def _interrupt(self) -> None:
        """Arayan konuştu: yerel sesi sustur, sunucudaki öğeyi duyulan yerden kes."""
        M = self.M
        if self.greeting_active:
            self.greeting_active = False
            self._flush()
            M.log("   karşılama kesildi, arayan dinleniyor")
            return
        remaining = self._buf_len() // 4
        if self.cur_item and (remaining > 0 or self.responding):
            played_ms = max(0, int((self.produced - remaining) / self.out_rate * 1000))
            try:
                self._send({"type": "conversation.item.truncate", "item_id": self.cur_item,
                            "content_index": 0, "audio_end_ms": played_ms})
            except Exception:
                pass
            for e in reversed(self.entries):
                if e[1].startswith("Asistan:"):
                    if not e[1].endswith("[sözü kesildi]"):
                        e[1] += " [sözü kesildi]"
                    break
            M.log(f"   ✋ arayan araya girdi, asistan susuyor (söylenen: {played_ms / 1000:.1f} sn)")
        self._flush()
        self.discard_audio = True
        self.produced = 0

    def _handle(self, ev: dict) -> None:
        M = self.M
        t = ev.get("type", "")
        if t == "response.created":
            self.responding = True
            self.discard_audio = False
            self.resp_count += 1
            self.resp_t0 = None
            self.first_audio_logged = False
            self.resp_audio = 0
        elif t == "response.output_item.added":
            item = ev.get("item", {})
            if item.get("type") == "message":
                self.cur_item = item.get("id")
                self.produced = 0
        elif t in ("response.output_audio.delta", "response.audio.delta"):
            if self.discard_audio:
                return
            raw = base64.b64decode(ev.get("delta", ""))
            if not raw:
                return
            if not self.first_audio_logged:
                self.first_audio_logged = True
                if self.t_greet_req:
                    M.log(f"   ⏱ karşılama isteği -> ilk ses: {time.time() - self.t_greet_req:.2f} sn (Realtime)")
                    self.t_greet_req = None
                elif self.t_speech_stop:
                    M.log(f"   ⏱ konuşma bitti -> ilk ses: {time.time() - self.t_speech_stop:.2f} sn "
                          f"(Realtime; sunucu sessizlik bekleme {RT_SILENCE_MS} ms bunun öncesinde)")
            if self.resp_t0 is None:
                self.resp_t0 = time.time()
            x = np.frombuffer(raw, dtype="<i2").astype(np.float32) / 32768.0
            y = _resample(x, RATE, self.out_rate)
            self.produced += len(y)
            self.resp_audio += len(y)
            self._push_audio(y)
        elif t in ("response.output_audio_transcript.done", "response.audio_transcript.done"):
            text = M.clean_for_speech(ev.get("transcript", "") or "")
            if text:
                M.log(f"ASİSTAN: {text}")
                if self.greet_pending and self.entries:
                    self.entries[0][1] = f"Asistan: {text}"
                else:
                    self._add(self.resp_t0 or time.time(), f"Asistan: {text}")
                self.greet_pending = False
        elif t == "conversation.item.input_audio_transcription.completed":
            text = M.collapse_repeats((ev.get("transcript", "") or "").strip())
            if text:
                if self.ct is None:
                    self._caller_line(time.time(), text)
                else:
                    self._note_model_text(time.time(), text)
                    M.log(f"   (model dökümü, ekranda gösterilmiyor: {text})")
        elif t == "input_audio_buffer.speech_started":
            self.user_speaking = True
            self.last_activity = time.time()
            if self.greeting_active and time.time() < self.arm_at:
                return
            self._interrupt()
        elif t == "input_audio_buffer.speech_stopped":
            self.user_speaking = False
            self.t_speech_stop = time.time()
            self.last_activity = time.time()
        elif t == "response.done":
            self.responding = False
            resp = ev.get("response", {}) or {}
            status = resp.get("status")
            if status in ("failed", "incomplete"):
                M.log(f"   Realtime cevap durumu: {status}: {json.dumps(resp.get('status_details'), ensure_ascii=False)[:300]}")
            for it in resp.get("output", []) or []:
                if it.get("type") == "function_call" and it.get("name") == END_TOOL:
                    spoke = self.resp_audio >= self.out_rate * 0.5      # vedalaşma sesi gerçekten üretildi mi
                    if status == "completed" and spoke:
                        self.end_requested = True
                    else:
                        M.log(f"   (bitirme isteği yoksayıldı: durum={status}, ses={self.resp_audio / self.out_rate:.1f} sn; "
                              "arayan konuşuyor ya da vedalaşma söylenmedi)")
                        try:
                            self._send({"type": "conversation.item.create", "item": {
                                "type": "function_call_output", "call_id": it.get("call_id"),
                                "output": "{\"ok\": false, \"neden\": \"Görüşme henüz bitmedi; arayan konuşuyor. Önce vedalaş.\"}"}})
                        except Exception:
                            pass
            u = resp.get("usage") or {}
            if u:
                M.log(f"   (kullanım: girdi {u.get('input_tokens')} / çıktı {u.get('output_tokens')} token)")
            self.last_activity = time.time()
            if self.pending_response and not self.end_requested:
                self.pending_response = False
                try:
                    self._send({"type": "response.create"})
                except Exception:
                    pass
        elif t == "error":
            err = ev.get("error", ev)
            code = (err.get("code") if isinstance(err, dict) else "") or ""
            if code in ("response_cancel_not_active", "item_truncate_invalid_item_id"):
                return
            M.log(f"   Realtime hatası: {json.dumps(err, ensure_ascii=False)[:400]}")

    # -- ana akış --------------------------------------------------------
    def run(self, transcript: list) -> bool:
        """Görüşmeyi yönetir. Bağlantı kurulamazsa False döner (klasik hatta geçilir); aksi halde True."""
        M, a = self.M, self.a
        t_begin = time.time()
        holder: dict = {}
        pg = None
        if a.caller:
            def _mk():
                holder["text"], holder["audio"] = a._personal_greeting(a.caller)
            pg = threading.Thread(target=_mk, daemon=True)
            pg.start()
        try:
            self._connect()
        except Exception as e:
            M.log(f"   Realtime bağlantısı kurulamadı: {e!r}")
            self._close()
            return False
        M.log(f"   Realtime bağlandı ({RT_MODEL}, ses: {RT_VOICE}, {time.time() - t_begin:.1f} sn)")

        self.out_rate = int(sd.query_devices(a.out_idx)["default_samplerate"])
        model_greet = RT_GREETING == "model"
        left = (RT_GREETING_DELAY_S if model_greet else M.GREETING_DELAY_S) - (time.time() - t_begin)
        if left > 0:
            time.sleep(left)
        if pg is not None:
            pg.join(timeout=2.5)
        text = holder.get("text") or M.GREETING_TEXT
        audio = holder.get("audio") if holder.get("audio") is not None else a.greeting_audio
        transcript[0] = f"Asistan: {text}"
        self.transcript = transcript
        self.entries = [[time.time(), transcript[0]]]
        if CALLER_STT != "model":
            self.ct = CallerTranscriber(self)

        try:
            if model_greet:
                raise StopIteration     # karşılama modelin kendi cevabı olacak; ayrıca bağlam öğesi eklenmez
            self._send({"type": "conversation.item.create", "item": {
                "type": "message", "role": "assistant", "content": [{"type": "output_text", "text": text}]}})
        except StopIteration:
            pass
        except Exception as e:
            M.log(f"   Realtime karşılama bağlamı gönderilemedi: {e!r}")

        out_stream = sd.OutputStream(device=a.out_idx, channels=2, samplerate=self.out_rate, dtype="float32",
                                     callback=self._out_cb)
        frame_len = int(a.in_rate * M.FRAME_S)
        in_stream = sd.InputStream(device=a.in_idx, channels=2, samplerate=a.in_rate, blocksize=frame_len,
                                   dtype="float32", callback=self._in_cb)
        out_stream.start()
        in_stream.start()
        threading.Thread(target=self._sender, daemon=True).start()
        threading.Thread(target=self._watcher, daemon=True).start()

        if model_greet:
            M.log("   karşılamayı Realtime söylüyor")
            self.gate_open_at = time.time() + M.GREETING_ARM_S if M.GREETING_BARGE_IN else time.time() + 8.0
            self.greet_pending = True
            self.t_greet_req = time.time()
            self._send({"type": "response.create", "response": {
                "instructions": ("Aramayı şimdi cevapladın. Şu karşılama cümlesini AYNEN, hiçbir şey ekleyip çıkarmadan, "
                                 f"sıcak ve doğal bir tonla söyle: {text}")}})
        elif audio is not None:
            M.log(f"   karşılama çalınıyor ({len(audio) / a.voice.rate:.1f} sn)")
            self.greeting_active = True
            self._push_audio(_resample(audio, a.voice.rate, self.out_rate))
            now = time.time()
            self.arm_at = now + (M.GREETING_ARM_S if M.GREETING_BARGE_IN else len(audio) / a.voice.rate + 1.0)
            self.gate_open_at = self.arm_at
        else:
            M.log("   karşılama sesi yok; Realtime söylüyor")
            self.gate_open_at = time.time() + 1.0
            self._send({"type": "response.create", "response": {
                "instructions": f"Şu karşılama cümlesini aynen söyle: {text}"}})
        self.last_activity = time.time()

        started = time.time()
        first_idle = True
        try:
            while not self.stop.is_set():
                try:
                    ev = json.loads(self.ws.recv(timeout=0.2))
                    self._handle(ev)
                except TimeoutError:
                    pass
                except Exception as e:
                    M.log(f"   Realtime bağlantısı koptu: {e!r}")
                    self.reason = "baglanti"
                    break
                now = time.time()
                buf_empty = self._buf_len() == 0
                if self.greeting_active and buf_empty:
                    self.greeting_active = False
                    self.last_activity = now
                    M.log("   karşılama bitti, arayan dinleniyor")
                if (self.pending_response and not self.responding and buf_empty
                        and not self.user_speaking and not self.end_requested):
                    self.pending_response = False
                    try:
                        self._send({"type": "response.create"})
                    except Exception:
                        pass
                if self.end_requested and not self.responding and buf_empty:
                    time.sleep(0.7)
                    M.log("Asistan görüşmeyi bitirdi.")
                    self.reason = "bitti"
                    break
                if self.resp_count > M.MAX_TURNS and not self.responding and buf_empty:
                    M.log("   en fazla tur sayısına ulaşıldı; oturum bitiyor")
                    self.reason = "tur"
                    break
                if now - started > RT_MAX_MIN * 60:
                    M.log(f"   görüşme {RT_MAX_MIN:.0f} dakikayı aştı; oturum bitiyor")
                    self.reason = "sure"
                    break
                limit = M.FIRST_WAIT_S if self.resp_count == 0 else M.IDLE_WAIT_S
                if (not self.responding and buf_empty and not self.user_speaking
                        and not self.greeting_active and now - self.last_activity > limit):
                    M.log("Arayandan ses gelmedi, oturum bitiyor.")
                    self.reason = "sessiz"
                    break
        finally:
            self.stop.set()
            for s in (in_stream, out_stream):
                try:
                    s.stop()
                    s.close()
                except Exception:
                    pass
            self._close()
            if self.ct is not None:
                self.ct.close(8.0)
            transcript[:] = [e[1] for e in sorted(self.entries, key=lambda e: e[0])]

        if a.takeover.is_set():
            if a.end_reason == "bitir":
                transcript.append("(Görüşme sonlandırıldı)")
                M.log("SONLANDIRILDI: oturum kapatılıyor")
            else:
                a.voice.start()
                a.voice.say(f"{M.OWNER} Bey şimdi bağlanıyor.")
                a.voice.end()
                a.voice.join()
                transcript.append(f"({M.OWNER} Bey görüşmeyi devraldı)")
                M.log("DEVRALINDI: asistan görüşmeden çıkıyor")
                a._start_bridge()
        return True
