open Bistro_base

include Sigs.Repo with type 'a workflow := 'a Workflow.t
                   and type 'a expr := 'a Workflow.expr
                   and type logger := Logger.t

val to_expr :
  Db.t ->
  outdir:string ->
  t ->
  unit Workflow.expr