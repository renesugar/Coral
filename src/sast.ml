open Ast

(* sast.ml: contains the definitions of the algebraic types which make up the semantically checked abstract 
syntax tree. 

The overall semantically checked program is an sprogram, with a list of semantically checked statements
(sstmt list) and a list of global variables and their inferred types (bind list). 

Semantically checked functions are stored as sfunc_decl records, containing their return type (styp), their
name (sfname), a list of formal variables (sformals), a list of local variables (slocals), and the sbody, an
SBlock sstmt. 

sexp is the type that stores semantically checked expressions. SListSlice, SMethod, and SField have not been
implemented. sexpr is merely an sexp with an associated type. In general, that type is the type inferred 
by semant, while any binds found in sexprs or sstmts contain types that need to be checked at runtime. 

sstmt is the type that stores semantically checked statements. SClass has not been implemented. STransform
is an internal type used to handle some of the boxing and unboxing required by the gradual type system. This
is usually inserted when conditional branches are merged or when generic (unknown) functions are called.

lvalues are the types that can occur on the left-hand side of an assignment. SLListSlice has not been
implemented. These can be expanded as more kinds of features are added, including classes.

The various print functions are pretty-printing functions for debugging and viewing the generated SAST.
*)

type sprogram = sstmt list * bind list

and sfunc_decl = {
  styp : typ;
  sfname : string;
  sformals : bind list;
  slocals : bind list;
  sbody : sstmt
}

and sexp =
  | SBinop of sexpr * operator * sexpr (* (left sexpr, op, right sexpr) *)
  | SLit of literal (* literal *)
  | SVar of string (* see above *)
  | SUnop of uop * sexpr (* (uop, sexpr ) *)
  | SCall of sexpr * sexpr list * sstmt (* SVar or SCall, list of args, SFunc) *) (* sstmt is SNop if recursive call within function or weak function *)
  | SMethod of sexpr * string * sexpr list (* not implemented *)
  | SField of sexpr * string (* not implemented *)
  | SList of sexpr list * typ (* (list of expressions, inferred type) *)
  | SNoexpr (* no expression *)
  | SListAccess of sexpr * sexpr (* not implemented *)
  | SListSlice of sexpr * sexpr * sexpr (* not implemented *)
  | SCast of typ * typ * sexpr (* from type, to type, expr *)

and sexpr = sexp * typ

and sstmt = (* this can be refactored using Blocks, but I haven't quite figured it out yet *)
  | SFunc of sfunc_decl (* (name, return type), list of formals, list of locals, body) *)
  | SBlock of sstmt list (* block found in function body or for/else/if/while loop *)
  | SExpr of sexpr (* see above *)
  | SIf of sexpr * sstmt * sstmt (* condition, if, else *)
  | SFor of bind * sexpr * sstmt (* (variable, list, body (block)) *)
  | SWhile of sexpr * sstmt (* (condition, body (block)) *)
  | SRange of bind * sexpr * sstmt
  | SReturn of sexpr (* return statement *)
  | SClass of string * sstmt (* not implemented *)
  | SAsn of lvalue list * sexpr (* x : int = sexpr, (Bind(x, int), sexpr) *)
  | STransform of string * typ * typ 
  | SStage of sstmt * sstmt * sstmt (* entry, body, exit *)
  | SPrint of sexpr
  | SType of sexpr
  | SContinue
  | SBreak
  | SNop

and lvalue = 
  | SLVar of bind
  | SLListAccess of sexpr * sexpr
  | SLListSlice of sexpr * sexpr * sexpr

let concat_end delim = List.fold_left (fun a c -> a ^ delim ^ c) ""
let append_list v = List.map (fun c -> c ^ v)

(* let rec string_of_sexpr (e, t) = "(" ^ string_of_sexp e ^ ": " ^ string_of_typ t ^ ")" *)

let funcs = ref []

let string_of_sbind = function
  | Bind(s, t) -> (string_of_typ t) ^ " " ^ s

let rec string_of_sexpr e = let (e, t) = e in 
  (match e with
  | SBinop(e1, o, e2) -> string_of_sexpr e1 ^ " " ^ string_of_op o ^ " " ^ string_of_sexpr e2
  | SLit(l) -> string_of_lit l
  | SVar(str) -> str
  | SUnop(o, e) -> string_of_uop o ^ string_of_sexpr e
  | SCall(e, el, s) -> funcs := ((string_of_func s) :: !funcs); string_of_sexpr e ^ "(" ^ String.concat ", " (List.map string_of_sexpr el) ^ ")"
  | SMethod(obj, m, el) -> string_of_sexpr obj ^ "." ^ m ^ "(" ^ String.concat ", " (List.map string_of_sexpr el) ^ ")"
  | SField(obj, s) -> string_of_sexpr obj ^ "." ^ s
  | SList(el, t) -> "{" ^ String.concat ", " (List.map string_of_sexpr el) ^ "}"
  | SListAccess(e1, e2) -> string_of_sexpr e1 ^ "[" ^ string_of_sexpr e2 ^ "]"
  | SListSlice(e1, e2, e3) -> string_of_sexpr e1 ^ "[" ^ string_of_sexpr e2 ^ ":" ^ string_of_sexpr e3 ^ "]"
  | SCast(t1, t2, e) -> string_of_typ t2 ^ "(" ^ string_of_sexpr e ^ ") -> " ^ string_of_typ t1
  | SNoexpr -> "")

and string_of_sstmt depth = function
  | SFunc({ styp; sfname; sformals; slocals; sbody }) -> ""
  | SBlock(sl) -> string_of_stmt_list depth sl
  | SExpr(e) -> string_of_sexpr e
  | SIf(e, s1, s2) ->  "if (" ^ string_of_sexpr e ^ ") {\n" ^ string_of_sstmt depth s1 ^ (String.make (2 * (depth - 1)) ' ') ^ "} else {\n" ^ string_of_sstmt depth s2 ^ "}\n"
  | SFor(b, e, s) -> let Bind(s1, t1) = b in "for (auto " ^ s1 ^ " : " ^ string_of_sexpr e ^ ") {\n" ^ string_of_sstmt depth s ^ "}\n"
  | SRange(b, e, s) -> let Bind(s1, t1) = b in "for (int " ^ s1 ^ "=0; i < " ^ string_of_sexpr e ^ "; " ^ s1 ^ "++){\n" ^ string_of_sstmt depth s ^ "}\n"
  | SWhile(e, s) -> "while (" ^ string_of_sexpr e ^ ") {\n" ^ string_of_sstmt depth s ^ "}\n"
  | SReturn(e) -> "return " ^ string_of_sexpr e
  | SClass(b, s) -> funcs := string_of_class (SClass(b, s)) :: !funcs; ""
  | SAsn(lvalues, e) -> let (e', t) = e in String.concat ", " (List.map (string_of_lvalue t) lvalues) ^ " = "  ^ string_of_sexpr e
  | STransform(s, t1, t2) -> ""
  | SStage(s1, s2, s3) -> string_of_sstmt depth s2
  | SPrint(e) -> let (e', t) = e in "std::cout << " ^ string_of_sexpr e ^ " << std::endl"
  | SBreak -> "break"
  | SContinue -> "continue"
  | SNop -> ""

and string_of_class = function
  | SClass(b, s) -> "class " ^ b ^ " {\npublic:\n" ^ string_of_sstmt 1 s ^ "}"
  | _ -> raise (Failure("type not found"));

and string_of_func = function
  | (SFunc({ styp; sfname; sformals; slocals; sbody })) -> let locals = String.concat "\n" (List.map (fun x -> x ^ ";") (List.map string_of_sbind (List.filter (fun x -> not (List.mem x sformals)) slocals))) in List.iter print_endline (List.map string_of_sbind slocals); string_of_typ styp ^ " " ^ sfname ^ "(" ^ String.concat ", " (List.map string_of_sbind sformals) ^ ") {\n" ^ locals ^ string_of_sstmt 1 sbody ^ " }"
  | _ -> raise (Failure("type not found"));

and string_of_lvalue t = function
  | SLVar(sbind) -> let (Bind(str, t')) = sbind in str
  | SLListAccess(e1, e2) ->  string_of_sexpr e1 ^ "[" ^ string_of_sexpr e2 ^ "]"
  | SLListSlice(e1, e2, e3) -> string_of_sexpr e1 ^ "[" ^ string_of_sexpr e2 ^ ":" ^ string_of_sexpr e3 ^ "]"

and string_of_stmt_list depth sl = concat_end (String.make (2 * depth) ' ') (append_list "\n" (List.map (fun x -> x ^ ";") (List.filter_map (fun x -> match String.length x with | 0 -> None | _ -> Some x) (List.map (string_of_sstmt (depth + 1)) sl))))

and string_of_sprogram (sl, bl) = let locals = String.concat "\n" (List.map (fun x -> x ^ ";") (List.map string_of_sbind bl)) in let body = "int main(int argc, char ** argv) {\n" ^ locals ^ string_of_stmt_list 1 sl ^ "\n }" in let temp_funcs = List.sort_uniq Stdlib.compare !funcs in (String.concat "\n" temp_funcs ^ "\n\n" ^ body)
