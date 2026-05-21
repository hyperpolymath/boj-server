# SPDX-License-Identifier: PMPL-1.0-or-later
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# Backend-assurance harness for `prim__strToCharList`.
#
# Validates that BEAM string-to-charlist conversion (Elixir
# `String.to_charlist/1` on UTF-8 binaries) satisfies the
# length-preservation axiom declared at:
#
#   src/abi/Boj/SafetyLemmas.idr:218  unpackLength :
#     (s : String) -> length (unpack s) = length s
#
# `unpack` in Idris2 calls `prim__strToCharList`. The axiom is class
# (J) — irreducible in Idris2 0.8.0 because `String` is an opaque
# primitive with no constructors and no induction principle relating
# its primitive length to the length of the derived `List Char`. See
# PROOF-NEEDS.md and docs/backend-assurance/prim__strToCharList.md for
# the campaign framing and the Chez (R6RS) lowering argument.
#
# This is *external* evidence: it does not change the in-language proof,
# and the believe_me site stays in source. The harness shrinks the
# trusted base from "we trust the backend" to "we randomly tested the
# operation against the property over N strings".
#
# Idris2's `length` on `String` is codepoint count (Chez
# `string-length` on R6RS characters; BEAM `String.length/1` on UTF-8
# binaries). `String.to_charlist/1` returns a list of codepoint
# integers; `length/1` on that list returns the same count. Tests
# below use codepoint count, *not* byte count — the axiom is about
# logical-character length, not encoded-byte length.
defmodule Boj.BackendAssurance.PrimStrToCharListTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  @moduletag :backend_assurance

  # Random codepoint generator: covers ASCII, BMP, and astral planes
  # excluding surrogates (which are illegal as standalone code units).
  # Mirrors the codepoint generator in prim_eq_char_test.exs.
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

  # ── Length preservation: |to_charlist(s)| = |s| ──────────────────────
  #
  # Backs `unpackLength`. On BEAM, `String.to_charlist/1` decodes a
  # UTF-8 binary to a list of codepoint integers; the list length is
  # the codepoint count, which matches `String.length/1` because UTF-8
  # is prefix-free (each codepoint occupies a self-delimiting
  # 1-/2-/3-/4-byte sequence with no ambiguity).
  property "BEAM String.to_charlist/1 preserves codepoint count (unpackLength)" do
    check all s <- legal_string() do
      assert length(String.to_charlist(s)) == String.length(s),
             "unpackLength violation: |to_charlist(#{inspect(s)})| = " <>
               "#{length(String.to_charlist(s))}, expected #{String.length(s)}"
    end
  end

  # ── Empty-string corner ──────────────────────────────────────────────
  #
  # `String.to_charlist("")` must yield the empty list, and both
  # lengths are 0. A backend that allocated a sentinel codepoint on
  # empty input would surface here.
  test "empty string maps to empty charlist (both lengths zero)" do
    assert String.to_charlist("") == []
    assert length(String.to_charlist("")) == 0
    assert String.length("") == 0
  end

  # ── Round-trip: to_string(to_charlist(s)) = s ────────────────────────
  #
  # Not in the axiom but cheap to assert. The round-trip property
  # guards against a backend whose charlist conversion drops or
  # duplicates codepoints in a way that happens to preserve length
  # (e.g. a 1-codepoint replacement on decode error). If round-trip
  # fails, length preservation is suspect even when the counts agree.
  property "to_string ∘ to_charlist is identity on legal strings" do
    check all s <- legal_string() do
      assert s |> String.to_charlist() |> to_string() == s,
             "round-trip violation on #{inspect(s)}"
    end
  end

  # ── Charlist element type ───────────────────────────────────────────
  #
  # `String.to_charlist/1` returns a list whose every element is a
  # legal codepoint integer (non-negative, ≤ 0x10FFFF, not in the
  # surrogate range). Not the axiom but a sanity check that the
  # `length` we are measuring is over real codepoints.
  property "to_charlist elements are legal codepoint integers" do
    check all s <- legal_string() do
      for cp <- String.to_charlist(s) do
        assert is_integer(cp), "non-integer codepoint: #{inspect(cp)}"
        assert cp >= 0 and cp <= 0x10FFFF, "out-of-range codepoint: #{cp}"
        refute cp in 0xD800..0xDFFF, "surrogate codepoint in charlist: #{cp}"
      end
    end
  end

  # ── Boundary cases the property generator may rarely hit ─────────────
  #
  # Multi-byte codepoint boundaries (ASCII, Latin-1 supplement
  # boundary, BMP boundary, BMP→astral boundary, max codepoint,
  # emoji) — each is a different UTF-8 encoding width (1/2/3/4
  # bytes). Length preservation must hold across all of them.
  test "boundary strings satisfy unpackLength" do
    boundaries = [
      "",
      "a",
      "ab",
      "",
      "",
      "߿",
      "ࠀ",
      "퟿",
      "",
      "￿",
      "\u{10000}",
      "\u{10FFFF}",
      "café",
      "日本語",
      "🦀"
    ]

    for s <- boundaries do
      assert length(String.to_charlist(s)) == String.length(s),
             "unpackLength boundary violation: " <>
               "|to_charlist(#{inspect(s)})| = #{length(String.to_charlist(s))}, " <>
               "expected #{String.length(s)}"

      assert s |> String.to_charlist() |> to_string() == s,
             "round-trip boundary violation: #{inspect(s)}"
    end
  end
end
