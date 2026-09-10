#!/bin/sh
# ==============================================================================
# JD2CaptchaSolver - In-Container Installer for jlesage/jdownloader-2
# Repository: https://github.com/DevDrake/JD2CaptchaSolver
# ==============================================================================
set -e

REPO_URL="https://github.com/DevDrake/JD2CaptchaSolver.git"
BRANCH="${BRANCH:-master}"
JD2_CONFIG_DIR="/config"

echo "========================================================"
echo " JD2CaptchaSolver Installer for jlesage/jdownloader-2"
echo " Repository: $REPO_URL"
echo " Branch:     $BRANCH"
echo "========================================================"

# 1. Verify root privileges
if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: This installation script must be run as root." >&2
    echo "Please re-run using root user in Docker:" >&2
    echo "  docker exec -u 0 -it <container_name> sh" >&2
    exit 1
fi

# 2. Verify Alpine Linux
if [ ! -f /etc/alpine-release ]; then
    echo "WARNING: /etc/alpine-release not found. Proceeding with Alpine package manager..."
fi

# 3. Verify JDownloader config directory exists
if [ ! -d "$JD2_CONFIG_DIR" ]; then
    echo "ERROR: Target directory '$JD2_CONFIG_DIR' not found." >&2
    echo "Ensure you are running inside the jlesage/jdownloader-2 container." >&2
    exit 1
fi

# 4. Install system packages via apk
echo "[1/6] Installing system dependencies (Node.js, npm, compiler)..."
apk update
apk add --no-cache \
    nodejs \
    npm \
    build-base \
    cmake \
    git \
    libstdc++ \
    ca-certificates \
    dos2unix

# 5. Compile Darknet from source natively (for AMD64 or ARM64)
echo "[2/6] Compiling Darknet natively from source for this architecture..."
TMP_DARKNET_DIR="/tmp/darknet_build"
rm -rf "$TMP_DARKNET_DIR"
git clone --depth 1 https://github.com/AlexeyAB/darknet.git "$TMP_DARKNET_DIR"
cd "$TMP_DARKNET_DIR"

# Patch musl compatibility: guard glibc-specific execinfo.h and strip -Wfatal-errors
sed -i '/<execinfo\.h>/d' src/utils.c
sed -i 's/#if !defined(WIN32) && !defined(__ANDROID__)/#if 0/' src/utils.c
sed -i 's/-Wfatal-errors//g' CMakeLists.txt

cmake -B build_cmake \
    -DCMAKE_BUILD_TYPE=Release \
    -DENABLE_CUDA=OFF \
    -DENABLE_OPENCV=OFF \
    -DENABLE_CUDNN=OFF \
    -DENABLE_SSE_AND_AVX_FLAGS=OFF \
    -DBUILD_SHARED_LIBS=OFF \
    -DBUILD_USELIB_TRACK=OFF

NPROC=$(nproc 2>/dev/null || echo 1)
cmake --build build_cmake --target darknet -j"$NPROC"

DARKNET_BIN="build_cmake/darknet"
if [ ! -f "$DARKNET_BIN" ]; then
    echo "ERROR: Darknet compilation failed. 'darknet' binary was not produced." >&2
    exit 1
fi
echo "Darknet compiled successfully: $DARKNET_BIN"

# 6. Fetch JD2CaptchaSolver from DevDrake/JD2CaptchaSolver
echo "[3/6] Fetching JD2CaptchaSolver repository..."
TMP_SOLVER_DIR="/tmp/JD2CaptchaSolver"
rm -rf "$TMP_SOLVER_DIR"
git clone --depth 1 -b "$BRANCH" "$REPO_URL" "$TMP_SOLVER_DIR"

# 7. Install into JDownloader directories
echo "[4/6] Installing solver files into $JD2_CONFIG_DIR..."
mkdir -p "$JD2_CONFIG_DIR/jd/captcha/methods"
mkdir -p "$JD2_CONFIG_DIR/tools/offlineCaptchaSolver"

cp -rf "$TMP_SOLVER_DIR/JDownloader 2.0/jd/captcha/methods/." "$JD2_CONFIG_DIR/jd/captcha/methods/"
cp -rf "$TMP_SOLVER_DIR/JDownloader 2.0/tools/offlineCaptchaSolver/." "$JD2_CONFIG_DIR/tools/offlineCaptchaSolver/"

# Replace darknet binary with the natively compiled binary
cp -f "$DARKNET_BIN" "$JD2_CONFIG_DIR/tools/offlineCaptchaSolver/darknet64/darknet"

# Remove unnecessary Windows binaries to save space in /config
rm -f "$JD2_CONFIG_DIR/tools/offlineCaptchaSolver/node.exe"
rm -f "$JD2_CONFIG_DIR/tools/offlineCaptchaSolver/darknet64/"*.exe
rm -f "$JD2_CONFIG_DIR/tools/offlineCaptchaSolver/darknet64/"*.dll
rm -f "$JD2_CONFIG_DIR/tools/offlineCaptchaSolver/result.txt"
rm -f "$JD2_CONFIG_DIR/tools/offlineCaptchaSolver/log.txt"
rm -f "$JD2_CONFIG_DIR/tools/offlineCaptchaSolver/solver.log"

# 8. Install production npm dependencies
echo "[5/6] Installing Node.js production dependencies..."
cd "$JD2_CONFIG_DIR/tools/offlineCaptchaSolver"
npm ci --production || npm install --production

# 9. Set permissions, line endings, and ownership
echo "[6/6] Finalizing permissions and line endings..."
sed -i 's/\r$//' "$JD2_CONFIG_DIR/tools/offlineCaptchaSolver/"*.sh 2>/dev/null || true
dos2unix "$JD2_CONFIG_DIR/tools/offlineCaptchaSolver/"*.sh 2>/dev/null || true
chmod +x "$JD2_CONFIG_DIR/tools/offlineCaptchaSolver/"*.sh
chmod +x "$JD2_CONFIG_DIR/tools/offlineCaptchaSolver/darknet64/darknet"

TARGET_UID="${USER_ID:-$(stat -c '%u' "$JD2_CONFIG_DIR" 2>/dev/null || echo 1000)}"
TARGET_GID="${GROUP_ID:-$(stat -c '%g' "$JD2_CONFIG_DIR" 2>/dev/null || echo 1000)}"
chown -R "$TARGET_UID:$TARGET_GID" "$JD2_CONFIG_DIR/tools/offlineCaptchaSolver" "$JD2_CONFIG_DIR/jd/captcha/methods"

# Create s6 init script so container restarts preserve permissions
if [ -d /etc/cont-init.d ]; then
    cat << 'EOF' > /etc/cont-init.d/99-captchasolver.sh
#!/bin/sh
TARGET_UID="${USER_ID:-$(stat -c '%u' /config 2>/dev/null || echo 1000)}"
TARGET_GID="${GROUP_ID:-$(stat -c '%g' /config 2>/dev/null || echo 1000)}"
if [ -d /config/tools/offlineCaptchaSolver ]; then
    rm -f /config/tools/offlineCaptchaSolver/result.txt /config/tools/offlineCaptchaSolver/log.txt /config/tools/offlineCaptchaSolver/solver.log 2>/dev/null || true
    sed -i 's/\r$//' /config/tools/offlineCaptchaSolver/*.sh 2>/dev/null || true
    chmod +x /config/tools/offlineCaptchaSolver/*.sh 2>/dev/null || true
    chmod +x /config/tools/offlineCaptchaSolver/darknet64/darknet 2>/dev/null || true
    chown -R "$TARGET_UID:$TARGET_GID" /config/tools/offlineCaptchaSolver /config/jd/captcha/methods 2>/dev/null || true
fi
EOF
    chmod +x /etc/cont-init.d/99-captchasolver.sh
fi

# Cleanup build artifacts and compilers to reclaim disk space
echo "Cleaning up temporary build artifacts..."
rm -rf "$TMP_DARKNET_DIR" "$TMP_SOLVER_DIR"
apk del build-base cmake git 2>/dev/null || true

echo ""
echo "========================================================"
echo " JD2CaptchaSolver installed successfully!"
echo "========================================================"
echo "To start using the solver:"
echo "1. Restart JDownloader 2 via the Web UI (File -> Restart),"
echo "   OR restart the Docker container from your host:"
echo "   docker restart <container_name>"
echo "========================================================"
