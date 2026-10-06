(* JSON-RPC 2.0 framing for the LSP base protocol over stdio.

   Every packet is `Content-Length: <bytes>\r\n\r\n<json>`. The server
   reads requests and notifications, and writes responses and
   notifications. Only what the Emo server needs is implemented. *)

type incoming =
  | Request of { id : Yojson.Safe.t; method_ : string; params : Yojson.Safe.t }
  | Notification of { method_ : string; params : Yojson.Safe.t }

type t = incoming

let empty_params = `Assoc []

(* Reads one packet. Returns [None] on a clean end of input. *)
let read (ic : in_channel) : incoming option =
  let rec headers (content_length : int option) =
    match input_line ic with
    | exception End_of_file -> content_length
    | line -> (
        let line = String.trim line in
        if line = "" then content_length
        else
          match String.index_opt line ':' with
          | Some i ->
              let key = String.trim (String.sub line 0 i) in
              let value =
                String.trim
                  (String.sub line (i + 1) (String.length line - i - 1))
              in
              if String.lowercase_ascii key = "content-length" then
                headers (int_of_string_opt value)
              else headers content_length
          | None -> headers content_length)
  in
  match headers None with
  | None -> None
  | Some len -> (
      let buf = Bytes.create len in
      let rec read_all off =
        if off >= len then true
        else
          let n = input ic buf off (len - off) in
          if n = 0 then false else read_all (off + n)
      in
      if not (read_all 0) then None
      else
        let body = Bytes.to_string buf in
        match Yojson.Safe.from_string body with
        | exception _ ->
            Some
              (Notification { method_ = "$/parse-error"; params = empty_params })
        | json -> (
            let method_ =
              match Yojson.Safe.Util.member "method" json with
              | `String m -> m
              | _ -> ""
            in
            let params =
              match Yojson.Safe.Util.member "params" json with
              | `Null -> empty_params
              | p -> p
            in
            match Yojson.Safe.Util.member "id" json with
            | `Null when method_ <> "" ->
                Some (Notification { method_; params })
            | `Null -> None
            | id -> Some (Request { id; method_; params })))

(* Writes one JSON value framed with its Content-Length. *)
let write_raw (oc : out_channel) (json : Yojson.Safe.t) : unit =
  let body = Yojson.Safe.to_string json in
  Printf.fprintf oc "Content-Length: %d\r\n\r\n%s" (String.length body) body;
  flush oc

let respond (oc : out_channel) ~(id : Yojson.Safe.t) (result : Yojson.Safe.t) :
    unit =
  write_raw oc
    (`Assoc [ ("jsonrpc", `String "2.0"); ("id", id); ("result", result) ])

let respond_error (oc : out_channel) ~(id : Yojson.Safe.t) ~(code : int)
    ~(message : string) : unit =
  write_raw oc
    (`Assoc
       [
         ("jsonrpc", `String "2.0");
         ("id", id);
         ("error", `Assoc [ ("code", `Int code); ("message", `String message) ]);
       ])

let notify (oc : out_channel) ~(method_ : string) (params : Yojson.Safe.t) :
    unit =
  write_raw oc
    (`Assoc
       [
         ("jsonrpc", `String "2.0");
         ("method", `String method_);
         ("params", params);
       ])

(* A server-initiated request (used for client-side edits such as
   workspace/applyEdit). *)
let request (oc : out_channel) ~(id : int) ~(method_ : string)
    (params : Yojson.Safe.t) : unit =
  write_raw oc
    (`Assoc
       [
         ("jsonrpc", `String "2.0");
         ("id", `Int id);
         ("method", `String method_);
         ("params", params);
       ])
