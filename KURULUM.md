# Asistan — Yeni Mac'e Kurulum

1. `Asistan.zip` dosyasını yeni Mac'e kopyala (AirDrop/USB), aç, `Asistan.app`'i Uygulamalar'a taşı.
2. Terminal: `xattr -dr com.apple.quarantine /Applications/Asistan.app`
   (ya da uygulamaya sağ tık > Aç).
3. Uygulamayı aç. Kurulum penceresi açılır:
   - Loopback (Rogue Amoeba, ücretli): kurulu olmalı; aşağıdaki "Loopback aygıtları" bölümüne göre 3 aygıt oluştur.
   - "Kurulumu başlat": Python 3.12, paketler ve Whisper modeli otomatik iner (birkaç dakika, ~1.5 GB).
   - Anthropic API anahtarını gir, "Kaydet". (OpenAI kullanmak ya da model değiştirmek için: menü > Asistan ayarları.)
   - "İzinleri iste": Mikrofon, Rehber, Erişilebilirlik (Cihaz Kontrolü ve Veri Erişimi).
4. FaceTime: mikrofon/hoparlör "Sistem Ayarını Kullan" kalsın; Asistan, arama sırasında mikrofonu kendisi Asistan Mikrofonu'na alır ve sonra geri döner.
   WhatsApp: Call > Microphone > **Asistan Mikrofonu** (bir kez); Speaker: kendi hoparlörün. WhatsApp kaynağı Asistan Dinleme'de ekli olmalı.
5. Bildirim ayarlarında FaceTime çağrı banner'ı görünür olmalı.
6. iPhone'da: Ayarlar > Telefon > Diğer Cihazlarda Aramalar'ı aç.

Veriler: ~/Library/Application Support/Asistan (notlar, .env, .venv).
Not: imza kendinden imzalı; yeni Mac'te izinleri bir kez vermen gerekir.

## Günlük kullanım
- Menü çubuğundaki ahize simgesi: içi dolu = görüşmede, dalga işaretli = asistan yükleniyor.
- Gelen aramada küçük panel çıkar: "Asistanla cevapla" ya da aramayı elle aç (asistan karışmaz).
- Görüşme sırasında: canlı metin penceresi (⌘L), not yaz → asistan arayana iletir, Devral (⌘D), Sonlandır (⌘E).
- Notlar: menü > Son notu aç / Notlar klasörü. Sorun olursa: menü > Kayıt dosyasını aç (app.log).

## Loopback aygıtları (BlackHole artık kullanılmıyor)
Sistem ses ayarları hiç değişmez; her şey üç sabit Loopback aygıtıyla çalışır. Loopback'te oluştur, adlarını birebir yaz ve üçünün ana anahtarını **Açık** yap:

1. **Asistan Ses Çıkışı** — Pass-Thru **açık**; başka kaynak / monitör yok. (Asistanın sesi buraya gelir.)
2. **Asistan Mikrofonu** — Pass-Thru kapalı; kaynak: *Asistan Ses Çıkışı* (kanal 1–2 → 1–2). Arama uygulamalarının mikrofonu budur.
3. **Asistan Dinleme** — Pass-Thru kapalı; kaynaklar: *FaceTime*, *Telefon* (ve varsa *WhatsApp*) uygulamaları, kanal 1–2. **Mute when capturing** açık (arayanın sesi hoparlörden ayrıca çıkmaz).

Doğrulama: Asistan menüsü > Ses ayarları… üç aygıtın da ✅ olduğunu gösterir. WhatsApp mikrofon listesinde görünmezse WhatsApp'ı tamamen kapatıp aç.
- **Devral**: asistan çıkar, fiziksel mikrofonun otomatik olarak Asistan Ses Çıkışı'na aktarılır (arama uygulaması mikrofonu değişmeden sesin karşıya gider). Asistan Dinleme kapandığı için arayanı hoparlörden duyarsın. Arama bitince köprü kendiliğinden kapanır.
- **Normal aramalar**: WhatsApp mikrofonu Asistan Mikrofonu'nda kaldıysa menüden "Mikrofonumu aramaya aktar (köprü)" ile sesin gider (ya da WhatsApp mikrofonunu geri değiştir).
