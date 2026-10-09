# Asistan 0.8.7

macOS menü çubuğunda çalışan yapay zekâ telefon asistanı. iPhone–Mac arama aktarımıyla gelen Telefon/FaceTime ve WhatsApp masaüstü sesli aramalarını karşılar, arayanla Türkçe konuşur ve görüşme notu çıkarır. Görüşmeyi canlı metinden izleyebilir, asistana not gönderebilir, görüşmeyi devralabilir veya sonlandırabilirsiniz. Aynı işleri **Asistan Mobile** ile iPhone'dan da yapabilirsiniz.

0.8, eski Alpha (kökteki ilk uygulama) ile Beta 0.7.3'ü tek uygulamada birleştirir. Temeli Beta 0.7.3'tür; Alpha kaynakları depodan kaldırıldı.

## 0.8.1: Arama uygulamalarının ses seçimi otomatik

Bir arama uygulaması (özellikle macOS Telefon) mikrofon olarak Asistan Mikrofonu dışında bir aygıt kullanırsa asistanın sesi arayana gitmez. 0.8.1 bunu her görüşmede kendisi çözer:

1. **Menüden seçim:** Arama bağlanınca Asistan, aramanın geldiği uygulamanın (Telefon, FaceTime, WhatsApp) menüsünde mikrofonu **Asistan Mikrofonu** yapar. Hoparlör yanlışlıkla bir Asistan sanal aygıtındaysa gerçek hoparlöre alır. Uygulama arka plandaysa menüsünü okumak için kısa süre öne getirilir. Seçim, uygulama hazır olana kadar 6 kez yeniden denenir.
2. **Doğrulama:** macOS'un ses sisteminden Asistan Mikrofonu'nu gerçekten hangi işlemin kullandığına bakılır.
3. **Yedek:** Üçüncü denemede hâlâ doğrulanmadıysa sistem mikrofonu görüşme süresince **Asistan Mikrofonu** yapılır ("Sistem ayarını kullan" seçili uygulamalar için). Görüşme bitince, uygulama kapanınca veya bir sonraki açılışta eski mikrofon geri gelir. **Ses ayarları…** penceresinden kapatılabilir.
4. **Uyarı:** Hiçbiri sonuç vermezse canlı metne, bildirimlere ve iPhone'a açık bir uyarı düşer; Devral ile görüşmeyi alabilirsiniz.

**Ses ayarları… → Uygulamaları denetle ve düzelt** düğmesi, arama yokken açık olan Telefon, FaceTime ve WhatsApp'ı denetleyip düzeltir ve her birinin mikrofon/hoparlör durumunu gösterir. **Diğer seçenekler → Tanı bilgilerini kaydet** artık bu uygulamaların menü yapısını ve Asistan Mikrofonu'nu kullanan işlemleri de kaydeder.

## 0.8'de neler değişti

- **Tek uygulama:** Uygulamanın adı **Asistan**, kimliği `com.mtahca.asistan`. Ayrı Alpha/Beta seçimi kalmadı.
- **Otomatik taşıma:** İlk açılışta Beta'nın veri klasörü (`~/Documents/Codex/Asistan Beta Data`) `~/Documents/Asistan Data` klasörüne taşınır. Ayarlar, API anahtarları, notlar, kişiselleştirme ve Python ortamı korunur. Beta'nın tercihleri de bir kez aktarılır: mobil eşleştirme kodu, otomatik cevaplama, Odak, duraklatma ve Devral mikrofonu. Beta açıksa taşıma yapılmaz; Beta'dan çıkıp Asistan'ı yeniden açın.
- **Asistan Mobile:** Port yeniden **47821** oldu; Mobile'ın Bonjour listesi de elle IP alanı da çalışır. **iPhone ve Odak…** penceresi Mac'in yerel IP adresini gösterir. Bonjour adı artık `— Asistan` ile bitiyor; telefonda Mac'i listeden bir kez yeniden seçin. Eşleştirme kodu aynı kalır.
- **Canlı görüşme penceresi:** Metni yukarı kaydırıp okurken yeni satırlar pencereyi aşağı atlatmaz. **Kopyala** düğmesi tüm metni panoya alır. **Hazır notlar** menüsünden sık kullanılan bir talimat yazı alanına eklenir ve Enter ile gönderilir.
- **Menü çubuğu:** Simge durumu gösterir (hazır, görüşmede, duraklatıldı, dikkat gerekiyor). Görüşme sürerken yanında süre görünür. **Son görüşmeler** alt menüsü son sekiz notu tarih ve arayan adıyla listeler.
- **Simge:** Uygulama simgesi olarak `app/AppIcon.iconset` kullanılır.

## Kaynaktan derleme

Gereksinimler: Apple Silicon Mac, macOS 14.2 veya üzeri, Xcode Command Line Tools ve sisteminizle uyumlu Loopback. API kullanımı, Python/paket kurulumu ve ilk model indirmeleri internet gerektirir.

```sh
git clone https://github.com/mtahca/Asistan.git
cd Asistan
bash make_cert.sh   # bir kez; sabit imza sayesinde izinler yeniden derlemede korunur
bash build.sh
```

Oluşan **Asistan.app** dosyasını **Uygulamalar** klasörüne taşıyıp açın. Başka bir Mac'e taşımak için `bash paketle.sh` bir kurulum ZIP'i üretir; adımlar [DIGER_MAC_KURULUM.md](DIGER_MAC_KURULUM.md) içindedir. `AsistanLocal` imzalama kimliği varsa derleme onu kullanır; yoksa geçici (ad hoc) imza kullanılır. Uygulama Apple tarafından notarize edilmez. Hazır uygulama, ZIP paketi, Python ortamı ve model dosyaları bu depoda bulunmaz.

### Beta'dan 0.8'e geçiş

1. Asistan Beta'dan ve varsa eski Asistan'dan (Alpha) çıkın.
2. Yeni **Asistan.app**'i Uygulamalar'a koyup açın. Veri ve tercihler otomatik taşınır.
3. **Kurulum ve izinleri kontrol et…** ekranında erişilebilirlik ve mikrofon izinlerini doğrulayın. Uygulama kimliği değiştiği için macOS izinleri yeniden isteyebilir. Erişilebilirlik listesindeki eski **Asistan Beta** kaydını kaldırabilirsiniz.
4. Mobil bağlantı açıksa Asistan Mobile'da Mac'i listeden yeniden seçin.
5. Uygulamalar'daki eski **Asistan Beta.app**'i çalıştığını doğruladıktan sonra silebilirsiniz.

## İlk kurulum

1. **Modeller ve API anahtarları…** ekranında yerel ses veya GPT-Live 1 modunu seçin, gereken Anthropic/OpenAI anahtarlarını gizli alanlara girin.
2. **Kurulum ve izinleri kontrol et…** ekranındaki **Ortamı kur** düğmesiyle Python 3.12 ve sabitlenmiş bağımlılıkları hazırlayın. Yerel modda Whisper ve Türkçe EMA modelleri indirilip sınanır; GPT-Live modunda bunlar gerekmez.
3. Mikrofon ve erişilebilirlik izinlerini verin. Rehber izni isteğe bağlıdır.
4. Aşağıdaki Loopback düzenini hazırlayın ve arama uygulamalarının mikrofonu olarak **Asistan Mikrofonu**'nu seçin.
5. Asistan'ı başlatıp **Asistan hazır** durumunu bekleyin. **Seçili modellerin bağlantısını sına** hesap/model erişimini küçük bir gerçek API isteğiyle kontrol eder; ücret oluşabilir.

Başka bir Mac'e kurulum: [DIGER_MAC_KURULUM.md](DIGER_MAC_KURULUM.md).

## Sabit Loopback ses hattı

BlackHole gerekmez. Asistan sistemin ses aygıtlarını değiştirmez; tek istisna, arama uygulamasının mikrofonu doğrulanamadığında devreye giren ve görüşme bitince geri alınan sistem mikrofonu yedeğidir (Ses ayarlarından kapatılabilir).

| Aygıt | Kaynak | Pass-Thru |
|---|---|---|
| Asistan Dinleme | Phone/Telefon, FaceTime, WhatsApp | Kapalı |
| Asistan Ses Çıkışı | Başka kaynak yok | Açık |
| Asistan Mikrofonu | Asistan Ses Çıkışı sanal aygıtı | Kapalı |

Üç aygıt da açık ve iki kanallı olmalı; kanallar 1→1 ve 2→2 bağlanmalı. Monitör veya sürekli açık fiziksel mikrofon eklemeyin. **Asistan Dinleme**'deki uygulama kaynaklarında **Mute when capturing** açık olsun; böylece arayanın sesi Mac hoparlöründen ayrıca çalmaz.

Telefon **Audio**, FaceTime **Video** ve WhatsApp **Call** menüsünde mikrofon **Asistan Mikrofonu**, hoparlör fiziksel hoparlör veya kulaklık olmalı. Ayrıntılar: [WHATSAPP_COZUM.md](WHATSAPP_COZUM.md).

Asistan kapalıyken sanal mikrofon hattından sizin sesiniz gitmez. Bilgisayardan kendiniz konuşacaksanız arama uygulamasında fiziksel mikrofonu seçin. **Devral** fiziksel mikrofonunuzu aynı hatta aktarır.

## Kullanım

Gelen sesli aramada **Asistan ile Cevapla** düğmesine basın. İsterseniz otomatik cevaplamayı, yalnızca Odak açıkken otomatik cevaplamayı veya arama karşılamayı duraklatmayı açabilirsiniz. Görüşme penceresinde süre ve canlı metin görünür. Buradan en fazla 1000 karakterlik not gönderebilir, **Devral** veya **Sonlandır** düğmelerini kullanabilirsiniz. Görüntülü aramalar kapsam dışıdır. Asistan, arama bağlantısı doğrulandıktan sonra konuşmaya başlar.

**Kişiselleştirme…** penceresinde genel talimatı, yalnızca bugüne ait notu, karşılama metnini ve `Ekrandaki ad=Hitap` eşleşmelerini düzenleyebilirsiniz (örneğin `Ayşe=Ayşe Hanım`). Ekrandaki isim kimlik doğrulaması değildir. İsim veya numara yoksa arayan **Bilinmiyor** gösterilir; bu durumda bildirimin yapısı `~/Documents/Asistan Data/son_arama_tani.txt` dosyasına kaydedilir ve tespit kuralları bu dosyayla düzeltilebilir.

## Modeller

- **Yerel ses:** Whisper → seçili metin modeli → Türkçe EMA. Ham ses bu Mac'te işlenir; görüşme metni yanıt ve özet için bulut sağlayıcısına gider.
- **GPT-Live 1:** Ses OpenAI'ye gönderilir; gelen ses aynı Loopback hattında çalınır. Arka plan ve özet modeli ayrı seçilebilir.
- **Metin/özet:** Claude Haiku 4.5, Haiku 5.5, Sonnet 5.5; OpenAI GPT-6 Luna, GPT-6 Sol, GPT-6.1 Sol.
- **GPT-Live sesi:** Varsayılan Marin; 31 yerleşik ses seçilebilir.

Seçenekler: [MODEL_ONERILERI.md](MODEL_ONERILERI.md).

## Asistan Mobile ve Odak

**iPhone ve Odak…** ekranından mobil bağlantıyı açın. Mac ve iPhone aynı yerel ağda olmalı; istenirse Yerel Ağ iznini verin. Asistan Mobile'da Bonjour listesinden adı **— Asistan** ile biten Mac'i seçin ya da ekranda gösterilen Mac adresini yazın. Sonra sekiz haneli eşleştirme kodunu girin.

Bağlantı Mobile v1 protokolünü kullanır: TLS-PSK, port **47821**. Telefondan gelen aramayı cevaplayabilir, not gönderebilir, canlı metni izleyebilir ve görüşmeyi sonlandırabilirsiniz. Ham ses telefona aktarılmaz.

**Odak açıkken gelen aramaları otomatik cevapla** isteğe bağlıdır. Genel otomatik cevaplama ayarını değiştirmez. macOS'un Odak durumu belgelenmemiş yerel bir dosyadan okunur; okunamıyorsa Tam Disk Erişimi gerekebilir. Odak durumu okunamazsa otomatik cevap başlatılmaz.

## Veriler

Özel veriler `~/Documents/Asistan Data` içindedir: `.env` (API anahtarları), notlar (`notlar/`), dökümler, özet işleri, kişiselleştirme, günlük ve Python ortamı. Bunların hiçbiri Git deposuna girmez. Ham ses kaydı varsayılan olarak kapalıdır.

## Doğrulama

```sh
bash test.sh
```

Testler kurulu Python ortamını kullanır (`~/Documents/Asistan Data/.venv`). Başka bir ortam için `ASISTAN_PYTHON` değişkenine Python çalıştırıcısının tam yolunu verin. Kapsam ve canlı doğrulama sınırları: [DOGRULAMA.md](DOGRULAMA.md). Mimari: [INCELEME.md](INCELEME.md). Paketlenmiş WebSocket kitaplığının lisansı `vendor/websocket_client-1.9.2.dist-info/licenses/LICENSE` içindedir.

## Sürüm geçmişi

- **0.8.7** — GPT-Live'da notlar artık talimat kanalıyla gider (önce yok sayılan "yorum" kanalıyla gidiyordu); modelin kabulü not durumunda görünür. Karşılama gecikmesi kısaldı: GPT-Live oturumu cevap düğmesine basılır basılmaz, arama bağlantısı doğrulanırken açılır; doğrulama taraması bu sırada 0,6 sn yerine 0,2 sn'de bir yapılır.
- **0.8.6** — FaceTime/iPhone bildirimindeki arayan adı gerçek yapıya göre düzeltildi: `AXGenericElement` öğesi, yön işaretleri ve "FaceTime Audio" içindeki bölünmez boşluk artık sorun çıkarmıyor.
- **0.8.5** — FaceTime ve iPhone aramalarında arayan adı: Bildirim Merkezi'nin `AXUnknown`/`AXGroup` öğelerindeki "Ad, FaceTime Audio", "Ad⏎From Your iPhone" ve ayrı öğe biçimleri tanınır; numara görünüyorsa nota yazılır. Arayan yine bulunamazsa bildirimin ham yapısı `son_arama_tani.txt` dosyasına kaydedilir.
- **0.8.4** — Asistan Mobile 0.2 için protokol alanları: `state` içinde arama kaynağı, duraklatma ve devralma durumu, `hello` içinde sürüm; telefondan `pause` komutu (görüşme yokken). Eski Mobile sürümleri etkilenmez.
- **0.8.3** — GPT-Live bağlantısı görüşme ortasında koparsa aynı aramada en fazla iki kez otomatik yeniden bağlanılır; yeni oturum konuşmanın geçmişini alır ve karşılamayı tekrarlamaz. Kısa ağ duraksamaları artık görüşmeyi bitirmez (gönderim yeniden denenir, ses karesi düşürülür). Menü durumu ve gelen arama paneli arayan adını gösterir. Görüşme notuna süre eklendi. Ayar dosyası her 0,4 sn yerine yalnızca değiştiğinde okunur.
- **0.8.2** — WhatsApp menü başlıklarındaki görünmez yön işaretleri artık mikrofon listesinin tanınmasını engellemiyor. GPT-Live bağlantısı koptuğunda sunucunun asıl hata nedeni gösteriliyor ve `app.log`a "GPT-Live tanı" satırı olarak yazılıyor.
- **0.8.1** — Arama uygulamalarının mikrofon/hoparlör seçimi her görüşmede otomatik yapılıyor ve doğrulanıyor; sistem mikrofonu yedeği, Ses ayarlarında denetle-düzelt düğmesi ve menüleri içeren tanı kaydı.
- **0.8.0** — Alpha ve Beta tek uygulamada birleşti. Veri ve tercih taşıma, Mobile portu 47821, Mac adresinin gösterilmesi, canlı pencere iyileştirmeleri, durum simgesi ve Son görüşmeler menüsü eklendi.
- **0.7.3** — GPT-Live karşılamasında tek seslendirme hatırlatmasından önceki bekleme 4 saniyeden 2 saniyeye indi.
- **0.7.2** — WhatsApp sesli arama başlıkları için algılama düzeltmesi; GPT-Live karşılaması arayanı beklemeden başlıyor.
- **0.7.1** — Bağımsız Beta: sabit Loopback hattı, GPT-Live 1, model seçimi, Asistan Mobile ve Odak.
