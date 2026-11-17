#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"

dart --version
dart pub get
dart format test
dart test
dart analyze
