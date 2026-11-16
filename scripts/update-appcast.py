#!/usr/bin/env python3
"""Adds one release to the Sparkle appcast, creating the file if needed.

Called by .github/workflows/release.yml. Stable and beta releases share one
feed. Beta items carry <sparkle:channel>beta</sparkle:channel>, which hides
them from everyone who has not turned on beta updates in the app.
"""
import argparse
import email.utils
import os
import xml.etree.ElementTree as ET

SPARKLE = "http://www.andymatuschak.org/xml-namespaces/sparkle"
ET.register_namespace("sparkle", SPARKLE)


def sparkle(tag):
    return f"{{{SPARKLE}}}{tag}"


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--appcast", required=True)
    parser.add_argument("--version", required=True, help="CFBundleShortVersionString, e.g. 0.3.0-beta.2")
    parser.add_argument("--build", required=True, help="CFBundleVersion, which Sparkle compares")
    parser.add_argument("--url", required=True)
    parser.add_argument("--length", required=True)
    parser.add_argument("--signature", required=True)
    parser.add_argument("--minimum-system-version", required=True)
    parser.add_argument("--channel", help="omit for stable releases")
    parser.add_argument("--release-notes-html", help="file with the release notes as HTML")
    args = parser.parse_args()

    if os.path.exists(args.appcast):
        tree = ET.parse(args.appcast)
        channel = tree.getroot().find("channel")
    else:
        rss = ET.Element("rss", {"version": "2.0"})
        channel = ET.SubElement(rss, "channel")
        ET.SubElement(channel, "title").text = "Archipel"
        tree = ET.ElementTree(rss)

    # A re-run of the same release replaces its item instead of listing the version twice.
    for item in channel.findall("item"):
        if item.findtext(sparkle("version")) == args.build:
            channel.remove(item)

    item = ET.Element("item")
    ET.SubElement(item, "title").text = args.version
    ET.SubElement(item, "pubDate").text = email.utils.formatdate(usegmt=True)
    ET.SubElement(item, sparkle("version")).text = args.build
    ET.SubElement(item, sparkle("shortVersionString")).text = args.version
    ET.SubElement(item, sparkle("minimumSystemVersion")).text = args.minimum_system_version
    if args.channel:
        ET.SubElement(item, sparkle("channel")).text = args.channel
    if args.release_notes_html:
        with open(args.release_notes_html, encoding="utf-8") as f:
            notes = f.read().strip()
        if notes:
            ET.SubElement(item, "description").text = notes
    ET.SubElement(item, "enclosure", {
        "url": args.url,
        "length": args.length,
        "type": "application/octet-stream",
        sparkle("edSignature"): args.signature,
    })

    # Newest first, after the channel's own title.
    first_item = next((i for i, child in enumerate(channel) if child.tag == "item"), len(channel))
    channel.insert(first_item, item)

    ET.indent(tree, space="  ")
    tree.write(args.appcast, encoding="utf-8", xml_declaration=True)


if __name__ == "__main__":
    main()
