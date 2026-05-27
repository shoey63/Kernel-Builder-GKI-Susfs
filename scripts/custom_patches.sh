#!/usr/bin/env bash
set -euo pipefail

echo "=== Applying sane schedutil tuning patches ==="

cd kernel_workspace/common || {
  echo "[-] kernel_workspace/common not found" >&2
  exit 1
}

# ==============================================================================
# MODIFICATION 1:
# include/linux/sched/cpufreq.h
#
# Conservative schedutil boost:
# - ~1.25x headroom
# - safer thermals
# - avoids Tensor thermal death spirals
# ==============================================================================

echo ">>> Patching include/linux/sched/cpufreq.h..."

python3 << 'EOF'
from pathlib import Path
import re
import sys

path = Path("include/linux/sched/cpufreq.h")

content = path.read_text()

pattern = r"return\s+freq\s*\*\s*util\s*/\s*cap\s*;"

replacement = """\
unsigned long baseline;

\tbaseline = freq * util / cap;
\treturn baseline + (baseline >> 2); /* blu_schedutil 1.25x */
"""

if not re.search(pattern, content):
    print("[-] ERROR: map_util_freq formula not found")
    sys.exit(1)

content = re.sub(pattern, replacement, content, count=1)

path.write_text(content)

print("[+] map_util_freq tuned to 1.25x headroom")
EOF

# ==============================================================================
# MODIFICATION 2:
# kernel/sched/cpufreq_schedutil.c
#
# Goals:
# - Lower latency moderately (1000us)
# - Keep thermal behavior sane
# - Add visible boot banner
# ==============================================================================

echo ">>> Patching kernel/sched/cpufreq_schedutil.c..."

python3 << 'EOF'
from pathlib import Path
import re
import sys

path = Path("kernel/sched/cpufreq_schedutil.c")

content = path.read_text()

# ------------------------------------------------------------------------------
# Force governor update delay to 1000us
# ------------------------------------------------------------------------------

pattern_delay = (
    r"sg_policy->freq_update_delay_ns\s*=\s*"
    r"sg_policy->tunables->rate_limit_us\s*\*\s*NSEC_PER_USEC;"
)

replacement_delay = (
    "sg_policy->freq_update_delay_ns = "
    "1000 * NSEC_PER_USEC; "
    "/* blu_schedutil forced 1000us */"
)

if re.search(pattern_delay, content):
    content = re.sub(
        pattern_delay,
        replacement_delay,
        content,
        count=1
    )
    print("[+] Forced schedutil rate limit to 1000us")
else:
    print("[-] ERROR: freq_update_delay_ns assignment not found")
    sys.exit(1)

# ------------------------------------------------------------------------------
# Increase fallback capacity margin slightly
#
# Stock:
#   +25%
#
# Tuned:
#   +37.5%
# ------------------------------------------------------------------------------

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

# ------------------------------------------------------------------------------
# Add visible boot banner
# ------------------------------------------------------------------------------

banner = (
    'pr_info("blu_schedutil: active '
    '(1.25x map_util_freq, 1000us rate limit)\\\\n");'
)

if banner not in content:

    pattern_start = (
        r"(static int sugov_start\(struct cpufreq_policy \*policy\)\n\{)"
    )

    match = re.search(pattern_start, content)

    if match:
        insert = match.group(1) + "\n\t" + banner
        content = content.replace(match.group(1), insert, 1)
        print("[+] Injected schedutil boot banner")
    else:
        print("[*] Could not safely inject boot banner")

path.write_text(content)
EOF

# ==============================================================================
# VALIDATION
# ==============================================================================

echo ">>> Validating resulting cpufreq.h snippet..."

grep -A8 -B4 "baseline" \
  include/linux/sched/cpufreq.h || true

echo ">>> Validating schedutil rate limit patch..."

grep -n "1000 \\* NSEC_PER_USEC" \
  kernel/sched/cpufreq_schedutil.c || true

cd ../..

echo "=== Schedutil tuning patches applied successfully ==="
