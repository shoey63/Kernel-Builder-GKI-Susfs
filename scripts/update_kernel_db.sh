#!/bin/bash

# Configuration
DB_FILE="tools/master_kernel_db.json"
MANIFEST_URL="https://android.googlesource.com/kernel/manifest"
COMMIT_DEPTH=300

echo "========================================================"
echo "      SuSFS Kernel DB Maintenance Scraper ($COMMIT_DEPTH Commits)      "
echo "========================================================"

# Check if jq is installed
if ! command -v jq &> /dev/null; then
    echo "[-] Error: jq is required but not installed."
    exit 1
fi

# ==========================================
# 1. INITIALIZE OR LOAD DATABASE
# ==========================================
if [ ! -f "$DB_FILE" ]; then
    echo "[!] Database not found at '$DB_FILE'."
    echo "[*] Triggering full historical build..."
    
    # Check if the python generator script exists
    if [ -f "scripts/generate_full_db.py" ]; then
        # Run it explicitly with python3
        python3 scripts/generate_full_db.py
        
        # Verify the generator actually created the DB file
        if [ ! -f "$DB_FILE" ]; then
            echo "[-] FATAL: Generator script finished, but '$DB_FILE' was not created."
            exit 1
        fi
        
        echo "[+] Full database rebuilt successfully!"
    else
        echo "[-] FATAL: 'scripts/generate_full_db.py' not found. Cannot rebuild database."
        exit 1
    fi
else
    echo "[*] Existing database found at '$DB_FILE'."
    echo "[*] Preparing to scan for new updates..."
fi

# ==========================================
# 2. FETCH AND SORT ACTIVE BRANCHES
# ==========================================
echo "[*] Fetching active KMI branches from Gitiles..."
# Get refs, filter for KMI branches, strip 'refs/heads/', and sort oldest first (-V)
BRANCHES=$(curl -s "${MANIFEST_URL}/+refs?format=JSON" | \
           sed '1s/^[^{]*//' | \
           jq -r 'keys[]' | \
           grep -E '^refs/heads/common-android[0-9]+-[0-9]+\.[0-9]+-[0-9]{4}-[0-9]{2}$' | \
           sed 's|refs/heads/||' | \
           sort -V)

if [ -z "$BRANCHES" ]; then
    echo "[-] Failed to retrieve branches. Check your internet connection."
    exit 1
fi

# ==========================================
# 3. SCAN LOGS AND UPDATE DB
# ==========================================
ADDED_COUNT=0

for BRANCH in $BRANCHES; do
    # Extract metadata from branch string (e.g., common-android14-6.1-2025-08)
    BASE_VER=$(echo "$BRANCH" | grep -oE '[0-9]+\.[0-9]+' | head -n 1)
    ANDROID_VER=$(echo "$BRANCH" | grep -oE 'android[0-9]+')
    BRANCH_DATE=$(echo "$BRANCH" | grep -oE '[0-9]{4}-[0-9]{2}')
    
    echo ">>> Scanning last $COMMIT_DEPTH commits of $BRANCH..."
    
    # Fetch log page with n limit
    LOG_JSON=$(curl -s "${MANIFEST_URL}/+log/refs/heads/${BRANCH}?format=JSON&n=${COMMIT_DEPTH}" | sed '1s/^[^{]*//')
    
    # Extract raw kernel versions from merge tags
    TAGS=$(echo "$LOG_JSON" | \
           jq -r '.log[]?.message' 2>/dev/null | \
           grep -oE "Merge tag 'android[0-9]+-[0-9]+\.[0-9]+\.[0-9]+(_r[0-9]+)?'" | \
           grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | \
           sort -u)
           
    for KERNEL_VER in $TAGS; do
        # Check if the kernel version already exists anywhere in the JSON DB
        if ! jq -e --arg k "$KERNEL_VER" '.[][] | select(.kernel == $k)' "$DB_FILE" > /dev/null 2>&1; then
            echo "    [+] New tag found: $KERNEL_VER. Mapping to $BRANCH_DATE ($ANDROID_VER)..."
            
            TMP_DB=$(mktemp)
            
            # Inject new entry and instantly sort the array so it stays perfectly chronological
            jq --arg base "$BASE_VER" \
               --arg kv "$KERNEL_VER" \
               --arg dt "$BRANCH_DATE" \
               --arg av "$ANDROID_VER" \
               '.[$base] += [{"kernel": $kv, "date": $dt, "android_version": $av}] | 
                .[$base] |= sort_by(.kernel | split(".") | map(tonumber))' \
               "$DB_FILE" > "$TMP_DB"
               
            mv "$TMP_DB" "$DB_FILE"
            ((ADDED_COUNT++))
        fi
    done
done

echo "========================================================"
if [ "$ADDED_COUNT" -eq 0 ]; then
    echo "[*] Database is completely up to date! No new tags found."
else
    echo "[+] Database updated successfully! Added $ADDED_COUNT new kernels."
fi
echo "========================================================"
