# Mimari ve sınırlar

Asistan 0.8 tek bir uygulamadır (`com.mtahca.asistan`). Alpha ve Beta ayrımı kalktı. Uygulama ilk açılışta Beta'nın veri klasörünü ve tercihlerini bir kez devralır. Taşıma hiçbir şey silmez. Beta açıksa ya da klasör taşınamazsa eski klasör yerinde kullanılmaya devam eder.

Swift tarafı menüyü, izinleri ve kurulumu, arama algılamayı, arayan kimliğini ve kullanıcı pencerelerini yönetir. Python ajanı ses ve model işlerini ayrı bir süreçte yürütür; durum ve canlı metni yapılandırılmış olaylarla Swift'e iletir. Arama bağlantısı doğrulanmadan ajan konuşmaya başlamaz.

Sabit üç Loopback aygıtı, sistemin ses aygıtlarını değiştirme ihtiyacını ortadan kaldırır. Arama uygulamaları Asistan Mikrofonu'nu kullanır. Asistan, Asistan Dinleme'den dinler ve Asistan Ses Çıkışı'na konuşur. Devral fiziksel mikrofonu aynı hatta aktarır.

Yerel ve GPT-Live ses akışları ayrı seçeneklerdir. Arka plan/özet sağlayıcısı ve modeli ayrıca seçilebilir. Ayar değişiklikleri etkin görüşme sırasında uygulanmaz. API anahtarları yayınlanan kaynaklarda bulunmaz.

Asistan Mobile uyumluluğu mevcut v1 TLS-PSK protokolüyle korunur. Port 47821'dir; Mobile'ın elle adres alanı da bu porta bağlanır. Bağlantı sayısı, çerçeve boyutu, gönderim kuyruğu ve komut sıklığı sınırlandırılmıştır. Yeniden bağlanan telefon canlı metni sınırlı bir bellekten alır; telefona ham ses gitmez. Eşleştirme kodunu bilen yerel ağdaki cihazlar cevaplama, not ve sonlandırma komutlarını kullanabilir.

Canlı pencere metni her güncellemede yeniden çizer. Kullanıcı yukarı kaydırmışsa okuma konumu korunur; yalnızca en alttayken yeni satırlar izlenir. Son görüşmeler menüsü notlar klasöründeki dosya adlarından ve not başlığındaki "Arayan ekranı" satırından oluşturulur. Menü her açıldığında yeniden okunur.

Odak otomatik cevaplama isteğe bağlıdır. Genel otomatik cevaplama tercihini değiştirmez. Duraklatma her iki yolu da engeller. Okunamayan veya tanınmayan Odak verisi otomatik cevap tetiklemez.

Arayan adı ekran bilgisidir, kimlik doğrulaması değildir. Geçmiş görüşmeler veya kişi kartları taranarak etkin aramaya isim atanmaz. Teknik pencere adları filtrelenir; bilgi yoksa Bilinmiyor gösterilir.

Kalan canlı doğrulama sınırları ve test kapsamı [DOGRULAMA.md](DOGRULAMA.md) içindedir.
