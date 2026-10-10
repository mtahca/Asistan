# Asistan sanal ses sürücüsü (deneme)

Loopback'in yerine geçebilecek, ücretsiz kendi ses sürücümüz. Şimdilik Asistan'a bağlı değil; önce tek başına çalıştığını sınıyoruz.

İki aygıt oluşturur. Birine çalınan ses diğerinden mikrofon olarak gelir:

| Aygıt | Yön | Kim kullanır |
|---|---|---|
| **Asistan Sanal Çıkış** | yalnızca çıkış | asistan buraya konuşur |
| **Asistan Sanal Mikrofon** | yalnızca giriş | WhatsApp/FaceTime/Telefon mikrofon olarak seçer |

BlackHole'u WhatsApp, tek aygıtta hem giriş hem çıkış olduğu için listelemiyordu (tahmin). Burada mikrofon yalnızca giriş olan ayrı bir aygıt; Loopback'teki "Asistan Mikrofonu" düzeninin aynısı.

Kaynak: [BlackHole](https://github.com/ExistentialAudio/BlackHole) v0.7.2, GPL-3.0. Kod değiştirilmez; yalnızca ad, yön ve örnekleme hızı derleme ayarlarıyla verilir. Lisans metni sürücü paketinin içindedir.

## Kurulum ve test (Mac'te, depo klasöründen)

```bash
bash driver/build.sh        # Komut Satırı Araçları yeterli, Xcode gerekmez
bash driver/install.sh      # yönetici parolası ister, Core Audio'yu yeniden başlatır
"$HOME/Documents/Asistan Data/.venv/bin/python" driver/test.py   # ton testi
```

Ardından elle:
1. WhatsApp → Call → Microphone listesinde **Asistan Sanal Mikrofon** görünüyor mu?
2. Görünüyorsa seçin ve bir test aramasında `say -a "Asistan Sanal Çıkış" "Merhaba, bu bir deneme"` komutuyla karşı tarafa ses gidiyor mu bakın.
3. Aynısını FaceTime (Video menüsü) ve Telefon (Audio menüsü) için deneyin.

Kaldırmak için: `bash driver/uninstall.sh`
