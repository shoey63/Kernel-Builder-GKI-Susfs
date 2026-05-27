#!/usr/bin/env bash
set -euo pipefail

echo "=== Executing Python Sledgehammer Patches ==="

cd kernel_workspace/common || { echo "[-] kernel_workspace/common not found" >&2; exit 1; }

# ==============================================================================
# MODIFICATION 1: include/linux/sched/cpufreq.h
# ==============================================================================
echo ">>> Optimizing map_util_freq multiplier in include/linux/sched/cpufreq.h..."

python3 << 'EOF'
import re
import sys

filepath = "include/linux/sched/cpufreq.h"
with open(filepath, "r") as f:
    content = f.read()

# Target the raw linear calculation formula found in 6.1: return freq * util / cap;
pattern = r"return\s+freq\s*\*\s*util\s*/\s*(cap|max);"
match = re.search(pattern, content)

if match:
    divisor = match.group(1)
    # Intercept the base value and inject the aggressive 1.50x headroom multiplier
    replacement = f"unsigned long baseline = freq * util / {divisor}; return baseline + (baseline >> 1); /* blu_schedutil 1.50x headroom */"
    content = re.sub(pattern, replacement, content)
    with open(filepath, "w") as f:
        f.write(content)
    print("[+] Successfully optimized map_util_freq multiplier!")
else:
    print("[-] ERROR: Target map_util_freq linear formula not found in include/linux/sched/cpufreq.h")
    sys.exit(1)
EOF

# ==============================================================================
# MODIFICATION 2: kernel/sched/cpufreq_schedutil.c
# ==============================================================================
echo ">>> Hotwiring scaling behaviors in kernel/sched/cpufreq_schedutil.c..."

python3 << 'EOF'
import re
import sys

filepath = "kernel/sched/cpufreq_schedutil.c"
with open(filepath, "r") as f:
    content = f.read()

# 1. Update the fallback reference frequency overhead margin (if active)
pattern_margin = r"return\s+policy->cur\s*\+\s*\(policy->cur\s*>>\s*2\);"
replacement_margin = "return policy->cur + (policy->cur >> 1); /* blu_schedutil 50% overhead */"

if re.search(pattern_margin, content):
    content = re.sub(pattern_margin, replacement_margin, content)
    print("[+] Successfully bumped get_capacity_ref_freq capacity margin!")
else:
    print("[*] Note: Fallback margin line not found or handled by reference clock (skipping safely)")

# 2. Force the frequency evaluation update latency window down to 500us
pattern_latency = r"(sg_policy->freq_update_delay_ns\s*=\s*.*?;\n)"
match_latency = re.search(pattern_latency, content)

if match_latency:
    original_line = match_latency.group(1)
    # Inject the 500us override AND a custom dmesg log entry
    override_line = original_line + \
                    "\tsg_policy->freq_update_delay_ns = 500 * NSEC_PER_USEC; /* Force ultra-responsive 500us window */\n" + \
                    "\tpr_info(\"blu_schedutil: Hotwired CPU cluster latency to 500us\\n\");\n"
    content = content.replace(original_line, override_line)
    print("[+] Successfully injected 500us latency override and dmesg logger!")
else:
    print("[-] ERROR: Could not find freq_update_delay_ns initialization block")
    sys.exit(1)

with open(filepath, "w") as f:
    f.write(content)
EOF

cd ../..
echo ">>> All inline customizations successfully hot-wired."
