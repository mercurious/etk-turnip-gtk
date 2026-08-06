#!/usr/bin/env bash
# ETK Stage IV — Turnip (Mesa) ROCKNIX/RPCS3 build (glibc/msm/wayland).
# Runs INSIDE the native-arm64 'turnip-rocknix' container (NO Rosetta; ROCKNIX is aarch64).
# Lighter than ROCKNIX buildroot: builds vanilla mesa in a generic arm64 container and relies on
#   - glibc forward-compat (built on 2.39 -> runs on ROCKNIX 2.41), and
#   - SONAME compat (libdrm.so.2 / libwayland-client.so.0 exist on ROCKNIX).
# MUST be validated by actually loading on a COLD-booted rig (always-reboot doctrine).
set -euo pipefail

MESA_VER="${MESA_VER:-26.1.3}"
JOBS="${JOBS:-4}"
WORK=/work
cd "$WORK"

# --- Mesa source ---
if [ ! -d "$WORK/mesa-$MESA_VER" ]; then
  echo ">> downloading mesa $MESA_VER tarball"
  curl -fL --retry 3 -o mesa.tar.xz "https://archive.mesa3d.org/mesa-$MESA_VER.tar.xz"
  tar -xf mesa.tar.xz && rm -f mesa.tar.xz
fi
cd "$WORK/mesa-$MESA_VER"

# --- configure: Vulkan-only freedreno, msm kmd, wayland+x11 WSI ---
rm -rf build-rocknix
meson setup build-rocknix \
  -Dbuildtype=release \
  -Dplatforms=wayland,x11 \
  -Dvulkan-drivers=freedreno \
  -Dgallium-drivers= \
  -Dfreedreno-kmds=msm \
  -Dvideo-codecs= \
  -Dglx=disabled -Degl=disabled -Dgbm=disabled -Dllvm=disabled \
  -Db_lto=false -Dstrip=false

ninja -C build-rocknix -j"$JOBS" src/freedreno/vulkan/libvulkan_freedreno.so

# --- versioned outputs ---
OUT="$WORK/out"; mkdir -p "$OUT"
RAW="$OUT/libvulkan_freedreno-rocknix-$MESA_VER.so"
STRIPPED="$OUT/libvulkan_freedreno-rocknix-$MESA_VER.stripped.so"
cp build-rocknix/src/freedreno/vulkan/libvulkan_freedreno.so "$RAW"
cp "$RAW" "$STRIPPED"; strip "$STRIPPED"

# --- ICD JSON for /storage override on the rig (VK_DRIVER_FILES points here) ---
cat > "$OUT/freedreno_icd.rocknix.json" <<JSON
{
    "file_format_version": "1.0.0",
    "ICD": {
        "library_path": "/storage/turnip/libvulkan_freedreno.so",
        "api_version": "1.4.303"
    }
}
JSON

echo ">> BUILT ROCKNIX $MESA_VER"
ls -la "$RAW" "$STRIPPED"
file "$RAW"
echo ">> ICD loader symbols (expect vk_icdGetInstanceProcAddr + vk_icdNegotiateLoaderICDInterfaceVersion):"
nm -D --defined-only "$RAW" | grep -iE 'vk_icdGetInstanceProcAddr|vk_icdNegotiateLoaderICDInterfaceVersion' || echo '!!! ICD SYMBOLS MISSING'
echo ">> NEEDED libs (each must exist on ROCKNIX):"
readelf -d "$RAW" | grep NEEDED
