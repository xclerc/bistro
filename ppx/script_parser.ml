open Base

module Position = struct
  type t = {
    cnum : int ;
    bol : int ;
    lnum : int ;
  }
  [@@deriving sexp]

  let zero = { cnum = 0 ; bol = 0 ; lnum = 0 }
  let shift p n = { p with cnum = p.cnum + n }
  let newline p =
    { cnum = p.cnum + 1 ;
      bol = p.cnum + 1 ;
      lnum = p.lnum + 1 }

  let translate_lexing_position (q : Lexing.position) ~by:p =
  {
    q with pos_lnum = p.lnum + q.pos_lnum ;
           pos_bol = if p.lnum = 0 then q.pos_bol - 2 else q.pos_cnum + p.bol ;
           pos_cnum = p.cnum + q.pos_cnum
  }
end

type token = [
  | `Text of Position.t * Position.t
  | `Antiquotation of Position.t * Position.t
]
[@@deriving sexp]

type lexing_error = [
  | `Unmatched_opening_bracket of Position.t
  | `Unmatched_closing_bracket of Position.t
]
[@@deriving sexp]

type lexing_result = (token list, lexing_error) Result.t
[@@deriving sexp]

let lexer s : lexing_result =
  let n = String.length s in
  let opening i =
    i < n - 1 && Char.(s.[i] = '{' && s.[i + 1] = '{')
  and closing i =
    i < n - 1 && Char.(s.[i] = '}' && s.[i + 1] = '}')
  in
  let classify_current_pos { Position.cnum = i ; _ } =
    if i = n then `EOI
    else if Char.(s.[i] = '\n') then `Newline
    else if opening i then `Opening_bracket
    else if closing i then `Closing_bracket
    else `Text
  in
  let add_text_item acc start stop =
    if Position.(start.cnum < stop.cnum) then `Text (start, stop) :: acc else acc
  in
  let rec loop pos state acc =
    match classify_current_pos pos, state with
    | `EOI, `Quotation p ->
      Ok (List.rev (add_text_item acc p pos))

    | `EOI, `Antiquotation (bracket_pos, _) ->
      Error (`Unmatched_opening_bracket bracket_pos)

    | `Opening_bracket, `Quotation p ->
      let newpos = Position.shift pos 2 in
      loop newpos (`Antiquotation (pos, newpos)) (add_text_item acc p pos)

    | `Opening_bracket, `Antiquotation _ ->
      loop (Position.shift pos 2) state acc

    | `Closing_bracket, `Quotation _ ->
      Error (`Unmatched_closing_bracket pos)

    | `Closing_bracket, `Antiquotation (_, p) ->
      let newpos = Position.shift pos 2 in
      loop newpos (`Quotation newpos) (`Antiquotation (p, pos) :: acc)

    | `Newline, _ ->
      loop (Position.newline pos) state acc

    | `Text, _ ->
      loop (Position.shift pos 1) state acc
  in
  loop Position.zero (`Quotation Position.zero) []

let print_lexing_result r =
  r
  |> sexp_of_lexing_result
  |> Sexp.to_string_hum
  |> Stdio.print_string

let%expect_test "text only" =
  print_lexing_result @@ lexer "rien" ;
  [%expect {| (Ok ((Text (((cnum 0) (bol 0) (lnum 0)) ((cnum 4) (bol 0) (lnum 0)))))) |}]

let%expect_test "text only" =
  print_lexing_result @@ lexer "ad{{a}} {{e}}b" ;
  [%expect {|
    (Ok
     ((Text (((cnum 0) (bol 0) (lnum 0)) ((cnum 2) (bol 0) (lnum 0))))
      (Antiquotation (((cnum 4) (bol 0) (lnum 0)) ((cnum 5) (bol 0) (lnum 0))))
      (Text (((cnum 7) (bol 0) (lnum 0)) ((cnum 8) (bol 0) (lnum 0))))
      (Antiquotation (((cnum 10) (bol 0) (lnum 0)) ((cnum 11) (bol 0) (lnum 0))))
      (Text (((cnum 13) (bol 0) (lnum 0)) ((cnum 14) (bol 0) (lnum 0)))))) |}]

let%expect_test "text + antiquot" =
  print_lexing_result @@ lexer "ri{{en}}{{}}";
  [%expect {|
    (Ok
     ((Text (((cnum 0) (bol 0) (lnum 0)) ((cnum 2) (bol 0) (lnum 0))))
      (Antiquotation (((cnum 4) (bol 0) (lnum 0)) ((cnum 6) (bol 0) (lnum 0))))
      (Antiquotation (((cnum 10) (bol 0) (lnum 0)) ((cnum 10) (bol 0) (lnum 0)))))) |}]

let%expect_test "text + antiquot + eol" =
  print_lexing_result @@ lexer "ri{{en}}\n{{du \n tout}}";
  [%expect {|
    (Ok
     ((Text (((cnum 0) (bol 0) (lnum 0)) ((cnum 2) (bol 0) (lnum 0))))
      (Antiquotation (((cnum 4) (bol 0) (lnum 0)) ((cnum 6) (bol 0) (lnum 0))))
      (Text (((cnum 8) (bol 0) (lnum 0)) ((cnum 9) (bol 9) (lnum 1))))
      (Antiquotation
       (((cnum 11) (bol 9) (lnum 1)) ((cnum 20) (bol 15) (lnum 2)))))) |}]
