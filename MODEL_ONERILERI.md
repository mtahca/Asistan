# Model seçenekleri

Bu belge uygulamadaki seçenekleri açıklar; modellerin Türkçe görüşmelerde birbirine üstünlüğünü gösteren bir ölçüm değildir. Hesap erişimini Kurulum ve durum ekranından kontrol edin.

## Ses modları

**Yerel ses** Whisper Large v3 Turbo veya Large v3 ile konuşmayı tanır, seçili metin modeliyle yanıt üretir ve Türkçe EMA ile seslendirir. Yerel modeller ilk kurulumda indirilir. **GPT-Live 1** sesin dinlenmesi ve üretilmesini OpenAI'ye taşır; arka plan ve özet için seçili metin modeli kullanılır. Mod değiştirmek Loopback hattını değiştirmez.

GPT-Live için OpenAI API anahtarı gerekir. Claude arka plan/özet kullanılırsa Anthropic anahtarı da gerekir. GPT-Live modunda Whisper/EMA yüklenmez; yalnızca çevrimiçi ortam kurulmuş Mac'te yerel moda dönmeden önce yerel kurulum tamamlanmalıdır.

## Metin modelleri

| Sağlayıcı | Seçenekler | Uygulamadaki kullanım |
|---|---|---|
| Anthropic | Claude Haiku 4.5, Haiku 5.5, Sonnet 5.5 | Görüşme/arka plan ve özet |
| OpenAI | GPT-6 Luna, GPT-6 Sol, GPT-6.1 Sol | Görüşme/arka plan ve özet |

Varsayılan Haiku 4.5 seçimi korunur. Haiku 5.5 kısa yanıtlar için düşünme kapalı/düşük effort ile çağrılır. OpenAI Luna/Sol düşünme kapalı, GPT-6.1 Sol düşük düşünmeyle çağrılır. Gereken anahtarları uygulamanın gizli alanlarına girin; sohbette veya Git dosyalarında paylaşmayın.

## GPT-Live sesleri

Marin, Cedar, Alloy, Ash, Ballad, Beacon, Bossa, Brise, Cinder, Coral, Delta, Echo, Flitz, Gleam, Harema, Juni, Meridian, Nira, Noeul, Nuri, Quartz, Ripple, Sage, Shida, Shimmer, Sillage, Stone, Tempo, Verse, Vesper ve Willow seçilebilir. Varsayılan Marin'dir. Kaydet ve uygula sonraki görüşmede kullanılır; etkin görüşmenin sesi değiştirilmez.

Karşılaştırırken aynı Türkçe cümlelerle isim/numara doğruluğunu, ilk sesi duyma gecikmesini, araya girince susma süresini, notların iletimini ve özet doğruluğunu değerlendirin. Sessiz API bağlantı testi ses kalitesini doğrulamaz. Gerçek ücret ve erişim sağlayıcının hesabına/modeline bağlıdır.

Belgeler: [OpenAI Live](https://developers.openai.com/api/docs/guides/live-conversations), [ses seçenekleri](https://developers.openai.com/api/reference/resources/live/methods/create), [Anthropic modelleri](https://platform.claude.com/docs/en/models/overview).
