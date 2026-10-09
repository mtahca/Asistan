# Beta mimarisi ve sınırlar

Beta bağımsız bir uygulama kimliği ve veri klasörü kullanır. Reponun kökündeki Alpha kaynaklarını değiştirmez; bir seçici uygulama gerektirmez. Aynı aramayı birlikte yönetmemeleri için geçişte diğer uygulamadan çıkılmalıdır.

Native Swift menü, izin/kurulum, arama algılama, arayan kimliği ve kullanıcı pencerelerini yönetir. Python ajanı ayrı süreçte ses/model işlerini yürütür; yapılandırılmış olaylarla Swift'e durum ve canlı metin iletir. Arama bağlantısı doğrulanmadan ajan konuşmaya başlamaz.

Sabit üç Loopback aygıtı sistemin ses aygıtlarını değiştirme ihtiyacını kaldırır. Arama uygulamaları Asistan Mikrofonu'nu kullanır; Beta Asistan Dinleme'den dinler ve Asistan Ses Çıkışı'na konuşur. Devral aynı hatta fiziksel mikrofonu aktarır.

Yerel ve GPT-Live ses akışları ayrı seçeneklerdir. Arka plan/özet sağlayıcısı ve model ayrıca seçilebilir. Ayarlar etkin görüşme sırasında uygulanmaz. API anahtarları yayınlanan kaynaklarda bulunmaz.

Asistan Mobile uyumluluğu mevcut v1 TLS-PSK protokolünü korur; Beta ayrı Bonjour adı, port ve eşleştirme kodu kullanır. Bağlantı, çerçeve, gönderim kuyruğu ve komut oranı sınırlandırılır. Canlı metin yeniden bağlantıda sınırlı bellekten alınır; telefon ham ses almaz. Eşleştirme kodunu bilen yerel ağ cihazları cevaplama/not/sonlandırma komutlarını kullanabilir.

Odak otomatik cevaplama isteğe bağlıdır. Genel otomatik cevaplama tercihini değiştirmez; duraklatma her iki yolu engeller. Okunamayan veya tanınmayan Odak verisi otomatik cevap tetiklemez.

Arayan adı ekran bilgisidir; kimlik doğrulaması değildir. Geçmiş görüşmeler veya kişi kartları taranarak aktif aramaya isim atanmaz. Teknik pencere adları filtrelenir; bilgi yoksa Bilinmiyor gösterilir.

Kalan canlı doğrulama sınırları ve test kapsamı [DOGRULAMA.md](DOGRULAMA.md) içindedir.
