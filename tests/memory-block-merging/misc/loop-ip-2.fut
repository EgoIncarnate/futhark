-- Very Simple Example of Loop Coalescing.
-- ==
-- input {  [ [1,2], [3,4] ]
--          [1,2]
--       }
-- output {
--          [ [1i32, 9i32], [1i32, 3i32] ]
--        }

import "/futlib/array"

-- Code below should result in 1 mem-block coalescing,
-- corresponding to 4 coalesced variables.
let main(y: *[#n][#m]i32, a : [#m]i32): *[n][m]i32 =
  let y[0,1] = 9
  let a0 = copy(a)
  let a1 = loop(a1 = a0) for i < m do
    let a1[i] = i+a1[i]
    in  a1

  let y[n/2] = a1
  in  y
