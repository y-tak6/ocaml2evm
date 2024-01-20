open Normalized_common_ast

type letexp = LVal of value | LApp of (value * value list)
type resexp = RVal of value | RTuple of value list

type exp =
  | Rexp of resexp
  | Seq of letexp * exp
  | Letin of string list * letexp * exp

let string_of_letexp = function
  | LVal v -> string_of_value v
  | LApp (f, xs) ->
      string_of_value f
      ^ List.fold_left (fun acc x -> acc ^ " " ^ string_of_value x) "" xs

let string_of_resexp = function
  | RVal v -> string_of_value v
  | RTuple vs ->
      "("
      ^ List.fold_left (fun acc x -> acc ^ ", " ^ string_of_value x) "" vs
      ^ ")"

let rec string_of_exp e =
  match e with
  | Rexp e -> string_of_resexp e
  | Seq (e1, e2) -> string_of_letexp e1 ^ "; " ^ string_of_exp e2
  | Letin (vars, e1, e2) ->
      "let"
      ^ List.fold_left (fun acc x -> acc ^ ", " ^ x) "" vars
      ^ " = " ^ string_of_letexp e1 ^ " in " ^ string_of_exp e2