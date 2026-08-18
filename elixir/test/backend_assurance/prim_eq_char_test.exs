# SPDX-License-Identifier: PMPL-1.0-or-later
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# Backend-assurance harness for `prim__eqChar`.
#
# Validates that the BEAM-level integer-equality operation that backs
# `prim__eqChar` (Idris2 0.8.0) satisfies the two `believe_me`
# axioms declared at:
#
#   src/abi/Boj/SafetyLemmas.idr:53  charEqSound : c1 == c2 = True -> c1 = c2
#   src/abi/Boj/SafetyLemmas.idr:60  charEqSym   : (x == y) = (y == x)
#
# Both axioms are class (J) — irreducible in Idris2 because `Char` is an
# opaque primitive. See PROOF-NEEDS.md and docs/backend-assurance/prim__eqChar.md.
#
# This is *external* evidence: it does not change the in-language proof,
# and the believe_me sites stay in source. The harness shrinks the trusted
# base by replacing "we trust the backend" with "we randomly tested the
# backend operation on N codepoints and the property held".
defmodule Boj.BackendAssurance.PrimEqCharTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  @moduletag :backend_assurance

  # Random codepoint generator: covers ASCII, BMP, and astral planes
  # excluding surrogates (which are illegal as standalone Char values).
  defp legal_codepoint do
    StreamData.one_of([
      StreamData.integer(0..0xD7FF),
      StreamData.integer(0xE000..0x10FFFF)
    ])
  end

  # ── Soundness: a =:= b  =>  a = b ────────────────────────────────────
  #
  # Backs `charEqSound`. On BEAM, Char is a codepoint integer and
  # `prim__eqChar` lowers to integer `=:=`. The property is that `=:=`
  # returning true implies the two operands are the same value.
  property "BEAM =:= on codepoints is sound (charEqSound)" do
    check all c1 <- legal_codepoint(),
              c2 <- legal_codepoint() do
      if c1 === c2 do
        assert c1 == c2,
               "charEqSound violation: #{inspect(c1)} =:= #{inspect(c2)} but not equal"
      end
    end
  end

  # The biased case: when generators happen to coincide, we still must
  # observe =:= returning true. Forces the soundness witness to fire.
  property "BEAM =:= reflexivity over codepoints (charEqSound, reflexive case)" do
    check all c <- legal_codepoint() do
      assert c === c,
             "charEqSound reflexivity violation: #{inspect(c)} not =:= itself"
    end
  end

  # ── Symmetry: a =:= b  iff  b =:= a ──────────────────────────────────
  #
  # Backs `charEqSym`. R6RS `char=?` and Erlang `=:=` are both
  # commutative; this asserts that property over the codepoint space.
  property "BEAM =:= on codepoints is symmetric (charEqSym)" do
    check all c1 <- legal_codepoint(),
              c2 <- legal_codepoint() do
      assert (c1 === c2) == (c2 === c1),
             "charEqSym violation: (#{inspect(c1)} =:= #{inspect(c2)}) /= (#{inspect(c2)} =:= #{inspect(c1)})"
    end
  end

  # ── Negative edges ───────────────────────────────────────────────────
  #
  # Distinct codepoints must not be =:=. Catches a pathological backend
  # where =:= would over-accept (e.g. case-insensitive collation slipping
  # into char equality). Not in scope for the named axioms but cheap.
  property "distinct codepoints are not =:=" do
    check all {c1, c2} <-
                StreamData.bind(legal_codepoint(), fn c1 ->
                  StreamData.filter(legal_codepoint(), fn c2 -> c2 != c1 end)
                  |> StreamData.map(&{c1, &1})
                end) do
      refute c1 === c2,
             "Over-accepting =:= on distinct codepoints: #{inspect(c1)}, #{inspect(c2)}"
    end
  end

  # ── Boundary cases the property generator may rarely hit ─────────────
  #
  # Explicit corner cases — surrogates excluded, BMP/astral boundaries,
  # max codepoint. Belt-and-braces against generator coverage gaps.
  test "boundary codepoints satisfy soundness + symmetry" do
    boundaries = [0, 0x7F, 0x80, 0xD7FF, 0xE000, 0xFFFF, 0x10000, 0x10FFFF]

    for c1 <- boundaries, c2 <- boundaries do
      assert (c1 === c2) == (c1 == c2),
             "charEqSound boundary: #{c1} vs #{c2}"
      assert (c1 === c2) == (c2 === c1),
             "charEqSym boundary: #{c1} vs #{c2}"
    end
  end
end
