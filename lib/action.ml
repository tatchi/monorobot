open Devkit
open Base
open Slack
open Config_t
open Common
open Github_j

exception Action_error of string

let action_error msg = raise (Action_error msg)
let log = Log.from "action"

module Action (Github_api : Api.Github) (Slack_api : Api.Slack) = struct
  let partition_push (cfg : Config_t.config) n =
    let default = Option.to_list cfg.prefix_rules.default_channel in
    let rules = cfg.prefix_rules.rules in
    let branch = Github.commits_branch_of_ref n.ref in
    let main_branch = if cfg.prefix_rules.filter_main_branch then cfg.main_branch_name else None in
    let filter_by_branch = Rule.Prefix.filter_by_branch ~branch ~main_branch in
    n.commits
    |> List.filter ~f:(fun c ->
         let skip = Github.is_merge_commit_to_ignore ~cfg ~branch c in
         if skip then log#info "main branch merge, ignoring %s: %s" c.id (first_line c.message);
         not skip
       )
    |> List.concat_map ~f:(fun commit ->
         let rules = List.filter ~f:(filter_by_branch ~distinct:commit.distinct) rules in
         let matched_channel_names =
           Github.modified_files_of_commit commit
           |> List.filter_map ~f:(Rule.Prefix.match_rules ~rules)
           |> List.dedup_and_sort ~compare:String.compare
         in
         let channel_names =
           if List.is_empty matched_channel_names && commit.distinct then default else matched_channel_names
         in
         List.map channel_names ~f:(fun n -> n, commit)
       )
    |> Map.of_alist_multi (module String)
    |> Map.map ~f:(fun commits -> { n with commits })
    |> Map.to_alist

  let partition_label (cfg : Config_t.config) (labels : label list) =
    let default = cfg.label_rules.default_channel in
    let rules = cfg.label_rules.rules in
    labels |> List.concat_map ~f:(Rule.Label.match_rules ~rules) |> List.dedup_and_sort ~compare:String.compare
    |> fun channel_names -> if List.is_empty channel_names then Option.to_list default else channel_names

  let partition_pr cfg (n : pr_notification) =
    match n.action with
    | (Opened | Closed | Reopened | Labeled | Ready_for_review) when not n.pull_request.draft ->
      partition_label cfg n.pull_request.labels
    | _ -> []

  let partition_issue cfg (n : issue_notification) =
    match n.action with
    | Opened | Closed | Reopened | Labeled -> partition_label cfg n.issue.labels
    | _ -> []

  let partition_pr_review_comment cfg (n : pr_review_comment_notification) =
    match n.action with
    | Created -> partition_label cfg n.pull_request.labels
    | _ -> []

  let partition_issue_comment cfg (n : issue_comment_notification) =
    match n.action with
    | Created -> partition_label cfg n.issue.labels
    | _ -> []

  let partition_pr_review cfg (n : pr_review_notification) =
    let { review; action; _ } = n in
    match action, review.state, review.body with
    | Submitted, "commented", (Some "" | None) -> []
    (* the case (action = Submitted, review.state = "commented", review.body = "") happens when
       a reviewer starts a review by commenting on particular sections of the code, which triggars a pull_request_review_comment event simultaneouly,
       and then submits the review without submitting any general feedback or explicit approval/changes.

       the case (action = Submitted, review.state = "commented", review.body = null) happens when
       a reviewer adds a single comment on a particular section of the code, which triggars a pull_request_review_comment event simultaneouly.

       in both cases, since pull_request_review_comment is already handled by another type of event, information in the pull_request_review payload
       does not provide any insightful information and will thus be ignored. *)
    | Submitted, _, _ -> partition_label cfg n.pull_request.labels
    | _ -> []

  let partition_commit (cfg : Config_t.config) files =
    let default = Option.to_list cfg.prefix_rules.default_channel in
    let rules = cfg.prefix_rules.rules in
    let matched_channel_names =
      List.map ~f:(fun f -> f.filename) files
      |> List.filter_map ~f:(Rule.Prefix.match_rules ~rules)
      |> List.dedup_and_sort ~compare:String.compare
    in
    if List.is_empty matched_channel_names then default else matched_channel_names

  let partition_status (ctx : Context.t) (n : status_notification) =
    let repo = n.repository in
    let cfg = Context.find_repo_config_exn ctx repo.url in
    let pipeline = n.context in
    let current_status = n.state in
    let rules = cfg.status_rules.rules in
    let action_on_match (branches : branch list) ~notify_channels ~notify_dm =
      let%lwt () = State.set_repo_pipeline_status ctx.state repo.url ~pipeline ~branches ~status:current_status in
      let%lwt direct_message =
        if notify_dm then begin
          match%lwt Slack_api.lookup_user ~ctx ~cfg ~email:n.commit.commit.author.email () with
          (* To send a DM, channel parameter is set to the user id of the recipient *)
          | Ok res -> Lwt.return [ res.user.id ]
          | Error e ->
            log#warn "couldn't match commit email to slack profile: %s" e;
            Lwt.return []
        end
        else Lwt.return []
      in
      let%lwt chans =
        let default = Option.to_list cfg.prefix_rules.default_channel in
        match notify_channels with
        | false -> Lwt.return []
        | true ->
        match List.is_empty branches with
        | true -> Lwt.return []
        | false ->
        match cfg.main_branch_name with
        | None -> Lwt.return default
        | Some main_branch_name ->
        (* non-main branch build notifications go to default channel to reduce spam in topic channels *)
        match List.exists branches ~f:(fun { name } -> String.equal name main_branch_name) with
        | false -> Lwt.return default
        | true ->
          let sha = n.commit.sha in
          ( match%lwt Github_api.get_api_commit ~ctx ~repo ~sha with
          | Error e -> action_error e
          | Ok commit -> Lwt.return @@ partition_commit cfg commit.files
          )
      in
      Lwt.return (direct_message @ chans)
    in
    if Context.is_pipeline_allowed ctx repo.url ~pipeline then begin
      let%lwt repo_state = State.find_or_add_repo ctx.state repo.url in
      match Rule.Status.match_rules ~rules n with
      | Some (Ignore, _, _) | None -> Lwt.return []
      | Some (Allow, notify_channels, notify_dm) -> action_on_match n.branches ~notify_channels ~notify_dm
      | Some (Allow_once, notify_channels, notify_dm) ->
      match Map.find repo_state.pipeline_statuses pipeline with
      | Some branch_statuses ->
        let has_same_status_state_as_prev (branch : branch) =
          match Map.find branch_statuses branch.name with
          | None -> false
          | Some state -> Poly.equal state current_status
        in
        let branches = List.filter n.branches ~f:(Fn.non @@ has_same_status_state_as_prev) in
        action_on_match branches ~notify_channels ~notify_dm
      | None -> action_on_match n.branches ~notify_channels ~notify_dm
    end
    else Lwt.return []

  let partition_commit_comment (ctx : Context.t) n =
    let cfg = Context.find_repo_config_exn ctx n.repository.url in
    match n.comment.commit_id with
    | None -> action_error "unable to find commit id for this commit comment event"
    | Some sha ->
      ( match%lwt Github_api.get_api_commit ~ctx ~repo:n.repository ~sha with
      | Error e -> action_error e
      | Ok commit ->
        let default = Option.to_list cfg.prefix_rules.default_channel in
        let rules = cfg.prefix_rules.rules in
        ( match n.comment.path with
        | None -> Lwt.return @@ (partition_commit cfg commit.files, commit)
        | Some filename ->
        match Rule.Prefix.match_rules filename ~rules with
        | None -> Lwt.return (default, commit)
        | Some chan -> Lwt.return ([ chan ], commit)
        )
      )

  let ignore_notifications_from_user cfg req =
    let sender_login =
      match req with
      | Github.Issue_comment n ->
        Some n.sender.login
        (*
          | Github.Push n -> Some n.sender.login
          | Pull_request n -> Some n.sender.login
          | PR_review n -> Some n.sender.login
          | PR_review_comment n -> Some n.sender.login
          | Issue n -> Some n.sender.login
          | Commit_comment n -> Some n.sender.login
        *)
      | _ -> None
    in
    match sender_login with
    | Some sender_login -> List.exists cfg.ignored_users ~f:(String.equal sender_login)
    | None -> false

  let generate_notifications (ctx : Context.t) (req : Github.t) =
    let repo = Github.repo_of_notification req in
    let cfg = Context.find_repo_config_exn ctx repo.url in
    match ignore_notifications_from_user cfg req with
    | true -> Lwt.return []
    | false ->
    match req with
    | Github.Push n ->
      partition_push cfg n |> List.map ~f:(fun (channel, n) -> generate_push_notification n channel) |> Lwt.return
    | Pull_request n -> partition_pr cfg n |> List.map ~f:(generate_pull_request_notification n) |> Lwt.return
    | PR_review n -> partition_pr_review cfg n |> List.map ~f:(generate_pr_review_notification n) |> Lwt.return
    | PR_review_comment n ->
      partition_pr_review_comment cfg n |> List.map ~f:(generate_pr_review_comment_notification n) |> Lwt.return
    | Issue n -> partition_issue cfg n |> List.map ~f:(generate_issue_notification n) |> Lwt.return
    | Issue_comment n ->
      partition_issue_comment cfg n |> List.map ~f:(generate_issue_comment_notification n) |> Lwt.return
    | Commit_comment n ->
      let%lwt channels, api_commit = partition_commit_comment ctx n in
      let notifs = List.map ~f:(generate_commit_comment_notification api_commit n) channels in
      Lwt.return notifs
    | Status n ->
      let%lwt channels = partition_status ctx n in
      let notifs = List.map ~f:(generate_status_notification cfg n) channels in
      Lwt.return notifs

  let send_notifications (ctx : Context.t) notifications =
    let notify (msg : Slack_t.post_message_req) =
      match%lwt Slack_api.send_notification ~ctx ~msg with
      | Ok () -> Lwt.return_unit
      | Error e -> action_error e
    in
    Lwt_list.iter_s notify notifications

  (** [refresh_repo_config ctx n] fetches the latest repo config if it's
      uninitialized, or if the incoming request [n] is a push
      notification containing commits that touched the config file. *)
  let refresh_repo_config (ctx : Context.t) notification =
    let repo = Github.repo_of_notification notification in
    let fetch_config () =
      match%lwt Github_api.get_config ~ctx ~repo with
      | Ok config ->
        Context.set_repo_config ctx repo.url config;
        Context.print_config ctx repo.url;
        Lwt.return @@ Ok ()
      | Error e -> action_error e
    in
    match Context.find_repo_config ctx repo.url with
    | None -> fetch_config ()
    | Some _ ->
    match notification with
    | Github.Push commit_pushed_notification ->
      let commits = commit_pushed_notification.commits in
      let modified_files = List.concat_map commits ~f:Github.modified_files_of_commit in
      let config_was_modified = List.exists modified_files ~f:(String.equal ctx.config_filename) in
      if config_was_modified then fetch_config () else Lwt.return @@ Ok ()
    | _ -> Lwt.return @@ Ok ()

  let do_github_tasks ctx (repo : repository) (req : Github.t) =
    let cfg = Context.find_repo_config_exn ctx repo.url in
    let project_owners (pull_request : pull_request) repository number =
      match Github.get_project_owners pull_request cfg.project_owners with
      | Some reviewers ->
        ( match%lwt Github_api.request_reviewers ~ctx ~repo:repository ~number ~reviewers with
        | Ok () -> Lwt.return_unit
        | Error e -> action_error e
        )
      | None -> Lwt.return_unit
    in
    match req with
    | Github.Pull_request
        { action; pull_request = { draft = false; state = Open; _ } as pull_request; repository; number; _ } ->
      begin
        match action with
        | Ready_for_review | Labeled -> project_owners pull_request repository number
        | _ -> Lwt.return_unit
      end
    | _ -> Lwt.return_unit

  let process_github_notification (ctx : Context.t) headers body =
    let validate_signature secrets payload =
      let repo = Github.repo_of_notification payload in
      let signing_key = Context.gh_hook_secret_token_of_secrets secrets repo.url in
      Github.validate_signature ?signing_key ~headers body
    in
    let repo_is_supported secrets (repo : Github_t.repository) =
      List.exists secrets.repos ~f:(fun r -> String.equal r.url repo.url)
    in
    try%lwt
      let secrets = Context.get_secrets_exn ctx in
      match Github.parse_exn headers body with
      | exception Failure msg ->
        log#warn "skipping event : %s" msg;
        Lwt.return_unit
      | payload ->
      match validate_signature secrets payload with
      | Error e -> action_error e
      | Ok () ->
        let repo = Github.repo_of_notification payload in
        ( match repo_is_supported secrets repo with
        | false -> action_error @@ Printf.sprintf "unsupported repository %s" repo.url
        | true ->
          ( match%lwt refresh_repo_config ctx payload with
          | Error e -> action_error e
          | Ok () ->
            let%lwt notifications = generate_notifications ctx payload in
            let%lwt () = Lwt.join [ send_notifications ctx notifications; do_github_tasks ctx repo payload ] in
            ( match ctx.state_filepath with
            | None -> Lwt.return_unit
            | Some path ->
              ( match%lwt State.save ctx.state path with
              | Ok () -> Lwt.return_unit
              | Error e -> action_error e
              )
            )
          )
        )
    with
    | Yojson.Json_error msg ->
      log#error "failed to parse file as valid JSON (%s)" msg;
      Lwt.return_unit
    | Action_error msg ->
      log#error "%s" msg;
      Lwt.return_unit
    | Context.Context_error msg ->
      log#error "%s" msg;
      Lwt.return_unit

  let process_link_shared_event (ctx : Context.t) (event : Slack_t.link_shared_event) =
    let fetch_bot_user_id () =
      match%lwt Slack_api.send_auth_test ~ctx () with
      | Ok { user_id; _ } ->
        State.set_bot_user_id ctx.state user_id;
        let%lwt () =
          Option.value_map ctx.state_filepath ~default:Lwt.return_unit ~f:(fun path ->
            match%lwt State.save ctx.state path with
            | Ok () -> Lwt.return_unit
            | Error msg ->
              log#warn "failed to save state file %s : %s" path msg;
              Lwt.return_unit
          )
        in
        Lwt.return_some user_id
      | Error msg ->
        log#warn "failed to query slack auth.test : %s" msg;
        Lwt.return_none
    in
    let process link =
      let with_gh_result_populate_slack (type a) ~(api_result : (a, string) Result.t)
        ~(populate : repository -> a -> Slack_t.message_attachment) ~repo
        =
        match api_result with
        | Error _ -> Lwt.return_none
        | Ok item -> Lwt.return_some @@ (link, populate repo item)
      in
      match Github.gh_link_of_string link with
      | None -> Lwt.return_none
      | Some gh_link ->
      match gh_link with
      | Pull_request (repo, number) ->
        let%lwt result = Github_api.get_pull_request ~ctx ~repo ~number in
        with_gh_result_populate_slack ~api_result:result ~populate:Slack_message.populate_pull_request ~repo
      | Issue (repo, number) ->
        let%lwt result = Github_api.get_issue ~ctx ~repo ~number in
        with_gh_result_populate_slack ~api_result:result ~populate:Slack_message.populate_issue ~repo
      | Commit (repo, sha) ->
        let%lwt result = Github_api.get_api_commit ~ctx ~repo ~sha in
        with_gh_result_populate_slack ~api_result:result ~populate:Slack_message.populate_commit ~repo
      | Compare (repo, basehead) ->
        let%lwt result = Github_api.get_compare ~ctx ~repo ~basehead in
        with_gh_result_populate_slack ~api_result:result ~populate:Slack_message.populate_compare ~repo
    in
    log#info "slack link shared: channel=%s, user=%s, message_ts=%s, links=[%s]" event.channel event.user
      event.message_ts
      (Stre.catmap ~sep:"; " (fun (l : Slack_t.link_shared_link) -> l.url) event.links);
    let%lwt is_self_bot_user =
      match String.equal event.user "U00" with
      | true ->
        (* field has value "U00" when the message containing the link was sent by a bot with a custom username set *)
        Lwt.return_true
      | false ->
        let%lwt bot_user_id =
          match State.get_bot_user_id ctx.state with
          | Some id -> Lwt.return_some id
          | None -> fetch_bot_user_id ()
        in
        Lwt.return (Option.value_map ~default:false ~f:(String.equal event.user) bot_user_id)
    in
    if List.length event.links > 2 then Lwt.return "ignored: more than two links present"
    else if is_self_bot_user then Lwt.return "ignored: is bot user"
    else begin
      let links = List.map event.links ~f:(fun l -> l.url) in
      let%lwt unfurls = List.map links ~f:process |> Lwt.all |> Lwt.map List.filter_opt |> Lwt.map StringMap.of_list in
      if Map.is_empty unfurls then Lwt.return "ignored: no links to unfurl"
      else begin
        match%lwt Slack_api.send_chat_unfurl ~ctx ~channel:event.channel ~ts:event.message_ts ~unfurls () with
        | Ok () -> Lwt.return "ok"
        | Error e ->
          log#error "%s" e;
          Lwt.return "ignored: failed to unfurl links"
      end
    end

  let process_slack_event (ctx : Context.t) headers body =
    let secrets = Context.get_secrets_exn ctx in
    match Slack_j.event_notification_of_string body with
    | Url_verification payload -> Lwt.return payload.challenge
    | Event_callback notification ->
    match Slack.validate_signature ?signing_key:secrets.slack_signing_secret ~headers body with
    | Error e -> action_error e
    | Ok () ->
    match notification.event with
    | Link_shared event -> process_link_shared_event ctx event

  (** debugging endpoint to return current in-memory repo config *)
  let print_config (ctx : Context.t) repo_url =
    log#info "finding config for repo_url: %s" repo_url;
    match Context.find_repo_config ctx repo_url with
    | None -> Lwt.return_error (`Not_found, Printf.sprintf "repo_url not found: %s" repo_url)
    | Some config -> Lwt.return_ok (Config_j.string_of_config config)
end
