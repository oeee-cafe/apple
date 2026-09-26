#!/bin/sh
# Xcode Cloud runs this after each action. After an archive, it uploads the
# archive's dSYMs (and the sources they point at) to Sentry, so crashes from
# TestFlight and the App Store come back symbolicated.
#
# The workflow needs SENTRY_AUTH_TOKEN as a secret environment variable; without
# it the upload is skipped. A failed upload doesn't fail the build.
set -u

[ -n "${CI_ARCHIVE_PATH:-}" ] || exit 0

if [ -z "${SENTRY_AUTH_TOKEN:-}" ]; then
  echo "SENTRY_AUTH_TOKEN isn't set; not uploading dSYMs to Sentry"
  exit 0
fi

brew install getsentry/tools/sentry-cli || exit 0
sentry-cli debug-files upload \
  --org limeburst \
  --project oeee-cafe-ios \
  --include-sources \
  "$CI_ARCHIVE_PATH/dSYMs" ||
  echo "Uploading dSYMs to Sentry failed"
