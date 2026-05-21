# SPDX-License-Identifier: PMPL-1.0-or-later
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# Backend-assurance harness for `prim__strSubstr`.
#
# Validates that BEAM substring extraction (`String.slice/3` over UTF-8
# binaries) satisfies the length-bound axiom declared at:
#
#   src/abi/Boj/SafetyLemmas.idr:233  substrLengthBound :
#     (s : String) -> (start, len : Nat) ->
#       LTE (length (substr start len s)) len
#
# The axiom is class (J) — irreducible in Idris2 0.8.0 because `String`
# is an opaque primitive. See PROOF-NEEDS.md and
# docs/backend-assurance/prim__strSubstr.md for the campaign framing
# and the Chez (R6RS `substring`) lowering argument.
#
# This is *external* evidence: it does not change the in-language proof,
# and the believe_me site stays in source. The harness shrinks the
# trusted base from "we trust the backend" to "we randomly tested the
# operation against the property over N (start, len, s) tuples".
#
# Length is codepoint count (`String.length/1`), matching Idris2's
# `prim__strLength` semantics on Chez (`string-length`).
defmodule Boj.BackendAssurance.PrimStrSubstrTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  @moduletag :backend_assurance

  defp legal_codepoint do
    StreamData.one_of([
      StreamData.integer(0..0xD7FF),
      StreamData.integer(0xE000..0x10FFFF)
    ])
  end

  defp legal_string do
    StreamData.bind(StreamData.list_of(legal_codepoint(), max_length: 64), fn cps ->
      StreamData.constant(List.to_string(cps))
    end)
  end

  # ── Length bound: |substr(start, len, s)| ≤ len ──────────────────────
  #
  # Backs `substrLengthBound`. On BEAM, `String.slice(s, start, len)`
  # returns at most `len` codepoints starting at offset `start`, clamped
  # to the string's actual length. The clamp means the result can be
  # shorter than `len` (when `start + len > length(s)` or `start ≥
  # length(s)`), never longer.
  property "BEAM String.slice respects the requested length bound (substrLengthBound)" do
    check all s <- legal_string(),
              start <- StreamData.integer(0..96),
              len <- StreamData.integer(0..96) do
      result_len = String.length(String.slice(s, start, len))

      assert result_len <= len,
             "substrLengthBound violation: substr(#{start}, #{len}, " <>
               "#{inspect(s)}) has length #{result_len}, exceeds bound #{len}"
    end
  end

  # ── Zero-length request: substr(_, 0, _) = "" ────────────────────────
  #
  # Tight corner of the bound: `len = 0` must always return the empty
  # string (length 0 ≤ 0). A backend that returned at least one char
  # for `len = 0` would surface here.
  property "len = 0 always yields the empty string" do
    check all s <- legal_string(),
              start <- StreamData.integer(0..96) do
      assert String.slice(s, start, 0) == "",
             "substr(#{start}, 0, #{inspect(s)}) was not empty"
    end
  end

  # ── Start beyond end: result is empty (length 0 ≤ len trivially) ─────
  #
  # When `start ≥ length(s)`, the result is the empty string regardless
  # of `len`. This is the bound-clamp path through the backend.
  property "start ≥ length(s) yields the empty string" do
    check all s <- legal_string(),
              len <- StreamData.integer(0..96) do
      start = String.length(s) + 5
      assert String.slice(s, start, len) == "",
             "substr(#{start}, #{len}, #{inspect(s)}) past end was not empty"
    end
  end

  # ── Full-string slice: substr(0, length(s), s) = s ───────────────────
  #
  # When the bound matches the actual string length, the slice should
  # be the whole string. Anchors the upper edge of the bound.
  property "start = 0, len = length(s) returns the whole string" do
    check all s <- legal_string() do
      assert String.slice(s, 0, String.length(s)) == s
      assert String.length(String.slice(s, 0, String.length(s))) == String.length(s)
    end
  end

  # ── Boundary cases ───────────────────────────────────────────────────
  #
  # Explicit (start, len, s) tuples crossing UTF-8 encoding widths and
  # the slice-clamp boundary. The bound must hold across all of them.
  test "boundary slices satisfy substrLengthBound" do
    strings = [
      "",
      "a",
      "abc",
      "café",
      "日本語",
      "🦀🦀🦀",
      String.duplicate("x", 64)
    ]

    starts = [0, 1, 3, 8, 64, 1000]
    lens = [0, 1, 3, 8, 64, 1000]

    for s <- strings, start <- starts, len <- lens do
      result_len = String.length(String.slice(s, start, len))

      assert result_len <= len,
             "substrLengthBound boundary: substr(#{start}, #{len}, " <>
               "#{inspect(s)}) has length #{result_len}, exceeds bound #{len}"
    end
  end
end
