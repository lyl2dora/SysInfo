# Review probe: NET_RT_IFLIST2 en0 byte counters read from a Python interpreter via ctypes (tests signer/platform dependence)
import ctypes, struct, sys, os
libc = ctypes.CDLL(None, use_errno=True)
mib = (ctypes.c_int * 6)(4, 17, 0, 0, 6, 7)
buf = ctypes.create_string_buffer(65536); ln = ctypes.c_size_t(65536)
rc = libc.sysctl(mib, 6, buf, ctypes.byref(ln), None, ctypes.c_size_t(0))
raw = buf.raw[:ln.value]; off = 0
while off < len(raw):
    msglen, ver, typ = struct.unpack_from("HBB", raw, off)
    if not msglen: break
    if typ == 18:
        idx = struct.unpack_from("H", raw, off + 12)[0]
        ib, ob = struct.unpack_from("QQ", raw, off + 96)
        print(f"{os.path.realpath(sys.executable)} rc={rc} idx={idx} ibytes={ib} obytes={ob}")
    off += msglen
