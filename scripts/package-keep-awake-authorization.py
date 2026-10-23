#!/usr/bin/env python3
"""Build explicit, setup-only test PKGs. Never install or change host trust."""
import argparse
import hashlib
import html
import importlib.util
import json
from pathlib import Path
import plistlib
import re
import subprocess
import sys
import tempfile

sys.dont_write_bytecode = True
_spec = importlib.util.spec_from_file_location("ka1_test_package", Path(__file__).with_name("package-keep-awake-test.py"))
package = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(package)


def require(value, message):
    if not value:
        raise ValueError(message)


def validate_policy(policy):
    require(re.fullmatch(r"[0-9a-f]{64}", policy["sha256"]), "Invalid certificate SHA256")
    require(re.fullmatch(r"[0-9a-f]{40}", policy["sha1"]), "Invalid certificate SHA1")
    require(policy["bundleID"] in package.APP_IDS, "Unexpected App identifier")
    require(policy["architecture"] in ("arm64", "x86_64"), "Unsupported architecture")


def installer_script(mode, policy):
    validate_policy(policy)
    require(mode in ("enable", "remove"), "Invalid setup mode")
    # Only validated hexadecimal values enter shell literals. No runtime command,
    # path, certificate, trust domain or signing identity is supplied by a caller.
    common = r'''#!/bin/sh
set -eu
umask 077
PATH=/usr/bin:/bin:/usr/sbin:/sbin
export PATH
fail() { /usr/bin/printf '%s\n' "$1" >&2; exit 1; }
[ "$(/usr/bin/id -u)" = 0 ] || fail 'Administrator installation is required.'
[ "${3:-/}" = / ] || fail 'Only the current startup volume is supported.'
resources=$(CDPATH= cd -- "$(/usr/bin/dirname "$0")" && /bin/pwd -P)
cert="$resources/certificate.der"
inspector="$resources/inspect"
temporary=$(/usr/bin/mktemp -d /private/tmp/superisland-trust.XXXXXXXX)
base='/Library/Application Support/com.workview.SuperIsland.LocalSigning'
record="$base/@SHA256@"
receipt="$record/receipt.plist"
cleanup() {
  /bin/rm -f "$temporary/status.plist" "$temporary/helper.txt" "$temporary/power.txt"
  /bin/rmdir "$temporary" 2>/dev/null || true
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM
inspect() { "$inspector" "$cert" > "$temporary/status.plist" || fail 'Public signing inspection failed; no further changes made.'; }
field() { /usr/libexec/PlistBuddy -c "Print :$1" "$temporary/status.plist"; }
secure_directory() {
  [ ! -L "$1" ] || fail 'A setup directory is a symbolic link.'
  if [ ! -e "$1" ]; then /bin/mkdir "$1"; /bin/chmod 700 "$1"; fi
  [ -d "$1" ] && [ "$(/usr/bin/stat -f %u "$1")" = 0 ] || fail 'Setup directory ownership is invalid.'
  permissions=$(/usr/bin/stat -f %OLp "$1")
  [ $((0$permissions & 022)) = 0 ] || fail 'Setup directory is writable by another account.'
}
valid_receipt() {
  [ -f "$receipt" ] && [ ! -L "$receipt" ] && [ "$(/usr/bin/stat -f %u "$receipt")" = 0 ] || fail 'Setup receipt is not a root-owned regular file.'
  permissions=$(/usr/bin/stat -f %OLp "$receipt")
  [ $((0$permissions & 077)) = 0 ] || fail 'Setup receipt permissions are invalid.'
  [ "$(/usr/libexec/PlistBuddy -c 'Print :CertificateSHA256' "$receipt")" = '@SHA256@' ] || fail 'Setup receipt identity mismatch.'
  [ "$(/usr/libexec/PlistBuddy -c 'Print :Version' "$receipt")" = 1 ] || fail 'Unsupported setup receipt.'
  [ "$(/usr/libexec/PlistBuddy -c 'Print :AdminAdded' "$receipt")" = true ] || fail 'This setup does not own the administrator trust.'
  phase=$(/usr/libexec/PlistBuddy -c 'Print :Phase' "$receipt")
  case "$phase" in intent|applied) ;; *) fail 'Unknown setup transaction state.' ;; esac
  added=$(/usr/libexec/PlistBuddy -c 'Print :CertificateAdded' "$receipt")
  case "$added" in true|false) ;; *) fail 'Invalid certificate ownership record.' ;; esac
}
lock_record() {
  [ ! -L "$record/transaction.lock" ] || fail 'Invalid transaction lock.'
  if [ -e "$record/transaction.lock" ]; then
    [ -f "$record/transaction.lock" ] && [ "$(/usr/bin/stat -f %u "$record/transaction.lock")" = 0 ] || fail 'Invalid transaction lock ownership or type.'
    permissions=$(/usr/bin/stat -f %OLp "$record/transaction.lock")
    [ $((0$permissions & 077)) = 0 ] || fail 'Invalid transaction lock permissions.'
  fi
  if [ "${4:-}" != SI_TRANSACTION_LOCKED ]; then
    cleanup
    # Use lockf's longstanding command form, rather than its newer fd form.
    # Re-check the live state inside the locked child before any trust write.
    exec /usr/bin/lockf -k -s -t 0 "$record/transaction.lock" /bin/sh "$0" "${1:-}" "${2:-}" "${3:-/}" SI_TRANSACTION_LOCKED
  fi
}
inspect
[ "$(field CertificateSHA256)" = '@SHA256@' ] || fail 'Certificate fingerprint mismatch.'
'''
    enable = r'''
[ "$(field Notebook)" = true ] || fail 'This Mac does not have a supported built-in battery; lid setup is unnecessary.'
[ "$(field AppSignatureValid)" = true ] || fail 'Install the matching signed SuperIsland.app in /Applications first.'
if [ "$(field AdminEntryPresent)" = true ]; then
  /usr/bin/security verify-cert -q -L -R offline -p codeSign -c "$cert" || fail 'Existing certificate trust is not usable for code signing; it was left unchanged.'
  /usr/bin/printf '%s\n' 'Existing code-signing trust retained; no trust settings changed.'
  exit 0
fi
secure_directory /Library
secure_directory '/Library/Application Support'
secure_directory "$base"
secure_directory "$record"
lock_record "$@"
[ ! -e "$receipt" ] && [ ! -L "$receipt" ] || fail 'An earlier setup transaction exists; review or remove it before enabling again.'
[ ! -e "$record/certificate.der" ] && [ ! -L "$record/certificate.der" ] || fail 'An unrecognized certificate file already exists.'
certificateAdded=false
if [ "$(field SystemCertificatePresent)" = false ]; then certificateAdded=true; fi
/bin/cp "$cert" "$record/certificate.der"
/bin/chmod 600 "$record/certificate.der"
/usr/bin/printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict><key>Version</key><integer>1</integer><key>CertificateSHA256</key><string>@SHA256@</string><key>AdminAdded</key><true/><key>CertificateAdded</key><'$certificateAdded'/><key>Phase</key><string>intent</string></dict></plist>' > "$receipt"
/bin/chmod 600 "$receipt"
/bin/sync
# Intent is retained if a command fails or installation is interrupted. The
# remove package can recover it; no helper is registered by either package.
/usr/bin/security add-trusted-cert -d -r trustRoot -p codeSign -k /Library/Keychains/System.keychain "$cert"
inspect
[ "$(field AdminEntryPresent)" = true ] && [ "$(field ExactCodeSigningTrust)" = true ] && [ "$(field SystemCertificatePresent)" = true ] || fail 'Code-signing trust was not confirmed; the recovery receipt was retained.'
/usr/libexec/PlistBuddy -c 'Set :Phase applied' "$receipt"
/usr/bin/printf '%s\n' 'SuperIsland local test code-signing trust is ready. Enable lid support in the App to continue.'
'''
    remove = r'''
if [ ! -e "$receipt" ] && [ ! -L "$receipt" ]; then
  /usr/bin/printf '%s\n' 'No managed setup receipt exists; existing trust was left unchanged.'
  exit 0
fi
secure_directory /Library
secure_directory '/Library/Application Support'
secure_directory "$base"
secure_directory "$record"
lock_record "$@"
valid_receipt
"$inspector" "$record/certificate.der" > "$temporary/status.plist" || fail 'The managed public certificate changed; trust was retained.'
if /bin/launchctl print system/com.workview.SuperIsland.KeepAwakeHelper > "$temporary/helper.txt" 2>&1; then
  fail 'Revoke lid support inside SuperIsland before removing its test trust.'
else
  status=$?
  [ "$status" = 113 ] || fail 'Unable to verify that the helper is unregistered.'
fi
/usr/bin/pmset -g > "$temporary/power.txt"
sleepDisabled=$(/usr/bin/awk '$1 == "SleepDisabled" {print $2}' "$temporary/power.txt")
[ "$sleepDisabled" = 0 ] || fail 'System sleep restoration has not been confirmed; test trust was retained.'
if [ "$(field AdminEntryPresent)" = true ]; then
  [ "$(field ExactCodeSigningTrust)" = true ] || fail 'Certificate trust was modified outside this setup; it was left unchanged.'
  /usr/bin/security remove-trusted-cert -d "$cert"
fi
if [ "$added" = true ] && [ "$(field SystemCertificatePresent)" = true ]; then
  /usr/bin/security delete-certificate -Z @SHA256@ /Library/Keychains/System.keychain
fi
inspect
[ "$(field AdminEntryPresent)" = false ] || fail 'Administrator trust removal was not confirmed.'
if [ "$added" = true ]; then
  [ "$(field SystemCertificatePresent)" = false ] || fail 'Public certificate removal was not confirmed.'
fi
/bin/rm -f "$receipt" "$record/certificate.der"
/usr/bin/printf '%s\n' 'SuperIsland managed local test trust removed; login identities were not changed.'
'''
    return (common + (enable if mode == "enable" else remove)).replace("@SHA256@", policy["sha256"])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--package-dir", type=Path, required=True)
    parser.add_argument("--output-dir", type=Path, required=True)
    parser.add_argument("--signing-identity", required=True)
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    source = args.package_dir.resolve()
    manifest = json.loads((source / "manifest.json").read_text())
    require(not package.run("git", "-C", root, "status", "--porcelain").stdout, "Commit reviewed source before building authorization packages")
    require(manifest["source_revision"] == package.run("git", "-C", root, "rev-parse", "HEAD").stdout.strip() and
            manifest["source_tree"] == package.run("git", "-C", root, "rev-parse", "HEAD^{tree}").stdout.strip(),
            "App package and authorization source must have the same revision/tree")
    app = source / "SuperIsland.app"
    require(manifest.get("test_only") is True and manifest.get("scope") == "native-keep-awake-test", "A reviewed native test package is required")
    require(package.app_digest(app) == manifest["candidate_app_sha256"], "Packaged App changed")
    records = package.verify_signatures(app, manifest["bundle_id"])
    require(records == manifest["signatures"], "Packaged signing identity changed")
    package.inspect_app(app, manifest["architecture"])
    signature = records["Contents/MacOS/SuperIsland"]
    policy = dict(sha256=signature["certificate_sha256"], sha1=signature["certificate_sha1"],
                  bundleID=manifest["bundle_id"], architecture=manifest["architecture"])
    validate_policy(policy)
    out = args.output_dir.resolve()
    require(not out.exists(), "Output must be new")
    require(not out.is_relative_to(app.resolve()), "Output cannot modify the source App")
    out.mkdir(parents=True)
    with tempfile.TemporaryDirectory(prefix="superisland-local-authorization-") as temporary:
        work = Path(temporary)
        resources = work / "resources"; resources.mkdir()
        prefix = work / "cert-"
        package.run("codesign", "-d", "--extract-certificates=" + str(prefix), app)
        certificate = Path(str(prefix) + "0").read_bytes()
        require(hashlib.sha256(certificate).hexdigest() == policy["sha256"], "Extracted certificate mismatch")
        swift = work / "main.swift"
        policy_swift = "enum SetupPolicy {\n" + "\n".join(" static let " + key + " = " + json.dumps(policy[key]) for key in ("sha256", "sha1", "bundleID")) + "\n}\n"
        swift.write_text(policy_swift + (root / "KeepAwakeSetup/inspect.swift").read_text())
        inspector = work / "inspect"
        package.run("xcrun", "swiftc", "-O", "-target", policy["architecture"] + "-apple-macos14.0", swift, "-o", inspector)
        package.run("codesign", "--force", "--options", "runtime", "--timestamp=none", "--identifier", "com.workview.SuperIsland.LocalSigningInspector", "--sign", args.signing_identity, inspector)
        package.run("codesign", "--verify", "--strict", "-R", '=certificate leaf = H"' + policy["sha1"] + '" and identifier "com.workview.SuperIsland.LocalSigningInspector"', inspector)
        require(package.run("lipo", "-archs", inspector).stdout.split() == [policy["architecture"]], "Inspector architecture mismatch")
        package.validate_no_host_dependencies("LocalSigningInspector", package.run("xcrun", "otool", "-l", inspector).stdout,
                                              package.run("xcrun", "otool", "-L", inspector).stdout)
        for mode in ("enable", "remove"):
            scripts = work / mode; scripts.mkdir()
            (scripts / "postinstall").write_text(installer_script(mode, policy)); (scripts / "postinstall").chmod(0o755)
            (scripts / "certificate.der").write_bytes(certificate)
            package.run("ditto", inspector, scripts / "inspect")
            package.run("/bin/sh", "-n", scripts / "postinstall")
            component = work / (mode + ".pkg")
            identifier = "com.workview.SuperIsland.LocalSigning." + policy["sha256"][:16] + "." + mode
            package.run("pkgbuild", "--nopayload", "--scripts", scripts,
                        "--identifier", identifier,
                        "--version", "1.0", component)
            title = "SuperIsland 测试版合盖授权" if mode == "enable" else "撤销 SuperIsland 测试签名授权"
            detail = ("将这张测试证书加入系统信任，仅用于代码签名，持续保留直到撤销。信任适用于该证书签署的程序，不只限于本 App；不修改 SSL 信任、Gatekeeper 或隔离属性。" if mode == "enable" else
                      "请先在 SuperIsland 中撤销合盖授权。仅移除配套启用包记录为本次新增且未被外部修改的信任和公开证书；保留原有登录钥匙串和其他证书。")
            welcome = resources / (mode + ".html")
            welcome.write_text('<html><meta charset="utf-8"><body><h2>' + title + '</h2><p>' + detail + '</p><p>这是未经 Apple 公证的内部测试安装包，可能被系统阻止；请保留系统保护并使用已公证版本进行正式分发。</p><p>本包不安装 App、不注册辅助程序、不修改电源。请先将配套 SuperIsland.app 放入 /Applications，再在 App 设置中单独授权。</p><p>证书 SHA-256：<code>' + policy["sha256"] + '</code></p></body></html>')
            distribution = work / (mode + ".xml")
            distribution.write_text('<?xml version="1.0"?><installer-gui-script minSpecVersion="2"><title>' + title + '</title><welcome file="' + welcome.name + '"/><options customize="never" hostArchitectures="' + policy["architecture"] + '"/><allowed-os-versions><os-version min="14.0"/></allowed-os-versions><domains enable_localSystem="true" enable_currentUserHome="false" enable_anywhere="false"/><choices-outline><line choice="trust"/></choices-outline><choice id="trust" visible="false" title="' + title + '"><pkg-ref id="' + identifier + '"/></choice><pkg-ref id="' + identifier + '" version="1.0" auth="Root">' + html.escape(component.name) + '</pkg-ref></installer-gui-script>')
            destination = out / ("SuperIsland-Local-Test-" + mode + ".pkg")
            package.run("productbuild", "--distribution", distribution, "--resources", resources, "--package-path", work, destination)
            expanded = work / (mode + "-expanded")
            package.run("pkgutil", "--expand-full", destination, expanded)
            extracted = list(expanded.rglob("postinstall"))
            require(len(extracted) == 1 and extracted[0].read_text() == installer_script(mode, policy), "Installer script round-trip mismatch")
            embedded_cert = list(expanded.rglob("certificate.der"))
            require(len(embedded_cert) == 1 and embedded_cert[0].read_bytes() == certificate, "Installer certificate mismatch")
            embedded_tool = list(expanded.rglob("inspect"))
            require(len(embedded_tool) == 1 and package.sha(embedded_tool[0]) == package.sha(inspector), "Installer inspector mismatch")
            package.run("/bin/sh", "-n", extracted[0])
    results = {p.name: package.sha(p) for p in out.glob("*.pkg")}
    (out / "manifest.json").write_text(json.dumps(dict(policy=policy, source_revision=manifest["source_revision"], app_sha256=manifest["candidate_app_sha256"], packages=results, installed=False, system_trust_modified=False, test_only=True, notarized=False, signed_installer=False), ensure_ascii=False, indent=2) + "\n")
    (out / "说明.txt").write_text("内部测试配套包；不安装App。先放置配套App，再在系统安装器中阅读并批准 enable 包。它持续信任此证书的代码签名；不同版本沿用同一证书时无需重做。App 中启用合盖支持仍走系统后台项目批准。撤销时先在App中撤销合盖授权，再运行 remove 包。没有 Developer ID/公证，其他Mac首次安装可能被系统拦截；本包不绕过系统保护。\n证书 SHA-256：" + policy["sha256"] + "\n")
    print(json.dumps(dict(output=str(out), packages=results, installed=False), ensure_ascii=False))


if __name__ == "__main__":
    try:
        main()
    except (ValueError, KeyError, OSError, subprocess.CalledProcessError) as error:
        raise SystemExit("Authorization package rejected: " + str(error))
