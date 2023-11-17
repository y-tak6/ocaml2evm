(* to use results of parsing *)
open Typedtree
open Asttypes
open Path

(* for keccak256 *)
open Digestif

(* Yul and ABI *)
open Yul_ast
open Abi_json

exception Not_implemented
exception Undefined_storage
exception Not_allowed_function

(* names of default runtime *)
let runtime = Strlit "runtime"

(* deploy code part *)
let deploy_code =
  Code
    [
      Exp (EVM (Sstore (Literal (Dec 0), EVM Caller)));
      Exp
        (EVM
           (Datacopy
              (Literal (Dec 0), EVM (Dataoffset runtime), EVM (Datasize runtime))));
      Exp (EVM (Return (Literal (Dec 0), EVM (Datasize runtime))));
    ]

(* names of default functions *)
let return_uint = "returnUint"
let get_storage = "getStorage"
let set_storage = "setStorage"
let selector = "selector"
let decode_as_uint = "decodeAsUint"
let decode_as_address = "decodeAsAddress"

(* definitions of default functions *)
let return_uint_def =
  let arg = "v" in
  FunctionDef
    ( return_uint,
      [ arg ],
      None,
      [
        Exp (EVM (Mstore (Literal (Dec 0), ID arg)));
        Exp (EVM (Return (Literal (Dec 0), Literal (Hex 32))));
      ] )

let get_storage_def =
  let return_arg = "ret" in
  FunctionDef
    ( get_storage,
      [],
      Some return_arg,
      [ Assign ((return_arg, []), EVM (Sload (Literal (Dec 1)))) ] )

let set_storage_def =
  let arg = "v" in
  FunctionDef
    ( set_storage,
      [ arg ],
      None,
      [ Exp (EVM (Sstore (Literal (Dec 1), ID arg))) ] )

let selector_def =
  let return_arg = "ret" in
  FunctionDef
    ( selector,
      [],
      Some return_arg,
      [
        Assign
          ( (return_arg, []),
            EVM (Shr (Literal (Dec 224), EVM (Calldataload (Literal (Dec 0)))))
          );
      ] )

let decode_as_uint_def =
  let arg = "offset" in
  let return_arg = "v" in
  let pos = "pos" in
  FunctionDef
    ( decode_as_uint,
      [ arg ],
      Some return_arg,
      [
        Let
          ( (pos, []),
            EVM (Add (Literal (Dec 4), EVM (Mul (ID arg, Literal (Hex 32))))) );
        Assign ((return_arg, []), EVM (Calldataload (ID pos)));
      ] )

let default_revert_def =
  Default [ Exp (EVM (Revert (Literal (Dec 0), Literal (Dec 0)))) ]

let default_function_defs =
  [
    return_uint_def;
    get_storage_def;
    set_storage_def;
    selector_def;
    decode_as_uint_def;
  ]

(* splitting signatures to the types part and vals part *)
let rec split_module_sig = function
  | [] -> ([], [])
  | x :: xs -> (
      let types, vals = split_module_sig xs in
      match x.sig_desc with
      | Tsig_type (_, y) -> (y @ types, vals)
      | Tsig_value y -> (types, y :: vals)
      | _ -> raise Not_implemented)

let rec pairlist_to_listpair f = function
  | [] -> ([], [])
  | x :: xs ->
      let x1, x2 = f x in
      let xs1, xs2 = pairlist_to_listpair f xs in
      (x1 :: xs1, x2 :: xs2)

(* name of storage type *)
(* for now, storage type must be int *)
let storage_name = function
  | [ { typ_id = s; _ } ] -> s
  | _ -> raise Not_implemented

let abi_input_of_typ s =
  if Ident.name s = "int" then [ { input_name = ""; input_type = Uint256 } ]
  else if Ident.name s = "unit" then []
  else raise Not_implemented

let abi_output_of_typ s =
  if Ident.name s = "int" then [ { output_name = ""; output_type = Uint256 } ]
  else if Ident.name s = "unit" then []
  else raise Not_implemented

let keccak_256_for_abi func_sig =
  Strlit
    ("0x"
    ^ String.sub
        (KECCAK_256.to_hex
           (KECCAK_256.get (KECCAK_256.feed_string KECCAK_256.empty func_sig)))
        0 8)

let params_in_case inputs =
  let decoder = function
    | Uint256 -> decode_as_uint
    | Address -> decode_as_address
  in
  let rec aux n = function
    | [] -> []
    | { input_type = x; _ } :: xs ->
        FunctionCall (decoder x, [ Literal (Dec n) ]) :: aux (n + 1) xs
  in
  aux 0 inputs

let returner_in_case = function
  | [] -> None
  | [ { output_type = x; _ } ] -> (
      match x with
      | Uint256 -> Some return_uint
      | Address -> raise Not_implemented)
  | _ -> raise Not_implemented

(* accesible functions must be the form "params -> storage -> (return val, storage)" *)
(* generating (ABI, (func_name, keccak256 of a function signature)) from a signature  *)
let abi_of_sig stor = function
  | { val_id = name; val_desc = { ctyp_desc = core_desc; _ }; _ } -> (
      match core_desc with
      | Ttyp_arrow
          ( _,
            { ctyp_desc = Ttyp_constr (Path.Pident arg, _, _); _ },
            {
              ctyp_desc =
                Ttyp_arrow
                  ( _,
                    { ctyp_desc = Ttyp_constr (Path.Pident s1, _, _); _ },
                    {
                      ctyp_desc =
                        Ttyp_tuple
                          [
                            {
                              ctyp_desc = Ttyp_constr (Path.Pident ret, _, _);
                              _;
                            };
                            {
                              ctyp_desc = Ttyp_constr (Path.Pident s2, _, _);
                              _;
                            };
                          ];
                      _;
                    } );
              _;
            } ) ->
          if Ident.same stor s1 && Ident.same stor s2 then
            let func_name = Ident.name name in
            let inputs = abi_input_of_typ arg in
            let outputs = abi_output_of_typ ret in
            let abi =
              {
                abi_name = func_name;
                abi_type = Func;
                abi_inputs = inputs;
                abi_outputs = outputs;
                abi_mutability = Nonpayable;
              }
            in
            ( abi,
              ( func_name,
                keccak_256_for_abi (signature_of_function abi),
                params_in_case inputs,
                returner_in_case outputs ) )
          else raise Not_implemented
      | _ -> raise Not_allowed_function)

let rec translate_exp = function
  | Texp_ident (Pident s, _, _) -> ID (Ident.unique_name s)
  | Texp_constant (Const_int n) -> Literal (Dec n)
  | Texp_apply (f, args) -> (
      match (f, args) with
      | ( { exp_desc = Texp_ident (Pdot (_, s), _, _); _ },
          [
            (Nolabel, Some { exp_desc = e1; _ });
            (Nolabel, Some { exp_desc = e2; _ });
          ] ) ->
          if s = "+" then EVM (Add (translate_exp e1, translate_exp e2))
          else raise Not_implemented
      | _ -> raise Not_implemented)
  | _ -> raise Not_implemented

(* splitting module structure to types and external vals and internal vas *)
let rec split_module_str = function
  | [] -> ([], [])
  | x :: xs -> (
      let types, exps = split_module_str xs in
      match x.str_desc with
      | Tstr_type (_, y) -> (y :: types, exps)
      | Tstr_value (_, y) -> (types, y :: exps)
      | _ -> raise Not_implemented)

let translate_external_func func_sigs = function
  | {
      vb_pat = { pat_desc = Tpat_var (func_name, _); _ };
      vb_expr = { exp_desc = e; _ };
      _;
    }
    :: [] -> (
      match
        List.find_opt (fun (x, _, _, _) -> x = Ident.name func_name) func_sigs
      with
      | Some (_, sig_string, params, returner) -> (
          match e with
          | Texp_function
              {
                cases =
                  {
                    c_lhs = { pat_desc = Tpat_var (arg, _); _ };
                    c_rhs =
                      {
                        exp_desc =
                          Texp_function
                            {
                              cases =
                                {
                                  c_lhs =
                                    { pat_desc = Tpat_var (storage, _); _ };
                                  c_rhs =
                                    {
                                      exp_desc =
                                        Texp_tuple
                                          [
                                            { exp_desc = e1; _ };
                                            { exp_desc = e2; _ };
                                          ];
                                      _;
                                    };
                                  _;
                                }
                                :: [];
                              _;
                            };
                        _;
                      };
                    _;
                  }
                  :: [];
                _;
              } ->
              let func_name = Ident.unique_name func_name in
              let return_arg = "ret" in
              let return_arg, return_exp, case_result =
                match returner with
                | Some return_func ->
                    ( Some return_arg,
                      [ Assign ((return_arg, []), translate_exp e1) ],
                      [
                        Exp
                          (FunctionCall
                             (return_func, [ FunctionCall (func_name, params) ]));
                      ] )
                | None -> (None, [], [ Exp (FunctionCall (func_name, params)) ])
              in
              ( FunctionDef
                  ( func_name,
                    [ Ident.unique_name arg ],
                    return_arg,
                    [
                      Let
                        ( (Ident.unique_name storage, []),
                          FunctionCall (get_storage, []) );
                      Exp (FunctionCall (set_storage, [ translate_exp e2 ]));
                    ]
                    @ return_exp ),
                Some (Case (Str sig_string, case_result)) )
          | _ -> raise Not_implemented)
      | None -> raise Not_implemented)
  | _ -> raise Not_implemented

let backend _ Typedtree.{ structure; _ } =
  match structure with
  | {
   str_items =
     [
       {
         str_desc =
           Tstr_module
             {
               mb_id = Some contract_name;
               mb_expr =
                 {
                   mod_desc =
                     Tmod_constraint
                       ( {
                           mod_desc = Tmod_structure { str_items = items; _ };
                           _;
                         },
                         _,
                         Tmodtype_explicit
                           {
                             mty_desc = Tmty_signature { sig_items = sigs; _ };
                             _;
                           },
                         _ );
                   _;
                 };
               _;
             };
         _;
       };
     ];
   _;
  } ->
      let contract_name = Ident.name contract_name in
      (* getting storage id and signatures *)
      let stor, sigs = split_module_sig sigs in
      let stor = storage_name stor in
      (* getting ABI and function signatures *)
      let abis, func_sigs = pairlist_to_listpair (abi_of_sig stor) sigs in
      (* getting val expression (types are not yet implemented) *)
      let _, exps = split_module_str items in
      (* getting function declarations and dispatcher cases *)
      let funcs, cases =
        pairlist_to_listpair (translate_external_func func_sigs) exps
      in
      (* code fragment: dispatcher *)
      let dispatcher =
        let cases = List.filter_map (fun x -> x) cases in
        Switch (FunctionCall (selector, []), cases, default_revert_def)
      in
      (* generating whole Yul code *)
      let yul_code =
        json_string_of_yul
          (Object
             ( Strlit contract_name,
               deploy_code,
               Some
                 (Object
                    ( runtime,
                      Code ((dispatcher :: funcs) @ default_function_defs),
                      None )) ))
      in
      (* json provided for solc *)
      let yul_json : Yojson.Basic.t =
        `Assoc
          [
            ("language", `String "Yul");
            ( "sources",
              `Assoc
                [ ("destructible", `Assoc [ ("content", `String yul_code) ]) ]
            );
            ( "settings",
              `Assoc
                [
                  ( "outputSelection",
                    `Assoc
                      [
                        ( "*",
                          `Assoc
                            [
                              ( "*",
                                `List
                                  [
                                    `String "evm.bytecode.object";
                                    `String "evm.deployedBytecode.object";
                                  ] );
                            ] );
                      ] );
                ] );
          ]
      in
      (* solc compilation result *)
      let tmp_json_name = "___" ^ contract_name ^ ".json" in
      Yojson.Basic.to_file tmp_json_name yul_json;
      let compiled_json =
        Unix.open_process_in ("solc --standard-json " ^ tmp_json_name)
        |> Yojson.Basic.from_channel
      in
      Sys.remove tmp_json_name;
      (* getting required values *)
      let evm_field =
        compiled_json
        |> Yojson.Basic.Util.member "contracts"
        |> Yojson.Basic.Util.member "destructible"
        |> Yojson.Basic.Util.member contract_name
        |> Yojson.Basic.Util.member "evm"
      in
      let bytecode : Yojson.Basic.t =
        `Assoc
          [
            ( "bytecode",
              evm_field
              |> Yojson.Basic.Util.member "bytecode"
              |> Yojson.Basic.Util.member "object" );
          ]
      in
      let deployed_bytecode : Yojson.Basic.t =
        `Assoc
          [
            ( "deployedBytecode",
              evm_field
              |> Yojson.Basic.Util.member "deployedBytecode"
              |> Yojson.Basic.Util.member "object" );
          ]
      in
      (* combining ABI and solc compilation result  *)
      let result_json =
        List.fold_left Yojson.Basic.Util.combine
          (`Assoc [ ("contractName", `String contract_name) ])
          [ json_of_abis abis; bytecode; deployed_bytecode ]
        |> Yojson.Basic.pretty_to_string
      in
      let result_chan = open_out (contract_name ^ ".json") in
      output_string result_chan result_json;
      close_out result_chan
  | _ -> raise Not_implemented
