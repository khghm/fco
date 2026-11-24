#!/usr/bin/env python3
"""ممیزی یکپارچگی اسناد — Fashion Commerce OS

قاعده تک‌منبعی (Management-00/PROJECT_MASTER_CONTROL.md §4.2) را قابل‌اجرا می‌کند.
سه بررسی الزامی + یک بررسی ارجاع:

1. تکرار خط بین اسناد   — یک جمله/بند یکسان در دو سند = تعریف دوباره.
2. تکرار ردیف جدول      — یک ردیف جدول در دو سند = دو منبع حقیقت.
3. پایان خط             — همه فایل‌ها باید LF باشند (.gitattributes).
4. ارجاع شکسته          — مسیر/لینک به سند ناموجود.

کد خروج: 0 = سالم، 1 = نقض. در CI به‌صورت مسدودکننده اجرا می‌شود.

اجرا:
    python scripts/docs-audit.py
    python scripts/docs-audit.py --verbose

نکته‌ها:
- سطرهای جدول/نقل‌قول نادیده گرفته می‌شوند (بررسی جدول جداگانه است).
- محتوای بلوک‌های کد (` ``` `) در بررسی «تکرار خط» نادیده گرفته می‌شود، چون شاهد اجرا است و نه تعریف قاعده.
- CHANGELOG.md از بررسی تکرار مستثناست: ماهیتش نقل وضعیت گذشته است.
- اسناد «برنامه‌ریزی‌شده» (docs/README.md §9) در ارجاع‌ها هشدار می‌دهند، نه خطا؛
  به‌محض ساخته‌شدن، خودبه‌خود از این فهرست خارج می‌شوند.
"""

from __future__ import annotations

import re
import sys
from collections import defaultdict
from pathlib import Path

# خروجی فارسی: روی کنسول ویندوز (cp1252) چاپ باید utf-8 باشد، وگرنه اسکریپت
# با UnicodeEncodeError می‌شکند و CI نتیجه واقعی را نشان نمی‌دهد.
for stream in (sys.stdout, sys.stderr):
    try:
        stream.reconfigure(encoding="utf-8", errors="replace")
    except (AttributeError, ValueError):
        pass

ROOT = Path(__file__).resolve().parent.parent
DOCS = ROOT / "docs"
LINE_MIN_LEN = 40
CHANGELOG_EXEMPT = {"Management-00/CHANGELOG.md"}

# اسناد عمداً ساخته‌نشده (docs/README.md §9). ارجاع به آن‌ها خطا نیست.
PLANNED_SUFFIXES = (
    "quality/REQUIREMENTS_TRACEABILITY_MATRIX.md",
    "quality/ACCEPTANCE_CRITERIA.md",
    "quality/PERFORMANCE_BUDGETS.md",
    "quality/SECURITY_CHECKLIST.md",
    "quality/DATA_RETENTION_POLICY.md",
    "Architecture-02/DOMAIN_BOUNDARIES.md",
    "Architecture-02/INTEGRATION_ARCHITECTURE.md",
    "Engineering-04/OBSERVABILITY_PLAN.md",
    "Engineering-04/RUNBOOK.md",
    "Engineering-04/INCIDENT_RESPONSE_PLAN.md",
    "Engineering-04/ADMIN_GUIDE.md",
    "Engineering-04/USER_GUIDE.md",
    "Engineering-04/DEVELOPER_GUIDE.md",
)

DOC_REF_RE = re.compile(
    r"(?:docs/)?(?:Management-00|Business-01|Architecture-02|UX-03|Engineering-04|product|quality)"
    r"/[A-Za-z0-9_.-]+\.md"
)
MD_LINK_RE = re.compile(r"\]\(([^)\s#]+)(?:#[^)]*)?\)")

errors: list[str] = []
warnings: list[str] = []


def rel(p: Path) -> str:
    try:
        return p.relative_to(ROOT).as_posix()
    except ValueError:
        return p.as_posix()


def collect_files() -> list[Path]:
    files = sorted(DOCS.rglob("*.md"))
    root_readme = ROOT / "README.md"
    if root_readme.exists():
        files.append(root_readme)
    return files


def check_line_endings(files: list[Path]) -> None:
    bad = [rel(p) for p in files if b"\r\n" in p.read_bytes()]
    if bad:
        errors.append(
            "پایان خط CRLF در "
            + str(len(bad))
            + " فایل (سیاست: LF):\n    "
            + "\n    ".join(bad)
        )


def is_noise(line: str) -> bool:
    s = line.strip()
    return (
        not s
        or s.startswith(("#", "|", ">", "`", "```", "---", "|", "!", "<!--"))
    )


def check_duplicates(files: list[Path], verbose: bool) -> None:
    long_lines: dict[str, set[str]] = defaultdict(set)
    table_rows: dict[str, set[str]] = defaultdict(set)

    for p in files:
        name = rel(p)
        if name.startswith("docs/") and name[len("docs/"):] in CHANGELOG_EXEMPT:
            continue
        in_fence = False
        for line in p.read_text(encoding="utf-8").splitlines():
            s = line.strip()
            # بلوک کد نمی‌تواند «تعریف دوباره قاعده» باشد: شاهد اجرا است
            # (مثل دستور راه‌اندازی که در README هم آمده). پایان خط و ارجاع
            # همان فایل جداگانه بررسی می‌شوند.
            if s.startswith("```"):
                in_fence = not in_fence
                continue
            if in_fence:
                continue
            if len(s) >= LINE_MIN_LEN and not is_noise(s):
                long_lines[s].add(name)
            elif s.startswith("|") and s.count("|") >= 4 and "---" not in s:
                table_rows[s].add(name)

    dup_lines = {k: v for k, v in long_lines.items() if len(v) > 1}
    dup_rows = {k: v for k, v in table_rows.items() if len(v) > 1}

    if dup_lines:
        errors.append(f"تکرار خط بین اسناد ({len(dup_lines)} مورد ≥{LINE_MIN_LEN} کاراکتر):")
        for text, where in list(dup_lines.items())[:20]:
            errors.append(f"  «{text[:70]}…»\n    " + " · ".join(sorted(where)))
    if dup_rows:
        errors.append(f"تکرار ردیف جدول بین اسناد ({len(dup_rows)} مورد):")
        for text, where in list(dup_rows.items())[:20]:
            errors.append(f"  {text[:70]}\n    " + " · ".join(sorted(where)))

    if verbose:
        print(f"  خطوط یکتا: {len(long_lines)} · ردیف جدول یکتا: {len(table_rows)}")


def check_refs(files: list[Path]) -> None:
    for p in files:
        text = p.read_text(encoding="utf-8")
        targets: list[str] = []

        for m in DOC_REF_RE.finditer(text):
            targets.append(m.group(0).removeprefix("docs/"))

        for m in MD_LINK_RE.finditer(text):
            link = m.group(1)
            if link.startswith(("http://", "https://", "mailto:", "tel:", "#")):
                continue
            if link.endswith(".md"):
                targets.append(link)

        for t in targets:
            t = t.lstrip("./")
            candidates = [DOCS / t, p.parent / t, ROOT / t]
            if any(c.exists() for c in candidates):
                continue
            if t in PLANNED_SUFFIXES or t.replace("\\", "/") in PLANNED_SUFFIXES:
                warnings.append(f"{rel(p)} → «{t}» (سند برنامه‌ریزی‌شده)")
                continue
            errors.append(f"ارجاع شکسته: {rel(p)} → {t}")


def main(argv: list[str]) -> int:
    verbose = "--verbose" in argv or "-v" in argv
    files = collect_files()

    print(f"ممیزی اسناد — {len(files)} فایل")
    check_line_endings(files)
    check_duplicates(files, verbose)
    check_refs(files)

    if warnings:
        print(f"\nهشدار ({len(warnings)}):")
        for w in warnings:
            print("  -", w)

    if errors:
        print(f"\nنقض ({len(errors)}):")
        for e in errors:
            print("  -", e)
        print("\nنتیجه: FAILED — قاعده تک‌منبعی یا یکپارچگی مسیرها نقض شده است.")
        return 1

    print("\nنتیجه: OK — بدون تکرار، بدون ارجاع شکسته، پایان خط LF.")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
