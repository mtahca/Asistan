#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Telefon asistanı ajanı.

Akış:  arayan sesi (Loopback: Asistan Dinleme)  ->  Whisper (Türkçe STT)  ->  LLM
       ->  EMA Lightning (TTS)  ->  Loopback: Asistan Ses Çıkışı (-> Asistan Mikrofonu = arama mikrofonu)

Arayan, asistan konuşurken araya girerse asistan susar ve arayanı dinler (barge-in).

Kullanım:
    python agent.py            # bekler; callanswer.swift --agent aramayı açınca go.flag oluşturur
    python agent.py --now      # beklemeden hemen bir oturum başlatır (arama açıkken test için)
    python agent.py --debug    # ses seviyesini yazdırır (eşik ayarı için)
    python agent.py --devices  # ses aygıtlarını listeler
"""
from __future__ import annotations

import argparse
import os
import queue
import re
import sys
import threading
import json
import time
import unicodedata
import wave
from collections import deque
from datetime import datetime
from pathlib import Path

import numpy as np

try:
    import sounddevice as sd
except OSError:  # PortAudio yoksa (ör. testte) içe aktarma başarısız olabilir
    sd = None

RES = Path(__file__).resolve().parent                 # kaynak/kaynak dosyalar (agent.py, sesler/)
BASE = Path(os.getenv("ASISTAN_HOME") or RES)         # kullanıcı verisi (.env, notlar, go.flag, caller.json)


# ----------------------------------------------------------------------------
# Ayarlar
# ----------------------------------------------------------------------------

def load_env() -> None:
    env_file = BASE / ".env"
    if not env_file.exists():
        return
    for line in env_file.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        k, v = line.split("=", 1)
        os.environ.setdefault(k.strip(), v.strip().strip('"').strip("'"))


load_env()

OWNER = os.getenv("OWNER_NAME", "Mehmet")
IN_DEVICE = os.getenv("IN_DEVICE", "Asistan Dinleme")       # arayanın sesi (Loopback; FaceTime/Telefon/WhatsApp uygulama sesi)
OUT_DEVICE = os.getenv("OUT_DEVICE", "Asistan Ses Çıkışı")  # ajanın sesi (Loopback; "Asistan Mikrofonu" bunu arama mikrofonu yapar)
HUMAN_MIC = os.getenv("HUMAN_MIC", "")                     # Devral / köprü için fiziksel mikrofon adı (boşsa uygulama bildirir ya da otomatik)
WHISPER_MODEL = os.getenv("WHISPER_MODEL", "small")
STT_BACKEND = os.getenv("STT_BACKEND", "faster")         # "faster" (CPU) veya "mlx" (Apple Silicon GPU)
LLM_PROVIDER = os.getenv("LLM_PROVIDER", "anthropic").strip().lower()   # anthropic | openai | ollama (yerel)
LLM_MODEL = (os.getenv("LLM_MODEL") or os.getenv("CLAUDE_MODEL") or
             {"anthropic": "claude-haiku-4-5", "openai": "gpt-4.1-mini", "ollama": "qwen2.5:7b"}.get(LLM_PROVIDER, "claude-haiku-4-5")).strip()
OLLAMA_URL = os.getenv("OLLAMA_URL", "http://localhost:11434/v1").strip()
CLAUDE_MODEL = LLM_MODEL   # geriye dönük ad
KEEPWARM_S = float(os.getenv("KEEPWARM_S", "90"))      # boşta beklerken STT/TTS'i bu aralıkla sıcak tut (0 = kapalı)
SPEC_STT = os.getenv("SPEC_STT", "1") == "1"             # arayan susar susmaz (bitiş sessizliği dolmadan) STT'yi başlat
SPEC_SILENCE_S = float(os.getenv("SPEC_SILENCE_S", "0.2"))
VAD_THRESHOLD = float(os.getenv("VAD_THRESHOLD", "0.006"))   # RMS eşiği
END_SILENCE_S = float(os.getenv("END_SILENCE_S", "0.6"))
GREETING_DELAY_S = float(os.getenv("GREETING_DELAY_S", "3.0"))  # arama açıldıktan sonra karşılamadan önce bekleme (ses hattı oturana kadar)
GREETING_BARGE_IN = os.getenv("GREETING_BARGE_IN", "1") == "1"  # karşılama sırasında arayan konuşursa karşılamayı kes
GREETING_ARM_S = float(os.getenv("GREETING_ARM_S", "2.5"))     # karşılamanın ilk N saniyesinde araya girme kapalı (hat gürültüsü)
NOTE_IDLE_S = float(os.getenv("NOTE_IDLE_S", "2.0"))           # bekleyen not varsa, arayan bu kadar sustuğunda notu kendiliğinden ilet
API_TIMEOUT_S = float(os.getenv("API_TIMEOUT_S", "12"))        # Claude isteği için zaman aşımı
FIRST_WAIT_S = float(os.getenv("FIRST_WAIT_S", "30"))        # karşılamadan sonra ilk bekleme
IDLE_WAIT_S = float(os.getenv("IDLE_WAIT_S", "25"))          # cevaptan sonra bekleme
MAX_TURNS = int(os.getenv("MAX_TURNS", "25"))        # cevaplanan en fazla tur sayısı
BARGE_IN = os.getenv("BARGE_IN", "1") == "1"                 # arayan araya girerse asistan sussun
BARGE_FRAMES = int(os.getenv("BARGE_FRAMES", "10"))          # kaç ardışık konuşma çerçevesi (1 çerçeve = 30 ms)
BARGE_FACTOR = float(os.getenv("BARGE_FACTOR", "1.5"))       # asistan konuşurken eşik çarpanı
FRAME_S = 0.03

LEGACY_GREETING = (      # eski varsayılan metin: elle kaydedilmiş karsilama_st.wav yalnızca bunun için geçerli
    f"Merhaba, {OWNER} Bey şu anda bir toplantıda. Ben onun yapay zeka asistanıyım. "
    "Mesajınızı not alabilirim. Kiminle görüşüyorum ve ne için aradınız?"
)
DEFAULT_GREETING = "Merhaba, nasıl yardımcı olabilirim?"
GREETING_TEXT = os.getenv("GREETING_TEXT", DEFAULT_GREETING).strip() or DEFAULT_GREETING
GREETING_WAV = RES / "sesler" / "karsilama_st.wav"   # elle kaydedilmiş karşılama (varsayılan metin için)
END_TOKEN = "[BITTI]"
CONVERSATION_MODE = os.getenv("CONVERSATION_MODE", "classic").strip().lower()   # classic (Whisper+LLM+yerel TTS) | realtime (OpenAI Realtime, uçtan uca ses)

SYSTEM_PROMPT = f"""Sen {OWNER} Bey'in telefon asistanısın. {OWNER} Bey şu an bir toplantıda ve aramayı sen cevaplıyorsun.
Karşılama olarak yalnızca selam verip nasıl yardımcı olabileceğini sordun; henüz yapay zeka asistanı olduğunu söylemedin.

Görevin: arayanın adını ve ne için aradığını anlamak, gerekiyorsa geri dönüş tercihini öğrenmek; bunu bir sorgu gibi değil, doğal bir sohbet gibi yapmak. Aciliyeti ASLA kendin sorma; acil bir durum varsa arayan zaten söyler.

Kurallar:
- Telefonda konuşuyorsun: cevapların genelde kısa (1-3 cümle) ama akıcı ve sohbet eder gibi olsun. Arayan bir şey anlatıyor ya da soruyorsa gerektiği kadar cevap ver; uzun liste, gereksiz açıklama ve tekrardan kaçın.
- Arayanın söylediğini papağan gibi tekrar etme ya da özetleme ("Anladım, test amaçlı aradınız" deme); doğal bir karşılık ver.
- Her cevapta soru sormak zorunda değilsin; sorarsan en fazla BİR soru sor. Zaten bildiğin şeyi (adı, konuyu) tekrar sorma. "Başka bir not var mı?" gibi kalıp soruları sürekli tekrarlama; arayan söylemek istediğini kendisi söylesin.
- Arayan adını ve konusunu söylediyse daha fazla sorgulama; "acil mi" diye sorma. Mesajı ileteceğini söyleyip nazikçe vedalaş.
- Arayan rehberde kayıtlı ve yakın biriyse (eş, aile, arkadaş) resmi sorgulama yapma; sıcak ve kısa konuş, sadece ne istediğini öğren.
- Arayan sohbet ederse, selam verirse ya da basit bir şey sorarsa (hesap, saat, genel bilgi, \"nasılsın\", \"sen kimsin\") samimi ve doğal cevap ver, sohbete bir iki cümle eşlik et, sonra gerekiyorsa konuya dön. Soruyu görmezden gelme.
- Arayan hangi model olduğunu sorarsa her zaman tam model adını ve sürüm numarasını söyle: kullandığın dil modeli {LLM_MODEL} ({LLM_PROVIDER}). Kendi tahminini ya da başka bir model adı söyleme, yalnızca bu adı kullan; adı olduğu gibi, sürüm numarasıyla birlikte oku.
- Arayan {OWNER} Bey'i sorarsa ya da onunla görüşmek isterse, {OWNER} Bey'in yapay zeka asistanı olduğunu, {OWNER} Bey'in şu an müsait olmadığını ve mesajını/isteğini ona ileteceğini söyle. Nerede olduğunu ya da programını söyleme.
- Arayan {OWNER} Bey'den bir unvan ya da hitapla söz ederse ("{OWNER} Başkan", "{OWNER} Abi", "Başkanım" vb.), hangisini kullanırsa kullansın sen onun hakkında konuşurken her zaman "{OWNER} Başkanım" de ("{OWNER} Bey" deme). Arayan sıradan "{OWNER} Bey" ya da yalnızca adıyla söz ediyorsa "{OWNER} Bey" demeye devam et. Arayana hitabını ise yine ayrıca kurallara göre yap.
- Arayan ne söylüyorsa ona göre ilerle: sorgu yapma, kalıp soru sorma. Mesaj bırakmak istiyorsa adını (bilmiyorsan) ve konuyu doğal biçimde öğren.
- Yalnızca {OWNER} Bey'e özel, bilmediğin veya yetkin olmadığın konularda (programı, kararları, kişisel bilgileri) ileteceğini söyle.
- Doğal konuş: kalıp cümleler, resmi sorgu ve her cevapta soru sorma. Bazen sadece kısa bir karşılık vermek ("tabii", "olur, ileteyim") yeterli.
- Aynı cümleyi art arda tekrar etme; her cevabın farklı ve arayanın son söylediğine uygun olsun.
- Doğal ve nazik ol. Emoji, madde işareti, markdown, parantez kullanma. Sayıları ve saatleri okunacak şekilde yaz.
- Ses tanıma hatalı olabilir. Anlamadıysan kibarca ve kısaca tekrar iste.
- {OWNER} Bey'in programı, nerede olduğu veya kişisel bilgileri hakkında bilgi verme. Sadece toplantısı bitince mesajı ileteceğini söyle.
- Hiçbir söz verme (randevu, ödeme, onay gibi).
- Gerekli bilgileri aldıysan (en az isim ve konu) ve arayan başka bir şey söylemiyorsa teşekkür edip vedalaş ve cevabının EN SONUNA {END_TOKEN} yaz. Arayan sohbet etmek istiyorsa aceleyle bitirme, sohbete eşlik et.
- Arayan kapatmak veya vedalaşmak isterse de vedalaş ve sonuna {END_TOKEN} yaz.
- Arayana hitap: "Bey" ve "Hanım" yalnızca ARAYAN için cinsiyete göre kullanılır. Arayan kadınsa adına "Hanım" ekle (ör. "Ayşe Hanım", "Tuğba Hanım"), erkekse "Bey" ekle (ör. "Ali Bey"). Cinsiyeti adından, rehber kaydından ve konuşmasından çıkar. Kadın bir arayana asla "Bey" deme. Emin değilsen ya da ad bilinmiyorsa Bey/Hanım kullanma, sadece "siz" diye hitap et. Arayan eşin, yakının veya arkadaşınsa ve rehberde "Aşkım" gibi bir sevgi sözcüğüyle kayıtlıysa o sözcüğü kullanma; gerçek adıyla ve uygun ek ile hitap et. Ek (Bey/Hanım) yalnızca ilk adla kullanılır, soyadı eklenmez.
- Önceki cevabın yarıda kesilmiş olabilir ("[sözü kesildi]" yazar). Bu durumda arayanın söylediğine odaklan.
"""



def _norm(t: str) -> str:
    import unicodedata
    t = (t or "").replace("ı", "i").replace("İ", "i").replace("I", "i")
    t = unicodedata.normalize("NFKD", t.lower())
    return "".join(ch for ch in t if ch.isalnum())


def alias_address(caller: dict) -> str:
    """Rehber adı -> hitap eşlemesi (.env: HITAP="Aşkım=Tuba Hanım; Anne=Ayşe Hanım"). Yoksa boş döner."""
    raw = os.getenv("HITAP", "").strip()
    name = (caller or {}).get("name") or ""
    if not raw or not name:
        return ""
    keys = {_norm(name), _norm(name.split("(")[0])}
    if "(" in name:
        keys.add(_norm(name.split("(")[1].split(")")[0]))
    for part in raw.split(";"):
        if "=" not in part:
            continue
        k, v = part.split("=", 1)
        if _norm(k) and _norm(k) in keys and v.strip():
            return v.strip()
    return ""


def load_instructions() -> str:
    """Mehmet Bey'in kendi yazdığı talimatlar: genel kurallar (talimat_genel.txt) + yalnızca bugün geçerli notlar (talimat_bugun.json)."""
    parts = []
    try:
        g = (BASE / "talimat_genel.txt").read_text(encoding="utf-8").strip()
        if g:
            parts.append("GENEL KURALLAR:\n" + g)
    except Exception:
        pass
    try:
        d = json.loads((BASE / "talimat_bugun.json").read_text(encoding="utf-8"))
        if d.get("date") == datetime.now().strftime("%Y-%m-%d") and (d.get("text") or "").strip():
            parts.append("BUGÜNÜN DURUMU VE KİŞİLERE ÖZEL NOTLAR (yalnızca bugün geçerli):\n" + d["text"].strip())
    except Exception:
        pass
    if not parts:
        return ""
    return (f"\n\n{OWNER} Bey'in kendi talimatları. Bunlar yukarıdaki kurallarla çelişirse BUNLAR geçerlidir "
            "(kısa konuşma ve tek soru kuralı hariç). Ayrıntıları arayana ezbere okuma; yalnızca ilgili olduğunda doğal biçimde kullan:\n"
            + "\n\n".join(parts) + "\n")

CALLER_FILE = BASE / "caller.json"


def load_caller() -> dict:
    """Uygulamanın yazdığı arayan bilgisini (ad, numara, rehber kaydı) okur; bayatsa yok sayar."""
    try:
        if not CALLER_FILE.exists():
            return {}
        age = time.time() - CALLER_FILE.stat().st_mtime
        data = json.loads(CALLER_FILE.read_text(encoding="utf-8"))
        CALLER_FILE.unlink(missing_ok=True)
        return data if age < 120 and isinstance(data, dict) else {}
    except Exception as e:
        log(f"caller.json okunamadı: {e!r}")
        return {}


def caller_summary(c: dict) -> str:
    if not c:
        return ""
    name, number = c.get("name") or "", c.get("number") or ""
    parts = []
    if name:
        parts.append(name)
    if number:
        parts.append(number)
    who = " - ".join(parts) if parts else "bilinmiyor"
    return who + (" (rehberde kayıtlı)" if c.get("in_contacts") else " (rehberde kayıtlı değil)")


def build_system_prompt(c: dict) -> str:
    base = _build_system_prompt(c)
    return base + load_instructions()


def _build_system_prompt(c: dict) -> str:
    if not c:
        return SYSTEM_PROMPT
    info = caller_summary(c)
    extra = f"""
Telefon sisteminden gelen arayan bilgisi (güvenilir): {info}.
- Arayanın adı biliniyorsa adını ASLA sorma ("Adınız nedir?" deme); bunun yerine ne için aradığını sor. Arayan kendini farklı biri olarak tanıtırsa ona güven.
- Bu bilgiyi arayana ezbere okuma. Numarayı sorma, zaten elimizde; sadece geri dönüş için başka bir numara istiyorsa not al.
- "Sizi tanıyorum" gibi şeyler söyleme.
"""
    addr = alias_address(c)
    if addr:
        extra += f"- Arayana her zaman \"{addr}\" diye hitap et (Rehberdeki takma adı kullanma). Adını tekrar sorma.\n"
    return SYSTEM_PROMPT + extra

# Whisper'ın sessizlikte ürettiği bilinen hayali cümleler
HALLUCINATIONS = (
    "altyazı", "abone ol", "izlediğiniz için", "izlediğin için", "teşekkürler.",
    "müzik", "devam edecek", "iyi seyirler", "sesli betimleme", "betimleme",
    "bu dizinin", "kanalımıza", "beğenmeyi unutmayın", "görüşmek üzere",
)

NOTE_SENTINEL = "__NOT__"   # wait_utterance: arayan sustu, bekleyen not iletilsin


def collapse_repeats(text: str, max_n: int = 8) -> str:
    """Whisper'ın takılıp aynı parçayı tekrarlamasını ("... miyim miyim? ... miyim miyim?") tek kopyaya indirir."""
    words = text.split()
    def key(w: str) -> str:
        return w.lower().strip(".,?!;:…\"'")
    changed = True
    while changed:
        changed = False
        for n in range(1, max_n + 1):
            i = 0
            need = 3 if n <= 2 else 2   # tek/çift kelimede ("evet evet") 3 kopya gerekir, uzun parçalarda 2
            while i + need * n <= len(words):
                ks = [key(w) for w in words[i:i + n]]
                if all([key(w) for w in words[i + k * n:i + (k + 1) * n]] == ks for k in range(1, need)):
                    del words[i + n:i + need * n]
                    changed = True
                else:
                    i += 1
    return " ".join(words)


def log(msg: str) -> None:
    print(f"[{datetime.now().strftime('%H:%M:%S')}] {msg}", flush=True)


# ----------------------------------------------------------------------------
# Ses yardımcıları
# ----------------------------------------------------------------------------

def _nfc(t: str) -> str:
    # macOS aygıt adı ile ortam değişkeni farklı Unicode biçiminde olabilir (Ç ≠ C + ◌̧)
    return unicodedata.normalize("NFC", t).casefold()


def find_device(name: str, kind: str) -> int:
    assert sd is not None, "sounddevice kullanılamıyor"
    devices = list(sd.query_devices())
    wanted = _nfc(name)
    ok = [i for i, d in enumerate(devices) if d[f"max_{kind}_channels"] > 0]
    exact = [i for i in ok if _nfc(devices[i]["name"]) == wanted]
    if len(exact) == 1:
        return exact[0]
    if not exact:
        part = [i for i in ok if wanted in _nfc(devices[i]["name"])]
        if len(part) == 1:
            return part[0]
    avail = ", ".join(f"{d['name']} (giriş={d['max_input_channels']}, çıkış={d['max_output_channels']})"
                      for d in devices if _nfc(d["name"]).startswith("asistan")) or "Asistan aygıtı yok"
    log("Ses aygıtı tanısı: " + avail)
    if len(exact) > 1:
        raise RuntimeError(f"'{name}' adı birden fazla {kind} aygıtında kullanılıyor.")
    raise RuntimeError(f"'{name}' {kind} aygıtı bulunamadı. Loopback'te 'Asistan Dinleme', 'Asistan Mikrofonu' ve "
                       f"'Asistan Ses Çıkışı' aygıtlarının açık olduğundan emin olun (python agent.py --devices).")


def find_human_mic(preferred: str = "") -> int:
    """Devral / köprü için fiziksel mikrofon: istenen ad, yoksa sistem varsayılanı, o da Loopback ise yerleşik mikrofon."""
    devices = list(sd.query_devices())
    def ok(i):
        d = devices[i]
        return d["max_input_channels"] > 0 and not _nfc(d["name"]).startswith("asistan")
    if preferred:
        for i in range(len(devices)):
            if ok(i) and _nfc(devices[i]["name"]) == _nfc(preferred):
                return i
        for i in range(len(devices)):
            if ok(i) and _nfc(preferred) in _nfc(devices[i]["name"]):
                return i
    try:
        di = sd.default.device[0]
        di = int(di) if di is not None and int(di) >= 0 else None
    except Exception:
        di = None
    if di is not None and ok(di):
        return di
    for i in range(len(devices)):
        if ok(i) and any(k in _nfc(devices[i]["name"]) for k in ("macbook", "built-in", "yerleşik", "mikrofon", "microphone")):
            return i
    for i in range(len(devices)):
        if ok(i):
            return i
    raise RuntimeError("Fiziksel mikrofon bulunamadı.")


def to_16k(x: np.ndarray, rate: int) -> np.ndarray:
    x = x.astype(np.float32)
    if rate == 16000:
        out = x
    elif rate % 16000 == 0:
        k = rate // 16000
        n = len(x) // k * k
        out = x[:n].reshape(-1, k).mean(axis=1)
    else:
        n_out = int(len(x) * 16000 / rate)
        out = np.interp(np.linspace(0, len(x) - 1, n_out), np.arange(len(x)), x)
    out = out.astype(np.float32)
    peak = float(np.abs(out).max()) if len(out) else 0.0
    if peak > 0:
        out = out / peak * 0.9   # Whisper için seviyeyi normalle
    return out


class UtteranceDetector:
    """Enerji tabanlı basit konuşma bitiş algılayıcı. Çerçeve verir, konuşma bitince ses döndürür."""

    def __init__(self, thr: float, end_silence: float = END_SILENCE_S, min_speech: float = 0.35,
                 max_len: float = 20.0, frame_s: float = FRAME_S):
        self.thr, self.end_silence, self.min_speech = thr, end_silence, min_speech
        self.max_len, self.frame_s = max_len, frame_s
        self.preroll: deque = deque(maxlen=int(0.3 / frame_s))
        self.reset()

    def reset(self) -> None:
        self.active = False
        self.hits = 0
        self.silent = 0
        self.voiced = 0
        self.buf: list = []
        self.preroll.clear()
        self.tentative = None        # (ses, voiced) — sessizlik başlar başlamaz alınan anlık görüntü
        self.tentative_sent = False
        self.last_voiced = 0         # son döndürülen konuşmadaki konuşma çerçevesi sayısı

    def feed(self, frame: np.ndarray):
        rms = float(np.sqrt(np.mean(frame ** 2))) if len(frame) else 0.0
        is_voiced = rms > self.thr
        if not self.active:
            self.preroll.append(frame)
            if is_voiced:
                self.hits += 1
                if self.hits >= 2:
                    self.active, self.buf = True, list(self.preroll)
                    self.silent, self.voiced = 0, self.hits
            else:
                self.hits = 0
            return None
        self.buf.append(frame)
        if is_voiced:
            self.silent = 0
            self.voiced += 1
            self.tentative_sent = False
        else:
            self.silent += 1
            if (not self.tentative_sent and self.silent * self.frame_s >= SPEC_SILENCE_S
                    and self.voiced * self.frame_s >= self.min_speech):
                self.tentative_sent = True
                self.tentative = (np.concatenate(self.buf), self.voiced)
        duration = len(self.buf) * self.frame_s
        if self.silent * self.frame_s >= self.end_silence or duration >= self.max_len:
            utt = np.concatenate(self.buf) if self.voiced * self.frame_s >= self.min_speech else None
            self.last_voiced = self.voiced
            self.reset()
            return utt
        return None


def play_audio(audio: np.ndarray, rate: int, device: int, cancel: threading.Event) -> None:
    """Tek bir oynatma işçisi akışın sahibidir; başkaları yalnızca `cancel` bayrağını kurar
    (sd.play/sd.stop'u eşzamanlı çağırmak PortAudio akışını iki kez kapatıp çökmeye yol açabiliyordu)."""
    if cancel.is_set():
        return
    stereo = np.column_stack([audio, audio]).astype(np.float32)
    if not len(stereo):
        return
    finished = threading.Event()
    cursor = 0

    def callback(outdata, frames, time_info, status):
        nonlocal cursor
        outdata.fill(0)
        if cancel.is_set():
            raise sd.CallbackAbort
        count = min(frames, len(stereo) - cursor)
        outdata[:count] = stereo[cursor:cursor + count]
        cursor += count
        if cursor >= len(stereo):
            raise sd.CallbackStop

    with sd.OutputStream(device=device, channels=2, samplerate=rate, dtype="float32",
                         callback=callback, finished_callback=finished.set) as stream:
        while not finished.wait(0.03):
            if cancel.is_set():
                stream.abort()
                break


class MicrophoneBridge:
    """Fiziksel mikrofonu 'Asistan Ses Çıkışı'na aktarır (Loopback'te Asistan Mikrofonu bunu arama mikrofonu yapar).
    Devral'da ve normal (asistansız) aramalarda sesin karşıya gitmesini sağlar."""
    def __init__(self, in_idx: int, out_idx: int, rate: int):
        self.closed = False
        self.stream = sd.Stream(device=(in_idx, out_idx), channels=(1, 2), samplerate=rate,
                                dtype="float32", latency="low", callback=self._callback)
        try:
            self.stream.start()
        except Exception:
            self.stream.close()
            raise

    def _callback(self, indata, outdata, frames, time_info, status):
        if self.closed:
            outdata.fill(0)
        else:
            outdata[:] = indata[:, :1]

    def close(self) -> None:
        self.closed = True
        try:
            self.stream.stop()
        finally:
            self.stream.close()


def save_debug_audio(audio16: np.ndarray, tag: str, keep: int = 10) -> None:
    """STT'nin reddettiği konuşmaları tanılama için yerelde sakla (en yeni `keep` dosya)."""
    try:
        d = BASE / "debug_ses"
        d.mkdir(exist_ok=True)
        path = d / f"{datetime.now().strftime('%H-%M-%S')}_{tag}.wav"
        with wave.open(str(path), "wb") as w:
            w.setnchannels(1)
            w.setsampwidth(2)
            w.setframerate(16000)
            w.writeframes((np.clip(audio16, -1, 1) * 32767).astype(np.int16).tobytes())
        for old in sorted(d.glob("*.wav"))[:-keep]:
            old.unlink(missing_ok=True)
    except Exception as e:
        log(f"   (debug sesi kaydedilemedi: {e})")


def read_wav(path: Path):
    with wave.open(str(path)) as w:
        ch, sw, rate = w.getnchannels(), w.getsampwidth(), w.getframerate()
        raw = w.readframes(w.getnframes())
    a = np.frombuffer(raw, dtype={2: np.int16, 4: np.int32}[sw]).astype(np.float32) / (2 ** (8 * sw - 1))
    if ch > 1:
        a = a.reshape(-1, ch).mean(axis=1)
    return a, rate


# ----------------------------------------------------------------------------
# Metin yardımcıları
# ----------------------------------------------------------------------------

def clean_for_speech(text: str) -> str:
    text = text.replace(END_TOKEN, "")
    text = re.sub(r"[*_`#>\[\]]", "", text)
    return re.sub(r"\s+", " ", text).strip()


def pop_sentences(buf: str, min_len: int = 14, first: bool = False):
    """Akan metinden tamamlanmış cümleleri ayırır. (cümleler, kalan) döndürür.
    first=True: ilk parçada virgülde de böl ve kısa parçaya izin ver (ilk sesi erken başlatmak için)."""
    sentences, start = [], 0
    pattern = r"[.!?…,;:]+[\"”)]?\s+|\n+" if first else r"[.!?…]+[\"”)]?\s+|\n+"
    if first:
        min_len = 8
    for m in re.finditer(pattern, buf):
        piece = buf[start:m.end()].strip()
        if len(piece) >= min_len:
            sentences.append(piece)
            start = m.end()
    return sentences, buf[start:]


# ----------------------------------------------------------------------------
# Dil modeli (Anthropic Claude ya da OpenAI) — akış ve tek seferlik tamamlama
# ----------------------------------------------------------------------------

class LLM:
    def __init__(self, provider: str, model: str):
        self.provider, self.model = provider, model
        if provider == "ollama":
            self.client = None      # Ollama'nın kendi API'si (/api/chat) kullanılır: düşünme modunu güvenilir kapatır
        elif provider == "openai":
            if not os.getenv("OPENAI_API_KEY"):
                sys.exit("OPENAI_API_KEY bulunamadı. Uygulamadaki Asistan ayarları penceresinden gir.")
            from openai import OpenAI
            self.client = OpenAI(timeout=API_TIMEOUT_S, max_retries=2)
        else:
            if not os.getenv("ANTHROPIC_API_KEY"):
                sys.exit("ANTHROPIC_API_KEY bulunamadı. Uygulamadaki Asistan ayarları penceresinden gir.")
            from anthropic import Anthropic
            self.client = Anthropic(timeout=API_TIMEOUT_S, max_retries=2)

    def _oai_reasoning(self) -> bool:
        return self.provider == "openai" and bool(re.match(r"(gpt-[5-9]|o\d)", self.model))

    def _limit(self, n: int) -> dict:
        if self.provider == "ollama":
            return {"max_tokens": n}
        if self._oai_reasoning():
            n += 1500   # düşünme token'ları da bu sınırdan harcanır: boş cevap çıkmasın
        return {"max_completion_tokens": n}

    def _create(self, **kw):
        """OpenAI/Ollama isteği. Ollama'da düşünme modu kapalı istenir (gecikme); desteklemezse onsuz yeniden dener."""
        if self.provider == "ollama" and os.getenv("OLLAMA_THINK", "0") != "1" and getattr(self, "_think_off_ok", True):
            try:
                return self.client.chat.completions.create(extra_body={"think": False, "reasoning_effort": "none"}, **kw)
            except Exception as e:
                self._think_off_ok = False
                log(f"   (Ollama düşünme kapatma desteklenmedi, onsuz deneniyor: {e!r})")
        if self._oai_reasoning() and getattr(self, "_effort_ok", True):
            effort = os.getenv("OPENAI_EFFORT", "low")
            try:
                return self.client.chat.completions.create(reasoning_effort=effort, **kw)
            except Exception as e:
                if "reasoning_effort" not in str(e) and "reasoning" not in str(e).lower():
                    raise
                self._effort_ok = False
                log(f"   (reasoning_effort={effort} desteklenmedi, onsuz deneniyor: {e!r})")
        return self.client.chat.completions.create(**kw)


    def _ollama_chat(self, messages: list, max_tokens: int):
        """Ollama /api/chat (akış). Düşünme modu kapalı; boş cevap gelirse loga yazar."""
        import urllib.request, urllib.error
        base = OLLAMA_URL.replace("/v1", "").rstrip("/")
        def call(think_off: bool):
            body = {"model": self.model, "messages": messages, "stream": True, "keep_alive": "60m",
                    "options": {"num_predict": max_tokens, "num_ctx": 6144, "temperature": 0.6}}
            if think_off and os.getenv("OLLAMA_THINK", "0") != "1":
                body["think"] = False
            req = urllib.request.Request(base + "/api/chat", data=json.dumps(body).encode("utf-8"),
                                         headers={"Content-Type": "application/json"})
            return urllib.request.urlopen(req, timeout=60)
        try:
            resp = call(True)
        except urllib.error.HTTPError as e:
            detail = e.read().decode("utf-8", "ignore")[:200]
            log(f"   (Ollama think=false reddedildi: {e.code} {detail}; onsuz deneniyor)")
            resp = call(False)
        got = False
        thinking = 0
        with resp:
            for raw in resp:
                raw = raw.strip()
                if not raw:
                    continue
                d = json.loads(raw)
                if d.get("error"):
                    raise RuntimeError(d["error"])
                m = d.get("message") or {}
                if m.get("thinking"):
                    thinking += 1
                t = m.get("content") or ""
                if t:
                    got = True
                    yield t
        if not got:
            log(f"   Ollama boş cevap döndürdü (düşünme parçası: {thinking}); OLLAMA_THINK/num_predict kontrol et")

    def stream(self, system: str, messages: list, max_tokens: int):
        """Metin parçalarını üretir (generator)."""
        if self.provider == "ollama":
            yield from self._ollama_chat([{"role": "system", "content": system}] + messages, max_tokens)
            return
        if self.provider == "openai":
            r = self._create(
                model=self.model, stream=True, **self._limit(max_tokens),
                messages=[{"role": "system", "content": system}] + messages)
            for chunk in r:
                if chunk.choices and chunk.choices[0].delta and chunk.choices[0].delta.content:
                    yield chunk.choices[0].delta.content
            return
        kw = self._claude_extra()
        if self._is5():
            # Düşünme token'ları max_tokens'tan harcanır: boş cevap çıkmasın diye pay ekle (konuşma uzunluğunu prompt sınırlar)
            max_tokens += 1000
            system += "\n\nCevabını düşünme aşamasına uzun girmeden, doğrudan ve kısa ver."
        try:
            with self.client.messages.stream(model=self.model, max_tokens=max_tokens,
                                             system=system, messages=messages, **kw) as st:
                for delta in st.text_stream:
                    yield delta
        except Exception as e:
            if kw and "output_config" in str(e):   # model effort desteklemiyorsa onsuz bir kez dene
                log(f"   (effort reddedildi, onsuz deneniyor: {e!r})")
                self._effort_ok = False
                with self.client.messages.stream(model=self.model, max_tokens=max_tokens,
                                                 system=system, messages=messages) as st:
                    for delta in st.text_stream:
                        yield delta
            else:
                raise

    def _is5(self) -> bool:
        return self.provider == "anthropic" and bool(re.search(r"claude-(haiku|sonnet|opus)-5", self.model))

    def _claude_extra(self) -> dict:
        """Claude 5.x modellerinde (ör. Haiku 5.5) uyarlanabilir düşünme varsayılan açık: telefon için düşük 'effort' iste.
        (Düşünme token'ları max_tokens'ı tüketip boş cevaba yol açabiliyordu.)"""
        if self.provider != "anthropic" or not getattr(self, "_effort_ok", True):
            return {}
        if not re.search(r"claude-(haiku|sonnet|opus)-5", self.model):
            return {}
        effort = os.getenv("CLAUDE_EFFORT", "low").strip()
        return {"extra_body": {"output_config": {"effort": effort}}} if effort else {}

    def complete(self, prompt: str, max_tokens: int) -> str:
        if self.provider == "ollama":
            return "".join(self._ollama_chat([{"role": "user", "content": prompt}], max_tokens)).strip()
        if self.provider == "openai":
            r = self._create(
                model=self.model, **self._limit(max_tokens),
                messages=[{"role": "user", "content": prompt}])
            return (r.choices[0].message.content or "").strip()
        kw = self._claude_extra()
        if self._is5():
            max_tokens += 1000
        try:
            r = self.client.messages.create(model=self.model, max_tokens=max_tokens,
                                            messages=[{"role": "user", "content": prompt}], **kw)
        except Exception as e:
            if kw and "output_config" in str(e):
                self._effort_ok = False
                r = self.client.messages.create(model=self.model, max_tokens=max_tokens,
                                                messages=[{"role": "user", "content": prompt}])
            else:
                raise
        # Düşünme blokları (ThinkingBlock) 'text' taşımaz: yalnızca metin bloklarını al
        return "".join(getattr(b, "text", "") or "" for b in r.content if getattr(b, "type", "") == "text").strip()


# ----------------------------------------------------------------------------
# Konuşma motoru (TTS) — cümle cümle üretir ve çalar; yarıda kesilebilir
# ----------------------------------------------------------------------------

class Voice:
    def __init__(self, out_idx: int):
        from ema_lightning import EMA
        self.out_idx = out_idx
        self.rate = int(sd.query_devices(out_idx)["default_samplerate"]) or 48000
        self.tts = EMA(device=os.getenv("TTS_DEVICE", "cpu"))
        self.tts_lock = threading.Lock()   # EMA'yı aynı anda iki iş parçacığından çağırma
        self._text_q: queue.Queue = queue.Queue()
        self._audio_q: queue.Queue = queue.Queue()
        self._threads: list = []
        self._stop = threading.Event()
        self.first_play: float | None = None
        self.played: list = []

    def warmup(self) -> None:
        self.tts.say("Merhaba.", sample_rate=self.rate)

    def start(self) -> None:
        self._text_q, self._audio_q = queue.Queue(), queue.Queue()
        self._stop = threading.Event()
        self.first_play = None
        self.played = []
        self._threads = [threading.Thread(target=self._synth_loop, daemon=True),
                         threading.Thread(target=self._play_loop, daemon=True)]
        for t in self._threads:
            t.start()

    def say(self, text: str) -> None:
        text = clean_for_speech(text)
        if text and not self._stop.is_set():
            self._text_q.put(text)

    def end(self) -> None:
        """Yeni metin gelmeyecek; kuyruktakiler çalınınca iş parçacıkları biter."""
        self._text_q.put(None)

    def busy(self) -> bool:
        return any(t.is_alive() for t in self._threads)

    def interrupt(self) -> None:
        """Çalmayı hemen durdur. Kuyruklar silinmez: iş parçacıkları dur bayrağını görünce kalan
        öğeleri atlar ve bitiş işaretiyle (None) kapanır (kuyruk boşaltmak bitiş işaretini
        kaybettirebilir)."""
        self._stop.set()   # oynatma işçisi bayrağı görüp akışı kendisi kapatır
        self._text_q.put(None)

    def join(self, timeout: float = 5.0) -> None:
        for t in self._threads:
            t.join(timeout)

    def _synth_loop(self) -> None:
        first = True
        while True:
            text = self._text_q.get()
            if text is None:
                self._audio_q.put(None)
                return
            if self._stop.is_set():
                continue
            t0 = time.time()
            with self.tts_lock:
                speech = self.tts.say(text, sample_rate=self.rate)
            if first:
                log(f"   TTS ilk cümle: {time.time() - t0:.2f} sn")
                first = False
            self._audio_q.put((text, speech.audio))

    def _play_loop(self) -> None:
        while True:
            item = self._audio_q.get()
            if item is None:
                return
            if self._stop.is_set():
                continue
            text, audio = item
            if self.first_play is None:
                self.first_play = time.time()
            play_audio(audio, self.rate, self.out_idx, self._stop)
            if not self._stop.is_set():
                self.played.append(text)


# ----------------------------------------------------------------------------
# Ajan
# ----------------------------------------------------------------------------

class Agent:
    def __init__(self, debug: bool = False):
        self.system_prompt = SYSTEM_PROMPT
        self.caller: dict = {}
        self.done_notes: list = []      # uygulanmış talimatlar (görüşme boyunca bağlamda kalır)
        self.pending_notes: list = []   # Mehmet Bey'in görüşme sırasında yazdığı, henüz iletilmemiş notlar
        self.note_log: list = []        # tüm notlar (not dosyasına yazılır)
        self.takeover = threading.Event()   # oturumu bitir sinyali (devral ya da sonlandır)
        self.end_reason = ""                # "devral" | "bitir"
        self.human_mic_name = ""            # Devral'da kullanılacak fiziksel mikrofon (uygulama bildirir)
        self.bridge: MicrophoneBridge | None = None
        self.bridge_lock = threading.RLock()
        if not sys.stdin.isatty():
            threading.Thread(target=self._stdin_reader, daemon=True).start()
        self.debug = debug
        self.in_idx = find_device(IN_DEVICE, "input")
        self.out_idx = find_device(OUT_DEVICE, "output")
        self.in_rate = int(sd.query_devices(self.in_idx)["default_samplerate"])
        log(f"Giriş: {sd.query_devices(self.in_idx)['name']} @ {self.in_rate} Hz | "
            f"Çıkış: {sd.query_devices(self.out_idx)['name']}")

        self.llm = LLM(LLM_PROVIDER, LLM_MODEL)
        log(f"Dil modeli: {LLM_PROVIDER} / {LLM_MODEL}")
        log(f"Konuşma modu: {CONVERSATION_MODE}")
        self._stt_lock = threading.Lock()
        self._spec: dict | None = None

        log(f"Konuşma tanıma yükleniyor: {STT_BACKEND} / {WHISPER_MODEL} (ilk seferde model indirilir)...")
        if STT_BACKEND == "mlx":
            import mlx_whisper
            self.mlx_whisper = mlx_whisper
            self._stt(np.zeros(16000, dtype=np.float32))   # modeli belleğe yükle ve ısıt
        else:
            from faster_whisper import WhisperModel
            self.whisper = WhisperModel(WHISPER_MODEL, device="cpu", compute_type="int8",
                                        cpu_threads=min(8, os.cpu_count() or 4))

        log("TTS (EMA Lightning) yükleniyor ve ısıtılıyor (ilk seferde yarım dakika sürebilir)...")
        self.voice = Voice(self.out_idx)
        self.voice.warmup()
        self._q: queue.Queue = queue.Queue()
        self.greeting_audio = self._prepare_greeting()
        self.greeting_override = None
        self._last_warm = time.time()
        log(f"HAZIR. Arama bekleniyor. (araya girme: {'açık' if BARGE_IN else 'kapalı'})")
        threading.Thread(target=self.pregenerate_greetings, daemon=True).start()

    def warm(self, reason: str = "") -> None:
        """STT ve TTS'i kısa bir işle sıcak tutar (boşta bellekten düşünce ilk tur 5-8 sn sürebiliyor)."""
        t0 = time.time()
        try:
            with self._stt_lock:
                self._stt(np.zeros(8000, dtype=np.float32))
            with self.voice.tts_lock:
                self.voice.tts.say("Merhaba.", sample_rate=self.voice.rate)
            if self.llm.provider == "ollama":
                self.llm.complete("Merhaba", 1)    # yerel modeli bellekte tut
            self._last_warm = time.time()
            dt = time.time() - t0
            if dt > 1.5 or reason:
                log(f"   ısıtma{(' (' + reason + ')') if reason else ''}: {dt:.1f} sn")
        except Exception as e:
            log(f"   ısıtma hatası: {e!r}")

    def _prepare_greeting(self):
        """Karşılama sesini hazırlar (çıkış aygıtının örnekleme hızında).
        Varsayılan metin için elle kaydedilmiş wav kullanılır; metin .env'den değiştirildiyse TTS ile üretilip önbelleğe alınır."""
        rate = self.voice.rate
        try:
            if GREETING_TEXT == LEGACY_GREETING and GREETING_WAV.exists():
                audio, r = read_wav(GREETING_WAV)
            else:
                import hashlib
                cache = BASE / "sesler_cache"
                cache.mkdir(exist_ok=True)
                f = cache / f"karsilama_{hashlib.md5(GREETING_TEXT.encode()).hexdigest()[:10]}_{rate}.wav"
                if f.exists():
                    audio, r = read_wav(f)
                else:
                    log("   karşılama metni TTS ile üretiliyor ve önbelleğe alınıyor...")
                    with self.voice.tts_lock:
                        audio = np.asarray(self.voice.tts.say(GREETING_TEXT, sample_rate=rate).audio, dtype=np.float32).reshape(-1)
                    r = rate
                    with wave.open(str(f), "wb") as w:
                        w.setnchannels(1); w.setsampwidth(2); w.setframerate(rate)
                        w.writeframes((np.clip(audio, -1, 1) * 32767).astype(np.int16).tobytes())
            if r != rate:
                n_out = int(len(audio) * rate / r)
                audio = np.interp(np.linspace(0, len(audio) - 1, n_out), np.arange(len(audio)), audio).astype(np.float32)
            log(f"   karşılama hazır ({len(audio) / rate:.1f} sn)")
            return audio
        except Exception as e:
            log(f"Karşılama sesi hazırlanamadı ({e}); TTS ile söylenecek.")
            return None

    def _greeting_cache_dir(self):
        d = BASE / "sesler_cache"
        d.mkdir(exist_ok=True)
        return d

    def _gender_title(self, first: str) -> str:
        """Ad için Bey/Hanım (ya da boş); sonuç diske önbelleğe alınır."""
        f = self._greeting_cache_dir() / "cinsiyet.json"
        try:
            cache = json.loads(f.read_text(encoding="utf-8")) if f.exists() else {}
        except Exception:
            cache = {}
        key = _norm(first)
        if key in cache:
            return cache[key]
        ans = self.llm.complete(
            f"Türkçe bir ad: \"{first}\". Bu ad genelde kadın adı mı erkek adı mı? "
            "Yalnızca şunlardan birini yaz: Hanım (kadın adı), Bey (erkek adı), yok (sevgi sözcüğü, unvan, belirsiz veya ad değil).", 8).strip()
        title = "Hanım" if ans.lower().startswith("han") else "Bey" if ans.lower().startswith("bey") else ""
        cache[key] = title
        try:
            f.write_text(json.dumps(cache, ensure_ascii=False), encoding="utf-8")
        except Exception:
            pass
        return title

    def _greeting_for(self, address: str):
        """'Tuba Hanım' gibi bir hitap için karşılama (metin, ses); sesi diskte önbellekler."""
        import hashlib
        text = f"Merhaba {address}, nasıl yardımcı olabilirim?"
        rate = self.voice.rate
        f = self._greeting_cache_dir() / f"kisisel_{hashlib.md5(text.encode()).hexdigest()[:10]}_{rate}.wav"
        if f.exists():
            audio, r = read_wav(f)
            if r == rate:
                return text, audio, True
        with self.voice.tts_lock:
            audio = np.asarray(self.voice.tts.say(text, sample_rate=rate).audio, dtype=np.float32).reshape(-1)
        try:
            with wave.open(str(f), "wb") as w:
                w.setnchannels(1); w.setsampwidth(2); w.setframerate(rate)
                w.writeframes((np.clip(audio, -1, 1) * 32767).astype(np.int16).tobytes())
        except Exception:
            pass
        return text, audio, False

    def _personal_greeting(self, caller: dict):
        """Rehberde kayıtlı arayan için adıyla karşılama üretir. (metin, ses) ya da (None, None)."""
        addr = alias_address(caller)
        first = (caller.get("first_name") or "").strip()
        if not addr and not (caller.get("in_contacts") and first):
            return None, None
        t0 = time.time()
        try:
            if not addr:
                title = self._gender_title(first)
                if not title:
                    log(f"   kişisel karşılama yok (ad/cinsiyet belirsiz: {first!r})")
                    return None, None
                addr = f"{first} {title}"
            text, audio, cached = self._greeting_for(addr)
            log(f"   kişisel karşılama hazır ({time.time() - t0:.1f} sn{', önbellekten' if cached else ''}; "
                f"{len(audio) / self.voice.rate:.1f} sn ses): {addr}")
            return text, audio
        except Exception as e:
            log(f"   kişisel karşılama hazırlanamadı: {e!r}")
            return None, None

    def pregenerate_greetings(self) -> None:
        """Özel hitap listesindeki kişiler için karşılamaları açılışta önceden üretir (ilk arama da hızlı olsun)."""
        raw = os.getenv("HITAP", "")
        for part in raw.split(";"):
            if "=" not in part:
                continue
            addr = part.split("=", 1)[1].strip()
            if not addr:
                continue
            try:
                t0 = time.time()
                _, _, cached = self._greeting_for(addr)
                if not cached:
                    log(f"   kişisel karşılama önceden üretildi: {addr} ({time.time() - t0:.1f} sn)")
            except Exception as e:
                log(f"   önceden üretim hatası: {e!r}")

    # -- dinleme -----------------------------------------------------------
    def _drain(self) -> None:
        try:
            while True:
                self._q.get_nowait()
        except queue.Empty:
            pass

    def wait_utterance(self, timeout: float, note_poll: bool = False):
        """Bir konuşma parçasını (16 kHz) döndürür; süre içinde konuşma yoksa None.
        note_poll=True: bekleyen not varsa ve arayan NOTE_IDLE_S boyunca sustuysa NOTE_SENTINEL döndürür."""
        det = UtteranceDetector(VAD_THRESHOLD)
        t_start = time.time()
        deadline = t_start + timeout
        last_dbg = 0.0
        while True:
            try:
                frame = self._q.get(timeout=0.2)
            except queue.Empty:
                frame = None
            if frame is not None:
                if self.debug and time.time() - last_dbg > 0.5:
                    last_dbg = time.time()
                    log(f"   seviye (RMS): {float(np.sqrt(np.mean(frame ** 2))):.4f}  eşik: {VAD_THRESHOLD}")
                utt = det.feed(frame)
                if SPEC_STT and det.tentative is not None:
                    snap, voiced = det.tentative
                    det.tentative = None
                    if self._spec is None or self._spec["done"].is_set():
                        self._start_spec(to_16k(snap, self.in_rate), voiced)
                if utt is not None:
                    rms = float(np.sqrt(np.mean(utt ** 2)))
                    log(f"   konuşma algılandı: {len(utt) / self.in_rate:.1f} sn, ortalama seviye {rms:.4f}")
                    if self._spec is not None and self._spec["voiced"] != det.last_voiced:
                        self._spec = None   # sessizlikten sonra konuşma devam etmiş; erken sonuç geçersiz
                    return to_16k(utt, self.in_rate)
            if self.takeover.is_set():
                return None
            if note_poll and self.pending_notes and not det.active and time.time() - t_start >= NOTE_IDLE_S:
                return NOTE_SENTINEL
            if not det.active and time.time() > deadline:
                return None

    def _start_spec(self, audio16: np.ndarray, voiced: int) -> None:
        """Arayan susar susmaz STT'yi arka planda başlat; bitiş sessizliği dolana kadar geçen süre kazanılır."""
        spec = {"voiced": voiced, "text": "", "done": threading.Event(), "t0": time.time(), "dt": 0.0}
        def run():
            try:
                with self._stt_lock:
                    spec["text"] = self._stt(audio16)
            except Exception as e:
                log(f"   erken STT hatası: {e!r}")
            spec["dt"] = time.time() - spec["t0"]
            spec["done"].set()
        self._spec = spec
        threading.Thread(target=run, daemon=True).start()

    def _stt(self, audio16: np.ndarray) -> str:
        if STT_BACKEND == "mlx":
            r = self.mlx_whisper.transcribe(audio16, path_or_hf_repo=WHISPER_MODEL, language="tr",
                                            temperature=0.0, condition_on_previous_text=False,
                                            no_speech_threshold=None, verbose=None)
            return r["text"].strip()
        segs, _ = self.whisper.transcribe(audio16, language="tr", beam_size=1,
                                          condition_on_previous_text=False, temperature=0.0,
                                          without_timestamps=True, no_speech_threshold=None)
        return " ".join(s.text.strip() for s in segs).strip()

    def transcribe(self, audio16: np.ndarray) -> str:
        t0 = time.time()
        spec, self._spec = self._spec, None
        if spec is not None:
            spec["done"].wait(timeout=15)
            text = spec["text"]
            log(f"   STT {spec['dt']:.2f} sn, erken başlatıldı; beklenen {time.time() - t0:.2f} sn ({len(audio16) / 16000:.1f} sn ses)")
        else:
            with self._stt_lock:
                text = self._stt(audio16)
            log(f"   STT {time.time() - t0:.2f} sn ({len(audio16) / 16000:.1f} sn ses)")
        squeezed = collapse_repeats(text)
        if len(squeezed) < len(text) * 0.7:
            log(f"   (STT takılma/tekrar temizlendi: {text!r} -> {squeezed!r})")
            save_debug_audio(audio16, "tekrar")
            text = squeezed
        low = text.lower()
        if len(text) < 2:
            log("   (STT boş sonuç döndürdü; ses debug_ses klasörüne kaydedildi)")
            save_debug_audio(audio16, "bos")
            return ""
        if any(h in low for h in HALLUCINATIONS) and len(text) < 40:
            log(f"   (STT sonucu hayali cümle sanılıp elendi: {text!r}; ses debug_ses klasörüne kaydedildi)")
            save_debug_audio(audio16, "elendi")
            return ""
        return text

    def _start_bridge(self, mic_name: str = "") -> bool:
        with self.bridge_lock:
            if self.bridge is not None:
                return True
            try:
                idx = find_human_mic(mic_name or self.human_mic_name or HUMAN_MIC)
                self.bridge = MicrophoneBridge(idx, self.out_idx, int(sd.query_devices(self.out_idx)["default_samplerate"]) or 48000)
                log(f"MİKROFON KÖPRÜSÜ AÇIK: {sd.query_devices(idx)['name']} -> {sd.query_devices(self.out_idx)['name']}")
                return True
            except Exception as e:
                log(f"UYARI: mikrofon köprüsü açılamadı: {e!r}")
                self.bridge = None
                return False

    def _stop_bridge(self) -> None:
        with self.bridge_lock:
            b, self.bridge = self.bridge, None
            if b is None:
                return
            try:
                b.close()
            except Exception as e:
                log(f"Köprü kapanırken hata: {e!r}")
            log("MİKROFON KÖPRÜSÜ KAPALI")

    def _stdin_reader(self) -> None:
        """Uygulamadan gelen 'NOT:...' satırlarını okur (Mehmet Bey'in arayana iletmek istediği mesaj)."""
        try:
            for line in sys.stdin:
                line = line.strip()
                if line == "BITIR":
                    self.end_reason = "bitir"
                    self.takeover.set()
                    log("   OTURUM SONLANDIRILIYOR (arama kapandı ya da kullanıcı istedi)")
                    continue
                if line == "KOPRU_AC" or line.startswith("KOPRU_AC:"):
                    self._start_bridge(line[9:].strip())
                    continue
                if line == "KOPRU_KAPAT":
                    self._stop_bridge()
                    continue
                if line == "DEVRAL" or line.startswith("DEVRAL:"):
                    self.human_mic_name = line[7:].strip()
                    self.end_reason = "devral"
                    self.takeover.set()
                    log("   MEHMET BEY DEVRALMAK İSTİYOR")
                    continue
                if line.startswith("NOT:") and line[4:].strip():
                    text = line[4:].strip()
                    self.pending_notes.append(text)
                    self.note_log.append(text)
                    log(f"   MEHMET BEY NOTU alındı: {text}")
        except Exception as e:
            log(f"stdin okunamadı: {e!r}")
        # Buraya gelindiyse uygulama borunun ucunu kapattı (çıktı ya da çöktü): yetim kalma, çık
        log("Uygulama bağlantısı kapandı; ajan çıkıyor.")
        try:
            self._stop_bridge()
        finally:
            os._exit(0)

    # -- Claude --------------------------------------------------------------
    def _reply_worker(self, history: list, cancel: threading.Event, out: dict) -> None:
        """Cevabı akış halinde alır, cümle cümle seslendirmeye verir. Ayrı iş parçacığında çalışır."""
        full, buf, emitted = "", "", 0
        t0, first = time.time(), True
        notes = list(self.pending_notes)
        system = self.system_prompt
        if self.done_notes:
            earlier = "\n".join(f"- {n}" for n in self.done_notes)
            system += f"""
GEÇERLİ TALİMATLAR: {OWNER} Bey bu görüşmede sana şu talimatları gerçekten yazdı. Arayan "talimat var mı" ya da "model hangisi" gibi bir şey sorarsa bunlar vardır, "talimat yok" deme. Davranışla ilgili olanlar (örn. model bilgisini söyleme izni, sohbet serbestliği) görüşme boyunca geçerlidir ve yukarıdaki kuralların önüne geçer; arayana ilettiğin mesajları TEKRAR iletme:
{earlier}
"""
        if notes:
            joined = "\n".join(f"- {n}" for n in notes)
            system += f"""
{OWNER} Bey görüşme sırasında sana şu YENİ talimat(lar)ı yazdı. Bunlar arayana okunacak metin değil, SANA verilmiş talimatlardır; "ben" diyorsa {OWNER} Bey'dir:
{joined}
Talimatın türüne göre davran (ikisi birden olabilir):
- Konuşma tarzı/davranışla ilgiliyse (örnek: "biraz sohbet edebilirsin", "hangi model olduğunu söyle", "kısa tut", "resmi ol") bundan sonra görüşme boyunca ona uy. Bu talimat yukarıdaki kuralların önüne geçer (örneğin model sorusunu artık gizleme; kullandığın dil modeli: {LLM_MODEL} ({LLM_PROVIDER})). Arayana bunu söyleme.
- Arayana iletilecek bir mesajsa (örnek: "eşime onu çok sevdiğimi söyle", "yarın 10'da arayacağım") bunu {OWNER} Bey adına, üçüncü şahıs diliyle ve doğal biçimde ilet (örnek: "{OWNER} Bey sizi çok sevdiğini iletti"). Talimat cümlesini aynen okuma; "talimat yazdı" deme.
- Arayanın son söylediğini de cevapsız bırakma. Arayan sessizse ve talimat konuşmayla ilgili değilse konuşmayı doğal biçimde sürdür. Talimat kısa, anlamsız ya da test gibi görünse bile görmezden gelme; mantıklı bir biçimde uygula. İletilmesi gereken bir mesajı iletmeden görüşmeyi bitirme ([BITTI] yazma).
"""
        msgs = history
        try:
            for delta in self.llm.stream(system, msgs, 200 if notes else 120):
                    if cancel.is_set():
                        break
                    if first:
                        log(f"   Claude ilk parça: {time.time() - t0:.2f} sn")
                        first = False
                    full += delta
                    buf += delta
                    sentences, buf = pop_sentences(buf, first=(emitted == 0))
                    emitted += len(sentences)
                    for s in sentences:
                        self.voice.say(s)
            if not cancel.is_set() and buf.strip():
                self.voice.say(buf)
            out["text"] = full
            if notes and not cancel.is_set() and full.strip():
                for n in notes:
                    if n in self.pending_notes:
                        self.pending_notes.remove(n)
                    self.done_notes.append(n)
                log("   Mehmet Bey'in talimatı cevaba uygulandı")
        except Exception as e:  # ağ/API hatası
            out["error"] = e
            log(f"   Claude hatası: {e!r}")
            if not cancel.is_set() and not full.strip():
                fallback = "Üzgünüm, bağlantıda kısa bir sorun oldu. Tekrar söyler misiniz?"
                self.voice.say(fallback)
                out["text"] = fallback
        finally:
            self.voice.end()

    def summarize(self, transcript: str) -> str:
        prompt = (
            f"Aşağıda {OWNER} Bey adına cevaplanan bir telefon görüşmesinin dökümü var. "
            "Ses tanıma hatalı olabilir. Türkçe, kısa ve net bir not çıkar. Şu başlıkları kullan:\n"
            "Arayan:\nKonu:\nGeri dönüş bilgisi:\nAciliyet (düşük/orta/yüksek):\nÖnerilen işlem:\n"
            "Bilmediğin bilgiye 'belirtilmedi' yaz, uydurma.\n"
            + (f"Telefon sisteminden gelen arayan bilgisi: {caller_summary(self.caller)}. 'Arayan:' satırında bunu kullan.\n" if self.caller else "")
            + "\n" + transcript
        )
        return self.llm.complete(prompt, 400)

    # -- cevap sırasında dinleme (araya girme) -----------------------------
    def _monitor(self, reply_thread, cancel: threading.Event, arm_after: float = 0.0, allow: bool = True):
        """Asistan konuşurken arayanı izler. (konuşma16k | None, araya_girildi) döndürür.
        arm_after: ilk N saniye araya girme kapalı (hat açılış gürültüsü). allow=False: hiç araya girilmesin."""
        det = UtteranceDetector(VAD_THRESHOLD * BARGE_FACTOR)
        self._drain()
        interrupted = False
        recent: list = []
        t0 = time.time()
        while True:
            if self.takeover.is_set():
                cancel.set()
                self.voice.interrupt()
                return None, False
            speaking = (reply_thread is not None and reply_thread.is_alive()) or self.voice.busy()
            if not speaking and not det.active:
                return None, interrupted
            try:
                frame = self._q.get(timeout=0.05)
            except queue.Empty:
                continue
            if not allow or time.time() - t0 < arm_after:
                continue   # henüz dinlemiyoruz; algılayıcıya da verme (gürültü birikmesin)
            utt = det.feed(frame)
            recent.append(float(np.sqrt(np.mean(np.square(frame)))))
            if BARGE_IN and not interrupted and det.active and det.voiced >= BARGE_FRAMES:
                interrupted = True
                lvl = recent[-BARGE_FRAMES:]
                log(f"   ✋ arayan araya girdi, asistan susuyor (seviye ort={sum(lvl) / len(lvl):.4f} maks={max(lvl):.4f}, "
                    f"eşik={VAD_THRESHOLD * BARGE_FACTOR:.4f}, asistan {time.time() - t0:.1f} sn'dir konuşuyor)")
                cancel.set()
                self.voice.interrupt()
            if utt is not None and interrupted:
                return to_16k(utt, self.in_rate), True

    def speak_reply(self, history: list, t_utt_end: float):
        """Cevabı üretip konuşur. (geçmişe_yazılacak_metin, araya_girildi, bekleyen_konuşma) döndürür."""
        cancel = threading.Event()
        out: dict = {}
        self.voice.start()
        th = threading.Thread(target=self._reply_worker, args=(history, cancel, out), daemon=True)
        th.start()
        pending, interrupted = self._monitor(th, cancel)
        th.join(timeout=5)
        self.voice.join()
        if self.voice.first_play:
            log(f"   ⏱ konuşma bitti -> ilk ses: {self.voice.first_play - t_utt_end:.2f} sn "
                f"(buna ayrıca {END_SILENCE_S:.1f} sn sessizlik bekleme eklenir)")
        if interrupted:
            spoken = " ".join(self.voice.played).strip()
            log(f"ASİSTAN (kesildi): {spoken}")
            return (spoken + " [sözü kesildi]").strip(), True, pending
        if not out.get("text", "").strip():
            log(f"   UYARI: model boş cevap döndürdü ({LLM_PROVIDER}/{LLM_MODEL}); sabit cümle söyleniyor")
        full = out.get("text", "").strip() or "Üzgünüm, bir sorun oluştu."
        log(f"ASİSTAN: {clean_for_speech(full)}")
        return full, False, None

    # -- oturum --------------------------------------------------------------
    def run_session(self) -> None:
        self._stop_bridge()   # önceki görüşmeden kalan mikrofon köprüsü varsa kapat
        log("=== ARAMA OTURUMU BAŞLADI ===")
        self.caller = load_caller()
        self.pending_notes = []
        self.done_notes = []
        self.note_log = []
        self.takeover.clear()
        self.end_reason = ""
        self.system_prompt = build_system_prompt(self.caller)
        if self.caller:
            log(f"   arayan: {caller_summary(self.caller)}")
        started = datetime.now()
        history = [{"role": "user", "content": "(Arama bağlandı.)"},
                   {"role": "assistant", "content": GREETING_TEXT}]
        transcript = [f"Asistan: {GREETING_TEXT}"]

        if CONVERSATION_MODE in ("realtime", "live"):
            if self._run_realtime(started, transcript):
                return
            log("   Realtime kullanılamadı; klasik hatta geçiliyor")
            transcript = [f"Asistan: {GREETING_TEXT}"]

        self._drain()
        frame_len = int(self.in_rate * FRAME_S)

        def cb(indata, frames, time_info, status):
            self._q.put(indata.mean(axis=1).copy())

        stream = sd.InputStream(device=self.in_idx, channels=2, samplerate=self.in_rate,
                                blocksize=frame_len, dtype="float32", callback=cb)
        stream.start()
        try:
            self._converse(history, transcript)
        finally:
            stream.stop()
            stream.close()

        self.save_notes(started, transcript)
        log("=== OTURUM BİTTİ ===")

    def _run_realtime(self, started, transcript: list) -> bool:
        """OpenAI Realtime modu (CONVERSATION_MODE=realtime). Kurulamazsa False döner ve klasik hat devralır."""
        try:
            import realtime_mode
            live_mode = None
            if CONVERSATION_MODE == "live":
                import live_mode
        except Exception as e:
            log(f"   Realtime/Live modülü yüklenemedi: {e!r} (websockets kurulu mu?)")
            return False
        try:
            cls = live_mode.LiveConversation if live_mode is not None else realtime_mode.RealtimeConversation
            ok = cls(self).run(transcript)
        except Exception as e:
            log(f"   Realtime oturum hatası: {e!r}")
            return False
        if not ok:
            return False
        self.save_notes(started, transcript)
        log("=== OTURUM BİTTİ ===")
        return True

    def play_greeting(self):
        """Karşılamayı çalar; arayan araya girerse (ilk GREETING_ARM_S sn hariç) keser. (araya_girildi, bekleyen_konuşma)"""
        cancel = threading.Event()
        self.voice.start()
        audio = self.greeting_override if self.greeting_override is not None else self.greeting_audio
        if audio is not None:
            log(f"   karşılama çalınıyor ({len(audio) / self.voice.rate:.1f} sn)")
            self.voice._audio_q.put(("(karşılama)", audio))
        else:
            self.voice.say(GREETING_TEXT)
        self.voice.end()
        pending, interrupted = self._monitor(None, cancel, arm_after=GREETING_ARM_S, allow=GREETING_BARGE_IN)
        self.voice.join()
        log("   karşılama kesildi, arayan dinleniyor" if interrupted else "   karşılama bitti, arayan dinleniyor")
        return interrupted, pending

    def _converse(self, history: list, transcript: list) -> None:
        self._spec = None
        threading.Thread(target=self.warm, args=("arama başı",), daemon=True).start()   # karşılama çalarken modelleri ısıt
        self.greeting_override = None
        holder = {}
        pg = None
        if self.caller:
            def _mk():
                holder["text"], holder["audio"] = self._personal_greeting(self.caller)
            pg = threading.Thread(target=_mk, daemon=True)
            pg.start()
        time.sleep(GREETING_DELAY_S)
        if pg is not None:
            pg.join(timeout=2.5)   # bağlantı süresi bitince hazır değilse en fazla bu kadar bekle
            if holder.get("audio") is not None:
                self.greeting_override = holder["audio"]
                history[1]["content"] = holder["text"]
                transcript[0] = f"Asistan: {holder['text']}"
            elif pg.is_alive():
                log("   kişisel karşılama yetişmedi; standart karşılama kullanılıyor")
        _, pending = self.play_greeting()   # pending: karşılamayı keserek söylenen konuşma

        wait = FIRST_WAIT_S
        replies = 0
        false_barge = 0
        cut_unanswered = False   # son cevap araya girilerek kesildi ve arayanın sorusu hâlâ cevapsız
        while replies < MAX_TURNS:
            if self.takeover.is_set():
                break
            if pending is not None:
                audio16, pending = pending, None
            else:
                audio16 = self.wait_utterance(wait, note_poll=True)
                if audio16 is None:
                    if self.takeover.is_set():
                        break
                    log("Arayandan ses gelmedi, oturum bitiyor.")
                    break
            if isinstance(audio16, str) and audio16 == NOTE_SENTINEL:
                # Arayan bekliyor, Mehmet Bey'in notu var: beklemeden ilet
                log("   arayan sessiz; bekleyen not kendiliğinden iletiliyor")
                history.append({"role": "user", "content": "(Arayan sessizce bekliyor.)"})
                t_utt_end = time.time()
                text = None
            else:
                t_utt_end = time.time()
                text = self.transcribe(audio16)
                if not text:
                    # Araya girildi sanıldı ama gelen ses boş/hayali çıktı (gürültü, yankı): kesilen cevabı yeniden söyle,
                    # yoksa arayanın sorusu cevapsız kalıp görüşme sessizce biter.
                    if cut_unanswered and false_barge < 1 and history and history[-1]["role"] == "assistant":
                        false_barge += 1
                        cut_unanswered = False
                        log("   (araya girme anlaşılmaz çıktı; kesilen cevap yeniden söyleniyor)")
                        history.pop()
                        if transcript and transcript[-1].startswith("Asistan:"):
                            transcript.pop()
                        answer, interrupted, pending = self.speak_reply(history, time.time())
                        if self.takeover.is_set():
                            break
                        transcript.append(f"Asistan: {clean_for_speech(answer)}")
                        history.append({"role": "assistant", "content": answer})
                        cut_unanswered = interrupted
                        if END_TOKEN in answer and not interrupted:
                            log("Asistan görüşmeyi bitirdi.")
                            break
                    wait = IDLE_WAIT_S
                    continue
                log(f"ARAYAN: {text}")
                transcript.append(f"Arayan: {text}")
                history.append({"role": "user", "content": text})

            replies += 1
            answer, interrupted, pending = self.speak_reply(history, t_utt_end)
            if self.takeover.is_set():
                break
            if interrupted and pending is None and false_barge < 1:
                # Araya girildi sanıldı ama arayan bir şey söylemedi (gürültü): cevabı yeniden söyle
                false_barge += 1
                log("   (yanlış araya girme: konuşma yoktu; cevap yeniden söyleniyor)")
                answer, interrupted, pending = self.speak_reply(history, time.time())
                if self.takeover.is_set():
                    break
            if not interrupted:
                false_barge = 0
            cut_unanswered = interrupted
            transcript.append(f"Asistan: {clean_for_speech(answer)}")
            history.append({"role": "assistant", "content": answer})
            if END_TOKEN in answer and not interrupted:
                log("Asistan görüşmeyi bitirdi.")
                break
            wait = IDLE_WAIT_S

        if self.takeover.is_set():
            if self.end_reason == "bitir":
                self.voice.interrupt()
                transcript.append("(Görüşme sonlandırıldı)")
                log("SONLANDIRILDI: oturum kapatılıyor")
            else:
                self.voice.start()
                self.voice.say(f"{OWNER} Bey şimdi bağlanıyor.")
                self.voice.end()
                self.voice.join()
                transcript.append(f"({OWNER} Bey görüşmeyi devraldı)")
                log("DEVRALINDI: asistan görüşmeden çıkıyor")
                self._start_bridge()   # fiziksel mikrofon -> Asistan Ses Çıkışı (arama mikrofonu Asistan Mikrofonu)

    def save_notes(self, started: datetime, transcript: list) -> None:
        """Notu hemen yazar (döküm + notlar); özeti arka planda üretip dosyaya ekler.
        Böylece özet beklenirken yeni arama karşılanabilir."""
        text = "\n".join(transcript)
        notes_dir = BASE / "notlar"
        notes_dir.mkdir(exist_ok=True)
        path = notes_dir / f"{started.strftime('%Y-%m-%d_%H-%M-%S')}.md"
        caller_line = (f"**Arayan numarası/kaydı:** {caller_summary(self.caller)}\n\n" if self.caller else "")
        notes_block = (("## Mehmet Bey'in görüşme sırasında verdiği notlar\n" + "\n".join(f"- {n}" for n in self.note_log) + "\n\n") if self.note_log else "")

        def write(summary: str) -> None:
            tmp = path.with_suffix(".tmp")
            tmp.write_text(f"# Arama notu - {started.strftime('%d.%m.%Y %H:%M')}\n\n" + caller_line + notes_block
                           + f"## Özet\n{summary}\n\n## Döküm\n{text}\n", encoding="utf-8")
            os.replace(tmp, path)

        need_summary = len(transcript) > 1
        write("Özet hazırlanıyor…" if need_summary else "Arayan konuşmadı.")
        log(f"Not kaydedildi: {path}")
        if not need_summary:
            return

        job = {"path": str(path), "started": started.isoformat(), "text": text,
               "caller_line": caller_line, "notes_block": notes_block, "caller": self.caller or {}}
        job_file = BASE / "summary_jobs" / f"{started.strftime('%Y%m%d_%H%M%S')}.json"
        try:
            job_file.parent.mkdir(exist_ok=True)
            job_file.write_text(json.dumps(job, ensure_ascii=False), encoding="utf-8")   # çökme/ağ kesintisinde özet kaybolmasın
            os.chmod(job_file, 0o600)
        except Exception as e:
            log(f"Özet işi kaydedilemedi: {e!r}")

        def work() -> None:
            summary, err = None, None
            for attempt, wait in enumerate((0, 3, 8), start=1):
                if wait:
                    time.sleep(wait)
                try:
                    summary = self.summarize(text)
                    break
                except Exception as e:
                    err = e
                    log(f"Özet denemesi {attempt}/3 başarısız: {e!r}")
            if summary is None:
                write(f"(Özet çıkarılamadı: {err}) Görüşme dökümü aşağıda korunmuştur. Asistan bir sonraki açılışta yeniden dener.")
                return          # iş dosyası kalır; açılışta yeniden denenir
            try:
                write(summary)
                job_file.unlink(missing_ok=True)
            except Exception as e:
                log(f"Özet yazılamadı: {e!r}")
            log("ÖZET:\n" + summary)

        threading.Thread(target=work, daemon=True).start()

    def resume_summaries(self) -> None:
        """Önceki oturumlarda özeti çıkarılamayan notları arka planda yeniden dener."""
        jobs_dir = BASE / "summary_jobs"
        if not jobs_dir.is_dir():
            return

        def run() -> None:
            for jf in sorted(jobs_dir.glob("*.json")):
                try:
                    job = json.loads(jf.read_text(encoding="utf-8"))
                    path = Path(job["path"])
                    started = datetime.fromisoformat(job["started"])
                    if not str(path).startswith(str(BASE)):
                        jf.unlink(missing_ok=True)
                        continue
                    summary = self.summarize(job["text"])
                    tmp = path.with_suffix(".tmp")
                    tmp.write_text(f"# Arama notu - {started.strftime('%d.%m.%Y %H:%M')}\n\n" + job.get("caller_line", "")
                                   + job.get("notes_block", "") + f"## Özet\n{summary}\n\n## Döküm\n{job['text']}\n", encoding="utf-8")
                    os.replace(tmp, path)
                    jf.unlink(missing_ok=True)
                    log(f"Bekleyen özet tamamlandı: {path.name}")
                except Exception as e:
                    log(f"Bekleyen özet ertelendi ({jf.name}): {e!r}")
                    break       # ağ/anahtar sorunu olabilir; bir sonraki açılışta tekrar dene

        threading.Thread(target=run, daemon=True).start()



# ----------------------------------------------------------------------------
# Bağlantı sınaması (ayarlar penceresindeki "Bağlantıyı sına" düğmesi): kısa gerçek istekler, görüşme içeriği göndermez
# ----------------------------------------------------------------------------

def selftest() -> int:
    """Seçili modelleri ve (varsa) Realtime/GPT-Live erişimini sınar. Her satır: OK|FAIL|ATLA: açıklama. Hata varsa 1 döner."""
    bad = 0

    def say(kind: str, msg: str) -> None:
        print(f"{kind}: {msg}", flush=True)

    # 1) dil modeli
    try:
        t0 = time.time()
        llm = LLM(LLM_PROVIDER, LLM_MODEL)
        out = (llm.complete("Yalnızca 'tamam' yaz.", 12) or "").strip()
        say("OK", f"Dil modeli {LLM_MODEL} ({LLM_PROVIDER}) yanıt verdi ({time.time() - t0:.1f} sn): {out[:40]!r}")
    except SystemExit as e:
        say("FAIL", f"Dil modeli: {e}"); bad += 1
    except Exception as e:
        say("FAIL", f"Dil modeli {LLM_MODEL} ({LLM_PROVIDER}): {str(e)[:200]}"); bad += 1

    # 2) Realtime / GPT-Live: WebSocket el sıkışma
    mode = CONVERSATION_MODE
    if mode not in ("realtime", "live"):
        say("ATLA", "Konuşma modu klasik; Realtime/GPT-Live sınanmadı.")
        return 1 if bad else 0
    key = os.getenv("OPENAI_API_KEY", "")
    if not key:
        say("FAIL", f"{mode} için OPENAI_API_KEY gerekli."); return 1
    try:
        import json as _json
        from websockets.sync.client import connect
        hdr = {"Authorization": f"Bearer {key}"}
        if mode == "live":
            url = os.getenv("LIVE_URL", "wss://api.openai.com/v1/live/sessions").strip()
            model = os.getenv("LIVE_MODEL", "gpt-live-1").strip()
        else:
            model = os.getenv("RT_MODEL", "gpt-realtime").strip()
            url = os.getenv("RT_URL", "wss://api.openai.com/v1/realtime").strip() + f"?model={model}"
        t0 = time.time()
        try:
            ws = connect(url, additional_headers=hdr, open_timeout=8, max_size=None)
        except TypeError:
            ws = connect(url, extra_headers=hdr, open_timeout=8, max_size=None)
        try:
            if mode == "live":
                ws.send(_json.dumps({"type": "session.start", "event_id": "selftest",
                                     "session": {"model": model, "instructions": "Sınama.",
                                                 "audio": {"format": {"type": "audio/pcm", "rate": 24000}}}}))
                want = "session.started"
            else:
                want = "session.created"
            deadline = time.time() + 10
            ok = False
            while time.time() < deadline:
                try:
                    ev = _json.loads(ws.recv(timeout=1.0))
                except TimeoutError:
                    continue
                if ev.get("type") == want:
                    ok = True
                    break
                if ev.get("type") == "error":
                    raise RuntimeError(_json.dumps(ev.get("error", ev), ensure_ascii=False)[:200])
            if ok:
                say("OK", f"{'GPT-Live' if mode == 'live' else 'Realtime'} {model} oturumu açıldı ({time.time() - t0:.1f} sn)")
            else:
                say("FAIL", f"{model}: oturum açılışı zaman aşımına uğradı"); bad += 1
        finally:
            try:
                ws.close()
            except Exception:
                pass
    except Exception as e:
        say("FAIL", f"{'GPT-Live' if mode == 'live' else 'Realtime'} bağlantısı: {str(e)[:220]}"); bad += 1
    return 1 if bad else 0

# ----------------------------------------------------------------------------
# Giriş noktası
# ----------------------------------------------------------------------------

def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--now", action="store_true", help="hemen bir oturum başlat")
    ap.add_argument("--debug", action="store_true", help="ses seviyesini yazdır")
    ap.add_argument("--devices", action="store_true", help="ses aygıtlarını listele")
    ap.add_argument("--selftest", action="store_true", help="seçili model ve bağlantıları kısa gerçek isteklerle sına")
    args = ap.parse_args()

    if args.selftest:
        sys.exit(selftest())

    if args.devices:
        print(sd.query_devices())
        return

    agent = Agent(debug=args.debug)
    agent.resume_summaries()
    if args.now:
        agent.run_session()
        return

    flag = BASE / "go.flag"
    flag.unlink(missing_ok=True)
    while True:
        if flag.exists():
            flag.unlink(missing_ok=True)
            try:
                agent.run_session()
            except Exception as e:
                log(f"Oturum hatası: {e!r}")
            flag.unlink(missing_ok=True)  # oturum sırasında oluşan eski bayrakları sil
            log("HAZIR. Arama bekleniyor.")
        elif KEEPWARM_S > 0 and time.time() - agent._last_warm > KEEPWARM_S:
            agent.warm()
        time.sleep(0.2)


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        print("\nÇıkılıyor.")
