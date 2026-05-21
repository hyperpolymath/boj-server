# SPDX-License-Identifier: PMPL-1.0-or-later
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# Backend-assurance harness for `prim__strAppend`.
#
# Validates that BEAM string concatenation (Erlang/Elixir `<>` on UTF-8
# binaries) satisfies the length-additivity axiom declared at:
#
#   src/abi/Boj/SafetyLemmas.idr:226  appendLengthSum :
#     (s, t : String) -> length (s ++ t) = length s + length t
#
# The axiom is class (J) — irreducible in Idris2 0.8.0 because `String`
# is an opaque primitive with no constructors. See PROOF-NEEDS.md and
# docs/backend-assurance/prim__strAppend.md for the campaign framing
# and the Chez (R6RS) lowering argument.
#
# This is *external* evidence: it does not change the in-language proof,
# and the believe_me site stays in source. The harness shrinks the
# trusted base from "we trust the backend" to "we randomly tested the
# operation against the property over N strings".
#
# Idris2's `length` on `String` is codepoint count (Chez `string-length`
# on R6RS characters; BEAM `String.length/1` on UTF-8 binaries). Tests
# below use codepoint count, *not* byte count — the axiom is about
# logical-character length, not encoded-byte length.
defmodule Boj.BackendAssurance.PrimStrAppendTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  @moduletag :backend_assurance

  # Random string generator over the legal codepoint range (surrogates
  # excluded as illegal standalone code units). Mirrors the codepoint
  # generator in prim_eq_char_test.exs.
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

  # ── Length additivity: |s <> t| = |s| + |t| ──────────────────────────
  #
  # Backs `appendLengthSum`. On BEAM, `<>` on UTF-8 binaries appends the
  # byte sequences; codepoint count of the result equals the sum of the
  # operand codepoint counts because UTF-8 encoding is prefix-free.
  property "BEAM <> is length-additive on codepoint count (appendLengthSum)" do
    check all s <- legal_string(),
              t <- legal_string() do
      assert String.length(s <> t) == String.length(s) + String.length(t),
             "appendLengthSum violation: |#{inspect(s)} <> #{inspect(t)}| = " <>
               "#{String.length(s <> t)}, expected #{String.length(s) + String.length(t)}"
    end
  end

  # ── Identity: s <> "" = s  and  "" <> s = s ──────────────────────────
  #
  # The empty-string identity case is a corollary of additivity, but
  # worth pinning explicitly — a backend that special-cased empty-string
  # append (e.g. allocating a sentinel byte) would surface here.
  property "right identity: s <> \"\" = s (length and content)" do
    check all s <- legal_string() do
      assert s <> "" == s
      assert String.length(s <> "") == String.length(s)
    end
  end

  property "left identity: \"\" <> s = s (length and content)" do
    check all s <- legal_string() do
      assert "" <> s == s
      assert String.length("" <> s) == String.length(s)
    end
  end

  # ── Associativity-friendly: |(s <> t) <> u| = |s <> (t <> u)| ────────
  #
  # Not in the axiom but cheap to assert. Idris2's `++` on String is
  # associative; BEAM `<>` is binary-concatenation-associative on the
  # byte level, which the codepoint count inherits.
  property "<> on codepoint count distributes over three-way append" do
    check all s <- legal_string(),
              t <- legal_string(),
              u <- legal_string() do
      assert String.length((s <> t) <> u) == String.length(s <> (t <> u))
      assert String.length((s <> t) <> u) ==
               String.length(s) + String.length(t) + String.length(u)
    end
  end

  # ── Boundary cases the property generator may rarely hit ─────────────
  #
  # Multi-byte codepoint boundaries (ASCII, Latin-1 supplement boundary,
  # BMP boundary, BMP→astral boundary, max codepoint, emoji) — each is
  # a different UTF-8 encoding width (1/2/3/4 bytes). Length additivity
  # must hold across all of them.
  test "boundary strings satisfy appendLengthSum" do
    boundaries = [
      "",
      "a",
      "ab",
      "",
      "",
      "߿",
      "ࠀ",
      "퟿",
      "",
      "￿",
      "\u{10000}",
      "\u{10FFFF}",
      "café",
      "日本語",
      "🦀"
    ]

    for s <- boundaries, t <- boundaries do
      assert String.length(s <> t) == String.length(s) + String.length(t),
             "appendLengthSum boundary violation: #{inspect(s)} <> #{inspect(t)}"
    end
  end
end
