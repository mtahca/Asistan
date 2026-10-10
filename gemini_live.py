"""Gemini Live transport and call loop (gemini-3.8-live or gemini-3.1-flash-live-preview).
Raw WebSocket protocol: ai.google.dev/api/live. Input is 16 kHz PCM, output 24 kHz PCM.
Gemini listens, decides when the caller has finished, and speaks; there is no backend delegation.
"""
from __future__ import annotations
import base64
import json
import queue
import threading
import time
from datetime import datetime

from live import LiveError, NoiseGate, PCMPlayer, diagnose, lower_tr, prompt

ENDPOINT = 'wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent'
INPUT_RATE = 16000
OUTPUT_RATE = 24000
MODELS = ('gemini-3.8-live', 'gemini-3.1-flash-live-preview')
# Prebuilt voices; keep the Swift catalog (BetaModelConfiguration.geminiVoices) in sync.
VOICES = ('Kore', 'Aoede', 'Leda', 'Zephyr', 'Puck', 'Charon', 'Fenrir', 'Orus', 'Callirrhoe', 'Autonoe', 'Enceladus',
          'Iapetus', 'Umbriel', 'Algieba', 'Despina', 'Erinome', 'Algenib', 'Rasalgethi', 'Laomedeia', 'Achernar',
          'Alnilam', 'Schedar', 'Gacrux', 'Pulcherrima', 'Achird', 'Zubenelgenubi', 'Vindemiatrix', 'Sadachbia',
          'Sadaltager', 'Sulafat')
FAREWELLS = ('hoşça kal', 'hoşçakal', 'iyi günler', 'iyi akşamlar', 'iyi geceler', 'görüşmek üzere', 'görüşürüz',
             'güle güle', 'kendine iyi bak', 'kendinize iyi bak', 'bay bay', 'baybay')


def model_name(values):
    model = values.get('GEMINI_LIVE_MODEL') or 'gemini-3.8-live'
    if model not in MODELS: raise ValueError('Gemini modeli geçersiz. Model ayarlarını yeniden kaydedin.')
    return model


def voice_name(values):
    voice = values.get('GEMINI_LIVE_VOICE') or 'Kore'
    if voice not in VOICES: raise ValueError('Gemini sesi geçersiz. Ayarlardan desteklenen bir ses seçin.')
    return voice


def require_key(values):
    if len(values.get('GEMINI_API_KEY', '').strip()) <= 20:
        raise LiveError('Gemini Live için Gemini API anahtarı girin.')


def setup_message(instructions, model, voice, handle=None):
    """Native-audio models pick the language themselves; Turkish is enforced in the instructions."""
    config = dict(responseModalities=['AUDIO'],
                  speechConfig=dict(voiceConfig=dict(prebuiltVoiceConfig=dict(voiceName=voice))))
    if model == 'gemini-3.1-flash-live-preview':
        config['thinkingConfig'] = dict(thinkingLevel='minimal')  # 3.8 rejects thinkingConfig
    setup = dict(model='models/' + model, generationConfig=config,
                 systemInstruction=dict(parts=[dict(text=instructions)]),
                 inputAudioTranscription=dict(languageCodes=['tr']), outputAudioTranscription=dict(languageCodes=['tr']),
                 # Low start sensitivity: line noise must not count as the caller speaking.
                 realtimeInputConfig=dict(automaticActivityDetection=dict(startOfSpeechSensitivity='START_SENSITIVITY_LOW',
                                                                          silenceDurationMs=600)),
                 sessionResumption=dict(handle=handle) if handle else {})
    return dict(setup=setup)


def instructions(system):
    text = prompt(system).split('Delegation policy:')[0].replace('kapanışı arka plan modeline danış', 'vedalaş ve konuşmayı bitir')
    return text + '''
Her zaman Türkçe konuş. Kısa ve doğal cümleler kur; tek seferde tek soru sor.
Görüşmeyi bitirirken vedalaş ("İyi günler" gibi); arka plan modeli veya teknik işaret yoktur.
Bir işlem yapıldığını, randevu veya dönüş sözü verildiğini iddia etme; yalnızca mesajı not al.
'''


class GeminiConnection:
    def __init__(self, key, timeout=8, factory=None):
        import certifi
        import websocket
        self.timeout_error = websocket.WebSocketTimeoutException
        self.ws = None
        try:
            self.ws = (factory or websocket.create_connection)(ENDPOINT + '?key=' + key.strip(), timeout=timeout,
                redirect_limit=0, suppress_origin=True, enable_multithread=True, sslopt={'ca_certs': certifi.where()})
            if self.ws.getstatus() != 101:
                raise LiveError('Gemini Live bağlantısı kabul edilmedi.')
            self.ws.settimeout(0.5)
        except Exception as e:
            self.close()
            code = getattr(e, 'status_code', None)
            if code in (400, 401, 403): message = 'Gemini anahtarı kabul edilmedi veya hesabın Live API erişimi yok.'
            elif code == 429: message = 'Gemini kota veya hız sınırı. Hesap kullanımını kontrol edin.'
            elif isinstance(e, LiveError): message = str(e)
            else: message = 'Gemini Live bağlantısı kurulamadı. İnternet ve hesap erişimini kontrol edin.'
            diagnose(f'Gemini bağlantısı: {type(e).__name__} {code or ""}')
            raise LiveError(message) from None

    def send(self, message, drop_on_timeout=False):
        payload = json.dumps(message, ensure_ascii=False)
        for attempt in range(3):
            try:
                self.ws.send(payload); return True
            except self.timeout_error:
                if drop_on_timeout: return False
                time.sleep(0.05)
            except Exception as e:
                diagnose(f'Gemini gönderimi başarısız: {type(e).__name__}: {e}')
                break
        raise LiveError('Gemini Live bağlantısına veri gönderilemedi.')

    def recv(self):
        try:
            raw = self.ws.recv()
            if not raw: raise LiveError('Gemini Live bağlantısı kapandı.')
            message = json.loads(raw)
            if not isinstance(message, dict): raise ValueError()
            return message
        except self.timeout_error:
            return None
        except LiveError:
            raise
        except Exception as e:
            reason = getattr(self.ws, 'close_reason', None) if self.ws else None
            diagnose(f'Gemini okuma hatası: {type(e).__name__}: {e} {reason or ""}')
            raise LiveError('Gemini Live bağlantısı kesildi.') from None

    def close(self):
        if self.ws is not None:
            try: self.ws.close()
            except Exception: pass


def wait_for_setup(connection, stop=None, timeout=12):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline and not (stop and stop.is_set()):
        message = connection.recv()
        if message is None: continue
        if 'setupComplete' in message: return True
    if stop and stop.is_set(): return False
    raise LiveError('Gemini Live hazırlanırken zaman aşımı. Model erişimini bağlantı testiyle sınayın.')


def check_access(key, model, voice, factory=GeminiConnection):
    """No audio, caller data or conversation; only opens and closes a session."""
    connection = factory(key)
    try:
        connection.send(setup_message('Bu bir bağlantı testidir. Sessiz kal.', model, voice))
        wait_for_setup(connection, timeout=10)
    finally:
        connection.close()


class Transcript:
    """Caller and assistant text arrive as small pieces; consecutive pieces of one speaker form a row."""
    def __init__(self, started):
        self.rows = []; self.started = started

    def add(self, speaker, text):
        if not text: return False
        now = datetime.now()
        if self.rows and self.rows[-1]['speaker'] == speaker and time.monotonic() - self.rows[-1]['last'] < 2.5:
            row = self.rows[-1]
        else:
            row = dict(speaker=speaker, text='', clock=now, last=0.0)
            self.rows.append(row)
        row['text'] += text; row['last'] = time.monotonic()
        return True

    def lines(self):
        out = []
        for r in self.rows:
            elapsed = max(0, int((r['clock'] - self.started).total_seconds()))
            out.append(f"[{r['clock']:%H:%M:%S} +{elapsed // 60:02d}:{elapsed % 60:02d}] {r['speaker']}: {r['text'].strip()}")
        return out

    def public(self):
        return [dict(speaker=r['speaker'], text=r['text'].strip()) for r in self.rows if r['text'].strip()]


class GeminiCall:
    RECONNECT_LIMIT = 2

    def __init__(self, agent, session, system, greeting, key, model, voice, factory=GeminiConnection):
        self.agent = agent; self.s = session; self.greeting = greeting
        self.key = key; self.model = model; self.voice = voice; self.factory = factory
        self.instructions = instructions(system)
        self.connection = None; self.player = PCMPlayer(agent.np, OUTPUT_RATE)
        self.events = queue.Queue(maxsize=1024); self.audio = queue.Queue(maxsize=25); self.errors = queue.Queue()
        self.worker_stop = threading.Event(); self.streams = []
        self.transcript = Transcript(session.started)
        self.handle = None; self.go_away = False
        self.last_input = 0.0; self.ending = False; self.end_requested = 0.0
        self.greeting_sent_at = None; self.first_output = False
        self.last_caption = 0.0; self.caption_dirty = False; self.tokens = 0
        self.gate = NoiseGate(agent.np, floor=getattr(agent, 'live_threshold', 0.00225))

    def capture(self, indata, frames, time_info, status):
        if self.s.stop.is_set() or self.worker_stop.is_set(): return
        try: self.audio.put_nowait(indata.mean(axis=1).copy())
        except queue.Full: self.errors.put('Ses bağlantısı yetişemedi; görüşmeyi devralabilirsiniz.')

    def receive(self, connection, stop):
        try:
            while not stop.is_set():
                message = connection.recv()
                if message is not None: self.events.put(message, timeout=1)
        except Exception as e:
            if not stop.is_set():
                diagnose(f'Gemini alımı durdu: {type(e).__name__}: {e}')
                self.errors.put('Gemini Live bağlantısı kesildi.')

    def open_session(self, resume=False):
        text = self.instructions + '\nİlk karşılama: ' + self.greeting
        if resume and not self.handle:
            history = '\n'.join(self.transcript.lines()[-12:])[-1500:]
            text += ('\n\nBAĞLANTI YENİLENDİ: Görüşme zaten sürüyor. Karşılamayı TEKRAR ETME; kaldığın yerden devam et.\n'
                     'Şimdiye kadarki konuşma:\n' + (history or '(henüz konuşma yok)'))
        self.connection = self.factory(self.key)
        self.connection.send(setup_message(text, self.model, self.voice, self.handle if resume else None))
        if not wait_for_setup(self.connection, self.s.stop): return False
        self.worker_stop = threading.Event()
        self.reader = threading.Thread(target=self.receive, args=(self.connection, self.worker_stop), daemon=True)
        self.reader.start()
        return True

    def caller_context(self):
        info = self.agent.caller_summary(self.s.caller) if hasattr(self.agent, 'caller_summary') else ''
        return ('Arayan ekranından alınan bilgi (kimlik doğrulaması değildir): ' + (info or 'yok') +
                '. Adı biliniyorsa adını tekrar sorma; arayan kendini farklı tanıtırsa ona güven.')

    def say(self, text):
        """A user turn makes the model respond at once (and interrupts it if it is speaking)."""
        self.connection.send(dict(clientContent=dict(turns=[dict(role='user', parts=[dict(text=text)])], turnComplete=True)))

    def handle_message(self, message):
        if 'goAway' in message:
            self.go_away = True
        update = message.get('sessionResumptionUpdate')
        if isinstance(update, dict) and update.get('resumable') and update.get('newHandle'):
            self.handle = update['newHandle']
        usage = message.get('usageMetadata')
        if isinstance(usage, dict) and isinstance(usage.get('totalTokenCount'), int):
            self.tokens = max(self.tokens, usage['totalTokenCount'])
        content = message.get('serverContent')
        if not isinstance(content, dict): return
        if content.get('interrupted'):
            if self.player.busy(): self.agent.emit('interrupted', self.s.id)
            self.player.clear()
        for part in (content.get('modelTurn') or {}).get('parts') or []:
            data = (part.get('inlineData') or {}).get('data') if isinstance(part, dict) else None
            if data:
                self.player.push(data)
                if not self.first_output and self.greeting_sent_at is not None:
                    self.first_output = True
                    self.agent.emit('live_status', self.s.id, text=f'İlk konuşma sesi geldi: {time.monotonic() - self.greeting_sent_at:.2f} sn')
        heard = (content.get('inputTranscription') or {}).get('text')
        if isinstance(heard, str) and self.transcript.add('Arayan', heard):
            self.caption_dirty = True; self.last_input = time.monotonic(); self.ending = False
        spoken = (content.get('outputTranscription') or {}).get('text')
        if isinstance(spoken, str) and self.transcript.add('Asistan', spoken):
            self.caption_dirty = True; self.detect_farewell()

    def detect_farewell(self):
        """End after the audio once the caller and the assistant have both said goodbye."""
        rows = self.transcript.rows
        if self.ending or not rows or rows[-1]['speaker'] != 'Asistan': return
        if not any(f in lower_tr(rows[-1]['text'])[-200:] for f in FAREWELLS): return
        caller = next((lower_tr(r['text'])[-200:] for r in reversed(rows) if r['speaker'] == 'Arayan'), '')
        if any(f in caller for f in FAREWELLS):
            self.ending = True; self.end_requested = time.monotonic()
            self.agent.emit('live_status', self.s.id, text='Karşılıklı vedalaşma algılandı; görüşme kapanıyor.')

    def captions(self):
        with self.s.lock: self.s.transcript = self.transcript.lines()
        self.agent.emit('live_transcript', self.s.id, rows=self.transcript.public())
        self.agent._checkpoint(self.s)
        self.caption_dirty = False; self.last_caption = time.monotonic()

    def deliver_notes(self):
        if self.player.busy(): return  # a user turn would cut the assistant off mid-sentence
        with self.s.lock: notes = [n for n in self.s.notes if n['status'] == 'bekliyor']
        for n in notes:
            self.say('TELEFON SAHİBİNDEN YENİ TALİMAT (şimdi uygula, arayana Türkçe aktar; "not aldım" deme): ' + n['text'])
            with self.s.lock: n['status'] = 'iletildi; duyulması doğrulanmadı'
            self.agent.emit('note_status', self.s.id, note_id=n['id'], text=n['text'], status=n['status'])
            self.agent._checkpoint(self.s)

    def reconnect(self, attempt):
        self.worker_stop.set()
        try: self.connection.close()
        except Exception: pass
        self.player.clear()
        for q in (self.events, self.errors):
            while True:
                try: q.get_nowait()
                except queue.Empty: break
        self.go_away = False
        self.agent.emit('live_notice', self.s.id, text=f'Gemini bağlantısı yenileniyor ({attempt}/{self.RECONNECT_LIMIT})…')
        try:
            if not self.open_session(resume=True): return False
        except LiveError as e:
            diagnose(f'Gemini yeniden bağlanma başarısız: {e}'); return False
        self.agent.emit('live_notice', self.s.id, text='Gemini yeniden bağlandı; görüşme devam ediyor.')
        return True

    def run(self):
        sd = self.agent.sd
        if not self.open_session(): return
        inp = sd.InputStream(device=self.agent.in_idx, channels=2, samplerate=INPUT_RATE, blocksize=480, dtype='float32', callback=self.capture)
        out = sd.OutputStream(device=self.agent.out_idx, channels=2, samplerate=OUTPUT_RATE, blocksize=720, dtype='float32', callback=self.player.callback)
        self.streams += [inp, out]
        inp.start(); out.start()
        self.greeting_sent_at = time.monotonic()
        self.say(self.caller_context() + '\nTelefon araması bağlandı. Arayanın konuşmasını bekleme; hemen Türkçe olarak şu karşılamayı söyle: '
                 + self.greeting + ' Sonra sus ve dinle.')
        self.agent.emit('live_status', self.s.id, text='Karşılama istendi (' + self.model + ').')
        attempt = 0
        while True:
            try:
                self.converse(); return
            except LiveError:
                if self.s.stop.is_set() or attempt >= self.RECONNECT_LIMIT: raise
                attempt += 1
                if not self.reconnect(attempt): raise

    def converse(self):
        np = self.agent.np; started = time.monotonic()
        while not self.agent._expired(self.s, started):
            if not self.errors.empty(): raise LiveError(self.errors.get())
            if self.go_away: raise LiveError('Gemini bağlantı süresi doldu.')
            try:
                frame = self.audio.get(timeout=0.02)
                rms = float(np.sqrt(np.mean(frame * frame)))
                for piece in self.gate.process(frame, rms)[0]:
                    pcm = (np.clip(piece, -1, 1) * 32767).astype('<i2').tobytes()
                    self.connection.send(dict(realtimeInput=dict(audio=dict(data=base64.b64encode(pcm).decode('ascii'),
                                                                            mimeType=f'audio/pcm;rate={INPUT_RATE}'))), drop_on_timeout=True)
            except queue.Empty:
                pass
            for _ in range(64):
                try: message = self.events.get_nowait()
                except queue.Empty: break
                self.handle_message(message)
            if self.s.stop.is_set(): break
            if self.caption_dirty and time.monotonic() - self.last_caption > 0.35: self.captions()
            self.deliver_notes()
            if time.monotonic() - max(started, self.last_input, self.player.last_audio) > 45:
                self.s.reason = 'silence'; self.s.stop.set()
            if self.ending and not self.player.busy() and time.monotonic() - max(self.end_requested, self.player.last_audio) > 2.5:
                self.s.reason = 'completed'; self.s.stop.set()

    def close(self):
        self.player.clear(stop=True)
        for stream in reversed(self.streams):
            try: stream.stop()
            except Exception: pass
            try: stream.close()
            except Exception: pass
        self.streams = []
        self.worker_stop.set()
        if self.connection is not None: self.connection.close()
        if self.tokens: self.agent.emit('live_status', self.s.id, text=f'Gemini kullanımı: {self.tokens} token')
        self.captions()
