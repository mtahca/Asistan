# Diğer Mac'te Asistan 0.8 kurulumu

Bu depoda hazır uygulama veya kurulum ZIP'i yoktur. Derlediğiniz Mac'te:

```sh
bash paketle.sh      # derler ve "Asistan <sürüm> Kurulum.zip" üretir
```

ZIP yalnızca uygulamayı içerir. API anahtarları, notlar, kişiselleştirme, Python ortamı ve modeller diğer Mac'te sıfırdan hazırlanır; uygulama bunları kendi kurar.

## Normal uygulama olarak kurulum

1. ZIP'i diğer Mac'e aktarıp açın. **Asistan.app** dosyasını **Uygulamalar** klasörüne sürükleyin. İlk açılıştan önce taşıyın; ZIP içinden veya geçici bir klasörden çalıştırmayın.
2. Uygulamalar'dan Asistan'a çift tıklayın. Asistan menü çubuğunda çalışır. Pencere kapanırsa uygulamaya yeniden çift tıklayarak **Kurulum ve durum** ekranını açabilirsiniz. Üstte **Sürüm 0.8.0 · Derleme 20** görünmelidir.
3. **Ortamı kur (internet gerekir)** düğmesine basın. Python 3.12, gerekli paketler, Whisper konuşma tanıma modeli ve Türkçe EMA ses modeli indirilir. İlerlemeyi **Kurulum ayrıntıları** sekmesinden izleyin ve **Ortam kuruldu** mesajını bekleyin.
4. **Modeller ve API anahtarları…** ekranında görüşme ve özet modelini seçip gereken Anthropic ve/veya OpenAI anahtarını girin. Anahtarlar ve kişiselleştirme ayarları paketle taşınmaz.
5. Loopback'i kurun ve aşağıdaki üç aygıtı oluşturun. FaceTime/WhatsApp/Telefon mikrofonunu **Asistan Mikrofonu** seçin; hoparlörü gerçek hoparlör veya kulaklık olarak bırakın. BlackHole gerekmez.
6. **İzinleri iste** düğmesiyle mikrofon ve erişilebilirlik izinlerini tamamlayın. Rehber izni isteğe bağlıdır. Erişilebilirlik listesinde **Uygulamalar'daki Asistan** görünmelidir.
7. **Asistan'ı başlat** düğmesine basın. **Asistan hazır** ve **Whisper ve Türkçe ses sınandı** göründükten sonra isterseniz **Seçili modellerin bağlantısını sına** ile model erişimini doğrulayın. Bu test küçük, ücretli bir API isteği gönderir; görüşme içeriği göndermez.
8. Önceki Mac'te Asistan'ı kapatın ve yeni Mac'e bir deneme araması yapın. WhatsApp ile iPhone/FaceTime'ı ayrı ayrı deneyin.

Xcode, Homebrew veya elle kurulmuş Python gerekmez; uygulama kendi konuşma ortamını hazırlar. Kullanıcı verileri o Mac'te `~/Documents/Asistan Data` klasöründe oluşturulur. Başka bir Mac'in Python ortamını kopyalamayın.

Taşımak istediğiniz ayarlar varsa yalnızca şu dosyaları kopyalayın: `~/Documents/Asistan Data/.env` (API anahtarları ve model seçimi) ve `asistan_tercihleri.json` (kişiselleştirme). Kopyaladıktan sonra `.env` için `chmod 600` uygulayın. `.venv`, `notlar/`, `summary_jobs/` ve günlükleri kopyalamayın. Mobil eşleştirme kodu Mac'e özeldir; diğer Mac kendi kodunu üretir.

## Bilgisayar gereklilikleri

- **Apple Silicon** (M1 ve sonrası) gerekir; Intel Mac desteklenmez. Alt sınır macOS 14.2'dir. Güncel Loopback 2.5.0 için üreticinin belirttiği aralık macOS **14.5–27** olduğundan yeni kurulumda macOS 14.5 veya üstünü kullanın. [Loopback'in resmi sayfası](https://rogueamoeba.com/loopback/).
- Asistan yerel ortamı, üç ses aygıtını, erişilebilirlik ve mikrofon izinlerini ve model/anahtar ayarlarını kontrol eder. Kurulum, Whisper ile kısa bir tanıma ve EMA ile ses üretimi denenmeden başarılı sayılmaz.
- Asistan, Loopback'i veya lisansını otomatik kurmaz. Aygıt adlarının bulunması, kaynakların, kanal bağlantılarının, **Mute when capturing** ayarının ve arama uygulamalarındaki mikrofon seçiminin doğru olduğunu göstermez; bunları ayrıca kontrol edin.
- Paket API anahtarlarını, kişisel görüşmeleri, Python ortamını ve model önbelleklerini içermez.

## İlk açılışta macOS uyarısı

Bu kişisel dağıtım Apple tarafından notarize edilmemiştir; başka bir Mac'te "geliştirici doğrulanamadı" ya da "hasarlı" uyarısı çıkabilir. Uyarı, uygulamadan değil, macOS'un indirilen/AirDrop ile gelen dosyalara koyduğu karantina işaretinden kaynaklanır. İki çözüm:

- İlk açılış denemesinden sonra **Sistem Ayarları → Gizlilik ve Güvenlik → Yine de Aç**. [Apple'ın açıklaması](https://support.apple.com/en-gb/102445).
- Ya da uygulamayı Uygulamalar'a taşıdıktan sonra Terminal'de karantina işaretini kaldırın:
  ```sh
  xattr -dr com.apple.quarantine /Applications/Asistan.app
  ```

Genel güvenlik korumalarını kapatmayın. Uygulama sabit bir yerel imzayla imzalanmışsa (`make_cert.sh`), o sertifika diğer Mac'te yoktur; bu sorun değildir, yalnızca o Mac'te yeniden derlerseniz izinler sıfırlanır.

## Loopback düzeni

Her aygıt iki kanallı ve açık olmalı:

1. **Asistan Ses Çıkışı:** Yalnızca Pass-Thru açık. Başka kaynak veya monitör yok. Asistan'ın sesi buraya gider.
2. **Asistan Mikrofonu:** Pass-Thru kapalı. Kaynak, sanal **Asistan Ses Çıkışı** aygıtı; kanallar 1→1, 2→2. Fiziksel mikrofon, BlackHole veya monitör yok. Bu ayrı aygıt, WhatsApp'ın mikrofon listesinde görünmesi için gereklidir.
3. **Asistan Dinleme:** Pass-Thru kapalı. Kaynaklar FaceTime, WhatsApp ve varsa Telefon/Phone; kanallar 1→1, 2→2. Her uygulama kaynağında **Mute when capturing** açık, monitör yok.

FaceTime'ın Video, WhatsApp'ın Call ve Telefon'un Audio menüsünde mikrofonu **Asistan Mikrofonu**, hoparlörü gerçek hoparlör veya kulaklık olarak seçin. Asistan Dinleme'yi ve Asistan Ses Çıkışı'nı arama uygulamasının mikrofonu yapmayın. Sistem varsayılanlarını fiziksel aygıtlarda bırakın. WhatsApp yeni aygıtı görmüyorsa açık görüşme yokken uygulamayı tamamen kapatıp yeniden açın.

## İsteğe bağlı: Codex veya Claude ile kurulum

Aşağıdaki talimatı diğer bilgisayardaki bir yapay zekâ kodlama asistanına yapıştırıp bu depoyu veya paketi ekleyebilirsiniz. Bu zorunlu değildir; aynı düzeni elle de kurabilirsiniz.

> Bu Mac'te Asistan 0.8'i kurmanı ve Loopback ayarlarını aşağıdaki düzene göre yapmanı istiyorum. Kurulumu gerçekleştir; yalnızca anlatmakla kalma. README.md, DOGRULAMA.md ve WHATSAPP_COZUM.md belgelerini oku. Mevcut Loopback ayarlarını değiştirmeden önce yedekle. Önce bu Mac'in Apple Silicon ve macOS 14.2 veya üzeri olduğunu kontrol et. Önceki bilgisayarın dosya yollarını veya Python ortamını kullanma; Asistan verileri ~/Documents/Asistan Data klasöründe tutulur. Uygulamayı /Applications klasörüne yerleştir ve kurulum ekranından Python/paket/model hazırlığını tamamla. API anahtarlarını sohbette isteme veya yazdırma; Modeller ve API anahtarları ekranına benim girmemi sağla. macOS'un kimlik doğrulaması isteyen adımlarını bana bırak.
>
> Loopback'te iki kanallı üç aygıt olsun: Asistan Ses Çıkışı (yalnızca Pass-Thru), Asistan Mikrofonu (kaynak: Asistan Ses Çıkışı; 1→1, 2→2) ve Asistan Dinleme (kaynaklar: FaceTime, WhatsApp, varsa Telefon; her birinde Mute when capturing açık). Arama uygulamalarında mikrofon Asistan Mikrofonu, hoparlör gerçek hoparlör veya kulaklık olsun. Sistem varsayılanlarını fiziksel aygıtlarda bırak.
>
> Erişilebilirlik ve mikrofon izinlerinin çalışan Asistan'da gerçekten kullanılabildiğini ve ses modellerinin hazır olduğunu doğrula. iPhone–Mac arama aktarımını kontrol et. Gerçek aramayı ben başka bir telefondan başlatacağım; deneme sırasında önceki bilgisayardaki Asistan'ı kapatmamı hatırlat. WhatsApp ve iPhone/FaceTime sesli aramalarını ayrı ayrı sına: cevaplama, iki yönlü konuşma, araya girince susma, not gönderme, Devral ve Sonlandır. Devral'da arayanı duyabildiğimi ayrıca test et. Bitince hangi testlerin geçtiğini ve kalan eksikleri kısaca bildir.

## GPT-Live 1 modu

Varsayılan yerel moddur. Kurulumdan önce **Modeller ve API anahtarları** ekranında **Ses modu → Çevrimiçi ses — GPT-Live 1** seçebilirsiniz. GPT-Live için OpenAI anahtarı gerekir; arka plan/özet için Claude seçiliyse Anthropic anahtarı da gerekir. Bu modda kurulum yalnızca ses bağlantısı ortamını hazırlar; Whisper ve EMA indirilmez. Sonradan yerel moda dönerseniz tam kurulum gerekir. GPT-Live modunda görüşme sesi OpenAI'ye gider.

## Asistan Mobile ve Odak

**iPhone ve Odak…** ekranından mobil bağlantıyı açın ve Yerel Ağ iznini verin. Telefon aynı Wi-Fi'de olmalı. Asistan Mobile'da adı **— Asistan** ile biten Mac'i listeden seçin ya da ekranda gösterilen Mac adresini yazın (port 47821). Ardından bu Mac'teki sekiz haneli kodu girin. Eşleştirme kodu Mac'e özeldir; başka bir bilgisayardan taşınmaz.

Odak açıkken otomatik cevaplamayı ayrıca açabilirsiniz. Odak durumu okunamıyorsa yalnızca bu özellik için Tam Disk Erişimi verip Asistan'ı yeniden başlatın.
