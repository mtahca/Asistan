import importlib.util
import unicodedata
import os
import json
import queue
import sys
import tempfile
import threading
import time
import unittest
import uuid
import subprocess
import io
from contextlib import redirect_stdout
from pathlib import Path
from unittest.mock import patch
from types import SimpleNamespace

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

spec = importlib.util.spec_from_file_location('beta', Path(__file__).resolve().parents[1] / 'agent.py')
beta = importlib.util.module_from_spec(spec)
sys.modules['beta'] = beta
spec.loader.exec_module(beta)


class BetaTests(unittest.TestCase):
    def test_online_startup_never_loads_local_speech_models(self):
        import builtins
        original_import=builtins.__import__
        def guarded(name,*args,**kwargs):
            if name in ('mlx_whisper','faster_whisper','ema_lightning'):raise AssertionError('Online mode imported local model')
            return original_import(name,*args,**kwargs)
        with patch.object(beta,'VOICE_MODE','gpt-live'), patch.dict(os.environ,{'ANTHROPIC_API_KEY':'dummy','OPENAI_API_KEY':'dummy'}), patch.object(beta,'find_device',return_value=0), patch.object(beta.sd,'query_devices',return_value={'default_samplerate':48000}), patch.object(beta.sd,'check_input_settings'), patch.object(beta.sd,'check_output_settings'), patch.object(beta.Agent,'_resume_summaries'), patch.object(threading.Thread,'start'), patch.object(builtins,'__import__',side_effect=guarded):
            a=beta.Agent()
        self.assertEqual(a.voice.rate,48000);self.assertFalse(hasattr(a,'mlx_whisper'))

    def test_online_session_cleanup_preserves_takeover_and_summary(self):
        a=self.agent();a.out_idx=9;s=self.session();cleanup=[]
        class Call:
            def __init__(self,*args,**kwargs):pass
            def run(self):s.reason='takeover';s.stop.set()
            def close(self):cleanup.append('released')
        def bridge(session):
            self.assertEqual(cleanup,['released']);return True
        with patch.object(beta,'LiveCall',Call),patch.object(a,'_start_bridge',side_effect=bridge):
            a.run_live_session(s)
        self.assertIsNone(a.session);self.assertEqual(a.summaries.qsize(),1)
        ended=next(e for e in self.events if e['event']=='session_ended')
        self.assertTrue(ended['bridge_active']);self.assertEqual(ended['reason'],'takeover')

    def test_live_fragments_survive_summary_job_restart(self):
        a=self.agent();s=self.session();s.live_fragments=[{'speaker':'Arayan','delta':'Deneme','start_ms':0,'end_ms':100}]
        a._queue_summary(s);a.summaries.get();a._resume_summaries()
        resumed=a.summaries.get_nowait();self.assertEqual(resumed.live_fragments,s.live_fragments)

    def test_live_timestamps_are_private_and_do_not_clutter_the_note(self):
        s=self.session();s.transcript=['Arayan: Deneme.']
        s.live_fragments=[{'speaker':'Arayan','delta':'Deneme.','start_ms':0,'end_ms':100}]
        s.write()
        self.assertNotIn('start_ms',s.path.read_text())
        metadata=beta.BASE/'live_transcripts'/(s.id+'.json')
        self.assertEqual(json.loads(metadata.read_text()),s.live_fragments)
        self.assertEqual(metadata.stat().st_mode & 0o777,0o600)

    def test_audio_defaults_ignore_legacy_driver_settings(self):
        with tempfile.TemporaryDirectory() as directory:
            Path(directory, '.env').write_text('IN_DEVICE=Old Virtual Input\nOUT_DEVICE=Old Virtual Output\n')
            environment = dict(os.environ, ASISTAN_HOME=directory)
            for key in ('BETA_AUDIO_INPUT', 'BETA_AUDIO_OUTPUT'):
                environment.pop(key, None)
            script = "import importlib.util,sys,json; s=importlib.util.spec_from_file_location('audio_check',sys.argv[1]); m=importlib.util.module_from_spec(s);sys.modules[s.name]=m;s.loader.exec_module(m);print(json.dumps([m.IN_DEVICE,m.OUT_DEVICE]))"
            output = subprocess.check_output([sys.executable, '-B', '-c', script, str(Path(beta.__file__))], env=environment, text=True)
            self.assertEqual(json.loads(output), ['Asistan Dinleme', 'Asistan Ses Çıkışı'])

    def test_audio_device_lookup_is_exact_and_unambiguous(self):
        devices = [{'name': 'Asistan Dinleme Yedek', 'max_input_channels': 2},
                   {'name': 'Asistan Dinleme', 'max_input_channels': 2}]
        with patch.object(beta.sd, 'query_devices', return_value=devices):
            self.assertEqual(beta.find_device('Asistan Dinleme', 'input'), 1)
        with patch.object(beta.sd, 'query_devices', return_value=[devices[1], devices[1]]):
            with self.assertRaises(RuntimeError): beta.find_device('Asistan Dinleme', 'input')

    def test_audio_names_match_macos_canonical_unicode_forms(self):
        name = 'Asistan Ses Çıkışı'
        decomposed = unicodedata.normalize('NFD', name)
        self.assertNotEqual(name, decomposed)
        for device_name, requested in ((name, decomposed), (decomposed, name)):
            devices = [{'name': device_name, 'max_input_channels': 2, 'max_output_channels': 2}]
            with patch.object(beta.sd, 'query_devices', return_value=devices):
                self.assertEqual(beta.find_device(requested, 'output'), 0)
        devices = [{'name': name, 'max_output_channels': 2},
                   {'name': decomposed, 'max_output_channels': 2}]
        with patch.object(beta.sd, 'query_devices', return_value=devices):
            with self.assertRaises(RuntimeError): beta.find_device(name, 'output')

    def test_takeover_uses_same_fixed_output_and_closes_microphone(self):
        class Stream:
            def __init__(self, **options): self.options=options; self.started=False; self.stopped=False; self.closed=False
            def start(self): self.started=True
            def stop(self): self.stopped=True
            def close(self): self.closed=True
        with patch.object(beta.sd, 'Stream', Stream), patch.object(beta, 'find_device', return_value=3):
            bridge = beta.MicrophoneBridge('call', 9, 48000)
        self.assertEqual(bridge.stream.options['device'], (3, 9))
        self.assertTrue(bridge.stream.started)
        audio=beta.np.array([[0.25],[-0.5]], dtype='float32'); out=beta.np.zeros((2,2), dtype='float32')
        bridge._callback(audio,out,2,None,None)
        beta.np.testing.assert_array_equal(out, [[0.25,0.25],[-0.5,-0.5]])
        bridge.close(); self.assertTrue(bridge.stream.stopped and bridge.stream.closed)
        bridge._callback(audio,out,2,None,None)
        self.assertFalse(out.any())

    def test_old_bridge_stop_cannot_close_new_takeover(self):
        a=self.agent(); closed=[]
        a.bridge=SimpleNamespace(id='current',close=lambda:closed.append(True))
        a.handle_command({'command':'stop_bridge','session_id':'old'})
        self.assertFalse(closed)
        a.handle_command({'command':'stop_bridge','session_id':'current'})
        self.assertEqual(closed,[True]);self.assertIsNone(a.bridge)
        self.assertEqual(self.events[-1]['event'],'bridge_ended')

    def test_playback_cancellation_has_one_stream_owner(self):
        started = threading.Event(); calls = []; errors = []
        class Stream:
            def __init__(self, **options): self.options = options
            def __enter__(self):
                calls.append(('start', threading.get_ident())); started.set(); return self
            def abort(self): calls.append(('abort', threading.get_ident()))
            def __exit__(self, *args): calls.append(('close', threading.get_ident()))
        voice = object.__new__(beta.Voice); voice.turn = beta.VoiceTurn()
        def play():
            try: beta.play_audio(beta.np.ones(100), 48000, 9, voice.turn.stop)
            except Exception as e: errors.append(e)
        with patch.object(beta.sd, 'OutputStream', Stream), patch.object(beta.sd, 'stop', side_effect=AssertionError('global stop is unsafe')):
            player = threading.Thread(target=play); player.start()
            self.assertTrue(started.wait(1))
            interrupters = [threading.Thread(target=voice.interrupt) for _ in range(8)]
            for t in interrupters: t.start()
            for t in interrupters: t.join(1)
            player.join(1)
        self.assertFalse(player.is_alive()); self.assertFalse(errors)
        self.assertEqual([name for name, _ in calls], ['start', 'abort', 'close'])
        self.assertEqual({owner for _, owner in calls}, {player.ident})

    def test_playback_stereo_tail_and_normal_completion(self):
        blocks = []; calls = []
        class Stream:
            def __init__(self, **options): self.options = options
            def __enter__(self):
                while True:
                    out = beta.np.full((2, 2), 99, dtype='float32')
                    try: self.options['callback'](out, 2, None, None)
                    except beta.sd.CallbackStop:
                        blocks.append(out.copy()); self.options['finished_callback'](); break
                    blocks.append(out.copy())
                return self
            def abort(self): calls.append('abort')
            def __exit__(self, *args): calls.append('close')
        with patch.object(beta.sd, 'OutputStream', Stream):
            beta.play_audio(beta.np.array([0.1, 0.2, 0.3]), 48000, 9, threading.Event())
        beta.np.testing.assert_allclose(blocks[0], [[0.1,0.1],[0.2,0.2]])
        beta.np.testing.assert_allclose(blocks[1], [[0.3,0.3],[0,0]])
        self.assertEqual(calls, ['close'])

    def test_cancelled_playback_never_opens_audio(self):
        cancel = threading.Event(); cancel.set()
        with patch.object(beta.sd, 'OutputStream', side_effect=AssertionError('cancelled audio opened')):
            beta.play_audio(beta.np.ones(100), 48000, 9, cancel)

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.base = patch.object(beta, 'BASE', Path(self.tmp.name))
        self.base.start()
        self.events = []
        self.emitter = patch.object(beta, 'emit', lambda event, session_id=None, **kw: self.events.append(dict(event=event, session_id=session_id, **kw)))
        self.emitter.start()

    def tearDown(self):
        self.emitter.stop(); self.base.stop(); self.tmp.cleanup()

    def agent(self):
        a = object.__new__(beta.Agent)
        a.shutdown = threading.Event(); a.commands = queue.Queue(maxsize=2)
        a.summaries = queue.Queue(); a._q = queue.Queue(maxsize=256)
        a.session = None; a.voice = SimpleNamespace(interrupt=lambda: None)
        a.bridge = None; a.bridge_lock = threading.RLock()
        a.in_idx = 0; a.in_rate = 48000
        return a

    def session(self):
        return beta.Session(str(uuid.uuid4()), {'name':'Deneme', 'number':''})

    def test_tts_failure_releases_playback(self):
        v = object.__new__(beta.Voice)
        v._synth_lock = threading.Lock(); v.rate = 48000; v.out_idx = 0
        v.greeting_audio = None
        def fail(*a, **k): raise RuntimeError('tts failed')
        v.tts = SimpleNamespace(say=fail)
        turn = beta.VoiceTurn(); turn.texts.put('Test'); turn.texts.put(None)
        player = threading.Thread(target=v._play_loop, args=(turn,), daemon=True)
        player.start(); v._synth_loop(turn); player.join(1)
        self.assertFalse(player.is_alive())
        self.assertEqual(turn.errors, ['tts failed'])

    def test_obsolete_turn_cannot_enqueue_into_current_turn(self):
        v = object.__new__(beta.Voice)
        old, new = beta.VoiceTurn(), beta.VoiceTurn()
        old.stop.set(); v.turn = new
        v.say(old, 'Eski cevap'); v.end(old)
        self.assertTrue(new.texts.empty())
        self.assertIsNone(old.texts.get_nowait())

    def test_session_error_saves_transcript_and_always_releases_ui(self):
        a = self.agent(); s = self.session()
        class Stream:
            def __init__(self, **kw): pass
            def start(self): pass
            def stop(self): pass
            def close(self): pass
        def fail(*args, **kw):
            a._record(s, 'Arayan', 'Lütfen beni yarın arayın.')
            raise RuntimeError('simulated error')
        a._speak = fail
        with patch.object(beta.sd, 'InputStream', Stream), patch.object(beta, 'GREETING_DELAY_S', 0):
            a.run_session(s)
        self.assertIn('Lütfen beni yarın arayın.', s.path.read_text())
        self.assertTrue(any(e['event'] == 'session_ended' and e['reason'] == 'error' for e in self.events))
        self.assertIsNone(a.session)
        self.assertEqual(a.summaries.get_nowait(), s)

    def test_summary_is_queued_after_audio_release(self):
        a = self.agent(); s = self.session()
        s.stop.set(); s.reason = 'takeover'
        with patch.object(beta.sd, 'InputStream', side_effect=RuntimeError('stream unavailable')):
            a.run_session(s)
        self.assertTrue(s.path.exists())
        self.assertTrue(any(e['event'] == 'session_ended' for e in self.events))
        self.assertEqual(a.summaries.get_nowait(), s)
        # No cloud client is used by run_session, including its error/finally path.

    def test_stale_commands_do_not_stop_or_add_notes_to_new_call(self):
        a = self.agent(); s = self.session(); a.session = s
        wrong = str(uuid.uuid4())
        a.handle_command({'command':'takeover','session_id':wrong})
        a.handle_command({'command':'note','session_id':wrong,'text':'Yanlış not'})
        self.assertFalse(s.stop.is_set()); self.assertEqual(s.notes, [])
        a.handle_command({'command':'takeover','session_id':s.id})
        self.assertTrue(s.stop.is_set()); self.assertEqual(s.reason, 'takeover')

    def test_caller_identity_cannot_choose_output_path(self):
        a = self.agent()
        a.handle_command({'command':'begin','session_id':'../../escape','caller':{}})
        self.assertTrue(a.commands.empty())
        s = self.session()
        a.handle_command({'command':'begin','session_id':s.id,'caller':{'name':'OTURUM BİTTİ','number':''}})
        queued = a.commands.get_nowait()
        self.assertEqual(queued.caller['name'],'OTURUM BİTTİ')
        self.assertEqual(queued.path.parent, beta.BASE / 'notlar')

    def test_note_status_is_delivered_only_after_completed_audio(self):
        a = self.agent(); s = self.session(); a.session = s
        a.handle_command({'command':'note','session_id':s.id,'note_id':'n1','text':'Yarın arayacağım.'})
        self.assertEqual(s.notes[0]['status'],'bekliyor')
        a._speak = lambda *args, **kw: ('',None,True)
        a._deliver_notes(s,time.monotonic())
        self.assertEqual(s.notes[0]['status'],'yarıda kesildi')
        self.assertNotIn('iletildi',[e.get('status') for e in self.events])

    def test_note_is_delivered_without_waiting_for_new_caller_speech(self):
        a = self.agent(); s = self.session(); a.session = s
        a.handle_command({'command':'note','session_id':s.id,'note_id':'n1','text':'Mesajınızı aldım.'})
        self.assertEqual(a._wait(s,time.monotonic(),30),'note')
        a._speak = lambda *args, **kw: ('',None,False)
        a._deliver_notes(s,time.monotonic())
        self.assertEqual(s.notes[0]['status'],'iletildi')

    def test_disk_failure_does_not_skip_session_cleanup(self):
        a = self.agent(); s = self.session()
        with patch.object(s,'write',side_effect=OSError('disk full')), patch.object(beta.sd,'InputStream',side_effect=OSError('missing device')):
            a.run_session(s)
        self.assertTrue(any(e['event']=='session_ended' for e in self.events))
        self.assertIsNone(a.session)

    def test_private_local_note_permissions(self):
        s = self.session(); s.transcript.append('Arayan: Test mesajı')
        s.write()
        self.assertEqual(s.path.stat().st_mode & 0o777,0o600)
        self.assertEqual(s.path.parent.stat().st_mode & 0o777,0o700)
        self.assertEqual(list(s.path.parent.glob('*.tmp')),[])

    def test_pending_summary_survives_a_restart(self):
        a = self.agent(); s = self.session()
        s.transcript.append('Arayan: Yarın arayın.')
        a._queue_summary(s)
        job = beta.BASE / 'summary_jobs' / (s.id + '.json')
        self.assertTrue(job.exists())
        self.assertEqual(job.stat().st_mode & 0o777, 0o600)
        restarted = self.agent(); restarted._resume_summaries()
        restored = restarted.summaries.get_nowait()
        self.assertEqual(restored.id, s.id)
        self.assertEqual(restored.transcript, s.transcript)
        self.assertEqual(restored.path, s.path)

    def test_invalid_summary_job_cannot_redirect_note_file(self):
        a = self.agent()
        jobs = beta.BASE / 'summary_jobs'; jobs.mkdir()
        (jobs/'bad.json').write_text(json.dumps({'id':'../../other','started':'2026-01-01','caller':{}}))
        a._resume_summaries()
        self.assertTrue(a.summaries.empty())

    def test_route_loss_stops_the_current_session(self):
        a = self.agent(); s = self.session(); a.session = s
        stopped = []
        a.voice = SimpleNamespace(interrupt=lambda: stopped.append(True))
        a.handle_command({'command':'route_lost','session_id':s.id})
        self.assertTrue(s.stop.is_set())
        self.assertEqual(s.reason,'route_lost')
        self.assertEqual(stopped,[True])

    def test_saved_settings_override_inherited_model_environment(self):
        (beta.BASE / '.env').write_text('CLAUDE_MODEL=claude-sonnet-5-5\n')
        with patch.dict(os.environ, {'CLAUDE_MODEL':'claude-haiku-4-5'}):
            beta.load_env()
            self.assertEqual(os.environ['CLAUDE_MODEL'],'claude-sonnet-5-5')

    def test_sonnet_options_reach_sdk_as_valid_request_json(self):
        import httpx2
        from anthropic import Anthropic
        captured = []
        def transport(request):
            captured.append(json.loads(request.content))
            return httpx2.Response(200,json={'id':'msg_test','type':'message','role':'assistant',
                'model':'claude-sonnet-5-5','content':[{'type':'text','text':'Mesajınız alındı.'}],
                'stop_reason':'end_turn','stop_sequence':None,'usage':{'input_tokens':1,'output_tokens':1}})
        with httpx2.Client(transport=httpx2.MockTransport(transport)) as http:
            client=Anthropic(api_key='test-key',http_client=http)
            client.messages.create(model='claude-sonnet-5-5',max_tokens=140,
                messages=[{'role':'user','content':'Merhaba'}],**beta.claude_model_options('claude-sonnet-5-5'))
        self.assertEqual(captured[0]['thinking'],{'type':'between_tools'})
        self.assertNotIn('thinking',beta.claude_model_options('claude-haiku-4-5'))

    def test_haiku_55_options_reach_sdk_without_sampling_or_thinking_budget(self):
        import httpx2
        from anthropic import Anthropic
        captured = []
        def transport(request):
            captured.append(json.loads(request.content))
            return httpx2.Response(200, json={'id':'msg_test','type':'message','role':'assistant',
                'model':'claude-haiku-5-5','content':[{'type':'text','text':'Mesajınız alındı.'}],
                'stop_reason':'end_turn','stop_sequence':None,'usage':{'input_tokens':1,'output_tokens':1}})
        with httpx2.Client(transport=httpx2.MockTransport(transport)) as http:
            client = Anthropic(api_key='test-key', http_client=http)
            client.messages.create(model='claude-haiku-5-5', max_tokens=180,
                messages=[{'role':'user','content':'Merhaba'}], **beta.claude_model_options('claude-haiku-5-5'))
        self.assertEqual(captured[0]['thinking'], {'type':'disabled'})
        self.assertEqual(captured[0]['output_config'], {'effort':'low'})
        for key in ('temperature','top_p','top_k','budget_tokens'): self.assertNotIn(key, captured[0])

    def test_haiku_live_backend_does_not_send_assistant_prefill(self):
        captured = []
        history = [{'role':'user','content':'Merhaba'}, {'role':'assistant','content':'Nasıl yardımcı olabilirim?'}]
        a = self.agent()
        def create(**kwargs):
            captured.append(kwargs)
            return SimpleNamespace(content=[SimpleNamespace(type='text', text='Mesajınızı alabilirim.')])
        a.claude = SimpleNamespace(messages=SimpleNamespace(create=create))
        with patch.object(beta, 'LLM_PROVIDER', 'anthropic'), patch.object(beta, 'CONVERSATION_CHOICE', beta.model_choices({'CLAUDE_MODEL':'claude-haiku-5-5'})[0]):
            self.assertEqual(a._live_delegate(self.session(), history), 'Mesajınızı alabilirim.')
        self.assertEqual(captured[0]['messages'][-1]['role'], 'user')
        self.assertEqual(len(history), 2)
        self.assertEqual(captured[0]['messages'][:-1], history)
        self.assertIs(beta.claude_messages('claude-haiku-4-5', history), history)

    def test_summary_can_use_a_different_model_than_the_call(self):
        a=self.agent(); s=self.session(); s.transcript=['Arayan: Yarın arayın.']
        a._queue_summary(s)
        captured=[]
        def create(**kw):
            captured.append(kw); a.shutdown.set()
            return SimpleNamespace(content=[SimpleNamespace(type='text',text='Konu: Geri arama.')])
        client=SimpleNamespace(messages=SimpleNamespace(create=create))
        with patch('anthropic.Anthropic',return_value=client), patch.object(beta,'SUMMARY_MODEL','claude-sonnet-5-5'), patch.object(beta,'CLAUDE_MODEL','claude-haiku-4-5'):
            a._summary_loop()
        self.assertEqual(captured[0]['model'],'claude-sonnet-5-5')
        self.assertIn('Geri arama.',s.path.read_text())
        self.assertFalse((beta.BASE/'summary_jobs'/(s.id+'.json')).exists())

    def test_cloud_summary_failure_keeps_local_transcript_and_retry_job(self):
        a=self.agent(); s=self.session(); s.transcript=['Arayan: Yarın arayın.']
        a._queue_summary(s)
        def fail(**kw):
            a.shutdown.set(); raise RuntimeError('simulated network failure')
        client=SimpleNamespace(messages=SimpleNamespace(create=fail))
        with patch('anthropic.Anthropic',return_value=client): a._summary_loop()
        self.assertIn('Arayan: Yarın arayın.',s.path.read_text())
        self.assertTrue((beta.BASE/'summary_jobs'/(s.id+'.json')).exists())
        self.assertTrue(any(e['event']=='summary_failed' for e in self.events))

    def test_api_default_is_bounded_for_live_calls(self):
        self.assertLessEqual(beta.API_TIMEOUT_S,30)
        self.assertLessEqual(beta.MAX_SESSION_S,600)

    def save_preferences(self, **changes):
        values = dict(version=1, general='', today='', todayDate='', greeting='', aliases={})
        values.update(changes)
        (beta.BASE / 'asistan_tercihleri.json').write_text(json.dumps(values))

    def test_empty_preferences_preserve_greeting_and_prompt(self):
        self.assertEqual(beta.load_assistant_preferences(), {})
        self.assertEqual(beta.build_greeting({}, {}), beta.GREETING_TEXT)
        self.assertEqual(beta.build_system_prompt({}, {}), beta.SYSTEM_PROMPT)

    def test_daily_note_expires_but_general_instructions_remain(self):
        self.save_preferences(general='Kısa konuş.', today='Bugün toplantıdayım.', todayDate='2000-01-01')
        prefs = beta.load_assistant_preferences()
        self.assertEqual(prefs['general'], 'Kısa konuş.')
        self.assertEqual(prefs['today'], '')
        self.assertNotIn('Bugün toplantıdayım.', beta.build_system_prompt({}, prefs))
        self.save_preferences(today='Bugün toplantıdayım.', todayDate=beta.datetime.now().strftime('%Y-%m-%d'))
        self.assertIn('Bugün toplantıdayım.', beta.build_system_prompt({}, beta.load_assistant_preferences()))

    def test_preferences_are_snapshotted_when_begin_is_received(self):
        a = self.agent()
        self.save_preferences(general='İlk talimat', greeting='İlk karşılama')
        a.handle_command(dict(command='begin', session_id=str(uuid.uuid4()), caller={}))
        session = a.commands.get_nowait()
        self.save_preferences(general='Yeni talimat', greeting='Yeni karşılama')
        self.assertEqual(beta.build_greeting(session.caller, session.preferences), 'İlk karşılama')
        self.assertIn('İlk talimat', beta.build_system_prompt(session.caller, session.preferences))
        self.assertNotIn('Yeni talimat', beta.build_system_prompt(session.caller, session.preferences))
        a.handle_command(dict(command='begin', session_id=str(uuid.uuid4()), caller={}))
        self.assertEqual(a.commands.get_nowait().preferences['general'], 'Yeni talimat')

    def test_manual_aliases_match_exact_canonical_names_only(self):
        self.save_preferences(aliases={'AŞKIM': 'Ayşe Hanım'})
        prefs = beta.load_assistant_preferences()
        self.assertEqual(beta.caller_address({'name':'Aşkım'}, prefs), 'Ayşe Hanım')
        self.assertEqual(beta.caller_address({'name':'Aşkım (Ayşe)', 'in_contacts':True}, prefs), 'Ayşe Hanım')
        for name in ('Aşkim', 'Aşkım iş', 'Başka kişi', 'Aşkım (Ayşe)'):
            self.assertEqual(beta.caller_address({'name':name}, prefs), '')
        self.assertIn('Merhaba Ayşe Hanım,', beta.build_greeting({'name':'Aşkım'}, prefs))

    def test_invalid_preferences_fall_back_without_overwriting_file(self):
        path = beta.BASE / 'asistan_tercihleri.json'
        invalid = ['{broken', '[]', json.dumps({'version':True}),
                   json.dumps({'version':1, 'general': ['bad']}),
                   json.dumps({'version':1, 'aliases': {'Aşkım':'One', 'aşkım':'Two'}}),
                   json.dumps({'version':1, 'aliases': {'Name':'bad\ntext'}}),
                   json.dumps({'version':1, 'greeting':'x'*501})]
        for text in invalid:
            with self.subTest(text=text[:40]):
                path.write_text(text)
                self.assertEqual(beta.load_assistant_preferences(), {})
                self.assertEqual(path.read_text(), text)

    def test_configured_greeting_reaches_speech_and_history(self):
        a = self.agent(); self.save_preferences(greeting='Özel karşılama.')
        s = self.session(); speech=[]; histories=[]
        class Stream:
            def __init__(self, **kwargs): pass
            def start(self): pass
            def stop(self): pass
            def close(self): pass
        def speak(session, started, history=None, text=None):
            speech.append(text)
            if history: histories.append(list(history))
            return ('Tamam. [BITTI]', None, False)
        a._speak = speak; a._wait = lambda *args: beta.np.zeros(16000)
        a._stt = lambda *args: 'Merhaba.'
        with patch.object(beta.sd, 'InputStream', Stream), patch.object(beta, 'GREETING_DELAY_S', 0):
            a.run_session(s)
        self.assertEqual(speech[0], 'Özel karşılama.')
        self.assertEqual(histories[0][1]['content'], 'Özel karşılama.')
        job = beta.BASE / 'summary_jobs' / (s.id + '.json')
        self.assertNotIn('preferences', json.loads(job.read_text()))

    def test_selected_takeover_microphone_is_snapshotted_per_call(self):
        a = self.agent(); a.out_idx=9; a.voice.rate=48000
        a.handle_command(dict(command='begin', session_id=str(uuid.uuid4()), caller={}, microphone='USB Microphone'))
        session = a.commands.get_nowait()
        with patch.object(beta, 'MicrophoneBridge') as bridge:
            self.assertTrue(a._start_bridge(session))
            bridge.assert_called_once_with(session.id, 9, 48000, 'USB Microphone')

    def test_private_instructions_reach_model_without_becoming_caller_identity(self):
        a = self.agent(); s = self.session(); s.preferences={'general':'Özel talimat', 'today':'Günlük not'}
        captured=[]
        class Stream:
            text_stream = ['Mesajınızı alayım.']
            def __enter__(self): return self
            def __exit__(self, *args): pass
        def stream(**kwargs): captured.append(kwargs); return Stream()
        a.claude=SimpleNamespace(messages=SimpleNamespace(stream=stream))
        spoken=[]; a.voice.say=lambda turn, text: spoken.append(text); a.voice.end=lambda turn: None
        a._reply_worker(s, [{'role':'user','content':'Merhaba'}], beta.VoiceTurn(), threading.Event(), {})
        self.assertIn('Özel talimat', captured[0]['system'])
        self.assertIn('Günlük not', captured[0]['system'])
        self.assertNotIn('Özel talimat', json.dumps(captured[0]['messages']))
        self.assertEqual(s.caller['name'], 'Deneme')

    def test_openai_reply_reaches_existing_sentence_audio_pipeline(self):
        import httpx
        from llm import OpenAIResponses
        a = self.agent(); s = self.session(); s.preferences={'general':'Genel talimat'}
        requests=[]; spoken=[]
        def transport(request):
            requests.append(json.loads(request.content))
            values=[{'type':'response.output_text.delta','delta':'Mesajınızı alayım. '},
                    {'type':'response.completed'}]
            return httpx.Response(200,content=''.join('data: '+json.dumps(v)+'\n\n' for v in values))
        with httpx.Client(transport=httpx.MockTransport(transport)) as client:
            a.openai=OpenAIResponses('test-key',8,client)
            a.voice.say=lambda turn,text:spoken.append(text); a.voice.end=lambda turn: None
            out={}
            with patch.object(beta,'LLM_PROVIDER','openai'), patch.object(beta,'OPENAI_MODEL','gpt-6-luna'):
                a._reply_worker(s,[{'role':'user','content':'Merhaba'}],beta.VoiceTurn(),threading.Event(),out)
        self.assertEqual(spoken,['Mesajınızı alayım.'])
        self.assertIn('Genel talimat',requests[0]['instructions'])
        self.assertEqual(requests[0]['input'],[{'role':'user','content':'Merhaba'}])
        self.assertNotIn('error',out)

    def test_openai_summary_keeps_existing_checkpoint_and_retry_behavior(self):
        import httpx
        from llm import OpenAIResponses
        a=self.agent(); s=self.session(); s.transcript=['Arayan: Geri arayın.']; a._queue_summary(s)
        captured=[]
        def transport(request):
            captured.append(json.loads(request.content)); a.shutdown.set()
            return httpx.Response(200,json={'status':'completed','output':[{'type':'message','content':[{'type':'output_text','text':'Geri arama istendi.'}]}]})
        with httpx.Client(transport=httpx.MockTransport(transport)) as http:
            client=OpenAIResponses('test-key',8,http)
            with patch.object(beta,'SUMMARY_PROVIDER','openai'), patch.object(beta,'SUMMARY_MODEL','gpt-6-luna'), patch.object(beta,'OpenAIResponses',return_value=client):
                a._summary_loop()
        self.assertIn('Geri arama istendi.',s.path.read_text())
        self.assertEqual(captured[0]['model'],'gpt-6-luna')
        self.assertFalse((beta.BASE/'summary_jobs'/(s.id+'.json')).exists())

    def test_api_check_deduplicates_models_and_sends_no_call_content(self):
        import httpx
        from llm import ModelChoice, OpenAIResponses
        requests=[]
        def transport(request):
            requests.append(json.loads(request.content))
            return httpx.Response(200, content='data: '+json.dumps({'type':'response.output_text.delta','delta':'Tamam'})+'\n\ndata: '+json.dumps({'type':'response.completed'})+'\n\n')
        with httpx.Client(transport=httpx.MockTransport(transport)) as http:
            client=OpenAIResponses('test-key',8,http); output=io.StringIO()
            choice=ModelChoice('openai','gpt-6-luna')
            with patch.object(beta,'CONVERSATION_CHOICE',choice), patch.object(beta,'SUMMARY_CHOICE',choice), patch.object(beta,'OpenAIResponses',return_value=client), patch.dict(os.environ,{'OPENAI_API_KEY':'test-key'}), redirect_stdout(output):
                beta.check_api()
        data=json.loads(output.getvalue())
        self.assertEqual(len(requests),1); self.assertTrue(data['checks'][0]['ok'])
        self.assertEqual(requests[0]['input'],[{'role':'user','content':'Bağlantı denemesi.'}])
        self.assertNotIn('test-key',output.getvalue())

    def test_api_check_never_echoes_arbitrary_error_text(self):
        from llm import ModelChoice
        secret='private-error-with-credential'
        choice=ModelChoice('openai','gpt-6-luna'); output=io.StringIO()
        with patch.object(beta,'CONVERSATION_CHOICE',choice), patch.object(beta,'SUMMARY_CHOICE',choice), patch.object(beta,'OpenAIResponses',side_effect=RuntimeError(secret)), patch.dict(os.environ,{'OPENAI_API_KEY':'test-key'}), redirect_stdout(output):
            beta.check_api()
        self.assertNotIn(secret,output.getvalue())
        self.assertFalse(json.loads(output.getvalue())['checks'][0]['ok'])

    def test_hallucination_filter_drops_phantom_lines_only(self):
        for text in ('', ' ', 'Altyazı M.K.', 'altyazı', 'Abone olmayı unutmayın.', 'İzlediğiniz için teşekkürler.'):
            self.assertTrue(beta.is_hallucination(text), text)
        for text in ('Merhaba.', 'Adım Mehmet.', 'Altyazıyı açar mısınız?', 'Devam edecek misiniz?',
                     'Altyazı konusunda Mehmet Bey ile konuşmam gerekiyor, ne zaman müsait olur acaba söyler misiniz'):
            self.assertFalse(beta.is_hallucination(text), text)

    def test_record_stamps_clock_and_elapsed_time(self):
        a = self.agent(); s = self.session()
        a._record(s, 'Arayan', 'Merhaba.')
        self.assertRegex(s.transcript[-1], r'^\[\d{2}:\d{2}:\d{2} \+00:0\d\] Arayan: Merhaba\.$')

    def test_greeting_cut_by_noise_is_repeated_once(self):
        a = self.agent(); s = self.session(); spoken = []
        class Stream:
            def __init__(self, **kw): pass
            def start(self): pass
            def stop(self): pass
            def close(self): pass
        def speak(session, started, history=None, text=None):
            spoken.append(text)
            if len(spoken) == 1: return text, beta.np.zeros(160, dtype=beta.np.float32), True
            return text, None, False
        a._speak = speak
        a._stt = lambda audio: 'Altyazı M.K.'
        a._wait = lambda *args: None
        with patch.object(beta, 'sd', SimpleNamespace(InputStream=Stream)), patch.object(beta, 'GREETING_DELAY_S', 0):
            a.run_session(s)
        greeting = beta.build_greeting(s.caller, s.preferences)
        self.assertEqual(spoken[:2], [greeting, greeting])
        self.assertEqual(len(spoken), 3)  # greeting, repeated greeting, goodbye after silence
        self.assertFalse(any('Altyazı' in line for line in s.transcript))

    def test_caller_line_accepts_time_stamped_lines(self):
        self.assertTrue(beta.caller_line('[20:48:06 +00:01] Arayan: Merhaba.'))
        self.assertTrue(beta.caller_line('Arayan: Merhaba.'))
        self.assertFalse(beta.caller_line('[20:48:06 +00:01] Asistan: Merhaba.'))

if __name__ == '__main__':
    unittest.main()
