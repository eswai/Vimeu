#!/usr/bin/env python3
"""Build/run the offline probe and summarize fixed policies; no IME install."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile

parser = argparse.ArgumentParser()
parser.add_argument("--samples", type=int, default=60, help="sentences per corpus")
parser.add_argument("--start-length", type=int, default=40)
parser.add_argument("--output", type=Path, default=Path(__file__).with_name("results.json"))
args = parser.parse_args()
if args.samples < 1:
    parser.error("samples must be positive")
if not 2 <= args.start_length <= 1000:
    parser.error("start-length must be in 2...1000")
root = Path(__file__).resolve().parents[2]
env = dict(os.environ, CLANG_MODULE_CACHE_PATH="/tmp/vimeu-clang-module-cache",
           SWIFTPM_MODULECACHE_OVERRIDE="/tmp/vimeu-swift-module-cache")
for target in (["--product", "vimeu-eval"], ["--target", "VimeuInput"]):
    subprocess.run(["swift", "build", "--disable-sandbox", "--build-system", "native", "-debug-info-format", "none", "-c", "release", *target],
                   cwd=root, env=env, check=True)
build = Path(subprocess.check_output(
    ["swift", "build", "--disable-sandbox", "--build-system", "native", "-debug-info-format", "none", "-c", "release", "--show-bin-path"],
    cwd=root, env=env, text=True).strip())
objects = []
for module in ("VimeuDict", "VimeuEngine", "VimeuUserDict", "VimeuInput"):
    mapping = json.loads((build / f"{module}.build/output-file-map.json").read_text())
    objects.extend(value["object"] for key, value in mapping.items() if key and "object" in value)
with tempfile.TemporaryDirectory(prefix="vimeu-cost-probe-") as work:
    binary = Path(work) / "probe"
    raw = Path(work) / "observations.json"
    subprocess.run([
        "swiftc", "-O", "-I", str(build / "Modules"),
        str(Path(__file__).with_name("main.swift")),
        str(Path(__file__).with_name("LegacyPartialCommit.swift")),
        str(root / "Sources/VimeuIME/PartialCommitStability.swift"),
        str(root / "Tests/VimeuEngineTests/TestDictionary.swift"),
        *objects, "-o", str(binary),
    ], cwd=root, env=env, check=True)
    subprocess.run([str(binary), str(root), str(args.samples), str(raw), str(args.start_length)], check=True)
    data = json.loads(raw.read_text())

rows = data.pop("observations")

def stats(pairs):
    pairs = [(row, cut) for row, cut in pairs if cut is not None]
    count = len(pairs)
    return dict(selectedSnapshots=count, eligibleSnapshots=len(rows),
                selectedFraction=count / len(rows) if rows else 0,
                meanCommitScalars=sum(cut["cut"] for _, cut in pairs) / count if count else None,
                meanRemainingScalars=sum(len(row["input"]) - cut["cut"] for row, cut in pairs) / count if count else None,
                minRemainingScalars=min((len(row["input"]) - cut["cut"] for row, cut in pairs), default=None),
                alignmentOrSurfaceDisagreements=sum(cut["revised"] for _, cut in pairs),
                alignmentOrSurfaceDisagreementFraction=sum(cut["revised"] for _, cut in pairs) / count if count else None,
                surfaceConflicts=sum(not row["fullBest"].startswith(cut["text"]) for row, cut in pairs),
                surfaceConflictFraction=sum(not row["fullBest"].startswith(cut["text"]) for row, cut in pairs) / count if count else None,
                boundaryChanged=sum(cut["boundaryChanged"] for _, cut in pairs))

policies = {"lengthOnly": stats((row, row["cuts"][-1]) for row in rows)}

def non_hiragana_cut(row, stable=False):
    eligible = [cut for cut in row["cuts"] if not cut["remainingStartsWithHiragana"]
                and (not stable or cut["cut"] <= row["stableCut"])]
    return eligible[-1] if eligible else None

for stable in (False, True):
    policies[f'{"stable5+" if stable else ""}nonHiraganaStart'] = stats(
        (row, non_hiragana_cut(row, stable)) for row in rows)
policies["forwardNonHiraganaStart"] = stats((row, row["forwardNonHiraganaCut"]) for row in rows)
policies["stable5+forwardNonHiraganaStart"] = stats(
    (row, row["forwardNonHiraganaCut"] if row["forwardNonHiraganaCut"]
     and row["forwardNonHiraganaCut"]["cut"] <= row["stablePrefixScalarCount"] else None) for row in rows)

def pos_cut(row, rule, stable=False):
    eligible = [cut for cut in row["cuts"] if rule in cut["allowedPOSRules"]
                and (not stable or cut["cut"] <= row["stableCut"])]
    return eligible[-1] if eligible else None

pos_suffix_changes = {}
for rule in ("particles", "attachedWords", "attachedWordsAndPrefixes"):
    for stable in (False, True):
        policies[f'{"stable5+" if stable else ""}{rule}'] = stats(
            (row, pos_cut(row, rule, stable)) for row in rows)
    selected = [row for row in rows if rule in row["posSuffixChanges"]]
    pos_suffix_changes[rule] = dict(
        selectedSnapshots=len(selected), eligibleSnapshots=len(rows),
        baselineChangesAmongSelected=sum(row["suffixChangedAfterBOSReset"] for row in selected),
        changesAfterBoundaryChoice=sum(row["posSuffixChanges"][rule] for row in selected),
        meanBoundaryRetreatScalars=sum(row["maxCut"] - pos_cut(row, rule)["cut"] for row in selected) / len(selected) if selected else None)
for stable in (False, True):
    for threshold in (0, 1, 100, 500, 1000, 2000):
        def choose(row):
            eligible = [cut for cut in row["cuts"] if cut["margin"] >= threshold
                        and (not stable or cut["cut"] <= row["stableCut"])]
            return eligible[-1] if eligible else None
        policies[f'{"stable5+" if stable else ""}margin>={threshold}'] = stats(
            (row, choose(row)) for row in rows)

bins = []
for low, high in ((0, 1), (1, 100), (100, 500), (500, 1000), (1000, 2000), (2000, None)):
    group = [(row, row["cuts"][-1]) for row in rows
             if row["cuts"][-1]["margin"] >= low
             and (high is None or row["cuts"][-1]["margin"] < high)]
    bins.append(dict(marginFrom=low, marginBelow=high, **stats(group)))

changed = [row for row in rows if row["suffixChangedAfterBOSReset"]]
non_hiragana_rows = [row for row in rows if row["nonHiraganaSuffixChangedAfterBOSReset"] is not None]
forward_rows = [row for row in rows if row["forwardNonHiraganaSuffixChangedAfterBOSReset"] is not None]
data.update(policies=policies, baselineMarginBins=bins, posSuffixChanges=pos_suffix_changes,
            suffixChanges=dict(count=len(changed), total=len(rows), fraction=len(changed) / len(rows)),
            suffixChangesWithLeftContext=dict(
                count=sum(row["suffixChangedWithLeftContext"] for row in rows), total=len(rows),
                fraction=sum(row["suffixChangedWithLeftContext"] for row in rows) / len(rows)),
            nonHiraganaSuffixChanges=dict(
                selectedSnapshots=len(non_hiragana_rows), eligibleSnapshots=len(rows),
                baselineChangesAmongSelected=sum(row["suffixChangedAfterBOSReset"] for row in non_hiragana_rows),
                changesAfterBoundaryChoice=sum(row["nonHiraganaSuffixChangedAfterBOSReset"] for row in non_hiragana_rows),
                meanBoundaryRetreatScalars=sum(row["maxCut"] - non_hiragana_cut(row)["cut"]
                    for row in non_hiragana_rows) / len(non_hiragana_rows) if non_hiragana_rows else None,
                changedExamples=[row for row in non_hiragana_rows
                    if row["nonHiraganaSuffixChangedAfterBOSReset"]][:2]),
            forwardNonHiraganaSuffixChanges=dict(
                selectedSnapshots=len(forward_rows), eligibleSnapshots=len(rows),
                baselineChangesAmongSelected=sum(row["suffixChangedAfterBOSReset"] for row in forward_rows),
                changesAfterBoundaryChoice=sum(row["forwardNonHiraganaSuffixChangedAfterBOSReset"] for row in forward_rows),
                meanBoundaryAdvanceScalars=sum(row["forwardNonHiraganaCut"]["cut"] - row["maxCut"]
                    for row in forward_rows) / len(forward_rows) if forward_rows else None),
            suffixExamples=changed[:3],
            revisedHighMarginExamples=[row for row in rows
                if row["cuts"][-1]["revised"] and row["cuts"][-1]["margin"] >= 1000][:3])
data["files"] = {
    str(path.relative_to(root)): hashlib.sha256(path.read_bytes()).hexdigest()
    for path in (root / "dict/vimeu.dic", root / "corpus/testset.tsv", root / "corpus/testset_messenger.tsv")
}
args.output.parent.mkdir(parents=True, exist_ok=True)
args.output.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n")
print(json.dumps({"policies": policies, "suffixChanges": data["suffixChanges"]}, ensure_ascii=False, indent=2))
print(f"wrote {args.output.resolve()}")
