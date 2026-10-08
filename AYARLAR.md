# Asistan — .env ayarları

Dosya: `.env` (geliştirmede proje klasörü, kurulu uygulamada `~/Library/Application Support/Asistan/.env`).
Değişiklik için uygulamayı kapatıp açmak (ya da menüden "Asistanı yeniden başlat") yeterlidir.

| Ayar | Varsayılan | Açıklama |
|---|---|---|
| `ANTHROPIC_API_KEY` | — | Zorunlu. |
| `OWNER_NAME` | Mehmet | "… Bey" olarak kullanılır. Değiştirirsen karşılama TTS ile yeniden üretilir. |
| `LLM_PROVIDER` | anthropic | `anthropic` ya da `openai`. Menü > Asistan ayarları penceresinden seçilir. |
| `LLM_MODEL` | claude-haiku-4-5 / gpt-4.1-mini | Konuşmayı yöneten model (eski ad `CLAUDE_MODEL` hâlâ okunur). |
| `OPENAI_API_KEY` | — | OpenAI seçildiyse zorunlu. |
| `KEEPWARM_S` | 90 | Boşta beklerken STT/TTS'i bu aralıkla ısıt (ilk turun 5-8 sn sürmesini önler). 0 = kapalı. |
| `SPEC_STT` | 1 | Arayan susar susmaz (bitiş sessizliği dolmadan) konuşma tanımayı başlat. 0 = kapalı. |
| `SPEC_SILENCE_S` | 0.2 | Erken STT için gereken sessizlik. |
| `GREETING_TEXT` | (sabit metin) | Karşılama cümlesi. Değiştirilirse TTS ile üretilip `sesler_cache/` içine alınır. |
| `GREETING_DELAY_S` | 3.0 | Arama açıldıktan sonra karşılamadan önce bekleme. |
| `GREETING_BARGE_IN` | 1 | Karşılama sırasında arayan konuşursa karşılamayı kes (0 = kapalı). |
| `GREETING_ARM_S` | 2.5 | Karşılamanın ilk N saniyesinde araya girme kapalı (hat açılış gürültüsü). |
| `NOTE_IDLE_S` | 2.0 | Bekleyen not varsa, arayan bu kadar sustuğunda not kendiliğinden iletilir. |
| `API_TIMEOUT_S` | 12 | Claude isteği zaman aşımı; aşılırsa arayana "bağlantıda sorun oldu" denir. |
| `VAD_THRESHOLD` | 0.006 | Konuşma algılama eşiği (RMS). Şu an .env'de 0.0015. |
| `END_SILENCE_S` | 0.6 | Konuşma bitti sayılacak sessizlik. |
| `BARGE_IN` / `BARGE_FRAMES` / `BARGE_FACTOR` | 1 / 10 / 1.5 | Araya girme: açık mı, kaç çerçeve (30 ms) konuşma gerekir, eşik çarpanı. |
| `FIRST_WAIT_S` / `IDLE_WAIT_S` | 30 / 25 | Karşılamadan / cevaptan sonra arayanı bekleme süresi. |
| `MAX_TURNS` | 25 | En fazla cevap sayısı. |
| `STT_BACKEND` / `WHISPER_MODEL` | mlx / whisper-large-v3-turbo | Konuşma tanıma. |
| `TTS_DEVICE` | cpu | EMA Lightning cihazı; M4'te `mps` denenebilir. |

## AUTO_HANGUP
`AUTO_HANGUP=1` (varsayılan): asistan görüşmeyi kendisi bitirince (bilgileri aldıktan veya arayan vedalaştıktan sonra) arama otomatik kapatılır.
`AUTO_HANGUP=0`: arama açık kalır; ses Mac'in mikrofon ve hoparlörüne döner.

## HITAP
Rehberde "Aşkım" gibi takma adla kayıtlı kişilere gerçek adıyla hitap için: `HITAP=Aşkım=Tuba Hanım; Anne=Ayşe Hanım` (Rehber adı=Hitap, `;` ile ayrılır). Asistan Asistan ayarları ekranındaki "Özel hitaplar" alanından da yazılır. Eşleşen arayana "Merhaba Tuba Hanım, …" diye karşılar.

## Yerel model (Ollama)
`LLM_PROVIDER=ollama`, `LLM_MODEL=qwen2.5:7b` (ya da gemma3:12b …). API anahtarı gerekmez. Ollama'yı ollama.com'dan kur; Asistan ayarları > "Modeli indir" ilk indirmeyi yapar. `OLLAMA_URL` varsayılan http://localhost:11434/v1.

## Talimatlar
Menü > "Talimatlar…" (⌘T). Genel kurallar `talimat_genel.txt` dosyasına, bugünün durumu `talimat_bugun.json` dosyasına yazılır (bugün dışındaki tarihli not yok sayılır). Bir sonraki aramada geçerli olur.


## Ses hattı (Loopback)
- `IN_DEVICE` (varsayılan `Asistan Dinleme`), `OUT_DEVICE` (varsayılan `Asistan Ses Çıkışı`): ajanın kullandığı Loopback aygıtları. Adlar NFC/NFD fark etmeksizin eşleşir; aynı ada sahip birden fazla aygıt varsa hata verir.
- `HUMAN_MIC`: Devral ve mikrofon köprüsünde kullanılacak fiziksel mikrofon adı (boşsa uygulamanın Ses ayarlarındaki seçimi, o da yoksa yerleşik mikrofon).
- WhatsApp sesli aramaları FaceTime ile aynı şekilde cevaplanır (gelen sesli arama penceresi: "WhatsApp audio call" + Accept/Decline). Görüntülü aramalar cevaplanmaz. Otomatik kapatma WhatsApp'ta "leave call / hang up" düğmesiyle yapılır.

## Konuşma modu: klasik ya da OpenAI Realtime

Varsayılan **klasik** hattır (Whisper → LLM → yerel ses). İstediğin zaman `.env` dosyasına şunu yazarak **Realtime** (uçtan uca sesli model) moduna geçebilirsin; silince ya da `classic` yapınca eski hatta dönersin. Değişiklikten sonra menüden "Asistanı yeniden başlat".

| Değişken | Varsayılan | Açıklama |
|---|---|---|
| `CONVERSATION_MODE` | `classic` | `realtime` = OpenAI Realtime. Kurulamazsa o arama için otomatik klasik hatta döner. |
| `RT_MODEL` | `gpt-realtime` | Daha ucuz: `gpt-realtime-mini`. |
| `RT_VOICE` | `marin` | Ör. `cedar`, `alloy`, `coral`, `sage`, `verse`. |
| `RT_VAD` | `server` | `semantic` = cümlenin bittiğini anlamaya dayalı. |
| `RT_VAD_THRESHOLD` / `RT_SILENCE_MS` | `0.6` / `500` | Konuşma algılama eşiği ve bitiş sessizliği (ms). |
| `RT_MAX_MIN` | `10` | Bir görüşmenin en uzun süresi (maliyet güvenliği). |

Gereksinimler: `OPENAI_API_KEY` ve `websockets` paketi:
`cd ~/Documents/Claude/Asistan && .venv/bin/python -m pip install "websockets>=13"`

Notlar: karşılama yine yerel (önbellekli) sesle çalar; Mehmet Bey'in yazdığı talimatlar, Devral/Sonlandır ve not/özet çalışır. Arayanın sesi OpenAI'a gönderilir. Görüşme sırasında bağlantı koparsa o arama sonlanır.

### GPT-Live (deneysel)

`CONVERSATION_MODE=live` → OpenAI GPT-Live (tam dupleks sesli model, `wss://api.openai.com/v1/live/sessions`). Ses oturumu dakikada sabit ~$0,05; arka uç kullanılmaz (ek model ücreti yok). Aynı `websockets` paketi ve `OPENAI_API_KEY` gerekir.

| Değişken | Varsayılan | Açıklama |
|---|---|---|
| `LIVE_MODEL` | `gpt-live-1` | |
| `LIVE_VOICE` | `marin` | |
| `LIVE_AUTO_END` | `1` | Arayan ve asistan vedalaşınca görüşmeyi bitirir (modelde bitirme aracı yok; metne dayalı tespit). |

Sınırlar: araya girmede yerel ses tamponu arayanın konuşması algılanınca temizlenir (Live'da ayrı bir "kes" olayı belgelenmemiş); kapanış tespiti kelimeye dayalıdır. Sorun olursa `CONVERSATION_MODE`'u `realtime` ya da `classic` yap.
`LIVE_GREETING=local` (varsayılan): karşılama hazır yerel sesle hemen çalar, model bağlamı bilir. `model`: Live söyler ama arayan konuşana kadar başlamayabilir.

## Rahatsız Etme'de otomatik cevap
Menü: "Rahatsız Etme açıkken otomatik cevapla" (varsayılan açık). Mac'te bir Odak modu (Rahatsız Etme dahil) etkinse gelen arama onay beklenmeden asistanla cevaplanır. Durum ~/Library/DoNotDisturb/DB/Assertions.json'dan okunur; okunamazsa app.log'a "Odak durumu okunamadı" yazılır ve Asistan'a Tam Disk Erişimi verilmesi gerekir.

## GPT-Live arka uç (delegation)
`LIVE_DELEGATION=client` (varsayılan): Live bilgi gerektiren soruyu devredince Claude hattı (`LLM_MODEL`) cevaplar, sonuç `session.commentary.append` ile geri verilir. `LIVE_DELEGATION=off`: devretme kapalı talimatı, "bilmiyorum, ileteyim" davranışı. Log: "devretme isteği" ve "arka uç cevabı".

## Son sürüm iyileştirmeleri (2026-10-08)
- **Asistan ayarları penceresi:** "Konuşma modu" (Klasik / OpenAI Realtime / GPT-Live), Realtime modeli, GPT-Live arka ucu açma-kapama ve **Bağlantıyı sına** düğmesi (kayıtlı model ve anahtarlarla kısa gerçek istekler; küçük API ücreti çıkabilir). Seçimler `.env`'e yazılır (`CONVERSATION_MODE`, `RT_MODEL`, `LIVE_DELEGATION`). Dil modeli listesinde Claude Haiku 4.5 ve 5.5 ile GPT-6 Luna/Sol var; Haiku 4.5 hâlâ telefon için önerilen kararlı seçenek.
- **Menü:** Sık kullanılanlar üstte; canlı metin, mikrofon köprüsü, oturum açılışı, günlük, tanı ve yeniden başlatma "Diğer seçenekler" altında. Devral/Sonlandır yalnızca görüşmedeyken etkin.
- **Arama karşılamayı duraklat:** Açıkken gelen aramalar karşılanmaz, panel çıkmaz (menü ⌘P benzeri kısayol: p).
- **Durum satırı:** "Hazır — GPT-Live (gpt-live-1) · arka uç claude-haiku-4-5" gibi aktif mod ve modeli gösterir.
- **Canlı pencere:** Başlıkta arayan ve süre; Gönder/Devral/Sonlandır ve not alanı görüşme yokken kapalı; önceki aramadan kalan taslak yeni aramaya taşınmaz.
- **Özet güvenliği:** Özet 3 kez denenir; olmazsa iş `summary_jobs/` altında saklanır ve asistan açılınca yeniden denenir. Not dosyası özet gelene kadar "Özet hazırlanıyor…" der.
- **Günlük:** 1 MB'ı aşınca `app.log.previous`'a döner (silinmez), dosya izni 600.
- **Yedek:** Bu sürümden önceki çalışan hâl `yedek/calisan_surum_2026-10-08/` içinde. Geri dönmek için o klasördeki `app/`, `agent.py`, `live_mode.py`, `realtime_mode.py` dosyalarını proje köküne kopyalayıp `bash build.sh` çalıştır.
