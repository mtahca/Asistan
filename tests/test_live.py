import base64
from pathlib import Path
import queue
import sys
import threading
import time
from types import SimpleNamespace
import unittest
from unittest.mock import patch
import numpy as np
sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
import live


def delta(speaker,text,start=0,end=100,event_id=None):
    return dict(type='session.'+speaker+'_transcript.delta',delta=text,start_ms=start,end_ms=end,event_id=event_id)

class Connection:
    def __init__(self,key='dummy'):
        self.events=queue.Queue();self.sent=[];self.closed=False
    def send(self,kind,**fields):
        self.sent.append((kind,fields))
        if kind=='session.start':self.events.put(dict(type='session.started'))
        if kind=='session.close':self.events.put(dict(type='session.closed',usage=dict(seconds=4)))
    def recv(self):
        try:return self.events.get(timeout=0.01)
        except queue.Empty:return None
    def close(self):self.closed=True

class LiveTests(unittest.TestCase):
    def call(self):
        s=SimpleNamespace(id='call',stop=threading.Event(),lock=threading.Lock(),notes=[],transcript=[],live_fragments=[],reason='completed')
        a=SimpleNamespace(np=np,emit=lambda *args,**kwargs:self.emitted.append((args,kwargs)),_checkpoint=lambda s:True)
        self.emitted=[]
        return live.LiveCall(a,s,'Talimat','Karşılama')

    def test_failed_send_reports_queued_server_reason(self):
        import io, contextlib
        c=self.call()
        c.events.put(delta('input','Merhaba',0,100,'a'))
        c.events.put({'type':'error','error':{'code':'rate_limit_exceeded','message':'limit'}})
        with contextlib.redirect_stderr(io.StringIO()) as err:
            reason=c.server_reason()
        self.assertIn('kota',str(reason));self.assertIn('rate_limit_exceeded',err.getvalue())
        c=self.call();c.events.put({'type':'session.closed'})
        with contextlib.redirect_stderr(io.StringIO()):
            self.assertIn('sunucu tarafından kapatıldı',str(c.server_reason()))
        self.assertIsNone(self.call().server_reason())

    def test_legacy_default_and_invalid_mode(self):
        self.assertEqual(live.voice_mode({}),'local')
        self.assertEqual(live.voice_mode({'VOICE_MODE':'gpt-live'}),'gpt-live')
        with self.assertRaises(ValueError):live.voice_mode({'VOICE_MODE':'other'})

    def test_voice_selection_default_allowed_values_and_rejection(self):
        self.assertEqual(live.voice_name({}), 'marin')
        for voice in live.LIVE_VOICES:
            self.assertEqual(live.session_config('hello', voice)['audio']['output']['voice'], voice)
        for voice in ('unknown', 'Marin', 'marin\nOPENAI_API_KEY=x'):
            with self.assertRaises(ValueError): live.voice_name({'GPT_LIVE_VOICE': voice})

    def test_voice_catalog_matches_swift_picker(self):
        import re, json
        source = (Path(__file__).resolve().parents[1] / 'app/ModelConfiguration.swift').read_text()
        names = json.loads(re.search(r'static let liveVoices: \[String\] = (\[[^\n]+\])', source).group(1))
        self.assertEqual(names, list(live.LIVE_VOICES))

    def test_access_check_uses_selected_voice_and_rejects_unknown_before_network(self):
        c = Connection(); live.check_access('dummy', factory=lambda key: c, voice='cedar')
        self.assertEqual(c.sent[0][1]['session']['audio']['output']['voice'], 'cedar')
        called = []
        with self.assertRaises(ValueError): live.check_access('dummy', factory=lambda key: called.append(key), voice='invalid')
        self.assertEqual(called, [])

    def test_live_requires_key_without_changing_local(self):
        live.require_live_key({})
        with self.assertRaises(live.LiveError):live.require_live_key({'VOICE_MODE':'gpt-live'})
        live.require_live_key({'VOICE_MODE':'gpt-live','OPENAI_API_KEY':'dummy'})

    def test_session_is_live_not_realtime_and_does_not_store(self):
        cfg=live.session_config('hello')
        self.assertEqual(cfg['model'],'gpt-live-1');self.assertFalse(cfg['store'])
        self.assertEqual(cfg['audio']['format'],{'type':'audio/pcm','rate':24000})
        self.assertEqual(cfg['delegation'],{'type':'client'})
        self.assertNotIn('tools',cfg)

    def test_access_check_has_no_audio_or_greeting_and_closes(self):
        c=Connection();live.check_access('dummy',factory=lambda key:c)
        self.assertEqual([k for k,_ in c.sent],['session.start','session.close']);self.assertTrue(c.closed)
        self.assertNotIn('Karşılama',str(c.sent))

    def test_greeting_ack_matches_only_current_instruction(self):
        c=self.call();c.greeting_id='current'
        c.handle_event({'type':'session.instructions.appended','client_event_id':'old'})
        self.assertFalse(c.greeting_ack)
        c.handle_event({'type':'session.instructions.appended','client_event_id':'current'})
        self.assertTrue(c.greeting_ack)
        self.assertFalse(c.first_output)

    def test_silent_start_gets_one_speakable_greeting_after_ack(self):
        c=self.call();c.connection=Connection();c.greeting_sent_at=0;c.greeting_ack=True
        with patch.object(live.time,'monotonic',return_value=5):
            c.ensure_greeting();c.ensure_greeting()
        self.assertEqual(c.connection.sent,[('session.commentary.append',{'delegation_id':None,'content':'Karşılama'})])

    def test_greeting_nudge_waits_two_seconds_and_ack_then_runs_once(self):
        c=self.call();c.connection=Connection();c.greeting_sent_at=0;c.greeting_ack=True
        with patch.object(live.time,'monotonic',return_value=1.9):c.ensure_greeting()
        self.assertEqual(c.connection.sent,[])
        with patch.object(live.time,'monotonic',return_value=2.1):c.ensure_greeting();c.ensure_greeting()
        self.assertEqual(len(c.connection.sent),1)

    def test_greeting_never_repeats_after_caller_or_assistant_or_stop(self):
        for state,value in [('input_revision',1),('first_output',True),('output_text_seen',True),('caller_audio_seen',True),('greeting_ack',False)]:
            c=self.call();c.connection=Connection();c.greeting_sent_at=0;c.greeting_ack=True;setattr(c,state,value)
            with patch.object(live.time,'monotonic',return_value=5):c.ensure_greeting()
            self.assertEqual(c.connection.sent,[],state)
        c=self.call();c.connection=Connection();c.greeting_sent_at=0;c.greeting_ack=True;c.s.stop.set()
        with patch.object(live.time,'monotonic',return_value=5):c.ensure_greeting()
        self.assertEqual(c.connection.sent,[])

    def test_silent_audio_is_not_reported_as_first_speech(self):
        c=self.call();c.greeting_sent_at=0
        c.handle_event({'type':'session.output_audio.delta','delta':base64.b64encode(bytes(10)).decode()})
        self.assertFalse(c.first_output)
        with patch.object(live.time,'monotonic',return_value=2):
            c.handle_event({'type':'session.output_audio.delta','delta':base64.b64encode(np.array([0,100,-100],dtype='<i2').tobytes()).decode()})
        self.assertTrue(c.first_output);self.assertEqual(self.emitted[-1][0][0],'live_status')

    def test_transport_returns_event_id_for_ack_matching(self):
        class WS:
            def getstatus(self):return 101
            def settimeout(self,n):pass
            def send(self,payload):self.payload=payload
            def shutdown(self):pass
        import json
        ws=WS();c=live.LiveConnection('dummy',factory=lambda *a,**k:ws)
        eid=c.send('session.instructions.append',delegation_id=None,content='hello')
        self.assertEqual(json.loads(ws.payload)['event_id'],eid)
        self.assertEqual(c.send('session.instructions.append',event_id='fixed',delegation_id=None,content='hello'),'fixed')
        c.close()

    def test_access_error_is_sanitized_and_releases_transport(self):
        c=Connection()
        def send(kind,**fields):c.events.put({'type':'error','error':{'message':'secret-key','code':'other'}})
        c.send=send
        with self.assertRaises(live.LiveError) as result:live.check_access('secret-key',factory=lambda key:c)
        self.assertNotIn('secret-key',str(result.exception));self.assertTrue(c.closed)

    def test_transport_uses_fixed_endpoint_verified_tls_and_no_redirect(self):
        class WS:
            def getstatus(self):return 101
            def settimeout(self,n):pass
            def shutdown(self):pass
        args=[]
        c=live.LiveConnection('dummy',factory=lambda *a,**k:(args.append((a,k)) or WS()))
        self.assertEqual(args[0][0],(live.ENDPOINT,));self.assertEqual(args[0][1]['redirect_limit'],0)
        self.assertTrue(args[0][1]['suppress_origin'])
        self.assertIn('ca_certs',args[0][1]['sslopt']);self.assertNotIn('cert_reqs',args[0][1]['sslopt']);c.close()

    def test_redirect_and_http_error_never_forward_key_or_server_text(self):
        class WS:
            stopped=False
            def getstatus(self):return 302
            def shutdown(self):self.stopped=True
        ws=WS()
        with self.assertRaises(live.LiveError):live.LiveConnection('secret',factory=lambda *a,**k:ws)
        self.assertTrue(ws.stopped)
        def factory(*a,**k):raise RuntimeError('secret in server body')
        with self.assertRaises(live.LiveError) as e:live.LiveConnection('secret',factory=factory)
        self.assertNotIn('secret',str(e.exception))

    def test_context_chunks_are_lossless_and_within_token_upper_bound(self):
        text='😀 İğdır\n'*100
        chunks=list(live.context_chunks(text))
        self.assertEqual(''.join(chunks),text);self.assertTrue(all(len(x.encode())<=450 for x in chunks))

    def test_transcript_keeps_spaces_repetitions_and_overlapping_speakers(self):
        t=live.Transcript()
        t.add(delta('input','Bir',1000,1200,'a'));t.add(delta('output','Anladım.',1100,1300,'b'))
        t.add(delta('input',' bir not.',1200,1700,'c'))
        self.assertEqual([r['text'] for r in t.rows()],['Bir bir not.','Anladım.'])
        self.assertEqual(len(t.fragments),3);self.assertEqual(t.fragments[0]['start_ms'],1000)

    def test_late_transcript_is_ordered_by_interval(self):
        t=live.Transcript();t.add(delta('input',' ikinci',1100,1300));t.add(delta('input','Birinci',900,1100))
        self.assertEqual(t.rows()[0]['text'],'Birinci ikinci')

    def test_duplicate_events_not_repeated_but_repeated_words_kept(self):
        t=live.Transcript();e=delta('input','evet ',0,100,'a')
        self.assertTrue(t.add(e));self.assertFalse(t.add(e))
        t.add(delta('input','evet',100,200,'b'));self.assertEqual(t.rows()[0]['text'],'evet evet')

    def test_invalid_transcript_intervals_rejected(self):
        with self.assertRaises(live.LiveError):live.Transcript().add(delta('input','x',100,0))

    def test_pcm_player_stereo_tail_and_silence(self):
        p=live.PCMPlayer(np);p.push(base64.b64encode(np.array([32767,-32768,0],dtype='<i2').tobytes()).decode())
        out=np.ones((5,2),dtype=np.float32);p.callback(out,5,None,None)
        np.testing.assert_allclose(out[:3,0],[32767/32768,-1,0]);np.testing.assert_array_equal(out[:,0],out[:,1])
        self.assertFalse(out[3:].any());self.assertFalse(p.busy())

    def test_pcm_player_interruption_discards_old_audio(self):
        p=live.PCMPlayer(np);raw=base64.b64encode(np.ones(20,dtype='<i2').tobytes()).decode()
        p.push(raw);p.clear(mute=True);p.push(raw)
        out=np.ones((2,2));p.callback(out,2,None,None);self.assertFalse(out.any());self.assertFalse(p.busy())

    def test_pcm_player_bounded_latency_and_invalid_payload(self):
        p=live.PCMPlayer(np)
        with self.assertRaises(live.LiveError):p.push(base64.b64encode(b'x').decode())
        with self.assertRaises(live.LiveError):p.push('!invalid!')
        with self.assertRaises(live.LiveError):p.push(base64.b64encode(bytes(24000*2*4)).decode())

    def test_capture_stops_immediately_on_takeover(self):
        c=self.call();c.s.stop.set();c.capture(np.ones((720,2)),720,None,None);self.assertTrue(c.audio.empty())

    def test_capture_overflow_reports_failure_instead_of_growing_queue(self):
        c=self.call()
        for _ in range(26):c.capture(np.zeros((720,2)),720,None,None)
        self.assertEqual(c.audio.qsize(),25);self.assertFalse(c.errors.empty())

    def test_delegate_uses_metadata_only_once(self):
        c=self.call();e={'type':'session.delegation.created','delegation':{'id':'task','target':'client'}}
        c.handle_event(e);c.handle_event(e);self.assertEqual(list(c.pending),['task'])
        c.handle_event({'type':'session.delegation.created','delegation':{'id':'wrong','target':'responses'}})
        self.assertEqual(list(c.pending),['task'])

    def test_backend_history_starts_with_user_context_when_greeting_is_first(self):
        c=self.call();c.connection=Connection()
        c.handle_event(delta('output','Merhaba.',0,100))
        c.handle_event(delta('input','Bir not bırakacağım.',110,200))
        history=[]
        c.agent._live_delegate=lambda session,messages:(history.extend(messages) or 'Mesajınızı alayım.')
        c.pending.append('task');c.start_backend();c.backend.join(1)
        self.assertEqual(history[0]['role'],'user');self.assertEqual(history[0]['content'],'Telefon araması bağlandı.')
        self.assertEqual(history[-1]['content'],'Bir not bırakacağım.')

    def test_caption_updates_save_exact_fragments(self):
        c=self.call();c.handle_event(delta('input','Merhaba.',100,200,'t'));c.captions()
        self.assertEqual(c.s.transcript,['Arayan: Merhaba.']);self.assertEqual(c.s.live_fragments[0]['delta'],'Merhaba.')
        self.assertEqual(self.emitted[-1][0][0],'live_transcript')

    def test_note_sent_does_not_claim_audible_delivery(self):
        c=self.call();c.connection=Connection();c.s.notes=[{'id':'n','text':'😀'*1000,'status':'bekliyor'}]
        c.deliver_notes();self.assertIn('duyulması doğrulanmadı',c.s.notes[0]['status'])
        self.assertTrue(all(len(fields['content'].encode())<=450 for _,fields in c.connection.sent))
        c.deliver_notes();self.assertEqual(len(self.emitted),1)

    def test_usage_snapshots_are_not_added(self):
        c=self.call()
        for n in [12,15]:c.handle_event({'type':'session.usage.updated','usage':{'seconds':n}})
        self.assertEqual(c.seconds,15)

    def test_finalized_remote_session_is_not_mistaken_for_success(self):
        c=self.call();c.handle_event({'type':'session.closed','usage':{'seconds':15},'reason':'connection_lost'})
        self.assertTrue(c.finalized);self.assertTrue(c.s.stop.is_set());self.assertEqual(c.s.reason,'error')

    def test_caller_correction_cancels_pending_auto_close(self):
        c=self.call();c.ending=True;c.handle_event(delta('input','Hayır, bir şey daha var.',100,200))
        self.assertFalse(c.ending)

    def test_goodbye_can_be_split_across_fragments(self):
        c=self.call();c.ending=True
        c.handle_event(delta('output','Hoş',100,200));c.handle_event(delta('output','ça kalın.',200,300))
        self.assertTrue(c.ending_spoken)

    def test_audio_released_before_network_finalization_and_takeover(self):
        c=self.call();order=[]
        class Stream:
            def stop(self):order.append('audio-stop')
            def close(self):order.append('audio-close')
        c.streams=[Stream()];c.connection=Connection();c.s.stop.set()
        c.events.put({'type':'session.closed','usage':{'seconds':2}})
        original=c.connection.send
        def send(kind,**fields):order.append(kind);original(kind,**fields)
        c.connection.send=send;c.close()
        self.assertEqual(order[:3],['audio-stop','audio-close','session.close']);self.assertTrue(c.connection.closed)

    def test_stale_backend_cannot_send_into_a_closed_call(self):
        c=self.call();c.connection=Connection();c.s.stop.set();c.results.put(('task','Old reply',None,0))
        c.close();self.assertNotIn('session.commentary.append',[k for k,_ in c.connection.sent])

    def test_prompt_preserves_user_rules_but_adapts_text_markers(self):
        p=live.prompt('Karşılama cümlesini zaten söyledin (yapay zeka asistanı olduğunu ve not aldığını belirttin).\nKısa konuş ve cevabının EN SONUNA [BITTI] yaz.')
        self.assertNotIn('EN SONUNA [BITTI] yaz',p);self.assertIn('Interruption policy',p);self.assertIn('Kısa konuş',p)

class LiveCallIntegrationTests(unittest.TestCase):
    def test_stream_start_audio_protocol_transcript_and_takeover_cleanup(self):
        owner=LiveTests();call=owner.call();streams=[]
        class Stream:
            def __init__(self,**options):self.options=options;self.closed=False;streams.append(self)
            def start(self):
                cb=self.options['callback']
                if cb==call.capture:
                    for _ in range(3):cb(np.zeros((720,2),dtype=np.float32),720,None,None)
                else:cb(np.zeros((720,2),dtype=np.float32),720,None,None)
            def stop(self):pass
            def close(self):self.closed=True
        call.agent.live_voice = "cedar"
        c=Connection();original=c.send;audio=[]
        def send(kind,**fields):
            original(kind,**fields)
            if kind=='session.instructions.append':
                c.events.put(delta('input','Deneme.',100,200,'test'))
                c.events.put(delta('output','Sizi duyuyorum.',210,500,'answer'))
            if kind=='session.input_audio.append':
                audio.append(fields['audio'])
                if len(audio)==2:call.s.reason='takeover';call.s.stop.set()
        c.send=send
        call.factory=lambda key:c
        call.agent.sd=SimpleNamespace(InputStream=Stream,OutputStream=Stream)
        call.agent.live_key='dummy';call.agent.in_idx=1;call.agent.out_idx=2;call.agent.live_threshold=0.01
        call.agent._expired=lambda session,started:session.stop.is_set()
        try:call.run()
        finally:call.s.stop.set();call.close()
        self.assertEqual(call.s.reason,'takeover');self.assertTrue(all(x.closed for x in streams))
        self.assertEqual([x.options['samplerate'] for x in streams],[24000,24000])
        self.assertEqual([x.options['device'] for x in streams],[1,2])
        self.assertEqual(c.sent[0][1]['session']['audio']['output']['voice'], 'cedar')
        self.assertEqual(len(base64.b64decode(audio[0])),720*2)
        self.assertTrue(c.closed);self.assertTrue(call.finalized)
        self.assertIn('Arayan: Deneme.',call.s.transcript)
        self.assertEqual(c.sent[0][0],'session.start')
        greeting_commands=[fields for kind,fields in c.sent if kind=='session.instructions.append']
        self.assertEqual(len(greeting_commands),1)
        self.assertIn('Karşılama',greeting_commands[0]['content'])
        self.assertIn('do not wait for the caller',greeting_commands[0]['content'])
        self.assertEqual(greeting_commands[0]['event_id'],call.greeting_id)
        self.assertTrue(any(base64.b64decode(x)==bytes(720*2) for x in audio))

if __name__=='__main__':unittest.main()
