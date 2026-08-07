{ lib
, stdenv
, callPackage
, zig_0_16
}:

stdenv.mkDerivation (finalAttrs: {
  pname = "nixprbot";
  version = "0.2.0";

  src = lib.fileset.toSource {
    root = ../.;
    fileset = lib.fileset.unions [
      ../build.zig
      ../build.zig.zon
      ../src
    ];
  };

  deps = callPackage ./deps.nix { };

  nativeBuildInputs = [ zig_0_16 ];

  dontConfigure = true;
  doCheck = true;

  preBuild = ''
    export HOME="$TMPDIR"
    export ZIG_GLOBAL_CACHE_DIR="$TMPDIR/zig-global-cache"
    export ZIG_LOCAL_CACHE_DIR="$TMPDIR/zig-cache"
  '';

  buildPhase = ''
    runHook preBuild
    zig build install \
      --system "${finalAttrs.deps}" \
      -Doptimize=ReleaseSafe \
      --prefix "$out"
    runHook postBuild
  '';

  checkPhase = ''
    runHook preCheck
    zig build test \
      --system "${finalAttrs.deps}"
    runHook postCheck
  '';

  installPhase = ''
    runHook preInstall
    runHook postInstall
  '';

  meta = {
    description = "Telegram bot tracking nixpkgs PRs across channel branches";
    mainProgram = "nixprbot";
    license = lib.licenses.mit;
    platforms = lib.platforms.linux ++ lib.platforms.darwin;
  };
})
