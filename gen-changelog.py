#!/usr/bin/env python3
"""Generate release notes and CHANGELOG.md from git tags."""

import argparse
import subprocess


def git(*args):
    return subprocess.run(
        ["git", *args], capture_output=True, text=True, check=True
    ).stdout


def tag_section(tag, previous, build_type=None):
    code = git("rev-list", tag, "--count").strip()
    sha = git("rev-parse", "--short", tag).strip()
    build_type = build_type or ("prerelease" if "-" in tag else "release")
    lines = [f"## {tag} ({code}-{sha}-{build_type})"]
    revision_range = f"{previous}..{tag}" if previous else tag
    entries = git("log", "--format=%h%x1f%s%x1f%b%x1e", revision_range)

    for entry in entries.split("\x1e"):
        if not entry.strip():
            continue
        short_sha, subject, body = entry.rstrip("\n").split("\x1f", 2)
        lines.append(f"- {subject} ({short_sha})")
        for line in body.splitlines():
            line = line.strip()
            if line:
                lines.append(f"  - {line.removeprefix('- ').removeprefix('* ')}")
    return lines


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--tag")
    parser.add_argument("--build-type")
    parser.add_argument("--stable-only", action="store_true")
    parser.add_argument("--with-hotfix", action="store_true")
    parser.add_argument("--tags", type=int, default=4)
    args = parser.parse_args()

    tags = git("tag", "--sort=v:refname").split()
    if not tags:
        raise SystemExit("No git tags found")

    if args.stable_only:
        tags = [tag for tag in tags if "-" not in tag]
        if args.with_hotfix:
            tags = [tag for tag in git("tag", "--sort=v:refname").split()
                    if "-" not in tag or "-hotfix" in tag]

    if args.tag:
        if args.tag not in tags:
            raise SystemExit(f"Tag not found: {args.tag}")
        index = tags.index(args.tag)
        previous = tags[index - 1] if index else None
        print("\n".join(tag_section(args.tag, previous, args.build_type)))
        return

    print("# Changelog\n")
    for tag in reversed(tags[-args.tags:]):
        index = tags.index(tag)
        previous = tags[index - 1] if index else None
        build_type = "hotfix" if "-hotfix" in tag else None
        print("\n".join(tag_section(tag, previous, build_type)))
        print()


if __name__ == "__main__":
    main()
