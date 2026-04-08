module Check

import Data.List

allCons : (p : a -> Bool) -> (x : a) -> (xs : List a) ->
          all p (x :: xs) = (p x && all p xs)
allCons p x xs = Refl
