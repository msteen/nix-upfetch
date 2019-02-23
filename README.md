`nix-upfetch`
===

Update any fetcher call that can be prefetched with [`nix-prefetch`](https://github.com/msteen/nix-prefetch).

Installation
---

```
git clone https://github.com/msteen/nix-upfetch.git
cd nix-upfetch
nix-env --install --file release.nix
```

Features
---

* Can update most packages as in the example, see Limitations.
* Can work with string interpolated bindings, see Examples.
* Aside from fetcher arguments a version can be supplied, so that its binding will also be modified.
* Can handle `${majorMinor version}` in an URL.

Limitations
---

* Cannot handle inheriting fetcher arguments from an expression, i.e. `inherit (args) sha256;` will fail, but `inherit sha256;` works (see next point).
* Can only handle attribute set and let bindings, so it cannot handle `with` expressions or function arguments at the moment.

Examples
---

Can handle interpolated bindings and simple inherits:

```
{ stdenv, fetchurl }:

let
  sha256 = "0000000000000000000000000000000000000000000000000000";
  rev = "112c7d23f90da692927b76f7284c8047e50fdc14";

in stdenv.mkDerivation rec {
  name = "${pname}-${version}";
  pname = "test";
  version = "0.1.0";

  src = fetchurl {
    inherit sha256;
    url = "https://gist.githubusercontent.com/msteen/fef0b259aa8e26e9155fa0f51309892c/raw/${rev}/test.txt";
  };
}
```

```
$ nix-upfetch "$(nix-preupfetch test \
    --url https://gist.githubusercontent.com/msteen/fef0b259aa8e26e9155fa0f51309892c/raw/98170052fc54d3e901cca0d7d4a68e1424a58e94/test.txt)"

 { stdenv, fetchurl }:

 let
-  sha256 = "0000000000000000000000000000000000000000000000000000";
-  rev = "112c7d23f90da692927b76f7284c8047e50fdc14";
+  sha256 = "0ddb2gn6wrisva81zidnv03rq083bndqnwar7zhfw5jy4qx5wwyl";
+  rev = "98170052fc54d3e901cca0d7d4a68e1424a58e94";

 in stdenv.mkDerivation rec {
   name = "${pname}-${version}";
Do you want to apply these changes? [Y/n]
```

Update a GitHub revision:

```
$ nix-upfetch "$(nix-preupfetch kore --rev master)"
   src = fetchFromGitHub {
     owner = "jorisvink";
     repo = "kore";
-    rev = "${version}-release";
-    sha256 = "1jjhx9gfjzpsrs7b9rgb46k6v03azrxz9fq7vkn9zyz6zvnjj614";
+    rev = "master";
+    sha256 = "1sqzh1bwk94g7djip5av1b00d75r65j2xw9hs3br58any0b86c3r";
   };

   buildInputs = [ openssl ];
Do you want to apply these changes? [Y/n]
```
