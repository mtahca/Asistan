import sys
import json
import threading
import unittest
from pathlib import Path
import httpx

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from llm import model_choices, require_keys, ModelChoice, OpenAIResponses, OpenAIError


def events(*values):
    return ''.join('event: ' + value.get('type', 'unknown') + '\ndata: ' + json.dumps(value, ensure_ascii=False) + '\n\n' for value in values).encode()


class ProviderTests(unittest.TestCase):
    def test_legacy_claude_configuration_is_preserved(self):
        call, summary = model_choices({'CLAUDE_MODEL':'claude-sonnet-5-5'})
        self.assertEqual(call, ModelChoice('anthropic', 'claude-sonnet-5-5'))
        self.assertEqual(summary, call)
        _, summary = model_choices({'SUMMARY_MODEL':'claude-sonnet-5-5'})
        self.assertEqual(summary.model, 'claude-sonnet-5-5')

    def test_haiku_55_can_be_backend_or_separate_summary_without_changing_defaults(self):
        choices = model_choices({'CLAUDE_MODEL':'claude-haiku-5-5'})
        self.assertEqual(choices[0], ModelChoice('anthropic', 'claude-haiku-5-5'))
        self.assertEqual(choices[0], choices[1])
        mixed = model_choices({'LLM_PROVIDER':'openai', 'SUMMARY_PROVIDER':'anthropic', 'SUMMARY_MODEL':'claude-haiku-5-5'})
        self.assertEqual(mixed[1], choices[0])
        self.assertEqual(model_choices({})[0].model, 'claude-haiku-4-5')

    def test_openai_only_does_not_require_anthropic_credentials(self):
        choices = model_choices({'LLM_PROVIDER':'openai', 'OPENAI_MODEL':'gpt-6-luna'})
        require_keys({'OPENAI_API_KEY':'test-key'}, choices)
        self.assertEqual(choices[0], choices[1])
        with self.assertRaisesRegex(RuntimeError, 'OpenAI'): require_keys({'ANTHROPIC_API_KEY':'key'}, choices)

    def test_cross_provider_summary_requires_both_keys(self):
        choices = model_choices({'LLM_PROVIDER':'openai', 'SUMMARY_PROVIDER':'anthropic', 'SUMMARY_MODEL':'claude-sonnet-5-5'})
        with self.assertRaisesRegex(RuntimeError, 'Anthropic'): require_keys({'OPENAI_API_KEY':'key'}, choices)
        require_keys({'OPENAI_API_KEY':'key', 'ANTHROPIC_API_KEY':'key'}, choices)

    def test_invalid_provider_or_model_pair_never_falls_back_silently(self):
        for values in ({'LLM_PROVIDER':'other'}, {'SUMMARY_PROVIDER':'other'},
                       {'LLM_PROVIDER':'openai', 'OPENAI_MODEL':'claude-haiku-4-5'},
                       {'LLM_PROVIDER':'openai', 'SUMMARY_MODEL':'claude-sonnet-5-5'},
                       {'SUMMARY_PROVIDER':'anthropic', 'SUMMARY_MODEL':'gpt-6-luna'}):
            with self.subTest(values=values), self.assertRaises(ValueError): model_choices(values)


class OpenAITransportTests(unittest.TestCase):
    def setUp(self): self.key = 'private-test-key-never-display'
    def client(self, handler):
        http = httpx.Client(transport=httpx.MockTransport(handler))
        self.addCleanup(http.close)
        return OpenAIResponses(self.key, 8, http)

    def test_stream_uses_responses_schema_and_only_speaks_text_deltas(self):
        captured=[]
        def handler(request):
            captured.append(request)
            return httpx.Response(200, content=events(
                {'type':'response.created'}, {'type':'response.reasoning_summary_text.delta','delta':'DO NOT SPEAK'},
                {'type':'response.output_text.delta','delta':'Merhaba. '},
                {'type':'response.output_text.delta','delta':'Mesajınızı alayım.'},
                {'type':'response.completed','response':{'status':'completed'}}))
        client = self.client(handler)
        with client.stream_text('gpt-6-luna', 'System', [{'role':'user','content':'Hi'}], 220, threading.Event()) as text:
            self.assertEqual(''.join(text), 'Merhaba. Mesajınızı alayım.')
        body=json.loads(captured[0].content)
        self.assertEqual(str(captured[0].url), 'https://api.openai.com/v1/responses')
        self.assertEqual(body['instructions'], 'System'); self.assertFalse(body['store'])
        self.assertTrue(body['stream']); self.assertEqual(body['reasoning'], {'effort':'none'})
        self.assertEqual(captured[0].headers['Authorization'], 'Bearer ' + self.key)
        self.assertNotIn('temperature', body)

    def test_sol_61_has_supported_reasoning_effort_and_output_budget(self):
        client=self.client(lambda request: httpx.Response(500))
        payload=client.payload('gpt-6.1-sol','system',[],220,True)
        self.assertEqual(payload['reasoning'], {'effort':'low'})
        self.assertGreaterEqual(payload['max_output_tokens'], 2048)
        self.assertEqual(client.payload('gpt-6-sol','system',[],220,True)['reasoning'], {'effort':'none'})

    def test_stream_failure_and_incomplete_response_are_errors(self):
        for kind in ('error', 'response.failed', 'response.incomplete', 'response.refusal.delta'):
            with self.subTest(kind=kind):
                client=self.client(lambda request: httpx.Response(200, content=events({'type':kind, 'message':self.key})))
                with self.assertRaises(OpenAIError) as result:
                    with client.stream_text('gpt-6-luna','',[],220,threading.Event()) as text: list(text)
                self.assertNotIn(self.key, str(result.exception))

    def test_truncated_or_empty_success_is_not_accepted(self):
        for content in (events({'type':'response.output_text.delta','delta':'Partial'}),
                        events({'type':'response.completed'}), b'data: {broken}\n\n'):
            client=self.client(lambda request: httpx.Response(200, content=content))
            with self.assertRaises(OpenAIError):
                with client.stream_text('gpt-6-luna','',[],220,threading.Event()) as text: list(text)

    def test_http_and_network_errors_do_not_disclose_credentials(self):
        for status in (401,403,404,429,500,302):
            client=self.client(lambda request: httpx.Response(status, json={'error':{'message':self.key}}, headers={'Location':'https://example.invalid/'}))
            with self.assertRaises(OpenAIError) as result:
                with client.stream_text('gpt-6-luna','',[],220,threading.Event()) as text: list(text)
            self.assertNotIn(self.key,str(result.exception))
        def fail(request): raise httpx.ReadTimeout(self.key, request=request)
        client=self.client(fail)
        with self.assertRaises(OpenAIError) as result: client.complete('gpt-6-luna','',[],700)
        self.assertNotIn(self.key,str(result.exception))

    def test_cancelled_request_does_not_contact_the_api(self):
        called=[]; client=self.client(lambda request: called.append(request))
        cancel=threading.Event(); cancel.set()
        with client.stream_text('gpt-6-luna','',[],220,cancel) as text: self.assertEqual(list(text), [])
        self.assertFalse(called)

    def test_interrupted_stream_closes_response_once(self):
        closed=[]
        class Stream(httpx.SyncByteStream):
            def __iter__(self):
                yield events({'type':'response.output_text.delta','delta':'First.'})
                yield events({'type':'response.output_text.delta','delta':'Second.'}, {'type':'response.completed'})
            def close(self): closed.append(True)
        client=self.client(lambda request: httpx.Response(200, stream=Stream()))
        cancel=threading.Event()
        with client.stream_text('gpt-6-luna','',[],220,cancel) as text:
            self.assertEqual(next(text), 'First.')
            cancel.set(); self.assertEqual(list(text), [])
        self.assertEqual(closed, [True])

    def test_summary_collects_text_and_requires_completed_status(self):
        captured=[]
        def handler(request):
            captured.append(json.loads(request.content))
            return httpx.Response(200, json={'status':'completed','output':[
                {'type':'reasoning','summary':[]},
                {'type':'message','content':[{'type':'output_text','text':'Konu: mesaj.'}]}]})
        client=self.client(handler)
        self.assertEqual(client.complete('gpt-6-luna','Summary',[{'role':'user','content':'Transcript'}],700), 'Konu: mesaj.')
        self.assertFalse(captured[0]['store']); self.assertFalse(captured[0]['stream'])
        client=self.client(lambda request: httpx.Response(200,json={'status':'incomplete','output':[]}))
        with self.assertRaises(OpenAIError): client.complete('gpt-6-luna','',[],700)

if __name__ == '__main__': unittest.main()
