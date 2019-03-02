{ pkgs, fetcher, prefetcher }:

with builtins;
with pkgs.lib;

let
  # https://github.com/NixOS/nixpkgs/blob/d4224f05074b6b8b44fd9bd68e12d4f55341b872/lib/strings.nix#L316
  escapeNixString = s: escape ["$"] (toJSON s);

  hashAlgo = findFirst (name: prefetcher.args ? ${name})
    (throw "The fetcher is expected to have a hash defined, otherwise it cannot be updated.")
    [ "md5" "sha1" "sha256" "sha512" ];

  presentArgs = mapAttrs (name: value:
    if fetcher.args ? ${name} then value
    else throw "Cannot get the position information for fetcher argument '${name}', since its not yet passed to the fetcher call."
  ) prefetcher.args;

  diffArgs = filterAttrs (name: value: value != fetcher.args.${name}) presentArgs;

in toJSON (mapAttrs (name: value: {
  position = unsafeGetAttrPos name fetcher.args;
  value = escapeNixString value;
}) (diffArgs // { ${hashAlgo} = prefetcher.args.${hashAlgo}; }))
