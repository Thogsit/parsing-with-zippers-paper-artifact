open Pyast
open Pytokens

(* Define abstract types. *)

type pos = int ref (* Using ref makes it easy to create values that are not pointer equal *)
let p_bottom = ref (-1)

let s_bottom = "<s_bottom>"

type tok = token_pair
let t_eof = (-1, "<t_eof>")

(* Define types. *)
type exp = { mutable m : mem; e' : exp' }
and exp' = Eps of sym
         | Tok of tok
         | Seq of sym * exp * exp
         | Alt of (exp option) ref * (exp option) ref
         | Red of (ast -> ast) * exp
and cxt  = TopC
         | SeqC1 of mem ref * sym * exp
         | SeqC2 of mem * sym * exp
         | AltC1 of mem
         | AltC2 of mem
         | RedC of mem * (ast -> ast)
and mem  = { start_pos : pos;
             mutable parents : cxt list;
             mutable end_pos : pos;
             mutable result : exp }

type zipper = exp' * mem

(* Define bottom values. *)
let rec e_bottom = { m = m_bottom; e' = Alt (ref None, ref None) }
    and m_bottom = { start_pos = p_bottom; parents = []; end_pos = p_bottom; result = e_bottom }

let worklist : (zipper list) ref = ref []

let tops : (exp list) ref = ref []

let derive (p : pos) ((t, s) : tok) ((e', m) : zipper) : unit =
  let rec d_d (c : cxt) (e : exp) : unit =
    if p == e.m.start_pos
    then (e.m.parents <- c :: e.m.parents;
          if p == e.m.end_pos then d_u' e.m.result c)
    else (let m = { start_pos = p; parents = [c]; end_pos = p_bottom; result = e_bottom } in
          e.m <- m;
          d_d' m e.e')

  and d_d' (m : mem) (e' : exp') : unit =
    match e' with
    | Eps (s)         -> d_u (Eps s) m
    | Tok (t', _)     -> if t == t' then worklist := (Eps s, m) :: !worklist
    | Seq (s, e1, e2) -> d_d (SeqC1 (ref m, s, e2)) e1
    | Alt (e1, e2)    -> (match !e1 with Some e1' -> d_d (AltC1 m) e1' | None -> ());
                         (match !e2 with Some e2' -> d_d (AltC2 m) e2' | None -> ())
    | Red (f, e)      -> d_d (RedC (m, f)) e

  and d_u (e' : exp') (m : mem) : unit =
    let e = { m = m_bottom; e' = e' } in
    m.end_pos <- p;
    m.result <- e;
    List.iter (d_u' e) m.parents

  and d_u' (e : exp) (c : cxt) : unit =
    match c with
    | TopC             -> tops := e :: !tops
    | SeqC1 (m, s, e2) -> let m1 = { start_pos = !m.start_pos; parents = [AltC1 !m]; end_pos = p_bottom; result = e_bottom } in
                          let m2 = { start_pos = !m.start_pos; parents = [AltC2 !m]; end_pos = p_bottom; result = e_bottom } in
                          let s2 = SeqC2 (m2, s, e) in
                          m := m1;
                          d_d s2 e2
    | SeqC2 (m, s, e1) -> d_u (Seq (s, e1, e)) m
    | AltC1 m          -> if m.end_pos == p
                          then match m.result.e' with
                               | Alt (e1, e2) -> e1 := Some e
                          else d_u (Alt (ref (Some e), ref None)) m
    | AltC2 m          -> if m.end_pos == p
                          then match m.result.e' with
                               | Alt (e1, e2) -> e2 := Some e
                          else d_u (Alt (ref None, ref (Some e))) m
    | RedC (m, f)      -> d_u (Red (f, e)) m

  in d_u e' m

let init_zipper (e : exp) : zipper =
  let e'    = Seq (s_bottom, e_bottom, e_bottom) in
  let m_top = { start_pos = p_bottom; parents = [TopC]; end_pos = p_bottom; result = e_bottom } in
  let c     = SeqC1 (ref m_top, s_bottom, e) in
  let m_seq = { start_pos = p_bottom; parents = [c]; end_pos = p_bottom; result = e_bottom } in
  (e', m_seq)

let unwrap_top_exp (e : exp) : exp =
  match e.e' with
  | Alt (e1, e2) -> match (!e1, !e2) with
                    | (None, Some { e' = Seq (_, _, e) }) -> e

let parse (ts : tok list) (e : exp) : exp list =
  let rec parse' (p : pos) (ts : tok list) : exp list =
    let w = !worklist in
    worklist := [];
    tops := [];
    match ts with
    | []            -> List.iter (derive p t_eof) w;
                       List.map unwrap_top_exp !tops
    | (t, s) :: ts' -> List.iter (derive p (t, s)) w;
                       parse' (ref (!p + 1)) ts' in
  worklist := [init_zipper e];
  parse' (ref 0) ts

let list_product (l1 : 'a list) (l2 : ('a list) list) : ('a list) list =
  List.concat (List.map (fun l -> List.map (List.cons l) l2) l1)

let rec binary_cartesian_product (xs : 'a list) (ys : 'b list) (f : 'a -> 'b -> 'c) : 'c list =
  match xs with
  | []        -> []
  | x :: xs'  -> (List.map (f x) ys) @ (binary_cartesian_product xs' ys f)

let rec ast_list_of_exp (e : exp) : ast list =
  match e.e' with
  | Eps s           -> [Ast (s, [])]
  | Tok _           -> []
  | Seq (s, e1, e2) -> let t1s = ast_list_of_exp e1 in
                       let t2s = ast_list_of_exp e2 in
                       binary_cartesian_product t1s t2s (fun t1 t2 -> Ast (s, [t1; t2]))
  | Alt (e1, e2)    -> let t1s = match !e1 with
                                 | Some e1' -> ast_list_of_exp e1'
                                 | None     -> [] in
                       let t2s = match !e2 with
                                 | Some e2' -> ast_list_of_exp e2'
                                 | None     -> [] in
                       t1s @ t2s
  | Red (f, e)      -> List.map f (ast_list_of_exp e)

let ast_list_of_exp_list (es : exp list) : ast list =
  List.concat (List.map ast_list_of_exp es)
