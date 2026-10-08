#!/bin/bash
# Bir kerelik: Asistan.app'i sabit bir kimlikle imzalamak için yerel sertifika oluşturur.
# Böylece uygulamayı yeniden derleyince Erişilebilirlik/Rehber izinleri silinmez.
set -e
cd "$(mktemp -d)"
NAME="AsistanLocal"
cat > openssl.cnf <<CNF
[req]
distinguished_name=dn
x509_extensions=ext
prompt=no
[dn]
CN=$NAME
[ext]
basicConstraints=critical,CA:false
keyUsage=critical,digitalSignature
extendedKeyUsage=critical,codeSigning
CNF
openssl req -x509 -newkey rsa:2048 -nodes -keyout key.pem -out cert.pem -days 3650 -config openssl.cnf
openssl pkcs12 -export -legacy -out asistan.p12 -inkey key.pem -in cert.pem -passout pass:asistan 2>/dev/null \
  || openssl pkcs12 -export -out asistan.p12 -inkey key.pem -in cert.pem -passout pass:asistan
security import asistan.p12 -k "$HOME/Library/Keychains/login.keychain-db" -P asistan -T /usr/bin/codesign
echo "Sertifika güven ayarı için macOS parolanı soracak:"
security add-trusted-cert -r trustRoot -p codeSign -k "$HOME/Library/Keychains/login.keychain-db" cert.pem
echo "Tamam. Kimlikler:"
security find-identity -p codesigning
