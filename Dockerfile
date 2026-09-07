# ==============================================================================
# Multi-stage Dockerfile for JDownloader 2 with CaptchaSolver
# Supports AMD64 and ARM64 architectures
# ==============================================================================

# Stage 1: Build Darknet natively from source for Alpine musl
FROM alpine:3.19 AS darknet-builder

RUN apk add --no-cache \
    build-base \
    cmake \
    git

WORKDIR /tmp/darknet
RUN git clone --depth 1 https://github.com/AlexeyAB/darknet.git . \
    && cmake -B build \
        -DCMAKE_BUILD_TYPE=Release \
        -DENABLE_CUDA=OFF \
        -DENABLE_OPENCV=OFF \
        -DENABLE_CUDNN=OFF \
        -DENABLE_SSE_AND_AVX_FLAGS=OFF \
        -DBUILD_SHARED_LIBS=OFF \
        -DBUILD_USELIB_TRACK=OFF \
    && cmake --build build --target darknet -j$(nproc) \
    && cp $(find build -name darknet -type f) /tmp/darknet_binary

# Stage 2: Final runtime container extending jlesage/jdownloader-2
FROM jlesage/jdownloader-2:latest

RUN add-pkg nodejs npm libstdc++ dos2unix || apk add --no-cache nodejs npm libstdc++ dos2unix


# Copy the natively compiled Darknet binary
COPY --from=darknet-builder /tmp/darknet_binary /defaults/darknet

# Prepare directory for JD2CaptchaSolver defaults
RUN mkdir -p /defaults/JD2CaptchaSolver/jd/captcha/methods \
    && mkdir -p /defaults/JD2CaptchaSolver/tools/offlineCaptchaSolver

# Copy repository files into defaults
COPY ["JDownloader 2.0/jd/captcha/methods/", "/defaults/JD2CaptchaSolver/jd/captcha/methods/"]
COPY ["JDownloader 2.0/tools/offlineCaptchaSolver/", "/defaults/JD2CaptchaSolver/tools/offlineCaptchaSolver/"]

# Replace darknet with our musl-native compiled binary and remove Windows binaries
RUN cp /defaults/darknet /defaults/JD2CaptchaSolver/tools/offlineCaptchaSolver/darknet64/darknet \
    && rm -f /defaults/JD2CaptchaSolver/tools/offlineCaptchaSolver/node.exe \
    && rm -f /defaults/JD2CaptchaSolver/tools/offlineCaptchaSolver/darknet64/*.exe \
    && rm -f /defaults/JD2CaptchaSolver/tools/offlineCaptchaSolver/darknet64/*.dll

# Pre-install npm dependencies at image build time (no dynamic runtime install)
WORKDIR /defaults/JD2CaptchaSolver/tools/offlineCaptchaSolver
RUN npm ci --production

# Create s6 initialization script to populate /config and fix permissions
RUN printf '#!/bin/sh\n\
echo "[JD2CaptchaSolver] Initializing JD2CaptchaSolver in /config..."\n\
mkdir -p /config/jd/captcha/methods /config/tools/offlineCaptchaSolver\n\
cp -rf /defaults/JD2CaptchaSolver/jd/captcha/methods/. /config/jd/captcha/methods/\n\
cp -rf /defaults/JD2CaptchaSolver/tools/offlineCaptchaSolver/. /config/tools/offlineCaptchaSolver/\n\
cp -f /defaults/darknet /config/tools/offlineCaptchaSolver/darknet64/darknet\n\
dos2unix /config/tools/offlineCaptchaSolver/*.sh 2>/dev/null || true\n\
chmod +x /config/tools/offlineCaptchaSolver/*.sh\n\
chmod +x /config/tools/offlineCaptchaSolver/darknet64/darknet\n\
chown -R ${USER_ID:-1000}:${GROUP_ID:-1000} /config/tools/offlineCaptchaSolver /config/jd/captcha/methods\n\
echo "[JD2CaptchaSolver] Initialization complete."\n' > /etc/cont-init.d/99-captchasolver.sh \
    && chmod +x /etc/cont-init.d/99-captchasolver.sh

WORKDIR /config
