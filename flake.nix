{
  description = "Build Debian packages from NIX";

  inputs = {
    flake-utils.url = "github:numtide/flake-utils";
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
    pyproject-nix = {
      url = "github:pyproject-nix/pyproject.nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    uv2nix = {
      url = "github:pyproject-nix/uv2nix";
      inputs.pyproject-nix.follows = "pyproject-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    pyproject-build-systems = {
      url = "github:pyproject-nix/build-system-pkgs";
      inputs.pyproject-nix.follows = "pyproject-nix";
      inputs.uv2nix.follows = "uv2nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    bampkgbuild.url = "github:brianmay/bampkgbuild";
  };

  outputs =
    {
      self,
      nixpkgs,
      flake-utils,
      pyproject-nix,
      uv2nix,
      pyproject-build-systems,
      bampkgbuild,
    }:
    flake-utils.lib.eachDefaultSystem (
      system:
      let
        inherit (nixpkgs) lib;
        pkgs = nixpkgs.legacyPackages.${system};

        python = pkgs.python312;

        workspace = uv2nix.lib.workspace.loadWorkspace { workspaceRoot = ./.; };

        # Create package overlay from workspace.
        overlay = workspace.mkPyprojectOverlay {
          sourcePreference = "sdist";
        };

        # Extend generated overlay with build fixups
        #
        # Uv2nix can only work with what it has, and uv.lock is missing essential metadata to perform some builds.
        # This is an additional overlay implementing build fixups.
        # See:
        # - https://pyproject-nix.github.io/uv2nix/FAQ.html
        pyprojectOverrides =
          final: prev:
          # Implement build fixups here.
          # Note that uv2nix is _not_ using Nixpkgs buildPythonPackage.
          # It's using https://pyproject-nix.github.io/pyproject.nix/build.html
          let
            inherit (final) resolveBuildSystem;
            inherit (builtins) mapAttrs;

            # Build system dependencies specified in the shape expected by resolveBuildSystem
            # The empty lists below are lists of optional dependencies.
            #
            # A package `foo` with specification written as:
            # `setuptools-scm[toml]` in pyproject.toml would be written as
            # `foo.setuptools-scm = [ "toml" ]` in Nix
            buildSystemOverrides = {
              gbp.setuptools = [ ];
              python-dateutil.setuptools = [ ];
              six.setuptools = [ ];
            };

          in
          mapAttrs (
            name: spec:
            prev.${name}.overrideAttrs (old: {
              nativeBuildInputs = old.nativeBuildInputs ++ resolveBuildSystem spec;
            })
          ) buildSystemOverrides;

        pythonSet =
          (pkgs.callPackage pyproject-nix.build.packages {
            inherit python;
          }).overrideScope
            (
              lib.composeManyExtensions [
                pyproject-build-systems.overlays.default
                overlay
                pyprojectOverrides
              ]
            );

        venv = pythonSet.mkVirtualEnv "nix-debian" workspace.deps.default;

        # pristine-tar is not packaged in nixpkgs. Sid ships a single deb
        # containing the `zgz` C binary, a bundled SUSE bzip2 for reproducible
        # tarball deltas, and pure-perl scripts (pristine-tar/gz/bz2/xz).
        # We unpack the deb, patch the ELFs with autoPatchelf, point the perl
        # scripts at nix's perl (with Sys::CpuAffinity from nixpkgs) and wrap
        # them so runtime tool lookups (xz, bzip2, zgz, suse-bzip2, ...) work.
        #
        # Only x86_64-linux is supported because the deb ships prebuilt ELFs.
        pristine-tar =
          let
            perlPristine = pkgs.perl.withPackages (p: [ p.SysCpuAffinity ]);
            runtimeDeps = [
              pkgs.xz
              pkgs.bzip2
              pkgs.pbzip2
              pkgs.pixz
              # nixpkgs xdelta is xdelta3 (3.1.x)
              pkgs.xdelta
              pkgs.gnutar
            ];
          in
          pkgs.stdenv.mkDerivation {
            pname = "pristine-tar";
            version = "1.50+nmu2";
            src = pkgs.fetchurl {
              url = "https://deb.debian.org/debian/pool/main/p/pristine-tar/pristine-tar_1.50+nmu2_amd64.deb";
              sha256 = "ef5d997753c8a831e618d2bca8daab88ccfaa9b611be0ef3954ef8c0fcc79c4c";
            };

            dontConfigure = true;
            dontBuild = true;

            nativeBuildInputs = [
              pkgs.autoPatchelfHook
              pkgs.dpkg
              pkgs.makeWrapper
              pkgs.patchelf
            ];
            buildInputs = [
              pkgs.zlib
              pkgs.bzip2
              perlPristine
            ];

            unpackPhase = ''
              runHook preUnpack
              dpkg-deb -x $src .
              runHook postUnpack
            '';

            installPhase = ''
              runHook preInstall
              mkdir -p $out/bin $out/lib $out/share/perl5 $out/share/man
              cp -r usr/bin/. $out/bin/
              cp -r usr/lib/pristine-tar $out/lib/pristine-tar
              cp -r usr/share/perl5/Pristine $out/share/perl5/
              cp -r usr/share/man/. $out/share/man/
              runHook postInstall
            '';

            # autoPatchelf refuses the suse-bzip2 bundle's libbz2.so.1.0
            # (it's not in store). Give its own dir an RPATH of $ORIGIN so
            # the bundled lib is found, and ignore the missing-deps error.
            autoPatchelfIgnoreMissingDeps = [ "libbz2.so.1.0" ];

            preFixupPhases = [ "pristinePreFixup" ];
            pristinePreFixup = ''
              patchelf --set-rpath '$ORIGIN' $out/lib/pristine-tar/suse-bzip2/bzip2
            '';

            postFixup = ''
              # patchShebangs (auto-run in fixupPhase) already rewrote the
              # perl shebangs to perlPristine's interpreter via PATH, since
              # perlPristine is in buildInputs. We only need to wrap them.
              for f in $out/bin/pristine-tar $out/bin/pristine-gz $out/bin/pristine-bz2 $out/bin/pristine-xz; do
                wrapProgram $f \
                  --prefix PERL5LIB : "$out/share/perl5" \
                  --prefix PATH : "$out/bin:$out/lib/pristine-tar/suse-bzip2:${lib.makeBinPath runtimeDeps}"
              done
            '';

            meta = with lib; {
              description = "Regenerate pristine tarballs";
              homepage = "https://salsa.debian.org/debian/pristine-tar";
              license = licenses.gpl2Plus;
              platforms = [ "x86_64-linux" ];
            };
          };
      in
      {
        packages.pristine-tar = pristine-tar;

        devShells.default = pkgs.mkShell {
          packages = [
            pkgs.dpkg
            pkgs.debian-devscripts
            pkgs.uv
            venv
            bampkgbuild.packages.${system}.default
            pristine-tar
          ];
        };
      }
    );
}
