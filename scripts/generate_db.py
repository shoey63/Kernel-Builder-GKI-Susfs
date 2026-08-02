import json
import re
import urllib.request
import os
import time

DB_FILE = "master_kernel_db.json"
REPO_URL = "https://android.googlesource.com/kernel/common"

def get_gitiles_json(url, retries=3):
    """Fetches and cleans Gitiles API JSON output with retry logic."""
    for attempt in range(retries):
        try:
            req = urllib.request.Request(url, headers={'User-Agent': 'Termux-CI-Builder/1.3'})
            with urllib.request.urlopen(req, timeout=15) as response:
                data = response.read().decode('utf-8')
                # Strip XSS protection string
                if data.startswith(")]}'"):
                    data = data.split('\n', 1)[1]
                return json.loads(data)
        except Exception as e:
            print(f"\n     [-] Network error on attempt {attempt + 1}: {e}")
            if attempt < retries - 1:
                print(f"     [*] Retrying in 3 seconds...")
                time.sleep(3)
            else:
                print(f"     [-] Failed after {retries} attempts. Skipping page.")
                return None

def main():
    print("[*] Initializing Kernel DB Builder...")
    database = {}

    # 1. Fetch all remote branches from Gitiles
    print("[*] Fetching branches from kernel/common...")
    refs = get_gitiles_json(f"{REPO_URL}/+refs/heads/?format=JSON")
    if not refs:
        print("[-] Failed to get branches. Exiting.")
        return

    # 2. Filter for date-suffixed branches (e.g., android12-5.10-2025-09)
    branch_pattern = re.compile(r'^(android\d+)-(\d+\.\d+)-(\d{4}-\d{2})$')
    valid_branches = []
    
    for branch_name in refs.keys():
        match = branch_pattern.match(branch_name)
        if match:
            android_ver, base_ver, date_str = match.groups()
            valid_branches.append({
                "branch": branch_name,
                "android_ver": android_ver,
                "base_ver": base_ver,
                "date": date_str
            })

    # 3. Sort chronologically (Oldest to Newest)
    # Sorting oldest first ensures we lock a kernel version to its ORIGINAL branch for accurate toolchains
    valid_branches = sorted(valid_branches, key=lambda x: x["date"], reverse=False)
    print(f"[+] Found {len(valid_branches)} date-suffixed branches. Sorting oldest to newest...\n")

    # 4. Scrape tags using targeted release branch regex
    # Based on user target: Merge tag 'android1*-*.*.*_r*'
    tag_pattern = re.compile(r"Merge tag 'android\d+-(\d+\.\d+\.\d+)_r\w*'")
    seen_kernels = set()

    for b in valid_branches:
        base = b["base_ver"]
        if base not in database:
            database[base] = []

        print(f"\n  -> Scanning branch: {b['branch']} ...")
        
        branch_tag_count = 0
        total_commits_scanned = 0
        page_count = 1
        next_token = ""
        
        while True:
            # flush=True and \r overwrite the line in Termux so you see real-time progress without terminal spam
            print(f"     [*] Fetching page {page_count} (Scanned {total_commits_scanned} commits)...", end="\r", flush=True)
            
            # Construct standard Gitiles API URL (n=500 per request)
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
                
                # Apply the strict regex search
                match = tag_pattern.search(message)
                if match:
                    kernel_version = match.group(1) # Extracts the X.Y.Z part
                    
                    # Validation & Locking
                    if kernel_version.startswith(f"{base}."):
                        if kernel_version not in seen_kernels:
                            seen_kernels.add(kernel_version)
                            branch_tag_count += 1
                            
                            database[base].append({
                                "kernel": kernel_version,
                                "date": b["date"],
                                "android_version": b["android_ver"]
                            })
                            # Print a new line to preserve the visual log of what was found
                            print(f"\n        [+] Locked version {kernel_version}!")
                            
                            # Check if there is another page of commits
            next_token = log_data.get("next")
            if not next_token:
                break
                
            # --- NEW CAP LOGIC ---
            if total_commits_scanned >= 30000:
                print(f"\n     [!] Reached 30,000 commit cap. Halting deep upstream crawl.")
                break
                
            page_count += 1
                
        print(f"\n     [=] Finished {b['branch']}: Locked {branch_tag_count} version(s) out of {total_commits_scanned} commits.")

    # 5. Sort final arrays numerically and write file
    print(f"\n[*] Sorting final database chronologically and writing to {DB_FILE}...")
    
    for base in database:
        database[base].sort(key=lambda x: [int(p) for p in x["kernel"].split('.')])

    with open(DB_FILE, "w") as f:
        json.dump(database, f, indent=2)
        
    print(f"[*] Success! {DB_FILE} generated.")

if __name__ == "__main__":
    main()
