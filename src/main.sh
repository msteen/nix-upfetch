#!/usr/bin/env bash
# shellcheck disable=SC2015 disable=SC2119 disable=SC2120

# Tested succesfully with:
# set -euxo pipefail

## ##
## Configuration
## ##

lib='@lib@'
libredirect='@libredirect@'

## ##
## Helper functions
## ##

trap 'exit "$exit_code"' SIGHUP
exit_code=0
pid=$$

exit_script() {
  exit_code=$?
  (( $# >= 1 )) && exit_code=$1
  kill -SIGHUP -- "$pid"
}

die() {
  printf 'error: %s\n' "$*" >&2
  exit_script 1
}

# Allow the source to be used directly when developing.
# To prevent `--subst-var-by lib` from replacing the string literal in the equality check,
# the string literal for it has been broken up.
if [[ $lib == '@''lib''@' ]]; then
  case $PWD in
    */nix-upfetch/lib) lib=$PWD;;
    */nix-upfetch/src) lib=$(realpath "$PWD/../lib");;
    */nix-upfetch) lib=$PWD/lib;;
    *) die "The script backing nix-upfetch called from an unsupported location: ${PWD}."
  esac
fi

if [[ $libredirect == '@''libredirect''@' ]]; then
  libredirect=$(nix eval --raw nixpkgs.libredirect)
fi

die_usage() {
  { show_usage; printf '\n'; } >&2
  die "$@"
}

# https://stackoverflow.com/questions/6570531/assign-string-containing-null-character-0-to-a-variable-in-bash
quote_nul() {
  sed 's/\\/\\\\/g;s/\x0/\\x00/g'
}

unquote_nul() {
  echo -en "$1"
}

quote() {
  # shellcheck disable=SC1003
  grep -q '^[a-zA-Z0-9_\.-]\+$' <<< "$*" && printf '%s' "$*" || printf '%s' "'${*//'/\\'}'"
}

quote_args() {
  for arg in "$@"; do
    printf '%s ' "$(quote "$arg")"
  done
}

js_str() {
  jq --null-input --arg str "$*" '$str'
}

js_obj() {
  local i=$(( $# / 2 ))
  local names=( "${@:1:i}" ) values=( "${@:i+1}" )
  local obj='{'
  for i in "${!names[@]}"; do
    [[ $obj != '{' ]] && obj+=','
    obj+='"'${names[$i]}'": '$(js_str "${values[$i]}")
  done
  obj+='}'
  printf '%s' "$obj"
}

# Based on `escapeNixString`:
# https://github.com/NixOS/nixpkgs/blob/d4224f05074b6b8b44fd9bd68e12d4f55341b872/lib/strings.nix#L316
nix_str() {
  str=$(js_str "$*")
  printf '%s' "${str//\$/\\\$}"
}

nix_typed() {
  local type=$1 raw=$2
  case $type in
    expr) value="$raw";;
     str) value=$(nix_str "$raw");;
       *) die_usage "Unsupported expression type '${type}'.";;
  esac
  printf '%s' "$value"
}

show_usage() {
  { man --pager=cat nix-upfetch | col --no-backspaces --spaces || true; } | awk '
    $1 == "SYNOPSIS" { print "Usage:"; between=1; next }
    between && $1 ~ /^[A-Z]+$/ { exit }
    between == 1 { match($0, /^ */); between=2 }
    between && ! /^[[:space:]]*$/ { print "  " substr($0, RLENGTH + 1) }
  '
}

## ##
## Command line arguments
## ##

die_option_param() {
  die_usage "The option '${arg}' needs a parameter."
}

(( $# == 1 )) &&
case $1 in
  --help)
    man nix-upfetch
    exit
    ;;
  --version)
    nix-update-fetch --version
    exit
    ;;
esac

input_type=
context=
yes=0
debug=0
declare -A bindings
param_count=0
while (( $# >= 1 )); do
  arg=$1; shift
  param=
  case $arg in
    --input) param='input_type';;
    -C|--context) param='context';;
    -y|--yes) yes=1;;
    --no-yes) yes=0;;
    -vv|--debug) debug=1;;
    *)
      if [[ $arg == --* ]]; then
        disambiguate=0
        while true; do
          if [[ $arg == -- ]]; then
            disambiguate=1
            (( $# >= 1 )) && [[ $1 == --* ]] && arg=$1 && shift && continue || break
          fi

          name=${arg#--*}

          if (( $# == 0 )) || [[ ! $1 =~ ^(-E|--expr)$ && $1 == -* ]]; then
            type='expr'
            case $name in
              no-*) value='false'; name=${name#no-};;
                 *) value='true';;
            esac
          else
            (( $# >= 1 )) || die_option_param
            type='str'
            value=$1; shift
            case $value in
              -E|--expr) type='expr';;
              *) false;;
            esac && {
              (( $# >= 1 )) || die_option_param
              value=$1; shift
            }
          fi

          bindings[$name]=$(nix_typed "$type" "$value")

          (( disambiguate )) && (( $# >= 1 )) && [[ $1 == --* ]] && arg=$1 && shift || break
        done
        (( disambiguate )) && break || continue
      fi
      if (( param_count++ == 0 )); then
        prefetch_args=$arg
      else
        die_usage "An unexpected extra parameter '${arg}' has been given."
      fi
      ;;
  esac
  if [[ -n $param ]]; then
    (( $# >= 1 )) || die_option_param
    declare "${param}=${1}"; shift
  fi
done

(( $# == 0 )) || die_usage "Finished parsing the command line arguments, yet still found the following arguments remaining: $(quote_args "$@")."

[[ -v prefetch_args ]] || die_usage 'Use nix-preupfetch to supply nix-upfetch the prefetch expression.'

mapfile -t -d '' prefetch_args < <(unquote_nul "$prefetch_args")

nix_eval_args=()
(( debug )) && nix_eval_args+=( --show-trace )

if [[ -n $input_type ]]; then
  [[ $input_type == raw ]] && quoted_input=$(quote_nul < /dev/stdin) || input=$(< /dev/stdin)
  if [[ $input_type == nix ]]; then
    input=$(nix-instantiate --eval --strict --expr '{ input }: builtins.toJSON input' --arg input "$input" "${nix_eval_args[@]}") || exit
    input=$(jq 'fromjson' <<< "$input") || exit
  fi
  if [[ $input_type =~ ^(json|nix)$ ]]; then
    quoted_input=$(jq --join-output 'to_entries | .[] | .key + "=" + .value + "\u0000"' <<< "$input" | quote_nul) || exit
  fi
  while IFS= read -r -d '' line; do
    [[ $line == *'='* ]] || die "Expected a name value pair seperated by an equal sign, yet got input line '${line}'."
    IFS='=' read -r name value <<< "$line"
    bindings[$name]=$(nix_typed 'str' "$value")
  done < <(unquote_nul "$quoted_input")
fi

## ##
## Main command
## ##

if [[ -z $XDG_RUNTIME_DIR ]]; then
  XDG_RUNTIME_DIR=/run/user/$(id -u)
  [[ -d $XDG_RUNTIME_DIR ]] || die "Could not determine the runtime directory (i.e. XDG_RUNTIME_DIR)."
  export XDG_RUNTIME_DIR
fi

temps=()
mktemp() {
  temp=$(command mktemp "$@" --tmpdir="$XDG_RUNTIME_DIR" nix-upfetch.XXXXXXXXXX)
  temps+=( "$temp" )
  printf '%s' "$temp"
}

cleanup_temps() {
  for temp in "${temps[@]}"; do
    rm -rf "$temp"
  done
}
trap cleanup_temps EXIT

nixpkgs_overlays=$XDG_RUNTIME_DIR/nix-prefetch/overlays
[[ -d $nixpkgs_overlays ]] || nixpkgs_overlays+=.nix
nix_eval_args+=( -I "nixpkgs-overlays=${nixpkgs_overlays}" )

nix_prefetch() {
  set -- --quiet --output expr "$@"
  local arg args=() disambiguate=0
  for arg in "${prefetch_args[@]}"; do
    (( ! disambiguate )) && [[ $arg == -- ]] && disambiguate=1 && args+=( "$@" )
    args+=( "$arg" )
  done
  (( disambiguate )) || args+=( "$@" )
  prefetch_expr=$(nix-prefetch "${args[@]}") || exit
  nix eval --json "(import $lib/args.nix ${prefetch_expr})" --option allow-unsafe-native-code-during-evaluation true "${nix_eval_args[@]}" || exit
}

if (( ${#bindings[@]} > 0 )); then
  bindings_json=$(js_obj "${!bindings[@]}" "${bindings[@]}")

  fetcher_args_json=$(nix_prefetch --no-compute-hash)
  fetcher_args_json=$(jq 'with_entries(select(.key as $key | ["md5", "sha1", "sha256", "sha512"] | any(. == $key)))' <<< "$fetcher_args_json")

  redirects=
  declare -A temp_files
  while IFS= read -r -d '' file; do
    temp_file=$(mktemp)
    [[ -n $redirects ]] && redirects+=':'
    redirects+="$file=$temp_file"
    temp_files[$file]=$temp_file
    cp "$file" "$temp_file"
  done < <(jq --join-output '[.[] | .position.file + "\u0000"] | unique | .[]' <<< "$fetcher_args_json")

  temp_files_json=$(js_obj "${!temp_files[@]}" "${temp_files[@]}")
  fetcher_args_json=$(jq 'map_values(.position.file |= $temp_files[.])' --argjson temp_files "$temp_files_json" <<< "$fetcher_args_json") || exit

  nix-update-fetch --yes "$fetcher_args_json" "$bindings_json" > /dev/null || exit

  fetcher_args_json=$(
    export LD_PRELOAD=$libredirect/lib/libredirect.so
    export NIX_REDIRECTS=$redirects
    nix_prefetch
  ) || exit
else
  bindings_json='{}'
  fetcher_args_json=$(nix_prefetch)
fi

args=()
[[ -n $context ]] && args+=( --context "$context" )
(( yes )) && args+=( "--yes" )

nix-update-fetch "${args[@]}" "$fetcher_args_json" "$bindings_json"
