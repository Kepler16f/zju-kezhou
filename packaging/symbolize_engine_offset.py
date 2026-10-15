import ctypes
import ctypes.wintypes as wt
import sys

MAX = 2000


class SI(ctypes.Structure):
    _fields_ = [('SizeOfStruct', wt.ULONG), ('TypeIndex', wt.ULONG), ('Reserved', ctypes.c_ulonglong * 2),
                ('Index', wt.ULONG), ('Size', wt.ULONG), ('ModBase', ctypes.c_ulonglong), ('Flags', wt.ULONG),
                ('Value', ctypes.c_ulonglong), ('Address', ctypes.c_ulonglong), ('Register', wt.ULONG),
                ('Scope', wt.ULONG), ('Tag', wt.ULONG), ('NameLen', wt.ULONG), ('MaxNameLen', wt.ULONG),
                ('Name', ctypes.c_char * (MAX + 1))]


class LN(ctypes.Structure):
    _fields_ = [('SizeOfStruct', wt.DWORD), ('Key', ctypes.c_void_p), ('LineNumber', wt.DWORD),
                ('FileName', ctypes.c_char_p), ('Address', ctypes.c_ulonglong)]


d = ctypes.WinDLL('dbghelp.dll')
k = ctypes.WinDLL('kernel32.dll')

d.SymSetOptions.argtypes = [wt.DWORD]
d.SymSetOptions.restype = wt.DWORD
d.SymSetOptions(0x02 | 0x04 | 0x10 | 0x200)

d.SymInitialize.argtypes = [ctypes.c_void_p, ctypes.c_char_p, wt.BOOL]
d.SymInitialize.restype = wt.BOOL

d.SymLoadModuleEx.argtypes = [ctypes.c_void_p, ctypes.c_void_p, ctypes.c_char_p, ctypes.c_char_p,
                              ctypes.c_ulonglong, wt.DWORD, ctypes.c_void_p, wt.DWORD]
d.SymLoadModuleEx.restype = ctypes.c_ulonglong

d.SymFromAddr.argtypes = [ctypes.c_void_p, ctypes.c_ulonglong,
                          ctypes.POINTER(ctypes.c_ulonglong), ctypes.POINTER(SI)]
d.SymFromAddr.restype = wt.BOOL

d.SymGetLineFromAddr64.argtypes = [ctypes.c_void_p, ctypes.c_ulonglong,
                                   ctypes.POINTER(wt.DWORD), ctypes.POINTER(LN)]
d.SymGetLineFromAddr64.restype = wt.BOOL

hp = ctypes.c_void_p(k.GetCurrentProcess())
if not d.SymInitialize(hp, None, False):
    print('SymInitialize failed gle=%d' % ctypes.GetLastError())

dll = sys.argv[1]
offs = [int(x, 16) for x in sys.argv[2:]]
base = d.SymLoadModuleEx(hp, None, dll.encode('mbcs'), None, 0, 0, None, 0)
print('dll=%s' % dll)
print('base=0x%x  sizeof(SI)=%d' % (base, ctypes.sizeof(SI)))
if not base:
    print('SymLoadModuleEx failed gle=%d' % ctypes.GetLastError())
for off in offs:
    addr = base + off
    buf = ctypes.create_string_buffer(ctypes.sizeof(SI) + MAX + 1)
    si = ctypes.cast(buf, ctypes.POINTER(SI))
    si.contents.SizeOfStruct = 88
    si.contents.MaxNameLen = MAX
    disp = ctypes.c_ulonglong(0)
    ok = d.SymFromAddr(hp, addr, ctypes.byref(disp), si)
    print('--- RVA 0x%x' % off)
    if ok:
        print('    SYMBOL: %s + 0x%x  (func size=%d)' % (
            si.contents.Name.decode('utf-8', 'replace'), disp.value, si.contents.Size))
    else:
        print('    SYMBOL: <none> gle=%d' % ctypes.GetLastError())
    ln = LN()
    ln.SizeOfStruct = ctypes.sizeof(LN)
    ld = wt.DWORD(0)
    if d.SymGetLineFromAddr64(hp, addr, ctypes.byref(ld), ctypes.byref(ln)):
        print('    FILE:   %s:%d (+%d)' % (ln.FileName.decode('utf-8', 'replace'), ln.LineNumber, ld.value))
    else:
        print('    FILE:   <none> gle=%d' % ctypes.GetLastError())
    sys.stdout.flush()
