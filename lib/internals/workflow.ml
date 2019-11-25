type path =
  | FS_path of string
  | Cache_id of string
  | Cd of path * string list

let cd dir sel = match dir with
  | Cd (indir, insel) -> Cd (indir, insel @ sel)
  | FS_path _ | Cache_id _ -> Cd (dir, sel)

type _ t =
  | Pure : { id : string ; value : 'a } -> 'a t
  | App : {
      id : string ;
      f : ('a -> 'b) t ;
      x : 'a t ;
    } -> 'b t
  | Both : {
      id : string ;
      fst : 'a t ;
      snd : 'b t ;
    } -> ('a *'b) t
  | List : {
      id : string ;
      elts : 'a t list ;
    } -> 'a list t
  | Eval_path : { id : string ; workflow : path t } -> string t
  | Spawn : {
      id : string ;
      elts : 'a list t ;
      f : 'a t -> 'b t ;
      deps : any list ;
    } -> 'b list t
  | List_nth : {
      id : string ;
      elts : 'a list t ;
      index : int ;
    } -> 'a t

  | Input : { id : string ; path : string ; version : int option } -> path t
  | Select : {
      id : string ;
      dir : path t ;
      sel : string list ;
    } -> path t
  | Plugin : ('a plugin, any) step -> 'a t
  | Shell : (shell_command, any) step -> path t
  | Glob : {
      id : string ;
      pattern : string option ;
      type_selection : [`File | `Directory] option ;
      dir : path t ;
    } -> path list t

and ('a, 'b) step = {
  id : string ;
  descr : string ;
  task : 'a ;
  np : int ; (** Required number of processors *)
  mem : int t option ; (** Required memory in MB *)
  version : int option ; (** Version number of the wrapper *)
  deps : 'b list ;
}

and 'a plugin =
  | Value_plugin : (unit -> 'a) t -> 'a plugin
  | Path_plugin : (string -> unit) t -> path plugin

and shell_command = token Command.t

and token =
  | Path_token of path t
  | Path_list_token of {
      elts : path list t ;
      sep : string ;
      quote : char option ;
    }
  | String_token of string t

and any = Any : _ t -> any

let digest x =
  Digest.to_hex (Digest.string (Marshal.to_string x []))

let id : type s. s t -> string = function
  | Input { id ; _ } -> id
  | Select { id ; _ } -> id
  | Plugin { id ; _ } -> id
  | Pure { id ; _ } -> id
  | App { id ; _ } -> id
  | Spawn { id ; _ } -> id
  | Both { id ; _ } -> id
  | Eval_path { id ; _ } -> id
  | Shell { id ; _ } -> id
  | List { id ; _ } -> id
  | List_nth { id ; _ } -> id
  | Glob { id ; _ } -> id

let any x = Any x

module Any = struct
  module T = struct
    type t = any

    let id (Any w) = id w

    let compare x y =
      String.compare (id x) (id y)

    let equal x y =
      String.equal (id x) (id y)

    let hash x = Hashtbl.hash (id x)
  end

  module Set = Set.Make(T)
  module Table = Hashtbl.Make(T)
  module Map = Map.Make(T)

  include T

  let deps (Any w) = match w with
    | Pure _ -> []
    | App app -> [ Any app.f ; Any app.x ]
    | Both p -> [ Any p.fst ; Any p.snd ]
    | List l -> List.map any l.elts
    | Eval_path { workflow ; _ } -> [ Any workflow ]
    | Spawn s -> s.deps
    | List_nth l -> [ Any l.elts ]
    | Input _ -> []
    | Select sel -> [ any sel.dir ]
    | Plugin v -> v.deps
    | Shell s -> s.deps
    | Glob g -> [ Any g.dir ]

  let descr (Any w) = match w with
    | Shell s -> Some s.descr
    | Plugin s -> Some s.descr
    | Input i -> Some i.path
    | Select s -> Some (List.fold_left Filename.concat "" s.sel)
    | _ -> None

  let rec fold_aux w ~seen ~init ~f =
    if Set.mem w seen then init, seen
    else
      let acc, seen =
        List.fold_left
          (fun (acc, seen) w -> fold_aux w ~seen ~init:acc ~f)
          (init, seen)
          (deps w)
      in
      f acc w,
      Set.add w seen

  let fold w ~init ~f =
    fold_aux w ~seen:Set.empty ~init ~f
    |> fst
end

let input ?version path =
  let id = digest (`Input, path, version) in
  Input { id ; path ; version }

let select dir sel =
  let dir, sel =
    match dir with
    | Select { dir ; sel = root ; _ } -> dir, root @ sel
    | Input _ | Plugin _ | Shell _ -> dir, sel
    | _ -> assert false
  in
  let id = digest ("select", id dir, sel) in
  Select { id ; dir ; sel }

let pure ~id value = Pure { id ; value }
let pure_data value = pure ~id:(digest value) value
let int = pure_data
let string = pure_data
let app f x =
  let id = digest (`App, id f, id x) in
  App { id ; f ; x }
let ( $ ) = app
let both fst snd =
  let id = digest (`Both, id fst, id snd) in
  Both { id ; fst ; snd }

let add_mem_dep mem deps = match mem with
  | None -> deps
  | Some mem -> any mem :: deps

let cached_value ?(descr = "") ?(np = 1) ?mem ?version workflow =
  let id = digest (`Value, id workflow, version) in
  Plugin { id ; descr ; np ; mem ; version ;
           task = Value_plugin workflow ;
           deps = add_mem_dep mem [ any workflow ] }

let cached_path ?(descr = "") ?(np = 1) ?mem ?version workflow =
  let id = digest (`Value, id workflow, version) in
  Plugin { id ; descr ; np ; mem ; version ;
           task = Path_plugin workflow ;
           deps = add_mem_dep mem [ any workflow ] }

let eval_path w = Eval_path { id = digest (`Eval_path, id w) ; workflow = w }

let digestible_cmd = Command.map ~f:(function
    | Path_token w -> id w
    | Path_list_token { elts ; sep ; quote } -> digest (id elts, sep, quote)
    | String_token w -> id w
  )

let shell
    ?(descr = "")
    ?mem
    ?(np = 1)
    ?version
    cmds =
  let cmd = Command.And_list cmds in
  let id = digest ("shell", version, digestible_cmd cmd) in
  let deps = add_mem_dep mem (
      Command.deps cmd
      |> List.map (function
          | Path_token w -> any w
          | Path_list_token { elts ; _ } -> any elts
          | String_token s -> any s
        )
    )
  in
  Shell { descr ; task = cmd ; np ; mem ; version ; id ; deps }

let list elts =
  let id = digest ("list", List.map id elts) in
  List { id ; elts }

let rec independent_workflows_aux cache w ~from:u =
  if Any.equal w u then Any.Map.add w (true, Any.Set.empty) cache
  else if Any.Map.mem w cache then cache
  else (
    let deps = Any.deps w in
    let f acc w = independent_workflows_aux acc w ~from:u in
    let cache = List.fold_left f cache deps in
    let children = List.map (fun k -> Any.Map.find k cache) deps in
    if List.exists fst children
    then
      let union =
        List.fold_left
          (fun acc (_, s) -> Any.Set.union acc s)
          Any.Set.empty children in
      Any.Map.add w (true, union) cache
    else Any.Map.add w (false, Any.Set.singleton w) cache
  )

(* gathers all descendants of [w] excluding those having [u] as a
   descendant *)
let independent_workflows w ~from:u =
  let cache = independent_workflows_aux Any.Map.empty w ~from:u in
  Any.Map.find w cache |> snd |> Any.Set.elements

let spawn elts ~f =
  let hd = pure ~id:"__should_never_be_executed__" List.hd in
  let u = app hd elts in
  let f_u = f u in
  let id = digest (`Spawn, id elts, id f_u) in
  let deps = any elts :: independent_workflows (any f_u) ~from:(any u) in
  Spawn { id ; elts ; f ; deps }

let list_nth w i =
  let id = digest (`List_nth, id w, i) in
  List_nth { id ; elts = w ; index = i }

let glob ?pattern ?type_selection dir =
  let id = digest (`Glob, id dir, pattern, type_selection) in
  Glob { id ; dir ; pattern ; type_selection }
