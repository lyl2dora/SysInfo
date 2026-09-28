# Review: independent decode of pmgr voltage-states* tables from `ioreg -p IODeviceTree -r -n pmgr -a` (plist), using ioreg CLI instead of IOKit API.
import plistlib, struct, sys
d = plistlib.load(open(sys.argv[1], 'rb'))
node = d[0] if isinstance(d, list) else d
for k in sorted(node):
    if not k.startswith('voltage-states'): continue
    v = node[k]
    if not isinstance(v, bytes): continue
    pairs = [struct.unpack_from('<II', v, o) for o in range(0, len(v) - 7, 8)]
    f = [p[0] for p in pairs]; mv = [p[1] for p in pairs]
    print(f"{k:26s} n={len(pairs):2d} raw_first={f[:2]} raw_last={f[-1]} second_field_range={min(mv)}..{max(mv)}")
