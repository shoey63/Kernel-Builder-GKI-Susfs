import sys
import os
from remotezip import RemoteZip

def main():
    url = os.environ.get("OTA_URL", "").strip()
    github_env = os.environ.get("GITHUB_ENV")

    def set_repack_enabled(is_enabled):
        flag = "true" if is_enabled else "false"
        if github_env:
            with open(github_env, "a") as env_file:
                env_file.write(f"REPACK_ENABLED={flag}\n")

    # 1. Blank or Garbage format (Scenario: leaves blank or pastes garbage)
    if not url or not url.startswith("http") or not url.lower().endswith(".zip"):
        print("Invalid or empty - proceeding with Image generation only")
        set_repack_enabled(False)
        sys.exit(0)

    try:
        with RemoteZip(url) as z:
            files = z.namelist()
            
            # 2. Perfect match (Scenario: payload.bin in root)
            if "payload.bin" in files:
                print("Valid - proceeding with boot.img generation")
                set_repack_enabled(True)
                
            # 3. Nested payload (Scenario: payload.bin exists, but in a subfolder)
            elif any(f.endswith("payload.bin") for f in files):
                print("payload.bin not in root of zip - proceeding with Image generation only")
                set_repack_enabled(False)
                
            # 4. No payload at all (Scenario: Samsung Odin, Xiaomi Recovery, etc.)
            else:
                print("payload.bin not found - proceeding with Image generation only")
                set_repack_enabled(False)

    except Exception:
        # 5. Network errors, 404s, or server doesn't allow HTTP Range requests
        print("Bad address or not allowed - proceeding with Image generation only")
        set_repack_enabled(False)

if __name__ == "__main__":
    main()
