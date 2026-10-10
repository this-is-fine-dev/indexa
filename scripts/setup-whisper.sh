#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/whisper-source .build/whisper-models
if [ ! -f .build/whisper-source/CMakeLists.txt ]; then
  curl --fail --location --retry 3 https://github.com/ggml-org/whisper.cpp/archive/927cfce34f31707e17f2bff35c349632fb9e2c3a.tar.gz -o .build/whisper-source.tar.gz
  tar -xzf .build/whisper-source.tar.gz --strip-components=1 -C .build/whisper-source
fi
cmake --fresh -S .build/whisper-source -B .build/whisper-build \
  -DCMAKE_APPLE_SILICON_PROCESSOR="$(uname -m)" -DCMAKE_OSX_ARCHITECTURES="$(uname -m)" \
  -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0 -DBUILD_SHARED_LIBS=OFF \
  -DWHISPER_BUILD_TESTS=OFF -DWHISPER_BUILD_SERVER=OFF -DGGML_METAL=ON -DGGML_NATIVE=OFF
cmake --build .build/whisper-build --target whisper-cli --config Release -j 6
if [ ! -f .build/whisper-models/ggml-small.bin ]; then
  curl --fail --location --retry 3 https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-small.bin -o .build/whisper-models/ggml-small.bin.download
  printf '%s\n' '1be3a9b2063867b937e64e2ec7483364a79917e157fa98c5d94b5c1fffea987b  .build/whisper-models/ggml-small.bin.download' | shasum -a 256 -c -
  mv .build/whisper-models/ggml-small.bin.download .build/whisper-models/ggml-small.bin
fi
printf 'Lokalny model Whisper Small (polski) jest gotowy.\n'
