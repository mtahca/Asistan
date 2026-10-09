# Kaynak deposu notu

Bu Git deposu hazır uygulama veya kurulum ZIP’i içermez. Önce README.md içindeki adımlarla `bash build.sh` çalıştırın; oluşan Asistan Beta.app dosyasını Uygulamalar klasörüne taşıyın. Aşağıdaki paket kurulum adımları, derlenmiş uygulama için de geçerlidir.

# Diğer Mac’te Asistan Beta 0.7.1 kurulumu

## Normal uygulama olarak kurulum

1. **Asistan Beta 0.7.1 Kurulum.zip** dosyasını diğer Mac’e aktarın ve çift tıklayarak açın. İçindeki **Asistan Beta.app** dosyasını Finder’ın **Uygulamalar** klasörüne sürükleyin. İlk kez açmadan önce taşıyın; ZIP içinden veya geçici bir klasörden çalıştırmayın.
2. Uygulamalar’dan Beta’ya çift tıklayın. Beta menü çubuğunda çalışır; penceresi kapanırsa uygulamaya yeniden çift tıklayarak **Kurulum ve durum** ekranını açabilirsiniz. Üstte **Sürüm 0.7.1 · Derleme 17** görünmelidir.
3. **Ortamı kur (internet gerekir)** düğmesine basın. Python 3.12, gerekli paketler, Whisper konuşma tanıma modeli ve Türkçe EMA ses modeli indirilir. **Kurulum ayrıntıları** sekmesinden ilerlemeyi izleyin. Model indirmeleri nedeniyle ilk kurulum sonraki açılışlardan daha uzun sürebilir. **Ortam kuruldu** mesajını bekleyin.
4. **Modeller ve API anahtarları…** ekranında görüşme ve özet modelini seçip gereken Anthropic ve/veya OpenAI anahtarını girin. Anahtarları uygulamadaki gizli alanlara yazın. Yeni Mac’e anahtarlar ve kişiselleştirme ayarları bu paketle taşınmaz.
5. Loopback’i ayrıca kurup kendi izinlerini tamamlayın. Aşağıdaki üç aygıtı oluşturun. FaceTime/WhatsApp/Telefon mikrofonunu **Asistan Mikrofonu** seçin; hoparlörü gerçek hoparlör/kulaklık olarak bırakın. BlackHole gerekmez.
6. Beta’nın **İzinleri iste** düğmesiyle mikrofon ve erişilebilirlik izinlerini tamamlayın. Rehber isteğe bağlıdır. Erişilebilirlik listesine **Uygulamalar’daki Beta** eklenmelidir. Ekrandaki işaretler çalışan Beta’nın gerçekten kullanabildiği izni gösterir.
7. **Beta’yı başlat** düğmesine basın. **Asistan Beta hazır** ve **Whisper ve Türkçe ses sınandı** göründükten sonra isterseniz **Seçili modellerin bağlantısını sına** ile model erişimini doğrulayın. Bu test küçük bir ücretli API isteği gönderir; görüşme içeriği göndermez.
8. Önceki Mac’te Beta’yı kapatıp yeni Mac’e bir deneme araması yapın. WhatsApp ile iPhone/FaceTime’ı ayrı ayrı deneyin. Hazır durumu ses hattının karşı uçta duyulduğunu veya uygulamanın doğru mikrofonu seçtiğini tek başına kanıtlamaz.

Codex, Xcode, Homebrew veya elle kurulmuş Python gerekmez. Uygulama kendi konuşma ortamını hazırlar. API kullanımı ve ilk indirmeler internet gerektirir. Kullanıcı verileri otomatik olarak bu Mac’in `~/Documents/Codex/Asistan Beta Data` klasöründe oluşturulur; başka Mac’in Python ortamını kopyalamayın. Uygulamalar klasöründe yalnızca uygulama dosyası bulunması yeterlidir; kaynak ve belge klasörleri çalışma için zorunlu değildir.

## Bilgisayar gereklilikleri ve denetim kapsamı

- **Apple Silicon (M1/M2/M3/M4 ve sonraki Apple işlemcileri)** gerekir; mevcut sürüm Intel Mac için hazırlanmadı. Beta’nın alt sınırı macOS 14.2’dir. Güncel Loopback 2.5.0 için üreticinin belirttiği aralık macOS **14.5–27** olduğundan, yeni kurulumda macOS 14.5 veya üstü ve bu sistemle uyumlu Loopback kullanın. [Loopback’in resmi sayfası](https://rogueamoeba.com/loopback/).
- Beta yerel ortamın varlığını, üç ses aygıtını, erişilebilirlik ve mikrofon izinlerini, model/anahtar ayarlarını kontrol eder. Kurulum **Whisper ile kısa tanıma ve EMA ile ses üretimi** yapmadan başarılı işareti oluşturmaz. Her Beta açılışında modeller tekrar çalıştırılarak hazırlanır; **Whisper ve Türkçe ses sınandı** bu gerçek hazırlığın sonucudur.
- Kurulum kaydı tek başına model/paket dosyalarının sonradan bozulmadığını kanıtlamaz. Ajan açılmıyorsa günlüğe bakın; durmuş ajanla **Ortamı onar / modelleri sına** düğmesi paketleri ve modelleri yeniden doğrular. Model önbelleklerini sildiyseniz tekrar internet gerekir.
- Beta Loopback’i veya onun lisansını otomatik kurmaz. Aygıt isimlerinin bulunması Loopback kaynaklarını, kanal bağlantılarını, **Mute when capturing** ve WhatsApp/FaceTime mikrofon seçimini tamamen denetlediği anlamına gelmez; aşağıdaki düzene göre ayrıca kontrol edin. iPhone–Mac arama aktarımı veya WhatsApp masaüstü de hazırlanmış olmalıdır.
- ZIP’e API anahtarları, kişisel görüşmeler, Python ortamı ve indirilmiş model önbellekleri dahil değildir. Yerel ses işleme bu Mac’te yapılır; metin yanıtı/özet için seçtiğiniz bulut sağlayıcısı kullanılır.

## İlk açılışta macOS uyarısı

Bu kişisel dağıtım Apple tarafından notarize edilmemiştir; başka Mac’te geliştirici doğrulama uyarısı çıkabilir. Güvendiğiniz bu paketi açma kararını kendiniz verin. macOS izin veriyorsa, ilk açılış denemesinden sonra **Sistem Ayarları → Gizlilik ve Güvenlik → Yine de Aç (Open Anyway)** yoluyla uygulama için onay verebilirsiniz. Genel güvenlik korumalarını kapatmayın. [Apple’ın resmi açıklaması](https://support.apple.com/en-gb/102445).

## Loopback düzeni ve isteğe bağlı Codex yardımı

Aşağıdaki talimatı diğer bilgisayardaki Codex sohbetine yapıştırıp bu belgeyi veya paket klasörünü ekleyebilirsiniz. Önceki sohbet geçmişi gerekmez. Codex kullanmak zorunlu değildir; aynı aygıt düzenini elle de kurabilirsiniz.

## Yeni sohbete yapıştırılacak talimat

Bu Mac’te Asistan Beta’yı kurmanı ve Loopback ayarlarını aşağıdaki düzene göre yapmanı istiyorum. Kurulum işlemlerini gerçekleştir; yalnızca anlatmakla kalma. Eklediğim Asistan Beta paketini/klasörünü incele. Mevcut Loopback ayarlarını değiştirmeden önce yedekle. Asistan Alpha varsa ona dokunma. Beta bağımsız çalışmalı; bir seçici uygulama gerekmez.

Paket sürümü 0.7.1. Mevcut uygulama Apple Silicon ve macOS 14.2 veya üzerini gerektiriyor; önce bu Mac’in uyumluluğunu kontrol et. Yeni sistemde önceki bilgisayarın mutlak dosya yollarını veya Python ortamını kullanma. Beta verileri bu kullanıcının ~/Documents/Codex/Asistan Beta Data klasöründe tutulur. Paket içindeki README.md, DOGRULAMA.md ve WHATSAPP_COZUM.md belgelerini oku. Uygulamayı /Applications (Uygulamalar) klasörüne yerleştir ve Beta’nın kurulum ekranından Python/paket/model hazırlığını tamamla. API anahtarlarını sohbete isteme veya yazdırma; Modeller ve API anahtarları ekranına benim girmemi sağla. Seçtiğim görüşme/özet sağlayıcılarına göre gerekli Anthropic ve/veya OpenAI anahtarını kullan. İstersem kurulum ekranından seçili modellerin bağlantısını küçük bir deneme isteğiyle sına. macOS’un kişisel kimlik doğrulaması isteyen adımlarını bana bırak.

**Ses düzeni:** BlackHole gerekmiyor. Beta arama başında, sonunda veya Devral’da sistem aygıtlarını değiştirmemeli. Loopback’te adları aşağıdaki gibi olan, iki kanallı üç ayrı sanal aygıt oluştur veya mevcut doğru aygıtları kullan. Her aygıtın ana anahtarı On olmalı.

1. **Asistan Ses Çıkışı:** Yalnızca Pass-Thru açık. Başka kaynak veya monitör yok. Beta’nın ürettiği ses bu aygıta gönderilir.
2. **Asistan Mikrofonu:** Pass-Thru kapalı. Kaynak olarak sanal ses aygıtı **Asistan Ses Çıkışı** açık; kanal 1→1 ve 2→2. Fiziksel mikrofon, BlackHole veya uygulama kaynağı ekleme. Monitör yok. Bu ayrı aygıt WhatsApp’ın mikrofon listesinde görünmesi için gerekli.
3. **Asistan Dinleme:** Pass-Thru kapalı. FaceTime, WhatsApp ve bu Mac’te varsa Telefon/Phone uygulamaları kaynak olarak açık. Her kaynakta kanal 1→1, 2→2. Her uygulama kaynağında **Mute when capturing açık**. Monitör yok. Böylece Beta arayanı dinlerken ses ayrıca bilgisayar hoparlöründen çalmaz.

FaceTime’ın Video menüsünde, WhatsApp’ın Call menüsünde ve Telefon/Phone varsa Audio menüsünde mikrofonu **Asistan Mikrofonu**, hoparlörü bu Mac’in gerçek hoparlörü veya kullanacağım kulaklık olarak seç. Önceki Mac’teki MacBook Air Speakers adını bu bilgisayarda varsayma. Asistan Dinleme ve Asistan Ses Çıkışı’nı arama uygulamasının mikrofonu olarak seçme. Sistem varsayılan mikrofon/hoparlörünü fiziksel aygıtlarda bırak. WhatsApp yeni aygıtı görmüyorsa açık görüşme olmadığını kontrol edip uygulamayı tamamen kapat ve yeniden aç.

Beta’nın kullandığı giriş **Asistan Dinleme**, çıkış **Asistan Ses Çıkışı** olmalı. Erişilebilirlik ve mikrofon izinlerinin yalnızca Ayarlar’da açık görünmesini değil, çalışan Beta’da gerçekten kullanılabildiğini ve ses modellerinin hazır olduğunu doğrula. Güncellemeden sonra mevcut erişilebilirlik kaydı tanınmazsa doğru uygulama dosyasıyla aynı izni yenile.

iPhone aramalarının bu Mac’e ulaştığını da kontrol et; gerekirse iPhone–Mac arama aktarımını kurmama yardımcı ol. Gerçek aramayı ben başka telefondan başlatacağım. Aynı aramayı iki bilgisayardaki Beta’nın birlikte karşılamaması için deneme sırasında önceki bilgisayardaki Beta’yı kapatmamı hatırlat.

WhatsApp ve iPhone/FaceTime sesli aramalarını ayrı ayrı test et: Beta penceresi görünmeli, Beta ile Cevapla aramayı açmalı, iki yönlü konuşma çalışmalı, arayanın adı ekranda varsa doğru okunmalı, araya girdiğimde asistan susmalı, Sonlandır aramayı kapatmalı ve Python ajanı sonrasında hazır kalmalı. Arayan bilgisi yoksa Bilinmiyor görünmesi doğru; SceneWindow gibi teknik kimlikler isim sayılmamalı.

**Devral’ı ayrıca test et:** asistan susarken benim fiziksel mikrofonum aynı sabit hatta aktarılmalı, karşı taraf beni duymalı ve ben de arayanı duyabilmeliyim. Mute when capturing açıkken Devral’da arayanı duyma önceki bilgisayarda henüz doğrulanmadı. Bu davranışı test etmeden çalışıyor sayma; gerekiyorsa mevcut düzeni yedekleyerek uygun dinleme/monitör çözümü hazırla ve yankı olmadığını kontrol et. Sadece uygulamanın hazır olması veya aygıtların görünmesi, iki yönlü sesi doğrulamaz.

Kurulum bittiğinde uygulamanın yerini, nasıl açacağımı, hangi canlı testlerin geçtiğini ve varsa kalan eksikleri kısa biçimde bildir. Görüşme içeriğini veya API anahtarını dağıtım paketine ekleme.


## İsteğe bağlı GPT-Live 1 modu

Varsayılan yerel mod korunur. Kurulumdan önce Modeller ve API anahtarları ekranında Ses modu → Çevrimiçi ses — GPT-Live 1 seçip gerekli anahtarları kaydedebilirsiniz. GPT-Live için OpenAI anahtarı gerekir; Claude arka plan/özet seçiliyse Anthropic anahtarı da gerekir. Çevrimiçi modu seçtiğinizde kurulum yalnızca ses bağlantısı ortamını hazırlar; Whisper/EMA modelleri indirilmez. Yerel moda daha sonra dönerseniz tam ortam/model kurulumu gerekir. Var olan yerel ortamda GPT-Live için yeniden kurulum gerekmez; WebSocket kitaplığı uygulama içinde bulunur.

GPT-Live modunda ses OpenAI'ye gider. Mevcut Loopback düzenini koruyun. Önce Seçili modellerin bağlantısını sına düğmesiyle hesap erişimini kontrol edin, sonra gerçek aramayla Türkçe, söz kesme, kullanıcı notu, Devral ve kapatmayı deneyin. Bağlantı testi veya uygulamanın hazır görünmesi bu canlı davranışları doğrulamaz. Hesap GPT-Live erişimine sahip değilse yerel modu kullanmaya devam edin.


## Asistan Mobile ve Odak (0.7.1)

Telefondaki mevcut Asistan Mobile uygulamasıyla çalışır. Yeni Mac'te Beta → iPhone ve Odak… → Asistan Mobile bağlantısını aç. Yerel ağ iznini ver. Telefonla aynı Wi-Fi'de, mobil uygulamada Mac adresi alanını boşaltıp listeden adı Asistan Beta ile biten Mac'i seç ve bu Mac'teki Beta kodunu gir. Diğer bilgisayarın veya Alpha'nın eşleştirme kodu taşınmaz. Beta kendi 47822 portunu kullanır; mevcut mobil uygulamanın sabit 47821 portlu elle IP alanını kullanma.

Odak açıkken otomatik cevaplamayı ayrıca açabilirsin. Durum okunamıyorsa yalnızca bu özellik için Tam Disk Erişimi verip Beta'yı yeniden başlat. Kurulum ve durum → iPhone ve Odak sekmesinden iki özelliği kontrol et. Yeni bilgisayarda hazır görünmesi gerçek telefon görüşmesinin doğrulanması değildir; cevapla, not gönder, söz kesme, sonlandır ve Odak açık/kapalı geçişlerini bir deneme aramasıyla doğrula.


## Yeni model ve ses listesi

0.7.1 Modeller ve API anahtarları ekranında Claude Haiku 5.5 arka plan ve özet için seçilebilir. GPT-Live modunda GPT-Live sesi alanından 31 yerleşik ses seçilir; eski Marin varsayılanı korunur. Seçim bu Mac'in Beta verisinde saklanır ve Kaydet ve uygula sonrası yeni görüşmede kullanılır. Hesap erişimini kurulum ekranından sına; ses/Türkçe kalitesini gerçek aramayla dene. Telefon ve FaceTime mikrofonu Asistan Mikrofonu, hoparlör fiziksel hoparlör seçili olsun. Sistem ayarını kullan seçimi Beta'nın sesini arayana ulaştırmayabilir.
