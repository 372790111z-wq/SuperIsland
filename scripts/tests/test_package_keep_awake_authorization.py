"""Exercise generated Installer transactions with isolated fake system tools.

No test uses the real security/launchctl/pmset tools, root, or /Library writes.
"""
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import subprocess
import tempfile
import time
import unittest

SPEC = importlib.util.spec_from_file_location("ka1_auth_package", Path(__file__).resolve().parents[1] / "package-keep-awake-authorization.py")
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)
POLICY = dict(sha256="a" * 64, sha1="b" * 40, bundleID="com.workview.SuperIsland.WE1Debug", architecture="arm64")

FAKE = r'''#!/usr/bin/env python3
import sys,json,os,plistlib,stat,time
from pathlib import Path
root=Path(__file__).parent; path=root/'state.json'; s=json.loads(path.read_text()); name=Path(sys.argv[0]).name; args=sys.argv[1:]
def save():path.write_text(json.dumps(s))
if name=='id':print(0);sys.exit(0)
if name=='stat':
 print(0 if args[1]=='%u' else oct(os.stat(args[-1]).st_mode & 0o777)[2:]);sys.exit(0)
if name=='inspect':
 if s.get('inspectFailure'):sys.exit(1)
 sys.stdout.buffer.write(plistlib.dumps(dict(CertificateSHA256='a'*64,CertificateSHA1='b'*40,AdminEntryPresent=s['admin'],ExactCodeSigningTrust=s['exact'],SystemCertificatePresent=s['system'],AppSignatureValid=s.get('validApp',True),Notebook=s.get('notebook',True))));sys.exit(0)
if name=='launchctl':sys.exit(0 if s.get('helper') else s.get('launchError',113))
if name=='pmset':print('System-wide power settings:\n SleepDisabled '+str(s.get('sleep',0)));sys.exit(0)
if name=='security':
 s.setdefault('commands',[]).append(args)
 action=args[0]
 if action=='verify-cert':save();sys.exit(0 if s.get('usable',True) else 1)
 if action=='add-trusted-cert':
  if s.get('addDelay'):
   (root/'adding').write_text('active');time.sleep(s['addDelay'])
  s.update(admin=True,exact=True,system=True);save();sys.exit(1 if s.get('addFailure') else 0)
 if action=='remove-trusted-cert':s['admin']=False
 elif action=='delete-certificate':s['system']=False
 else:raise RuntimeError('Unexpected privileged command')
 save();sys.exit(0)
raise RuntimeError('Unexpected fake tool')
'''


class AuthorizationPackageTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="ka1-auth-transaction-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.library = self.root / "Library"; self.library.mkdir()
        (self.library / "Application Support").mkdir()
        self.tools = self.root / "tools"; self.tools.mkdir()
        self.state = dict(admin=False, exact=False, system=False, unrelated="preserved")
        for name in ("id", "stat", "security", "launchctl", "pmset", "inspect"):
            path = self.tools / name; path.write_text(FAKE); path.chmod(0o755)
        (self.root / "certificate.der").write_bytes(b"fixture public certificate")
        self.base = self.library / "Application Support/com.workview.SuperIsland.LocalSigning"
        self.record = self.base / POLICY["sha256"]

    def prepare(self, mode):
        (self.tools / "state.json").write_text(json.dumps(self.state))
        text = MODULE.installer_script(mode, POLICY)
        text = text.replace("/Library/Application Support", str(self.library / "Application Support"))
        text = text.replace("secure_directory /Library\n", "secure_directory '" + str(self.library) + "'\n")
        text = text.replace('inspector="$resources/inspect"', 'inspector="' + str(self.tools / "inspect") + '"')
        text = text.replace('/bin/sync', '/usr/bin/true')
        for source, name in (("/usr/bin/id", "id"), ("/usr/bin/stat", "stat"), ("/usr/bin/security", "security"),
                             ("/bin/launchctl", "launchctl"), ("/usr/bin/pmset", "pmset")):
            text = text.replace(source, str(self.tools / name))
        script = self.root / "postinstall"; script.write_text(text)
        return script

    def run_setup(self, mode):
        script = self.prepare(mode)
        result = subprocess.run(["/bin/sh", str(script)], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        self.state = json.loads((self.tools / "state.json").read_text())
        self.assertEqual(self.state['unrelated'], 'preserved')
        return result

    def testEnableIsIdempotentAndRemoveRestoresOnlyOwnedChanges(self):
        self.assertEqual(self.run_setup("enable").returncode, 0)
        receipt = plistlib.loads((self.record / "receipt.plist").read_bytes())
        self.assertEqual(receipt['Phase'], 'applied')
        self.assertTrue(receipt['CertificateAdded'])
        self.assertEqual(self.run_setup("enable").returncode, 0)
        self.assertEqual(sum(c[0] == 'add-trusted-cert' for c in self.state['commands']), 1)
        add = next(c for c in self.state['commands'] if c[0] == 'add-trusted-cert')
        self.assertEqual(add[1:8], ['-d', '-r', 'trustRoot', '-p', 'codeSign', '-k', '/Library/Keychains/System.keychain'])
        self.assertEqual(self.run_setup("remove").returncode, 0)
        self.assertFalse(self.state['admin']); self.assertFalse(self.state['system'])
        self.assertFalse((self.record / "receipt.plist").exists())
        self.assertEqual(self.run_setup("remove").returncode, 0)

    def testPreexistingSystemPublicCertificateIsPreserved(self):
        self.state['system'] = True
        self.assertEqual(self.run_setup("enable").returncode, 0)
        self.assertFalse(plistlib.loads((self.record / "receipt.plist").read_bytes())['CertificateAdded'])
        self.assertEqual(self.run_setup("remove").returncode, 0)
        self.assertTrue(self.state['system'])
        self.assertFalse(any(c[0] == 'delete-certificate' for c in self.state['commands']))

    def testPreexistingAdminTrustIsNotAdoptedOrOverwritten(self):
        self.state.update(admin=True, system=True, exact=False)
        self.assertEqual(self.run_setup("enable").returncode, 0)
        self.assertFalse((self.record / "receipt.plist").exists())
        self.assertEqual(self.run_setup("remove").returncode, 0)
        self.assertTrue(self.state['admin']); self.assertTrue(self.state['system'])
        self.assertEqual([c[0] for c in self.state['commands']], ['verify-cert'])

    def testExistingUnusableTrustIsLeftUnchanged(self):
        self.state.update(admin=True, system=True, usable=False)
        self.assertNotEqual(self.run_setup("enable").returncode, 0)
        self.assertTrue(self.state['admin'])
        self.assertFalse((self.record / "receipt.plist").exists())

    def testInvalidAppDesktopAndInspectionErrorCannotGrantTrust(self):
        for flag in ('validApp', 'notebook', 'inspectFailure'):
            with self.subTest(flag=flag):
                self.state[flag] = flag == 'inspectFailure'
                self.assertNotEqual(self.run_setup("enable").returncode, 0)
                self.assertFalse(self.state['admin']); self.assertFalse(self.state.get('commands'))
                self.state.pop(flag)

    def testPartialTrustWriteRetainsRecoveryIntent(self):
        self.state['addFailure'] = True
        self.assertNotEqual(self.run_setup("enable").returncode, 0)
        self.assertEqual(plistlib.loads((self.record / "receipt.plist").read_bytes())['Phase'], 'intent')
        self.assertTrue(self.state['admin'])
        self.assertEqual(self.run_setup("remove").returncode, 0)
        self.assertFalse(self.state['admin']); self.assertFalse(self.state['system'])

    def testLiveHelperUnrestoredPowerAndUnknownLaunchStateBlockRemoval(self):
        self.assertEqual(self.run_setup("enable").returncode, 0)
        for flag, value in [('helper', True), ('sleep', 1), ('launchError', 1)]:
            self.state[flag] = value
            self.assertNotEqual(self.run_setup("remove").returncode, 0)
            self.assertTrue(self.state['admin']); self.assertTrue(self.state['system'])
            self.state.pop(flag)

    def testExternallyModifiedTrustCannotBeRemoved(self):
        self.assertEqual(self.run_setup("enable").returncode, 0)
        self.state['exact'] = False
        self.assertNotEqual(self.run_setup("remove").returncode, 0)
        self.assertTrue(self.state['admin']); self.assertTrue(self.state['system'])

    def testUnexpectedReceiptAndSymlinkDirectoryStopBeforeWriting(self):
        self.base.parent.mkdir(exist_ok=True)
        self.base.symlink_to(self.root / 'elsewhere')
        self.assertNotEqual(self.run_setup("enable").returncode, 0)
        self.assertFalse(self.state['admin']); self.assertFalse(self.state.get('commands'))

    def testUnvalidatedPolicyCannotEnterGeneratedShell(self):
        for key, value in [('sha256', 'a; touch /tmp/no'), ('sha1', 'bad'), ('bundleID', 'other'), ('architecture', 'universal')]:
            changed = dict(POLICY, **{key: value})
            with self.assertRaises(ValueError):MODULE.installer_script('enable', changed)

    def testAlteredReceiptIdentityAndPermissionsCannotRemoveTrust(self):
        self.assertEqual(self.run_setup('enable').returncode, 0)
        receipt = self.record / 'receipt.plist'
        original = receipt.read_bytes()
        receipt.chmod(0o644)
        self.assertNotEqual(self.run_setup('remove').returncode, 0)
        receipt.chmod(0o600)
        changed = plistlib.loads(original); changed['CertificateSHA256'] = 'c'*64
        receipt.write_bytes(plistlib.dumps(changed))
        self.assertNotEqual(self.run_setup('remove').returncode, 0)
        self.assertTrue(self.state['admin']); self.assertTrue(self.state['system'])

    def testConcurrentEnrollmentCannotWriteTwice(self):
        self.state['addDelay'] = 1
        script = self.prepare('enable')
        first = subprocess.Popen(['/bin/sh', str(script)], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        try:
            deadline = time.monotonic() + 5
            while not (self.tools/'adding').exists() and time.monotonic() < deadline:time.sleep(0.01)
            self.assertTrue((self.tools/'adding').exists())
            second = subprocess.run(['/bin/sh', str(script)], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
            self.assertNotEqual(second.returncode, 0)
            first.communicate(timeout=5)
            self.assertEqual(first.returncode, 0)
            self.state = json.loads((self.tools/'state.json').read_text())
            self.assertEqual(sum(c[0]=='add-trusted-cert' for c in self.state['commands']), 1)
        finally:
            if first.poll() is None:first.terminate(); first.communicate(timeout=5)


if __name__ == '__main__':
    unittest.main()
