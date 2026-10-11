#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/whisper-source
if [ ! -f .build/whisper-source/CMakeLists.txt ]; then
  curl --fail --location --retry 3 https://github.com/ggml-org/whisper.cpp/archive/927cfce34f31707e17f2bff35c349632fb9e2c3a.tar.gz -o .build/whisper-source.tar.gz
  tar -xzf .build/whisper-source.tar.gz --strip-components=1 -C .build/whisper-source
fi
cmake --fresh -S .build/whisper-source -B .build/whisper-build \
  -DCMAKE_APPLE_SILICON_PROCESSOR="$(uname -m)" -DCMAKE_OSX_ARCHITECTURES="$(uname -m)" \
  -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0 -DBUILD_SHARED_LIBS=OFF \
  -DWHISPER_BUILD_TESTS=OFF -DWHISPER_BUILD_SERVER=OFF -DGGML_METAL=ON -DGGML_NATIVE=OFF
cmake --build .build/whisper-build --target whisper-cli --config Release -j 6
printf 'Lokalny silnik Whisper jest gotowy; model pobierze się osobno przy pierwszej transkrypcji.\n'
