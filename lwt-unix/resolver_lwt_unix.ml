(*
 * Copyright (c) 2014 Anil Madhavapeddy <anil@recoil.org>
 *
 * Permission to use, copy, modify, and distribute this software for any
 * purpose with or without fee is hereby granted, provided that the above
 * copyright notice and this permission notice appear in all copies.
 *
 * THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
 * WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
 * MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
 * ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
 * WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
 * ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
 * OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
 *
 *)

open Lwt.Infix

let is_tls_service =
  (* TODO fill in the blanks. nowhere else to get this information *)
  function
  | "https" | "imaps" -> true
  | _ -> false

let system_service_hashtbl = Hashtbl.create 13

let system_service name =
  match Hashtbl.find_opt system_service_hashtbl name with
  | Some svc -> Lwt.return (Some svc)
  | None ->
    Lwt.catch
      (fun () ->
         Lwt_unix.getservbyname name "tcp" >>= fun s ->
         let tls = is_tls_service name in
         let svc = { Resolver.name; port=s.Lwt_unix.s_port; tls } in
         Hashtbl.replace system_service_hashtbl name svc ;
         Lwt.return (Some svc))
      (function Not_found -> Lwt.return_none | e -> Lwt.fail e)

let static_service name =
  match Uri_services.tcp_port_of_service name with
  | [] -> Lwt.return_none
  | port :: _ ->
     let tls = is_tls_service name in
     let svc = { Resolver.name; port; tls } in
     Lwt.return (Some svc)

let get_host uri =
  match Uri.host uri with
  | None -> "localhost"
  | Some host ->
      match Ipaddr.of_string host with
      | Some ip -> Ipaddr.to_string ip
      | None -> host

let get_port service uri =
  match Uri.port uri with
  | None -> service.Resolver.port
  | Some port -> port

let endp_of_addrinfo = function
  | { Unix.ai_addr = ADDR_INET (addr, port) ; _ } ->
    Conduit.TCP (Ipaddr_unix.of_inet_addr addr, port)
  | { ai_addr = ADDR_UNIX path ; _ } ->
    Conduit.Unix_domain_socket path

(* Build a default resolver that uses the system gethostbyname and
   the /etc/services file *)
let system_resolver service uri =
  let open Lwt_unix in
  let host = get_host uri in
  let port = get_port service uri in
  getaddrinfo
    host (string_of_int port) [AI_SOCKTYPE SOCK_STREAM] >|=
  List.map endp_of_addrinfo

let static_resolver hosts service uri =
  match Hashtbl.find_opt hosts (get_host uri) with
  | None -> Lwt.return_nil
  | Some v -> Lwt.return v

let system =
  let service = system_service in
  let rewrites = ["", system_resolver] in
  Resolver_lwt.init ~service ~rewrites ()

(* Build a default resolver from a static set of lookup rules *)
let static hosts =
  let service = static_service in
  let rewrites = ["", static_resolver hosts] in
  Resolver_lwt.init ~service ~rewrites ()
