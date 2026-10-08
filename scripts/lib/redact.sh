#!/usr/bin/env bash
# lib/redact.sh — redact(): masks common secret shapes in model output (stdin → stdout).

redact() {
  sed \
    -e 's/re_[A-Za-z0-9_-]\{8,\}/***REDACTED***/g' \
    -e 's/sk-[A-Za-z0-9_-]\{8,\}/***REDACTED***/g' \
    -e 's/y0_[A-Za-z0-9_-]\{8,\}/***REDACTED***/g' \
    -e 's/eyJ[A-Za-z0-9_=+/-]\{10,\}/***REDACTED***/g' \
    -e 's/sbp_[A-Za-z0-9_-]\{8,\}/***REDACTED***/g' \
    -e 's/ghp_[A-Za-z0-9_-]\{8,\}/***REDACTED***/g' \
    -e 's/AKIA[A-Z0-9]\{16,\}/***REDACTED***/g' \
    -e 's,://[^:/@[:space:]]*:[^@[:space:]]*@,://***:***@,g' \
    -e 's/\(KEY=\)[^[:space:]"'"'"']*/\1***REDACTED***/gI' \
    -e 's/\(SECRET=\)[^[:space:]"'"'"']*/\1***REDACTED***/gI' \
    -e 's/\(TOKEN=\)[^[:space:]"'"'"']*/\1***REDACTED***/gI' \
    -e 's/\(PASSWORD=\)[^[:space:]"'"'"']*/\1***REDACTED***/gI'
}
