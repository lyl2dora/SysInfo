import sys,re
S="/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk/"
P={"SwiftUI":"System/Library/Frameworks/SwiftUI.framework/Versions/A/Modules/SwiftUI.swiftmodule/arm64e-apple-macos.swiftinterface",
"SwiftUICore":"System/Library/Frameworks/SwiftUICore.framework/Versions/A/Modules/SwiftUICore.swiftmodule/arm64e-apple-macos.swiftinterface",
"Charts":"System/Library/Frameworks/Charts.framework/Versions/A/Modules/Charts.swiftmodule/arm64e-apple-macos.swiftinterface",
"Observation":"usr/lib/swift/Observation.swiftmodule/arm64e-apple-macos.swiftinterface",
"WidgetKit":"System/Library/Frameworks/WidgetKit.framework/Versions/A/Modules/WidgetKit.swiftmodule/arm64e-apple-macos.swiftinterface",
"Symbols":"System/Library/Frameworks/Symbols.framework/Versions/A/Modules/Symbols.swiftmodule/arm64e-apple-macos.swiftinterface"}
cache={}
def lines(m):
    if m not in cache: cache[m]=open(S+P[m]).read().split("\n")
    return cache[m]
for arg in sys.argv[1:]:
    m,pat=arg.split(":",1)
    L=lines(m)
    for i,l in enumerate(L):
        if re.search(pat,l):
            # collect preceding availability lines (walk back through attr lines)
            av=[]
            j=i
            if '@available' in l: av.append(l.strip()[:200])
            k=i-1
            while k>=0 and (L[k].strip().startswith('@') or L[k].strip().startswith('#if') ):
                if '@available' in L[k]: av.insert(0,L[k].strip()[:200])
                k-=1
            print(f"{m} L{i+1}: {l.strip()[:160]}\n    AV: {' | '.join(av) if av else '(inherits enclosing)'}")
            break
    else:
        print(f"{m}: NOT FOUND {pat}")
