-- One size-parameterised type refers to another.
-- ==
-- input { empty(i32) empty(i32) } output { empty(i32) empty(i32) }
-- input { [1,2,3] [1,2,3] } output { [1,2,3] [1,2,3] }
-- input { [1,2,3] [1,2,3,4] } output { [1,2,3] [1,2,3] }

type ints [n] = [n]i32

type pairints [n] [m] = (ints [n], ints [m])

let main(a: ints [#n], b: ints [#m]) : pairints [n] [n] =
  let b' = #1 (split n b)
  in (a,b')
