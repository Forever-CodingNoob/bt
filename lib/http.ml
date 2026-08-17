(* In-process HTTPS via the system libcurl (see curl_stubs.c). libcurl
   honors https_proxy/http_proxy and the system CA store, matching what
   the curl binary did before. *)

external get_stub : string -> string -> string -> int * string = "bt_curl_get"

let get ~token ~url ~output =
  let status, message =
    get_stub url ("Authorization: Bearer " ^ token) output
  in
  if status = 0 then Error message else Ok status
