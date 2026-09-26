#!/usr/bin/env python3
"""Build a runtime lexicon from a pinned SCOWL archive; never touch training data."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import tarfile

VERSION = "2020.12.07"
REVISION = "5ef55f9c42730ebe4394a78b77855468a6f15dd2"
SHA256 = "5587667caa20c4891390c2d42dbb4d5c4c3f41bee77af1457ece3ba23fb859cc"
URL = f"https://downloads.sourceforge.net/project/wordlist/SCOWL/{VERSION}/scowl-{VERSION}.tar.gz"
OUTPUT = Path(__file__).resolve().parents[1] / "Core/Sources/Core/InputUtils/AutoMixed/EnglishLexiconResources"
# User-confirmed runtime vocabulary, authored separately from SCOWL source levels.
SUPPLEMENTAL_WORDS = """
azookey backend chatgpt claude codex config deploy docker figma firefox frontend
gemini git github gitlab google homebrew ios ipad iphone javascript json linux
localhost mac macos markdown npm obsidian openai plugin pnpm rebase swiftui
vscode xcode yaml
""".split()
SUPPLEMENTAL_LEVEL = 20


def generate(archive):
    if hashlib.sha256(archive.read_bytes()).hexdigest() != SHA256:
        raise ValueError("SCOWL archive checksum mismatch")
    words = {}
    inputs = []
    with tarfile.open(archive) as source:
        for member in sorted(source.getmembers(), key=lambda x: x.name):
            match = re.fullmatch(r"scowl-2020\.12\.07/final/(english|american|british|british_z)-(words|contractions)\.(10|20|35)", member.name)
            if match is None:
                continue
            if not member.isfile() or member.size > 1_000_000:
                raise ValueError("Invalid word-list member")
            data = source.extractfile(member).read()
            inputs.append(dict(path=member.name, sha256=hashlib.sha256(data).hexdigest()))
            level = int(match[3])
            for word in data.decode("iso-8859-1").splitlines():
                # Keep only the exact lowercase ASCII spelling; no lossy normalization.
                if re.fullmatch(r"[a-z]+(?:'[a-z]+)?", word) and len(word) <= 32:
                    words[word] = min(words.get(word, level), level)
        copyright_text = source.extractfile(f"scowl-{VERSION}/Copyright").read()
    if not words or not inputs:
        raise ValueError("No dictionary data")
    for word in SUPPLEMENTAL_WORDS:
        words[word] = min(words.get(word, SUPPLEMENTAL_LEVEL), SUPPLEMENTAL_LEVEL)
    text = "# Modified SCOWL subset with authored additions; see Copyright and README.md.\n"
    text += "".join(f"{word}\t{level}\n" for word, level in sorted(words.items()))
    data = text.encode("ascii")
    receipt = dict(source_url=URL, version=VERSION, source_revision=REVISION, archive_sha256=SHA256,
                   purpose="runtime_dictionary_only_not_training_data", source_files=inputs,
                   authored_additions=dict(words=sorted(SUPPLEMENTAL_WORDS), level=SUPPLEMENTAL_LEVEL),
                   word_count=len(words), output_sha256=hashlib.sha256(data).hexdigest(),
                   copyright_sha256=hashlib.sha256(copyright_text).hexdigest())
    return {"english.tsv": data, "Copyright": copyright_text,
            "provenance.json": (json.dumps(receipt, indent=2) + "\n").encode()}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("archive", type=Path)
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    outputs = generate(args.archive)
    if not args.check:
        OUTPUT.mkdir(parents=True, exist_ok=True)
    for name, data in outputs.items():
        target = OUTPUT / name
        if args.check or target.exists():
            if target.read_bytes() != data:
                raise ValueError(f"Generated file differs: {name}; refusing to overwrite")
        else:
            target.write_bytes(data)
    print(f"Verified {len(outputs)} lexicon artifacts")


if __name__ == "__main__":
    main()
