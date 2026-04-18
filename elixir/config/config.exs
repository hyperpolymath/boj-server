# SPDX-License-Identifier: PMPL-1.0-or-later
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
import Config

config :boj_rest,
  port: String.to_integer(System.get_env("BOJ_PORT") || "7700"),
  cartridges_root:
    System.get_env("BOJ_CARTRIDGES_ROOT") ||
      Path.expand("../../cartridges", __DIR__)
