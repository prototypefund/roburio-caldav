open Lwt.Infix

(** Common signature for http and https. *)
module type HTTP = Cohttp_lwt.S.Server

let server_src = Logs.Src.create "http.server" ~doc:"HTTP server"
module Server_log = (val Logs.src_log server_src : Logs.LOG)

let access_src = Logs.Src.create "http.access" ~doc:"HTTP server access log"
module Access_log = (val Logs.src_log access_src : Logs.LOG)

module Main (R : Mirage_random.C) (Clock: Mirage_clock.PCLOCK) (KEYS: Mirage_types_lwt.KV_RO) (S: HTTP) = struct
  module X509 = Tls_mirage.X509(KEYS)(Clock)
  module Webdav_server1 = Caldav.Webdav_server.Make(R)(Clock)(Caldav.Webdav_fs.Make(Mirage_fs_mem))(S)
  module Webdav_server2 = Caldav.Webdav_server.Make(R)(Clock)(Caldav.Webdav_fs.Make(FS_unix))(S)

  let initialize_fs clock config data_dir admin_pass =
    let now = Ptime.v (Clock.now_d_ps clock) in
    let module Fs = Caldav.Webdav_fs.Make(FS_unix) in
    let module Dav = Caldav.Webdav_api.Make(Fs) in
    FS_unix.connect data_dir >>= fun fs ->
    Fs.valid fs config >>= fun fs_is_valid ->
    match fs_is_valid, admin_pass with
    | Error (`Msg msg), None ->
      Lwt.fail_with ("got an uninitalized file system (error: " ^ msg ^ "), please provide admin password")
    | Error _, Some password ->
      Dav.initialize_fs fs now config >>= fun () ->
      let salt = Webdav_server1.generate_salt () in
      Dav.make_user fs now config ~name:"root" ~password ~salt >|= fun _ ->
      fs
    | Ok (), None -> Lwt.return fs
    | Ok (), Some password ->
      let salt = Webdav_server1.generate_salt () in
      Dav.change_user_password fs config ~name:"root" ~password ~salt >|= fun _ ->
      fs

  let tls_init kv =
    Lwt.catch (fun () ->
        X509.certificate kv `Default >|= fun cert ->
        Tls.Config.server ~certificates:(`Single cert) ())
      (function
        | Failure _ -> Lwt.fail_with "Could not find server.pem and server.key in the <working directory>/tls."
        | e -> Lwt.fail e)

  (* Redirect to the same address, but in https. *)
  let redirect port request _body =
    let redirect_port = match port with 443 -> None | x -> Some x in
    let uri = Cohttp.Request.uri request in
    let new_uri = Uri.with_scheme uri (Some "https") in
    let new_uri = Uri.with_port new_uri redirect_port in
    Access_log.debug (fun f -> f "[%s] -> [%s]"
                         (Uri.to_string uri) (Uri.to_string new_uri));
    let headers = Cohttp.Header.init_with "location" (Uri.to_string new_uri) in
    S.respond ~headers ~status:`Moved_permanently ~body:`Empty ()

  let serve callback =
    let callback (_, cid) request body =
      let cid = Cohttp.Connection.to_string cid in
      let uri = Cohttp.Request.uri request in
      Access_log.debug (fun f -> f "[%s] serving %s." cid (Uri.to_string uri));
      callback request body
    and conn_closed (_,cid) =
      let cid = Cohttp.Connection.to_string cid in
      Access_log.debug (fun f -> f "[%s] closing" cid);
    in
    S.make ~conn_closed ~callback ()

  let start _random clock tls_keys http =
    (* TODO naming *)
    let init_http port config fs =
      Server_log.info (fun f -> f "listening on %d/HTTP" port);
      http (`TCP port) @@ serve (match fs with
          | `Unix fs -> Webdav_server2.dispatch config fs
          | `Apple fs -> Webdav_server1.dispatch config fs)
    in
    let init_https port config fs =
      tls_init tls_keys >>= fun tls_config ->
      Server_log.info (fun f -> f "listening on %d/HTTPS" port);
      let tls = `TLS (tls_config, `TCP port) in
      http tls @@ serve (match fs with
          | `Unix fs -> Webdav_server2.dispatch config fs
          | `Apple fs -> Webdav_server1.dispatch config fs)
    in
    let config host =
      let do_trust_on_first_use = Key_gen.tofu () in
      Caldav.Webdav_config.config ~do_trust_on_first_use host
    in
    let init_fs_for_runtime config =
      let dir = Key_gen.fs_root ()
      and admin_pass = Key_gen.admin_password ()
      and apple_testable = Key_gen.apple_testable ()
      in
      if not apple_testable then
        initialize_fs clock config dir admin_pass >|= fun fs ->
        `Unix fs
      else
        let module Fs = Caldav.Webdav_fs.Make(Mirage_fs_mem) in
        let module Dav = Caldav.Webdav_api.Make(Fs) in
        let now = Ptime.v (Clock.now_d_ps clock) in
        Mirage_fs_mem.connect "" >>= fun fs ->
        Dav.initialize_fs_for_apple_testsuite fs now config >|= fun () ->
        `Apple fs
    in
    let hostname = Key_gen.hostname () in
    match Key_gen.http_port (), Key_gen.https_port () with
    | None, None ->
      Logs.err (fun m -> m "no port provided for neither HTTP nor HTTPS, exiting") ;
      Lwt.return_unit
    | Some port, None ->
      let config = config @@ Caldav.Webdav_config.host ~port ~hostname () in
      init_fs_for_runtime config >>=
      init_http port config
    | None, Some port ->
      let config = config @@ Caldav.Webdav_config.host ~scheme:"https" ~port ~hostname () in
      init_fs_for_runtime config >>=
      init_https port config
    | Some http_port, Some https_port ->
      Server_log.info (fun f -> f "redirecting on %d/HTTP to %d/HTTPS" http_port https_port);
      let config = config @@ Caldav.Webdav_config.host ~scheme:"https" ~port:https_port ~hostname () in
      init_fs_for_runtime config >>= fun fs ->
      Lwt.pick [
        http (`TCP http_port) @@ serve (redirect https_port) ;
        init_https https_port config fs
      ]
end
