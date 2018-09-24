open Bistro_base

type config = {
  db : Db.t ;
  use_docker : bool ;
}

type t =
  | Input of { id : string ; path : string }
  | Select of {
      id : string ;
      dir : Workflow.t ;
      sel : string list
    }
  | Shell of {
      id : string ;
      descr : string ;
      np : int ;
      mem : int ;
      cmd : Workflow.dep Command.t ;
    }
  | Plugin of {
      id : string ;
      descr : string ;
      np : int ;
      mem : int ;
      f : Workflow.env -> unit ;
    }

val input :
  id:string ->
  path:string ->
  t

val select :
  id:string ->
  dir:Workflow.t ->
  sel:string list ->
  t

val shell :
  id:string ->
  descr:string ->
  np:int ->
  mem:int ->
  Workflow.dep Command.t -> t

val plugin :
  id:string ->
  descr:string ->
  np:int ->
  mem:int ->
  (Workflow.env -> unit) -> t

val of_workflow : Workflow.t -> t

val id : t -> string

val requirement : t -> Allocator.request

val perform : t -> config -> Allocator.resource -> Task_result.t Lwt.t

val is_done : t -> Db.t -> bool Lwt.t
