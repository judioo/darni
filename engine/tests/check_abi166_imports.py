#!/usr/bin/env python3
"""ABI 1.66 (content blocking, tab/095): preserve the ABI 1.65 struct layouts and typecheck gated Swift adoption.

REARC_TEST_ABI_HEADER_DIR names a directory with the patched headers and module map when the
patch is not applied to the checkout yet."""
from pathlib import Path
import re,subprocess,tempfile
from run_c_abi import SRC,BRIDGE
bridge=BRIDGE
root=Path(tempfile.mkdtemp(prefix='rearc-abi166-import-'))
old=root/'abi-1.65';old.mkdir()
# 2ba09186f1: the overlay through security/014 on 156.0.8078.109 (ABI 1.65, bridge 0.75.0).
for name in ('rearc_engine_abi.h','rearc_engine_entry_mac.h','module.modulemap'):
 (old/name).write_bytes(subprocess.check_output(['git','-C',str(SRC),'show','2ba09186f1:chrome/browser/rearc_bridge/'+name]))
types=re.findall(r'typedef struct (\w+)\s*\{',(old/'rearc_engine_abi.h').read_text())
c=root/'layout.c';c.write_text('#include "rearc_engine_abi.h"\n#include <stdio.h>\nint main(void){\n'+''.join(f'printf("{t} %zu %zu\\n",sizeof({t}),_Alignof({t}));\n' for t in types)+'}\n')
layouts=[]
for name,include in (('old',old),('new',bridge)):
 exe=root/name;subprocess.run(['xcrun','clang','-std=c11',f'-I{include}',str(c),'-o',str(exe)],check=True);layouts.append(subprocess.check_output([str(exe)]))
assert layouts[0]==layouts[1],layouts
print(f'ABI 1.65 layouts preserved PASS: {len(types)} structs')
header=(bridge/'rearc_engine_abi.h').read_text()
assert 'REARC_ABI_MINOR_VERSION = 66' in header
added=['ReArcEngineSetBlocklistDirectory','ReArcProfileSetContentBlocking','ReArcProfileSetBlockingExceptions','ReArcProfileSetOwnBlockingRules','ReArcTabGetBlockedCount','ReArcEngineSetBlockedCountCallback']
old_header=(old/'rearc_engine_abi.h').read_text()
for name in added:
 assert re.search(r'REARC_ENGINE_EXPORT\s+[\w* ]+\s+'+name+r'\(',header),name
 assert name not in old_header,name
exports=lambda text:set(re.findall(r'REARC_ENGINE_EXPORT\s+[\w* ]+\s+(ReArc\w+)\(',text))
assert exports(header)-exports(old_header)==set(added) and not exports(old_header)-exports(header)
print(f'ABI 1.66 header: minor 66, {len(added)} functions added, none removed PASS')
swift=root/'adoption.swift';swift.write_text('''import Foundation
import ReArcEngine
func configureABI166(profile: UInt64, tab: UInt64, bundle: String) -> UInt32 {
    guard ReArcEngineABIMinorVersion() >= 66, ReArcEngineHasFeature("content_blocking") else { return 0 }
    ReArcEngineSetBlockedCountCallback({ _, tabID, count in _ = (tabID, count) }, nil)
    var status: ReArcStatus = bundle.withCString { ReArcEngineSetBlocklistDirectory($0) }
    status = "[\\"easyprivacy\\",\\"easylist\\"]".withCString { ReArcProfileSetContentBlocking(profile, 2, $0) }
    status = ReArcProfileSetContentBlocking(profile, 3, nil)
    status = "[\\"example.com\\"]".withCString { ReArcProfileSetBlockingExceptions(profile, $0) }
    status = "[]".withCString { ReArcProfileSetOwnBlockingRules(profile, $0) }
    _ = status
    // A host written against the spec's `void` setters drops the status.
    ReArcProfileSetContentBlocking(profile, 0, nil)
    return ReArcTabGetBlockedCount(tab)
}
''')
subprocess.run(['xcrun','swiftc','-typecheck',f'-I{bridge}',str(swift)],check=True)
print('Swift gated ABI 1.66 adoption PASS')
