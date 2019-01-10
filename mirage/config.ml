open Mirage

let net =
  if_impl Key.is_unix
    (socket_stackv4 [Ipaddr.V4.any])
    (static_ipv4_stack ~arp:farp default_network)

(* set ~tls to false to get a plain-http server *)
let http_srv = http_server @@ conduit_direct ~tls:true net

(* TODO: make it possible to enable and disable schemes without providing a port *)
let http_port =
  let doc = Key.Arg.info ~doc:"Listening HTTP port." ["http"] ~docv:"PORT" in
  Key.(create "http_port" Arg.(opt (some int) None doc))

let https_port =
  let doc = Key.Arg.info ~doc:"Listening HTTPS port." ["https"] ~docv:"PORT" in
  Key.(create "https_port" Arg.(opt (some int) None doc))

let certs = generic_kv_ro ~key:Key.(value @@ kv_ro ()) "tls"

let admin_password =
  let doc = Key.Arg.info ~doc:"Password for the administrator." ["admin-password"] ~docv:"STRING" in
  Key.(create "admin_password" Arg.(opt (some string) None doc))

let fs_root =
  let doc = Key.Arg.info ~doc:"Location of calendar data." [ "data" ] ~docv:"DIR" in
  Key.(create "fs_root" Arg.(required string doc))

let tofu =
  let doc = Key.Arg.info ~doc:"If a user does not exist, create them and give them a new calendar." [ "tofu" ] in
  Key.(create "tofu" Arg.(flag doc))

let hostname =
  let doc = Key.Arg.info ~doc:"Hostname to use." [ "host" ] ~docv:"STRING" in
  Key.(create "hostname" Arg.(required string doc))

let monitor =
  let doc = Key.Arg.info ~doc:"Hostname to use for monitoring." [ "monitor" ] ~docv:"STRING" in
  Key.(create "monitor" Arg.(opt (some string) None doc))

let apple_testable =
  let doc = Key.Arg.info ~doc:"Configure the server to use with Apple CCS CalDAVtester." [ "apple-testable" ] in
  Key.(create "apple_testable" Arg.(flag doc))

(*
in the Mirage module (from the mirage package):
code: let keys = List.map Key.abstract [ http_port ; https_port ; admin_password ]
We get: Error: This expression has type
         string option Mirage.Key.key = string option Functoria_key.key
       but an expression was expected of type
         int option Mirage.Key.key = int option Functoria_key.key
       Type string is not compatible with type int
http_port and https_port are of type "int option Key.t", admin_password "string option Key.t".
How to prevent getting Key.abstract specialized to "int option Key.t"?

existential wrapper:
type any_key = Any : 'a Key.key -> any_key
let keys = List.map (fun (Any k) -> Key.abstract k) [Any http_port; Any https_port; Any admin_password]
*)

let main =
  let direct_dependencies = [
    package "uri" ;
    package ~pin:"git+https://github.com/roburio/ocaml-webmachine.git#webdav" "webmachine" ;
    package ~pin:"git+https://github.com/roburio/caldav.git" "caldav" ;
    package ~pin:"git+https://github.com/hannesm/metrics.git#influx-mirage" "metrics" ;
    package ~pin:"git+https://github.com/hannesm/metrics.git#influx-mirage" "metrics-mirage" ;
    package ~pin:"git+https://github.com/hannesm/metrics.git#influx-mirage" "metrics-influx" ;
    package "mirage-fs-unix" ;
    package "mirage-fs-mem" ;
    package "mirage-fs-lwt" ;
  ] in
  let keys =
    [ Key.abstract http_port ; Key.abstract https_port ;
      Key.abstract admin_password ; Key.abstract fs_root ;
      Key.abstract tofu ; Key.abstract hostname ; 
      Key.abstract monitor ; Key.abstract apple_testable ]
  in
  foreign
    ~packages:direct_dependencies ~keys
    "Unikernel.Main" (random @-> pclock @-> mclock @-> kv_ro @-> stackv4 @-> http @-> job)

let () =
  register "caldav" [main $ default_random $ default_posix_clock $default_monotonic_clock $ certs $ net $ http_srv]
