#!/usr/bin/env bash

# https://stackoverflow.com/questions/6570531/assign-string-containing-null-character-0-to-a-variable-in-bash
quote_nul() {
  sed 's/\\/\\\\/g;s/\x0/\\0/g'
}

printf '%s\0' "$@" | quote_nul
