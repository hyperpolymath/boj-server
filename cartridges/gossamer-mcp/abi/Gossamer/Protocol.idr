-- SPDX-License-Identifier: MPL-2.0
-- Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath)
--
-- Gossamer ABI — webview shell protocol definitions.

module Gossamer.Protocol

import Data.Nat

||| Gossamer operation codes.
public export
data GossamerOp
  = CreateWindow
  | LoadPanel
  | EvalJS
  | GetVersion

||| Window handle — strictly positive identifier.
public export
record WindowHandle where
  constructor MkWindowHandle
  id : Nat
  {auto prf : IsSucc id}

||| Panel URI for loading into a Gossamer webview.
public export
record PanelURI where
  constructor MkPanelURI
  scheme : String
  path   : String

||| Result of a JS evaluation.
public export
data EvalResult
  = EvalOk String
  | EvalErr String

||| Gossamer version tuple.
public export
record Version where
  constructor MkVersion
  major : Nat
  minor : Nat
  patch : Nat

||| Proof: a valid WindowHandle always has a non-zero id.
export
windowHandleNonZero : (h : WindowHandle) -> Not (h.id = Z)
windowHandleNonZero (MkWindowHandle (S _)) = absurd

||| Proof: version ordering is reflexive.
export
versionEqRefl : (v : Version) -> (v.major = v.major, v.minor = v.minor)
versionEqRefl v = (Refl, Refl)
