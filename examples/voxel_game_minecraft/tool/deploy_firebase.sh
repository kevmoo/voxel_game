#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

PROJECT_ID="j832-com"
APP_ID="1:915141274861:web:dc3515c255ed6f573930e4"
GIT_SHA="$(git rev-parse --short HEAD)"
APP_VERSION="${APP_VERSION:-0.1.0+${GIT_SHA}}"

if [[ -z "${FIREBASE_API_KEY:-}" ]]; then
  FIREBASE_API_KEY="$(
    GOOGLE_CLOUD_QUOTA_PROJECT="${PROJECT_ID}" \
      firebase apps:sdkconfig WEB "${APP_ID}" --project "${PROJECT_ID}" --json \
      | jq -r '.result.sdkConfig.apiKey'
  )"
fi

echo "==> Compiling Web Worker (web/worker.dart -> web/worker.wasm) with source maps..."
dart compile wasm -O2 --no-strip-wasm web/worker.dart -o web/worker.wasm

echo "==> Building Flutter Web (--wasm --source-maps --web-content-hash) for version ${APP_VERSION}..."
flutter build web \
  --wasm \
  --source-maps \
  --web-content-hash \
  --no-web-resources-cdn \
  --dart-define="APP_VERSION=${APP_VERSION}" \
  --dart-define="FIREBASE_API_KEY=${FIREBASE_API_KEY}"

# Keep web/ clean in git while leaving build/web/worker.wasm.map for upload_sourcemaps.
rm -f web/worker.wasm.map web/worker.support.js

echo "==> Uploading Wasm sourcemaps to Firebase Crashlytics (${PROJECT_ID})..."
GOOGLE_CLOUD_QUOTA_PROJECT="${PROJECT_ID}" dart run web_crashlytics:upload_sourcemaps build/web \
  --project "${PROJECT_ID}" \
  --app "${APP_ID}" \
  --app-version "${APP_VERSION}"

echo "==> Deploying to Firebase Hosting (https://voxel-j832.web.app)..."
GOOGLE_CLOUD_QUOTA_PROJECT="${PROJECT_ID}" firebase deploy --only hosting --project "${PROJECT_ID}"
