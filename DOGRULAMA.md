# Doğrulama

## 0.8.5

Kullanıcının ekran görüntülerinde FaceTime, iPhone aktarmalı ve WhatsApp aramalarında arayan adı bildirimde görünüyordu; WhatsApp'ta tanınıyor, Apple bildirimlerinde "Bilinmiyor" kalıyordu. `extractCaller` artık Bildirim Merkezi'nin `AXUnknown`/`AXGroup` öğelerini de okur (`CallerIdentityTests` +6 kontrol). Gerçek bildirim yapısı elde olmadığı için kurallar tahmine dayanır; arayan bulunamayan her çalışta `son_arama_tani.txt` yazılır. Bu dosya kişi adı içerir ve yalnızca yereldir.

Elle kontrol: FaceTime, iPhone ve WhatsApp aramalarında gelen arama paneli ve menü durumu adı göstermeli. Göstermiyorsa `son_arama_tani.txt` dosyasını paylaşın.

## 0.8.3

GPT-Live: bağlantı koptuğunda aynı aramada yeniden bağlanma (`LiveCall.reconnect`) ve gönderimde zaman aşımı yeniden denemesi eklendi. Üç yeni Python testi bunları sınar: yeniden bağlanan oturumun geçmişi alması ve karşılamayı tekrarlamaması, iki denemeden sonra sunucunun asıl gerekçesinin bildirilmesi, kontrol mesajlarının yeniden denenip ses karelerinin düşürülmesi. Python testleri: 99.

Elle kontrol: bir GPT-Live görüşmesi sırasında Mac'in Wi-Fi'sini 2–3 saniye kapatıp açın. Canlı pencerede "yeniden bağlanılıyor" ve "yeniden bağlandı" notları görünmeli; asistan kendini yeniden tanıtmadan devam etmeli. Görüşme sonunda `live_usage` toplam süreyi iki oturumun toplamı olarak vermeli.

## 0.8.2

0.8.1 gerçek Telefon aramalarında doğrulandı: günlükte "Telefon: mikrofon Asistan Mikrofonu ✓" ve "Asistan Mikrofonu’nu kullanan: com.apple.avconferenced" satırları görüldü.

Tanı kaydındaki gerçek WhatsApp menüsü, başlıklarda görünmez U+200E işareti olduğunu gösterdi. Menü karşılaştırması bu işaretleri yok sayıyor; `MenuRouteTests` gerçek menü yapısıyla genişletildi.

Aynı günlükte GPT-Live oturumları görüşme ortasında "veri gönderilemedi" hatasıyla bitti. Ses her 30 ms'de gönderildiği için gönderim, sunucunun kuyruktaki hata olayından önce başarısız oluyordu ve asıl neden kayboluyordu. Artık önce sunucunun gerekçesi gösteriliyor; teknik ayrıntı `app.log`a "GPT-Live tanı:" satırı olarak yazılıyor. Bu değişiklik kopmayı engellemez; nedenini görünür kılar. Python testleri: 96.

## 0.8.1

Yeni Swift parçaları: menüden mikrofon/hoparlör seçimi (`MenuRoute.swift`, `CallAudioRoute.swift`), macOS ses işlemi doğrulaması, sistem mikrofonu yedeği ve Ses ayarlarındaki denetim düğmesi. Menü karar mantığı `tests/MenuRouteTests.swift` ile test edilir. Menüye erişim ve macOS ses API'si yalnızca gerçek Mac'te sınanabilir.

Elle kontrol:

- Telefon uygulamasında mikrofonu bilerek fiziksel mikrofona alın, iPhone'a gelen bir aramayı Asistan ile cevaplayın. `app.log` içinde "Ses hattı denetimi" satırları görünmeli; mikrofon Asistan Mikrofonu'na geçmeli ve arayan asistanı duymalı.
- Aynısını FaceTime ve WhatsApp için tekrarlayın.
- Ses ayarları → Uygulamaları denetle ve düzelt: açık uygulamaların mikrofon/hoparlör durumu listelenmeli.
- Yedek açıkken, menü okunamadığında sistem mikrofonu görüşme boyunca Asistan Mikrofonu olmalı, görüşme bitince eski haline dönmeli.
- Sorun sürerse Diğer seçenekler → Tanı bilgilerini kaydet ile `tani.txt` dosyasını oluşturun; dosyanın sonunda uygulamaların menüleri yer alır.

## 0.8.0

0.8, Beta 0.7.3'ün kodunu temel alır. Ses ajanı, GPT-Live ve arama mantığında davranış değişikliği yoktur; yalnızca kullanıcıya görünen adlar "Beta" yerine "Asistan" oldu. Python testlerinin tamamı (95) 0.8 kaynaklarıyla geçti.

Yeni Swift parçaları şunlar: veri ve tercih taşıma, mobil port ve Mac adresi, canlı pencerede kaydırma/kopyalama/hazır notlar, durum simgesi ve Son görüşmeler menüsü. Bu sürüm Swift derleyicisi olmayan bir bulut ortamında hazırlandığı için Swift kodu orada derlenemedi. Yayından önce Mac'te şunları çalıştırın:

```sh
bash test.sh    # Python + Swift testleri; yeni MigrationNotesTests dahil
bash build.sh   # derleme ve imza doğrulaması
```

Ardından elle kontrol edin:

- Beta kapalıyken ilk açılışta `~/Documents/Asistan Data` oluşmalı, `~/Documents/Codex/Asistan Beta Data` taşınmış olmalı. Model ayarları, notlar ve kişiselleştirme görünmeli.
- Beta açıkken açılışta veriler taşınmamalı; "Asistan Beta hâlâ açık" bildirimi gelmeli.
- iPhone ve Odak penceresinde eşleştirme kodu Beta ile aynı olmalı ve Mac adresi görünmeli. Asistan Mobile hem listeden hem elle adresle bağlanmalı.
- Canlı pencerede yukarı kaydırınca yeni satırlar konumu bozmamalı; en alttayken metni izlemeli. Kopyala ve Hazır notlar çalışmalı.
- Menü çubuğu simgesi hazır, görüşmede ve duraklatılmış durumlarında değişmeli; görüşmede süre görünmeli. Son görüşmeler menüsü notları açmalı.
- Gerçek bir WhatsApp ve bir FaceTime aramasıyla cevaplama, konuşma, not, Devral ve Sonlandır'ı yeniden deneyin.

## 0.7.3 ve önceki sürümler

### Otomatik kontroller

`test.sh` toplam **272 kontrol** çalıştırır: 95 Python testi ve 177 Swift kontrolü. Kapsam: ajan olayları, görüşme yaşam döngüsü, ses kapatma ve araya girme, özet işleri, OpenAI/Anthropic istemcileri, GPT-Live oturum/ses ayarları, model yapılandırması, arama politikası, arayan kimliği, kişiselleştirme, Mobile protokolü ve Odak durumunun ayrıştırılması.

Testlerde ağ/ses sağlayıcılarının yerine kontrollü örnekler kullanılır. API hesabı erişimi, gerçek ses kalitesi veya macOS arama arayüzlerinin her sürümü bu testlerle doğrulanmış sayılmaz. `build.sh` Swift uygulamasını derler ve uygulama imzasını doğrular.

### Canlı doğrulama kapsamı

Geliştirme sırasında WhatsApp ve iPhone/FaceTime sesli aramalarında karşılıklı konuşma doğrulandı. WhatsApp cevaplama, araya girme, sonlandırma ve ses kapatma yarışı düzeltmesinden sonra hata çıkmaması ayrıca denendi. Mobile üzerinden aramayı cevaplama ve canlı bağlantı denendi. Telefon/FaceTime mikrofonu Asistan Mikrofonu seçildikten sonra asistan sesi ve ekosuz konuşma doğrulandı.

Bu denemeler her yeni sürümün her donanımda tüm senaryoları geçtiği anlamına gelmez. Haiku 5.5 ve 31 sesin tamamı gerçek Türkçe aramalarda karşılaştırılmadı. Yeni Mac'te sesli aramalar, araya girme, not gönderme, sonlandırma ve mobil komutlar ayrıca denenmelidir.

### Kalan sınırlar

- Devral sonrası Mute when capturing açıkken karşı tarafı duyma ayrıca canlı doğrulama gerektirir.
- Arayanın adı yalnızca macOS erişilebilirlik arayüzünde varsa alınabilir. Aktif arama yedek okuması otomatik testlidir; tüm Phone/FaceTime sürümlerinde canlı isim doğrulaması yapılmadı.
- Özel GPT-Live karşılamasının sözcüğü sözcüğüne okunması ve gönderilen notun karşı uçta duyulması bağlantı/komut kabulünden çıkarılamaz.
- Odak durumu belgelenmemiş yerel dosyaya bağlıdır. Yeni macOS sürümleri ve izin durumları için ayrıca test gerekir.
- Loopback aygıtının bulunması kaynak, kanal, sessize alma veya arama uygulamasının mikrofon seçimini doğrulamaz.

Gerçek görüşme dökümleri, kişi adları, tanı günlükleri, API anahtarları ve yedekler bu doğrulama belgesine veya Git deposuna alınmaz.


### 0.7.2 karşılaması

İki gerçek GPT-Live oturumuna yalnızca sessiz PCM girişi gönderildi. Her ikisinde arayan dökümü olmadan asistanın metni ve konuşma sesi geldi; biri tek seferlik seslendirme hatırlatmasını kullandı. Mikrofon/hoparlör açılmadı, gerçek görüşme içeriği gönderilmedi. Son kullanım/kapanış bildirimi bu iki denemede doğrulanmadı; bağlantılar kapatıldı. Bu deneme telefonun karşı ucunda duyulmayı veya sözcüğü sözcüğüne karşılamayı doğrulamaz.

WhatsApp’ın güncel sesli arama başlığıyla ilgili düzeltme ve olumsuz video/geçmiş senaryoları otomatik test edildi. 0.7.2’nin gerçek WhatsApp kabul/bağlantı sonucu aşağıda kayıtlı kullanıcı aramasıyla doğrulandı.


0.7.2 gerçek WhatsApp sesli aramasında algılama, kabul ve karşılamanın arayan konuşmadan başlaması kullanıcı tarafından doğrulandı. Teknik günlük kaynak=WhatsApp, ses=gpt-live ve karşılama isteğinden yaklaşık 2,5 saniye sonra ilk konuşma sesini gösterdi; dökümde ilk konuşan Asistan oldu. Bu sonuç sesin karşı uçta duyulduğuna dair kullanıcı doğrulamasıyla birlikte değerlendirilmiştir.


FaceTime 0.7.2 canlı denemesinde de arayan konuşmadan asistanın karşılaması kullanıcı tarafından doğrulandı. İlk ses karşılama isteğinden 4,95 saniye sonra geldi; dört saniyelik tek hatırlatma kullanıldı. Dökümün ilk konuşanı Asistan’dı.

### 0.7.3 hız ayarı

Tek hatırlatmanın sessiz beklemesi iki saniyeye indirildi. Süre eşiği, onay, tekrar engeli ve arayan/asistan konuşurken göndermeme dahil 38 GPT-Live testi geçti. İki yeni gerçek API oturumuna yalnızca sessizlik verildi; ikisinde de asistan önce konuştu, biri hatırlatmayı kullandı. Bunlar gerçek telefon gecikme ölçümü değildir; önceki canlı 0.7.2 sonucuyla yeni 0.7.3 ses süresi karıştırılmamalıdır. Uygulama derleme/imza kontrolü başarılı.
