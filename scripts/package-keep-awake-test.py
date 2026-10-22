#!/usr/bin/env python3
"""Package a reviewed build for cross-Mac testing; never install or notarize it."""
import argparse
import datetime
import fnmatch
import hashlib
import importlib.util
import json
from pathlib import Path
import plistlib
import re
import subprocess
import sys
import tempfile


# Keep the existing receipt digest algorithm as the single source of truth.
_spec = importlib.util.spec_from_file_location(
    "superisland_local_packaging", Path(__file__).with_name("package-local-release.py"))
_local = importlib.util.module_from_spec(_spec)
_previous_bytecode = sys.dont_write_bytecode
try:
    sys.dont_write_bytecode = True  # Import must not dirty the checkout before its clean-build gate.
    _spec.loader.exec_module(_local)
finally:
    sys.dont_write_bytecode = _previous_bytecode
app_digest, sha, run = _local.app_digest, _local.sha, _local.run

APP_IDS = {"com.workview.SuperIsland", "com.workview.SuperIsland.WE1Debug"}
HELPER_ID = "com.workview.SuperIsland.KeepAwakeHelper"
TOOL_ID = "com.workview.SuperIsland.KeepAwakeEventTool"
CORE = {"Contents/MacOS/SuperIsland": None,
        "Contents/MacOS/KeepAwakeHelper": HELPER_ID,
        "Contents/MacOS/KeepAwakeEventTool": TOOL_ID}
NODE = "Contents/Resources/node"
MACHO_MAGICS = {bytes.fromhex(value) for value in (
    "feedface", "cefaedfe", "feedfacf", "cffaedfe", "cafebabe", "bebafeca", "cafebabf", "bfbafeca")}
TEST_PATTERNS = ("*.xctest", "*.debug.dylib", "XCTest*.framework", "Testing.framework",
                 "XCUnit.framework", "XCTAutomationSupport.framework", "XCUIAutomation.framework",
                 "libXCTest*.dylib", "libclang_rt.*san*_osx_dynamic.dylib")


class PackageError(RuntimeError):
    pass


def require(condition, message):
    if not condition:
        raise PackageError(message)


def validate_provenance(receipt, *, root, head, tree, clean):
    require(clean, "Commit reviewed source first; the working tree must be clean")
    require(type(receipt.get("exitCode")) is int and receipt["exitCode"] == 0,
            "The receipt must record a successful build")
    require(receipt.get("sourceUnchangedDuringBuild") is True, "Build source stability was not verified")
    require(receipt.get("sourceRevision") == head and receipt.get("sourceTree") == tree,
            "Receipt revision/tree do not match this checkout")
    source_root = Path(receipt.get("sourceRoot", ""))
    source_app = Path(receipt.get("sourceApp", ""))
    require(source_root.is_absolute() and source_root.resolve() == root.resolve(),
            "Receipt belongs to another checkout")
    require(source_app.is_absolute() and source_app.suffix == ".app", "Receipt sourceApp must be an absolute .app")
    for key in ("sourceBinarySHA256", "sourceAppSHA256"):
        require(isinstance(receipt.get(key), str) and re.fullmatch(r"[0-9a-f]{64}", receipt[key]),
                "Receipt lacks a valid " + key)


def validate_metadata(info, daemon):
    bundle_id = info.get("CFBundleIdentifier")
    require(bundle_id in APP_IDS, "Main bundle identifier is not authorized by this helper")
    require(info.get("CFBundleExecutable") == "SuperIsland", "Unexpected main executable")
    require(daemon.get("Label") == HELPER_ID and
            daemon.get("BundleProgram") == "Contents/MacOS/KeepAwakeHelper" and
            daemon.get("MachServices") == {HELPER_ID: True}, "Helper daemon packaging is incompatible")
    require(bundle_id in daemon.get("AssociatedBundleIdentifiers", []), "Daemon does not associate the main App")
    return bundle_id


def package_metadata(source_info, receipt, build_number):
    info = dict(source_info)
    info.update(CFBundleName="SuperIsland", CFBundleDisplayName="SuperIsland",
                CFBundleVersion=build_number, WE1BuildType="Optimized",
                WE1SourceRevision=receipt["sourceRevision"],
                WE1SourceExecutableSHA256=receipt["sourceBinarySHA256"])
    if info.get("CFBundleIdentifier") == "com.workview.SuperIsland.WE1Debug":
        # The test identity does not own production OAuth or deep-link routes.
        info.pop("CFBundleURLTypes", None)
    return info


def validate_architectures(inventory, architecture):
    require(architecture in ("arm64", "x86_64"), "Only explicit arm64 or x86_64 test packages are supported")
    for name in CORE:
        require(name in inventory, "Required native component missing: " + name)
    for name, slices in inventory.items():
        require(architecture in slices, "Missing " + architecture + " slice: " + name)
        if name in CORE:
            require(set(slices) == {architecture}, "Core executable must match the selected single architecture: " + name)


def validate_no_instrumentation(name, loads):
    require(not any(fnmatch.fnmatch(part, pattern) for part in Path(name).parts for pattern in TEST_PATTERNS),
            "Test/debug runtime is not distributable: " + name)
    require("__llvm_cov" not in loads and "__llvm_prf" not in loads,
            "Coverage instrumentation remains: " + name)
    require(not any(value in loads for value in ("XCTest.framework", "Testing.framework", "libXCTest", ".debug.dylib")),
            "Native component links a test/debug runtime: " + name)


def validate_no_host_dependencies(name, loads, links):
    paths = []
    for line in loads.splitlines():
        value = line.strip()
        if value.startswith(("path ", "name ")):
            paths.append(value.split(" ", 1)[1].split(" (offset", 1)[0])
    for line in links.splitlines():
        if line.startswith((" ", "\t")):
            paths.append(line.strip().split(" (compatibility", 1)[0])
    system = ("/System/Library/", "/usr/lib/", "/Library/Apple/System/Library/")
    require(all(not value.startswith("/") or value.startswith(system) for value in paths),
            "Native component depends on a build-host path outside macOS: " + name)


def inspect_app(app, architecture, command=run):
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    daemon = plistlib.loads((app / "Contents/Library/LaunchDaemons" / (HELPER_ID + ".plist")).read_bytes())
    bundle_id = validate_metadata(info, daemon)
    inventory = {}
    seen = {}
    for path in sorted(app.rglob("*")):
        relative = path.relative_to(app).as_posix()
        validate_no_instrumentation(relative, "")
        if path.is_symlink():
            require(not path.readlink().is_absolute() and path.resolve().is_relative_to(app.resolve()),
                    "Bundle symlink escapes the package: " + relative)
        if not path.is_file():
            continue
        resolved = path.resolve()
        if resolved in seen:
            inventory[relative] = seen[resolved]
            continue
        with path.open("rb") as handle:
            magic = handle.read(4)
        if magic not in MACHO_MAGICS:
            continue
        slices = command("lipo", "-archs", path).stdout.split()
        loads = command("xcrun", "otool", "-l", path).stdout
        links = command("xcrun", "otool", "-L", path).stdout
        validate_no_instrumentation(relative, loads + links)
        validate_no_host_dependencies(relative, loads, links)
        inventory[relative] = slices
        seen[resolved] = slices
    validate_architectures(inventory, architecture)
    require(not (app / NODE).exists() or NODE in inventory, "Included Node must be a validated native executable")
    return info, bundle_id, inventory


def entitlements(path, command=run):
    try:
        result = command("codesign", "-d", "--entitlements", ":-", path)
    except subprocess.CalledProcessError as error:
        # Unsigned build outputs have no signing capabilities to preserve.
        require(error.returncode == 1 and "not signed at all" in (error.stderr or ""),
                "Cannot inspect existing entitlements")
        return None
    output = result.stdout.encode() if isinstance(result.stdout, str) else result.stdout
    if not output.strip():
        return None
    try:
        value = plistlib.loads(output)
    except Exception as error:
        raise PackageError("Cannot parse existing entitlements") from error
    require(isinstance(value, dict), "Existing entitlements must be a dictionary")
    return value


def signing_commands(app, identity, bundle_id, main_entitlements):
    common = ["codesign", "--force", "--sign", identity, "--timestamp=none", "--options", "runtime"]
    # No entitlements argument on --deep: do not apply App capabilities to Node,
    # helper, frameworks or other nested executables. Preserve theirs instead.
    commands = [common + ["--deep", "--preserve-metadata=entitlements,identifier", app]]
    for relative, identifier in CORE.items():
        if identifier:
            commands.append(common + ["--preserve-metadata=entitlements", "--identifier", identifier, app / relative])
    commands.append(common + ["--identifier", bundle_id, "--entitlements", main_entitlements, app])
    return commands


def validate_core_signatures(records, bundle_id):
    require(set(records) == set(CORE), "All three core signatures must be verified")
    fingerprints = set()
    for name, expected in CORE.items():
        value = records[name]
        require(value["identifier"] == (expected or bundle_id), "Incorrect signed identifier: " + name)
        require(re.fullmatch(r"[0-9a-f]{64}", value["certificate_sha256"] or ""),
                "A real certificate signature is required; ad-hoc is not supported")
        require(value["hardened_runtime"], "Hardened Runtime is missing: " + name)
        fingerprints.add(value["certificate_sha256"])
    require(len(fingerprints) == 1, "App, Helper and EventTool must use the same signing certificate")


def verify_signatures(app, bundle_id, command=run):
    command("codesign", "--verify", "--deep", "--strict", app)
    records = {}
    with tempfile.TemporaryDirectory(prefix="superisland-public-cert-check-") as directory:
        for index, (relative, expected) in enumerate(CORE.items()):
            target = app if expected is None else app / relative
            command("codesign", "--verify", "--strict", "-R", '=identifier "' + (expected or bundle_id) + '"', target)
            result = command("codesign", "-d", "--verbose=4", target)
            details = result.stdout + result.stderr
            identifier = re.search(r"^Identifier=(.+)$", details, re.MULTILINE)
            require(identifier is not None, "Cannot read signature identifier")
            prefix = Path(directory) / (str(index) + "-cert-")
            # Extract only the PUBLIC certificate embedded in our output;
            # never read, copy or export a Keychain private key.
            command("codesign", "-d", "--extract-certificates", prefix, target)
            leaf = Path(str(prefix) + "0")
            require(leaf.is_file() and leaf.stat().st_size > 0, "Ad-hoc or unsigned test package is unsupported")
            certificate = leaf.read_bytes()
            flags = re.search(r"flags=0x([0-9a-fA-F]+)", details)
            records[relative] = dict(identifier=identifier.group(1),
                                     certificate_sha256=hashlib.sha256(certificate).hexdigest(),
                                     certificate_sha1=hashlib.sha1(certificate).hexdigest(),
                                     hardened_runtime=flags is not None and bool(int(flags.group(1), 16) & 0x10000),
                                     binary_sha256=sha(app / relative))
    validate_core_signatures(records, bundle_id)
    return records


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--build-receipt", required=True, type=Path)
    parser.add_argument("--output-dir", required=True, type=Path)
    parser.add_argument("--signing-identity", required=True)
    parser.add_argument("--architecture", required=True, choices=("arm64", "x86_64"))
    parser.add_argument("--build-number", default=datetime.datetime.now().strftime("%Y%m%d%H%M%S"))
    args = parser.parse_args()
    require(args.signing_identity.strip() not in ("", "-"), "Supply an existing certificate identity; do not use ad-hoc signing")
    require(re.fullmatch(r"\d{14}", args.build_number), "Build number must use YYYYMMDDHHMMSS")
    datetime.datetime.strptime(args.build_number, "%Y%m%d%H%M%S")
    root = Path(__file__).resolve().parents[1]
    receipt = json.loads(args.build_receipt.read_text())
    validate_provenance(receipt, root=root,
                        head=run("git", "-C", root, "rev-parse", "HEAD").stdout.strip(),
                        tree=run("git", "-C", root, "rev-parse", "HEAD^{tree}").stdout.strip(),
                        clean=not run("git", "-C", root, "status", "--porcelain").stdout)
    source = Path(receipt["sourceApp"]).resolve()
    require(sha(source / "Contents/MacOS/SuperIsland") == receipt["sourceBinarySHA256"], "Source binary changed after the build")
    require(app_digest(source) == receipt["sourceAppSHA256"], "Source app changed after the build")
    info, bundle_id, inventory = inspect_app(source, args.architecture)
    output = args.output_dir.resolve()
    require(not output.is_relative_to(source), "Output directory cannot be inside the source App")
    require(not output.exists(), "Output directory must be new; previous packages are never overwritten")
    saved_entitlements = {name: entitlements(source / name) for name in inventory}
    main_permissions = saved_entitlements["Contents/MacOS/SuperIsland"]
    if main_permissions is None:
        # An unsigned build uses the same committed, declared App permissions.
        main_permissions = plistlib.loads((root / "SuperIsland/SuperIsland.entitlements").read_bytes())
    for name, permissions in saved_entitlements.items():
        effective = main_permissions if name == "Contents/MacOS/SuperIsland" else permissions or {}
        require(effective.get("com.apple.security.get-task-allow") is not True,
                "Debug get-task-allow entitlement is not supported: " + name)
    output.mkdir(parents=True, exist_ok=False)
    candidate = output / "SuperIsland.app"
    run("ditto", source, candidate)
    require(app_digest(candidate) == receipt["sourceAppSHA256"], "Copied App differs from the verified source")
    info = package_metadata(info, receipt, args.build_number)
    (candidate / "Contents/Info.plist").write_bytes(plistlib.dumps(info, sort_keys=False))
    with tempfile.TemporaryDirectory(prefix="superisland-test-signing-") as directory:
        permission_file = Path(directory) / "app.entitlements"
        permission_file.write_bytes(plistlib.dumps(main_permissions))
        for command in signing_commands(candidate, args.signing_identity, bundle_id, permission_file):
            run(*command)
    records = verify_signatures(candidate, bundle_id)
    _, _, packaged_inventory = inspect_app(candidate, args.architecture)
    require(inventory == packaged_inventory, "Signing changed native component architecture")
    for name, before in saved_entitlements.items():
        expected = main_permissions if name == "Contents/MacOS/SuperIsland" else before
        require((entitlements(candidate / name) or {}) == (expected or {}), "Signing changed component permissions: " + name)
    archive = output / ("SuperIsland-" + args.build_number + "-" + args.architecture + "-test.zip")
    run("ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", candidate, archive)
    run("unzip", "-tq", archive)
    candidate_digest = app_digest(candidate)
    with tempfile.TemporaryDirectory(prefix="superisland-test-zip-check-") as directory:
        run("ditto", "-x", "-k", archive, directory)
        extracted = Path(directory) / candidate.name
        require(app_digest(extracted) == candidate_digest, "ZIP changed App files, permissions or symlinks")
        require(verify_signatures(extracted, bundle_id) == records, "ZIP changed signature identity")
        inspect_app(extracted, args.architecture)
    manifest = dict(source_revision=receipt["sourceRevision"], source_tree=receipt["sourceTree"],
                    source_app_sha256=receipt["sourceAppSHA256"], source_binary_sha256=receipt["sourceBinarySHA256"],
                    build_number=args.build_number, architecture=args.architecture, app_file_name=candidate.name,
                    candidate_app=str(candidate), candidate_app_sha256=candidate_digest, bundle_id=bundle_id,
                    candidate_binary_sha256=records["Contents/MacOS/SuperIsland"]["binary_sha256"],
                    signatures=records, native_architectures=packaged_inventory, zip_sha256=sha(archive),
                    signed=True, test_only=True, notarized=False, installed=False,
                    scope="native-keep-awake-test", bundled_node=NODE in packaged_inventory,
                    extension_runtime_portability_verified=False,
                    runtime_validation="not_performed", gatekeeper_bypass=False)
    (output / "manifest.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n")
    (output / "SHA256SUMS.txt").write_text(sha(archive) + "  " + archive.name + "\n")
    (output / "说明.txt").write_text(
        "SuperIsland " + args.build_number + "（" + args.architecture + "，仅测试）\n"
        "保留构建的应用身份、原有权限与嵌套组件权限；没有复制任何本机私钥。\n"
        "已使用所提供的现有证书签名，未经过 Apple 公证，未安装、启动或完成跨机验收。\n"
        "本包仅测试原生保持唤醒；未验证所有 JS 扩展运行时的跨机兼容性，不是 Universal 正式分发包。\n"
        "其他 Mac 仍可能被 Gatekeeper 拒绝；本工具不会移除隔离属性、降低系统策略或自动安装。\n"
        "合盖辅助程序和 Codex hooks 仍须在各电脑按正常流程明确授权。\n")
    print(json.dumps(manifest, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    try:
        main()
    except (PackageError, ValueError, KeyError, OSError, subprocess.CalledProcessError) as error:
        raise SystemExit("Test package rejected: " + str(error))
