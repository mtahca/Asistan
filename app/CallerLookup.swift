import Foundation
import ApplicationServices
import Contacts

// MARK: - Arayan bilgisi (banner metni + Rehber)

/// Rehberden eksik bilgiyi (isim <-> numara) tamamlar
func enrichFromContacts(_ info: CallerInfo) -> CallerInfo {
    var out = info
    guard CNContactStore.authorizationStatus(for: .contacts) == .authorized else {
        logLine("Rehber izni yok; sadece banner bilgisi kullanılıyor")
        return out
    }
    let store = CNContactStore()
    let keys: [CNKeyDescriptor] = [CNContactGivenNameKey as CNKeyDescriptor,
                                   CNContactFamilyNameKey as CNKeyDescriptor,
                                   CNContactNicknameKey as CNKeyDescriptor,
                                   CNContactPhoneNumbersKey as CNKeyDescriptor]
    func fullName(_ c: CNContact) -> String {
        let n = "\(c.givenName) \(c.familyName)".trimmingCharacters(in: .whitespaces)
        return n.isEmpty ? c.nickname : n
    }
    do {
        if !info.number.isEmpty && info.name.isEmpty {
            let pred = CNContact.predicateForContacts(matching: CNPhoneNumber(stringValue: info.number))
            if let c = try store.unifiedContacts(matching: pred, keysToFetch: keys).first {
                out.name = fullName(c)
                out.inContacts = true
            }
        } else if !info.name.isEmpty {
            let pred = CNContact.predicateForContacts(matchingName: info.name)
            var matches = try store.unifiedContacts(matching: pred, keysToFetch: keys)
            if matches.isEmpty {
                // takma ad ("Aşkım" gibi) için tüm kişilerde ara
                let req = CNContactFetchRequest(keysToFetch: keys)
                var found: [CNContact] = []
                try store.enumerateContacts(with: req) { c, _ in
                    if c.nickname.lowercased() == info.name.lowercased() { found.append(c) }
                }
                matches = found
            }
            if matches.count == 1, let c = matches.first,
               fullName(c).caseInsensitiveCompare(info.name) == .orderedSame || c.nickname.caseInsensitiveCompare(info.name) == .orderedSame {
                out.inContacts = true
                // The actual incoming number must come from the call, not the first contact number.
                let fn = fullName(c)
                if !fn.isEmpty && fn.lowercased() != info.name.lowercased() { out.name = "\(info.name) (\(fn))" }
            }
        }
    } catch {
        logLine("Rehber araması başarısız: \(error)")
    }
    return out
}



/// Controls belong to the call source captured when answering, never another app.
func callControl(for source: CallSource) -> AXUIElement? { CallObserver.shared.control(source) }
