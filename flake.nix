# SPDX-License-Identifier: PMPL-1.0-or-later
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# Nix flake for Bundle of Joy Server
#
# NOTE: guix.scm is the PRIMARY development environment. This flake is provided
# as a FALLBACK for contributors who use Nix instead of Guix. The .envrc checks
# for Guix first, then falls back to Nix.
#
# Retained per standards#102 rule 3 (KEEP+DEP). guix.scm declares
# empty (native-inputs (list)) / (inputs (list)) and acknowledges
# "idris2 and zig packages may need custom channels". This flake's
# devShell is therefore the SOLE source of the language layer
# (idris2, zig, zls) and the RSR-template common dev tools (git, just,
# nickel, curl, bash, coreutils). Remove only once those packages are
# available via Guix.
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

        # MCP bridge package (Node.js, zero dependencies)
        packages.default = pkgs.stdenv.mkDerivation {
          pname = "boj-server";
          version = "0.3.1";
          src = self;

          nativeBuildInputs = with pkgs; [ nodejs makeWrapper ];

          dontBuild = true;

          installPhase = ''
            mkdir -p $out/lib/boj-server $out/bin $out/share/doc/boj-server

            # Install MCP bridge
            cp -r mcp-bridge $out/lib/boj-server/
            cp gemini-extension.json $out/lib/boj-server/ 2>/dev/null || true
            cp GEMINI.md $out/lib/boj-server/ 2>/dev/null || true

            # Wrapper script
            makeWrapper ${pkgs.nodejs}/bin/node $out/bin/boj-server \
              --add-flags "$out/lib/boj-server/mcp-bridge/main.js"

            # Documentation
            cp README.adoc $out/share/doc/boj-server/ 2>/dev/null || true
            cp CHANGELOG.md $out/share/doc/boj-server/ 2>/dev/null || true
            cp docs/GETTING-STARTED.md $out/share/doc/boj-server/ 2>/dev/null || true
          '';

          meta = with pkgs.lib; {
            description = "Bundle of Joy — cartridge-based MCP server with 53 formally verified domain cartridges";
            homepage = "https://github.com/hyperpolymath/boj-server";
            license = licenses.mpl20; # PMPL-1.0-or-later extends MPL-2.0
            mainProgram = "boj-server";
            maintainers = [];
            platforms = [ "x86_64-linux" "aarch64-linux" ];
          };
        };

        # Full build with Zig FFI (for contributors/developers)
        packages.full = pkgs.stdenv.mkDerivation {
          pname = "boj-server-full";
          version = "0.3.1";
          src = self;

          nativeBuildInputs = with pkgs; [ zig nodejs makeWrapper ];

          buildPhase = ''
            cd ffi/zig && zig build -Doptimize=ReleaseSafe
          '';

          installPhase = ''
            mkdir -p $out/lib/boj-server $out/bin $out/share/doc/boj-server

            # Install MCP bridge
            cp -r mcp-bridge $out/lib/boj-server/

            # Install FFI shared libraries
            mkdir -p $out/lib/boj-server/ffi
            cp ffi/zig/zig-out/lib/*.so $out/lib/boj-server/ffi/ 2>/dev/null || true

            # Wrapper script
            makeWrapper ${pkgs.nodejs}/bin/node $out/bin/boj-server \
              --add-flags "$out/lib/boj-server/mcp-bridge/main.js" \
              --set LD_LIBRARY_PATH "$out/lib/boj-server/ffi"

            cp README.adoc $out/share/doc/boj-server/ 2>/dev/null || true
          '';

          meta = with pkgs.lib; {
            description = "Bundle of Joy — full build with Zig FFI shared libraries";
            homepage = "https://github.com/hyperpolymath/boj-server";
            license = licenses.mpl20; # PMPL-1.0-or-later extends MPL-2.0
            mainProgram = "boj-server";
            maintainers = [];
            platforms = [ "x86_64-linux" "aarch64-linux" ];
          };
        };
      }
    );
}
