open Core
open Lwt
open Bistro_engine

let zone = Lazy.force Time.Zone.local

let msg t fmt =
  let k s =
    let t = Time.(to_string (of_tm ~zone (Unix.localtime t))) in
    printf "[%s] %s\n%!" t s
  in
  ksprintf k fmt

let error_short_descr =
  let open Task_result in
  function
  | Input _ -> "input doesn't exist"
  | Select _ -> "invalid select"
  | Shell { exit_code ; outcome ; _ } -> (
      match outcome with
      | `Succeeded -> assert false
      | `Failed ->
        sprintf "ended with exit code %d" exit_code
      | `Missing_output ->
        "missing output"
    )
  | Plugin { outcome ; _ } -> (
      match outcome with
      | `Succeeded -> assert false
      | `Failed -> "failed"
      | `Missing_output ->
        "missing output"
    )
  | Container_image_fetch _ ->
    "failed to fetch container image"

let output_step_event t ~id ~descr =
  let id = String.prefix id 6 in
  msg t "started %s.%s" descr id

let output_event t = function
  | Logger.Workflow_started (Shell { id ; descr ; _ }, _) ->
    output_step_event t ~id ~descr
  | Logger.Workflow_started (Plugin { id ; descr ; _ }, _) ->
    output_step_event t ~id ~descr

  | Workflow_ended { outcome = (Task_result.Shell { id ; descr ; _ } as outcome) ; _ } ->
    let id = String.prefix id 6 in
    let outcome_msg =
      if Task_result.succeeded outcome then
        "success"
      else sprintf "error: %s" (error_short_descr outcome)
    in
    msg t "ended %s.%s (%s)" descr id outcome_msg

  | Workflow_ended { outcome = (Task_result.Plugin { id ; descr ; _ } as outcome) ; _ } ->
    let id = String.prefix id 6 in
    let outcome_msg =
      if Task_result.succeeded outcome then
        "success"
      else sprintf "error: %s" (error_short_descr outcome)
    in
    msg t "ended %s.%s (%s)" descr id outcome_msg

  | Logger.Workflow_allocation_error (Shell s, err) ->
    msg t "allocation error for %s.%s (%s)" s.descr s.id err

  | Logger.Workflow_allocation_error (Plugin s, err) ->
    msg t "allocation error for %s.%s (%s)" s.descr s.id err

  | Workflow_collected w ->
    msg t "collected %s" (Bistro_internals.Workflow.id w)

  | Debug m -> msg t "%s" m
  | _ -> ()

let rec loop stop queue new_event =
  match Queue.dequeue queue with
  | None ->
    if !stop then Lwt.return ()
    else
      Lwt_condition.wait new_event >>= fun () ->
      loop stop queue new_event

  | Some (t, ev) ->
    output_event t ev ;
    loop stop queue new_event

class t =
  let queue = Queue.create () in
  let new_event = Lwt_condition.create () in
  let stop = ref false in
  let loop = loop stop queue new_event in
  object
    method event (_ : Db.t) time event =
      Queue.enqueue queue (time, event) ;
      Lwt_condition.signal new_event ()

    method stop =
      stop := true ;
      Lwt_condition.signal new_event () ;
      loop
  end

let create () = new t
