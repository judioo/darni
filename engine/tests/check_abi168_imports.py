#!/usr/bin/env python3
"""ABI 1.67 (site permissions, tab/096) and 1.68 (WebAuthn steps, tab/097): preserve the ABI 1.66 struct layouts and typecheck gated Swift adoption.

REARC_TEST_ABI_HEADER_DIR names a directory with the patched headers and module map when the
patches are not applied to the checkout yet."""
from pathlib import Path
import re,subprocess,tempfile
from run_c_abi import SRC,BRIDGE
bridge=BRIDGE
root=Path(tempfile.mkdtemp(prefix='rearc-abi168-import-'))
old=root/'abi-1.66';old.mkdir()
# 67d25d5cf4: the overlay through tab/095 on 156.0.8078.109 (ABI 1.66, bridge 0.76.0).
for name in ('rearc_engine_abi.h','rearc_engine_entry_mac.h','module.modulemap'):
 (old/name).write_bytes(subprocess.check_output(['git','-C',str(SRC),'show','67d25d5cf4:chrome/browser/rearc_bridge/'+name]))
types=re.findall(r'typedef struct (\w+)\s*\{',(old/'rearc_engine_abi.h').read_text())
c=root/'layout.c';c.write_text('#include "rearc_engine_abi.h"\n#include <stdio.h>\nint main(void){\n'+''.join(f'printf("{t} %zu %zu\\n",sizeof({t}),_Alignof({t}));\n' for t in types)+'}\n')
layouts=[]
for name,include in (('old',old),('new',bridge)):
 exe=root/name;subprocess.run(['xcrun','clang','-std=c11',f'-I{include}',str(c),'-o',str(exe)],check=True);layouts.append(subprocess.check_output([str(exe)]))
assert layouts[0]==layouts[1],layouts
print(f'ABI 1.66 layouts preserved PASS: {len(types)} structs')
header=(bridge/'rearc_engine_abi.h').read_text()
assert 'REARC_ABI_MINOR_VERSION = 68' in header
added=['ReArcTabGetSitePermissions','ReArcTabSetSitePermission','ReArcTabRevokeSiteDevice','ReArcEngineSetSitePermissionsChangedCallback','ReArcEngineSetWebAuthnCallback','ReArcWebAuthnRespond']
old_header=(old/'rearc_engine_abi.h').read_text()
for name in added:
 assert re.search(r'REARC_ENGINE_EXPORT\s+[\w* ]+\s+'+name+r'\(',header),name
 assert name not in old_header,name
exports=lambda text:set(re.findall(r'REARC_ENGINE_EXPORT\s+[\w* ]+\s+(ReArc\w+)\(',text))
assert exports(header)-exports(old_header)==set(added) and not exports(old_header)-exports(header)
# Both channels are JSON over scalars: a host reaches them by symbol lookup, so no struct may be added.
assert set(re.findall(r'typedef struct (\w+)\s*\{',header))==set(types)
print(f'ABI 1.68 header: minor 68, {len(added)} functions added, none removed, no struct added PASS')
swift=root/'adoption.swift';swift.write_text('''import Foundation
import ReArcEngine
func configureABI167(tab: UInt64) -> ReArcStatus {
    guard ReArcEngineABIMinorVersion() >= 67, ReArcEngineHasFeature("site_permissions") else { return ReArcStatus(REARC_UNSUPPORTED) }
    ReArcEngineSetSitePermissionsChangedCallback({ _, tabID in _ = tabID }, nil)
    var status = ReArcTabGetSitePermissions(tab, { _, status, tabID, json in
        _ = (status, tabID, json.map { String(cString: $0) })
    }, nil)
    status = "https://example.com".withCString { origin in
        "notifications".withCString { ReArcTabSetSitePermission(tab, origin, $0, 2) }
    }
    status = "https://example.com".withCString { origin in
        "usb".withCString { kind in "1234;5678;SERIAL".withCString { ReArcTabRevokeSiteDevice(tab, origin, kind, $0) } }
    }
    return status
}
func configureABI168() -> ReArcStatus {
    guard ReArcEngineABIMinorVersion() >= 68, ReArcEngineHasFeature("webauthn_prompts") else { return ReArcStatus(REARC_UNSUPPORTED) }
    ReArcEngineSetWebAuthnCallback({ _, request, tabID, phase, json in
        _ = (request, tabID, phase, json.map { String(cString: $0) })
    }, nil)
    var status = ReArcWebAuthnRespond(1, 1, 0, nil)
    status = "123456".withCString { ReArcWebAuthnRespond(1, 3, 0, $0) }
    return status
}
''')
subprocess.run(['xcrun','swiftc','-typecheck',f'-I{bridge}',str(swift)],check=True)
print('Swift gated ABI 1.67 and 1.68 adoption PASS')
