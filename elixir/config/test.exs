# SPDX-License-Identifier: PMPL-1.0-or-later
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
import Config

# Do not start the Cowboy HTTP listener during ExUnit runs.
# Router tests use Plug.Test in-process — no real TCP socket needed.
config :boj_rest, start_server: false

config :boj_rest,
  cartridges_root: Path.expand("../../cartridges", __DIR__)
