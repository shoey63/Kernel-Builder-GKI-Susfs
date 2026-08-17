import json
import re
import urllib.request
import os
import time

DB_FILE = "tools/master_kernel_db.json"
REPO_URL = "https://android.googlesource.com/kernel/common"

def get_gitiles_json(url, retries=5):
    """Fetches and cleans Gitiles API JSON output with exponential backoff."""
    base_delay = 3
    for attempt in range(retries):
        try:
            req = urllib.request.Request(url, headers={'User-Agent': 'Termux-CI-Builder/2.0'})
            with urllib.request.urlopen(req, timeout=15) as response:
                data = response.read().decode('utf-8')
                # Strip XSS protection string
                if data.startswith(")]}'"):
                    data = data.split('\n', 1)[1]
                return json.loads(data)
                
        except urllib.error.HTTPError as e:
            print(f"\n     [-] HTTP Error on attempt {attempt + 1}: {e.code} {e.reason}")
            if attempt < retries - 1:
                # Exponential backoff: 3s, 6s, 12s, 24s
                sleep_time = base_delay * (2 ** attempt)
                if e.code == 429:
                    print(f"     [*] Rate limited! Backing off for {sleep_time} seconds...")
                else:
                    print(f"     [*] Retrying in {sleep_time} seconds...")
                time.sleep(sleep_time)
            else:
                print(f"     [-] Failed after {retries} attempts. Skipping page.")
                return None
                
        except Exception as e:
            print(f"\n     [-] Network error on attempt {attempt + 1}: {e}")
            if attempt < retries - 1:
                sleep_time = base_delay * (2 ** attempt)
                print(f"     [*] Retrying in {sleep_time} seconds...")
                time.sleep(sleep_time)
            else:
                print(f"     [-] Failed after {retries} attempts. Skipping page.")
                return None
                
def main():
    print("[*] Initializing Unified Kernel DB Maintainer...")
    
    database = {}
    is_incremental = False
    commit_depth = 40000

    # 1. State check: Full build vs Incremental update
    if os.path.exists(DB_FILE):
        print(f"[*] Existing database found at '{DB_FILE}'. Switching to Incremental Sync (Depth: 300).")
        is_incremental = True
        commit_depth = 300
        try:
            with open(DB_FILE, "r") as f:
                database = json.load(f)
        except Exception as e:
            print(f"[-] Failed to load existing DB: {e}. Defaulting to Full Build.")
            is_incremental = False
            commit_depth = 40000
            database = {}
    else:
        print(f"[!] Database not found at '{DB_FILE}'. Triggering Full Historical Build (Depth: 40000).")

    # 2. Fetch all remote branches
    print("[*] Fetching active KMI and LTS branches from kernel/common...")
    refs = get_gitiles_json(f"{REPO_URL}/+refs/heads/?format=JSON")
    if not refs:
        print("[-] Failed to get branches. Exiting.")
        return

    # Match androidXX-X.X-YYYY-MM OR androidXX-X.X-lts
    branch_pattern = re.compile(r'^(android\d+)-(\d+\.\d+)-(lts|\d{4}-\d{2})$')
    valid_branches = []
    
    for branch_name in refs.keys():
        match = branch_pattern.match(branch_name)
        if match:
            android_ver, base_ver, date_str = match.groups()
            
            # Exclude legacy kernels (4.x, 5.4) - GKI 2.0 started with 5.10
            if base_ver.startswith("4.") or base_ver in ["5.4"]:
                continue
                
            valid_branches.append({
                "branch": branch_name,
                "android_ver": android_ver,
                "base_ver": base_ver,
                "date": date_str
            })
    # 3. Sort branches: Chronological Dated first, then LTS last.
    # This guarantees we lock tags to their oldest dated branch immediately.
    # The LTS branch is scanned last to catch only the bleeding-edge leftovers.
    def branch_sort_key(b):
        return '9999-99' if b['date'] == 'lts' else b['date']
        
    valid_branches.sort(key=branch_sort_key)
 
    # 4. Scrape logic
    # Catch official tags AND raw upstream LTS merges
    tag_pattern = re.compile(r"Merge tag 'android\d+-(\d+\.\d+\.\d+)_r\w*'|Merge (\d+\.\d+\.\d+) into android\d+-\d+\.\d+-lts")
    added_count = 0
    upgraded_count = 0
    
    for b in valid_branches:
        base = b["base_ver"]
        if base not in database:
            database[base] = []

        # --- DYNAMIC DEPTH LOGIC ---
        if not is_incremental:
            # Full build: Deep scan only the foundational branches
            if b["date"] in ["2025-06", "2025-07"]:
                branch_depth = 40000
            else:
                branch_depth = 40000  # Shallow scan for newer branches and LTS
        else:
            # Incremental build: Always use the fast 300 commit limit
            branch_depth = commit_depth
        # ---------------------------

        print(f"\n  -> Scanning branch: {b['branch']} (Depth Limit: {branch_depth})...")
        
        branch_added = 0
        branch_upgraded = 0
        total_commits_scanned = 0
        page_count = 1
        next_token = ""
        
        while True:
            # \r overwrites the line to prevent terminal spam
            print(f"     [*] Fetching page {page_count} (Scanned {total_commits_scanned} commits)...", end="\r", flush=True)
            
            log_url = f"{REPO_URL}/+log/refs/heads/{b['branch']}?n=500&format=JSON"
            if next_token:
                log_url += f"&s={next_token}"
                
            log_data = get_gitiles_json(log_url)
            
            if not log_data or "log" not in log_data:
                break
                
            commits = log_data["log"]
            total_commits_scanned += len(commits)
            
            for commit in commits:
                message = commit.get("message", "")
                match = tag_pattern.search(message)
                
                if match:
                    kernel_version = match.group(1) or match.group(2)
                    
                    # Validation
                    if kernel_version.startswith(f"{base}."):
                        
                        # Search memory for existing entry
                        existing_entry = next((item for item in database[base] if item["kernel"] == kernel_version), None)
                        
                        if not existing_entry:
                            # Add New Tag
                            database[base].append({
                                "kernel": kernel_version,
                                "date": b["date"],
                                "android_version": b["android_ver"]
                            })
                            print(f"\n        [+] New tag added: {kernel_version} -> {b['date']}")
                            added_count += 1
                            branch_added += 1
                            
                        elif existing_entry["date"] == "lts" and b["date"] != "lts":
                            # Upgrade Tag Status
                            existing_entry["date"] = b["date"]
                            existing_entry["android_version"] = b["android_ver"]
                            print(f"\n        [^] Tag upgraded: {kernel_version} -> {b['date']}")
                            upgraded_count += 1
                            branch_upgraded += 1
                            
            next_token = log_data.get("next")
            
            # --- UPDATED HALT LOGIC ---
            # Halt if no next page or dynamic branch_depth is reached
            if not next_token or total_commits_scanned >= branch_depth:
                if total_commits_scanned >= branch_depth:
                    print(f"\n     [!] Reached {branch_depth} commit depth limit. Halting scan for this branch.")
                break
                
            page_count += 1
                
        print(f"\n     [=] Finished {b['branch']}: Added {branch_added}, Upgraded {branch_upgraded} (Scanned {total_commits_scanned})")

    # 5. Sort final database and write
    print(f"\n[*] Sorting final database chronologically and writing to {DB_FILE}...")
    
    for base in database:
        database[base].sort(key=lambda x: [int(p) for p in x["kernel"].split('.')])

    os.makedirs(os.path.dirname(DB_FILE) or '.', exist_ok=True)
    
    with open(DB_FILE, "w") as f:
        json.dump(database, f, indent=2)
        
    print(f"[*] Success! {DB_FILE} saved.")
    print(f"[*] SUMMARY: {added_count} Added | {upgraded_count} Upgraded")

if __name__ == "__main__":
    main()