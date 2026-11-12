import base64
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
import xml.etree.ElementTree as ET
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
                     "ghostty-version.env", "sparkle-public-key.env", "stamp-debug-update-key.sh",
                     "sparkle-debug-public-key.env"]:
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

    def write_unfilled_public_key_file(self):
        # The committed key file with its key left out, as it was before the secrets script filled it.
        lines = (ROOT / "scripts/sparkle-public-key.env").read_text().splitlines(keepends=True)
        return self.write("scripts/sparkle-public-key.env", "".join(
            "SPARKLE_PUBLIC_ED_KEY=\n" if line.startswith("SPARKLE_PUBLIC_ED_KEY=") else line for line in lines))

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
        self.write("build/SourcePackages/checkouts/Sparkle/LICENSE", "Sparkle license\n")
        self.write("build/SourcePackages/checkouts/Sparkle/Vendor/ed25519-sparkle/license.txt", "ed25519 license\n")
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
        for name in ["Ghostty", "Yams", "libyaml", "Sparkle"]:
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

    def test_package_passes_extra_build_settings_only_when_asked(self):
        self.package_fixture()
        self.env.pop("XCODEBUILD_EXTRA_SETTINGS", None)
        self.package("tip")
        self.assertNotIn("COMPILATION_CACHE_ENABLE_CACHING", (self.root / "xcode-args.txt").read_text())
        self.env["XCODEBUILD_EXTRA_SETTINGS"] = "COMPILATION_CACHE_ENABLE_CACHING=YES ONLY_ACTIVE_ARCH=YES"
        self.package("tip")
        args = (self.root / "xcode-args.txt").read_text()
        self.assertIn("COMPILATION_CACHE_ENABLE_CACHING=YES\nONLY_ACTIVE_ARCH=YES\n-quiet\nbuild\n", args)

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

    def stamp_fixture(self, configuration):
        plist = self.root / "products/Muxify.app/Contents/Info.plist"
        plist.parent.mkdir(parents=True)
        plist.write_bytes(plistlib.dumps({"CFBundleIdentifier": "dev.muxify.shell"}))
        self.env.update(CONFIGURATION=configuration, TARGET_BUILD_DIR=str(self.root / "products"),
                        INFOPLIST_PATH="Muxify.app/Contents/Info.plist")
        result = self.run_script("stamp-debug-update-key.sh")
        self.assertEqual(result.returncode, 0, result.stderr)
        return plistlib.loads(plist.read_bytes())

    def test_a_debug_build_carries_the_test_key_and_no_feed(self):
        info = self.stamp_fixture("Debug")
        pins = dict(line.split("=", 1) for line in (ROOT / "scripts/sparkle-debug-public-key.env").read_text().splitlines()
                    if line and not line.startswith("#"))
        self.assertEqual(info["SUPublicEDKey"], pins["SPARKLE_DEBUG_PUBLIC_ED_KEY"])
        self.assertNotIn("MuxifyUpdateFeedBaseURL", info)
        # The release key file is another key: the test key's private half is committed with the verify fixtures.
        release = (ROOT / "scripts/sparkle-public-key.env").read_text()
        self.assertNotIn(pins["SPARKLE_DEBUG_PUBLIC_ED_KEY"], release)
        self.assertTrue((ROOT / "scripts/verify/fixtures/sparkle-test-ed-key").is_file())

    def test_a_release_build_gets_no_test_key(self):
        self.assertNotIn("SUPublicEDKey", self.stamp_fixture("Release"))

    def test_package_requires_the_sparkle_notice(self):
        self.package_fixture()
        (self.root / self.BUILT_APP / "Contents/Resources/ThirdPartyNotices/Sparkle.txt").unlink()
        result = self.run_script("package-release.sh", "v1.2.3")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Missing bundled license notices: Sparkle", result.stderr)

    def test_package_refuses_an_empty_or_malformed_public_key_before_building(self):
        self.package_fixture()
        self.write_unfilled_public_key_file()
        self.assert_refused_before_building("tip", "holds no SPARKLE_PUBLIC_ED_KEY")
        self.write("scripts/sparkle-public-key.env", "SPARKLE_PUBLIC_ED_KEY='key</string>'\n")
        self.assert_refused_before_building("tip", "not a base64 Ed25519 public key")

    def test_committed_public_key_file_has_the_key_line_and_names_the_secrets_script(self):
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

    ED_PRIVATE_KEY = "c2VjcmV0LWVkZHNhLXNlZWQtb2YtdGhpcy10ZXN0LW9ubHk="
    SIGNATURE = "c2lnbmF0dXJl" * 7 + "c2lnbmF0dXJlIQ=="
    SPARKLE_NS = "{http://www.andymatuschak.org/xml-namespaces/sparkle}"

    def feed_fixture(self):
        shutil.copy(ROOT / "scripts/write-feed.py", self.root / "scripts/write-feed.py")
        shutil.copy(ROOT / "scripts/sparkle-version.env", self.root / "scripts/sparkle-version.env")
        self.zip = self.write("dist/Muxify-tip-abcdef1-arm64.zip", "zip fixture\n")
        # Records what sign_update got, and prints its signing line as the real one does.
        self.fake_tool("sign_update", f'''
printf "%s\\n" "$@" > sign-update-args.txt
env > sign-update-env.txt
cat > sign-update-stdin.txt
echo "sparkle:edSignature=\\"{self.SIGNATURE}\\" length=\\"$(wc -c < "${{@: -1}}" | tr -d " ")\\""''')

    def write_feed(self, channel="tip", version="abcdef1", **overrides):
        options = {
            "channel": channel, "zip": str(self.zip), "build": "1234", "version": version,
            "date": "2026-11-11T09:30:00Z",
            "download-url": "https://github.com/muxify-dev/muxify/releases/download/tip/Muxify-tip-abcdef1-arm64.zip",
            "notes-url": "https://github.com/muxify-dev/muxify/commit/abcdef1234567890abcdef1234567890abcdef12",
            "output": str(self.root / "feeds/tip.xml"),
        }
        options.update(overrides)
        args = [part for name, value in options.items() for part in (f"--{name}", value)]
        return subprocess.run(
            ["python3", str(self.root / "scripts/write-feed.py"), *args],
            env=self.env, text=True, capture_output=True, input=self.ED_PRIVATE_KEY + "\n", cwd=self.root,
        )

    def feed_item(self, path="feeds/tip.xml"):
        channel = ET.parse(self.root / path).getroot().find("channel")
        items = channel.findall("item")
        self.assertEqual(len(items), 1)
        return items[0]

    def test_feed_writes_one_item_with_its_versions_signature_and_links(self):
        self.feed_fixture()
        result = self.write_feed()
        self.assertEqual(result.returncode, 0, result.stderr)
        item = self.feed_item()
        s = self.SPARKLE_NS
        self.assertEqual(item.findtext(f"{s}version"), "1234")
        self.assertEqual(item.findtext(f"{s}minimumSystemVersion"), "14.0")
        self.assertEqual(item.findtext("pubDate"), "Wed, 11 Nov 2026 09:30:00 +0000")
        self.assertEqual(item.findtext("link"),
                         "https://github.com/muxify-dev/muxify/commit/abcdef1234567890abcdef1234567890abcdef12")
        enclosure = item.find("enclosure")
        self.assertEqual(enclosure.get("url"),
                         "https://github.com/muxify-dev/muxify/releases/download/tip/Muxify-tip-abcdef1-arm64.zip")
        self.assertEqual(enclosure.get(f"{s}edSignature"), self.SIGNATURE)
        self.assertEqual(enclosure.get("length"), str(self.zip.stat().st_size))
        # No delta, phased rollout, critical update, major upgrade, or release notes that Sparkle would download.
        self.assertEqual(
            sorted(child.tag for child in item),
            sorted(["title", "pubDate", f"{s}version", f"{s}shortVersionString", f"{s}minimumSystemVersion",
                    "link", "enclosure"]),
        )
        self.assertEqual(sorted(enclosure.attrib), sorted(["url", "type", f"{s}edSignature", "length"]))
        text = (self.root / "feeds/tip.xml").read_text()
        for absent in ["deltas", "phasedRollout", "criticalUpdate", "majorUpgrade", "releaseNotesLink"]:
            self.assertNotIn(absent, text)

    def test_feed_display_version_is_sha_and_date_for_a_tip_build_and_the_version_for_a_release(self):
        self.feed_fixture()
        self.assertEqual(self.write_feed(date="2026-11-11T23:30:00-02:00").returncode, 0)
        # The date is the UTC day of the publish time.
        self.assertEqual(self.feed_item().findtext(f"{self.SPARKLE_NS}shortVersionString"), "abcdef1 (2026-11-12)")
        result = self.write_feed(
            channel="stable", version="1.2.3-beta.4", output=str(self.root / "feeds/stable.xml"),
            **{"notes-url": "https://github.com/muxify-dev/muxify/releases/tag/v1.2.3-beta.4"},
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        item = self.feed_item("feeds/stable.xml")
        self.assertEqual(item.findtext(f"{self.SPARKLE_NS}shortVersionString"), "1.2.3-beta.4")
        self.assertEqual(item.findtext("link"), "https://github.com/muxify-dev/muxify/releases/tag/v1.2.3-beta.4")

    def test_feed_escapes_its_text(self):
        self.feed_fixture()
        url = "https://example.com/download?a=1&b=\"<2>\""
        result = self.write_feed(channel="stable", version="1.2.3 & <beta>",
                                 **{"download-url": url, "notes-url": "https://example.com/notes?x=<y>&z"})
        self.assertEqual(result.returncode, 0, result.stderr)
        item = self.feed_item()
        self.assertEqual(item.findtext(f"{self.SPARKLE_NS}shortVersionString"), "1.2.3 & <beta>")
        self.assertEqual(item.findtext("link"), "https://example.com/notes?x=<y>&z")
        self.assertEqual(item.find("enclosure").get("url"), url)
        text = (self.root / "feeds/tip.xml").read_text()
        self.assertIn("1.2.3 &amp; &lt;beta&gt;", text)
        self.assertNotIn("<beta>", text)

    def test_feed_gives_the_eddsa_key_to_sign_update_only_on_standard_input(self):
        self.feed_fixture()
        self.assertEqual(self.write_feed().returncode, 0)
        args = (self.root / "sign-update-args.txt").read_text().splitlines()
        self.assertEqual(args, ["--ed-key-file", "-", str(self.zip)])
        self.assertEqual((self.root / "sign-update-stdin.txt").read_text().strip(), self.ED_PRIVATE_KEY)
        self.assertNotIn(self.ED_PRIVATE_KEY, (self.root / "sign-update-env.txt").read_text())
        self.assertNotIn(self.ED_PRIVATE_KEY, (self.root / "feeds/tip.xml").read_text())

    def test_a_failing_sign_update_writes_no_feed(self):
        self.feed_fixture()
        old = self.write("feeds/tip.xml", "previous feed\n")
        for name, script in [
            ("exit status", 'cat >/dev/null; echo "ERROR! Unable to read EdDSA private key" >&2; exit 1'),
            # sign_update prints some errors on standard output and exits 0.
            ("error output", 'cat >/dev/null; echo "ERROR! Imported key must be 64 bytes or 96 bytes"'),
        ]:
            with self.subTest(name):
                self.fake_tool("sign_update", script)
                result = self.write_feed()
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("sign_update", result.stderr)
                self.assertEqual(old.read_text(), "previous feed\n")
                self.assertEqual(sorted(path.name for path in old.parent.iterdir()), ["tip.xml"])

    def test_feed_refuses_bad_arguments_before_signing(self):
        self.feed_fixture()
        for overrides in [{"build": "0"}, {"build": "12a"}, {"version": "v1.2.3"}, {"date": "2026-11-11T09:30:00"},
                          {"date": "yesterday"}, {"zip": str(self.root / "missing.zip")},
                          {"download-url": "file:///tmp/Muxify.zip"}]:
            with self.subTest(overrides=overrides):
                result = self.write_feed(**overrides)
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse((self.root / "sign-update-args.txt").exists())
                self.assertFalse((self.root / "feeds/tip.xml").exists())

    GENERATED_PUBLIC_KEY = "B" * 42 + "c="

    def secrets_fixture(self):
        shutil.copy(ROOT / "scripts/make-release-secrets.sh", self.root / "scripts/make-release-secrets.sh")
        self.write_unfilled_public_key_file()
        (self.root / "tmp").mkdir()
        self.env["TMPDIR"] = str(self.root / "tmp")
        self.fake_tool("generate_keys", f'''
printf "%s\\n" "$*" >> "{self.root}/generate-keys-args.txt"
[ "$1 $2" = "--account muxify-release" ] || exit 1
case "$3" in
  -p) echo "{self.GENERATED_PUBLIC_KEY}" ;;
  -x) [ ! -e "$4" ] && echo "{self.ED_PRIVATE_KEY}" > "$4" ;;
  "") echo "Generating a new signing key." ;;
  *) exit 1 ;;
esac''')
        for tool in ["gh", "security"]:
            self.fake_tool(tool, f'printf "%s\\n" "$*" >> "{self.root}/{tool}-args.txt"')

    def make_secrets(self, *args):
        result = self.run_script("make-release-secrets.sh", *args)
        self.assertEqual(result.returncode, 0, result.stderr)
        folders = list((self.root / "tmp").iterdir())
        self.assertEqual(len(folders), 1)
        return result.stdout, folders[0]

    def test_secrets_script_makes_the_certificate_and_eddsa_key_and_prints_the_commands(self):
        self.secrets_fixture()
        output, folder = self.make_secrets()
        self.assertIn(f"The release secrets are in {folder.resolve()}", output)
        self.assertEqual(folder.stat().st_mode & 0o777, 0o700)
        # The .p12 opens with its password and holds the code-signing certificate and its key.
        password = (folder / "muxify-release-signing.p12.password").read_text()
        p12 = self.root / "identity.p12"
        p12.write_bytes(base64.b64decode((folder / "muxify-release-signing.p12.base64").read_text()))
        opened = subprocess.run(["/usr/bin/openssl", "pkcs12", "-in", str(p12), "-passin", f"pass:{password}",
                                 "-nodes"], capture_output=True, text=True, check=True).stdout
        self.assertIn("PRIVATE KEY", opened)
        certificate = subprocess.run(["/usr/bin/openssl", "x509", "-noout", "-subject", "-text"], input=opened,
                                     capture_output=True, text=True, check=True).stdout
        self.assertIn("Muxify Release Signing", certificate)
        self.assertIn("Code Signing", certificate)
        # The .p12 is the only copy of the certificate's key.
        self.assertEqual(sorted(path.name for path in folder.iterdir()), [
            "muxify-release-signing.cert.pem", "muxify-release-signing.p12.base64",
            "muxify-release-signing.p12.password", "sparkle-ed-private-key",
        ])
        self.assertNotIn(password, output)
        # The EdDSA pair is made under the account, and the private key exported to the folder.
        self.assertEqual((folder / "sparkle-ed-private-key").read_text().strip(), self.ED_PRIVATE_KEY)
        exported = folder.resolve() / "sparkle-ed-private-key"
        self.assertEqual((self.root / "generate-keys-args.txt").read_text().splitlines(), [
            "--account muxify-release",
            "--account muxify-release -p",
            f"--account muxify-release -x {exported}",
        ])
        self.assertNotIn(self.ED_PRIVATE_KEY, output)
        key_file = (self.root / "scripts/sparkle-public-key.env").read_text()
        self.assertIn(f"\nSPARKLE_PUBLIC_ED_KEY={self.GENERATED_PUBLIC_KEY}\n", "\n" + key_file)
        self.assertIn("secrets script fills it", key_file)
        for secret, file in [("SPARKLE_ED_PRIVATE_KEY", "sparkle-ed-private-key"),
                             ("MUXIFY_RELEASE_CERTIFICATE_P12", "muxify-release-signing.p12.base64"),
                             ("MUXIFY_RELEASE_CERTIFICATE_PASSWORD", "muxify-release-signing.p12.password")]:
            self.assertIn(f'gh secret set {secret} --repo muxify-dev/muxify < "{folder.resolve()}/{file}"', output)
        self.assertIn("back up the EdDSA private key", output)
        self.assertIn("Losing the private key ends every update", output)
        # It sets no secret and touches no keychain itself.
        self.assertFalse((self.root / "gh-args.txt").exists())
        self.assertFalse((self.root / "security-args.txt").exists())

    def test_secrets_script_refuses_to_replace_a_public_key_unless_forced(self):
        self.secrets_fixture()
        self.write("scripts/sparkle-public-key.env", f"# Comment\nSPARKLE_PUBLIC_ED_KEY={self.PUBLIC_KEY}\n")
        result = self.run_script("make-release-secrets.sh")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("--force", result.stderr)
        self.assertEqual((self.root / "scripts/sparkle-public-key.env").read_text(),
                         f"# Comment\nSPARKLE_PUBLIC_ED_KEY={self.PUBLIC_KEY}\n")
        self.assertFalse((self.root / "generate-keys-args.txt").exists())
        self.assertEqual(list((self.root / "tmp").iterdir()), [])
        self.make_secrets("--force")
        self.assertEqual((self.root / "scripts/sparkle-public-key.env").read_text(),
                         f"# Comment\nSPARKLE_PUBLIC_ED_KEY={self.GENERATED_PUBLIC_KEY}\n")

    def test_secrets_script_stops_on_a_bad_public_key(self):
        self.secrets_fixture()
        unfilled = (self.root / "scripts/sparkle-public-key.env").read_text()
        self.fake_tool("generate_keys", 'if [ "$3" = -p ]; then echo "ERROR: No existing signing key found!"; fi')
        result = self.run_script("make-release-secrets.sh")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("no base64 Ed25519 public key", result.stderr)
        self.assertEqual((self.root / "scripts/sparkle-public-key.env").read_text(), unfilled)

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
        sparkle = (resources / "ThirdPartyNotices/Sparkle.txt").read_text()
        self.assertIn("Sparkle license", sparkle)
        self.assertIn("ed25519 license", sparkle)

    def test_bundle_requires_the_sparkle_checkout(self):
        self.bundle_fixture()
        shutil.rmtree(self.root / "build/SourcePackages/checkouts/Sparkle")
        result = self.run_script("bundle-ghostty-resources.sh")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Sparkle", result.stderr)

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
