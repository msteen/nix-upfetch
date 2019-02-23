#!/usr/bin/env bash

nix-upfetch() {
  case $PWD in
    */nix-upfetch/src) ./main.sh "$@";;
    */nix-upfetch/lib) ../src/main.sh "$@";;
    */nix-upfetch) ./src/main.sh "$@";;
    *) command nix-upfetch "$@"
  esac
}

nix-preupfetch() {
  case $PWD in
    */nix-upfetch/src) ./prefetch.sh "$@";;
    */nix-upfetch/lib) ../src/prefetch.sh "$@";;
    */nix-upfetch) ./src/prefetch.sh "$@";;
    *) command nix-preupfetch "$@"
  esac
}
