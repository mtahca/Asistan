# -*- coding: utf-8 -*-
"""
OpenAI GPT-Live (tam dupleks sesli model) konuşma modu — DENEYSEL.

.env'de CONVERSATION_MODE=live ise kullanılır. Kurulamazsa agent.py klasik hatta döner.
Bağlantı: wss://api.openai.com/v1/live/sessions  (model ilk mesajdaki session.start içinde).
Delegasyon kullanılmaz (client modu, arka uç yok): ses faturası dakikada sabit, ek model ücreti yok.

Ayarlar (.env, isteğe bağlı):
  LIVE_MODEL=gpt-live-1      LIVE_VOICE=marin      LIVE_AUTO_END=1 (vedalaşma tespit edilince görüşmeyi bitir)
  RT_MAX_MIN=10              (en uzun görüşme süresi)
"""
from __future__ import annotations

import base64
import json
import os
import re
import threading
import time

import numpy as np
import sounddevice as sd

import realtime_mode as R

LIVE_URL = os.getenv("LIVE_URL", "wss://api.openai.com/v1/live/sessions").strip()
LIVE_MODEL = os.getenv("LIVE_MODEL", "gpt-live-1").strip()
LIVE_DELEGATION = os.getenv("LIVE_DELEGATION", "client").strip().lower()   # client | off
LIVE_VOICE = os.getenv("LIVE_VOICE", "marin").strip()
LIVE_AUTO_END = os.getenv("LIVE_AUTO_END", "1") == "1"
LIVE_GREETING = os.getenv("LIVE_GREETING", "local").strip().lower()   # local = hazır yerel karşılama sesi (anında) | model = Live söylesin (arayanın konuşmasını bekleyebilir)

BYE_USER = re.compile(r"hoşça|görüşürüz|görüşmek üzere|iyi günler|kapatıyorum|sonlandır|bitir|kapat|bu kadar", re.I)
BYE_BOT = re.compile(r"hoşça\s?kal|hoşçakal|görüşmek üzere|iyi günler|kolay gelsin|iyi akşamlar|kapatıyorum|sonlandırıyorum", re.I)


class LiveConversation(R.RealtimeConversation):
    def __init__(self, agent):
        super().__init__(agent)
        self.cur_in = ""
        self.cur_out = ""
        self.last_in_t = None
        self.last_out_t = 0.0
        self.last_text_t = time.time()
        self.arm_at = 0.0               # karşılama sesi bu andan önce kesilemez
        self.last_voice_t = 0.0        # arayanın sesinin (yerel enerji ölçümü) son duyulduğu an
        self.bye_user = False
        self.cur_in_t0 = None
        self.last_out_text = ""
        self.last_out_text_t = 0.0
        self.cur_out_t0 = None
        self.last_out_delta_t = 0.0
        self.bye_user_t = 0.0           # arayanın vedalaşma ifadesinin son görüldüğü an (parçalı dökümlere dayanıklı)
        self.bye_bot = False

    # -- yardımcılar -----------------------------------------------------
    def _live_instructions(self) -> str:
        M = self.M
        p = self.a.system_prompt
        p = p.replace(f" ve cevabının EN SONUNA {M.END_TOKEN} yaz", "").replace(f" ve sonuna {M.END_TOKEN} yaz", "")
        p = p.replace(f"{M.LLM_MODEL} ({M.LLM_PROVIDER})", f"{LIVE_MODEL} (openai live)")
        if LIVE_DELEGATION == "client":
            deleg = ("Sohbeti ve basit genel bilgi sorularını (mesafe, tarih, tanım gibi) kendin hemen cevapla, \"bakıyorum\" deme. "
                     "Yalnızca cevabından emin olmadığın ya da araştırma gerektiren sorularda arka uca devret; "
                     "devredersen sessizce bekle, cevap gelince aynen ilet. ")
        else:
            deleg = ("Hiçbir işi arka uca devretme, araştırma yapma, \"bakıyorum/bir saniye\" deme; "
                     "bilmediğin ya da bakman gereken bir şey sorulursa hemen \"Bunu bilmiyorum, Mehmet Başkanıma ileteyim\" de ve konuya devam et. ")
        p += ("\nSesli görüşme kuralları: Yalnızca Türkçe konuş. Doğal ve sakin konuş, sohbet eder gibi; gereksiz uzatma. "
              "Anlaşılmayan, gürültü gibi ya da boş sesleri cevaplama. " + deleg +
              "Vedalaşmak gerekirse net bir veda cümlesi söyle (ör. \"hoşça kalın\").\n")
        return p

    def _backend_answer(self, delegation_id: str) -> None:
        """Live'ın devrettiği soruyu Claude hattıyla (agent.llm) yanıtlar; sonucu commentary olarak geri verir."""
        M = self.M
        t0 = time.time()
        try:
            time.sleep(0.25)                     # son transkript parçaları gelsin
            lines = [e[1] for e in sorted(self.entries, key=lambda e: e[0])][-8:]
            pending = (self.cur_in or "").strip()
            if pending:
                lines.append(f"Arayan: {pending}")
            ctx = "\n".join(lines) if lines else "(görüşme metni yok)"
            owner = M.OWNER
            prompt = (f"Sen {owner} Bey'in (ona 'Mehmet Başkanım' de) telefon asistanısın; yapay zekâsın, arayan biriyle konuşuyorsun. "
                      "Aşağıdaki görüşmede arayanın EN SON sorduğuna SESLİ SÖYLENECEK, 1-2 kısa cümlelik Türkçe cevap yaz. "
                      "Genel bilgi sorularına (mesafe, tarih, hava durumu hariç canlı veri, basit bilgi) kendi bilginle kısaca ve doğrudan cevap ver; "
                      "emin değilsen 'yaklaşık' de. Mehmet'in özel bilgisi (nerede, ne yapıyor, program, telefon) sorulursa söyleme: "
                      "'Bunu paylaşamam, Mehmet Başkanıma ileteyim' de. Canlı veriye (anlık hava, haber) erişimin olmadığını belirt. "
                      "Soru yoksa ya da anlaşılmıyorsa tek cümleyle tekrar sor. Karşı soru sorma, açıklama ekleme.\n\nGörüşme:\n" + ctx)
            ans = (self.a.llm.complete(prompt, 100) or "").replace(M.END_TOKEN, "").strip()
            paras = [p.strip() for p in re.split(r"\n\s*\n", ans) if p.strip()]
            if len(paras) > 1:
                ans = paras[-1]          # model önce düşünce yazdıysa yalnızca söylenecek son kısmı al
            if not ans:
                ans = "Bunu bilmiyorum, Mehmet Başkanıma ileteyim."
        except Exception as e:
            M.log(f"   arka uç hatası: {e!r}")
            ans = "Bunu şu an bakamıyorum, Mehmet Başkanıma ileteyim."
        self._send({"type": "session.commentary.append", "event_id": f"dlg_{int(time.time() * 1000)}",
                    "delegation_id": delegation_id, "content": ans})
        M.log(f"   (arka uç cevabı, {time.time() - t0:.1f} sn): {ans}")

    def _flush_line(self, who: str) -> None:
        M = self.M
        if who == "in" and self.cur_in.strip():
            text = M.collapse_repeats(self.cur_in.strip())
            if self.ct is None:
                self._caller_line(self.cur_in_t0 or time.time(), text)
            else:
                self._note_model_text(self.cur_in_t0 or time.time(), text)
                M.log(f"   (model dökümü, ekranda gösterilmiyor: {text})")
            self.cur_in_t0 = None
            if BYE_USER.search(text):
                self.bye_user_t = time.time()
                if self.last_out_text and BYE_BOT.search(self.last_out_text) and time.time() - self.last_out_text_t < 8:
                    self.bye_bot = True
            elif len(text.split()) >= 4:
                self.bye_user_t = 0.0          # vedalaşma değil, asıl konuşma sürüyor
                self.bye_bot = False
            self.cur_in = ""
        elif who == "out" and self.cur_out.strip():
            text = M.clean_for_speech(self.cur_out.strip())
            self.cur_out = ""
            if not text:
                return
            M.log(f"ASİSTAN: {text}")
            if self.greet_pending and self.entries:
                self.entries[0][1] = f"Asistan: {text}"
            else:
                self._add(self.cur_out_t0 or time.time(), f"Asistan: {text}")
            self.cur_out_t0 = None
            self.greet_pending = False
            self.last_out_text = text
            self.last_out_text_t = time.time()
            self.bye_bot = bool(BYE_BOT.search(text) and time.time() - self.bye_user_t < 15)

    def _caller_line(self, t: float, text: str) -> None:
        super()._caller_line(t, text)
        if BYE_USER.search(text):
            self.bye_user_t = time.time()
            if self.last_out_text and BYE_BOT.search(self.last_out_text) and time.time() - self.last_out_text_t < 8:
                self.bye_bot = True

    def _append_instructions(self, content: str) -> None:
        self._send({"type": "session.instructions.append", "event_id": f"ins_{int(time.time() * 1000)}",
                    "delegation_id": None, "content": content})

    def _in_cb(self, indata, frames, time_info, status):
        try:
            mono = indata.mean(axis=1)
            if float(np.sqrt(np.mean(mono ** 2))) > self.M.VAD_THRESHOLD:
                self.last_voice_t = time.time()
        except Exception:
            pass
        super()._in_cb(indata, frames, time_info, status)

    # -- bağlantı --------------------------------------------------------
    def _connect_live(self) -> None:
        from websockets.sync.client import connect
        key = os.environ["OPENAI_API_KEY"]
        hdr = {"Authorization": f"Bearer {key}"}
        try:
            self.ws = connect(LIVE_URL, additional_headers=hdr, open_timeout=8, max_size=None)
        except TypeError:
            self.ws = connect(LIVE_URL, extra_headers=hdr, open_timeout=8, max_size=None)
        sess = {
            "model": LIVE_MODEL,
            "instructions": self._live_instructions(),
            "audio": {"format": {"type": "audio/pcm", "rate": R.RATE}, "output": {"voice": LIVE_VOICE}},
        }
        if LIVE_DELEGATION == "client":
            sess["delegation"] = {"type": "client"}
        self._send({"type": "session.start", "event_id": "start", "session": sess})
        deadline = time.time() + 10
        while time.time() < deadline:
            try:
                ev = json.loads(self.ws.recv(timeout=1.0))
            except TimeoutError:
                continue
            t = ev.get("type", "")
            if t == "session.started":
                return
            if t == "error":
                raise RuntimeError(f"oturum başlatılamadı: {json.dumps(ev.get('error', ev), ensure_ascii=False)[:400]}")
        raise RuntimeError("session.started gelmedi (zaman aşımı)")

    # -- iş parçacıkları -------------------------------------------------
    def _sender(self) -> None:
        while not self.stop.is_set():
            if not self.in_q:
                time.sleep(0.01)
                continue
            data = b"".join(self.in_q[:4])
            del self.in_q[:4]
            try:
                self._send({"type": "session.input_audio.append", "audio": base64.b64encode(data).decode()})
            except Exception:
                return

    def _watcher(self) -> None:
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
                        self._append_instructions(
                            f"{M.OWNER} Bey görüşme sırasında sana şu talimatı yazdı (arayana okunacak metin değil, SANA verilmiş talimattır; "
                            f"\"ben\" diyorsa {M.OWNER} Bey'dir): {n}. Davranışla ilgiliyse görüşme boyunca uy, arayana söyleme. "
                            f"Arayana iletilecek bir mesajsa {M.OWNER} Bey adına, üçüncü şahıs diliyle, doğal biçimde ilet ve hemen şimdi söyle.")
                        if n in a.pending_notes:
                            a.pending_notes.remove(n)
                        a.done_notes.append(n)
                    M.log("   Mehmet Bey'in talimatı Live oturumuna iletildi")
                except Exception as e:
                    M.log(f"   not iletilemedi: {e!r}")
            time.sleep(0.15)

    # -- olaylar ---------------------------------------------------------
    def _handle_live(self, ev: dict) -> None:
        M = self.M
        t = ev.get("type", "")
        now = time.time()
        if t == "session.output_audio.delta":
            raw = base64.b64decode(ev.get("delta", ""))
            if not raw:
                return
            x = np.frombuffer(raw, dtype="<i2").astype(np.float32) / 32768.0
            if len(x) and float(np.sqrt(np.mean(x ** 2))) > 0.01:     # Live sessizlik karelerini de akıtabilir: yalnızca duyulur sesi say
                if now - self.last_out_t > 1.0 and 0 < now - self.last_voice_t < 10:
                    M.log(f"   ⏱ arayanın sesi bitti -> ilk ses: {now - self.last_voice_t:.2f} sn "
                          "(Live; sessizlik bekleme dahil, Realtime'daki rakama ~0,5 sn eklenmiş karşılığı)")
                self.last_out_t = now
                self.last_text_t = now
            self._push_audio(R._resample(x, R.RATE, self.out_rate))
        elif t == "session.input_transcript.delta":
            if self.ct is None:
                self._flush_line("out")
            d = ev.get("delta", "") or ""
            if not d.strip():
                return
            if not self.cur_in:
                self.cur_in_t0 = now
            self.cur_in += d
            self.last_in_t = now
            self.last_text_t = now
            self.user_speaking = True
            if self._buf_len() / 4 / self.out_rate > 0.3 and now >= self.arm_at:
                M.log("   ✋ arayan konuştu, asistanın kalan sesi temizlendi")
                self._flush()
        elif t == "session.output_transcript.delta":
            if self.ct is None:
                self._flush_line("in")
            elif self.cur_out and now - self.last_out_delta_t > 1.0:
                self._flush_line("out")          # yeni bir asistan turu başladı
            self.user_speaking = False
            if not self.cur_out:
                self.cur_out_t0 = now
            self.cur_out += ev.get("delta", "") or ""
            self.last_out_delta_t = now
            self.last_text_t = now
        elif t == "session.usage.updated":
            u = ev.get("usage") or {}
            if u.get("seconds") is not None and int(u["seconds"]) % 30 == 0:
                M.log(f"   (kullanım: {u.get('seconds')} sn)")
        elif t == "session.delegation.created":
            d = ev.get("delegation") or {}
            M.log(f"   (devretme isteği: {json.dumps(ev, ensure_ascii=False)[:300]})")
            did = d.get("id")
            if LIVE_DELEGATION == "client" and did:
                threading.Thread(target=self._backend_answer, args=(did,), daemon=True).start()
            else:
                self._append_instructions("Arka uç yok; araştırma yapılamaz. Bekletme. Şimdi tek cümleyle, bilmediğini söyle "
                                          "(\"Bunu bilmiyorum, Mehmet Başkanıma ileteyim\") ya da elindeki bilgiyle kısaca cevapla.")
        elif t == "session.closed":
            M.log(f"   Live oturumu kapandı: {json.dumps(ev, ensure_ascii=False)[:200]}")
            self.reason = "kapandi"
            self.stop.set()
        elif t == "error":
            M.log(f"   Live hatası: {json.dumps(ev.get('error', ev), ensure_ascii=False)[:400]}")

    # -- ana akış --------------------------------------------------------
    def run(self, transcript: list) -> bool:
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
            self._connect_live()
        except Exception as e:
            M.log(f"   Live bağlantısı kurulamadı: {e!r}")
            self._close()
            return False
        M.log(f"   Live bağlandı ({LIVE_MODEL}, ses: {LIVE_VOICE}, {time.time() - t_begin:.1f} sn)")

        self.out_rate = int(sd.query_devices(a.out_idx)["default_samplerate"])
        if pg is not None:
            pg.join(timeout=2.5)
        text = holder.get("text") or M.GREETING_TEXT
        transcript[0] = f"Asistan: {text}"
        self.transcript = transcript
        self.entries = [[time.time(), transcript[0]]]
        if R.CALLER_STT != "model":
            self.ct = R.CallerTranscriber(self)
        audio = holder.get("audio") if holder.get("audio") is not None else a.greeting_audio
        local_greet = LIVE_GREETING != "model" and audio is not None
        self.greet_pending = not local_greet
        self.gate_open_at = 0.0

        out_stream = sd.OutputStream(device=a.out_idx, channels=2, samplerate=self.out_rate, dtype="float32",
                                     callback=self._out_cb)
        frame_len = int(a.in_rate * M.FRAME_S)
        in_stream = sd.InputStream(device=a.in_idx, channels=2, samplerate=a.in_rate, blocksize=frame_len,
                                   dtype="float32", callback=self._in_cb)
        out_stream.start()
        in_stream.start()
        threading.Thread(target=self._sender, daemon=True).start()
        threading.Thread(target=self._watcher, daemon=True).start()
        try:
            if local_greet:
                dur = len(audio) / a.voice.rate
                self._append_instructions("Aramayı cevapladın ve karşılama cümlesini zaten söyledin: "
                                          f"\"{text}\" Şimdi arayanı dinle ve cevap ver; karşılamayı tekrar etme.")
                self._push_audio(R._resample(audio, a.voice.rate, self.out_rate))
                now = time.time()
                self.arm_at = now + (M.GREETING_ARM_S if M.GREETING_BARGE_IN else dur + 1.0)
                self.last_out_t = now + dur
                self.last_text_t = now + dur
                M.log(f"   karşılama çalınıyor ({dur:.1f} sn, yerel ses)")
            else:
                self._append_instructions("Aramayı şimdi cevapladın. Önce şu karşılama cümlesini AYNEN, hiçbir şey ekleyip "
                                          f"çıkarmadan söyle, sonra arayanı dinle: {text}")
                # "commentary" modelin sesli söylemesi amaçlanan bilgidir: arayan konuşmadan karşılamayı başlatmayı dener
                self._send({"type": "session.commentary.append", "event_id": f"com_{int(time.time() * 1000)}",
                            "delegation_id": None, "content": f"Karşılama cümlesi (hemen, aynen söyle): {text}"})
                M.log("   karşılamayı Live söylüyor")
        except Exception as e:
            M.log(f"   karşılama gönderilemedi: {e!r}")
        self.last_in_t = time.time()
        if not local_greet:
            self.last_text_t = time.time()

        started = time.time()
        bye_at = None
        try:
            while not self.stop.is_set():
                try:
                    ev = json.loads(self.ws.recv(timeout=0.2))
                    self._handle_live(ev)
                except TimeoutError:
                    pass
                except Exception as e:
                    M.log(f"   Live bağlantısı koptu: {e!r}")
                    self.reason = "baglanti"
                    break
                now = time.time()
                buf_empty = self._buf_len() == 0
                if self.cur_in and now - self.last_in_t > 1.0:
                    self._flush_line("in")
                if self.cur_out and now - self.last_text_t > 1.2:
                    self._flush_line("out")
                small = self._buf_len() / 4 / self.out_rate < 0.3      # Live sessizlik akıtsa da tampon neredeyse boş
                if LIVE_AUTO_END and self.bye_bot and time.time() - self.bye_user_t < 20 and small and now - self.last_out_t > 1.2:
                    if bye_at is None:
                        bye_at = now
                    elif now - bye_at > 0.8:
                        M.log("Asistan görüşmeyi bitirdi.")
                        self.reason = "bitti"
                        break
                else:
                    bye_at = None
                if now - started > R.RT_MAX_MIN * 60:
                    M.log(f"   görüşme {R.RT_MAX_MIN:.0f} dakikayı aştı; oturum bitiyor")
                    break
                limit = M.FIRST_WAIT_S if len(self.entries) <= 1 else M.IDLE_WAIT_S
                if small and now - max(self.last_text_t, self.last_out_t) > limit:
                    M.log("Arayandan ses gelmedi, oturum bitiyor.")
                    break
        finally:
            self.stop.set()
            self._flush_line("in")
            self._flush_line("out")
            if self.ct is not None:
                self.ct.close(8.0)
            transcript[:] = [e[1] for e in sorted(self.entries, key=lambda e: e[0])]
            try:
                self._send({"type": "session.close", "event_id": "close"})
                time.sleep(0.3)
            except Exception:
                pass
            for s in (in_stream, out_stream):
                try:
                    s.stop()
                    s.close()
                except Exception:
                    pass
            self._close()

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
