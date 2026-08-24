(** Simple moving average over a fixed period. *)
val sma : float array -> int -> float array

(** Population standard deviation over a fixed period. *)
val stddev : float array -> int -> float array

(** Exponential moving average seeded by the first complete sample. *)
val ema : float array -> int -> float array

(** Relative strength index over a fixed period. *)
val rsi : float array -> int -> float array

(** Highest value in each fixed-period window. *)
val highest : float array -> int -> float array

(** Lowest value in each fixed-period window. *)
val lowest : float array -> int -> float array

(** Lag a series by a non-negative number of bars. *)
val lag : float array -> int -> float array

(** Average true range over a fixed period. *)
val atr : Data.bar array -> int -> float array

(** Detect upward crossings between equally sized series. *)
val cross_above : float array -> float array -> bool array

(** Detect downward crossings between equally sized series. *)
val cross_below : float array -> float array -> bool array

(** Middle Bollinger band over a fixed period. *)
val bb_mid : float array -> int -> float array

(** Upper Bollinger band with the given width. *)
val bb_upper : float array -> int -> float -> float array

(** Lower Bollinger band with the given width. *)
val bb_lower : float array -> int -> float -> float array

(** Moving-average convergence/divergence line. *)
val macd : float array -> int -> int -> float array

(** Signal line for moving-average convergence/divergence. *)
val macd_signal : float array -> int -> int -> int -> float array

(** Histogram between the MACD and signal lines. *)
val macd_hist : float array -> int -> int -> int -> float array
