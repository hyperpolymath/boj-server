-- SPDX-License-Identifier: PMPL-1.0-or-later
-- Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
module Check

import Data.List

allCons : (p : a -> Bool) -> (x : a) -> (xs : List a) ->
          all p (x :: xs) = (p x && all p xs)
allCons p x xs = Refl
