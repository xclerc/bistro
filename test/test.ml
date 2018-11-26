open Core
open Bistro

let echo3 x = cached_path (fun%bistro dest ->
    let x = [%eval x] in
    Out_channel.write_lines dest [ x ; x ; x ]
  )

let wc x = cached_value (fun%bistro () ->
    In_channel.read_lines [%path x]
    |> List.length
  )

let request x =
  cached_value (fun%bistro () -> String.split ~on:' ' x)

let main () =
  request "am stram gram"
  |> spawn ~f:(fun x ->
      echo3 x
      |> wc
    )


module type API = sig
  type fasta

  val db_request : string -> string list workflow
  val fetch_sequences : org:string workflow -> fasta path workflow
  val concat_fasta : fasta path list workflow -> fasta path workflow
end

module Pipeline(M : API) = struct
  open M

  let f req =
    db_request req
    |> spawn ~f:(fun org -> fetch_sequences ~org)
    |> concat_fasta
end
