# Beta 0.7.1 doğrulama

## Otomatik kontroller

`test.sh` toplam **254 kontrol** çalıştırır: 89 Python testi ve 165 Swift kontrolü. Kapsam: ajan olayları, görüşme yaşam döngüsü, ses kapatma ve araya girme, özet işleri, OpenAI/Anthropic istemcileri, GPT-Live oturum/ses ayarları, model yapılandırması, arama politikası, arayan kimliği, kişiselleştirme, Mobile protokolü ve Odak durumunun ayrıştırılması.

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
