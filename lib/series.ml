let nan = Float.nan

let is_nan = Float.is_nan

let check_period name n =
  if n < 1 then invalid_arg (Printf.sprintf "Series.%s: period must be positive" name)

let sma s n =
  check_period "sma" n;
  let len = Array.length s in
  let out = Array.make len nan in
  let sum = ref 0. in
  let missing = ref 0 in
  for i = 0 to len - 1 do
    if i >= n then begin
      let x = s.(i - n) in
      if is_nan x then decr missing else sum := !sum -. x
    end;
    let x = s.(i) in
    if is_nan x then incr missing else sum := !sum +. x;
    if i >= n - 1 && !missing = 0 then
      out.(i) <- !sum /. float_of_int n
  done;
  out

let stddev s n =
  check_period "stddev" n;
  let len = Array.length s in
  let out = Array.make len nan in
  let sum = ref 0. in
  let sum_sq = ref 0. in
  let missing = ref 0 in
  for i = 0 to len - 1 do
    if i >= n then begin
      let x = s.(i - n) in
      if is_nan x then decr missing
      else begin
        sum := !sum -. x;
        sum_sq := !sum_sq -. (x *. x)
      end
    end;
    let x = s.(i) in
    if is_nan x then incr missing
    else begin
      sum := !sum +. x;
      sum_sq := !sum_sq +. (x *. x)
    end;
    if i >= n - 1 && !missing = 0 then begin
      let mean = !sum /. float_of_int n in
      let variance = max 0. ((!sum_sq /. float_of_int n) -. (mean *. mean)) in
      out.(i) <- sqrt variance
    end
  done;
  out

let ema s n =
  check_period "ema" n;
  let len = Array.length s in
  let out = Array.make len nan in
  let alpha = 2. /. (float_of_int n +. 1.) in
  let count = ref 0 in
  let seed_sum = ref 0. in
  let seeded = ref false in
  for i = 0 to len - 1 do
    let x = s.(i) in
    if not !seeded then begin
      if not (is_nan x) then begin
        incr count;
        seed_sum := !seed_sum +. x;
        if !count = n then begin
          out.(i) <- !seed_sum /. float_of_int n;
          seeded := true
        end
      end
    end
    else
      out.(i) <- alpha *. x +. (1. -. alpha) *. out.(i - 1)
  done;
  out

let rsi_value avg_gain avg_loss =
  if avg_loss = 0. then 100.
  else 100. -. 100. /. (1. +. avg_gain /. avg_loss)

let gain_and_loss delta =
  if is_nan delta then nan, nan
  else if delta > 0. then delta, 0.
  else 0., -.delta

let rsi s n =
  check_period "rsi" n;
  let len = Array.length s in
  let out = Array.make len nan in
  let gain_sum = ref 0. in
  let loss_sum = ref 0. in
  let avg_gain = ref nan in
  let avg_loss = ref nan in
  for i = 1 to len - 1 do
    let gain, loss = gain_and_loss (s.(i) -. s.(i - 1)) in
    if i <= n then begin
      gain_sum := !gain_sum +. gain;
      loss_sum := !loss_sum +. loss
    end;
    if i = n then begin
      avg_gain := !gain_sum /. float_of_int n;
      avg_loss := !loss_sum /. float_of_int n;
      out.(i) <- rsi_value !avg_gain !avg_loss
    end
    else if i > n then begin
      avg_gain := (!avg_gain *. float_of_int (n - 1) +. gain) /. float_of_int n;
      avg_loss := (!avg_loss *. float_of_int (n - 1) +. loss) /. float_of_int n;
      out.(i) <- rsi_value !avg_gain !avg_loss
    end
  done;
  out

let max_nan a b =
  if is_nan a || is_nan b then nan else if a > b then a else b

let true_range (bars : Data.bar array) i =
  let bar = bars.(i) in
  let range = bar.Data.h -. bar.Data.l in
  if i = 0 then range
  else
    let previous_close = bars.(i - 1).Data.c in
    max_nan range
      (max_nan (abs_float (bar.Data.h -. previous_close))
         (abs_float (bar.Data.l -. previous_close)))

let atr (bars : Data.bar array) n =
  check_period "atr" n;
  let len = Array.length bars in
  let out = Array.make len nan in
  let initial_sum = ref 0. in
  let average = ref nan in
  for i = 0 to len - 1 do
    let tr = true_range bars i in
    if i < n then initial_sum := !initial_sum +. tr;
    if i = n - 1 then begin
      average := !initial_sum /. float_of_int n;
      out.(i) <- !average
    end
    else if i >= n then begin
      average := (!average *. float_of_int (n - 1) +. tr) /. float_of_int n;
      out.(i) <- !average
    end
  done;
  out

let rolling_extreme name dominates s n =
  check_period name n;
  let len = Array.length s in
  let out = Array.make len nan in
  let deque = Array.make len 0 in
  let first = ref 0 in
  let last = ref 0 in
  let missing = ref 0 in
  for i = 0 to len - 1 do
    let expired = i - n in
    if expired >= 0 then begin
      if is_nan s.(expired) then decr missing;
      if !first < !last && deque.(!first) = expired then incr first
    end;
    let x = s.(i) in
    if is_nan x then incr missing
    else begin
      while !first < !last && dominates x s.(deque.(!last - 1)) do
        decr last
      done;
      deque.(!last) <- i;
      incr last
    end;
    if i >= n - 1 && !missing = 0 then out.(i) <- s.(deque.(!first))
  done;
  out

let highest s n = rolling_extreme "highest" ( >= ) s n

let lowest s n = rolling_extreme "lowest" ( <= ) s n

let lag s k =
  if k < 0 then invalid_arg "Series.lag: lag must not be negative";
  let len = Array.length s in
  let out = Array.make len nan in
  for i = k to len - 1 do
    out.(i) <- s.(i - k)
  done;
  out

let check_same_length name a b =
  if Array.length a <> Array.length b then
    invalid_arg (Printf.sprintf "Series.%s: length mismatch" name)

let cross_above a b =
  check_same_length "cross_above" a b;
  let len = Array.length a in
  let out = Array.make len false in
  for i = 1 to len - 1 do
    let a0 = a.(i - 1) in
    let b0 = b.(i - 1) in
    let a1 = a.(i) in
    let b1 = b.(i) in
    if not (is_nan a0 || is_nan b0 || is_nan a1 || is_nan b1) then
      out.(i) <- a0 <= b0 && a1 > b1
  done;
  out

let cross_below a b =
  check_same_length "cross_below" a b;
  let len = Array.length a in
  let out = Array.make len false in
  for i = 1 to len - 1 do
    let a0 = a.(i - 1) in
    let b0 = b.(i - 1) in
    let a1 = a.(i) in
    let b1 = b.(i) in
    if not (is_nan a0 || is_nan b0 || is_nan a1 || is_nan b1) then
      out.(i) <- a0 >= b0 && a1 < b1
  done;
  out

let combine name f a b =
  check_same_length name a b;
  let len = Array.length a in
  let out = Array.make len nan in
  for i = 0 to len - 1 do
    out.(i) <- f a.(i) b.(i)
  done;
  out

let bb_mid s n = sma s n

let bb_upper s n k =
  let middle = sma s n in
  let deviation = stddev s n in
  combine "bb_upper" (fun mean sigma -> mean +. k *. sigma) middle deviation

let bb_lower s n k =
  let middle = sma s n in
  let deviation = stddev s n in
  combine "bb_lower" (fun mean sigma -> mean -. k *. sigma) middle deviation

let macd s fast slow =
  let fast_line = ema s fast in
  let slow_line = ema s slow in
  combine "macd" ( -. ) fast_line slow_line

let macd_signal s fast slow signal = ema (macd s fast slow) signal

let macd_hist s fast slow signal =
  let line = macd s fast slow in
  let signal_line = ema line signal in
  combine "macd_hist" ( -. ) line signal_line
