#!/bin/bash
set -euo pipefail
# Pin runtime AND its patched ggml. Do not use llama's incompatible ggml implementation.
SD_REV=0e1d733b7ad9268b80171597ae84cae26353f3fa
GGML_REV=d25b121ce1d6ae0c7e62ad080460d9fc1e46dd93
ROOT="$PWD"
git init sd-src
git -C sd-src remote add origin https://github.com/leejet/stable-diffusion.cpp.git
git -C sd-src fetch --depth 1 origin "$SD_REV"
git -C sd-src checkout FETCH_HEAD
git -C sd-src submodule update --init --depth 1 ggml
test "$(git -C sd-src/ggml rev-parse HEAD)" = "$GGML_REV"
cp Native/PhoneDiffusion.cpp Native/PhoneDiffusion.h sd-src/
cp Native/exports.txt sd-src/
# A separate framework with an explicit export allowlist isolates every ggml symbol
# from the existing statically linked llama/mtmd engine. Both remain in the app.
python3 - <<'PY'
from pathlib import Path
p=Path('sd-src/CMakeLists.txt')
p.write_text(p.read_text()+'''
add_library(PhoneDiffusion SHARED PhoneDiffusion.cpp)
target_link_libraries(PhoneDiffusion PRIVATE stable-diffusion "-framework CoreGraphics" "-framework ImageIO" "-framework Foundation")
set_target_properties(PhoneDiffusion PROPERTIES
    FRAMEWORK TRUE FRAMEWORK_VERSION A
    MACOSX_FRAMEWORK_IDENTIFIER com.neo664evr.PhoneDiffusion
    MACOSX_FRAMEWORK_SHORT_VERSION_STRING 6.2
    MACOSX_FRAMEWORK_BUNDLE_VERSION 17
    INSTALL_NAME_DIR "@rpath" BUILD_WITH_INSTALL_NAME_DIR TRUE
    XCODE_ATTRIBUTE_CODE_SIGNING_ALLOWED NO
    XCODE_ATTRIBUTE_CODE_SIGNING_REQUIRED NO)
target_link_options(PhoneDiffusion PRIVATE "-Wl,-exported_symbols_list,${CMAKE_CURRENT_SOURCE_DIR}/exports.txt")
''')
PY
cmake -S sd-src -B sd-src/build-ios -G Xcode \
  -DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_DEPLOYMENT_TARGET=17.0 \
  -DCMAKE_OSX_ARCHITECTURES=arm64 \
  -DCMAKE_XCODE_ATTRIBUTE_CODE_SIGNING_ALLOWED=NO \
  -DCMAKE_XCODE_ATTRIBUTE_CODE_SIGNING_REQUIRED=NO \
  -DCMAKE_C_VISIBILITY_PRESET=hidden -DCMAKE_CXX_VISIBILITY_PRESET=hidden \
  -DCMAKE_VISIBILITY_INLINES_HIDDEN=ON \
  -DBUILD_SHARED_LIBS=OFF -DSD_BUILD_SHARED_LIBS=OFF \
  -DSD_BUILD_EXAMPLES=OFF -DSD_WEBP=OFF -DSD_WEBM=OFF \
  -DSD_METAL=ON -DGGML_METAL_EMBED_LIBRARY=ON -DGGML_ACCELERATE=ON \
  -DGGML_NATIVE=OFF
cmake --build sd-src/build-ios --config Release --target PhoneDiffusion -j 4
mkdir -p vendor-diffusion/include
cp Native/PhoneDiffusion.h vendor-diffusion/include/
FRAMEWORK=$(find sd-src/build-ios -name PhoneDiffusion.framework -type d | head -1)
test -n "$FRAMEWORK"
cp -R "$FRAMEWORK" vendor-diffusion/
BINARY=vendor-diffusion/PhoneDiffusion.framework/PhoneDiffusion
# Assert the only externally exported symbols belong to our C bridge, never ggml/sd.
nm -gjU "$BINARY" > "$RUNNER_TEMP/diffusion-exports.txt"
python3 - <<'PY'
import os
from pathlib import Path
exports=Path(os.environ['RUNNER_TEMP']+'/diffusion-exports.txt').read_text().splitlines()
assert exports and all(s.startswith('_cpd_') for s in exports), exports
assert '_cpd_generate' in exports and '_cpd_load' in exports
print('Isolated native diffusion exports:', exports)
PY
otool -L "$BINARY"
