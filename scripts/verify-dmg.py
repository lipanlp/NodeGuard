#!/usr/bin/env python3
"""Mount the delivered image read-only, verify its drag target, and verify a copy without installing it."""
import hashlib, json, plistlib, shutil, subprocess, platform
from pathlib import Path
root = Path(__file__).resolve().parent.parent
version = plistlib.loads((root/'outputs/NodeGuard.app/Contents/Info.plist').read_bytes())['CFBundleShortVersionString']
image = root / ('outputs/NodeGuard-' + version + '-macOS-' + platform.machine() + '.dmg')
attached = plistlib.loads(subprocess.check_output(['hdiutil', 'attach', '-readonly', '-nobrowse', '-plist', str(image)]))
mount = next(e['mount-point'] for e in attached['system-entities'] if 'mount-point' in e)
try:
    volume = Path(mount); app = volume/'NodeGuard.app'
    info = plistlib.loads((app/'Contents/Info.plist').read_bytes())
    assert (volume/'Applications').is_symlink() and (volume/'Applications').resolve() == Path('/Applications')
    assert info['CFBundleShortVersionString'] == version and info.get('LSUIElement') is False
    assert (app/'Contents/Resources/NodeGuard.icns').stat().st_size > 0
    assert (volume/'LICENSE').read_bytes() == (root/'LICENSE').read_bytes()
    for name, source in [('NodeGuard-LICENSE.txt', root/'LICENSE'), ('Yams-LICENSE.txt', root/'Vendor/Yams/LICENSE'), ('LibYAML-LICENSE.txt', root/'Vendor/Yams/LIBYAML-LICENSE')]:
        assert (app/'Contents/Resources'/name).read_bytes() == source.read_bytes()
    subprocess.run(['codesign','--verify','--deep','--strict',str(app)],check=True)
    target = root/'work/dmg-copy-test/NodeGuard.app'
    target.parent.mkdir(parents=True,exist_ok=True)
    if target.exists(): shutil.rmtree(target)
    subprocess.run(['ditto',str(app),str(target)],check=True)
    subprocess.run(['codesign','--verify','--deep','--strict',str(target)],check=True)
    def digest(p): return hashlib.sha256(p.read_bytes()).hexdigest()
    assert digest(target/'Contents/MacOS/NodeGuard') == digest(root/'outputs/NodeGuard.app/Contents/MacOS/NodeGuard')
    report = {'version': info['CFBundleShortVersionString'],'drag_target':'/Applications','dock_app':True,'icon_present':True,'dmg_signature_valid':True,'copied_app_signature_valid':True,'binary_identical_after_copy':True,'installed_into_applications':False}
    (root/('outputs/dmg-verification-v'+version+'.json')).write_text(json.dumps(report,indent=2))
    print(json.dumps(report))
finally: subprocess.run(['hdiutil','detach',mount],check=True,stdout=subprocess.DEVNULL)
