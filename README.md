# Custom GKI CI/CD Runner

An automated GitHub Actions workflow for building custom Android Generic Kernel Images (GKI). While explicitly tested on the Pixel 6 and Pixel 9 Pro XL, this pipeline is designed to be highly compatible with **any device that supports standard GKI architectures**. 

This runner caters to advanced kernel modifications, supporting automated pulling, patching, and repacking of boot images. It is modular by design, allowing developers to inject root solutions, mask modifications, and compile network/performance modules seamlessly.

## Core Features

* **Automated Source Syncing:** Fetches pure AOSP/Pixel kernel branches directly from Google's manifest.
* **KernelSU-Next & SUSFS Integration:** Automated cloning, branch verification, and patching for kernel-level masking. 
* **Rejection Resolution:** Built-in hooks to automatically resolve known SUSFS patch rejections in the common tree.
* **Environment Sanitizing:** Neutralizes ABI protected exports and uses the official Google commit hash and Unix timestamp to facilitate build environment and kernel string integrity.
* **WireGuard Support:** Optional native WireGuard integration with ARM64 hardware crypto acceleration and Android Netd routing hooks.
* **Targeted Payload Extraction:** Scans the remote OTA URL and streams only the `boot` partition directly from the source via `payload_dumper`, completely bypassing the need to download the massive multi-gigabyte OTA ZIP.
* **Automated Repacking:** Hot-swaps the compiled kernel `Image` into the stock boot image using `magiskboot`.

## Workflow Inputs

Trigger the workflow manually via the **Actions** tab. The pipeline accepts the following variables:

| Input | Default | Description |
| :--- | :--- | :--- |
| `build_name` | `gki-custom` | Identifier for the build artifact (e.g., `komodo-cp1a`). |
| `enable_ksu_susfs` | `true` | Toggles KernelSU-Next and SUSFS integrations. Uncheck for a pure stock build. |
| `ota_url` | `""` | Direct link to the official OTA `.zip`. Required if you want the runner to automatically repack the kernel into a flashable `boot.img`. |
| `manifest_branch` | `common-android14-6.1-2025-09` | The kernel manifest branch (e.g., use `common-android15-6.6-2025-10` for the P10 series). |
| `susfs_branch` | `gki-android14-6.1-dev` | The specific SUSFS branch to pull. |
| `build_wg` | `false` | Injects Bazel fragments to compile WireGuard natively into the kernel. |

> **Note on Repacking:** If an invalid `ota_url` is provided, or the ZIP does not contain a standard `payload.bin` at its root, the runner will automatically degrade gracefully to an "Image-only" mode and skip the magiskboot repacking phase.

## Repository Structure

The workflow delegates tasks to specialized scripts to keep the YAML clean and modular:

* `scripts/build_kernel.sh`: Wraps the Kleaf/Bazel build process, injects WG fragments if requested, and handles identity cloaking.
* `scripts/custom_patches.sh`: A blank canvas executed prior to compilation. Use this to apply standard kernel tweaks, such as custom CPU governors or scheduler modifications. 
* `scripts/integrate_*.sh`: Handles the cloning, symlinking, and common-side patching for KSU and SUSFS.
* `scripts/fix_susfs_rejections.sh`: A targeted `sed` routine to force-inject SUSFS headers into `exec.c`, `base.c`, and `namespace.c` if standard patching fails.
* `scripts/validate_ota.py` & `scripts/ota_pull.py`: Evaluates the OTA URL and executes the payload extraction.
* `scripts/boot_swap.sh`: Wraps Magiskboot to unpack the stock image, swap the core kernel, and repack the final artifact.
* 
