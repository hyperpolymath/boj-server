# SPDX-License-Identifier: PMPL-1.0-or-later
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# Homebrew formula for Bundle of Joy (BoJ) MCP Server.
#
# Install:
#   brew tap hyperpolymath/tap
#   brew install boj-server
#
# Or directly:
#   brew install hyperpolymath/tap/boj-server

class BojServer < Formula
  desc "Cartridge-based MCP server with 53 formally verified domain cartridges"
  homepage "https://github.com/hyperpolymath/boj-server"
  url "https://github.com/hyperpolymath/boj-server/archive/refs/tags/v0.3.0.tar.gz"
  # sha256 "UPDATE_ON_RELEASE"
  license "PMPL-1.0-or-later"
  head "https://github.com/hyperpolymath/boj-server.git", branch: "main"

  depends_on "node" => ">= 18.0"

  def install
    # Install the MCP stdio bridge (zero npm dependencies)
    libexec.install "mcp-bridge"
    libexec.install "gemini-extension.json"
    libexec.install "GEMINI.md"

    # Create wrapper script
    (bin/"boj-server").write <<~EOS
      #!/usr/bin/env bash
      # SPDX-License-Identifier: PMPL-1.0-or-later
      # Bundle of Joy MCP Server — stdio transport
      exec node "#{libexec}/mcp-bridge/main.js" "$@"
    EOS
  end

  def caveats
    <<~EOS
      BoJ Server MCP bridge is installed. To use with Claude Code:

        Add to your MCP config:
        {
          "mcpServers": {
            "boj-server": {
              "command": "boj-server"
            }
          }
        }

      For full cartridge functionality (REST API, federation, etc.),
      build the V-lang adapter from source:

        cd $(brew --prefix)/opt/boj-server
        # Requires V-lang 0.5.0+ and Zig 0.15.2+
    EOS
  end

  test do
    # Verify the MCP bridge responds to an initialize message
    input = '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"test","version":"0.1.0"}}}'
    output = pipe_output("#{bin}/boj-server", input + "\n", 0)
    assert_match "protocolVersion", output
  end
end
