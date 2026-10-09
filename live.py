"""GPT-Live transport and call loop. No local speech-model imports.
Official protocol: developers.openai.com/api/docs/guides/voice-websockets.
The caller audio uses the existing Loopback devices; connections exist only in calls.
"""
from __future__ import annotations
import base64
import json
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
    if mode not in ('local', 'gpt-live'):
        raise ValueError('Ses modu geçersiz. Model ayarlarını yeniden kaydedin.')
    return mode


def require_live_key(values):
    if voice_mode(values) == 'gpt-live' and not values.get('OPENAI_API_KEY', '').strip():
        raise LiveError('GPT-Live için OpenAI API anahtarı girin.')


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


class LiveConnection:
    def __init__(self, key, timeout=8, factory=None):
        import certifi
        import websocket
        self.timeout_error = websocket.WebSocketTimeoutException
        self.closed = False
        self.ws = None
        try:
            # This native client is not a browser. Match the official SDK: no Origin.
            self.ws = (factory or websocket.create_connection)(ENDPOINT, timeout=timeout,
                header={'Authorization': 'Bearer ' + key}, redirect_limit=0, suppress_origin=True,
                enable_multithread=True, sslopt={'ca_certs': certifi.where()})
            # websocket-client can return a 3xx handshake when redirects are disabled.
            if self.ws.getstatus() != 101:
                raise LiveError('GPT-Live bağlantısı yönlendirildi veya kabul edilmedi.')
            self.ws.settimeout(0.5)
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
        """The socket timeout (0.5 s) also bounds send. A short network stall must not end
        the call: control messages are retried for ~1.5 s, audio frames are simply dropped."""
        event_id = event_id or 'beta_' + uuid.uuid4().hex
        payload = json.dumps(dict(type=kind, event_id=event_id, **fields), ensure_ascii=False)
        for attempt in range(3):
            try:
                self.ws.send(payload)
                return event_id
            except self.timeout_error:
                if drop_on_timeout: return None
                if attempt == 2: diagnose(f'{kind} gönderimi 3 denemede zaman aşımına uğradı')
                else: time.sleep(0.05)
            except Exception as e:
                diagnose(f'{kind} gönderilemedi: {type(e).__name__}: {e}')
                break
        raise LiveError('GPT-Live bağlantısına veri gönderilemedi.')

    def recv(self):
        try:
            raw = self.ws.recv()
            if not raw: raise LiveError('GPT-Live bağlantısı kapandı.')
            event = json.loads(raw)
            if not isinstance(event, dict): raise ValueError()
            return event
        except self.timeout_error:
            return None
        except LiveError:
            raise
        except Exception as e:
            diagnose(f'okuma hatası: {type(e).__name__}: {e}')
            raise LiveError('GPT-Live bağlantısı kesildi veya yanıt okunamadı.') from None

    def close(self):
        self.closed = True
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
        self.fragments.append(dict(speaker=speaker, delta=delta, start_ms=start, end_ms=end))
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


class PCMPlayer:
    """One stream owner closes audio. Callbacks only read a bounded PCM queue."""
    def __init__(self, np, rate=RATE):
        self.np = np
        self.rate = rate
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
            if self.samples+len(x) > self.rate*3:
                raise LiveError('GPT-Live ses aktarımı yetişemedi; eski ses oynatılmadı.')
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


def prompt(system):
    # Adapt the text workflow's two assumptions; never speak the control marker.
    system=system.replace('Karşılama cümlesini zaten söyledin (yapay zeka asistanı olduğunu ve not aldığını belirttin).','Karşılamada yapay zeka asistanı olduğunu belirt.')
    system=system.replace('ve cevabının EN SONUNA [BITTI] yaz.','ve kapanışı arka plan modeline danış.').replace('sonuna [BITTI] yaz.','kapanışı arka plan modeline danış.')
    return system + '''
Türkçe konuş. Teknik kontrol işaretlerini ve [BITTI] ifadesini asla seslendirme.
Backchannel policy: Kısa dinleme tepkilerini seyrek kullan.
Interruption policy: Arayan sözünü kesince sus ve dinle.
Delegation policy:
Backend tools: Arayanın mesajını ve kullanıcı talimatlarını değerlendiren arka plan modeli; dış işlem yapmaz.
Delegate to the backend when: Ayrıntılı bir yanıt, kullanıcı notlarının yorumu veya vedalaşma/kapanış gerekiyor.
Do not delegate to the backend when: Selamlaşma veya kısa bir açıklayıcı soru yeterli.
Arka plan sonucu olmadan işlem yapıldığını, randevu veya dönüş sözü verildiğini iddia etme.
'''


class LiveCall:
    def __init__(self, agent, session, system, greeting, factory=LiveConnection):
        self.agent=agent; self.s=session; self.system=system; self.greeting=greeting
        self.factory=factory; self.connection=None; self.player=PCMPlayer(agent.np)
        self.events=queue.Queue(maxsize=1024); self.audio=queue.Queue(maxsize=25)
        self.errors=queue.Queue(); self.results=queue.Queue()
        self.worker_stop=threading.Event(); self.transcript=Transcript()
        self.delegations=set(); self.pending=deque(); self.backend=None
        self.streams=[]; self.finalized=False; self.seconds=0
        self.ending=False; self.end_requested=0.0; self.last_input=0.0
        self.ending_spoken=False; self.input_revision=0;self.ending_text=""
        self.last_caption=0.0; self.caption_dirty=False
        self.greeting_id=None; self.greeting_sent_at=None; self.greeting_ack=False
        self.first_output=False; self.greeting_warning=False
        self.output_text_seen=False; self.greeting_fallback=False; self.caller_audio_seen=False

    def capture(self,indata,frames,time_info,status):
        if self.s.stop.is_set() or self.worker_stop.is_set(): return
        try:
            self.audio.put_nowait(indata.mean(axis=1).copy())
        except queue.Full:
            self.errors.put('Ses bağlantısı yetişemedi; görüşmeyi devralabilirsiniz.')

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
        elif kind in ('session.input_transcript.delta','session.output_transcript.delta'):
            if self.transcript.add(event): self.caption_dirty=True
            if kind=='session.output_transcript.delta' and event.get('delta','').strip(): self.output_text_seen=True
            if kind=='session.input_transcript.delta':
                self.last_input=time.monotonic(); self.ending=False;self.input_revision+=1
            elif self.ending:
                self.ending_text+=event.get('delta','')
                if any(x in self.ending_text.lower() for x in ('hoşça','hoşçakal','iyi günler','görüşmek','güle güle')):
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

    def ensure_greeting(self):
        if self.s.stop.is_set() or self.greeting_sent_at is None: return
        elapsed=time.monotonic()-self.greeting_sent_at
        # Accepted instructions may still leave Live waiting. One speakable cue,
        # only while both sides remain silent; never repeat or interrupt a caller.
        if elapsed>2 and self.greeting_ack and not self.greeting_fallback and not self.first_output and not self.output_text_seen and self.input_revision==0 and not self.caller_audio_seen:
            self.greeting_fallback=True
            for chunk in context_chunks(self.greeting):
                self.connection.send('session.commentary.append',delegation_id=None,content=chunk)
            self.agent.emit('live_status',self.s.id,text='Sessiz başlangıçta karşılama için tek seslendirme hatırlatması gönderildi.')
        if elapsed>8 and not self.greeting_warning and not self.first_output:
            self.greeting_warning=True
            self.agent.emit('live_status',self.s.id,text='Karşılama sesi gecikti; talimat kabulü: '+('evet' if self.greeting_ack else 'bekleniyor'))

    def deliver_notes(self):
        with self.s.lock: notes=[n.copy() for n in self.s.notes if n['status']=='bekliyor']
        for n in notes:
            for chunk in context_chunks('Telefon sahibinin arayana iletmeni istediği not: '+n['text']):
                self.connection.send('session.commentary.append',delegation_id=None,content=chunk)
            with self.s.lock:
                for existing in self.s.notes:
                    if existing['id']==n['id']: existing['status']='modele iletildi; duyulması doğrulanmadı'
            self.agent.emit('note_status',self.s.id,note_id=n['id'],text=n['text'],status='modele iletildi; duyulması doğrulanmadı')
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
                           'Şimdiye kadarki konuşma:\n'+(history or '(henüz konuşma yok)'))
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

    def start_reader(self):
        self.worker_stop=threading.Event()
        reader=threading.Thread(target=self.receive,daemon=True);self.reader=reader;reader.start()

    def reconnect(self,attempt):
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
        self.player.clear()
        self.greeting_sent_at=None; self.greeting_id=None
        self.agent.emit('live_notice',self.s.id,text=f'GPT-Live bağlantısı koptu; yeniden bağlanılıyor ({attempt}/{self.RECONNECT_LIMIT})…')
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
                if not self.reconnect(attempt): raise reason from None

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
                pcm=(np.clip(frame,-1,1)*32767).astype('<i2').tobytes()
                self.connection.send('session.input_audio.append',audio=base64.b64encode(pcm).decode('ascii'),drop_on_timeout=True)
                rms=float(np.sqrt(np.mean(frame*frame)))
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
