# Universal GKI Kernel Builder CI
### (Pure GKI 2.0 only)

Welcome to the Universal GKI Kernel Builder! This repository hosts an automated, highly flexible GitHub Actions CI pipeline designed to compile custom GKI kernels directly from source.

Whether you need a pristine upstream kernel or a customized build featuring SuSFS, KernelPatch (KPM), NoMount VFS, network optimizations, or spoofed `uname` strings, this pipeline builds exactly what you want, right when you want it.

## 🚀 Overview

The core philosophy of this project is **Dynamic Generation over Bulk Compilation**.

Unlike massive kernel distribution repositories that compile hundreds of generic permutations on a fixed schedule, this CI is designed to be a personal build engine. When you trigger a workflow, the pipeline resolves the exact Google manifest branch (via `tools/master_kernel_db.json` with automatic LTS fallback), fetches the source for your chosen root environment, and integrates patches and config overrides on the fly.

The result is a single, tailor-made kernel artifact paired with its matching Manager APK.

### ✨ Advantages
* **No Waiting for Updates:** No need to wait for a maintainer to trigger a batch build. When Google drops a new GKI update or a root manager pushes a new commit, you can compile immediately.
* **Three Build Channels (`stable`, `dynamic`, `main`):** Build from verified, safe forks by default (`stable`), pull bleeding-edge upstream commits on demand (`dynamic`), or build kernel root without SuSFS (`main`).
* **Precision Output:** Instead of sifting through hundreds of zips, the CI builds only the exact target version and root configuration you request.
* **Matched Manager APKs:** Automatically resolves and packages the matching Manager APK alongside your kernel build (with multi-source fallbacks where needed, including Forgejo/CNB/GitHub for SukiSU-Nova).
* **Built-In OTA Validation:** Pre-validates any supplied OTA URL for `payload.bin` compatibility before starting a full kernel compile.

## ⚙️ Features
* **Multiple Root Managers:** Native integration support for `KernelSU-Next`, `SukiSU-Nova`, `BakaSU`, and `KernelSU`.
* **Automatic KPM Injection (SukiSU-Nova):** Automatically extracts `kpimg`, compiles `kptools` from source, and patches the compiled kernel `Image` for KernelPatch Module (KPM) support.
* **Smart Stock Isolation:** Select `Stock` to build from a pristine Google source tree without root source code—ideal for APatch or Magisk users who want custom Kconfigs or network tweaks baked in.
* **SuSFS Integration:** Automated common-side SuSFS patching and rejection handling across GKI branches (`5.10` / Android 12 through `6.18` / Android 17).
* **NoMount VFS:** Automatically pulls the latest `nomount.c` and `nomount.h` from `maxsteeel/nomount`, wires them into the kernel build, and bundles the latest flashable `NoMount-KSU-Module` artifact.
* **Network Optimizations:** One-click injection of BBR congestion control, CAKE queuing, TCP FastOpen, and ECN, along with version-aware user patches.
* **Custom `uname` Identity:** Optionally override the kernel release suffix (`uname -r`) and build timestamp (`uname -v`), or leave blank to preserve the official Google kernel commit hash and timestamp.
* **Flexible Packaging:** Outputs a ready-to-flash `AnyKernel3` (AK3) zip by default. Supply a direct full OTA ZIP URL to extract the stock `boot.img`, swap in the compiled `Image` with `magiskboot`, and package both the repacked `boot.img` and an AK3 zip.

---

## 🛠️ How to Use

### 1. Fork the Repository
Click the **Fork** button at the top right of this page to create your own copy of the repository.

### 2. Add Your Custom Files (Optional)
If you want to customize the build beyond the workflow toggles, place your files in these directories before triggering a run:
* **Custom Kconfigs:** Edit or uncomment flags in `tools/net_opts.fragment` (e.g., `CONFIG_TCP_CONG_BBR=y`).
* **User Patches:** Drop `.patch` files into `tools/user_patches/` (applied when **Inject Network Optimizations** is enabled). Patches prefixed with a base version (e.g., `6.1-fix.patch`) apply only to that branch; unprefixed patches apply generically across versions.
* **User Source:** Drop raw driver files or source overrides into `tools/user_source/` (injected into `common/` when **Inject nomount VFS module** or **Inject Network Optimizations** is enabled). *(Note: NoMount source files are fetched automatically when NoMount is enabled.)*

### 3. Enable GitHub Actions
In your forked repository, navigate to the **Actions** tab and click **"I understand my workflows, go ahead and enable them"**.

### 4. Trigger a Build
1. On the **Actions** tab, select **Universal GKI Kernel Builder CI** from the left sidebar.
2. Click the **Run workflow** dropdown on the right side of the screen.
3. Configure your build parameters:

| Parameter | Description |
| :--- | :--- |
| **Build Channel** | Choose `stable` (default — verified fork branches with SuSFS), `dynamic` (bleeding-edge upstream commits with SuSFS), or `main` (kernel root without SuSFS). |
| **Build Name** | A custom label for the workflow run and OTA-repacked artifact zip (e.g., `Pixel_9_Pro_6.1.162`). |
| **Kernel Version** | The target GKI version to build (e.g., `6.1.162`, `6.12.81`). Mapped via `tools/master_kernel_db.json`, falling back to the corresponding LTS branch for `5.10`–`6.18`. |
| **Root Environment** | Choose `KernelSU-Next`, `SukiSU-Nova`, `BakaSU`, `KernelSU`, or `Stock`. |
| **Integrate Root Manager and SUSFS?** | Enabled by default. Injects the selected root manager and SuSFS *(ignored when `Stock` is selected; select the `main` channel to integrate root without SuSFS)*. |
| **Inject Network Optimizations (BBR, CAKE, FastOpen, ECN)** | Enables network optimization configs, injects `tools/user_source/`, and applies matching patches from `tools/user_patches/`. |
| **Inject nomount VFS module** | Fetches the latest NoMount kernel source, compiles it into the kernel, and downloads the latest `NoMount-KSU-Module` release artifact. |
| **Full OTA ZIP URL (Optional)** | Leave blank to output a standalone `AnyKernel3` zip (`<RootManager>-<Version>-AK3`). Provide a direct full OTA ZIP URL to output a repacked `boot.img`, an AK3 zip, and `repack_metadata.txt`. |
| **Custom `uname -r` (Optional)** | Override the kernel release hash/build suffix (e.g., `6.1.162-android14-11-g9dd05ae3a1de-ab16261587`). Leave blank to use the synced Google commit hash. |
| **Custom `uname -v` (Optional)** | Override the kernel build timestamp using a `uname -v` string (e.g., `#1 SMP PREEMPT Thu Sep  3 03:59:00 UTC 2026`) or Unix epoch. Leave blank to use the synced Google commit date. |

4. Click **Run workflow**.

### 5. Download Your Artifacts
Once the workflow completes, scroll to the **Artifacts** section at the bottom of the run summary page:
* **Kernel Artifact:** Either `<RootManager>-<KernelVersion>-AK3` (standalone AnyKernel3 zip) or `<BuildName>` (containing the repacked `boot.img`, AK3 zip, and `repack_metadata.txt` when an OTA URL is provided).
* **Manager APK (`<RootManager>-Manager`):** The matching Manager APK for your chosen root environment.
* **NoMount Module (`NoMount-KSU-Module`):** Included whenever NoMount VFS is enabled.

Download your artifacts, flash via Kernel Flasher, custom recovery, or fastboot, and enjoy!
