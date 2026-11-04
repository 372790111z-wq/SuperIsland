#!/usr/bin/env python3
"""Create a small, locally signed BM1 review app without installing anything.

Never use --deep to sign: its --identifier can propagate to helper executables
and silently break the XPC signing requirements. Sign each leaf explicitly.
"""
import argparse
import datetime
import hashlib
import json
import plistlib
import shutil
import subprocess
import tempfile
from pathlib import Path


def run(*args):
    return subprocess.run(args, check=True, text=True, capture_output=True)


def logical_size(path):
    return sum(p.stat().st_size for p in path.rglob("*") if p.is_file() and not p.is_symlink())


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--built-app", type=Path, required=True)
    parser.add_argument("--output-dir", type=Path, required=True)
    parser.add_argument("--identity", required=True, help="An existing local signing identity; never creates or trusts a certificate")
    parser.add_argument("--entitlements", type=Path,
                        default=Path(__file__).resolve().parents[1] / "SuperIsland/SuperIsland.entitlements",
                        help="Preserve the application's existing hardened-runtime capabilities")
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--full-application-review", action="store_true", help="Launch the complete application lifecycle with isolated preferences and no production analytics")
    mode.add_argument("--native-cutoff-trial", action="store_true", help="Seal a fixed 79–85 percent, target80 native-limit review with a ten-minute discharge maximum; legacy flag name, never a production capability")
    mode.add_argument("--diagnostics-only", action="store_true", help="Permanently restrict this review package and helper to read-only diagnosis")
    mode.add_argument("--preferences79-review", action="store_true", help="Seal the separate fixed79 preference experiment; no production capability, no SMC writes, normal control excluded while its recovery journal exists")
    mode.add_argument("--pause-refresh-trial", action="store_true", help="Seal the single-use 79–85 percent 500ms pause refresh; persistent receipt forbids replay")
    args = parser.parse_args()
    source = args.built_app.resolve()
    with args.entitlements.open("rb") as file:
        entitlements = plistlib.load(file)
    if not isinstance(entitlements, dict) or entitlements.get("com.apple.security.get-task-allow"):
        raise SystemExit("Expected application entitlements without debug task access")
    with (source / "Contents/Info.plist").open("rb") as file:
        info = plistlib.load(file)
    if info.get("CFBundleIdentifier") != "com.workview.SuperIsland.BM1Debug":
        raise SystemExit("Build the isolated BM1Debug bundle first; production bundles are refused")
    architectures = {}
    for name in ["SuperIsland", "BatteryManagementHelper", "KeepAwakeHelper", "KeepAwakeEventTool"]:
        architectures[name] = run("/usr/bin/lipo", "-archs", str(source / "Contents/MacOS" / name)).stdout.strip().split()
    if architectures["SuperIsland"] != ["arm64"] or any(value != ["arm64"] for value in architectures.values()):
        raise SystemExit("Expected matching arm64 app and helper architectures")
    destination = args.output_dir.resolve() / "SuperIsland Battery Review.app"
    if any((destination.parent / name).exists() for name in
           [destination.name, "SuperIsland-Battery-Review.zip", "package-report.json"]):
        raise SystemExit("Output already exists; choose a new review directory to preserve it")
    destination.parent.mkdir(parents=True, exist_ok=True)
    shutil.copytree(source, destination, symlinks=True)
    # The review bundle must never claim production OAuth/deep-link schemes.
    info.pop("CFBundleURLTypes", None)
    info.pop("BM1NativeCutoffTrial", None)
    info.pop("BM1NativeCutoffTrialDurationSeconds", None)
    info.pop("BM1DiagnosticsOnly", None)
    info.pop("BM1Preferences79Review", None)
    info.pop("BM1FullApplicationReview", None)
    info.pop("BM1PauseRefreshTrial", None)
    if args.pause_refresh_trial:
        info["BM1PauseRefreshTrial"] = True
    if args.full_application_review:
        info["BM1FullApplicationReview"] = True
    if args.native_cutoff_trial:
        info["BM1NativeCutoffTrial"] = True
        info["BM1NativeCutoffTrialDurationSeconds"] = 600
    if args.diagnostics_only:
        info["BM1DiagnosticsOnly"] = True
    if args.preferences79_review:
        info["BM1Preferences79Review"] = True
    daemon = destination / "Contents/Library/LaunchDaemons/com.workview.SuperIsland.BatteryManagementHelper.plist"
    with daemon.open("rb") as file:
        launch = plistlib.load(file)
    launch["ProgramArguments"] = ["Contents/MacOS/BatteryManagementHelper"]
    if args.diagnostics_only:
        launch["ProgramArguments"].append("--bm1-helper-diagnostics")
    with daemon.open("wb") as file:
        plistlib.dump(launch, file)
    info["CFBundleName"] = "SuperIsland Battery Review"
    info["CFBundleDisplayName"] = "SuperIsland Battery Review"
    # Distinguish successive locally signed review bundles for ServiceManagement.
    info["CFBundleVersion"] = datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%d%H%M%S")
    with (destination / "Contents/Info.plist").open("wb") as file:
        plistlib.dump(info, file)
    original_bytes = logical_size(destination)
    executables = {
        "SuperIsland": "com.workview.SuperIsland.BM1Debug",
        "BatteryManagementHelper": "com.workview.SuperIsland.BatteryManagementHelper",
        "KeepAwakeHelper": "com.workview.SuperIsland.KeepAwakeHelper",
        "KeepAwakeEventTool": "com.workview.SuperIsland.KeepAwakeEventTool",
    }
    for name, identifier in executables.items():
        path = destination / "Contents/MacOS" / name
        run("/usr/bin/strip", "-S", "-x", str(path))
        options = ["--entitlements", str(args.entitlements.resolve())] if name == "SuperIsland" else []
        run("/usr/bin/codesign", "--force", "--sign", args.identity,
            "--identifier", identifier, "--options", "runtime", *options, str(path))
    frameworks = destination / "Contents/Frameworks"
    for framework in sorted(frameworks.glob("*.framework")):
        with (framework / "Resources/Info.plist").open("rb") as file:
            framework_id = plistlib.load(file)["CFBundleIdentifier"]
        run("/usr/bin/codesign", "--force", "--sign", args.identity,
            "--identifier", framework_id, "--options", "runtime", str(framework))
    run("/usr/bin/codesign", "--force", "--sign", args.identity,
        "--identifier", "com.workview.SuperIsland.BM1Debug", "--options", "runtime",
        "--entitlements", str(args.entitlements.resolve()), str(destination))
    run("/usr/bin/codesign", "--verify", "--deep", "--strict", str(destination))
    actual_entitlements = plistlib.loads(run("/usr/bin/codesign", "--display", "--entitlements", "-", "--xml", str(destination)).stdout.encode())
    if actual_entitlements != entitlements:
        raise SystemExit("Application entitlements were not preserved")
    # XPC pins the leaf certificate as well as each exact executable identifier.
    # Verify this contract rather than relying on deep signature validation alone.
    with tempfile.TemporaryDirectory(prefix="bm1-signature-") as temp:
        prefix = str(Path(temp) / "certificate")
        run("/usr/bin/codesign", "--display", "--extract-certificates=" + prefix, str(destination))
        certificate = Path(prefix + "0")
        if not certificate.exists():
            raise SystemExit("A certificate-backed signing identity is required")
        leaf_sha1 = hashlib.sha1(certificate.read_bytes()).hexdigest()
    for name, identifier in executables.items():
        result = run("/usr/bin/codesign", "-d", "--verbose=2", str(destination / "Contents/MacOS" / name))
        if "Identifier=" + identifier + "\n" not in result.stderr:
            raise SystemExit("Signing identity mismatch: " + name)
        run("/usr/bin/codesign", "--verify", "--strict", "-R",
            '=certificate leaf = H"' + leaf_sha1 + '" and identifier "' + identifier + '"',
            str(destination / "Contents/MacOS" / name))
    resources = destination / "Contents/Resources"
    forbidden = [p for p in resources.rglob("*") if "charge-management" in str(p.relative_to(resources)) or p.name.endswith(".swift") or p.name.endswith(".xcresult")]
    if forbidden:
        raise SystemExit("Development artifact leaked into app resources: " + str(forbidden[0]))
    metadata = json.loads((resources / "Metadata.appintents/extract.actionsdata").read_text())
    actions = sorted(k for k in metadata["actions"] if k.startswith("Battery"))
    if len(actions) != 12:
        raise SystemExit("Expected12 battery App Intents, found " + str(len(actions)))
    package = destination.parent / "SuperIsland-Battery-Review.zip"
    run("/usr/bin/ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", str(destination), str(package))
    report = {
        "bundle": str(destination), "configuration": "Release arm64 local review",
        "beforeStripBytes": original_bytes, "appBytes": logical_size(destination),
        "zipBytes": package.stat().st_size,
        "zipSHA256": hashlib.sha256(package.read_bytes()).hexdigest(),
        "batteryIntents": actions, "signatureVerified": True,
        "leafCertificateSHA1": leaf_sha1, "architectures": architectures,
        "appEntitlementsPreserved": True, "bundleVersion": info["CFBundleVersion"],
        "installed": False, "helperRegistered": False,
        "hardwareWritesTested": False, "diagnosticsOnly": args.diagnostics_only,
        "fullApplicationReview": args.full_application_review,
        "nativeCutoffTrial": args.native_cutoff_trial,
        "preferences79Review": args.preferences79_review,
        "preferences79Scope": {
            "batteryRange": [79, 85], "fixedTarget": 79, "originalTarget": 80,
            "maximumControlSeconds": 180, "maximumObserve79Seconds": 150,
            "journalSchema": 2, "legacyJournalSchema1ControlSeconds": 60,
            "minimumFreshDischargeContexts": 2, "minimumDischargeSegmentSeconds": 15,
            "maximumRecoveryObservationSeconds": 180, "maximumChildSeconds": 3,
            "model": "Mac17,2", "osBuild": "26A434", "productionCapability": False,
            "smcWrites": False,
        } if args.preferences79_review else None,
        "trialScope": {"batteryRange": [79, 85], "dischargeMechanism": "nativeLimit", "dischargeTarget": 80,
                       "maximumDischargeSeconds": 600, "watchdogIntervalSeconds": 1,
                       "unknownConnectionTimeoutSeconds": 90, "leaseSeconds": 45} if args.native_cutoff_trial else None,
    }
    (destination.parent / "package-report.json").write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
    print(json.dumps(report, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
