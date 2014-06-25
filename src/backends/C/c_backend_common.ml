open Format
open LustreSpec
open Corelang
open Machine_code


(* Generation of a non-clashing name for the self memory variable (for step and reset functions) *)
let mk_self m =
  mk_new_name (m.mstep.step_inputs@m.mstep.step_outputs@m.mstep.step_locals@m.mmemory) "self"

(* Generation of a non-clashing name for the instance variable of static allocation macro *)
let mk_instance m =
  mk_new_name (m.mstep.step_inputs@m.mmemory) "inst"

(* Generation of a non-clashing name for the attribute variable of static allocation macro *)
let mk_attribute m =
  mk_new_name (m.mstep.step_inputs@m.mmemory) "attr"

let mk_call_var_decl loc id =
  { var_id = id;
    var_dec_type = mktyp Location.dummy_loc Tydec_any;
    var_dec_clock = mkclock Location.dummy_loc Ckdec_any;
    var_dec_const = false;
    var_type = Type_predef.type_arrow (Types.new_var ()) (Types.new_var ());
    var_clock = Clocks.new_var true;
    var_loc = loc }

(* counter for loop variable creation *)
let loop_cpt = ref (-1)

let reset_loop_counter () =
 loop_cpt := -1

let mk_loop_var m () =
  let vars = m.mstep.step_inputs@m.mstep.step_outputs@m.mstep.step_locals@m.mmemory in
  let rec aux () =
    incr loop_cpt;
    let s = Printf.sprintf "__%s_%d" "i" !loop_cpt in
    if List.exists (fun v -> v.var_id = s) vars then aux () else s
  in aux ()
(*
let addr_cpt = ref (-1)

let reset_addr_counter () =
 addr_cpt := -1

let mk_addr_var m var =
  let vars = m.mmemory in
  let rec aux () =
    incr addr_cpt;
    let s = Printf.sprintf "%s_%s_%d" var "addr" !addr_cpt in
    if List.exists (fun v -> v.var_id = s) vars then aux () else s
  in aux ()
*)
let pp_machine_memtype_name fmt id = fprintf fmt "struct %s_mem" id
let pp_machine_regtype_name fmt id = fprintf fmt "struct %s_reg" id
let pp_machine_alloc_name fmt id = fprintf fmt "%s_alloc" id
let pp_machine_static_declare_name fmt id = fprintf fmt "%s_DECLARE" id
let pp_machine_static_link_name fmt id = fprintf fmt "%s_LINK" id
let pp_machine_static_alloc_name fmt id = fprintf fmt "%s_ALLOC" id
let pp_machine_reset_name fmt id = fprintf fmt "%s_reset" id
let pp_machine_step_name fmt id = fprintf fmt "%s_step" id

let pp_c_dimension fmt d =
 fprintf fmt "%a" Dimension.pp_dimension d

let pp_c_type var fmt t =
  let rec aux t pp_suffix =
  match (Types.repr t).Types.tdesc with
  | Types.Tclock t'       -> aux t' pp_suffix
  | Types.Tbool           -> fprintf fmt "_Bool %s%a" var pp_suffix ()
  | Types.Treal           -> fprintf fmt "double %s%a" var pp_suffix ()
  | Types.Tint            -> fprintf fmt "int %s%a" var pp_suffix ()
  | Types.Tarray (d, t')  ->
    let pp_suffix' fmt () = fprintf fmt "%a[%a]" pp_suffix () pp_c_dimension d in
    aux t' pp_suffix'
  | Types.Tstatic (_, t') -> fprintf fmt "const "; aux t' pp_suffix
  | Types.Tconst ty       -> fprintf fmt "%s %s" ty var
  | Types.Tarrow (_, _)   -> fprintf fmt "void (*%s)()" var
  | _                     -> eprintf "internal error: pp_c_type %a@." Types.print_ty t; assert false
  in aux t (fun fmt () -> ())

let rec pp_c_initialize fmt t = 
  match (Types.repr t).Types.tdesc with
  | Types.Tint -> pp_print_string fmt "0"
  | Types.Tclock t' -> pp_c_initialize fmt t'
  | Types.Tbool -> pp_print_string fmt "0" 
  | Types.Treal -> pp_print_string fmt "0."
  | Types.Tarray (d, t') when Dimension.is_dimension_const d ->
    fprintf fmt "{%a}"
      (Utils.fprintf_list ~sep:"," (fun fmt _ -> pp_c_initialize fmt t'))
      (Utils.duplicate 0 (Dimension.size_const_dimension d))
  | _ -> assert false

(* Declaration of an input variable:
   - if its type is array/matrix/etc, then declare it as a mere pointer,
     in order to cope with unknown/parametric array dimensions, 
     as it is the case for generics
*)
let pp_c_decl_input_var fmt id =
  if !Options.ansi && Types.is_address_type id.var_type
  then pp_c_type (sprintf "(*%s)" id.var_id) fmt (Types.array_base_type id.var_type)
  else pp_c_type id.var_id fmt id.var_type

(* Declaration of an output variable:
   - if its type is scalar, then pass its address
   - if its type is array/matrix/struct/etc, then declare it as a mere pointer,
     in order to cope with unknown/parametric array dimensions, 
     as it is the case for generics
*)
let pp_c_decl_output_var fmt id =
  if (not !Options.ansi) && Types.is_address_type id.var_type
  then pp_c_type                  id.var_id  fmt id.var_type
  else pp_c_type (sprintf "(*%s)" id.var_id) fmt (Types.array_base_type id.var_type)

(* Declaration of a local/mem variable:
   - if it's an array/matrix/etc, its size(s) should be
     known in order to statically allocate memory, 
     so we print the full type
*)
let pp_c_decl_local_var fmt id =
  pp_c_type id.var_id fmt id.var_type

let pp_c_decl_array_mem self fmt id =
  fprintf fmt "%a = (%a) (%s->_reg.%s)"
    (pp_c_type (sprintf "(*%s)" id.var_id)) id.var_type
    (pp_c_type "(*)") id.var_type
    self
    id.var_id

(* Declaration of a struct variable:
   - if it's an array/matrix/etc, we declare it as a pointer
*)
let pp_c_decl_struct_var fmt id =
  if Types.is_array_type id.var_type
  then pp_c_type (sprintf "(*%s)" id.var_id) fmt (Types.array_base_type id.var_type)
  else pp_c_type                  id.var_id  fmt id.var_type

(* Access to the value of a variable:
   - if it's not a scalar output, then its name is enough
   - otherwise, dereference it (it has been declared as a pointer,
     despite its scalar Lustre type)
   - moreover, dereference memory array variables.
*)
let pp_c_var_read m fmt id =
  if Types.is_address_type id.var_type
  then
    if is_memory m id
    then fprintf fmt "(*%s)" id.var_id
    else fprintf fmt "%s" id.var_id
  else
    if is_output m id
    then fprintf fmt "*%s" id.var_id
    else fprintf fmt "%s" id.var_id

(* Addressable value of a variable, the one that is passed around in calls:
   - if it's not a scalar non-output, then its name is enough
   - otherwise, reference it (it must be passed as a pointer,
     despite its scalar Lustre type)
*)
let pp_c_var_write m fmt id =
  if Types.is_address_type id.var_type
  then
    fprintf fmt "%s" id.var_id
  else
    if is_output m id
    then
      fprintf fmt "%s" id.var_id
    else
      fprintf fmt "&%s" id.var_id

let pp_c_decl_instance_var fmt (name, (node, static)) = 
  fprintf fmt "%a *%s" pp_machine_memtype_name (node_name node) name

let pp_c_tag fmt t =
 pp_print_string fmt (if t = tag_true then "1" else if t = tag_false then "0" else t)

(* Prints a constant value *)
let rec pp_c_const fmt c =
  match c with
    | Const_int i     -> pp_print_int fmt i
    | Const_real r    -> pp_print_string fmt r
    | Const_float r   -> pp_print_float fmt r
    | Const_tag t     -> pp_c_tag fmt t
    | Const_array ca  -> fprintf fmt "{%a }" (Utils.fprintf_list ~sep:", " pp_c_const) ca
    | Const_struct fl -> fprintf fmt "{%a }" (Utils.fprintf_list ~sep:", " (fun fmt (f, c) -> pp_c_const fmt c)) fl

(* Prints a value expression [v], with internal function calls only.
   [pp_var] is a printer for variables (typically [pp_c_var_read]),
   but an offset suffix may be added for array variables
*)
let rec pp_c_val self pp_var fmt v =
  match v with
    | Cst c         -> pp_c_const fmt c
    | Array vl      -> fprintf fmt "{%a}" (Utils.fprintf_list ~sep:", " (pp_c_val self pp_var)) vl
    | Access (t, i) -> fprintf fmt "%a[%a]" (pp_c_val self pp_var) t (pp_c_val self pp_var) i
    | Power (v, n)  -> assert false
    | LocalVar v    -> pp_var fmt v
    | StateVar v    ->
    (* array memory vars are represented by an indirection to a local var with the right type,
       in order to avoid casting everywhere. *)
      if Types.is_array_type v.var_type
      then fprintf fmt "%a" pp_var v
      else fprintf fmt "%s->_reg.%a" self pp_var v
    | Fun (n, vl)   -> Basic_library.pp_c n (pp_c_val self pp_var) fmt vl

let pp_c_checks self fmt m =
  Utils.fprintf_list ~sep:"" (fun fmt (loc, check) -> fprintf fmt "@[<v>%a@,assert (%a);@]@," Location.pp_c_loc loc (pp_c_val self (pp_c_var_read m)) check) fmt m.mstep.step_checks

(* Local Variables: *)
(* compile-command:"make -C .." *)
(* End: *)
