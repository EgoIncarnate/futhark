-- Memory block merging with a concat of multiple arrays into a multidimensional
-- array.
-- ==
-- input { [5, 15]
--         0
--       }
-- output { [[6, 16, 10, 30, 1, 5],
--           [0, 1, 2, 3, 4, 5]]
--        }

let main (ns: [#n]i32, i: i32): [][]i32 =
  let t_final = replicate n (iota (n * 3))
  let t0 = map (+ 1) ns
  let t1 = map (* 2) ns
  let t2 = map (/ 3) ns
  let t_final[i] = concat t0 t1 t2
  in t_final
