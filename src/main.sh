#!/usr/bin/env bash

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
  (( ! silent )) && printf 'error: %s\n' "$*" >&2
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
  (( ! quiet )) && { show_usage; printf '\n'; } >&2
  die "$@"
}

# https://stackoverflow.com/questions/6570531/assign-string-containing-null-character-0-to-a-variable-in-bash
quote_nul() {
  sed 's/\\/\\\\/g;s/\x0/\\0/g'
}

unquote_nul() {
  echo -en "$1"
}

quote() {
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

[[ -v prefetch_args ]] || die_usage 'Use `nix-preupfetch` to supply `nix-upfetch` the prefetch expression.'

mapfile -t -d '' prefetch_args < <(unquote_nul "$prefetch_args")

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

prefetch_update() {
  prefetch_expr=$(nix-prefetch "${prefetch_args[@]}" --quiet --output expr "$@") || exit
  nix eval --json "(import $lib/update.nix ${prefetch_expr})" --option allow-unsafe-native-code-during-evaluation true $( (( debug )) && printf --show-trace ) || exit
}

cleanup_tmp_files() {
  for tmp_file in "${tmp_files[@]}"; do
    rm -f "$tmp_file"
  done
}

bindings_json=$(js_obj "${!bindings[@]}" "${bindings[@]}")

fetcher_json="$(prefetch_update --no-compute-hash)"

redirects=
declare -A tmp_files
while IFS= read -r -d '' file; do
  tmp_file=$(mktemp --tmpdir=$XDG_RUNTIME_DIR nix-upfetch.XXXXXXXXXX)
  [[ -n $redirects ]] && redirects+=':'
  redirects+="$file=$tmp_file"
  tmp_files[$file]=$tmp_file
  cp "$file" "$tmp_file"
done < <(jq --join-output '[.[] | .position.file + "\u0000"] | unique | .[]' <<< "$fetcher_json")
trap cleanup_tmp_files EXIT

tmp_files_json=$(js_obj "${!tmp_files[@]}" "${tmp_files[@]}")
fetcher_json=$(jq 'map_values(.position.file |= $tmp_files[.])' --argjson tmp_files "$tmp_files_json" <<< "$fetcher_json") || exit

nix-update-fetch --yes "$fetcher_json" "$bindings_json" > /dev/null || exit

fetcher_json=$(
  export LD_PRELOAD=$libredirect/lib/libredirect.so
  export NIX_REDIRECTS=$redirects
  prefetch_update
) || exit

args=()
[[ -n $context ]] && args+=( --context "$context" )
(( yes )) && args+=( "--yes" )

nix-update-fetch "${args[@]}" "$fetcher_json" "$bindings_json"
