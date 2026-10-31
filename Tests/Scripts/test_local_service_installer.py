"""Run the real installer against an isolated filesystem and launchd double.

Never uses administrator privileges, the installed app, or the live launchd.
"""
from pathlib import Path
import json
import os
import plistlib
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
LEGACY = 'app.lumaroute.helper'
LOCAL = 'app.lumaroute.local-helper'


class LocalServiceInstallerTests(unittest.TestCase):
    def setUp(self):
        (ROOT / 'work').mkdir(exist_ok=True)
        self.temporary = tempfile.TemporaryDirectory(prefix='service-installer-', dir=ROOT / 'work')
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.service = self.root / 'Library/Application Support/LumaRoute/service'
        self.service.mkdir(parents=True)
        self.jobs = self.root / 'Library/LaunchDaemons'
        self.jobs.mkdir()
        self.app = self.root / 'Source App.app'
        self.bundle(self.app, 'new')
        self.bin = self.root / 'bin'
        self.bin.mkdir()
        self.state = self.root / 'launchd.json'
        self.state.write_text('{}')
        self.events = self.root / 'events'
        double = self.bin / 'double'
        double.write_text('''#!/usr/bin/env python3
import os,sys,pathlib,json,plistlib,shutil
name=pathlib.Path(sys.argv[0]).name
args=sys.argv[1:]
root=pathlib.Path(os.environ['FIXTURE_ROOT'])
if name=='id': print(0)
elif name=='stat': print('0' if args[1]=='%u' else '755')
elif name in ['chown','codesign','sleep']: pass
elif name=='ditto': shutil.copytree(args[0],args[1])
elif name=='install':
    import subprocess
    if os.environ.get('FAIL_WRITE') and args[-1].endswith('installation.plist'): sys.exit(71)
    clean=[]
    while args:
        arg=args.pop(0)
        if arg in ['-o','-g']: args.pop(0)
        else: clean.append(arg)
    subprocess.run(['/usr/bin/install',*clean],check=True)
elif name=='launchctl':
    file=root/'launchd.json'
    state=json.loads(file.read_text())
    with (root/'events').open('a') as log: log.write(' '.join(args)+'\\n')
    action=args[0]
    if action=='print':
        label=args[1].split('/')[-1]
        if label not in state: sys.exit(113)
        job=state[label]
        print('state = '+('spawn scheduled' if job.get('failed') else 'running'))
        print('program = '+job['Program'])
        if not job.get('failed'): print('pid = 12345')
    elif action=='bootout':
        label=args[1].split('/')[-1]
        if os.environ.get('FAIL_STOP')==label: sys.exit(5)
        if os.environ.get('RESTORE_ON_STOP')==label:
            journal=root/'Library/Application Support/LumaRoute/users/501/network-journal.plist'
            journal.write_bytes(plistlib.dumps({}))
        state.pop(label,None)
    elif action=='bootstrap':
        job=plistlib.loads(pathlib.Path(args[2]).read_bytes())
        label=job['Label']
        if os.environ.get('FAIL_BOOTSTRAP')==label: sys.exit(5)
        job['failed']=(os.environ.get('FAIL_START')==label and not (pathlib.Path(job['Program']).parents[3]/'old').exists())
        state[label]=job
    else: sys.exit('unexpected launchctl operation')
    file.write_text(json.dumps(state))
else: sys.exit('unexpected fixture command')
''')
        double.chmod(0o755)
        for name in ['id', 'stat', 'chown', 'codesign', 'ditto', 'install', 'sleep', 'launchctl']:
            (self.bin / name).symlink_to(double)
        source = (ROOT / 'script/install_local_service.sh').read_text()
        source = source.replace('/Library/Application Support/LumaRoute', str(self.service.parent))
        source = source.replace('/Library/LaunchDaemons', str(self.jobs))
        source = source.replace('/usr/bin/ditto', str(self.bin / 'ditto'))
        source = source.replace('/bin/sleep', str(self.bin / 'sleep'))
        source = source.replace('SECONDS + 35', 'SECONDS + 3').replace('SECONDS + 10', 'SECONDS + 3')
        self.script = self.root / 'installer.sh'
        self.script.write_text(source)

    def bundle(self, app, marker):
        (app / 'Contents/Library/LaunchServices').mkdir(parents=True)
        (app / 'Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier': 'app.lumaroute.desktop'}))
        helper = app / 'Contents/Library/LaunchServices/LumaRouteHelper'
        helper.write_text("""#!/usr/bin/env python3
import os,sys,pathlib,json,plistlib
root=pathlib.Path(os.environ['FIXTURE_ROOT'])
if sys.argv[1:] != ['--restore-network-for-maintenance']: sys.exit(21)
if not (pathlib.Path(__file__).parents[3]/'new').exists(): sys.exit(22)
if not (root/'Library/Application Support/LumaRoute/service/LumaRoute.app/old').exists(): sys.exit(23)
with (root/'events').open('a') as log: log.write('maintenance-restore\\n')
if os.environ.get('FAIL_MAINTENANCE'): sys.exit(24)
if os.environ.get('RESTORE_ON_MAINTENANCE'):
    journal=root/'Library/Application Support/LumaRoute/users/501/network-journal.plist'
    journal.write_bytes(plistlib.dumps({}))
""")
        helper.chmod(0o755)
        (app / marker).touch()

    def existing(self, label=LEGACY):
        self.bundle(self.service / 'LumaRoute.app', 'old')
        record = {'ownerUID': 501, 'protocolVersion': 1, 'healthOnly': False}
        if label == LOCAL:
            record['serviceID'] = LOCAL
        (self.service / 'installation.plist').write_bytes(plistlib.dumps(record))
        job = {'Label': label, 'Program': str(self.service / 'LumaRoute.app/Contents/Library/LaunchServices/LumaRouteHelper')}
        (self.jobs / (label + '.plist')).write_bytes(plistlib.dumps(job))
        self.state.write_text(json.dumps({label: job}))

    def run_installer(self, mode='--install', **environment):
        return subprocess.run(['/bin/bash', str(self.script), mode, str(self.app), '--network-ready'],
                              env={**os.environ, 'PATH': str(self.bin) + ':' + os.environ['PATH'],
                                   'SUDO_UID': '501', 'FIXTURE_ROOT': str(self.root), **environment},
                              capture_output=True, text=True, timeout=15)

    def test_fresh_install_has_independent_label_and_mach_service(self):
        result = self.run_installer()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        job = plistlib.loads((self.jobs / (LOCAL + '.plist')).read_bytes())
        self.assertEqual(job['MachServices'], {LOCAL: True})
        self.assertNotIn(LEGACY, json.loads(self.state.read_text()))
        record = plistlib.loads((self.service / 'installation.plist').read_bytes())
        self.assertEqual(record['serviceID'], LOCAL)

    def test_migration_removes_legacy_job_and_repeated_upgrade_uses_local_job(self):
        self.existing()
        for _ in range(2):
            result = self.run_installer()
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertEqual(set(json.loads(self.state.read_text())), {LOCAL})
            self.assertFalse((self.jobs / (LEGACY + '.plist')).exists())

    def test_legacy_sm_registration_cannot_replace_new_local_job(self):
        # A cached SMAppService job may exist even without a legacy system plist.
        self.state.write_text(json.dumps({LEGACY: {'Program': 'Contents/Library/LaunchServices/LumaRouteHelper', 'failed': True}}))
        result = self.run_installer()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        state = json.loads(self.state.read_text())
        self.assertIn(LOCAL, state)
        self.assertIn(LEGACY, state)  # Never remove an unowned system job.

    def test_bootstrap_success_but_spawn_failure_rolls_back_legacy_install(self):
        self.existing()
        result = self.run_installer(FAIL_START=LOCAL)
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(set(json.loads(self.state.read_text())), {LEGACY})
        self.assertTrue((self.service / 'LumaRoute.app/old').exists())
        self.assertTrue((self.jobs / (LEGACY + '.plist')).exists())
        self.assertFalse((self.jobs / (LOCAL + '.plist')).exists())

    def test_failed_upgrade_restores_previous_local_install(self):
        self.existing(LOCAL)
        result = self.run_installer(FAIL_START=LOCAL)
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        state = json.loads(self.state.read_text())
        self.assertFalse(state[LOCAL]['failed'])
        self.assertTrue((self.service / 'LumaRoute.app/old').exists())

    def test_failed_fresh_bootstrap_leaves_no_installation_record(self):
        result = self.run_installer(FAIL_BOOTSTRAP=LOCAL)
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertFalse((self.service / 'installation.plist').exists())
        self.assertFalse((self.service / 'LumaRoute.app').exists())
        self.assertFalse((self.jobs / (LOCAL + '.plist')).exists())

    def test_write_failure_after_replacing_bundle_restores_old_service(self):
        self.existing()
        result = self.run_installer(FAIL_WRITE='1')
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue((self.service / 'LumaRoute.app/old').exists())
        self.assertEqual(set(json.loads(self.state.read_text())), {LEGACY})

    def test_persisted_job_can_reload_without_managed_registration(self):
        self.existing()
        result = self.run_installer()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.state.write_text('{}')
        result = subprocess.run([str(self.bin / 'launchctl'), 'bootstrap', 'system', str(self.jobs / (LOCAL + '.plist'))],
                                env={**os.environ, 'FIXTURE_ROOT': str(self.root)}, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        state = json.loads(self.state.read_text())
        self.assertEqual(set(state), {LOCAL})
        self.assertTrue(Path(state[LOCAL]['Program']).is_absolute())
        self.assertNotIn('BundleProgram', state[LOCAL])

    def test_upgrade_restores_network_through_the_old_helper_before_replacement(self):
        self.existing(LOCAL)
        journal = self.service.parent / 'users/501/network-journal.plist'
        journal.parent.mkdir(parents=True)
        journal.write_bytes(plistlib.dumps({'fixture': {'applied': {'HTTPEnable': 1}}}))
        result = self.run_installer(RESTORE_ON_STOP=LOCAL)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(plistlib.loads(journal.read_bytes()), {})
        self.assertTrue((self.service / 'LumaRoute.app/new').exists())
        events = self.events.read_text()
        self.assertLess(events.index('bootout system/' + LOCAL), events.index('bootstrap system'))

    def test_incomplete_network_restore_preserves_files_and_restarts_old_service(self):
        self.existing()
        journal = self.service.parent / 'users/501/network-journal.plist'
        journal.parent.mkdir(parents=True)
        journal.write_bytes(plistlib.dumps({'fixture': {'applied': {}}}))
        result = self.run_installer()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(set(json.loads(self.state.read_text())), {LEGACY})
        self.assertTrue((self.service / 'LumaRoute.app/old').exists())
        self.assertFalse((self.service / 'LumaRoute.app/new').exists())
        self.assertIn('maintenance-restore', self.events.read_text())

    def test_stale_journal_is_recovered_by_staged_helper_before_replacement(self):
        self.existing(LOCAL)
        journal = self.service.parent / 'users/501/network-journal.plist'
        journal.parent.mkdir(parents=True)
        journal.write_bytes(plistlib.dumps({'deleted:Proxies': {'applied': {}}}))
        result = self.run_installer(RESTORE_ON_MAINTENANCE='1')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(plistlib.loads(journal.read_bytes()), {})
        self.assertTrue((self.service / 'LumaRoute.app/new').exists())
        events = self.events.read_text()
        self.assertLess(events.index('bootout system/' + LOCAL), events.index('maintenance-restore'))
        self.assertLess(events.index('maintenance-restore'), events.index('bootstrap system'))

    def test_failed_maintenance_recovery_retains_old_installation(self):
        self.existing(LOCAL)
        journal = self.service.parent / 'users/501/network-journal.plist'
        journal.parent.mkdir(parents=True)
        journal.write_bytes(plistlib.dumps({'live:Proxies': {'applied': {}}}))
        result = self.run_installer(FAIL_MAINTENANCE='1')
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue((self.service / 'LumaRoute.app/old').exists())
        self.assertIn(LOCAL, json.loads(self.state.read_text()))
        self.assertTrue(plistlib.loads(journal.read_bytes()))

    def test_active_journal_blocks_uninstall_before_stopping_jobs(self):
        self.existing(LOCAL)
        journal = self.service.parent / 'users/501/network-journal.plist'
        journal.parent.mkdir(parents=True)
        journal.write_bytes(plistlib.dumps({'live:Proxies': {'applied': {}}}))
        result = self.run_installer('--remove')
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.events.exists())
        self.assertTrue((self.service / 'LumaRoute.app/old').exists())

    def test_uninstall_removes_both_owned_service_plists(self):
        self.existing()
        result = self.run_installer('--remove')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(json.loads(self.state.read_text()), {})
        self.assertFalse((self.jobs / (LEGACY + '.plist')).exists())
        self.assertFalse((self.service / 'installation.plist').exists())

    def test_foreign_legacy_plist_is_preserved(self):
        self.existing()
        path = self.jobs / (LEGACY + '.plist')
        job = plistlib.loads(path.read_bytes())
        job['Program'] = '/other/service'
        path.write_bytes(plistlib.dumps(job))
        result = self.run_installer()
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue((self.service / 'LumaRoute.app/old').exists())
        self.assertEqual(plistlib.loads(path.read_bytes())['Program'], '/other/service')


if __name__ == '__main__':
    unittest.main()
