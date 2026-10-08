# Asistan

macOS menü çubuğunda çalışan, yönlendirilen **FaceTime ve WhatsApp sesli aramalarını** sizin adınıza otomatik yanıtlayan yapay zekâ telefon asistanı. Arayanı tanır, adıyla karşılar, doğal Türkçe konuşur, not alır ve arama sonunda özet çıkarır. Görüşme sırasında canlı metni izleyebilir, talimat yazabilir, görüşmeyi devralabilir veya sonlandırabilirsiniz.

## Konuşma modları
| Mod | Nasıl çalışır |
|---|---|
| `classic` (varsayılan) | Yerel Whisper + dil modeli (Claude / OpenAI / Ollama) + yerel Türkçe ses |
| `realtime` | OpenAI Realtime, uçtan uca ses |
| `live` | OpenAI GPT-Live, çift yönlü; bilgi soruları isteğe bağlı olarak seçili dil modeliyle cevaplanır |

## Kurulum
1. Gereksinimler: Apple Silicon Mac, macOS 14.2+, Loopback (sanal ses aygıtları), Xcode komut satırı araçları.
2. `bash setup.sh` ile Python ortamını kurun, `bash build.sh` ile uygulamayı derleyin.
3. `.env.example` dosyasını `.env` olarak kopyalayın ya da uygulamadaki **Asistan ayarları** penceresinden model ve API anahtarlarını girin.
4. Ayrıntılar: [KURULUM.md](KURULUM.md) ve [AYARLAR.md](AYARLAR.md).

## iPhone'dan izleme
Canlı metin penceresi iPhone'daki **Asistan Canlı** uygulamasından da izlenebilir ([Asistan-Mobile](https://github.com/mtahca/Asistan-Mobile)). Telefondan asistana talimat yazılabilir ve görüşme sonlandırılabilir. Menüden **iPhone'dan izle…** → **Aç** seçilir, gösterilen 8 haneli kod iPhone'a girilir. Bağlantı yalnızca yerel ağdadır ve bu kodla şifrelenir (TLS-PSK). Özellik varsayılan olarak kapalıdır.

## Gizlilik
API anahtarları ve kişisel veriler (`.env`, notlar, günlükler, ses kayıtları) bu depoya dahil değildir; `.gitignore` bunları dışarıda tutar. Görüşme metni ve arayan bilgisi, seçilen sağlayıcıya (Anthropic / OpenAI) yanıt ve özet için gönderilir.
