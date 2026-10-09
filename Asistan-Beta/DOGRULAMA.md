# Beta 0.7.2 doğrulama

## Otomatik kontroller

`test.sh` toplam **271 kontrol** çalıştırır: 94 Python testi ve 177 Swift kontrolü. Kapsam: ajan olayları, görüşme yaşam döngüsü, ses kapatma ve araya girme, özet işleri, OpenAI/Anthropic istemcileri, GPT-Live oturum/ses ayarları, model yapılandırması, arama politikası, arayan kimliği, kişiselleştirme, Mobile protokolü ve Odak durumunun ayrıştırılması.

Testlerde ağ/ses sağlayıcılarının yerine kontrollü örnekler kullanılır. API hesabı erişimi, gerçek ses kalitesi veya macOS arama arayüzlerinin her sürümü bu testlerle doğrulanmış sayılmaz. `build.sh` Swift uygulamasını derler ve uygulama imzasını doğrular.

## Canlı doğrulama kapsamı

Geliştirme sırasında WhatsApp ve iPhone/FaceTime sesli aramalarında karşılıklı konuşma doğrulandı. WhatsApp cevaplama, araya girme, sonlandırma ve ses kapatma yarışı düzeltmesinden sonra hata çıkmaması ayrıca denendi. Mobile üzerinden aramayı cevaplama ve canlı bağlantı denendi. Telefon/FaceTime mikrofonu Asistan Mikrofonu seçildikten sonra asistan sesi ve ekosuz konuşma doğrulandı.

Bu denemeler her yeni sürümün her donanımda tüm senaryoları geçtiği anlamına gelmez. Haiku 5.5 ve 31 sesin tamamı gerçek Türkçe aramalarda karşılaştırılmadı. Yeni Mac'te sesli aramalar, araya girme, not gönderme, sonlandırma ve mobil komutlar ayrıca denenmelidir.

## Kalan sınırlar

- Devral sonrası Mute when capturing açıkken karşı tarafı duyma ayrıca canlı doğrulama gerektirir.
- Arayanın adı yalnızca macOS erişilebilirlik arayüzünde varsa alınabilir. Aktif arama yedek okuması otomatik testlidir; tüm Phone/FaceTime sürümlerinde canlı isim doğrulaması yapılmadı.
- Özel GPT-Live karşılamasının sözcüğü sözcüğüne okunması ve gönderilen notun karşı uçta duyulması bağlantı/komut kabulünden çıkarılamaz.
- Odak durumu belgelenmemiş yerel dosyaya bağlıdır. Yeni macOS sürümleri ve izin durumları için ayrıca test gerekir.
- Loopback aygıtının bulunması kaynak, kanal, sessize alma veya arama uygulamasının mikrofon seçimini doğrulamaz.

Gerçek görüşme dökümleri, kişi adları, tanı günlükleri, API anahtarları ve yedekler bu doğrulama belgesine veya Git deposuna alınmaz.


## 0.7.2 karşılaması

İki gerçek GPT-Live oturumuna yalnızca sessiz PCM girişi gönderildi. Her ikisinde arayan dökümü olmadan asistanın metni ve konuşma sesi geldi; biri tek seferlik seslendirme hatırlatmasını kullandı. Mikrofon/hoparlör açılmadı, gerçek görüşme içeriği gönderilmedi. Son kullanım/kapanış bildirimi bu iki denemede doğrulanmadı; bağlantılar kapatıldı. Bu deneme telefonun karşı ucunda duyulmayı veya sözcüğü sözcüğüne karşılamayı doğrulamaz.

WhatsApp’ın güncel sesli arama başlığıyla ilgili düzeltme ve olumsuz video/geçmiş senaryoları otomatik test edildi. 0.7.2’nin gerçek WhatsApp kabul/bağlantı sonucu aşağıda kayıtlı kullanıcı aramasıyla doğrulandı.


0.7.2 gerçek WhatsApp sesli aramasında algılama, kabul ve karşılamanın arayan konuşmadan başlaması kullanıcı tarafından doğrulandı. Teknik günlük kaynak=WhatsApp, ses=gpt-live ve karşılama isteğinden yaklaşık 2,5 saniye sonra ilk konuşma sesini gösterdi; dökümde ilk konuşan Asistan oldu. Bu sonuç sesin karşı uçta duyulduğuna dair kullanıcı doğrulamasıyla birlikte değerlendirilmiştir.
