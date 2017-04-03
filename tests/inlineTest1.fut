-- ==
-- input {
--   42
--   1337
-- }
-- output {
--   24730855
-- }
let fun1(a: i32, b: i32): i32 = a + b

let fun2(a: i32, b: i32): i32 = fun1(a,b) * (a+b)

let fun3(a: i32, b: i32): i32 = fun2(a,b) + a + b

let main(n: i32, m: i32): i32 =
  fun1(n,m) + fun2(n+n,m+m) + fun3(3*n,3*m) + fun2(2,n) + fun3(n,3)
