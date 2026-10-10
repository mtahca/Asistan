"""GPT-Live transport and call loop. No local speech-model imports.
Official protocol: developers.openai.com/api/docs/guides/voice-websockets.
The caller audio uses the existing Loopback devices; connections exist only in calls.
"""
from __future__ import annotations
import base64
import json
import os
from pathlib import Path
import queue
import sys
import threading
import time
import uuid
from collections import deque

# Bundled pure-Python dependency, including its license. No pip update is needed.
sys.path.insert(0, str(Path(__file__).resolve().parent / 'vendor'))

RATE = 24000
MODEL = 'gpt-live-1'
ENDPOINT = 'wss://api.openai.com/v1/live/sessions'


class LiveError(RuntimeError):
    """Only application-authored, credential-free messages reach the UI."""


# Official GPT-Live built-in names; keep Swift UI catalog in sync.
LIVE_VOICES = ('marin', 'cedar', 'alloy', 'ash', 'ballad', 'beacon', 'bossa', 'brise', 'cinder', 'coral', 'delta', 'echo', 'flitz', 'gleam', 'harema', 'juni', 'meridian', 'nira', 'noeul', 'nuri', 'quartz', 'ripple', 'sage', 'shida', 'shimmer', 'sillage', 'stone', 'tempo', 'verse', 'vesper', 'willow')

def voice_name(values):
    voice = values.get('GPT_LIVE_VOICE') or 'marin'
    if voice not in LIVE_VOICES:
        raise ValueError('GPT-Live sesi geçersiz. Ayarlardan desteklenen bir ses seçin.')
    return voice


def voice_mode(values):
    mode = values.get('VOICE_MODE', '').strip() or 'local'
    if mode not in ('local', 'gpt-live', 'gemini-live'):
        raise ValueError('Ses modu geçersiz. Model ayarlarını yeniden kaydedin.')
    return mode


def require_live_key(values):
    if voice_mode(values) == 'gpt-live' and not values.get('OPENAI_API_KEY', '').strip():
        raise LiveError('GPT-Live için OpenAI API anahtarı girin.')


def lower_tr(text):
    """str.lower() turns "İ" into "i" plus a combining dot, so "İyi günler" would not match."""
    return text.replace('İ', 'i').replace('I', 'ı').lower()


def context_chunks(text, max_bytes=450):
    # Every byte is an upper bound on tokens; keep each append below 500 tokens.
    current=''
    for ch in text:
        if len((current+ch).encode('utf-8'))>max_bytes:
            yield current;current=''
        current+=ch
    if current:yield current


def session_config(instructions, voice="marin"):
    return dict(model=MODEL, store=False, instructions=instructions,
                audio=dict(format=dict(type='audio/pcm', rate=RATE), output=dict(voice=voice_name({'GPT_LIVE_VOICE':voice}))),
                delegation=dict(type='client'))


def diagnose(text):
    """Technical detail for app.log only; never shown to the caller or the UI."""
    print(time.strftime('[%H:%M:%S] ')+'GPT-Live tanı: '+str(text)[:300], file=sys.stderr, flush=True)


# One timeout bounds both send and recv on the socket. 0.5 s used to cut sends short during a
# brief Wi-Fi stall, leaving half a WebSocket/TLS frame on the wire; the server then dropped the
# link ("Connection to remote host was lost") about every 18 s. A stall this long means the link is gone.
SOCKET_TIMEOUT_S = 5
# The first greeting audio often takes ~2.5 s; a spoken cue sent before then starts a second, overlapping reply.
GREETING_FALLBACK_S = 4


def put_latest(q, item):
    """Audio callbacks must never block or fail the call: drop the oldest frame when full."""
    try: q.put_nowait(item)
    except queue.Full:
        try: q.get_nowait()
        except queue.Empty: pass
        try: q.put_nowait(item)
        except queue.Full: pass


# The server sees an idle link as dead if nothing arrives for ~15-30 s; a WebSocket ping keeps it open.
PING_INTERVAL_S = 10


class LinkDropped(Exception):
    """Raised by SocketPump.recv/send once the link is gone; the text is for app.log only."""


class SocketPump:
    """Only this thread touches the socket. websocket-client's reader and sender used to share
    one TLS socket from two threads; OpenSSL objects are not safe for that and the corrupted
    records dropped the call every 18-30 s. Callers queue sends and read received messages."""

    def __init__(self, ws, label):
        import select
        import socket
        import websocket
        self.ws, self.label, self.select = ws, label, select.select
        self.abnf, self.timeout_error = websocket.ABNF, websocket.WebSocketTimeoutException
        self.inbox, self.outbox = queue.Queue(), queue.Queue()
        self.wake_r, self.wake_w = socket.socketpair()
        self.wake_r.setblocking(False); self.wake_w.setblocking(False)
        self.stopped = threading.Event(); self.error = None
        now = time.monotonic()
        self.last_recv = self.last_send = self.last_pong = self.last_ping = now
        self.thread = threading.Thread(target=self.run, name=label + ' soket', daemon=True); self.thread.start()

    def _wake(self):
        try: self.wake_w.send(b'x')
        except OSError: pass

    def send(self, payload):
        """Blocks until this thread has written the whole frame; never retried or cut short."""
        if self.error: raise LinkDropped(self.error)
        done = [threading.Event(), None]
        self.outbox.put((payload, done)); self._wake()
        while not done[0].wait(0.5):
            if self.error or self.stopped.is_set(): break
        if done[0].is_set() and done[1] is None: return
        raise LinkDropped(done[1] or self.error or 'kapatıldı')

    def recv(self, timeout):
        """A received message, None after timeout, or LinkDropped once the link is gone."""
        try: item = self.inbox.get(timeout=timeout)
        except queue.Empty: return None
        if item is None:
            self.inbox.put(None)  # every later recv sees the drop too
            raise LinkDropped(self.error or 'kapatıldı')
        return item

    def close(self):
        self.stopped.set(); self._wake()
        if threading.current_thread() is not self.thread: self.thread.join(timeout=2)
        for s in (self.wake_r, self.wake_w):
            try: s.close()
            except OSError: pass

    def _ages(self):
        now = time.monotonic()
        return (f'son alım {now-self.last_recv:.1f} sn, son gönderim {now-self.last_send:.1f} sn, '
                f'son pong {now-self.last_pong:.1f} sn önce')

    def _fail(self, reason):
        if not self.stopped.is_set():
            self.error = reason
            diagnose(f'{self.label} bağlantısı koptu: {reason}; {self._ages()}')
        self.inbox.put(None)
        while True:
            try: _, done = self.outbox.get_nowait()
            except queue.Empty: break
            done[1] = reason; done[0].set()

    def _flush(self):
        while not self.stopped.is_set():
            try: payload, done = self.outbox.get_nowait()
            except queue.Empty: return
            try: self.ws.send(payload)
            except Exception as e:
                done[1] = f'gönderim: {type(e).__name__}: {e}'; done[0].set(); raise
            self.last_send = time.monotonic(); done[0].set()

    def _read(self):
        opcode, frame = self.ws.recv_data_frame(True)
        self.last_recv = time.monotonic()
        if opcode == self.abnf.OPCODE_TEXT:
            data = frame.data if hasattr(frame, 'data') else frame
            self.inbox.put(data.decode('utf-8') if isinstance(data, bytes) else data)
        elif opcode == self.abnf.OPCODE_BINARY:
            self.inbox.put(frame.data if hasattr(frame, 'data') else frame)
        elif opcode == self.abnf.OPCODE_PONG:
            self.last_pong = self.last_recv
        elif opcode == self.abnf.OPCODE_CLOSE:
            data = frame.data or b''
            code = int.from_bytes(data[:2], 'big') if len(data) >= 2 else None
            reason = data[2:].decode('utf-8', 'replace')[:120]
            raise LinkDropped(f'sunucu kapattı: kod={code} neden={reason or "-"}')

    def _pending(self):
        sock = self.ws.sock
        try: return bool(sock.pending())
        except Exception: return False

    def run(self):
        missed_pong_logged = False
        try:
            while not self.stopped.is_set():
                self._flush()
                now = time.monotonic()
                if now - self.last_ping >= PING_INTERVAL_S:
                    if self.last_pong < self.last_ping and not missed_pong_logged:
                        diagnose(f'{self.label}: {now-self.last_ping:.1f} sn içinde pong gelmedi; {self._ages()}')
                        missed_pong_logged = True
                    elif self.last_pong >= self.last_ping:
                        missed_pong_logged = False
                    self.ws.ping(); self.last_ping = now
                if self._pending(): readable = [self.ws.sock]
                else:
                    wait = max(0.0, self.last_ping + PING_INTERVAL_S - time.monotonic())
                    readable, _, _ = self.select([self.ws.sock, self.wake_r], [], [], wait)
                if self.wake_r in readable:
                    try:
                        while self.wake_r.recv(4096): pass
                    except (BlockingIOError, OSError): pass
                if self.stopped.is_set(): break
                if self.ws.sock in readable:
                    try: self._read()
                    except self.timeout_error: pass  # a partial frame; the rest is buffered for the next read
        except LinkDropped as e:
            self._fail(str(e))
        except Exception as e:
            self._fail(f'{type(e).__name__}: {e}')
        else:
            self._fail('kapatıldı')


class LiveConnection:
    def __init__(self, key, timeout=8, factory=None):
        import certifi
        import websocket
        self.timeout_error = websocket.WebSocketTimeoutException
        self.closed = False
        self.ws = self.pump = None
        try:
            # This native client is not a browser. Match the official SDK: no Origin.
            self.ws = (factory or websocket.create_connection)(ENDPOINT, timeout=timeout,
                header={'Authorization': 'Bearer ' + key}, redirect_limit=0, suppress_origin=True,
                enable_multithread=True, sslopt={'ca_certs': certifi.where()})
            # websocket-client can return a 3xx handshake when redirects are disabled.
            if self.ws.getstatus() != 101:
                raise LiveError('GPT-Live bağlantısı yönlendirildi veya kabul edilmedi.')
            self.ws.settimeout(SOCKET_TIMEOUT_S)
            # Test doubles have no socket; they keep the direct calls.
            self.pump = SocketPump(self.ws, 'GPT-Live') if getattr(self.ws, 'sock', None) is not None else None
        except Exception as e:
            self.close()
            code = getattr(e, 'status_code', None)
            if code == 401: message = 'OpenAI anahtarı kabul edilmedi.'
            elif code in (403,404): message = 'Hesabın GPT-Live 1 erişimi yok.'
            elif code == 429: message = 'GPT-Live kota veya hız sınırı. Hesap kullanımını kontrol edin.'
            elif isinstance(e, LiveError): message = str(e)
            else: message = 'GPT-Live bağlantısı kurulamadı. İnternet ve hesap erişimini kontrol edin.'
            raise LiveError(message) from None

    def send(self, kind, *, event_id=None, drop_on_timeout=False, **fields):
        """A send is never retried or abandoned midway: see SOCKET_TIMEOUT_S. drop_on_timeout is
        kept for callers; stale caller audio is dropped from the capture queue instead."""
        event_id = event_id or 'beta_' + uuid.uuid4().hex
        payload = json.dumps(dict(type=kind, event_id=event_id, **fields), ensure_ascii=False)
        try:
            if self.pump: self.pump.send(payload)
            else: self.ws.send(payload)
            return event_id
        except LinkDropped as e:
            diagnose(f'{kind} gönderilemedi: {e}')
        except Exception as e:
            diagnose(f'{kind} gönderilemedi: {type(e).__name__}: {e}')
        raise LiveError('GPT-Live bağlantısına veri gönderilemedi.')

    def recv(self):
        try:
            if self.pump:
                raw = self.pump.recv(SOCKET_TIMEOUT_S)
                if raw is None: return None
            else: raw = self.ws.recv()
            if not raw: raise LiveError('GPT-Live bağlantısı kapandı.')
            event = json.loads(raw)
            if not isinstance(event, dict): raise ValueError()
            return event
        except self.timeout_error:
            return None
        except LiveError:
            raise
        except LinkDropped:
            raise LiveError('GPT-Live bağlantısı kesildi veya yanıt okunamadı.') from None
        except Exception as e:
            diagnose(f'okuma hatası: {type(e).__name__}: {e}')
            raise LiveError('GPT-Live bağlantısı kesildi veya yanıt okunamadı.') from None

    def close(self):
        self.closed = True
        if self.pump is not None: self.pump.close()
        if self.ws is not None:
            try: self.ws.shutdown()
            except Exception: pass


def event_error(event):
    error = event.get('error') or {}
    code = error.get('code')
    diagnose(f"sunucu hatası: code={code} type={error.get('type')} message={error.get('message')}")
    if code in ('insufficient_quota', 'rate_limit_exceeded'):
        return LiveError('GPT-Live kota veya hız sınırı. Hesap kullanımını kontrol edin.')
    return LiveError('GPT-Live komutu kabul edilmedi veya oturum sürdürülemedi. Bağlantıyı yeniden sınayın.')


def check_access(key, factory=LiveConnection, voice="marin"):
    """No device capture, greeting, contacts, or conversation data in this check."""
    config = session_config('Remain silent. This is a connection test.', voice)
    connection = factory(key)
    started = finalized = False
    try:
        connection.send('session.start', session=config)
        deadline = time.monotonic() + 8
        while time.monotonic() < deadline:
            event = connection.recv()
            if event is None: continue
            if event.get('type') == 'error': raise event_error(event)
            if event.get('type') == 'session.started':
                started = True
                connection.send('session.close')
            elif event.get('type') == 'session.closed':
                finalized = True
                break
        if not started or not finalized:
            raise LiveError('GPT-Live başlangıcı veya oturum kapanışı doğrulanamadı.')
    finally:
        connection.close()


class Transcript:
    """Retain exact fragments and intervals; group each speaker independently."""
    def __init__(self):
        self.fragments = []
        self.seen = set()
        self.offset_ms = 0

    def new_session(self):
        """A resumed Live session restarts its clock at 0; keep its fragments after the old ones."""
        self.offset_ms = max((f['end_ms'] for f in self.fragments), default=self.offset_ms) + 2000

    def add(self, event):
        speaker = 'Arayan' if event['type'] == 'session.input_transcript.delta' else 'Asistan'
        delta = event.get('delta')
        if not isinstance(delta, str) or not delta: return False
        event_id = event.get('event_id')
        if event_id and event_id in self.seen: return False
        if event_id: self.seen.add(event_id)
        start, end = event.get('start_ms'), event.get('end_ms')
        if not isinstance(start, (int,float)) or not isinstance(end, (int,float)) or start < 0 or end < start:
            raise LiveError('GPT-Live döküm zamanları okunamadı.')
        self.fragments.append(dict(speaker=speaker, delta=delta, start_ms=start+self.offset_ms, end_ms=end+self.offset_ms))
        return True

    def rows(self):
        rows = []
        for speaker in ('Arayan','Asistan'):
            pieces = sorted((f for f in self.fragments if f['speaker'] == speaker), key=lambda f:f['start_ms'])
            group = None
            for f in pieces:
                if group is None or f['start_ms'] - group['end_ms'] > 1200:
                    group = dict(speaker=speaker,text='',start_ms=f['start_ms'],end_ms=f['end_ms'])
                    rows.append(group)
                group['text'] += f['delta']
                group['end_ms'] = max(group['end_ms'],f['end_ms'])
        return sorted(rows,key=lambda r:(r['start_ms'],r['speaker']))


class NoiseGate:
    """Passes caller audio to Live only while it rises clearly above the background level.
    Closed frames become silence so the stream stays continuous. The background estimate is a
    low percentile of the last ~3 s, so speech pauses keep it low while steady road noise
    becomes background within seconds. Pre-roll keeps word onsets; hangover keeps word ends."""
    def __init__(self, np, floor=0.00225, ratio=3.0, hang_frames=25, pre_frames=8, window=100):
        self.np=np; self.floor=floor; self.ratio=ratio; self.hang=hang_frames
        self.pre=deque(maxlen=pre_frames); self.recent=deque(maxlen=window); self.open=0; self.noise=floor

    def threshold(self):
        if len(self.recent)>=20:
            ordered=sorted(self.recent); self.noise=ordered[len(ordered)//10]
        return max(self.floor, self.noise*self.ratio)

    def process(self, frame, rms):
        """Returns (frames to send, speech flag)."""
        self.recent.append(rms)
        if rms>self.threshold():
            out=list(self.pre)+[frame] if self.open==0 else [frame]
            self.pre.clear(); self.open=self.hang
            return out, True
        if self.open>0:
            self.open-=1; return [frame], True
        self.pre.append(frame)
        return [self.np.zeros_like(frame)], False


class PCMPlayer:
    """One stream owner closes audio. Callbacks only read a bounded PCM queue."""
    def __init__(self, np, rate=RATE, max_seconds=120, overflow='Ses oynatma sırası taştı.'):
        self.np = np
        self.rate = rate
        self.max_seconds = max_seconds
        self.overflow = overflow
        self.lock = threading.Lock()
        self.buffers = deque()
        self.offset = 0
        self.samples = 0
        self.muted = False
        self.stopped = False
        self.last_audio = 0.0

    def push(self, encoded):
        try:
            raw = base64.b64decode(encoded,validate=True)
            if len(raw)%2: raise ValueError()
            x = self.np.frombuffer(raw,dtype='<i2').astype('float32')/32768
        except Exception:
            raise LiveError('GPT-Live ses biçimi okunamadı.') from None
        with self.lock:
            if self.stopped or self.muted: return
            if self.samples+len(x) > self.rate*self.max_seconds:
                raise LiveError(self.overflow)
            if len(x):
                self.buffers.append(x); self.samples+=len(x); self.last_audio=time.monotonic()

    def clear(self, mute=False, stop=False):
        with self.lock:
            self.buffers.clear(); self.offset=0; self.samples=0
            self.muted=mute; self.stopped=stop

    def busy(self):
        with self.lock: return self.samples > 0

    def callback(self,outdata,frames,time_info,status):
        outdata.fill(0)
        with self.lock:
            if self.stopped or self.muted: return
            filled=0
            while filled<frames and self.buffers:
                current=self.buffers[0]; count=min(frames-filled,len(current)-self.offset)
                outdata[filled:filled+count,:]=current[self.offset:self.offset+count,None]
                filled+=count; self.offset+=count; self.samples-=count
                if self.offset==len(current): self.buffers.popleft();self.offset=0


def owner_note(text):
    """Notes the owner types during a call. "!komut" is for the assistant alone and is never
    spoken; any other note is information to use in the assistant's own words, never read out."""
    text = text.strip()
    if text.startswith('!'):
        return True, ('TELEFON SAHİBİNDEN SANA ÖZEL KOMUT (arayana asla söyleme, aktarma veya ima etme; '
                      'varsayılan kurallardan önce gelir; uygun ilk anda ve bundan sonra uygula. Komut bir şey söylemeni '
                      'istiyorsa bunu kendi cümlenle söyle ama komuttan bahsetme): ' + text[1:].strip())
    return False, ('TELEFON SAHİBİNDEN BİLGİ: ' + text + ' — Bunu arayana birebir okuma ve "size şunu iletmemi istedi" deme. '
                   'Anlamını kavra; telefon sahibinin asistanı olarak kendi cümlenle, konuşmanın akışına ve arayanın sorularına '
                   'uygun biçimde kullan. Örneğin "yarın 10\'da müsait olacağım" notu, "Yarın saat onda müsait olacak, '
                   'o saatte görüşmek size uyar mı?" gibi bir yanıt demektir. Şu an konuşmayla ilgiliyse tek kısa cümleyle doğal '
                   'biçimde belirt; değilse arayan ilgili bir şey sorduğunda kullan.')


def owner_context(session):
    """Notes already given in this call, for a replaced Live session that never saw them."""
    with session.lock: texts=[n['text'] for n in session.notes if n['status']!='bekliyor']
    if not texts: return ''
    return '\n\nBU GÖRÜŞMEDE TELEFON SAHİBİNDEN DAHA ÖNCE GELENLER (hâlâ geçerli):' + ''.join('\n'+owner_note(t)[1] for t in texts)


def remember_command(session, instruction):
    """The background model (delegation, bilgi_al) reads "!" commands from the session."""
    commands=getattr(session,'owner_commands',None)
    if commands is not None:
        with session.lock: commands.append(instruction)


def override_reminder(system):
    """Live models weigh the last lines most; restate that the owner's wishes win over the fixed rules."""
    if 'ÖNCELİK KURALI' not in system: return ''
    return ('SON HATIRLATMA: Telefon sahibinin talimatları ve görüşme sırasındaki komutları, bu metindeki bütün '
            'varsayılan kurallardan (kısa konuşma, yalnızca mesaj alma, hitap, kişisel bilgi, kapanış) önce gelir.\n')


def prompt(system):
    # Adapt the text workflow's two assumptions; never speak the control marker.
    system=system.replace('Karşılama cümlesini zaten söyledin (yapay zeka asistanı olduğunu ve not aldığını belirttin).','Karşılamada yapay zeka asistanı olduğunu belirt.')
    system=system.replace('ve cevabının EN SONUNA [BITTI] yaz.','ve kapanışı arka plan modeline danış.').replace('sonuna [BITTI] yaz.','kapanışı arka plan modeline danış.')
    return system + '''
Türkçe konuş. Teknik kontrol işaretlerini ve [BITTI] ifadesini asla seslendirme.
Gürültü kuralı: Arka plan gürültüsü, anlaşılmaz mırıltı veya anlamsız kısa parçalar duyarsan bunlara yanıt verme ve bir şey uydurma; arayan net bir şey söylemediyse sessiz kal. Yalnızca gerçekten anlaşılmaz bir cümle duyduğunda bir kez "Sizi tam duyamadım, tekrar eder misiniz?" de.
Backchannel policy: Kısa dinleme tepkilerini seyrek kullan.
Interruption policy: Arayan sözünü kesince sus ve dinle.
Delegation policy:
Backend tools: Arayanın mesajını ve kullanıcı talimatlarını değerlendiren arka plan modeli; dış işlem yapmaz.
Delegate to the backend when: Ayrıntılı bir yanıt, emin olmadığın bir genel bilgi sorusu (mesafe, tarih, hesap gibi), kullanıcı notlarının yorumu veya vedalaşma/kapanış gerekiyor.
Do not delegate to the backend when: Selamlaşma veya kısa bir açıklayıcı soru yeterli.
Arka plan sonucu olmadan işlem yapıldığını, randevu veya dönüş sözü verildiğini iddia etme.
''' + override_reminder(system)


def prewarm_connection(key, system, voice='marin', factory=LiveConnection, timeout=12):
    """Open a Live session before the phone call is confirmed, with a caller-agnostic prompt.
    Caller details and the greeting are appended once the call connects."""
    connection=factory(key)
    connection.send('session.start',session=session_config(prompt(system)+'\nArayan bilgisi ve karşılama bağlantı kurulunca ayrıca bildirilecek.', voice))
    deadline=time.monotonic()+timeout
    while time.monotonic()<deadline:
        event=connection.recv()
        if event is None: continue
        if event.get('type')=='error': connection.close(); raise event_error(event)
        if event.get('type')=='session.started': return connection
    connection.close()
    raise LiveError('GPT-Live hazırlanırken zaman aşımı.')


class LiveCall:
    def __init__(self, agent, session, system, greeting, factory=LiveConnection, prewarmed=None):
        self.agent=agent; self.s=session; self.system=system; self.greeting=greeting; self.prewarmed=prewarmed
        self.factory=factory; self.connection=None; self.player=PCMPlayer(agent.np)
        self.events=queue.Queue(maxsize=1024); self.audio=queue.Queue(maxsize=25)
        self.errors=queue.Queue(); self.results=queue.Queue()
        self.worker_stop=threading.Event(); self.transcript=Transcript()
        self.delegations=set(); self.pending=deque(); self.backend=None
        self.streams=[]; self.finalized=False; self.seconds=0
        self.ending=False; self.end_requested=0.0; self.last_input=0.0
        self.ending_spoken=False; self.input_revision=0;self.ending_text=""
        self.last_caption=0.0; self.caption_dirty=False
        self.greeting_id=None; self.greeting_sent_at=None; self.greeting_ack=False; self.note_acks={}
        self.first_output=False; self.greeting_warning=False
        self.output_text_seen=False; self.greeting_fallback=False; self.caller_audio_seen=False
        self.gate=None if os.getenv('LIVE_NOISE_GATE','on').lower() in ('off','0','false','no') else NoiseGate(
            agent.np, floor=getattr(agent,'live_threshold',0.00225), ratio=float(os.getenv('LIVE_GATE_RATIO','3')))
        self.gated_frames=0

    def capture(self,indata,frames,time_info,status):
        if self.s.stop.is_set() or self.worker_stop.is_set(): return
        put_latest(self.audio, indata.mean(axis=1).copy())

    def receive(self):
        try:
            while not self.worker_stop.is_set():
                event=self.connection.recv()
                if event is not None: self.events.put(event,timeout=1)
        except Exception as e:
            if not self.worker_stop.is_set():
                diagnose(f'alım durdu: {type(e).__name__}: {e}')
                self.errors.put('GPT-Live bağlantısı kesildi. Görüşmeyi devralabilirsiniz.')

    def start_backend(self):
        if self.backend and self.backend.is_alive(): return
        if not self.pending: return
        did=self.pending.popleft()
        history=[dict(role='user' if r['speaker']=='Arayan' else 'assistant',content=r['text']) for r in self.transcript.rows()]
        if history and history[0]['role']=='assistant':
            history.insert(0,dict(role='user',content='Telefon araması bağlandı.'))
        # Live metadata contains no task text. Do not infer it from the delegation ID.
        if not any(m['role']=='user' for m in history):
            self.connection.send('session.thinking.append',delegation_id=did,content='Henüz anlaşılır bir arayan mesajı alınmadı. Kısa bir açıklayıcı soru sor.')
            return
        revision=self.input_revision
        def run():
            try: self.results.put((did,self.agent._live_delegate(self.s,history),None,revision))
            except Exception: self.results.put((did,None,'Arka plan modeli yanıt veremedi; bir taahhütte bulunmadan mesajı al.',revision))
        self.backend=threading.Thread(target=run,daemon=True);self.backend.start()

    def captions(self):
        rows=self.transcript.rows()
        with self.s.lock:
            self.s.live_fragments=list(self.transcript.fragments)
            self.s.transcript=[r['speaker']+': '+r['text'] for r in rows]
        self.agent.emit('live_transcript',self.s.id,rows=rows)
        self.agent._checkpoint(self.s)
        self.caption_dirty=False;self.last_caption=time.monotonic()

    def handle_event(self,event):
        kind=event.get('type')
        if kind=='error': raise event_error(event)
        if kind=='session.output_audio.delta':
            self.player.push(event.get('delta',''))
            # Continuous Live audio also contains silence; count actual speech only.
            raw=base64.b64decode(event.get('delta',''),validate=True)
            if not self.first_output and raw and self.agent.np.abs(self.agent.np.frombuffer(raw,dtype='<i2').astype('int32')).max()>50:
                self.first_output=True
                elapsed=time.monotonic()-self.greeting_sent_at if self.greeting_sent_at is not None else 0
                self.agent.emit('live_status',self.s.id,text=f'İlk konuşma sesi geldi: {elapsed:.2f} sn')
        elif kind=='session.instructions.appended' and self.greeting_id is not None and event.get('client_event_id')==self.greeting_id:
            self.greeting_ack=True
            self.agent.emit('live_status',self.s.id,text='Karşılama talimatı kabul edildi (seslendirme doğrulaması değildir).')
        elif kind=='session.instructions.appended' and event.get('client_event_id') in self.note_acks:
            self.set_note_status(self.note_acks.pop(event.get('client_event_id')),'model kabul etti; duyulması doğrulanmadı')
        elif kind in ('session.input_transcript.delta','session.output_transcript.delta'):
            if self.transcript.add(event): self.caption_dirty=True
            if kind=='session.output_transcript.delta' and event.get('delta','').strip():
                self.output_text_seen=True; self.detect_mutual_farewell()
            if kind=='session.input_transcript.delta':
                self.last_input=time.monotonic(); self.ending=False;self.input_revision+=1
            elif self.ending:
                self.ending_text+=event.get('delta','')
                if any(x in lower_tr(self.ending_text) for x in ('hoşça','hoşçakal','iyi günler','görüşmek','güle güle')):
                    self.ending_spoken=True
        elif kind=='session.delegation.created':
            delegation=event.get('delegation') or {}
            did=delegation.get('id')
            if delegation.get('target')=='client' and isinstance(did,str) and did not in self.delegations:
                if len(self.pending)>=16: raise LiveError('GPT-Live arka plan istekleri sınırı aşıldı.')
                self.delegations.add(did);self.pending.append(did)
        elif kind in ('session.usage.updated','session.closed'):
            seconds=(event.get('usage') or {}).get('seconds')
            if isinstance(seconds,(int,float)) and seconds>=0: self.seconds=seconds
            if kind=='session.closed':
                self.finalized=True
                if not self.s.stop.is_set():
                    self.s.reason='error';self.s.stop.set()
                    self.agent.emit('error',self.s.id,text='GPT-Live oturumu sona erdi. Aramayı devralabilirsiniz.')

    FAREWELLS=('hoşça kal','hoşçakal','iyi günler','iyi akşamlar','iyi geceler','görüşmek üzere','görüşürüz','güle güle','kendine iyi bak','kendinize iyi bak','bay bay','baybay')

    def detect_mutual_farewell(self):
        """Live says goodbye itself, without the backend's [BITTI] marker. When the caller's last
        words and the assistant's current reply both contain a farewell, close after the audio."""
        if self.ending: return
        rows=self.transcript.rows()
        if not rows or rows[-1]['speaker']=='Arayan': return
        assistant=lower_tr(rows[-1]['text'])[-200:]
        if not any(f in assistant for f in self.FAREWELLS): return
        caller=next((lower_tr(r['text'])[-200:] for r in reversed(rows) if r['speaker']=='Arayan'),'')
        if not any(f in caller for f in self.FAREWELLS): return
        self.ending=True; self.ending_spoken=True; self.ending_text=''; self.end_requested=time.monotonic()
        self.agent.emit('live_status',self.s.id,text='Karşılıklı vedalaşma algılandı; görüşme kapanıyor.')

    def ensure_greeting(self):
        if self.s.stop.is_set() or self.greeting_sent_at is None: return
        elapsed=time.monotonic()-self.greeting_sent_at
        # Accepted instructions may still leave Live waiting. One speakable cue,
        # only while both sides remain silent; never repeat or interrupt a caller.
        if elapsed>GREETING_FALLBACK_S and self.greeting_ack and not self.greeting_fallback and not self.first_output and not self.output_text_seen and self.input_revision==0 and not self.caller_audio_seen:
            self.greeting_fallback=True
            for chunk in context_chunks(self.greeting):
                self.connection.send('session.commentary.append',delegation_id=None,content=chunk)
            self.agent.emit('live_status',self.s.id,text='Sessiz başlangıçta karşılama için tek seslendirme hatırlatması gönderildi.')
        if elapsed>8 and not self.greeting_warning and not self.first_output:
            self.greeting_warning=True
            self.agent.emit('live_status',self.s.id,text='Karşılama sesi gecikti; talimat kabulü: '+('evet' if self.greeting_ack else 'bekleniyor'))

    def deliver_notes(self):
        """Owner notes go in as instructions, the same channel the greeting uses and the model
        acts on; commentary is advisory and was ignored. The last chunk's ack marks the note."""
        with self.s.lock: notes=[n.copy() for n in self.s.notes if n['status']=='bekliyor']
        for n in notes:
            command,instruction=owner_note(n['text'])
            if command: remember_command(self.s,instruction)
            chunks=context_chunks(instruction)
            event_id=None
            for chunk in chunks:
                event_id='beta_note_'+uuid.uuid4().hex
                self.connection.send('session.instructions.append',event_id=event_id,delegation_id=None,content=chunk)
            self.note_acks[event_id]=n['id']
            self.set_note_status(n['id'],'komut olarak iletildi; arayana söylenmez' if command else 'bilgi olarak iletildi; duyulması doğrulanmadı')

    def set_note_status(self,note_id,status):
        text=''
        with self.s.lock:
            for existing in self.s.notes:
                if existing['id']==note_id: existing['status']=status; text=existing['text']
        self.agent.emit('note_status',self.s.id,note_id=note_id,text=text,status=status)
        self.agent._checkpoint(self.s)

    RECONNECT_LIMIT=2

    def open_session(self,resume=False):
        """Start a Live session. On resume the new session gets the conversation so far
        and is told not to greet again."""
        instructions=prompt(self.system)+'\nİlk karşılama: '+self.greeting
        if resume:
            rows=self.transcript.rows()[-12:]
            history='\n'.join(r['speaker']+': '+r['text'] for r in rows)[-1500:]
            instructions+=('\n\nBAĞLANTI YENİLENDİ: Görüşme zaten sürüyor. Karşılamayı ve kendini tanıtmayı TEKRAR ETME. '
                           'Kaldığın yerden doğal biçimde devam et; gerekiyorsa kısa bir "Pardon, bağlantı kısa süre kesildi, devam edelim." de.\n'
                           'Şimdiye kadarki konuşma:\n'+(history or '(henüz konuşma yok)'))+owner_context(self.s)
        if not resume and self.prewarmed is not None:
            self.connection, self.prewarmed = self.prewarmed, None
            # The prewarmed prompt had no caller; add what the ring showed.
            for chunk in context_chunks(self.caller_context()):
                self.connection.send('session.instructions.append',delegation_id=None,content=chunk)
            self.agent.emit('live_status',self.s.id,text='Önceden açılmış GPT-Live oturumu kullanıldı.')
            return True
        self.connection=self.factory(self.agent.live_key)
        self.connection.send('session.start',session=session_config(instructions, getattr(self.agent, 'live_voice', 'marin')))
        deadline=time.monotonic()+12
        while not self.s.stop.is_set() and time.monotonic()<deadline:
            event=self.connection.recv()
            if event is None:continue
            if event.get('type')=='error':raise event_error(event)
            if event.get('type')=='session.started':return True
        if self.s.stop.is_set():return False
        raise LiveError('GPT-Live hazırlanırken zaman aşımı.')

    def caller_context(self):
        info=self.agent.caller_summary(self.s.caller) if hasattr(self.agent,'caller_summary') else ''
        return ('Arayan ekranından alınan bilgi (kimlik doğrulaması değildir): '+(info or 'yok')+
                '. Adı biliniyorsa adını tekrar sorma; arayan kendini farklı tanıtırsa ona güven.')

    def start_reader(self):
        self.worker_stop=threading.Event()
        reader=threading.Thread(target=self.receive,daemon=True);self.reader=reader;reader.start()

    def reconnect(self,attempt,reason=''):
        """Replace a broken Live connection inside the same phone call. Audio streams stay open."""
        old_stop=self.worker_stop; old_stop.set()
        try: self.connection.close()
        except Exception: pass
        if hasattr(self,'reader'): self.reader.join(1)
        self.seconds_base=getattr(self,'seconds_base',0)+self.seconds; self.seconds=0; self.finalized=False
        for q in (self.events,self.audio,self.errors,self.results):
            while True:
                try: q.get_nowait()
                except queue.Empty: break
        self.pending.clear(); self.delegations.clear(); self.backend=None
        self.player.clear(); self.transcript.new_session()
        self.greeting_sent_at=None; self.greeting_id=None
        diagnose(f'yeniden bağlanma nedeni: {reason}')
        self.agent.emit('live_notice',self.s.id,text=f'GPT-Live bağlantısı koptu ({reason}); yeniden bağlanılıyor ({attempt}/{self.RECONNECT_LIMIT})…')
        try:
            if not self.open_session(resume=True): return False
        except LiveError as e:
            diagnose(f'yeniden bağlanma başarısız: {e}')
            return False
        self.start_reader()
        self.agent.emit('live_notice',self.s.id,text='GPT-Live yeniden bağlandı; görüşme devam ediyor.')
        return True

    def run(self):
        np=self.agent.np; sd=self.agent.sd
        if not self.open_session(): return
        # CoreAudio performs device-rate conversion. No audio or network in callbacks.
        inp=sd.InputStream(device=self.agent.in_idx,channels=2,samplerate=RATE,
            blocksize=720,dtype='float32',callback=self.capture)
        self.streams.append(inp)
        out=sd.OutputStream(device=self.agent.out_idx,channels=2,samplerate=RATE,
            blocksize=720,dtype='float32',callback=self.player.callback)
        self.streams.append(out)
        inp.start();out.start()
        self.start_reader()
        self.greeting_id='beta_greeting_'+uuid.uuid4().hex
        self.greeting_sent_at=time.monotonic()
        # A self-contained instruction avoids relying on an indirect startup reference.
        # Send once after session.started and keep input (including silence) running.
        self.connection.send('session.instructions.append',event_id=self.greeting_id,delegation_id=None,
            content='The call is connected. Speak FIRST, immediately, in Turkish; do not wait for the caller to speak. '
                    'Say this greeting now: '+self.greeting+' Then stop speaking and listen. Do not repeat the greeting.')
        self.agent.emit('live_status',self.s.id,text='Karşılama istendi; arayanın konuşması beklenmiyor.')
        attempt=0
        while True:
            try: self.converse(np); return
            except LiveError as e:
                if self.s.stop.is_set(): return
                reason=self.server_reason() or e
                if attempt>=self.RECONNECT_LIMIT: raise reason from None
                attempt+=1
                if not self.reconnect(attempt,str(reason).rstrip('.')): raise reason from None

    def server_reason(self):
        """Audio is sent every 30 ms, so a send can fail before the reader's queued
        error event is handled. Report the server's own reason when it sent one."""
        deadline=time.monotonic()+0.3
        while time.monotonic()<deadline:
            try: event=self.events.get(timeout=0.05)
            except queue.Empty: continue
            if event.get('type')=='error': return event_error(event)
            if event.get('type')=='session.closed':
                diagnose('sunucu oturumu kapattı: '+json.dumps(event.get('reason') or event.get('session') or {}, ensure_ascii=False)[:200])
                return LiveError('GPT-Live oturumu sunucu tarafından kapatıldı. Aramayı devralabilirsiniz.')
        return None

    def converse(self,np):
        started=time.monotonic();voiced=0;muted_until=0.0;interrupted=False
        while not self.agent._expired(self.s,started):
            if not self.errors.empty():raise LiveError(self.errors.get())
            try:
                frame=self.audio.get(timeout=0.02)
                rms=float(np.sqrt(np.mean(frame*frame)))
                outgoing,speech=self.gate.process(frame,rms) if self.gate else ([frame],True)
                if not speech: self.gated_frames+=1
                for piece in outgoing:
                    pcm=(np.clip(piece,-1,1)*32767).astype('<i2').tobytes()
                    self.connection.send('session.input_audio.append',audio=base64.b64encode(pcm).decode('ascii'),drop_on_timeout=True)
                voiced=voiced+1 if rms>self.agent.live_threshold else 0
                if voiced>=10:
                    self.caller_audio_seen=True
                    self.ending=False;muted_until=time.monotonic()+0.3
                    if self.player.busy() and not interrupted:self.agent.emit('interrupted',self.s.id);interrupted=True
                    self.player.clear(mute=True)
                elif time.monotonic()>muted_until:
                    with self.player.lock:self.player.muted=False
                    interrupted=False
            except queue.Empty:pass
            # Bound receive processing so audio sends and stop requests stay responsive.
            for _ in range(64):
                try:event=self.events.get_nowait()
                except queue.Empty:break
                self.handle_event(event)
            if self.s.stop.is_set():break
            self.ensure_greeting()
            if self.caption_dirty and time.monotonic()-self.last_caption>0.35:self.captions()
            self.deliver_notes();self.start_backend()
            while not self.results.empty():
                did,text,error,revision=self.results.get_nowait()
                if self.s.stop.is_set():break
                if did not in self.delegations:continue  # from a connection that was replaced
                if error:
                    self.connection.send('session.thinking.append',delegation_id=did,content=error)
                else:
                    end='[BITTI]' in text; text=text.replace('[BITTI]','').strip()
                    for chunk in context_chunks(text[:1200]):
                        self.connection.send('session.commentary.append',delegation_id=did,content=chunk)
                    if end and revision==self.input_revision:
                        self.ending=True;self.ending_spoken=False;self.ending_text="";self.end_requested=time.monotonic()
            if time.monotonic()-max(started,self.last_input,self.player.last_audio)>45 and not (self.backend and self.backend.is_alive()):
                self.s.reason='silence';self.s.stop.set()
            if self.ending and self.ending_spoken and self.player.last_audio>self.end_requested and time.monotonic()-max(self.end_requested,self.player.last_audio)>3 and not self.player.busy():
                self.s.reason='completed';self.s.stop.set()

    def close(self):
        # Release audio before Devral; only this thread stops/closes PortAudio streams.
        self.player.clear(stop=True)
        for stream in reversed(self.streams):
            try:stream.stop()
            except Exception:pass
            try:stream.close()
            except Exception:pass
        self.streams=[]
        if self.connection is not None:
            try:
                if not self.finalized:
                    self.connection.send('session.close')
                    deadline=time.monotonic()+0.7
                    while time.monotonic()<deadline and not self.finalized:
                        try:event=self.events.get(timeout=0.1)
                        except queue.Empty:continue
                        self.handle_event(event)
            except Exception:pass
            self.worker_stop.set();self.connection.close()
            if hasattr(self,'reader'):self.reader.join(0.1)
            self.agent.emit('live_usage',self.s.id,seconds=getattr(self,'seconds_base',0)+self.seconds,finalized=self.finalized)
        # A completed backend job cannot deliver into a closed session or a new call.
        self.captions()
