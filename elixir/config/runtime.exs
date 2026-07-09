# SPDX-License-Identifier: MPL-2.0
# Copyright (c) Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>
import Config

# Runtime configuration — evaluated at release BOOT, not compile time. Without this,
# a `mix release` bakes config.exs's env lookups at build time, so BOJ_BIND_IP /
# BOJ_PORT / BOJ_CARTRIDGES_ROOT set at `podman run` are ignored (the release keeps
# the build-time values: bind 127.0.0.1 unreachable via port-map, and a build-path
# cartridges_root that yields cartridges_loaded:0). Re-reading them here fixes both.
config :boj_rest,
  port: String.to_integer(System.get_env("BOJ_PORT") || "7700"),
  bind_ip: System.get_env("BOJ_BIND_IP") || "127.0.0.1",
  cartridges_root:
    System.get_env("BOJ_CARTRIDGES_ROOT") ||
      System.get_env("BOJ_CARTRIDGES_PATH") ||
      Path.expand("../../cartridges", __DIR__),
  data_dir: System.get_env("BOJ_DATA_DIR") || "/data"
