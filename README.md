# Universal GKI Kernel Builder CI

An automated GitHub Actions workflow for building custom Android Generic Kernel Images (GKI). While explicitly tested on the Pixel 6 and Pixel 9/10 Pro XL, this pipeline is designed to be highly compatible with **any device that supports standard GKI architectures**.

This runner caters to advanced kernel modifications, supporting automated pulling, patching, and repacking of boot images. It is completely modular and engineered to seamlessly bypass restrictive build environments (like Bazel's strict sandboxing) to inject root solutions, mask modifications, and compile network/performance modules.

## Core Features

* **Automated Source Syncing:** Fetches pure AOSP/Pixel kernel branches directly from Google's manifest.
* **Hermetic Sandbox Bypass (The "Gatekeeper"):** Uses preemptive GNU Make `override` directives to completely bypass the Kleaf/Bazel sandbox. This mathematically locks the Kernel to the exact Git commit counts of the upstream root managers without relying on brittle regex hacks.
* **Native Multi-Variant Root Integration:** Automated cloning and native variable injection for **KernelSU**, **KernelSU-Next**, **SukiSU-Ultra**, and **ReSukiSU**. The pipeline feeds raw Git data to the compiler, allowing each fork to seamlessly calculate its own unique offset math for perfect version parity.
* **Zero-Touch Manager Synchronization:** The pipeline automatically tracks the upstream divergence point, queries the GitHub API, and downloads the exact matching Manager APK for your specific kernel build. No more version mismatch errors.
* **Resilient WireGuard Integration:** Injects WireGuard and Android Netd routing hooks while relying on the Linux kernel's internal dependency resolver to pull NEON hardware crypto accelerations. This future-proofs the build against fatal Strict Fragment Checking crashes on 6.12+ kernels.
* **Rejection Resolution & SUSFS:** Built-in hooks to automatically resolve known SUSFS patch rejections in the common tree.
* **Environment Sanitizing:** Neutralizes ABI protected exports and uses the official Google commit hash and Unix timestamp to facilitate build environment and kernel string integrity.
* **Targeted Payload Extraction:** Scans the remote OTA URL and streams only the `boot` partition directly from the source via `payload_dumper`, completely bypassing the need to download the massive multi-gigabyte OTA ZIP.
* **Automated Packaging:** Hot-swaps the compiled kernel `Image` into the stock boot image using `magiskboot`, or automatically generates an AnyKernel3 flashable zip if no OTA is provided.

## Workflow Inputs

Trigger the workflow manually via the **Actions** tab. The pipeline accepts the following variables:

| Input | Default | Description |
| :--- | :--- | :--- |
| `build_name` | `""` | (Required) Identifier for the build artifact (e.g., `komodo-cp1a`). |
| `root_manager` | `KernelSU-Next` | Select the Root Environment to integrate (`KernelSU`, `KernelSU-Next`, `SukiSU-Ultra`, `ReSukiSU`). |
| `enable_ksu_susfs` | `true` | Toggles root manager and SUSFS integrations. Uncheck for a pure stock build. |
| `target_version` | `""` | (Required) The specific kernel version to target. The pipeline automatically resolves this to the correct manifest branch. |
| `ota_url` | `""` | Direct link to the official OTA `.zip`. Required if you want the runner to automatically repack the kernel into a flashable `boot.img`. |
| `build_wg` | `false` | Injects custom Kconfig integrations (Bazel fragments or legacy Make) to compile WireGuard natively into the kernel. |

> **Note on Repacking:** If an `ota_url` is omitted or invalid, or the ZIP does not contain a standard `payload.bin` at its root, the runner will automatically degrade gracefully to generating an AnyKernel3 (AK3) flashable zip containing your compiled kernel `Image`, completely skipping the stock boot image repacking phase.

## Artifacts & Installation

Because custom root forks frequently update their API protocols, this pipeline dynamically locks the CI version strings to the exact upstream commit prior to custom modifications. 

You no longer need to hunt for the correct Manager APK. The CI handles version symmetry automatically.

1. Once the GitHub Action completes successfully, click on the workflow run.
2. Scroll down to the **Artifacts** section.
3. Download your compiled kernel artifact (either the repacked `boot.img` or the `AK3` zip).
4. Download the `*-Manager` artifact. This is the exact Manager APK compiled from the synced upstream commit. Install this APK to ensure perfect synchronization with your newly flashed kernel.

## Repository Structure

The workflow delegates tasks to specialized scripts to keep the YAML clean and highly modular:

* `scripts/build_kernel.sh`: Wraps the Kleaf/Bazel build process (with a legacy 5.10 Hermetic Make fallback), injects Google identity cloaking variables, and outputs a WireGuard configuration validation report.
* `scripts/configure_kconfigs.sh`: Neutralizes ABI protected exports and securely injects Kconfig fragments for WireGuard, relying on native Kconfig logic to resolve dependencies.
* `scripts/inject_ksu_variant.sh`: Handles cloning of your chosen Root Manager variant and utilizes the "Gatekeeper" GNU Make overrides to feed native versioning math to the compiler, completely bypassing the Kleaf sandbox.
* `scripts/integrate_susfs_next.sh`: Clones the designated SUSFS variant and handles common-side file transfers and patching.
* `scripts/custom_patches.sh`: A blank canvas executed prior to compilation. Use this to apply standard kernel tweaks, such as custom CPU governors or scheduler modifications. 
* `scripts/fix_susfs_rejections.sh`: A targeted `sed` routine to force-inject SUSFS headers into `exec.c`, `base.c`, and `namespace.c` if standard patching fails.
* `scripts/validate_ota.py` & `scripts/ota_pull.py`: Evaluates the OTA URL and executes the payload extraction.
* `scripts/boot_swap.sh`: Wraps Magiskboot to unpack the stock image, swap the core kernel, and repack the final artifact.
