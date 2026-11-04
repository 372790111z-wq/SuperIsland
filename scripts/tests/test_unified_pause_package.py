import importlib.util
from pathlib import Path
import unittest

SPEC = importlib.util.spec_from_file_location('local_release', Path(__file__).resolve().parents[1] / 'package-local-release.py')
PACKAGE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(PACKAGE)


class UnifiedPausePackagingTests(unittest.TestCase):
    def test_opt_in_matches_exact_narrow_build(self):
        info = {'CFBundleIdentifier': 'com.workview.SuperIsland.WE1Debug'}
        receipt = {'command': ['xcodebuild', 'WE1_BATTERY_SWIFT_CONDITIONS=BATTERY_PAUSE_REFRESH']}
        PACKAGE.validate_pause_refresh_build(receipt, info, True)
        PACKAGE.validate_pause_refresh_build({'command': ['xcodebuild']}, info, False)
        for enabled, command in [
            (True, []), (False, receipt['command']),
            (True, receipt['command'] + ['BM1_REVIEW_SWIFT_CONDITIONS=BATTERY_REVIEW']),
            (True, ['WE1_BATTERY_SWIFT_CONDITIONS=BATTERY_PAUSE_REFRESH BATTERY_REVIEW']),
            (False, ['SWIFT_ACTIVE_COMPILATION_CONDITIONS=BATTERY_PAUSE_REFRESH']),
            (True, receipt['command'] * 2),
        ]:
            with self.subTest(enabled=enabled, command=command), self.assertRaises(ValueError):
                PACKAGE.validate_pause_refresh_build({'command': command}, info, enabled)

    def test_cannot_repackage_other_identity_or_sealed_experiment(self):
        receipt = {'command': ['WE1_BATTERY_SWIFT_CONDITIONS=BATTERY_PAUSE_REFRESH']}
        for identifier in ['com.workview.SuperIsland', 'com.workview.SuperIsland.BM1Debug', None]:
            with self.subTest(identifier=identifier), self.assertRaises(ValueError):
                PACKAGE.validate_pause_refresh_build(receipt, {'CFBundleIdentifier': identifier}, True)
        for key in ['BM1DiagnosticsOnly', 'BM1NativeCutoffTrial', 'BM1Preferences79Review', 'BM1PauseRefreshTrial', 'WE1PauseRefreshTrial']:
            with self.subTest(key=key), self.assertRaises(ValueError):
                PACKAGE.validate_pause_refresh_build(receipt, {'CFBundleIdentifier': 'com.workview.SuperIsland.WE1Debug', key: True}, True)


if __name__ == '__main__':
    unittest.main()
