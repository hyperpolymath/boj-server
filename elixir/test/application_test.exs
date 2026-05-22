# SPDX-License-Identifier: MPL-2.0
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
defmodule BojRest.ApplicationTest do
  use ExUnit.Case, async: true

  alias BojRest.Application, as: App

  describe "parse_bind_ip/1" do
    test "parses IPv4 loopback" do
      assert App.parse_bind_ip("127.0.0.1") == {127, 0, 0, 1}
    end

    test "parses IPv4 all-interfaces" do
      assert App.parse_bind_ip("0.0.0.0") == {0, 0, 0, 0}
    end

    test "parses IPv6 loopback" do
      assert App.parse_bind_ip("::1") == {0, 0, 0, 0, 0, 0, 0, 1}
    end

    test "parses IPv6 all-interfaces" do
      assert App.parse_bind_ip("::") == {0, 0, 0, 0, 0, 0, 0, 0}
    end

    test "raises ArgumentError on invalid input" do
      assert_raise ArgumentError, ~r/not a valid IPv4 or IPv6 address/, fn ->
        App.parse_bind_ip("not-an-ip")
      end
    end

    test "raises ArgumentError on empty string" do
      assert_raise ArgumentError, ~r/not a valid IPv4 or IPv6 address/, fn ->
        App.parse_bind_ip("")
      end
    end

    test "error message names the offending value" do
      assert_raise ArgumentError, ~r/garbage/, fn ->
        App.parse_bind_ip("garbage")
      end
    end
  end
end
