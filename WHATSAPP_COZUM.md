# WhatsApp ve Loopback

Loopback'te iki kanallı üç aygıt oluşturun. Hepsinin ana anahtarı açık olmalıdır:

1. **Asistan Ses Çıkışı:** yalnızca Pass-Thru açık; başka kaynak veya monitör yok.
2. **Asistan Mikrofonu:** Pass-Thru kapalı; kaynak Asistan Ses Çıkışı sanal aygıtı. Kanallar 1→1, 2→2. Fiziksel mikrofon, BlackHole veya monitör eklemeyin.
3. **Asistan Dinleme:** Pass-Thru kapalı; WhatsApp, FaceTime, varsa Phone/Telefon uygulamaları kaynak. Kanallar 1→1, 2→2. Her uygulama kaynağında Mute when capturing açık; monitör yok.

WhatsApp **Call → Microphone → Asistan Mikrofonu**, **Call → Speaker** alanından fiziksel hoparlör veya kulaklık seçin. Mikrofon görünmezse aktif görüşme yokken WhatsApp'ı tamamen kapatıp açın. Asistan Dinleme ve Asistan Ses Çıkışı'nı WhatsApp mikrofonu seçmeyin. Sistem varsayılanlarını fiziksel aygıtlarda bırakın.

Phone/Telefon **Audio**, FaceTime **Video** menüsünde de mikrofonu **Asistan Mikrofonu** seçin. Asistan 0.8.1 bu seçimi her görüşmede kendisi de yapar ve doğrular; **Ses ayarları… → Uygulamaları denetle ve düzelt** ile görüşmeden önce kontrol edebilirsiniz. Sistem ayarını kullan seçimi Asistan'ın sesini karşı tarafa göndermeyebilir veya yanlış girişle eko oluşturabilir.

Asistan bu sabit hatta çalışır; BlackHole gerekmez. **Devral** yapay sesi durdurup fiziksel mikrofonu aynı hatta aktarır. Asistan kapalıyken normal konuşma için arama uygulamasında fiziksel mikrofon seçin.

Asistan WhatsApp sesli aramasını algılar, bağlantıyı doğrular ve konuşmaya başlar; görüntülü aramalar kapsam dışıdır. Görünen arayan metni kullanılır, SceneWindow gibi teknik kimlikler isim sayılmaz. İsim/numara sunulmuyorsa Bilinmiyor gösterilir.

Devral sonrası Mute when capturing açıkken arayanı duyma ayrıca canlı test gerektirir. Kulaklıkla deneyin; duyamıyorsanız mevcut düzeni yedekleyerek ilgili uygulama kaynağının sessize alma ayarını kontrol edin. Hazır durumu veya aygıtların listelenmesi iki yönlü sesi doğrulamaz.

Kaynaklar: [Loopback Pass-Thru](https://rogueamoeba.com/support/manuals/loopback/?page=passthru), [kaynaklar](https://rogueamoeba.com/support/manuals/loopback/?page=sources), [arama uygulamaları](https://rogueamoeba.com/support/knowledgebase/?showArticle=LB-VoIP).
