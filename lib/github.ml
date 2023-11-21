open Base
open Devkit
open Printf
open Github_j

let log = Log.from "github"

type t =
  | Push of commit_pushed_notification
  | Pull_request of pr_notification
  | PR_review of pr_review_notification
  | PR_review_comment of pr_review_comment_notification
  | Issue of issue_notification
  | Issue_comment of issue_comment_notification
  | Commit_comment of commit_comment_notification
  | Status of status_notification
  (* all other events *)
  | Event of event_notification

let repo_of_notification = function
  | Push n -> n.repository
  | Pull_request n -> n.repository
  | PR_review n -> n.repository
  | PR_review_comment n -> n.repository
  | Issue n -> n.repository
  | Issue_comment n -> n.repository
  | Commit_comment n -> n.repository
  | Status n -> n.repository
  | Event n -> n.repository

let commits_branch_of_ref ref =
  match String.split ~on:'/' ref with
  | "refs" :: "heads" :: l -> String.concat ~sep:"/" l
  | _ -> ref

let event_of_filename filename =
  match String.split_on_chars ~on:[ '.' ] filename with
  | [ kind; _; "json" ] -> Some kind
  | _ -> None

let merge_commit_re = Re2.create_exn {|^Merge(?: remote-tracking)? branch '(?:origin/)?(.+)'(?: of [^ ]+)?( into .+)?$|}

let is_merge_commit_to_ignore ~(cfg : Config_t.config) ~branch commit =
  match cfg.main_branch_name with
  | Some main_branch when String.equal branch main_branch ->
    (*
      handle "Merge <any branch> into <feature branch>" commits when they are merged into main branch
      we should have already seen these commits on the feature branch but for some reason they are distinct:true

      some possible patterns:
      Merge branch 'develop' into feature_branch
      Merge branch 'develop' of github.com:org/repo into feature_branch
      Merge remote-tracking branch 'origin/develop' into feature_branch
      Merge remote-tracking branch 'origin/develop' (the default message pattern generated by GitHub "Update with merge commit" button)
    *)
    let title = Common.first_line commit.message in
    begin
      match Re2.find_submatches_exn merge_commit_re title with
      | [| Some _; Some incoming_branch; receiving_branch |] ->
        let receiving_branch = Option.map ~f:(String.chop_prefix_exn ~prefix:" into ") receiving_branch in
        String.equal branch incoming_branch || Option.exists ~f:(not $ String.equal branch) receiving_branch
      | _ -> false
      | exception Re2.Exceptions.Regex_match_failed _ -> false
    end
  | Some _ | None -> false

let modified_files_of_commit commit = List.concat [ commit.added; commit.removed; commit.modified ]

let is_valid_signature ~secret headers_sig body =
  let request_hash =
    let key = Cstruct.of_string secret in
    Cstruct.to_string @@ Nocrypto.Hash.SHA1.hmac ~key (Cstruct.of_string body)
  in
  let (`Hex request_hash) = Hex.of_string request_hash in
  String.equal headers_sig (sprintf "sha1=%s" request_hash)

let validate_signature ?signing_key ~headers body =
  match signing_key with
  | None -> Ok ()
  | Some secret ->
  match List.Assoc.find headers "x-hub-signature" ~equal:String.equal with
  | None -> Error "unable to find header x-hub-signature"
  | Some signature -> if is_valid_signature ~secret signature body then Ok () else Error "signatures don't match"

(** Parse a payload. The type of the payload is detected from the headers.

    @raise Failure if unable to extract event from header *)
let parse_exn headers body =
  let string_of_abstract_issue_state = function
    | Open -> "open"
    | Closed -> "closed"
  in
  let string_of_comment_action = function
    | Created -> "created"
    | Edited -> "edited"
    | Deleted -> "deleted"
  in
  let string_of_pr_review_action = function
    | Submitted -> "submitted"
    | Dismissed -> "dismissed"
    | Edited -> "edited"
  in
  let string_of_status_state = function
    | Success -> "success"
    | Failure -> "failure"
    | Pending -> "pending"
    | Error -> "error"
  in
  let print_opt f v = Option.value_map ~f ~default:"none" v in
  let print_comment_preview = Stre.shorten ~escape:true 40 in
  let print_commit_hash s = String.prefix s 8 in
  match List.Assoc.find headers "x-github-event" ~equal:String.equal with
  | None -> Exn.fail "header x-github-event not found"
  | Some event ->
  match event with
  | "push" ->
    let n = commit_pushed_notification_of_string body in
    log#info "[%s] event %s: sender=%s, head=%s, ref=%s" n.repository.full_name event n.sender.login
      (print_opt (fun c -> print_commit_hash c.id) n.head_commit)
      n.ref;
    Push n
  | "pull_request" ->
    let n = pr_notification_of_string body in
    log#info "[%s] event %s: number=%d, state=%s" n.repository.full_name event n.pull_request.number
      (string_of_abstract_issue_state n.pull_request.state);
    Pull_request n
  | "pull_request_review" ->
    let n = pr_review_notification_of_string body in
    log#info "[%s] event %s: number=%d, sender=%s, action=%s, body=%S" n.repository.full_name event
      n.pull_request.number n.sender.login (string_of_pr_review_action n.action)
      (print_opt print_comment_preview n.review.body);
    PR_review n
  | "pull_request_review_comment" ->
    let n = pr_review_comment_notification_of_string body in
    log#info "[%s] event %s: number=%d, sender=%s, action=%s, body=%S" n.repository.full_name event
      n.pull_request.number n.sender.login (string_of_comment_action n.action) (print_comment_preview n.comment.body);
    PR_review_comment n
  | "issues" ->
    let n = issue_notification_of_string body in
    log#info "[%s] event %s: number=%d, state=%s" n.repository.full_name event n.issue.number
      (string_of_abstract_issue_state n.issue.state);
    Issue n
  | "issue_comment" ->
    let n = issue_comment_notification_of_string body in
    log#info "[%s] event %s: number=%d, sender=%s, action=%s, body=%S" n.repository.full_name event n.issue.number
      n.sender.login (string_of_comment_action n.action) (print_comment_preview n.comment.body);
    Issue_comment n
  | "status" ->
    let n = status_notification_of_string body in
    log#info "[%s] event %s: commit=%s, state=%s, context=%s, target_url=%s" n.repository.full_name event
      (print_commit_hash n.commit.sha) (string_of_status_state n.state) n.context (print_opt id n.target_url);
    Status n
  | "commit_comment" ->
    let n = commit_comment_notification_of_string body in
    log#info "[%s] event %s: commit=%s, sender=%s, action=%s, body=%S" n.repository.full_name event
      (print_opt print_commit_hash n.comment.commit_id)
      n.sender.login n.action (print_comment_preview n.comment.body);
    Commit_comment n
  | "create" | "delete" | "member" | "ping" | "release" -> Event (event_notification_of_string body)
  | event -> Exn.fail "unhandled event type : %s" event

type basehead = string * string

type gh_link =
  | Pull_request of repository * int
  | Issue of repository * int
  | Commit of repository * commit_hash
  | Compare of repository * basehead

let commit_sha_re = Re2.create_exn {|[a-f0-9]{4,40}|}
let comparer_re = {|([a-zA-Z0-9/:\-_.~\^]+)|}
let compare_basehead_re = Re2.create_exn (sprintf {|%s([.]{3})%s|} comparer_re comparer_re)
let gh_org_team_re = Re2.create_exn {|[a-zA-Z0-9\-]+/([a-zA-Z0-9\-]+)|}

(** [gh_link_of_string s] parses a URL string [s] to try to match a supported
    GitHub link type, generating repository endpoints if necessary *)
let gh_link_of_string url_str =
  let url = Uri.of_string url_str in
  let path = Uri.path url in
  let gh_com_html_base owner name = sprintf "https://github.com/%s/%s" owner name in
  let gh_com_api_base owner name = sprintf "https://api.github.com/repos/%s/%s" owner name in
  let custom_html_base ?(scheme = "https") base owner name = sprintf "%s://%s/%s/%s" scheme base owner name in
  let custom_api_base ?(scheme = "https") base owner name =
    sprintf "%s://%s/api/v3/repos/%s/%s" scheme base owner name
  in
  match Uri.host url with
  | None -> None
  | Some host ->
  match String.chop_prefix path ~prefix:"/" with
  | None -> None
  | Some path ->
    let path = String.chop_suffix_if_exists ~suffix:"/" path |> flip Stre.nsplitc '/' |> List.map ~f:Web.urldecode in
    let make_repo ~prefix ~owner ~name =
      let base = String.concat ~sep:"/" (List.rev prefix) in
      let scheme = Uri.scheme url in
      let html_base, api_base =
        if String.is_suffix base ~suffix:"github.com" then gh_com_html_base owner name, gh_com_api_base owner name
        else custom_html_base ?scheme base owner name, custom_api_base ?scheme base owner name
      in
      {
        name;
        full_name = sprintf "%s/%s" owner name;
        url = html_base;
        commits_url = sprintf "%s/commits{/sha}" api_base;
        contents_url = sprintf "%s/contents/{+path}" api_base;
        pulls_url = sprintf "%s/pulls{/number}" api_base;
        issues_url = sprintf "%s/issues{/number}" api_base;
        compare_url = sprintf "%s/compare{/basehead}" api_base;
      }
    in
    let rec extract_link_type ~prefix path =
      try
        match path with
        | [ owner; name; "pull"; n ] ->
          let repo = make_repo ~prefix ~owner ~name in
          Some (Pull_request (repo, Int.of_string n))
        | [ owner; name; "issues"; n ] ->
          let repo = make_repo ~prefix ~owner ~name in
          Some (Issue (repo, Int.of_string n))
        | [ owner; name; "commit"; commit_hash ] | [ owner; name; "pull"; _; "commits"; commit_hash ] ->
          let repo = make_repo ~prefix ~owner ~name in
          if Re2.matches commit_sha_re commit_hash then Some (Commit (repo, commit_hash)) else None
        | owner :: name :: "compare" :: base_head | owner :: name :: "pull" :: _ :: "files" :: base_head ->
          let base_head = String.concat ~sep:"/" base_head in
          let repo = make_repo ~prefix ~owner ~name in
          begin
            match Re2.find_submatches_exn compare_basehead_re base_head with
            | [| _; Some base; _; Some merge |] -> Some (Compare (repo, (base, merge)))
            | _ | (exception Re2.Exceptions.Regex_match_failed _) -> None
          end
        | [] -> None
        | next :: path -> extract_link_type ~prefix:(next :: prefix) path
      with _exn -> (* no hard fail when invalid format, slack user can compose any url string *) None
    in
    extract_link_type ~prefix:[ host ] path

let get_project_owners (pr : pull_request) ({ rules } : Config_t.project_owners) =
  Rule.Project_owners.match_rules pr.labels rules
  |> List.partition_map ~f:(fun reviewer ->
       try
         let team = Re2.find_first_exn ~sub:(`Index 1) gh_org_team_re reviewer in
         Second team
       with Re2.Exceptions.Regex_match_failed _ -> First reviewer
     )
  |> fun (reviewers, team_reviewers) ->
  let already_requested_or_author = pr.user.login :: List.map ~f:(fun r -> r.login) pr.requested_reviewers in
  let already_requested_team = List.map ~f:(fun r -> r.slug) pr.requested_teams in
  let reviewers = List.filter ~f:(not $ List.mem already_requested_or_author ~equal:String.equal) reviewers in
  let team_reviewers = List.filter ~f:(not $ List.mem already_requested_team ~equal:String.equal) team_reviewers in
  if List.is_empty reviewers && List.is_empty team_reviewers then None else Some { reviewers; team_reviewers }
