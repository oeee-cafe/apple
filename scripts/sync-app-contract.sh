#!/bin/sh
# Copies the site's app contract (frontend/shared/appContract.json in
# oeee-cafe/web) into the test target, where OeeeCafeTests reads it: every
# message the page sends, the user agents and the marks the site makes of them,
# the window.oeeeApp members an app may call, the site's command names, and the
# two scripts every app runs around leaving a page.
#
# The site's checkout is taken to sit beside this one; set OEEE_CAFE_WEB to use
# another (a worktree of either, say):
#
#   OEEE_CAFE_WEB=~/Git/oeee-cafe-web scripts/sync-app-contract.sh
#
# Then run the tests, and commit the copy with whatever the change needed.
set -eu

root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
web=${OEEE_CAFE_WEB:-$root/../oeee-cafe-web}
source=$web/frontend/shared/appContract.json
target=$root/OeeeCafeTests/appContract.json

if [ ! -f "$source" ]; then
  echo "No contract at $source; set OEEE_CAFE_WEB to the site's checkout." >&2
  exit 1
fi

cp "$source" "$target"
echo "Copied $source"
git -C "$root" diff --stat -- OeeeCafeTests/appContract.json
