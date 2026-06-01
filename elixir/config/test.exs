# SPDX-License-Identifier: MPL-2.0
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
import Config

# Do not start the Cowboy HTTP listener during ExUnit runs.
# Router tests use Plug.Test in-process — no real TCP socket needed.
config :boj_rest, start_server: false

config :boj_rest,
  cartridges_root:
    System.get_env("BOJ_CARTRIDGES_PATH") || Path.expand("../../cartridges", __DIR__)
