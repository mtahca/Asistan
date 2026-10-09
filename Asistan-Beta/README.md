# Asistan Beta 0.7.3

Bağımsız macOS AI telefon asistanı. iPhone–Mac arama aktarımı ve WhatsApp masaüstündeki sesli aramaları karşılar, arayanla konuşur ve görüşme notu oluşturur. Bu klasör Beta'nın kaynaklarını içerir; reponun kökündeki Asistan uygulaması Alpha olarak ayrı kalır.

## Kaynaktan derleme

Apple Silicon Mac, macOS 14.2 veya üzeri, Xcode Command Line Tools ve sisteminizle uyumlu Loopback gerekir. Yerel ses modelleri Apple Silicon içindir. API kullanımı, Python/paket kurulumu ve ilk model indirmeleri internet gerektirir.

```sh
git clone https://github.com/mtahca/Asistan.git
cd Asistan/Asistan-Beta
bash build.sh
```

Oluşan **Asistan Beta.app** dosyasını **Uygulamalar** klasörüne taşıyıp açın. Derleme mevcut `AsistanLocal` imzalama kimliği varsa onu, yoksa ad hoc imza kullanır. Apple notarizasyonu yapılmaz. Hazır uygulama, ZIP paketleri, Python ortamı ve model dosyaları bu Git deposunda bulunmaz. Uygulama derlendikten sonra çalışmak için kaynak klasörüne veya Codex'e ihtiyaç duymaz.

## İlk kurulum

1. Menüden **Modeller ve API anahtarları…** ekranını açın. Yerel ses veya GPT-Live 1 modunu seçip gereken Anthropic/OpenAI anahtarlarını gizli alanlara girin. Ses modu değişikliği sonraki görüşmeye uygulanır.
2. **Kurulum ve izinleri kontrol et…** ekranındaki **Ortamı kur** düğmesini kullanın. Python 3.12 ve sabitlenmiş bağımlılıklar hazırlanır. Yerel modda Whisper ve Türkçe EMA modelleri indirilip sınanır; GPT-Live modunda bunlar gerekmez. `setup.sh` bu ekran tarafından gerekli veri/kaynak yollarıyla çağrılır.
3. Mikrofon ve erişilebilirlik izinlerini verin. Rehber izni isteğe bağlıdır. Ekran çalışan sürüm/derleme numarasını, ortamı, ses aygıtlarını ve izinleri gösterir.
4. Aşağıdaki Loopback düzenini hazırlayıp arama uygulamalarının mikrofonunu **Asistan Mikrofonu** seçin. Beta'nın hazır olması uygulamaların mikrofon seçimini doğrulamaz.
5. Beta'yı başlatın; **Asistan Beta hazır** durumunu bekleyin. **Seçili modellerin bağlantısını sına** hesap/model erişimini küçük bir gerçek API isteğiyle kontrol eder; ücret oluşabilir. Sonra iPhone/FaceTime ve WhatsApp sesli aramalarını ayrı ayrı deneyin.

Ayrıntılı diğer Mac kurulumu: [DIGER_MAC_KURULUM.md](DIGER_MAC_KURULUM.md).

## Sabit Loopback ses hattı

BlackHole gerekmez. Beta arama başında, sonunda veya Devral sırasında sistemin ses aygıtlarını değiştirmez.

| Aygıt | Kaynak | Pass-Thru |
|---|---|---|
| Asistan Dinleme | Phone/Telefon, FaceTime, WhatsApp | Kapalı |
| Asistan Ses Çıkışı | Başka kaynak yok | Açık |
| Asistan Mikrofonu | Asistan Ses Çıkışı sanal aygıtı | Kapalı |

Üç aygıt açık ve iki kanallı olmalı; 1→1, 2→2 kanal bağlantıları yapılmalı. Monitör veya sürekli açık fiziksel mikrofon eklemeyin. **Asistan Dinleme** içindeki uygulama kaynaklarında **Mute when capturing açık** olsun; böylece Beta dinlerken arayanın sesi ayrıca Mac hoparlöründen çalmaz.

Telefon **Audio**, FaceTime **Video** ve WhatsApp **Call** menüsünde mikrofon **Asistan Mikrofonu**, hoparlör fiziksel hoparlör/kulaklık olmalıdır. **Sistem ayarını kullan**, Asistan Dinleme veya Asistan Ses Çıkışı mikrofon seçimi doğru değildir. Sistem varsayılanlarını fiziksel aygıtlarda bırakın. Ayrıntılar: [WHATSAPP_COZUM.md](WHATSAPP_COZUM.md).

Beta kapalıyken sanal mikrofon hattından kendi sesiniz gitmez; bilgisayardan kendiniz görüşecekseniz uygulamada fiziksel mikrofon seçin. **Devral** fiziksel mikrofonu aynı hatta aktarır. Mute when capturing açıkken Devral sonrası karşı tarafı duyma davranışı ayrıca canlı test gerektirir; kulaklık kullanarak doğrulayın.

## Kullanım ve kişiselleştirme

Gelen sesli aramada **Beta ile Cevapla** düğmesine basın. İsteğe bağlı otomatik cevaplama ve arama karşılamayı duraklatma seçenekleri vardır. Görüşme penceresinde süre/metin izlenebilir, en fazla 1000 karakterlik not gönderilebilir, **Devral** veya **Sonlandır** kullanılabilir. Video aramaları kapsam dışıdır; konuşma arama bağlantısı doğrulandıktan sonra başlar.

**Kişiselleştirme…** genel talimat, yalnızca bugüne ait not, karşılama ve `Ekrandaki ad=Hitap` eşleşmelerini düzenler. Örneğin `Ayşe=Ayşe Hanım`. Kısmi ad/cinsiyet tahmini yapılmaz. Teknik pencere kimlikleri kişi adı sayılmaz; erişilebilirlik arayüzünde isim/numara yoksa **Bilinmiyor** gösterilir. Ekrandaki isim kimlik doğrulaması değildir.

## Modeller

- **Yerel ses:** Whisper → seçili metin modeli → Türkçe EMA. Ham ses bu Mac'te işlenir; görüşme metni yanıt/özet için bulut sağlayıcısına gider.
- **GPT-Live 1:** ses OpenAI'ye gönderilir, gelen ses aynı Loopback hattında oynatılır. Yerel Whisper/EMA gerekmez. Arka plan ve özet modeli ayrı seçilebilir.
- **Metin/özet:** Claude Haiku 4.5, Haiku 5.5, Sonnet 5.5; OpenAI GPT-6 Luna, GPT-6 Sol, GPT-6.1 Sol. Hesabın seçili modele erişimi gerekir.
- **GPT-Live sesi:** Marin varsayılandır; ayarlardan 31 yerleşik ses seçilebilir. Ses tercihi yeni oturumda uygulanır. Yerel EMA sesini değiştirmez.

Görüşme ve özet farklı sağlayıcılardaysa iki API anahtarı gerekir. Boş anahtar alanı kayıtlı anahtarı korur. Ses kalitesi ve Türkçe telaffuz gerçek görüşmeyle değerlendirilmelidir. Seçenekler: [MODEL_ONERILERI.md](MODEL_ONERILERI.md).

## Asistan Mobile ve Odak

**iPhone ve Odak…** ekranından mobil bağlantıyı açın. Mac/iPhone aynı yerel ağda olmalı; istenirse Yerel Ağ iznini verin. Asistan Mobile'da Bonjour listesinden adı **— Asistan Beta** ile biten Mac'i seçip Beta'nın sekiz haneli eşleştirme kodunu girin. Önceden elle yazılmış Mac adresini temizleyin.

Beta mevcut Mobile v1 TLS-PSK protokolünü kullanır, kendi portu **47822** ve kendi kodu vardır. Alpha'nın portu 47821'dir. Mevcut Mobile uygulamasının elle IP alanı 47821'e sabit olduğundan Beta için Bonjour keşfi kullanılmalıdır. Alpha/Mobile kaynaklarını değiştirmek gerekmez. Telefonda aramayı cevaplama, not gönderme, canlı metin izleme ve sonlandırma desteklenir; ham ses telefona aktarılmaz.

**Odak açıkken gelen aramaları otomatik cevapla** isteğe bağlıdır ve genel otomatik cevaplama ayarını değiştirmez. Arama karşılamayı duraklatma her iki otomatik modu ve mobil cevaplamayı durdurur. macOS'un yerel Odak dosyası yalnızca okunur; biçimi belgelenmiş bir API değildir. Durum okunamıyorsa bu özellik için Tam Disk Erişimi gerekebilir. Tanınmayan/okunamayan durumda Odak seçeneği otomatik cevap başlatmaz.

## Veriler ve doğrulama

Beta'nın uygulama kimliği `com.mtahca.asistan.beta`; özel veriler varsayılan olarak `~/Documents/Codex/Asistan Beta Data` içinde tutulur. API anahtarları `.env` dosyasındadır; kullanıcı tercihleri, notlar, dökümler, özet işleri ve Python ortamı bu Git deposuna dahil değildir. Ham ses kaydı varsayılan olarak kapalıdır. Metin ve arayan bilgisi seçili sağlayıcıya yanıt/özet için gönderilir; GPT-Live modunda ses de OpenAI'ye gider.

Alpha ile Beta aynı aramayı birlikte yönetmemelidir; geçişte diğerinden çıkın. Beta'nın kaynak klasörü bağımsızdır; mevcut kullanıcı verileri ve yedekler yayınlama sırasında değiştirilmez.

```sh
bash test.sh
```

Testler kurulu Beta Python ortamını kullanır. Başka ortam için `ASISTAN_BETA_PYTHON` değişkenini Python çalıştırıcısının tam yoluna ayarlayın. [DOGRULAMA.md](DOGRULAMA.md) test kapsamını ve canlı doğrulama sınırlarını açıklar; [INCELEME.md](INCELEME.md) mimari kararları özetler. Paketlenmiş üçüncü taraf WebSocket kitaplığının lisansı `vendor/websocket_client-1.9.2.dist-info/licenses/LICENSE` içindedir.


## 0.7.2 düzeltmeleri

WhatsApp audio call ve WhatsApp voice call başlıkları, kişi adıyla başlayan pencere başlıkları ve iki WhatsApp uygulama kimliği desteklenir. Kabul/ret kontrolleri yine zorunludur; görüntülü aramalar ve geçmiş kayıtlar karşılanmaz. Tanı kaydı AXWindows sonucu/pencerelerini de içerir.

GPT-Live karşılaması tam metinle, arayanı beklemeden konuşma talimatıyla istenir. Talimat kabulü ve ilk konuşma sesi günlüğe eklenir. Talimat kabul edilmiş ancak dört saniye boyunca iki taraf da sessiz kalmışsa tek bir seslendirme hatırlatması yapılır. Arayanın konuşması, asistanın metin/ses üretmesi veya görüşmenin durması tekrarı engeller. Yerel ses modu ve Loopback hattı değişmez.


## 0.7.3 — Daha kısa sessiz başlangıç beklemesi

0.7.2’de WhatsApp ve FaceTime gerçek aramaları algılama, cevaplama ve arayan konuşmadan karşılama açısından doğrulandı. FaceTime’da ilk sesin geç başlaması nedeniyle, kabul edilmiş karşılamanın tek seslendirme hatırlatması için bekleme dört saniyeden iki saniyeye indirildi. Arayan/asistan konuşmuşsa veya görüşme duruyorsa hatırlatma yine gönderilmez. Model/anahtar, Mobile/Odak ve Loopback ayarları değişmedi. Çalışan 0.7.2 uygulama/kaynak yedeği Asistan-Beta-Yedek-0.7.2-karsilama-hizi-oncesi içinde doğrulandı.
