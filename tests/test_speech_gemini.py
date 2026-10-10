import base64
import io
import json
from pathlib import Path
import queue
import sys
import threading
from types import SimpleNamespace
import unittest
import wave
import numpy as np
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import gemini_live
import speech


class Response:
    def __init__(self, status, body):
        self.status_code = status; self.body = body
    def json(self):
        if isinstance(self.body, Exception): raise self.body
        return self.body


class Client:
    def __init__(self, response):
        self.response = response; self.requests = []
    def post(self, url, **kw):
        self.requests.append((url, kw))
        if isinstance(self.response, Exception): raise self.response
        return self.response
    def close(self): pass


class SpeechTests(unittest.TestCase):
    def test_wav_bytes_is_16k_mono_pcm(self):
        data = speech.wav_bytes(np.zeros(1600, dtype=np.float32), np)
        with wave.open(io.BytesIO(data)) as w:
            self.assertEqual((w.getnchannels(), w.getsampwidth(), w.getframerate(), w.getnframes()), (1, 2, 16000, 1600))

    def test_deepgram_sends_nova3_turkish_and_reads_transcript(self):
        body = {'results': {'channels': [{'alternatives': [{'transcript': ' Merhaba, ben Mehmet. '}]}]}}
        client = Client(Response(200, body))
        stt = speech.DeepgramSTT('private-deepgram-example-key', np, client=client)
        self.assertEqual(stt.transcribe(np.zeros(1600, dtype=np.float32)), 'Merhaba, ben Mehmet.')
        url, kw = client.requests[0]
        self.assertEqual(url, speech.DEEPGRAM_URL)
        self.assertEqual((kw['params']['model'], kw['params']['language']), ('nova-3', 'tr'))
        self.assertEqual(kw['headers']['Authorization'], 'Token private-deepgram-example-key')
        self.assertTrue(kw['content'].startswith(b'RIFF'))

    def test_deepgram_errors_are_readable_and_hide_the_key(self):
        for status, words in ((401, 'anahtarı'), (402, 'kredi'), (429, 'hız'), (500, '500')):
            stt = speech.DeepgramSTT('private-deepgram-example-key', np, client=Client(Response(status, {})))
            with self.assertRaises(speech.SpeechError) as e: stt.transcribe(np.zeros(160, dtype=np.float32))
            self.assertIn(words, str(e.exception)); self.assertNotIn('private', str(e.exception))
        stt = speech.DeepgramSTT('private-deepgram-example-key', np, client=Client(OSError('offline')))
        with self.assertRaises(speech.SpeechError): stt.transcribe(np.zeros(160, dtype=np.float32))
        stt = speech.DeepgramSTT('private-deepgram-example-key', np, client=Client(Response(200, {'results': {}})))
        with self.assertRaises(speech.SpeechError): stt.transcribe(np.zeros(160, dtype=np.float32))
        with self.assertRaises(speech.SpeechError): speech.DeepgramSTT('short', np, client=Client(None))

    def test_apple_helper_protocol(self):
        class Proc:
            def __init__(self, args, **kw):
                self.out = queue.Queue(); self.out.put(json.dumps({'ready': True}) + '\n'); self.requests = []
                proc = self
                class In:
                    def write(self, line): proc.requests.append(json.loads(line)); proc.out.put(json.dumps({'text': ' Merhaba. '}) + '\n')
                    def flush(self): pass
                    def close(self): proc.out.put(None)
                self.stdin = In(); self.stdout = iter(self.out.get, None)
            def wait(self, timeout=None): return 0
        made = []
        def popen(args, **kw):
            made.append(Proc(args, **kw)); return made[-1]
        helper = Path(__file__)  # any existing file stands in for the helper binary
        stt = speech.AppleSTT(np, path=helper, popen=popen)
        self.assertEqual(stt.transcribe(np.zeros(1600, dtype=np.float32)), 'Merhaba.')
        self.assertTrue(made[0].requests[0]['path'].endswith('.wav'))
        stt.close()

    def test_apple_helper_reports_its_startup_error(self):
        class Proc:
            def __init__(self, *a, **kw):
                self.stdout = iter([json.dumps({'error': 'Bu Mac\'te Apple Türkçe dikte modeli desteklenmiyor.'}) + '\n'])
                self.stdin = SimpleNamespace(close=lambda: None)
            def wait(self, timeout=None): return 1
        with self.assertRaises(speech.SpeechError) as e:
            speech.AppleSTT(np, path=Path(__file__), popen=Proc)
        self.assertIn('desteklenmiyor', str(e.exception))
        with self.assertRaises(speech.SpeechError):
            speech.AppleSTT(np, path=Path('/nonexistent/asistan-speech'))


class Connection:
    def __init__(self, key='dummy'):
        self.events = queue.Queue(); self.sent = []; self.closed = False
    def send(self, message, drop_on_timeout=False):
        self.sent.append(message)
        if 'setup' in message: self.events.put({'setupComplete': {}})
        return True
    def recv(self):
        try: return self.events.get(timeout=0.01)
        except queue.Empty: return None
    def close(self): self.closed = True


class GeminiTests(unittest.TestCase):
    def call(self):
        from datetime import datetime
        s = SimpleNamespace(id='call', stop=threading.Event(), lock=threading.Lock(), notes=[], transcript=[],
                            reason='completed', caller={}, started=datetime.now())
        self.emitted = []
        a = SimpleNamespace(np=np, emit=lambda *args, **kw: self.emitted.append((args, kw)), _checkpoint=lambda s: True)
        return gemini_live.GeminiCall(a, s, 'Talimat', 'Merhaba, Mehmet Bey müsait değil.', 'key', 'gemini-3.8-live', 'Kore', factory=Connection)

    def test_setup_message_per_model(self):
        new = gemini_live.setup_message('Talimat', 'gemini-3.8-live', 'Kore')['setup']
        self.assertEqual(new['model'], 'models/gemini-3.8-live')
        self.assertNotIn('thinkingConfig', new['generationConfig'])  # 3.8 rejects it
        self.assertEqual(new['generationConfig']['speechConfig']['voiceConfig']['prebuiltVoiceConfig']['voiceName'], 'Kore')
        self.assertNotIn('languageCode', new['generationConfig']['speechConfig'])
        self.assertEqual(new['inputAudioTranscription'], {'languageCodes': ['tr']})
        resumed = gemini_live.setup_message('Talimat', 'gemini-3.8-live', 'Aoede', handle='h1')['setup']
        self.assertEqual(resumed['sessionResumption'], {'handle': 'h1'})
        json.dumps(resumed)

    def test_setup_offers_the_question_tool_and_falls_back_without_it(self):
        setup = gemini_live.setup_message('Talimat', 'gemini-3.8-live', 'Kore')['setup']
        self.assertEqual(setup['tools'][0]['functionDeclarations'][0]['name'], 'bilgi_al')
        self.assertNotIn('tools', gemini_live.setup_message('T', 'gemini-3.8-live', 'Kore', tools=False)['setup'])
        made = []
        class Refusing(Connection):
            def send(self, message, drop_on_timeout=False):
                self.sent.append(message)
                if 'setup' in message and 'tools' in message['setup']: self.events.put(None)
                elif 'setup' in message: self.events.put({'setupComplete': {}})
                return True
            def recv(self):
                try: m = self.events.get(timeout=0.01)
                except queue.Empty: return None
                if m is None: raise gemini_live.LiveError('Gemini Live bağlantısı kesildi.')
                return m
        c = self.call(); c.factory = lambda key: made.append(Refusing()) or made[-1]
        import io, contextlib
        with contextlib.redirect_stderr(io.StringIO()): self.assertTrue(c.open_session())
        self.assertEqual(len(made), 2); self.assertFalse(c.tools); self.assertTrue(made[0].closed)
        c.worker_stop.set()

    def test_question_tool_asks_the_conversation_model_and_replies(self):
        c = self.call(); self.assertTrue(c.open_session())
        asked = []
        c.agent._live_delegate = lambda s, history: asked.append(history) or 'Karayoluyla yaklaşık altı yüz kilometre.'
        c.handle_message({'serverContent': {'inputTranscription': {'text': 'Muğla Ankara arası kaç kilometre?'}}})
        c.handle_message({'toolCall': {'functionCalls': [{'id': 'f1', 'name': 'bilgi_al', 'args': {'soru': 'Muğla Ankara arası kaç km?'}}]}})
        for _ in range(100):
            if not c.answers.empty(): break
            threading.Event().wait(0.01)
        c.send_answers()
        reply = c.connection.sent[-1]['toolResponse']['functionResponses'][0]
        self.assertEqual((reply['id'], reply['response']['yanit']), ('f1', 'Karayoluyla yaklaşık altı yüz kilometre.'))
        self.assertEqual([m['role'] for m in asked[0]], ['user'])
        self.assertIn('Muğla Ankara arası kaç km?', asked[0][-1]['content'])
        c.worker_stop.set()

    def test_reconnect_keeps_earlier_owner_notes(self):
        c = self.call(); self.assertTrue(c.open_session())
        c.s.notes.append({'id': 'n1', 'text': '!muhabbet et', 'status': 'komut olarak iletildi; arayana söylenmez'})
        c.worker_stop.set(); self.assertTrue(c.open_session(resume=True))
        text = c.connection.sent[0]['setup']['systemInstruction']['parts'][0]['text']
        self.assertIn('muhabbet et', text); self.assertIn('DAHA ÖNCE GELENLER', text)
        c.worker_stop.set()

    def test_bang_command_is_context_only(self):
        c = self.call(); self.assertTrue(c.open_session())
        c.s.notes.append({'id': 'n1', 'text': '!daha kibar konuş', 'status': 'bekliyor'})
        c.deliver_notes()
        self.assertFalse(c.connection.sent[-1]['clientContent']['turnComplete'])
        self.assertIn('arayana söylenmez', c.s.notes[0]['status'])
        c.worker_stop.set()

    def test_settings_validation(self):
        self.assertEqual(gemini_live.model_name({}), 'gemini-3.8-live')
        self.assertEqual(gemini_live.model_name({'GEMINI_LIVE_MODEL': 'gemini-3.1-flash-live-preview'}), 'gemini-3.8-live')
        self.assertEqual(gemini_live.voice_name({}), 'Kore')
        with self.assertRaises(ValueError): gemini_live.model_name({'GEMINI_LIVE_MODEL': 'gemini-2.5'})
        with self.assertRaises(ValueError): gemini_live.voice_name({'GEMINI_LIVE_VOICE': 'kore'})
        with self.assertRaises(gemini_live.LiveError): gemini_live.require_key({'GEMINI_API_KEY': ''})

    def test_instructions_drop_backend_delegation(self):
        text = gemini_live.instructions('Sistem talimatı.')
        self.assertNotIn('Delegation policy', text); self.assertIn('Türkçe', text)

    def test_check_access_opens_and_closes(self):
        made = []
        def factory(key): made.append(Connection()); return made[-1]
        gemini_live.check_access('key', 'gemini-3.8-live', 'Kore', factory=factory)
        self.assertTrue(made[0].closed); self.assertIn('setup', made[0].sent[0])

    def test_server_content_audio_transcripts_interruption_and_resumption(self):
        c = self.call(); self.assertTrue(c.open_session()); c.greeting_sent_at = 0.0
        pcm = base64.b64encode((np.ones(240) * 1000).astype('<i2').tobytes()).decode()
        c.handle_message({'serverContent': {'modelTurn': {'parts': [{'inlineData': {'mimeType': 'audio/pcm;rate=24000', 'data': pcm}}]},
                                            'outputTranscription': {'text': 'Merhaba, '}}})
        self.assertTrue(c.player.busy()); self.assertTrue(c.first_output)
        c.handle_message({'serverContent': {'outputTranscription': {'text': 'Mehmet Bey müsait değil.'}}})
        c.handle_message({'serverContent': {'interrupted': True}})
        self.assertFalse(c.player.busy())
        self.assertTrue(any(args[0] == 'interrupted' for args, _ in self.emitted))
        c.handle_message({'serverContent': {'inputTranscription': {'text': 'Adım Mehmet.'}}})
        c.handle_message({'sessionResumptionUpdate': {'newHandle': 'h2', 'resumable': True}})
        self.assertEqual(c.handle, 'h2')
        c.captions()
        self.assertEqual([r['speaker'] for r in c.transcript.public()], ['Asistan', 'Arayan'])
        self.assertEqual(c.transcript.public()[0]['text'], 'Merhaba, Mehmet Bey müsait değil.')
        self.assertRegex(c.s.transcript[1], r'^\[\d{2}:\d{2}:\d{2} \+\d{2}:\d{2}\] Arayan: Adım Mehmet\.$')
        c.worker_stop.set()

    def test_player_buffers_a_long_reply_sent_faster_than_real_time(self):
        c = self.call()
        second = base64.b64encode(np.zeros(gemini_live.OUTPUT_RATE, dtype='<i2').tobytes()).decode()
        for _ in range(30): c.player.push(second)  # 30 s of audio arriving at once must not raise
        self.assertTrue(c.player.busy())

    def test_mutual_farewell_ends_the_call(self):
        c = self.call(); self.assertTrue(c.open_session())
        c.handle_message({'serverContent': {'inputTranscription': {'text': 'Tamam, hoşça kalın.'}}})
        c.transcript.rows[-1]['last'] = 0  # the assistant's reply starts a new row
        c.handle_message({'serverContent': {'outputTranscription': {'text': 'İyi günler.'}}})
        self.assertTrue(c.ending)
        c.worker_stop.set()

    def test_notes_wait_until_the_assistant_stops_speaking(self):
        c = self.call(); self.assertTrue(c.open_session())
        c.s.notes.append({'id': 'n1', 'text': 'Yarın arasın.', 'status': 'bekliyor'})
        c.player.push(base64.b64encode((np.ones(240) * 1000).astype('<i2').tobytes()).decode())
        c.deliver_notes(); self.assertEqual(c.s.notes[0]['status'], 'bekliyor')
        c.player.clear(); c.deliver_notes()
        self.assertNotEqual(c.s.notes[0]['status'], 'bekliyor')
        self.assertIn('Yarın arasın.', c.connection.sent[-1]['clientContent']['turns'][0]['parts'][0]['text'])
        c.worker_stop.set()


if __name__ == '__main__':
    unittest.main()
