type config = {
  fill : Engine.fill;
  leverage : float;
  costs : Engine.costs;
  capital : float;
}

type fill = {
  time : string;
  price : float;
  from_exposure : float;
  to_exposure : float;
}

type result = {
  session_dates : string array;
  equity : float array;
  fills : fill list;
  trades : int;
  wins : int;
  flat_forced : int;
}

type account = {
  cash : float;
  shares : float;
  target : float;
  entry_equity : float;
  fills_rev : fill list;
  trades : int;
  wins : int;
  flat_forced : int;
}

let run (config : config) ~sessions ~(bars : Data.bar array) ~targets ~initial_equity =
  let () =
    if not (Float.is_finite config.capital && config.capital > 0.) then
      invalid_arg "Intraday.run: capital must be positive and finite"
  in
  let normalize target =
    if Float.is_nan target then 0.
    else if target < 0. then failwith "short targets are reserved"
    else Float.min config.leverage target
  in
  let costs = [|config.costs|] in
  let charge = Engine.charge costs config.capital 0 in
  let sell_cost = Engine.absolute_sell_cost costs config.capital 0 in
  let execute ~cap ~time ~price target account =
    let current = account.shares *. price in
    let e0 = account.cash +. current in
    let plan e1 =
      let value = Float.max 0. (Float.min cap (target *. e1)) in
      let delta = value -. current in
      let cost =
        if delta = 0. then 0.
        else if delta < 0. then sell_cost ~price (-. delta)
        else charge ~equity_before:e1 ~delta:(delta /. e1) ~price *. e1
      in
      value, delta, cost
    in
    let rec solve remaining e1 =
      if remaining = 0 then e1
      else
        let _, _, cost = plan e1 in
        let next = e0 -. cost in
        if next <= 0. then e1
        else if abs_float (next -. e1) <= 1e-15 *. abs_float e0 then next
        else solve (remaining - 1) next
    in
    let basis = solve 20 e0 in
    let value, delta, cost = plan basis in
    if delta = 0. then { account with target }
    else
      let cash = account.cash -. delta -. cost in
      let entry_equity =
        if account.shares = 0. then e0 else account.entry_equity
      in
      let closed = account.shares <> 0. && value = 0. in
      let event = {
        time; price;
        from_exposure = current /. e0;
        to_exposure = if value = 0. then 0. else value /. basis;
      } in
      { cash; shares = value /. price; target; entry_equity;
        fills_rev = event :: account.fills_rev;
        trades = account.trades + if closed then 1 else 0;
        wins = account.wins + if closed && cash > entry_equity then 1 else 0;
        flat_forced = account.flat_forced }
  in
  let initial = {
    cash = initial_equity; shares = 0.; target = 0.; entry_equity = initial_equity;
    fills_rev = []; trades = 0; wins = 0; flat_forced = 0;
  } in
  let count = Array.length bars in
  let session (cursor, account, dates_rev, equity_rev) (session : Data.session) =
    let start = session.date ^ "T" ^ session.open_ in
    let end_ = session.date ^ "T" ^ session.close in
    let rec collect index acc =
      if index = count || bars.(index).date >= end_ then index, List.rev acc
      else if bars.(index).date < start then collect (index + 1) acc
      else collect (index + 1) (index :: acc)
    in
    let cursor, indices = collect cursor [] in
    match indices with
    | [] -> cursor, account, dates_rev, equity_rev
    | _ ->
        let last = cursor - 1 in
        let cap = config.leverage *. account.cash in
        let step (account, previous) index =
          let bar = bars.(index) in
          let decision =
            match config.fill, previous with
            | Engine.Close_same, _ when index <> last -> Some index
            | Engine.Open_next, Some previous -> Some previous
            | _ -> None
          in
          let account =
            match decision with
            | None -> account
            | Some decision ->
                let target = normalize targets.(decision) in
                if target = account.target then account
                else
                  let price = match config.fill with
                    | Engine.Close_same -> bar.c
                    | Engine.Open_next -> bar.o
                  in
                  execute ~cap ~time:bar.date ~price target account
          in
          let account =
            if index = last && account.shares <> 0. then
              let account = execute ~cap ~time:bar.date ~price:bar.c 0. account in
              { account with flat_forced = account.flat_forced + 1 }
            else account
          in
          account, Some index
        in
        let account, _ = List.fold_left step (account, None) indices in
        let account = { account with target = 0. } in
        cursor, account, session.date :: dates_rev, account.cash :: equity_rev
  in
  let _, account, dates_rev, equity_rev =
    Array.fold_left session (0, initial, [], []) sessions
  in
  { session_dates = Array.of_list (List.rev dates_rev);
    equity = Array.of_list (List.rev equity_rev);
    fills = List.rev account.fills_rev;
    trades = account.trades; wins = account.wins; flat_forced = account.flat_forced }
