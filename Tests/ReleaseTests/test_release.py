import gzip
import importlib.util
import io
import json
import os
import plistlib
import shutil
import subprocess
import tarfile
import tempfile
import unittest
import zipfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("collect_notices", ROOT / "scripts/collect-notices.py")
NOTICES = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(NOTICES)


class ReleaseTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        (self.root / "scripts").mkdir()
        for name in ["bundle-ghostty-resources.sh", "collect-notices.py", "package-release.sh", "setup-ghostty.sh",
                     "ghostty-version.env", "sparkle-public-key.env"]:
            shutil.copy(ROOT / "scripts" / name, self.root / "scripts" / name)
        self.env = dict(os.environ)
        for name in ["GHOSTTYKIT", "GHOSTTY_SRC", "GHOSTTY_RESOURCES", "GHOSTTY_NOTICES", "ZIG", "BUILD_NUMBER",
                     "MUXIFY_RELEASE_IDENTITY", "MUXIFY_RELEASE_KEYCHAIN"]:
            self.env.pop(name, None)

    def write(self, relative, content):
        path = self.root / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content)
        return path

    def run_script(self, name, *args):
        return subprocess.run(
            ["/bin/bash", str(self.root / "scripts" / name), *args],
            env=self.env, text=True, capture_output=True,
        )

    def fake_tool(self, name, content):
        path = self.write(f"tools/{name}", "#!/bin/bash\n" + content + "\n")
        path.chmod(0o755)
        self.env["PATH"] = str(path.parent) + os.pathsep + self.env["PATH"]

    def bundle_fixture(self):
        for relative in [
            "terminfo/78/xterm-ghostty",
            "ghostty/themes/Example",
            "ghostty/shell-integration/zsh/ghostty-integration",
            "ghostty/shell-integration/zsh/.zshenv",
        ]:
            self.write(f"vendor/ghostty/resources/{relative}", "resource\n")
        self.write("vendor/ghostty/notices/Ghostty.txt", "Ghostty license\n")
        self.write("build/SourcePackages/checkouts/Yams/LICENSE", "Yams license\n")
        self.env["TARGET_BUILD_DIR"] = str(self.root / "products")
        self.env["UNLOCALIZED_RESOURCES_FOLDER_PATH"] = "Muxify.app/Contents/Resources"

    PUBLIC_KEY = "A" * 43 + "="
    IDENTITY_HASH = "0123456789ABCDEF0123456789ABCDEF01234567"
    FEED_BASE_URL = "https://github.com/muxify-dev/muxify/releases/download/appcast/"
    BUILT_APP = "build/Build/Products/Release/Muxify.app"

    def package_fixture(self):
        pins = dict(
            line.split("=", 1) for line in (ROOT / "scripts/ghostty-version.env").read_text().splitlines()
            if line and not line.startswith("#")
        )
        self.write("vendor/ghostty/build-info.json", json.dumps({
            "commit": pins["GHOSTTY_COMMIT"], "zig": pins["GHOSTTY_ZIG_VERSION"], "arch": "arm64", "dirty": False,
        }))
        self.write("vendor/ghostty/notices/Ghostty.txt", "Upstream notices\n")
        self.write("scripts/sparkle-public-key.env", f"SPARKLE_PUBLIC_ED_KEY={self.PUBLIC_KEY}\n")
        app = self.BUILT_APP
        executable = self.write(f"{app}/Contents/MacOS/MuxifyApp", "fixture\n")
        executable.chmod(0o755)
        (self.root / app / "Contents/Info.plist").write_bytes(plistlib.dumps({
            "CFBundleIdentifier": "dev.muxify.shell", "CFBundleVersion": "1", "CFBundleShortVersionString": "0.1.0",
        }))
        for name in ["Ghostty", "Yams", "libyaml"]:
            self.write(f"{app}/Contents/Resources/ThirdPartyNotices/{name}.txt", "License\n")
        link = self.root / app / "Contents/Resources/notice-link"
        link.symlink_to("ThirdPartyNotices/Ghostty.txt")
        self.keychain = self.write("keychains/release.keychain-db", "keychain fixture\n")
        self.env["MUXIFY_RELEASE_IDENTITY"] = "Muxify Release Signing"
        self.env["MUXIFY_RELEASE_KEYCHAIN"] = str(self.keychain)
        self.env["FAKE_SHALLOW"] = "false"
        self.env["FAKE_COUNT"] = "1234"
        self.fake_tool("uname", "echo arm64")
        self.fake_tool("make", "exit 0")
        self.fake_tool("git", '''
case "$*" in
  "rev-parse --is-shallow-repository") echo "$FAKE_SHALLOW" ;;
  "rev-list --count HEAD") echo "$FAKE_COUNT" ;;
  "rev-parse --short=7 HEAD") echo abcdef1 ;;
  "rev-parse HEAD") echo abcdef1234567890abcdef1234567890abcdef12 ;;
  "status --porcelain") ;;
  *) echo "unexpected git $*" >&2; exit 1 ;;
esac''')
        self.fake_tool("security", f'''
[ "$1 $2 $3 $4" = "find-identity -p codesigning $MUXIFY_RELEASE_KEYCHAIN" ] || exit 1
echo "  1) {self.IDENTITY_HASH} \\"Muxify Release Signing Old\\""
echo "  2) {self.IDENTITY_HASH[::-1]} \\"Muxify Release Signing\\""
echo "     2 valid identities found"''')
        self.fake_tool("xcodebuild", 'if [ "$1" = -version ]; then echo "Xcode fixture"; else printf "%s\\n" "$@" > xcode-args.txt; fi')
        self.fake_tool("codesign", '''
printf "%s\\n" "$*" >> codesign-args.txt
if [ "$1" = -dvv ]; then echo "Authority=Muxify Release Signing" >&2; fi''')
        self.fake_tool("lipo", "echo arm64")

    def package(self, tag):
        result = self.run_script("package-release.sh", tag)
        self.assertEqual(result.returncode, 0, result.stderr)
        return self.root / "build/releases" / tag

    def zipped_info(self, archive):
        with zipfile.ZipFile(archive) as zipped:
            return plistlib.loads(zipped.read("Muxify.app/Contents/Info.plist"))

    def assert_refused_before_building(self, tag, message):
        result = self.run_script("package-release.sh", tag)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(message, result.stderr)
        self.assertFalse((self.root / "xcode-args.txt").exists())
        self.assertFalse((self.root / "build/releases").exists())

    def test_package_archives_release_and_checksum_without_installing(self):
        self.package_fixture()
        dist = self.package("v1.2.3")
        archive = dist / "Muxify-1.2.3-arm64.zip"
        self.assertTrue(archive.is_file())
        subprocess.run(["shasum", "-a", "256", "-c", "SHA256SUMS"], cwd=dist, check=True, capture_output=True)
        with zipfile.ZipFile(archive) as zipped:
            executable = zipped.getinfo("Muxify.app/Contents/MacOS/MuxifyApp")
            self.assertTrue((executable.external_attr >> 16) & 0o111)
            link = zipped.getinfo("Muxify.app/Contents/Resources/notice-link")
            self.assertEqual((link.external_attr >> 16) & 0o170000, 0o120000)
        args = (self.root / "xcode-args.txt").read_text()
        self.assertIn("MARKETING_VERSION=1.2.3\n", args)
        self.assertIn("CURRENT_PROJECT_VERSION=1234\n", args)
        metadata = json.loads((dist / "build-info.json").read_text())
        self.assertEqual(metadata["tag"], "v1.2.3")
        self.assertEqual(metadata["kind"], "release")
        self.assertEqual(metadata["build"], "1234")
        self.assertEqual(metadata["short_version"], "1.2.3")
        self.assertEqual(metadata["signing"], "Muxify Release Signing")
        self.assertEqual(metadata["commit"], "abcdef1234567890abcdef1234567890abcdef12")
        self.assertFalse(metadata["source_dirty"])
        self.assertFalse(metadata["notarized"])

    def test_package_keeps_a_beta_tag_as_the_short_version(self):
        self.package_fixture()
        dist = self.package("v1.2.3-beta.4")
        self.assertTrue((dist / "Muxify-1.2.3-beta.4-arm64.zip").is_file())
        self.assertIn("MARKETING_VERSION=1.2.3-beta.4\n", (self.root / "xcode-args.txt").read_text())
        self.assertEqual(json.loads((dist / "build-info.json").read_text())["short_version"], "1.2.3-beta.4")

    def test_package_names_a_tip_build_by_its_short_sha(self):
        self.package_fixture()
        dist = self.package("tip")
        self.assertEqual([path.name for path in dist.glob("*.zip")], ["Muxify-tip-abcdef1-arm64.zip"])
        args = (self.root / "xcode-args.txt").read_text()
        self.assertIn("MARKETING_VERSION=abcdef1\n", args)
        self.assertIn("CURRENT_PROJECT_VERSION=1234\n", args)
        metadata = json.loads((dist / "build-info.json").read_text())
        self.assertEqual((metadata["tag"], metadata["kind"], metadata["short_version"]), ("tip", "tip", "abcdef1"))
        self.assertIn("# Muxify tip build abcdef1", (dist / "RELEASE-NOTES.md").read_text())

    def test_build_number_is_the_commit_count_whatever_build_number_says(self):
        self.package_fixture()
        self.env["BUILD_NUMBER"] = "42"
        self.env["FAKE_COUNT"] = "987"
        dist = self.package("tip")
        self.assertIn("CURRENT_PROJECT_VERSION=987\n", (self.root / "xcode-args.txt").read_text())
        self.assertEqual(json.loads((dist / "build-info.json").read_text())["build"], "987")

    def test_package_refuses_a_shallow_checkout_before_building(self):
        self.package_fixture()
        self.env["FAKE_SHALLOW"] = "true"
        self.assert_refused_before_building("v1.2.3", "full-depth checkout")

    def test_package_stamps_the_feed_and_public_key_into_the_packaged_copy_only(self):
        self.package_fixture()
        dist = self.package("v1.2.3")
        info = self.zipped_info(dist / "Muxify-1.2.3-arm64.zip")
        self.assertEqual(info["MuxifyUpdateFeedBaseURL"], self.FEED_BASE_URL)
        self.assertEqual(info["SUPublicEDKey"], self.PUBLIC_KEY)
        # make install builds this same product, so it must stay without the stamps.
        built = plistlib.loads((self.root / self.BUILT_APP / "Contents/Info.plist").read_bytes())
        self.assertNotIn("MuxifyUpdateFeedBaseURL", built)
        self.assertNotIn("SUPublicEDKey", built)

    def test_debug_and_install_builds_carry_no_update_stamps(self):
        for name in ["project.yml", "Makefile"]:
            text = (ROOT / name).read_text()
            with self.subTest(name=name):
                self.assertNotIn("SUPublicEDKey", text)
                self.assertNotIn("MuxifyUpdateFeedBaseURL", text)

    def test_package_refuses_an_empty_or_malformed_public_key_before_building(self):
        self.package_fixture()
        shutil.copy(ROOT / "scripts/sparkle-public-key.env", self.root / "scripts/sparkle-public-key.env")
        self.assert_refused_before_building("tip", "holds no SPARKLE_PUBLIC_ED_KEY")
        self.write("scripts/sparkle-public-key.env", "SPARKLE_PUBLIC_ED_KEY='key</string>'\n")
        self.assert_refused_before_building("tip", "not a base64 Ed25519 public key")

    def test_committed_public_key_file_is_empty_until_the_secrets_script_fills_it(self):
        text = (ROOT / "scripts/sparkle-public-key.env").read_text()
        self.assertIn("\nSPARKLE_PUBLIC_ED_KEY=", "\n" + text)
        self.assertIn("secrets script fills it", text)

    def test_package_signs_with_the_named_identity_from_the_named_keychain(self):
        self.package_fixture()
        self.package("v1.2.3")
        calls = (self.root / "codesign-args.txt").read_text().splitlines()
        sign = [call for call in calls if call.startswith("--force --sign")]
        self.assertEqual(len(sign), 1)
        # The exact name, not the first identity whose name starts with it.
        self.assertIn(f"--sign {self.IDENTITY_HASH[::-1]} --keychain {self.keychain} ", sign[0])
        self.assertTrue(sign[0].endswith("build/package/Muxify.app"))
        self.assertNotIn("--sign -", "\n".join(calls))

    def test_package_without_a_signing_identity_fails_naming_it(self):
        self.package_fixture()
        for tag in ["tip", "v1.2.3", "v1.2.3-beta.1"]:
            with self.subTest(tag=tag):
                self.env.pop("MUXIFY_RELEASE_IDENTITY")
                self.assert_refused_before_building(tag, "MUXIFY_RELEASE_IDENTITY")
                self.env["MUXIFY_RELEASE_IDENTITY"] = "Muxify Release Signing"
        self.env.pop("MUXIFY_RELEASE_KEYCHAIN")
        self.assert_refused_before_building("tip", "MUXIFY_RELEASE_KEYCHAIN")
        self.env["MUXIFY_RELEASE_KEYCHAIN"] = str(self.keychain)
        self.env["MUXIFY_RELEASE_IDENTITY"] = "Muxify Missing Signing"
        self.assert_refused_before_building("tip", 'holds no "Muxify Missing Signing" signing identity')

    def test_package_stops_when_the_app_is_signed_by_another_identity(self):
        self.package_fixture()
        self.fake_tool("codesign", 'if [ "$1" = -dvv ]; then echo "Signature=adhoc" >&2; fi')
        result = self.run_script("package-release.sh", "v1.2.3")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('not signed by "Muxify Release Signing"', result.stderr)
        self.assertFalse(any((self.root / "build/releases").rglob("*.zip")))

    def test_release_notes_say_muxify_updates_itself(self):
        self.package_fixture()
        notes = " ".join((self.package("v1.2.3") / "RELEASE-NOTES.md").read_text().split())
        self.assertIn("# Muxify 1.2.3", notes)
        self.assertIn("Muxify updates itself", notes)
        self.assertIn("Move `Muxify.app` to `/Applications` before you open it", notes)
        self.assertIn("Only the first install needs this", notes)
        self.assertIn("Until Muxify has a Developer ID", notes)
        self.assertIn("Open Anyway", notes)

    def test_package_stops_when_signature_verification_fails(self):
        self.package_fixture()
        self.fake_tool("codesign", "exit 1")
        result = self.run_script("package-release.sh", "v0.1.0-beta.1")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(any((self.root / "build/releases").rglob("*.zip")))

    def test_signature_check_consumes_all_codesign_output(self):
        self.package_fixture()
        self.fake_tool("codesign", '''
if [ "$1" = -dvv ]; then echo "Authority=Muxify Release Signing" >&2; printf "%262144s\\n" diagnostics >&2; fi''')
        result = self.run_script("package-release.sh", "v0.1.0-beta.1")
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_collects_notices_and_font_mapping_in_stable_order(self):
        self.write("source/LICENSE", "MIT license\n")
        self.write("source/nested/COPYING.txt", "BSD license\n")
        self.write("source/src/font/res/README.md", "Font attribution\n")
        self.write("source/src/font/res/BSD-2-Clause.txt", "Font license\n")
        self.write("source/.git/LICENSE", "Should not appear\n")
        self.write("source/.zig-cache/LICENSE", "Should not appear\n")
        self.write("source/README.md", "Not a license\n")
        text = NOTICES.collect([("Upstream", self.root / "source")])
        self.assertEqual(text, NOTICES.collect([("Upstream", self.root / "source")]))
        for expected in ["MIT license", "BSD license", "Font attribution", "Font license", "Upstream/nested/COPYING.txt"]:
            self.assertIn(expected, text)
        self.assertNotIn("Should not appear", text)
        self.assertNotIn("Not a license", text)
        self.assertNotIn(str(self.root), text)

    def test_notice_collector_rejects_missing_or_empty_sources(self):
        with self.assertRaises(ValueError):
            NOTICES.collect([("Upstream", self.root / "missing")])
        (self.root / "empty").mkdir()
        with self.assertRaises(ValueError):
            NOTICES.collect([("Upstream", self.root / "empty")])

    def test_collects_licenses_from_zig_016_package_archives(self):
        packages = self.root / "packages"
        packages.mkdir()
        tar = io.BytesIO()
        with tarfile.open(fileobj=tar, mode="w") as archive:
            for name, text in [("LICENSE", "Archive license"), ("README.md", "Not a license"), ("../LICENSE", "Unsafe path")]:
                member = tarfile.TarInfo(name)
                content = text.encode()
                member.size = len(content)
                archive.addfile(member, io.BytesIO(content))
            end = archive.offset
        # Like Zig's archives, end without the end-of-archive blocks.
        (packages / "package-hash.tar.gz").write_bytes(gzip.compress(tar.getvalue()[:end]))
        text = NOTICES.collect([("Dependencies", packages)])
        self.assertIn("Dependencies/package-hash.tar.gz/LICENSE", text)
        self.assertIn("Archive license", text)
        self.assertNotIn("Not a license", text)
        self.assertNotIn("Unsafe path", text)
        self.assertFalse((packages / "LICENSE").exists())

    def test_bundle_requires_resources_instead_of_ghostty_app(self):
        self.env["TARGET_BUILD_DIR"] = str(self.root / "products")
        self.env["UNLOCALIZED_RESOURCES_FOLDER_PATH"] = "Muxify.app/Contents/Resources"
        result = self.run_script("bundle-ghostty-resources.sh")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Ghostty resources missing", result.stderr)

    def test_bundle_copies_matching_resources_and_notices(self):
        self.bundle_fixture()
        result = self.run_script("bundle-ghostty-resources.sh")
        self.assertEqual(result.returncode, 0, result.stderr)
        resources = self.root / "products/Muxify.app/Contents/Resources"
        self.assertTrue((resources / "ghostty/shell-integration/zsh/.zshenv").is_file())
        self.assertEqual((resources / "ThirdPartyNotices/Ghostty.txt").read_text(), "Ghostty license\n")
        self.assertIn("Yams license", (resources / "ThirdPartyNotices/Yams.txt").read_text())

    def test_bundle_rejects_missing_themes_or_shell_integration(self):
        self.bundle_fixture()
        path = self.root / "vendor/ghostty/resources/ghostty/shell-integration/zsh/ghostty-integration"
        path.unlink()
        result = self.run_script("bundle-ghostty-resources.sh")
        self.assertNotEqual(result.returncode, 0)

    def test_package_rejects_invalid_tags_before_building(self):
        self.package_fixture()
        for tag in ["", "tips", "v0.1", "0.1.0", "v0.1.0-beta.0", "v01.1.0", "v01.1.0-beta.1", "v0.1.0-rc.1",
                    "v0.1.0-beta.1/other", "v0.1.0;echo bad", "tip;echo bad"]:
            with self.subTest(tag=tag):
                self.assert_refused_before_building(tag, "Usage:")

    def test_package_rejects_non_arm64_host(self):
        self.fake_tool("uname", "echo x86_64")
        result = self.run_script("package-release.sh", "v0.1.0-beta.1")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Apple-silicon", result.stderr)

    def test_package_rejects_unpinned_development_build(self):
        self.package_fixture()
        self.write("vendor/ghostty/build-info.json", json.dumps({"commit": "unknown", "zig": "unknown", "arch": "arm64"}))
        result = self.run_script("package-release.sh", "v0.1.0-beta.1")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("pinned Ghostty build", result.stderr)

    def test_package_rejects_modified_ghostty_source(self):
        self.package_fixture()
        metadata_path = self.root / "vendor/ghostty/build-info.json"
        metadata = json.loads(metadata_path.read_text())
        metadata["dirty"] = True
        metadata_path.write_text(json.dumps(metadata))
        result = self.run_script("package-release.sh", "v0.1.0-beta.1")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("pinned Ghostty build", result.stderr)

    def test_prebuilt_override_requires_matching_resources(self):
        self.env["GHOSTTYKIT"] = str(self.root / "GhosttyKit.xcframework")
        result = self.run_script("setup-ghostty.sh")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("GHOSTTY_RESOURCES", result.stderr)

    def test_setup_verifies_library_with_xcode_26_lipo_argument_order(self):
        framework = "GhosttyKit.xcframework/macos-arm64"
        self.write(f"{framework}/libghostty-internal.a", "Library fixture\n")
        self.write(f"{framework}/Headers/ghostty.h", "Header fixture\n")
        for relative in [
            "terminfo/78/xterm-ghostty",
            "ghostty/themes/Example",
            "ghostty/shell-integration/zsh/ghostty-integration",
        ]:
            self.write(f"resources/{relative}", "Resource fixture\n")
        self.write("upstream-notices.txt", "License fixture\n")
        self.env["GHOSTTYKIT"] = str(self.root / "GhosttyKit.xcframework")
        self.env["GHOSTTY_RESOURCES"] = str(self.root / "resources")
        self.env["GHOSTTY_NOTICES"] = str(self.root / "upstream-notices.txt")
        self.env["ARCH"] = "arm64"
        self.fake_tool("lipo", '''
if [ "$1" = -info ]; then
  echo "Non-fat file: $2 is architecture: arm64"
elif [ "$#" = 3 ] && [ "$2" = -verify_arch ] && [ "$3" = arm64 ]; then
  test -f "$1"
else
  echo "Input file must precede -verify_arch and its architecture arguments" >&2
  exit 1
fi
''')
        result = self.run_script("setup-ghostty.sh")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue((self.root / "vendor/ghostty/include/ghostty.h").is_file())
        self.assertTrue((self.root / "vendor/ghostty/resources/terminfo/78/xterm-ghostty").is_file())
        self.assertTrue((self.root / "vendor/ghostty/build-info.json").is_file())

    def test_failed_ghostty_build_cannot_be_masked_by_command_substitution(self):
        source = self.root / "source"
        self.write("source/build.zig.zon", '.{ .minimum_zig_version = "0.16.0", }\n')
        self.fake_tool("zig", 'if [ "$1" = version ]; then echo 0.16.0; else exit 17; fi')
        self.fake_tool("xcrun", "exit 0")
        self.env["GHOSTTY_SRC"] = str(source)
        self.env["ZIG"] = str(self.root / "tools/zig")
        result = self.run_script("setup-ghostty.sh")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.root / "vendor/ghostty/build-info.json").exists())


if __name__ == "__main__":
    unittest.main()
