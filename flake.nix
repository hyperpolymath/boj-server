# SPDX-License-Identifier: PMPL-1.0-or-later
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# Nix flake for Bundle of Joy Server
#
# NOTE: guix.scm is the PRIMARY development environment. This flake is provided
# as a FALLBACK for contributors who use Nix instead of Guix. The .envrc checks
# for Guix first, then falls back to Nix.
#
# Usage:
#   nix develop          # Enter development shell
#   nix build            # Build the project
#   nix flake check      # Run checks

{
  description = "Bundle of Joy Server — formally verified capability catalogue";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachSystem [ "x86_64-linux" "aarch64-linux" ] (system:
      let
        pkgs = import nixpkgs { inherit system; };

        commonTools = with pkgs; [
          git
          just
          nickel
          curl
          bash
          coreutils
        ];

        languageTools = with pkgs; [
          idris2
          zig
          zls
        ];

      in
      {
        devShells.default = pkgs.mkShell {
          name = "boj-server-dev";

          buildInputs = commonTools ++ languageTools;

          env = {
            PROJECT_NAME = "Bundle of Joy Server";
            RSR_TIER = "infrastructure";
          };

          shellHook = ''
            echo ""
            echo "  Bundle of Joy Server — development shell (Nix)"
            echo "  Idris2: $(idris2 --version 2>/dev/null | head -1 || echo 'not found')"
            echo "  Zig:    $(zig version 2>/dev/null || echo 'not found')"
            echo "  Just:   $(just --version 2>/dev/null || echo 'not found')"
            echo ""
            echo "  Run 'just' to see available recipes."
            echo ""
          '';
        };

        packages.default = pkgs.stdenv.mkDerivation {
          pname = "boj-server";
          version = "0.1.0";
          src = self;

          nativeBuildInputs = with pkgs; [ zig ];

          buildPhase = ''
            cd ffi/zig && zig build -Doptimize=ReleaseSafe
          '';

          installPhase = ''
            mkdir -p $out/share/doc
            cp README.adoc $out/share/doc/ 2>/dev/null || true
          '';

          meta = with pkgs.lib; {
            description = "Unified server capability catalogue with formally verified cartridges";
            homepage = "https://github.com/hyperpolymath/boj-server";
            license = licenses.mpl20; # PMPL-1.0-or-later extends MPL-2.0
            maintainers = [];
            platforms = [ "x86_64-linux" "aarch64-linux" ];
          };
        };
      }
    );
}
