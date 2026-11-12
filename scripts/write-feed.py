#!/usr/bin/env python3
"""Write a Sparkle appcast with exactly one item, for one zip of a Release or a Tip Build.

The EdDSA private key comes on this script's standard input and goes on to `sign_update --ed-key-file -`
the same way, so it never reaches an argument, the environment or a file. For example:

    printf '%s' "$SPARKLE_ED_PRIVATE_KEY" | scripts/write-feed.py --channel tip --zip Muxify-tip-a1b2c3d-arm64.zip \\
        --build 1234 --version a1b2c3d --date 2026-11-11T09:30:00Z \\
        --download-url https://github.com/muxify-dev/muxify/releases/download/tip/Muxify-tip-a1b2c3d-arm64.zip \\
        --notes-url https://github.com/muxify-dev/muxify/commit/<sha> --output tip.xml

A failing `sign_update` fails the script and writes no feed.
"""

import argparse
import os
import re
import shutil
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET
from datetime import datetime, timezone
from email.utils import format_datetime
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SPARKLE_NS = "http://www.andymatuschak.org/xml-namespaces/sparkle"
MINIMUM_SYSTEM_VERSION = "14.0"
SIGNATURE = re.compile(r'^sparkle:edSignature="([A-Za-z0-9+/]+={0,2})" length="([0-9]+)"$')


def fail(message):
    sys.exit(f"write-feed.py: {message}")


def sign_update_path():
    """sign_update on PATH, else the copy that `make sparkle` vendors."""
    found = shutil.which("sign_update")
    if found:
        return found
    pins = dict(
        line.split("=", 1) for line in (ROOT / "scripts/sparkle-version.env").read_text().splitlines()
        if line and not line.startswith("#")
    )
    vendored = ROOT / "vendor/sparkle" / pins["SPARKLE_VERSION"] / "bin/sign_update"
    if os.access(vendored, os.X_OK):
        return str(vendored)
    fail("sign_update is not on PATH and not in vendor/sparkle: run make sparkle first")


def parse_date(text):
    try:
        date = datetime.fromisoformat(text[:-1] + "+00:00" if text.endswith("Z") else text)
    except ValueError:
        date = None
    if date is None or date.tzinfo is None:
        fail(f"--date is not an ISO 8601 time with a time zone, such as 2026-11-11T09:30:00Z: {text!r}")
    return date.astimezone(timezone.utc)


def sign(zip_path):
    """Returns the zip's (edSignature, length) from sign_update, which reads the key on standard input."""
    result = subprocess.run(
        [sign_update_path(), "--ed-key-file", "-", str(zip_path)],
        stdin=sys.stdin, capture_output=True, text=True,
    )
    output = result.stdout.strip()
    if result.returncode != 0:
        fail(f"sign_update failed ({result.returncode}): {(result.stderr or output).strip()}")
    # sign_update reports some errors on standard output and still exits 0, so only its signature line passes.
    match = SIGNATURE.match(output)
    if not match:
        fail(f"sign_update printed no signature: {output or result.stderr.strip()}")
    return match.group(1), match.group(2)


def feed(args, date, signature, length):
    ET.register_namespace("sparkle", SPARKLE_NS)

    def sparkle(name):
        return f"{{{SPARKLE_NS}}}{name}"

    if args.channel == "tip":
        display = f"{args.version} ({date:%Y-%m-%d})"
        title = f"Muxify tip build {display}"
    else:
        display = args.version
        title = f"Muxify {display}"
    rss = ET.Element("rss", {"version": "2.0"})
    channel = ET.SubElement(rss, "channel")
    ET.SubElement(channel, "title").text = "Muxify Tip Builds" if args.channel == "tip" else "Muxify"
    item = ET.SubElement(channel, "item")
    ET.SubElement(item, "title").text = title
    ET.SubElement(item, "pubDate").text = format_datetime(date)
    ET.SubElement(item, sparkle("version")).text = args.build
    ET.SubElement(item, sparkle("shortVersionString")).text = display
    ET.SubElement(item, sparkle("minimumSystemVersion")).text = MINIMUM_SYSTEM_VERSION
    # Sparkle gives a user driver <link> as the item's infoURL. A sparkle:releaseNotesLink would instead make
    # Sparkle download that page as the notes body.
    ET.SubElement(item, "link").text = args.notes_url
    ET.SubElement(item, "enclosure", {
        "url": args.download_url,
        "type": "application/octet-stream",
        sparkle("edSignature"): signature,
        "length": length,
    })
    ET.indent(rss)
    return ET.tostring(rss, encoding="utf-8", xml_declaration=True) + b"\n"


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--channel", required=True, choices=["stable", "tip"])
    parser.add_argument("--zip", required=True, type=Path, help="the zip the item offers")
    parser.add_argument("--build", required=True, help="the build number, CFBundleVersion")
    parser.add_argument("--version", required=True,
                        help="the short version: a Release's version, or a Tip Build's short commit SHA")
    parser.add_argument("--date", required=True, help="the publish time, ISO 8601 with a time zone")
    parser.add_argument("--download-url", required=True)
    parser.add_argument("--notes-url", required=True,
                        help="a Release's release page, or a Tip Build's commit page")
    parser.add_argument("--output", required=True, type=Path, help="the feed file to write")
    args = parser.parse_args()

    if not re.fullmatch(r"[1-9][0-9]*", args.build):
        fail(f"--build is not a build number: {args.build!r}")
    if not args.version.strip():
        fail("--version is empty")
    if args.channel == "tip" and not re.fullmatch(r"[0-9a-f]{7,40}", args.version):
        fail(f"--version of a Tip Build is its short commit SHA, not {args.version!r}")
    for name in ["download_url", "notes_url"]:
        if not re.match(r"https?://", getattr(args, name)):
            fail(f"--{name.replace('_', '-')} is not an http(s) URL: {getattr(args, name)!r}")
    if not args.zip.is_file():
        fail(f"--zip {args.zip} does not exist")
    date = parse_date(args.date)

    signature, length = sign(args.zip)
    text = feed(args, date, signature, length)
    # Written whole, then renamed, so a reader never sees half a feed.
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(dir=args.output.parent, prefix=f".{args.output.name}.", delete=False) as temp:
        temp.write(text)
    os.chmod(temp.name, 0o644)
    os.replace(temp.name, args.output)
    print(f"Feed: {args.output}")


if __name__ == "__main__":
    main()
