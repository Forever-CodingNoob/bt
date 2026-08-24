let nan = Float.nan

let is_nan = Float.is_nan

let check_period name n =
  if n < 1 then invalid_arg (Printf.sprintf "Series.%s: period must be positive" name)

let sma s n =
  let () = check_period "sma" n in
  let len = Array.length s in
  let out = Array.make len nan in
  let rec scan i sum missing =
    if i = len then ()
    else
      let sum, missing =
        if i >= n then
          let x = s.(i - n) in
          if is_nan x then sum, missing - 1 else sum -. x, missing
        else sum, missing
      in
      let x = s.(i) in
      let sum, missing =
        if is_nan x then sum, missing + 1 else sum +. x, missing
      in
      let () =
        if i >= n - 1 && missing = 0 then
          out.(i) <- sum /. float_of_int n
      in
      scan (i + 1) sum missing
  in
  let () = scan 0 0. 0 in
  out

let stddev s n =
  let () = check_period "stddev" n in
  let len = Array.length s in
  let out = Array.make len nan in
  let rec scan i sum sum_sq missing =
    if i = len then ()
    else
      let sum, sum_sq, missing =
        if i >= n then
          let x = s.(i - n) in
          if is_nan x then sum, sum_sq, missing - 1
          else
            let sum = sum -. x in
            let sum_sq = sum_sq -. (x *. x) in
            sum, sum_sq, missing
        else sum, sum_sq, missing
      in
      let x = s.(i) in
      let sum, sum_sq, missing =
        if is_nan x then sum, sum_sq, missing + 1
        else
          let sum = sum +. x in
          let sum_sq = sum_sq +. (x *. x) in
          sum, sum_sq, missing
      in
      let () =
        if i >= n - 1 && missing = 0 then
          let mean = sum /. float_of_int n in
          let variance = max 0. ((sum_sq /. float_of_int n) -. (mean *. mean)) in
          out.(i) <- sqrt variance
      in
      scan (i + 1) sum sum_sq missing
  in
  let () = scan 0 0. 0. 0 in
  out

let ema s n =
  let () = check_period "ema" n in
  let len = Array.length s in
  let out = Array.make len nan in
  let alpha = 2. /. (float_of_int n +. 1.) in
  let rec scan i count seed_sum seeded =
    if i = len then ()
    else
      let x = s.(i) in
      if seeded then
        let () =
          out.(i) <- alpha *. x +. (1. -. alpha) *. out.(i - 1)
        in
        scan (i + 1) count seed_sum true
      else if is_nan x then scan (i + 1) count seed_sum false
      else
        let count = count + 1 in
        let seed_sum = seed_sum +. x in
        if count = n then
          let () = out.(i) <- seed_sum /. float_of_int n in
          scan (i + 1) count seed_sum true
        else scan (i + 1) count seed_sum false
  in
  let () = scan 0 0 0. false in
  out

let rsi_value avg_gain avg_loss =
  if avg_loss = 0. then 100.
  else 100. -. 100. /. (1. +. avg_gain /. avg_loss)

let gain_and_loss delta =
  if is_nan delta then nan, nan
  else if delta > 0. then delta, 0.
  else 0., -.delta

let rsi s n =
  let () = check_period "rsi" n in
  let len = Array.length s in
  let out = Array.make len nan in
  let rec scan i gain_sum loss_sum avg_gain avg_loss =
    if i >= len then ()
    else
      let gain, loss = gain_and_loss (s.(i) -. s.(i - 1)) in
      let gain_sum, loss_sum =
        if i <= n then
          let gain_sum = gain_sum +. gain in
          let loss_sum = loss_sum +. loss in
          gain_sum, loss_sum
        else gain_sum, loss_sum
      in
      if i = n then
        let avg_gain = gain_sum /. float_of_int n in
        let avg_loss = loss_sum /. float_of_int n in
        let () = out.(i) <- rsi_value avg_gain avg_loss in
        scan (i + 1) gain_sum loss_sum avg_gain avg_loss
      else if i > n then
        let avg_gain =
          (avg_gain *. float_of_int (n - 1) +. gain) /. float_of_int n
        in
        let avg_loss =
          (avg_loss *. float_of_int (n - 1) +. loss) /. float_of_int n
        in
        let () = out.(i) <- rsi_value avg_gain avg_loss in
        scan (i + 1) gain_sum loss_sum avg_gain avg_loss
      else scan (i + 1) gain_sum loss_sum avg_gain avg_loss
  in
  let () = scan 1 0. 0. nan nan in
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
  let () = check_period "atr" n in
  let len = Array.length bars in
  let out = Array.make len nan in
  let rec scan i initial_sum average =
    if i = len then ()
    else
      let tr = true_range bars i in
      let initial_sum =
        if i < n then initial_sum +. tr else initial_sum
      in
      if i = n - 1 then
        let average = initial_sum /. float_of_int n in
        let () = out.(i) <- average in
        scan (i + 1) initial_sum average
      else if i >= n then
        let average =
          (average *. float_of_int (n - 1) +. tr) /. float_of_int n
        in
        let () = out.(i) <- average in
        scan (i + 1) initial_sum average
      else scan (i + 1) initial_sum average
  in
  let () = scan 0 0. nan in
  out

let rolling_extreme name dominates s n =
  let () = check_period name n in
  let len = Array.length s in
  let out = Array.make len nan in
  let deque = Array.make len 0 in
  let rec scan i first last missing =
    if i = len then ()
    else
      let expired = i - n in
      let first, missing =
        if expired >= 0 then
          let missing =
            if is_nan s.(expired) then missing - 1 else missing
          in
          let first =
            if first < last && deque.(first) = expired then first + 1
            else first
          in
          first, missing
        else first, missing
      in
      let x = s.(i) in
      let last, missing =
        if is_nan x then last, missing + 1
        else
          let rec shrink last =
            if first < last && dominates x s.(deque.(last - 1)) then
              shrink (last - 1)
            else last
          in
          let last = shrink last in
          let () = deque.(last) <- i in
          last + 1, missing
      in
      let () =
        if i >= n - 1 && missing = 0 then out.(i) <- s.(deque.(first))
      in
      scan (i + 1) first last missing
  in
  let () = scan 0 0 0 0 in
  out

let highest s n = rolling_extreme "highest" ( >= ) s n

let lowest s n = rolling_extreme "lowest" ( <= ) s n

let lag s k =
  let () =
    if k < 0 then invalid_arg "Series.lag: lag must not be negative"
  in
  Array.init (Array.length s) (fun i -> if i < k then nan else s.(i - k))

let check_same_length name a b =
  if Array.length a <> Array.length b then
    invalid_arg (Printf.sprintf "Series.%s: length mismatch" name)

let cross_above a b =
  let () = check_same_length "cross_above" a b in
  Array.init (Array.length a) (fun i ->
      if i = 0 then false
      else
        let a0 = a.(i - 1) in
        let b0 = b.(i - 1) in
        let a1 = a.(i) in
        let b1 = b.(i) in
        not (is_nan a0 || is_nan b0 || is_nan a1 || is_nan b1)
        && a0 <= b0 && a1 > b1)

let cross_below a b =
  let () = check_same_length "cross_below" a b in
  Array.init (Array.length a) (fun i ->
      if i = 0 then false
      else
        let a0 = a.(i - 1) in
        let b0 = b.(i - 1) in
        let a1 = a.(i) in
        let b1 = b.(i) in
        not (is_nan a0 || is_nan b0 || is_nan a1 || is_nan b1)
        && a0 >= b0 && a1 < b1)

let combine name f a b =
  let () = check_same_length name a b in
  Array.init (Array.length a) (fun i -> f a.(i) b.(i))

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
