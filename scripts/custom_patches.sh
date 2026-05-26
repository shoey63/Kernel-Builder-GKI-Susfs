#!/usr/bin/env bash
set -euo pipefail

echo "=== Applying sane schedutil tuning patches ==="

cd kernel_workspace/common || {
  echo "[-] kernel_workspace/common not found" >&2
  exit 1
}

# ------------------------------------------------------------------------------
# MODIFICATION 1:
# include/linux/sched/cpufreq.h
#
# Goal:
# - Reduce under-frequency behavior slightly
# - Avoid insane thermal runaway
# - Keep compiler-safe formatting
#
# Target:
#   return freq * util / cap;
#
# Replace with ~1.25x headroom
# ------------------------------------------------------------------------------

echo ">>> Patching include/linux/sched/cpufreq.h..."

python3 << 'EOF'
from pathlib import Path
import re
import sys

path = Path("include/linux/sched/cpufreq.h")
content = path.read_text()

patterns = [
    r"return\s+freq\s*\*\s*util\s*/\s*cap\s*;",
    r"return\s+freq\s*\*\s*util\s*/\s*max\s*;"
]

matched = False

for pattern in patterns:
    if re.search(pattern, content):
        replacement = (
            "unsigned long baseline;\n"
            "\n"
            "\tbaseline = freq * util / cap;\n"
            "\treturn baseline + (baseline >> 2); "
            "/* blu_schedutil 1.25x */"
        )

        replacement = replacement.replace("/ cap", "/ max")

        content = re.sub(pattern, replacement, content, count=1)
        matched = True
        break

if not matched:
    print("[-] ERROR: map_util_freq formula not found")
    sys.exit(1)

path.write_text(content)

print("[+] map_util_freq tuned to 1.25x headroom")
EOF

# ------------------------------------------------------------------------------
# MODIFICATION 2:
# kernel/sched/cpufreq_schedutil.c
#
# Goal:
# - Faster response without thermal insanity
# - Reduce latency to 1000us instead of 500us
# - Add reliable boot-visible logging
# ------------------------------------------------------------------------------

echo ">>> Patching kernel/sched/cpufreq_schedutil.c..."

python3 << 'EOF'
from pathlib import Path
import re
import sys

path = Path("kernel/sched/cpufreq_schedutil.c")
content = path.read_text()

# ----------------------------------------------------------------------
# Patch the governor update delay
# ----------------------------------------------------------------------

pattern = (
    r"sg_policy->freq_update_delay_ns\s*=\s*"
    r"sg_policy->tunables->rate_limit_us\s*\*\s*NSEC_PER_USEC;"
)

replacement = (
    "sg_policy->freq_update_delay_ns = "
    "1000 * NSEC_PER_USEC; "
    "/* blu_schedutil forced 1000us */"
)

if re.search(pattern, content):
    content = re.sub(pattern, replacement, content, count=1)
    print("[+] Forced schedutil rate limit to 1000us")
else:
    print("[-] ERROR: freq_update_delay_ns assignment not found")
    sys.exit(1)

# ----------------------------------------------------------------------
# Optional: reduce fallback capacity margin from 25% -> 37.5%
# ----------------------------------------------------------------------

pattern_margin = (
    r"return\s+policy->cur\s*\+\s*"
    r"\(policy->cur\s*>>\s*2\)\s*;"
)

replacement_margin = (
    "return policy->cur + "
    "(policy->cur >> 2) + "
    "(policy->cur >> 3); "
    "/* blu_schedutil 37.5% overhead */"
)

if re.search(pattern_margin, content):
    content = re.sub(
        pattern_margin,
        replacement_margin,
        content,
        count=1
    )
    print("[+] Increased fallback margin to 37.5%")
else:
    print("[*] Fallback margin path not present (safe to ignore)")

# ----------------------------------------------------------------------
# Add one reliable boot log banner
# ----------------------------------------------------------------------

banner = (
    'pr_info("blu_schedutil: tuned '
    '(1.25x map_util_freq, 1000us rate limit)\\n");'
)

if banner not in content:

    init_pattern = r"(static int sugov_start\(.*?\)\n\{)"

    match = re.search(init_pattern, content, re.DOTALL)

    if match:
        insert = match.group(1) + "\n\t" + banner
        content = content.replace(match.group(1), insert, 1)
        print("[+] Injected boot banner")
    else:
        print("[*] Could not inject boot banner safely")

path.write_text(content)
EOF

cd ../..

echo "=== Schedutil tuning patches applied successfully ==="
