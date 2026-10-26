"""Native Security policy fixtures, with no live trust reads or writes."""
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


@unittest.skipUnless(sys.platform == 'darwin', 'Requires the macOS public Security framework')
class SigningInspectorTests(unittest.TestCase):
    def testExactPolicyRecognitionIncludingDefaultResultAndMetadata(self):
        root = Path(__file__).resolve().parents[2]
        with tempfile.TemporaryDirectory(prefix='ka1-signing-inspector-test-') as temporary:
            folder = Path(temporary)
            source = ('enum SetupPolicy { static let sha256="' + 'a'*64 + '"; static let sha1="' + 'b'*40 + '"; static let bundleID="com.workview.SuperIsland.WE1Debug" }\n' +
                      (root / 'KeepAwakeSetup/inspect.swift').read_text() + '\n' +
                      (root / 'KeepAwakeSetup/policy-tests.swift').read_text())
            main = folder / 'main.swift'; main.write_text(source)
            compiled = subprocess.run(['xcrun', 'swiftc', '-D', 'KEEP_AWAKE_INSPECTOR_TESTS', str(main), '-o', str(folder/'test')],
                                      stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
            self.assertEqual(compiled.returncode, 0, compiled.stderr)
            result = subprocess.run([str(folder/'test')], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn('11 code-signing trust policy cases passed', result.stdout)


if __name__ == '__main__':unittest.main()
