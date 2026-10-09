"""Provider configuration and OpenAI Responses transport; no audio dependencies."""
from contextlib import contextmanager
from dataclasses import dataclass
import json
import threading

import httpx

OPENAI_MODELS = {"gpt-6-luna": "none", "gpt-6-sol": "none", "gpt-6.1-sol": "low"}
API_KEYS = {"anthropic": "ANTHROPIC_API_KEY", "openai": "OPENAI_API_KEY"}


@dataclass(frozen=True)
class ModelChoice:
    provider: str
    model: str


def model_choices(values: dict) -> tuple[ModelChoice, ModelChoice]:
    provider = values.get("LLM_PROVIDER", "anthropic").strip() or "anthropic"
    if provider not in API_KEYS:
        raise ValueError("Geçersiz model sağlayıcısı. Model ayarlarını kontrol edin.")
    model = (values.get("OPENAI_MODEL") or "gpt-6-luna") if provider == "openai" else (values.get("CLAUDE_MODEL") or "claude-haiku-4-5")
    summary_provider = values.get("SUMMARY_PROVIDER", "").strip() or provider
    if summary_provider not in API_KEYS:
        raise ValueError("Geçersiz özet sağlayıcısı. Model ayarlarını kontrol edin.")
    summary_model = values.get("SUMMARY_MODEL", "").strip()
    if not summary_model:
        summary_model = model if summary_provider == provider else ("gpt-6-luna" if summary_provider == "openai" else "claude-haiku-4-5")
    for choice in (ModelChoice(provider, model), ModelChoice(summary_provider, summary_model)):
        if choice.provider == "openai" and choice.model not in OPENAI_MODELS:
            raise ValueError("OpenAI model seçimi geçersiz. Model ayarlarını yeniden kaydedin.")
        if choice.provider == "anthropic" and not choice.model.startswith("claude-"):
            raise ValueError("Claude model seçimi geçersiz. Model ayarlarını yeniden kaydedin.")
    return ModelChoice(provider, model), ModelChoice(summary_provider, summary_model)


def require_keys(values: dict, choices: tuple[ModelChoice, ModelChoice]) -> None:
    for provider in sorted({choice.provider for choice in choices}):
        if not values.get(API_KEYS[provider], "").strip():
            title = "OpenAI" if provider == "openai" else "Anthropic"
            raise RuntimeError(title + " API anahtarı bulunamadı. Model ve API ayarlarından kaydedin.")


class OpenAIError(RuntimeError):
    """Errors shown to the user contain no server-supplied text or credentials."""


class OpenAIResponses:
    endpoint = "https://api.openai.com/v1/responses"

    def __init__(self, key: str, timeout: float, client=None):
        self.key = key
        self.client = client or httpx.Client(timeout=timeout, follow_redirects=False)

    def close(self):
        self.client.close()

    def payload(self, model: str, system: str, messages: list, max_tokens: int, stream: bool) -> dict:
        if model not in OPENAI_MODELS:
            raise OpenAIError("OpenAI model seçimi desteklenmiyor.")
        # Reasoning consumes output budget as well. Sol 6.1 cannot use effort=none.
        budget = max(max_tokens, 2048) if OPENAI_MODELS[model] == "low" else max_tokens
        return dict(model=model, instructions=system, input=messages, store=False,
                    stream=stream, max_output_tokens=budget,
                    reasoning={"effort": OPENAI_MODELS[model]}, text={"verbosity": "low"})

    def headers(self) -> dict:
        return {"Authorization": "Bearer " + self.key, "Content-Type": "application/json"}

    def check_status(self, response):
        code = response.status_code
        if 200 <= code < 300:
            return
        if code == 401: message = "OpenAI anahtarı kabul edilmedi. Anahtarı kontrol edin."
        elif code == 403: message = "OpenAI hesabının bu modele erişimi yok."
        elif code == 404: message = "OpenAI modeli bulunamadı veya hesap erişimi yok."
        elif code == 429: message = "OpenAI kota veya hız sınırına ulaşıldı. Hesap kullanımını kontrol edin."
        else: message = "OpenAI bağlantısı başarısız (HTTP " + str(code) + ")."
        raise OpenAIError(message)

    def _events(self, lines):
        data = []
        for line in lines:
            if line == "":
                if data:
                    raw = "\n".join(data); data = []
                    if raw == "[DONE]": return
                    try: event = json.loads(raw)
                    except (ValueError, TypeError): raise OpenAIError("OpenAI yanıt biçimi okunamadı.") from None
                    if isinstance(event, dict): yield event
            elif line.startswith("data:"):
                data.append(line[5:].lstrip(" "))
        # A partial final event must not be mistaken for a completed answer.

    def _text(self, response, cancel: threading.Event):
        completed = False; emitted = False
        for event in self._events(response.iter_lines()):
            if cancel.is_set(): return
            kind = event.get("type")
            if kind == "response.output_text.delta":
                delta = event.get("delta")
                if isinstance(delta, str) and delta:
                    emitted = True; yield delta
            elif kind == "response.completed":
                completed = True; break
            elif kind in ("error", "response.failed", "response.incomplete"):
                raise OpenAIError("OpenAI yanıtı tamamlanamadı; notlarınız korunuyor.")
            elif isinstance(kind, str) and kind.startswith("response.refusal"):
                raise OpenAIError("OpenAI bu yanıtı üretemedi; notlarınız korunuyor.")
        if not cancel.is_set() and (not completed or not emitted):
            raise OpenAIError("OpenAI tamamlanmış bir metin yanıtı döndürmedi.")

    @contextmanager
    def stream_text(self, model, system, messages, max_tokens, cancel):
        if cancel.is_set():
            yield iter(())
            return
        try:
            with self.client.stream("POST", self.endpoint, json=self.payload(model, system, messages, max_tokens, True), headers=self.headers()) as response:
                self.check_status(response)
                yield self._text(response, cancel)
        except httpx.HTTPError:
            raise OpenAIError("OpenAI bağlantısı kurulamadı veya zaman aşımına uğradı.") from None

    def complete(self, model, system, messages, max_tokens):
        try:
            response = self.client.post(self.endpoint, json=self.payload(model, system, messages, max_tokens, False), headers=self.headers())
            self.check_status(response)
            data = response.json()
        except httpx.HTTPError:
            raise OpenAIError("OpenAI bağlantısı kurulamadı veya zaman aşımına uğradı.") from None
        except ValueError:
            raise OpenAIError("OpenAI yanıt biçimi okunamadı.") from None
        if not isinstance(data, dict) or data.get("status") != "completed":
            raise OpenAIError("OpenAI yanıtı tamamlanamadı.")
        parts = [part.get("text", "") for item in data.get("output", []) if isinstance(item, dict) and item.get("type") == "message"
                 for part in item.get("content", []) if isinstance(part, dict) and part.get("type") == "output_text"]
        text = " ".join(part for part in parts if isinstance(part, str)).strip()
        if not text: raise OpenAIError("OpenAI boş bir metin yanıtı döndürdü.")
        return text
