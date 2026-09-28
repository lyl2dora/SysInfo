import Foundation
let ud = UserDefaults.standard
print("NSGlassTintAmount via UserDefaults.standard:", ud.object(forKey: "NSGlassTintAmount") as Any)
print("NSGlassBuddyTintAmount:", ud.object(forKey: "NSGlassBuddyTintAmount") as Any)
let g = UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain) ?? [:]
print("global-domain keys with 'Glass':", g.keys.filter { $0.localizedCaseInsensitiveContains("glass") }.sorted())
