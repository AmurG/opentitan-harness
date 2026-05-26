#!/usr/bin/env python3
from __future__ import annotations

import argparse
import datetime as dt
import gzip
import hashlib
import json
import os
import re
import shutil
from pathlib import Path


IMPORTANT_LOG_RE = re.compile(
    r"(UVM_(?:ERROR|FATAL)|\*E,|\*F,|TEST (?:PASSED|FAILED)|"
    r"PASSED|FAILED|Errors?:|Fatals?:|SVSEED|ntb_random_seed|waves?\.)",
    re.IGNORECASE,
)
TIME_RE = re.compile(r"^#([0-9]+)\s*$")
VAR_RE = re.compile(r"^\$var\s+\S+\s+(\d+)\s+(\S+)\s+(.+?)\s+\$end\s*$")
SCOPE_RE = re.compile(r"^\$scope\s+\S+\s+(.+?)\s+\$end\s*$")


def utc_now() -> str:
    return dt.datetime.now(dt.timezone.utc).replace(microsecond=0).isoformat()


def read_env(path: Path) -> dict[str, str]:
    data: dict[str, str] = {}
    if not path.is_file():
        return data
    for raw in path.read_text(encoding="utf-8", errors="replace").splitlines():
        if not raw or raw.startswith("#") or "=" not in raw:
            continue
        key, value = raw.split("=", 1)
        data[key] = value
    return data


def sha256_file(path: Path, limit: int | None = None) -> str | None:
    if limit is not None and path.stat().st_size > limit:
        return None
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def write_json(path: Path, data: object) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(data, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def copy_text_if_present(src: Path, dst: Path) -> str | None:
    if not src.is_file():
        return None
    dst.parent.mkdir(parents=True, exist_ok=True)
    dst.write_text(src.read_text(encoding="utf-8", errors="replace"), encoding="utf-8")
    return str(dst)


def parse_target_file(path: Path) -> list[dict[str, str]]:
    rows: list[dict[str, str]] = []
    if not path.is_file():
        return rows
    for raw in path.read_text(encoding="utf-8", errors="replace").splitlines():
        if not raw.strip() or raw.startswith("#"):
            continue
        parts = raw.split("\t")
        while len(parts) < 5:
            parts.append("")
        rows.append(
            {
                "test": parts[0],
                "iteration": parts[1],
                "seed": parts[2],
                "build_mode": parts[3],
                "reason": parts[4],
            }
        )
    return rows


def log_counts(paths: list[Path]) -> dict[str, int]:
    counts = {
        "uvm_error": 0,
        "uvm_fatal": 0,
        "xrun_error": 0,
        "xrun_fatal": 0,
        "passed_lines": 0,
        "failed_lines": 0,
    }
    for path in paths:
        try:
            lines = path.read_text(encoding="utf-8", errors="replace").splitlines()
        except OSError:
            continue
        for line in lines:
            upper = line.upper()
            counts["uvm_error"] += upper.count("UVM_ERROR")
            counts["uvm_fatal"] += upper.count("UVM_FATAL")
            if "*E," in line:
                counts["xrun_error"] += 1
            if "*F," in line:
                counts["xrun_fatal"] += 1
            if "PASSED" in upper:
                counts["passed_lines"] += 1
            if "FAILED" in upper:
                counts["failed_lines"] += 1
    return counts


def write_log_excerpt(paths: list[Path], out_path: Path, tail_lines: int) -> None:
    selected: list[str] = []
    for path in paths:
        selected.append(f"===== {path.name} important lines =====")
        try:
            lines = path.read_text(encoding="utf-8", errors="replace").splitlines()
        except OSError as exc:
            selected.append(f"<read failed: {exc}>")
            continue
        important = [line for line in lines if IMPORTANT_LOG_RE.search(line)]
        selected.extend(important[-tail_lines:])
        selected.append(f"===== {path.name} tail =====")
        selected.extend(lines[-tail_lines:])
    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_text("\n".join(selected) + "\n", encoding="utf-8")


def load_patterns(path: Path) -> list[re.Pattern[str]]:
    patterns: list[re.Pattern[str]] = []
    for raw in path.read_text(encoding="utf-8", errors="replace").splitlines():
        text = raw.strip()
        if not text or text.startswith("#"):
            continue
        patterns.append(re.compile(text))
    return patterns


def signal_wanted(path: str, patterns: list[re.Pattern[str]]) -> bool:
    return any(pattern.search(path) for pattern in patterns)


def summarize_vcd(
    path: Path,
    patterns: list[re.Pattern[str]],
    *,
    max_signals: int,
    max_events_per_signal: int,
    hash_limit: int,
) -> dict[str, object]:
    scopes: list[str] = []
    id_to_path: dict[str, str] = {}
    all_signal_hash = hashlib.sha256()
    prefix_counts: dict[str, int] = {}
    selected_ids: set[str] = set()
    selected: dict[str, dict[str, object]] = {}
    stats = {
        "path": path.name,
        "bytes": path.stat().st_size,
        "sha256": sha256_file(path, hash_limit),
        "sha256_omitted_reason": None,
        "scope_count": 0,
        "var_count": 0,
        "selected_signal_count": 0,
        "time_markers": 0,
        "max_time": 0,
    }
    if stats["sha256"] is None:
        stats["sha256_omitted_reason"] = f"file larger than hash_limit={hash_limit}"

    in_header = True
    current_time = 0
    with path.open("r", encoding="utf-8", errors="replace") as f:
        for raw in f:
            line = raw.strip()
            if in_header:
                if line.startswith("$enddefinitions"):
                    in_header = False
                    continue
                m_scope = SCOPE_RE.match(line)
                if m_scope:
                    scopes.append(m_scope.group(1).strip())
                    stats["scope_count"] += 1
                    continue
                if line.startswith("$upscope"):
                    if scopes:
                        scopes.pop()
                    continue
                m_var = VAR_RE.match(line)
                if m_var:
                    _size, ident, ref = m_var.groups()
                    full_path = ".".join([*scopes, ref.strip()])
                    id_to_path[ident] = full_path
                    all_signal_hash.update(f"{full_path}\n".encode("utf-8"))
                    parts = [piece for piece in full_path.split(".") if piece]
                    prefix = ".".join(parts[:4]) if parts else "<root>"
                    prefix_counts[prefix] = prefix_counts.get(prefix, 0) + 1
                    stats["var_count"] += 1
                    if len(selected_ids) < max_signals and signal_wanted(full_path, patterns):
                        selected_ids.add(ident)
                        selected[ident] = {
                            "path": full_path,
                            "changes": 0,
                            "last_value": None,
                            "event_hash": hashlib.sha256(),
                            "sample_events": [],
                        }
                continue

            m_time = TIME_RE.match(line)
            if m_time:
                current_time = int(m_time.group(1))
                stats["time_markers"] += 1
                stats["max_time"] = max(int(stats["max_time"]), current_time)
                continue
            if not line:
                continue

            ident = ""
            value = ""
            if line[0] in "01xXzZ":
                ident = line[1:]
                value = line[0]
            elif line[0] in "bBrR" and " " in line:
                value, ident = line.split(None, 1)
            if ident not in selected:
                continue
            item = selected[ident]
            item["changes"] = int(item["changes"]) + 1
            item["last_value"] = value
            digest = item["event_hash"]
            digest.update(f"{current_time} {value}\n".encode("utf-8"))
            sample = item["sample_events"]
            assert isinstance(sample, list)
            if len(sample) < max_events_per_signal:
                sample.append([current_time, value])

    stats["selected_signal_count"] = len(selected)
    stats["all_signal_name_sha256"] = all_signal_hash.hexdigest()
    stats["top_prefixes"] = [
        {"prefix": prefix, "count": count}
        for prefix, count in sorted(prefix_counts.items(), key=lambda item: (-item[1], item[0]))[
            :40
        ]
    ]
    signals = []
    for item in selected.values():
        digest = item.pop("event_hash")
        item["event_sha256"] = digest.hexdigest()
        signals.append(item)
    return {"stats": stats, "signals": signals}


def discover_files(run_dir: Path) -> tuple[list[Path], list[Path]]:
    logs = sorted(
        p
        for p in run_dir.rglob("*")
        if p.is_file() and p.suffix.lower() in {".log", ".err"} and p.stat().st_size < 25_000_000
    )
    waves = sorted(
        p
        for p in run_dir.rglob("*")
        if p.is_file() and p.suffix.lower() in {".vcd", ".evcd"}
    )
    return logs, waves


def copy_raw_wave(path: Path, out_path: Path) -> None:
    out_path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("rb") as src, gzip.open(out_path, "wb", compresslevel=6) as dst:
        shutil.copyfileobj(src, dst)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--private-root", type=Path, required=True)
    parser.add_argument("--usable-out", type=Path, required=True)
    parser.add_argument("--target-file", type=Path, required=True)
    parser.add_argument("--signal-patterns", type=Path, required=True)
    parser.add_argument("--log-excerpt-lines", type=int, default=220)
    parser.add_argument("--vcd-max-signals", type=int, default=200)
    parser.add_argument("--vcd-max-events-per-signal", type=int, default=64)
    parser.add_argument("--max-raw-wave-bytes", type=int, default=25_000_000)
    parser.add_argument("--export-raw-waves", action="store_true")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    patterns = load_patterns(args.signal_patterns)
    args.usable_out.mkdir(parents=True, exist_ok=True)

    manifest: dict[str, object] = {
        "created_utc": utc_now(),
        "format": "opentitan-xcelium-usable-emissions-v1",
        "policy": {
            "raw_xcelium_output_exported": bool(args.export_raw_waves),
            "raw_output_source": str(args.private_root),
            "note": "Default output is derived summaries, filtered log excerpts, and VCD signatures.",
        },
        "target_file": str(args.target_file),
        "targets": parse_target_file(args.target_file),
        "runs": [],
    }
    copy_text_if_present(args.target_file, args.usable_out / "selected_targets.tsv")

    run_dirs = sorted(p for p in (args.private_root / "runs").glob("*") if p.is_dir())
    for run_dir in run_dirs:
        env = read_env(run_dir / "run.env")
        slug = run_dir.name
        out_dir = args.usable_out / "runs" / slug
        out_dir.mkdir(parents=True, exist_ok=True)
        logs, waves = discover_files(run_dir)

        summary: dict[str, object] = {
            "slug": slug,
            "env": env,
            "logs": [
                {
                    "name": path.name,
                    "relative_private_path": str(path.relative_to(args.private_root)),
                    "bytes": path.stat().st_size,
                    "sha256": sha256_file(path, 25_000_000),
                }
                for path in logs
            ],
            "log_counts": log_counts(logs),
            "waves": [],
        }
        copied_command = copy_text_if_present(run_dir / "command.sh", out_dir / "command.sh")
        copied_env = copy_text_if_present(run_dir / "run.env", out_dir / "run.env")
        copied_targets = copy_text_if_present(
            run_dir / "selected_targets.tsv", out_dir / "selected_targets.tsv"
        )
        if copied_command:
            summary["command_sh"] = str(Path(copied_command).relative_to(args.usable_out))
        if copied_env:
            summary["run_env"] = str(Path(copied_env).relative_to(args.usable_out))
        if copied_targets:
            summary["selected_targets_tsv"] = str(Path(copied_targets).relative_to(args.usable_out))
        write_log_excerpt(logs, out_dir / "log_excerpt.txt", args.log_excerpt_lines)

        for wave in waves:
            wave_entry: dict[str, object] = {
                "name": wave.name,
                "relative_private_path": str(wave.relative_to(args.private_root)),
                "bytes": wave.stat().st_size,
            }
            if wave.suffix.lower() in {".vcd", ".evcd"}:
                sig = summarize_vcd(
                    wave,
                    patterns,
                    max_signals=args.vcd_max_signals,
                    max_events_per_signal=args.vcd_max_events_per_signal,
                    hash_limit=args.max_raw_wave_bytes,
                )
                sig_path = out_dir / f"{wave.stem}_signature.json"
                write_json(sig_path, sig)
                wave_entry["signature_json"] = str(sig_path.relative_to(args.usable_out))
                wave_entry["stats"] = sig["stats"]
            if args.export_raw_waves and wave.stat().st_size <= args.max_raw_wave_bytes:
                raw_out = out_dir / f"{wave.name}.gz"
                copy_raw_wave(wave, raw_out)
                wave_entry["exported_raw_gzip"] = str(raw_out.relative_to(args.usable_out))
            summary["waves"].append(wave_entry)

        write_json(out_dir / "summary.json", summary)
        manifest["runs"].append(
            {
                "slug": slug,
                "summary_json": str((out_dir / "summary.json").relative_to(args.usable_out)),
                "rc": env.get("RC"),
                "test": env.get("TEST"),
                "seed": env.get("SEED"),
                "iteration": env.get("ITERATION"),
            }
        )

    write_json(args.usable_out / "manifest.json", manifest)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
