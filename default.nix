{ stdenv, callPackage, fetchFromGitHub, makeWrapper
, asciidoc, docbook_xml_dtd_45, docbook_xsl, libxml2, libxslt
, libredirect, coreutils, gawk, gnugrep, gnused, jq, nix, nix-prefetch, nix-update-fetch }:

with stdenv.lib;

with callPackage (fetchFromGitHub {
  owner = "siers";
  repo = "nix-gitignore";
  rev = "cc962a73113dbb32407d5099c4bf6f7ecf5612c9";
  sha256 = "08mgdnb54rhsz4024hx008dzg01c7kh3r45g068i7x91akjia2cq";
}) { };

stdenv.mkDerivation rec {
  name = "${pname}-${version}";
  pname = "nix-upfetch";
  version = "0.1.0";

  src = gitignoreSource [ ".git" ] ./.;

  nativeBuildInputs = [
    makeWrapper
    asciidoc docbook_xml_dtd_45 docbook_xsl libxml2 libxslt
  ];

  configurePhase = ''
    . configure.sh
  '';

  buildPhase = ''
    a2x -f manpage doc/nix-upfetch.1.asciidoc
  '';

  installPhase = ''
    lib=$out/lib/${pname}
    mkdir -p $lib
    substitute src/main.sh $lib/main.sh \
      --subst-var-by lib $lib \
      --subst-var-by libredirect ${libredirect}
    chmod +x $lib/main.sh
    patchShebangs $lib/main.sh
    find .
    cp lib/*.nix $lib/

    mkdir -p $out/bin
    makeWrapper $lib/main.sh $out/bin/${pname} \
      --prefix PATH : '${makeBinPath [ coreutils gawk gnugrep gnused jq nix nix-prefetch nix-update-fetch ]}'

    mkdir -p $out/bin
    cp src/prefetch.sh $lib/prefetch.sh
    chmod +x $lib/prefetch.sh
    patchShebangs $lib/prefetch.sh
    makeWrapper $lib/prefetch.sh $out/bin/nix-preupfetch \
      --prefix PATH : '${makeBinPath [ coreutils gnused ]}'

    mkdir -p $out/share/man/man1
    substitute doc/nix-upfetch.1 $out/share/man/man1/nix-upfetch.1 \
      --subst-var-by version '${version}' \
      --replace '01/01/1970' "$date"

    mkdir -p $out/share/bash-completion/completions
    substitute ${nix-prefetch}/share/bash-completion/completions/nix-prefetch $out/share/bash-completion/completions/nix-preupfetch \
      --replace 'complete -F _nix_prefetch nix-prefetch' 'complete -F _nix_prefetch nix-preupfetch'
    mkdir -p $out/share/zsh/site-functions
    substitute ${nix-prefetch}/share/zsh/site-functions/_nix_prefetch $out/share/zsh/site-functions/_nixpkg_prefetch \
      --replace '#compdef nix-prefetch' '#compdef nix-preupfetch'
  '';

  meta = {
    description = "Update any fetcher call that can be prefetched with nix-prefetch";
    homepage = https://github.com/msteen/nix-upfetch;
    license = licenses.mit;
    maintainers = with maintainers; [ msteen ];
    platforms = platforms.all;
  };
}
