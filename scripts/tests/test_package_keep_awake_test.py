"""Pure validators and fake command fixtures; never execute signing or packaging."""
import copy
import importlib.util
from pathlib import Path
import plistlib
import subprocess
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / "package-keep-awake-test.py"
SPEC = importlib.util.spec_from_file_location("package_keep_awake_test", SCRIPT)
PACKAGE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(PACKAGE)


class KeepAwakeTestPackageTests(unittest.TestCase):
    def testReceiptBindsCheckoutRevisionTreeAndSuccessfulStableBuild(self):
        root = Path("/fixture/checkout")
        receipt = dict(exitCode=0, sourceUnchangedDuringBuild=True,
                       sourceRevision="revision", sourceTree="tree", sourceRoot=str(root),
                       sourceApp="/fixture/build/SuperIsland.app", sourceBinarySHA256="a" * 64,
                       sourceAppSHA256="b" * 64)
        def check(value, **overrides):
            args = dict(root=root, head="revision", tree="tree", clean=True)
            args.update(overrides)
            PACKAGE.validate_provenance(value, **args)
        check(receipt)
        for key, value in (("exitCode", 1), ("exitCode", False), ("sourceUnchangedDuringBuild", False),
                           ("sourceRevision", "old"), ("sourceTree", "old"),
                           ("sourceRoot", "/another/checkout"), ("sourceApp", "relative.app"),
                           ("sourceBinarySHA256", "missing")):
            with self.subTest(key=key, value=value), self.assertRaises(PACKAGE.PackageError):
                changed = dict(receipt); changed[key] = value; check(changed)
        with self.assertRaises(PACKAGE.PackageError):
            check(receipt, clean=False)

    def testNativeOnlyPackageAllowsMissingNodeButRejectsWrongIncludedRuntime(self):
        inventory = {name: ["arm64"] for name in PACKAGE.CORE}
        PACKAGE.validate_architectures(inventory, "arm64")
        inventory[PACKAGE.NODE] = ["arm64", "x86_64"]
        PACKAGE.validate_architectures(inventory, "arm64")
        inventory[PACKAGE.NODE] = ["x86_64"]
        with self.assertRaisesRegex(PACKAGE.PackageError, "Resources/node"):
            PACKAGE.validate_architectures(inventory, "arm64")

    def testEveryIncludedNativeComponentMustSupportChosenArchitecture(self):
        inventory = {name: ["x86_64"] for name in PACKAGE.CORE}
        PACKAGE.validate_architectures(inventory, "x86_64")
        inventory["Contents/Frameworks/Adapter.framework/Adapter"] = ["arm64"]
        with self.assertRaisesRegex(PACKAGE.PackageError, "Adapter"):
            PACKAGE.validate_architectures(inventory, "x86_64")

    def testMissingHelperOrUniversalCoreCannotMasqueradeAsSingleArchitecture(self):
        for missing in PACKAGE.CORE:
            inventory = {name: ["arm64"] for name in PACKAGE.CORE if name != missing}
            with self.subTest(missing=missing), self.assertRaises(PACKAGE.PackageError):
                PACKAGE.validate_architectures(inventory, "arm64")
        inventory = {name: ["arm64", "x86_64"] for name in PACKAGE.CORE}
        with self.assertRaises(PACKAGE.PackageError):
            PACKAGE.validate_architectures(inventory, "arm64")
        with self.assertRaises(PACKAGE.PackageError):
            PACKAGE.validate_architectures(inventory, "universal")

    def testAppIdentityIsKeptAndMustMatchFixedDaemonContract(self):
        daemon = dict(Label=PACKAGE.HELPER_ID, BundleProgram="Contents/MacOS/KeepAwakeHelper",
                      MachServices={PACKAGE.HELPER_ID: True}, AssociatedBundleIdentifiers=sorted(PACKAGE.APP_IDS))
        for bundle_id in PACKAGE.APP_IDS:
            info = dict(CFBundleIdentifier=bundle_id, CFBundleExecutable="SuperIsland")
            self.assertEqual(PACKAGE.validate_metadata(info, daemon), bundle_id)
        with self.assertRaises(PACKAGE.PackageError):
            PACKAGE.validate_metadata(dict(CFBundleIdentifier="other", CFBundleExecutable="SuperIsland"), daemon)
        changed = dict(daemon, BundleProgram="/outside/helper")
        with self.assertRaises(PACKAGE.PackageError):
            PACKAGE.validate_metadata(dict(CFBundleIdentifier="com.workview.SuperIsland", CFBundleExecutable="SuperIsland"), changed)

    def testTestingDebugAndCoverageArtifactsAreRejected(self):
        for name in ("Contents/PlugIns/Tests.xctest", "Contents/Frameworks/XCTest.framework/XCTest",
                     "Contents/MacOS/SuperIsland.debug.dylib", "Contents/Frameworks/Testing.framework"):
            with self.subTest(name=name), self.assertRaises(PACKAGE.PackageError):
                PACKAGE.validate_no_instrumentation(name, "")
        for loads in ("sectname __llvm_covmap", "sectname __llvm_prf_cnts", "@rpath/XCTest.framework/XCTest"):
            with self.subTest(loads=loads), self.assertRaises(PACKAGE.PackageError):
                PACKAGE.validate_no_instrumentation("Contents/MacOS/SuperIsland", loads)
        PACKAGE.validate_no_instrumentation("Contents/Frameworks/libApplication.dylib", "sectname __text")

    def testDebugMetadataStripsProductionRoutesAndBindsReceiptWithoutMutatingSource(self):
        source = dict(CFBundleIdentifier="com.workview.SuperIsland.WE1Debug", CFBundleVersion="10",
                      CFBundleName="Old Name", CFBundleURLTypes=[{"CFBundleURLSchemes": ["superisland"]}])
        original = copy.deepcopy(source)
        receipt = dict(sourceRevision="reviewed-revision", sourceBinarySHA256="a" * 64)
        result = PACKAGE.package_metadata(source, receipt, "20261022235900")
        self.assertNotIn("CFBundleURLTypes", result)
        self.assertEqual(result["CFBundleIdentifier"], source["CFBundleIdentifier"])
        self.assertEqual(result["CFBundleName"], "SuperIsland")
        self.assertEqual(result["CFBundleDisplayName"], "SuperIsland")
        self.assertEqual(result["CFBundleVersion"], "20261022235900")
        self.assertEqual(result["WE1BuildType"], "Optimized")
        self.assertEqual(result["WE1SourceRevision"], receipt["sourceRevision"])
        self.assertEqual(result["WE1SourceExecutableSHA256"], receipt["sourceBinarySHA256"])
        self.assertEqual(source, original)

    def testProductionIdentityRetainsItsOwnedRoutesWithoutMutatingSource(self):
        source = dict(CFBundleIdentifier="com.workview.SuperIsland", CFBundleVersion="10",
                      CFBundleURLTypes=[{"CFBundleURLSchemes": ["superisland"]}])
        original = copy.deepcopy(source)
        receipt = dict(sourceRevision="production-revision", sourceBinarySHA256="b" * 64)
        result = PACKAGE.package_metadata(source, receipt, "20261022235901")
        self.assertEqual(result["CFBundleURLTypes"], source["CFBundleURLTypes"])
        self.assertEqual(result["CFBundleIdentifier"], "com.workview.SuperIsland")
        self.assertEqual(result["WE1SourceRevision"], receipt["sourceRevision"])
        self.assertEqual(result["WE1SourceExecutableSHA256"], receipt["sourceBinarySHA256"])
        self.assertEqual(source, original)

    def testCoreSignatureRequiresSameRealCertificateFixedIDsAndRuntime(self):
        bundle_id = "com.workview.SuperIsland.WE1Debug"
        records = {name: dict(identifier=identifier or bundle_id, certificate_sha256="a" * 64, hardened_runtime=True)
                   for name, identifier in PACKAGE.CORE.items()}
        PACKAGE.validate_core_signatures(records, bundle_id)
        for key, value in (("certificate_sha256", "b" * 64), ("certificate_sha256", ""),
                           ("identifier", "KeepAwakeHelper"), ("hardened_runtime", False)):
            changed = copy.deepcopy(records)
            changed["Contents/MacOS/KeepAwakeHelper"][key] = value
            with self.subTest(key=key, value=value), self.assertRaises(PACKAGE.PackageError):
                PACKAGE.validate_core_signatures(changed, bundle_id)

    def testNativeDependenciesCannotPointIntoAnotherAppHomeOrHomebrew(self):
        for dependency in ("/opt/homebrew/lib/libfixture.dylib", "/usr/local/lib/libfixture.dylib",
                           "/Applications/Other.app/Contents/Frameworks/libfixture.dylib", "/Users/fixture/libfixture.dylib"):
            with self.subTest(path=dependency), self.assertRaises(PACKAGE.PackageError):
                PACKAGE.validate_no_host_dependencies("fixture", "", "fixture:\n\t" + dependency + " (compatibility version 1.0.0)")
            with self.subTest(rpath=dependency), self.assertRaises(PACKAGE.PackageError):
                PACKAGE.validate_no_host_dependencies("fixture", "path " + dependency + " (offset 12)", "")
        PACKAGE.validate_no_host_dependencies("fixture", "path @executable_path/../Frameworks (offset 12)",
                                              "fixture:\n\t/usr/lib/libSystem.B.dylib (compatibility version 1.0.0)\n"
                                              "\t@rpath/Adapter.framework/Adapter (compatibility version 1.0.0)")

    def testSigningOrderDoesNotSpreadAppEntitlementsOrOverwriteNestedIdentifiers(self):
        app = Path("/fixture/SuperIsland.app")
        commands = PACKAGE.signing_commands(app, "existing-test-certificate", "com.workview.SuperIsland.WE1Debug",
                                            Path("/fixture/app.entitlements"))
        self.assertEqual(len(commands), 4)
        self.assertIn("--deep", commands[0])
        self.assertNotIn("--entitlements", commands[0])
        self.assertNotIn("--identifier", commands[0], "Do not replace framework identifiers with the outer App identifier")
        self.assertIn("--preserve-metadata=entitlements,identifier", commands[0])
        for index, name in enumerate(("KeepAwakeHelper", "KeepAwakeEventTool"), 1):
            self.assertNotIn("--deep", commands[index])
            self.assertIn("com.workview.SuperIsland." + name, commands[index])
            self.assertIn("--preserve-metadata=entitlements", commands[index])
        self.assertNotIn("--deep", commands[-1])
        self.assertIn("--entitlements", commands[-1])
        self.assertTrue(all("--timestamp=none" in command for command in commands))

    def testFixtureInspectionUsesOnlyInjectedReadCommandsAndSeesNodeArchitecture(self):
        with tempfile.TemporaryDirectory() as directory:
            app = self.fixture(Path(directory))
            calls = []
            def command(*args):
                calls.append(args)
                self.assertIn(args[0], ("lipo", "xcrun"))
                output = "arm64\n" if args[0] == "lipo" else "sectname __text\n"
                return subprocess.CompletedProcess(args, 0, stdout=output, stderr="")
            _, bundle_id, inventory = PACKAGE.inspect_app(app, "arm64", command)
            self.assertEqual(bundle_id, "com.workview.SuperIsland.WE1Debug")
            self.assertEqual(set(inventory), set(PACKAGE.CORE) | {PACKAGE.NODE})
            self.assertEqual(len(calls), 12)

    def testFixtureRejectsEscapingSymlinkBeforeFollowingIt(self):
        with tempfile.TemporaryDirectory() as directory:
            app = self.fixture(Path(directory))
            (app / "outside").symlink_to(Path(directory) / "private-outside")
            def command(*args):
                return subprocess.CompletedProcess(args, 0, stdout="arm64\n" if args[0] == "lipo" else "", stderr="")
            with self.assertRaisesRegex(PACKAGE.PackageError, "escapes"):
                PACKAGE.inspect_app(app, "arm64", command)

    def testFixtureRejectsNodeWrapperThatWouldDependOnExternalRuntime(self):
        with tempfile.TemporaryDirectory() as directory:
            app = self.fixture(Path(directory))
            (app / PACKAGE.NODE).write_text("#!/bin/sh\nexec /opt/homebrew/bin/node\n")
            def command(*args):
                return subprocess.CompletedProcess(args, 0, stdout="arm64\n" if args[0] == "lipo" else "", stderr="")
            with self.assertRaisesRegex(PACKAGE.PackageError, "Node"):
                PACKAGE.inspect_app(app, "arm64", command)

    def testEntitlementInspectionDoesNotMistakeErrorsForUnsignedOutput(self):
        def unsigned(*args):
            raise subprocess.CalledProcessError(1, args, stderr="fixture: code object is not signed at all")
        self.assertIsNone(PACKAGE.entitlements(Path("/fixture/unsigned"), unsigned))
        def inaccessible(*args):
            raise subprocess.CalledProcessError(1, args, stderr="fixture: access denied")
        with self.assertRaises(PACKAGE.PackageError):
            PACKAGE.entitlements(Path("/fixture/inaccessible"), inaccessible)

    def fixture(self, base):
        app = base / "SuperIsland.app"
        for name in (*PACKAGE.CORE, PACKAGE.NODE):
            target = app / name
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(bytes.fromhex("cffaedfe") + b"native-fixture")
        info = dict(CFBundleIdentifier="com.workview.SuperIsland.WE1Debug", CFBundleExecutable="SuperIsland")
        (app / "Contents/Info.plist").write_bytes(plistlib.dumps(info))
        daemon = app / "Contents/Library/LaunchDaemons" / (PACKAGE.HELPER_ID + ".plist")
        daemon.parent.mkdir(parents=True)
        daemon.write_bytes(plistlib.dumps(dict(Label=PACKAGE.HELPER_ID, BundleProgram="Contents/MacOS/KeepAwakeHelper",
                                               MachServices={PACKAGE.HELPER_ID: True},
                                               AssociatedBundleIdentifiers=[info["CFBundleIdentifier"]])))
        return app


if __name__ == "__main__":
    unittest.main()
