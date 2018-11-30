open Core
open Lwt.Infix
open Bistro_internals
module W = Bistro_internals.Workflow

type error = [
  | `Msg of string
]

type config = {
  db : Db.t ;
  use_docker : bool ;
}

module Traces = Caml.Set.Make(struct
    type t = Execution_trace.t
    let compare = compare
  end)

(* Lwt threads that accumulate errors *)
module Eval_thread : sig
  type 'a t = ('a, Traces.t) Lwt_result.t
  val return : 'a -> 'a t
  (* val fail : Traces.t -> 'a t *)
  (* val fail1 : Execution_trace.t -> 'a t *)
  val both : 'a t -> 'b t -> ('a * 'b) t
  (* val list_map : *)
  (*   'a list -> *)
  (*   f:('a -> 'b t) -> *)
  (*   'b list t *)
  val join :
    'a list ->
    f:('a -> unit t) ->
    unit t

  module Infix : sig
    val ( >>= ) : 'a t -> ('a -> 'b t) -> 'b t
    val ( >>| ) : 'a t -> ('a -> 'b) -> 'b t
    val ( >> ) : 'a Lwt.t -> ('a -> 'b t) -> 'b t
  end
end
=
struct
  type 'a t = ('a, Traces.t) Lwt_result.t

  module Infix = struct
    let ( >> ) = Lwt.( >>= )
    let ( >>= ) = Lwt_result.( >>= )
    let ( >>| ) = Lwt_result.( >|= )
  end

  let return = Lwt_result.return
  (* let fail = Lwt_result.fail *)
  (* let fail1 e = Lwt_result.fail (Traces.singleton e) *)
  let result_both x y =
    match x, y with
    | Ok x, Ok y -> Ok (x, y)
    | Ok _, Error e -> Error e
    | Error e, Ok _ -> Error e
    | Error e, Error e' -> Error (Traces.union e e')

  let both x y =
    Lwt.(x >>= fun x ->
         y >>= fun y ->
         return (result_both x y))

  let list_map xs ~f =
    Lwt.bind (Lwt_list.map_p f xs) @@ fun results ->
    let res =
      List.fold results ~init:(Ok []) ~f:(fun acc res ->
          Result.map (result_both acc res) ~f:(fun (xs, x) -> x :: xs)
        )
      |> (
        function
        | Ok xs -> Ok (List.rev xs)
        | Error _ as e -> e
      )
    in
    Lwt.return res

  let join xs ~f =
    let open Lwt_result in
    list_map xs ~f >|= ignore
end

type 'a thread = 'a Eval_thread.t

let worker f x =
  let (read_from_child, write_to_parent) = Unix.pipe () in
  let (read_from_parent, write_to_child) = Unix.pipe () in
  match Unix.fork () with
  | `In_the_child ->
    Unix.close read_from_child ;
    Unix.close write_to_child ;
    let res =
      try f x ; Ok ()
      with e ->
        let msg =
          sprintf "%s\n%s"
            (Exn.to_string e)
            (Printexc.get_backtrace ())
        in
        Error msg
    in
    let oc = Unix.out_channel_of_descr write_to_parent in
    Marshal.to_channel oc res [] ;
    Caml.flush oc ;
    Unix.close write_to_parent ;
    ignore (Caml.input_value (Unix.in_channel_of_descr read_from_parent)) ;
    assert false
  | `In_the_parent pid ->
    Unix.close write_to_parent ;
    Unix.close read_from_parent ;
    let ic = Lwt_io.of_unix_fd ~mode:Lwt_io.input read_from_child in
    Lwt_io.read_value ic >>= fun (res : (unit, string) result) ->
    Caml.Unix.kill (Pid.to_int pid) Caml.Sys.sigkill;
    Misc.waitpid (Pid.to_int pid) >>= fun _ ->
    Unix.close read_from_child ;
    Unix.close write_to_child ;
    Lwt.return res

let load_value fn =
  In_channel.with_file fn ~f:Marshal.from_channel

let save_value ~data fn =
  Out_channel.with_file fn ~f:(fun oc -> Marshal.to_channel oc data [])

let lwt_both x y =
  x >>= fun x ->
  y >>= fun y ->
  Lwt.return (x, y)

let list_nth xs i =
  W.(pure ~id:"List.nth" List.nth_exn $ xs $ int i)

let step_outcome ~exit_code ~dest_exists=
  match exit_code, dest_exists with
    0, true -> `Succeeded
  | 0, false -> `Missing_output
  | _ -> `Failed

let perform_shell config ~id ~descr cmd =
  let env =
    Execution_env.make
      ~use_docker:config.use_docker
      ~db:config.db
      ~np:1 ~mem:0 ~id
  in
  let cmd = Shell_command.make env cmd in
  Shell_command.run cmd >>= fun (exit_code, dest_exists) ->
  let cache_dest = Db.cache config.db id in
  let outcome = step_outcome ~exit_code ~dest_exists in
  Misc.(
    if outcome = `Succeeded then
      mv env.dest cache_dest >>= fun () ->
      remove_if_exists env.tmp_dir
    else
      Lwt.return ()
  ) >>= fun () ->
  Eval_thread.return (Task_result.Shell {
      outcome ;
      id ;
      descr ;
      exit_code ;
      cmd = Shell_command.text cmd ;
      file_dumps = Shell_command.file_dumps cmd ;
      cache = if outcome = `Succeeded then Some cache_dest else None ;
      stdout = env.stdout ;
      stderr = env.stderr ;
    })

let rec blocking_evaluator
  : type s. Db.t -> s W.t -> (unit -> s)
  = fun db w ->
    match w with
    | W.Pure { value ; _ } -> fun () -> value
    | W.App { f ; x ; _ } ->
      let f = blocking_evaluator db f in
      let x = blocking_evaluator db x in
      fun () -> (f ()) (x ())
    | W.Both { fst ; snd ; _ } ->
      let fst = blocking_evaluator db fst in
      let snd = blocking_evaluator db snd in
      fun () -> (fst (), snd ())
    | W.Eval_path x ->
      let f = blocking_evaluator db x.workflow in
      fun () -> Db.path db (f ())
    | W.Select _ -> assert false
    | W.Input { path ; _ } -> fun () -> W.FS_path path
    | W.Value { id ; _ } ->
      fun () -> (load_value (Db.cache db id))
    | W.Path _ -> assert false
    | W.Spawn _ -> assert false
    | W.Shell s -> fun () -> W.Cache_id s.id

let rec shallow_eval
  : type s. config -> s W.t -> s Lwt.t
  = fun config w ->
    match w with
    | W.Pure { value ; _ } -> Lwt.return value
    | W.App { f ; x ; _ } ->
      lwt_both (shallow_eval config f) (shallow_eval config x) >>= fun (f, x) ->
      let y = f x in
      Lwt.return y
    | W.Both { fst ; snd ; _ } ->
      lwt_both (shallow_eval config fst) (shallow_eval config snd) >>= fun (fst, snd) ->
      Lwt.return (fst, snd)
    | W.Eval_path w ->
      shallow_eval config w.workflow >|= Db.path config.db
    | W.Select s ->
      shallow_eval config s.dir >>= fun dir ->
      Lwt.return (W.Cd (dir, s.sel))
    | W.Input { path ; _ } -> Lwt.return (W.FS_path path)
    | W.Value { id ; _ } ->
      Lwt.return (load_value (Db.cache config.db id)) (* FIXME: blocking call *)
    | W.Spawn s -> (* FIXME: much room for improvement *)
      shallow_eval config s.elts >>= fun elts ->
      let targets = List.init (List.length elts) ~f:(fun i -> s.f (list_nth s.elts i)) in
      Lwt_list.map_p (shallow_eval config) targets
    | W.Path s -> Lwt.return (W.Cache_id s.id)
    | W.Shell s -> Lwt.return (W.Cache_id s.id)

and shallow_eval_command config =
  let list xs = Lwt_list.map_p (shallow_eval_command config) xs in
  let open Command in
  function
  | Simple_command cmd ->
    shallow_eval_template config cmd >|= fun cmd ->
    Simple_command cmd
  | And_list xs ->
    list xs >|= fun xs -> And_list xs
  | Or_list xs ->
    list xs >|= fun xs -> Or_list xs
  | Pipe_list xs ->
    list xs >|= fun xs -> Pipe_list xs
  | Docker (env, cmd) ->
    shallow_eval_command config cmd >|= fun cmd ->
    Docker (env, cmd)

and shallow_eval_template config toks =
    Lwt_list.map_p (shallow_eval_token config) toks

and shallow_eval_token config =
  let open Template in
  function
  | D w -> shallow_eval config w >|= fun p -> D p
  | F f -> shallow_eval_template config f >|= fun t -> F t
  | DEST | TMP | NP | MEM | S _ as tok -> Lwt.return tok

let rec build
  : type s. config -> s W.t -> unit thread
  = fun config w ->
    let open Eval_thread.Infix in
    match w with
    | W.Pure _ -> Eval_thread.return ()
    | W.App { x ; f ; _ } ->
      Eval_thread.both (build config x) (build config f) >>| ignore
    | W.Both { fst ; snd ; _ } ->
      Eval_thread.both (build config fst) (build config snd) >>| ignore
    | W.Eval_path { workflow ; _ } -> build config workflow
    | W.Spawn { elts ; f ; _ } ->
      build config elts >>= fun () ->
      shallow_eval config elts >> fun elts_value ->
      let n = List.length elts_value in
      List.init n ~f:(fun i -> f (list_nth elts i))
      |> Eval_thread.join ~f:(build config)
    | W.Input _ -> Eval_thread.return () (* FIXME: check path *)
    | W.Select _ -> Eval_thread.return () (* FIXME: check path *)
    | W.Value { task = workflow ; id ; _ } ->
      if Sys.file_exists (Db.cache config.db id) = `Yes
      then Eval_thread.return ()
      else
        let () = printf "build %s\n" id in
        let evaluator = blocking_evaluator config.db workflow in
        worker (fun () ->
            let y = evaluator () () in
            save_value ~data:y (Db.cache config.db id)
          ) ()
        >> fun _ -> Eval_thread.return () (* FIXME *)
    | W.Path { id ; task = workflow ; _ } ->
      if Sys.file_exists (Db.cache config.db id) = `Yes
      then Eval_thread.return ()
      else
        let () = printf "build %s\n" id in
        let evaluator = blocking_evaluator config.db workflow in
        (* let env = *) (* FIXME: use this *)
        (*   Execution_env.make *)
        (*     ~use_docker:config.use_docker *)
        (*     ~db:config.db *)
        (*     ~np ~mem ~id *)
        (* in *)
        worker (Fn.flip evaluator (Db.cache config.db id)) ()
        >> fun _ -> Eval_thread.return () (* FIXME *)
    | W.Shell s ->
      if Sys.file_exists (Db.cache config.db s.id) = `Yes
      then Eval_thread.return ()
      else
        build_command_deps config s.task >>= fun () ->
        shallow_eval_command config s.task >> fun cmd ->
        perform_shell config ~id:s.id ~descr:s.descr cmd >>= fun _ -> (* FIXME *)
        Eval_thread.return ()

and build_command_deps config
  : W.path W.t Command.t -> unit Eval_thread.t
  = function
    | Simple_command cmd -> build_template_deps config cmd
    | And_list xs
    | Or_list xs
    | Pipe_list xs ->
      Eval_thread.join ~f:(build_command_deps config) xs
    | Docker (_, cmd) -> build_command_deps config cmd

and build_template_deps config toks =
    Eval_thread.join ~f:(build_template_token_deps config) toks

and build_template_token_deps config
  : W.path W.t Template.token -> unit thread
  = function
    | D w -> build config w
    | F f -> build_template_deps config f
    | DEST | TMP | NP | MEM | S _ -> Eval_thread.return ()

let eval
  : type s. config -> s Bistro.workflow -> (s, Execution_trace.t list) Lwt_result.t
  = fun config w ->
    let w = Bistro.Private.reveal w in
    build config w
    |> Fn.flip Lwt_result.bind Lwt.(fun () -> shallow_eval config w >|= Result.return)
    |> Lwt_result.map_err Traces.elements
