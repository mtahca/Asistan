# Diğer Mac'te Asistan 0.9 kurulumu

Bu depoda hazır uygulama veya kurulum ZIP'i yoktur. Derlediğiniz Mac'te:

```sh
bash paketle.sh      # derler ve "Asistan <sürüm> Kurulum.zip" üretir
```

ZIP yalnızca uygulamayı içerir. API anahtarları, notlar, kişiselleştirme, Python ortamı ve modeller diğer Mac'te sıfırdan hazırlanır; uygulama bunları kendi kurar.

## Normal uygulama olarak kurulum

1. ZIP'i diğer Mac'e aktarıp açın. **Asistan.app** dosyasını **Uygulamalar** klasörüne sürükleyin. İlk açılıştan önce taşıyın; ZIP içinden veya geçici bir klasörden çalıştırmayın.
2. Uygulamalar'dan Asistan'a çift tıklayın. Asistan menü çubuğunda çalışır. Pencere kapanırsa uygulamaya yeniden çift tıklayarak **Kurulum ve durum** ekranını açabilirsiniz. Üstte **Sürüm 0.9.0 · Derleme 36** (ya da kurduğunuz sürüm) görünmelidir.
3. **Ortamı kur (internet gerekir)** düğmesine basın. Python 3.12 ve çevrimiçi ses için gereken hafif paketler kurulur; Whisper ve EMA gibi yerel modeller indirilmez. Yerel ses isterseniz sonra **Yerel modeller** sekmesinden **Yerel modelleri kur** düğmesine basın. İlerlemeyi **Kurulum ayrıntıları** sekmesinden izleyin ve **Ortam kuruldu** mesajını bekleyin.
4. **Modeller ve API anahtarları…** ekranında görüşme ve özet modelini seçip gereken Anthropic ve/veya OpenAI anahtarını girin. Anahtarlar ve kişiselleştirme ayarları paketle taşınmaz.
5. **Ses ayarları…** ekranında **Ses sürücüsünü kur** düğmesine basın ve yönetici parolasını girin. **Sistem sesi kaydetme** iznini verin (gerekirse Mac'i yeniden başlatın). FaceTime/WhatsApp/Telefon mikrofonunu **Asistan Sanal Mikrofon** seçin; hoparlörü gerçek hoparlör veya kulaklık olarak bırakın. Loopback ve BlackHole gerekmez.
6. **İzinleri iste** düğmesiyle mikrofon ve erişilebilirlik izinlerini tamamlayın. Rehber izni isteğe bağlıdır. Erişilebilirlik listesinde **Uygulamalar'daki Asistan** görünmelidir.
7. **Asistan'ı başlat** düğmesine basın. **Asistan hazır** ve **Whisper ve Türkçe ses sınandı** göründükten sonra isterseniz **Seçili modellerin bağlantısını sına** ile model erişimini doğrulayın. Bu test küçük, ücretli bir API isteği gönderir; görüşme içeriği göndermez.
8. Önceki Mac'te Asistan'ı kapatın ve yeni Mac'e bir deneme araması yapın. WhatsApp ile iPhone/FaceTime'ı ayrı ayrı deneyin.

Xcode, Homebrew veya elle kurulmuş Python gerekmez; uygulama kendi konuşma ortamını hazırlar. Kullanıcı verileri o Mac'te `~/Documents/Asistan Data` klasöründe oluşturulur. Başka bir Mac'in Python ortamını kopyalamayın.

Taşımak istediğiniz ayarlar varsa yalnızca şu dosyaları kopyalayın: `~/Documents/Asistan Data/.env` (API anahtarları ve model seçimi) ve `asistan_tercihleri.json` (kişiselleştirme). Kopyaladıktan sonra `.env` için `chmod 600` uygulayın. `.venv`, `notlar/`, `summary_jobs/` ve günlükleri kopyalamayın. Mobil eşleştirme kodu Mac'e özeldir; diğer Mac kendi kodunu üretir.

## Bilgisayar gereklilikleri

- **Apple Silicon** (M1 ve sonrası) gerekir; Intel Mac desteklenmez. Alt sınır macOS 14.2'dir (arayanın sesini dinleme için gerekli).
- Asistan yerel ortamı, üç ses aygıtını, erişilebilirlik ve mikrofon izinlerini ve model/anahtar ayarlarını kontrol eder. Kurulum, Whisper ile kısa bir tanıma ve EMA ile ses üretimi denenmeden başarılı sayılmaz.
- Aygıt adlarının bulunması, arama uygulamalarındaki mikrofon seçiminin doğru olduğunu göstermez; bunu ayrıca kontrol edin.
- Paket API anahtarlarını, kişisel görüşmeleri, Python ortamını ve model önbelleklerini içermez.

## Developer ID ile imzalı ve notarize edilmiş paket (önerilen)

Apple geliştirici hesabınız varsa paket Apple'a notarize ettirilebilir; diğer Mac'te "geliştirici doğrulanamadı" uyarısı çıkmaz ve izinler (Erişilebilirlik, Sistem sesi) güncellemelerde korunur. Bir kez hazırlık:

1. Xcode → Settings → Accounts → hesabınız → **Manage Certificates…** → **+** → **Developer ID Application**.
2. Apple Account'ta (appleid.apple.com) bir **uygulamaya özel parola** oluşturun. Parolayı kimseye yazmayın; yalnızca bir sonraki komuta siz girersiniz:
   ```sh
   xcrun notarytool store-credentials asistan-notary --apple-id <Apple kimliğiniz> --team-id <Team ID>
   ```
3. Her paketlemede:
   ```sh
   ASISTAN_NOTARY_PROFILE=asistan-notary bash paketle.sh
   ```
   Betik Developer ID sertifikasını kendisi bulur, hardened runtime ile imzalar, Apple'a gönderir, beklemeyi ve `staple` işlemini yapar, sonunda `spctl` ile doğrular. Bu üretilen ZIP'i diğer Mac'te karantina adımı olmadan açabilirsiniz.

`ASISTAN_NOTARY_PROFILE` verilmezse paket Developer ID ile imzalanır ama notarize edilmez; sertifika da yoksa eski yerel imzalı paket çıkar. Notarize edilmiş uygulamada mikrofon ve rehber izinleri, ses sürücüsünün yönetici parolasıyla kurulumu ve sistem sesi kaydı normal çalışmalıdır; ilk paketi diğer Mac'te bu dört şeyle sınayın.

## İlk açılışta macOS uyarısı (yalnızca notarize edilmemiş pakette)

Yerel imzalı paket Apple tarafından notarize edilmemiştir; başka bir Mac'te "geliştirici doğrulanamadı" ya da "hasarlı" uyarısı çıkabilir. Uyarı, uygulamadan değil, macOS'un indirilen/AirDrop ile gelen dosyalara koyduğu karantina işaretinden kaynaklanır. İki çözüm:

- İlk açılış denemesinden sonra **Sistem Ayarları → Gizlilik ve Güvenlik → Yine de Aç**. [Apple'ın açıklaması](https://support.apple.com/en-gb/102445).
- Ya da uygulamayı Uygulamalar'a taşıdıktan sonra Terminal'de karantina işaretini kaldırın:
  ```sh
  xattr -dr com.apple.quarantine /Applications/Asistan.app
  ```

Genel güvenlik korumalarını kapatmayın. Uygulama sabit bir yerel imzayla imzalanmışsa (`make_cert.sh`), o sertifika diğer Mac'te yoktur; bu sorun değildir, yalnızca o Mac'te yeniden derlerseniz izinler sıfırlanır.

## Ses aygıtları

Sürücü **Asistan Sanal Çıkış** ve **Asistan Sanal Mikrofon** aygıtlarını ekler; Asistan açıkken **Asistan Dinleme** aygıtını kendisi oluşturur. FaceTime'ın Video, WhatsApp'ın Call ve Telefon'un Audio menüsünde mikrofonu **Asistan Sanal Mikrofon**, hoparlörü gerçek hoparlör veya kulaklık olarak seçin. Asistan Dinleme'yi ve Asistan Sanal Çıkış'ı arama uygulamasının mikrofonu veya hoparlörü yapmayın. Sistem varsayılanlarını fiziksel aygıtlarda bırakın. WhatsApp yeni aygıtı görmüyorsa açık görüşme yokken uygulamayı tamamen kapatıp yeniden açın. Daha önce Loopback kullanıldıysa oradaki Asistan aygıtlarını kapatın.

## İsteğe bağlı: Codex veya Claude ile kurulum

Aşağıdaki talimatı diğer bilgisayardaki bir yapay zekâ kodlama asistanına yapıştırıp bu depoyu veya paketi ekleyebilirsiniz. Bu zorunlu değildir; aynı düzeni elle de kurabilirsiniz.

> Bu Mac'te Asistan'ı kurmanı ve ses hattını hazırlamanı istiyorum. Kurulumu gerçekleştir; yalnızca anlatmakla kalma. README.md, DOGRULAMA.md ve WHATSAPP_COZUM.md belgelerini oku. Önce bu Mac'in Apple Silicon ve macOS 14.2 veya üzeri olduğunu kontrol et. Önceki bilgisayarın dosya yollarını veya Python ortamını kullanma; Asistan verileri ~/Documents/Asistan Data klasöründe tutulur. Uygulamayı /Applications klasörüne yerleştir ve kurulum ekranından Python/paket/model hazırlığını tamamla. API anahtarlarını sohbette isteme veya yazdırma; Modeller ve API anahtarları ekranına benim girmemi sağla. macOS'un kimlik doğrulaması isteyen adımlarını bana bırak.
>
> Ses sürücüsünü Ses ayarlarındaki Ses sürücüsünü kur düğmesiyle kur (parolayı ben gireceğim) ve Sistem sesi kaydetme iznini kontrol et. Loopback kullanma. Arama uygulamalarında mikrofon Asistan Sanal Mikrofon, hoparlör gerçek hoparlör veya kulaklık olsun. Sistem varsayılanlarını fiziksel aygıtlarda bırak.
>
> Erişilebilirlik ve mikrofon izinlerinin çalışan Asistan'da gerçekten kullanılabildiğini ve ses modellerinin hazır olduğunu doğrula. iPhone–Mac arama aktarımını kontrol et. Gerçek aramayı ben başka bir telefondan başlatacağım; deneme sırasında önceki bilgisayardaki Asistan'ı kapatmamı hatırlat. WhatsApp ve iPhone/FaceTime sesli aramalarını ayrı ayrı sına: cevaplama, iki yönlü konuşma, araya girince susma, not gönderme, Devral ve Sonlandır. Devral'da arayanı duyabildiğimi ayrıca test et. Bitince hangi testlerin geçtiğini ve kalan eksikleri kısaca bildir.

## GPT-Live 1 modu

Varsayılan ses modu **Gemini Live**'dır (0.9.1 ve sonrası). Başka bir mod için **Modeller ve API anahtarları** ekranında **Ses modu**nu değiştirebilirsiniz. GPT-Live için OpenAI anahtarı gerekir; arka plan/özet için Claude seçiliyse Anthropic anahtarı da gerekir. Bu modda kurulum yalnızca ses bağlantısı ortamını hazırlar; Whisper ve EMA indirilmez. Sonradan yerel moda dönerseniz tam kurulum gerekir. GPT-Live modunda görüşme sesi OpenAI'ye gider.

## Asistan Mobile ve Odak

**iPhone ve Odak…** ekranından mobil bağlantıyı açın ve Yerel Ağ iznini verin. Telefon aynı Wi-Fi'de olmalı. Asistan Mobile'da adı **— Asistan** ile biten Mac'i listeden seçin ya da ekranda gösterilen Mac adresini yazın (port 47821). Ardından Mac'teki **iPhone ve Odak…** penceresinde görünen QR kodu Asistan Mobile ile okutun. Eşleştirme anahtarı Mac'e özeldir; başka bir bilgisayardan taşınmaz.

Odak açıkken otomatik cevaplamayı ayrıca açabilirsiniz. Odak durumu okunamıyorsa yalnızca bu özellik için Tam Disk Erişimi verip Asistan'ı yeniden başlatın.
