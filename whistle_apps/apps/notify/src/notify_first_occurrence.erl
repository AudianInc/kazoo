%%%-------------------------------------------------------------------
%%% @copyright (C) 2012, VoIP INC
%%% @doc
%%% Craws accounts and triggers 'first' registration and call emails
%%% @end
%%%
%%% @contributors
%%% Karl Anderson <karl@2600hz.org>
%%%
%%% Created : 25 Jan 2012 by Karl Anderson <karl@2600hz.org>
%%%-------------------------------------------------------------------
-module(notify_first_occurrence).

-include("notify.hrl").
-include_lib("whistle/include/wh_databases.hrl").

-export([init/0]).
-export([handle_req/2]).
-export([start_crawler/0]).
-export([crawler_loop/0]).

-define(SERVER, ?MODULE).

-define(DEFAULT_TEXT_TMPL, notify_init_occur_text_tmpl).
-define(DEFAULT_HTML_TMPL, notify_init_occur_html_tmpl).
-define(DEFAULT_SUBJ_TMPL, notify_init_occur_subj_tmpl).

-define(NOTIFY_INIT_OCCUR_CONFIG_CAT, <<(?NOTIFY_CONFIG_CAT)/binary, ".first_occurrence">>).

%%--------------------------------------------------------------------
%% @public
%% @doc
%% 
%% @end
%%--------------------------------------------------------------------
-spec init/0 :: () -> ok.
init() ->
    %% ensure the vm template can compile, otherwise crash the processes
    {ok, ?DEFAULT_TEXT_TMPL} = erlydtl:compile(whapps_config:get(?NOTIFY_INIT_OCCUR_CONFIG_CAT, default_text_template), ?DEFAULT_TEXT_TMPL),
    {ok, ?DEFAULT_HTML_TMPL} = erlydtl:compile(whapps_config:get(?NOTIFY_INIT_OCCUR_CONFIG_CAT, default_html_template), ?DEFAULT_HTML_TMPL),
    {ok, ?DEFAULT_SUBJ_TMPL} = erlydtl:compile(whapps_config:get(?NOTIFY_INIT_OCCUR_CONFIG_CAT, default_subject_template), ?DEFAULT_SUBJ_TMPL),
    Crawler = {notify_first_occurrence, {notify_first_occurrence, start_crawler, []}, permanent, 5000, worker, [notify_first_occurrence]},
    supervisor:start_child(notify_sup, Crawler),
    ?LOG_SYS("init done for first occurrence notify").

%%--------------------------------------------------------------------
%% @public
%% @doc
%% Starts the server
%%
%% @end
%%--------------------------------------------------------------------
-spec start_crawler/0 :: () -> {ok, pid()}.
start_crawler() ->
    {ok, spawn_link(fun crawler_loop/0)}.

%%--------------------------------------------------------------------
%% @public
%% @doc
%% Handles AMQP request comming from gen_listener (reg_resp)
%% @end
%%--------------------------------------------------------------------
-spec handle_req/2 :: (wh_json:json_object(), proplist()) -> ok.
handle_req(JObj, _Props) ->
    AccountId = case wh_json:is_true(<<"Multiple">>, JObj) of
                    true -> wh_json:get_value([<<"Fields">>, 1, <<"Account-ID">>], JObj);
                    false -> wh_json:get_value([<<"Fields">>, <<"Account-ID">>], JObj)
                end,
    AccountDb = wh_util:format_account_id(AccountId, encoded),
    case couch_mgr:open_doc(AccountDb, AccountId) of
        {ok, Account} ->
            notify_initial_registration(AccountDb, Account);
        _E -> ok
    end.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Attempts to set a flag marking the initial_registration notice as
%% sent, and if successfull then send the email. This will fail if
%% another process does it first (ie: generating a 409 conflict).
%% @end
%%--------------------------------------------------------------------
-spec notify_initial_registration/2 :: (ne_binary(), wh_json:json_object()) -> ok.
notify_initial_registration(AccountDb, JObj) ->
    Account = wh_json:set_value([<<"notifications">>, <<"first_occurrence">>, <<"sent_initial_registration">>]
                                ,true
                                ,JObj),
    case couch_mgr:save_doc(AccountDb, Account) of
        {ok, _} ->
            couch_mgr:ensure_saved(?WH_ACCOUNTS_DB, Account),
            first_occurrence_notice(Account, <<"registration">>);
        _E -> ok
    end.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Attempts to set a flag marking the initial_call notice as
%% sent, and if successfull then send the email. This will fail if
%% another process does it first (ie: generating a 409 conflict).
%% @end
%%--------------------------------------------------------------------
-spec notify_initial_call/2 :: (ne_binary(), wh_json:json_object()) -> ok.
notify_initial_call(AccountDb, JObj) ->
    Account = wh_json:set_value([<<"notifications">>, <<"first_occurrence">>, <<"sent_initial_call">>]
                                ,true
                                ,JObj),
    case couch_mgr:save_doc(AccountDb, Account) of
        {ok, _} ->
            couch_mgr:ensure_saved(?WH_ACCOUNTS_DB, Account),
            first_occurrence_notice(Account, <<"call">>);
        _ -> ok
    end.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Send an email notifying that a first occurrence event has happened. 
%% @end
%%--------------------------------------------------------------------
first_occurrence_notice(Account, Occurrence) ->
    To = wh_json:get_value([<<"notifications">>, <<"first_occurrence">>, <<"send_to">>], Account
                           ,whapps_config:get(?NOTIFY_INIT_OCCUR_CONFIG_CAT, <<"default_to">>, <<"sales@2600hz.com">>)),

    DefaultFrom = list_to_binary([<<"no_reply@">>, wh_util:to_binary(net_adm:localhost())]),
    From = wh_json:get_value([<<"notifications">>, <<"first_occurrence">>, <<"send_from">>], Account
                             ,whapps_config:get(?NOTIFY_INIT_OCCUR_CONFIG_CAT, <<"default_from">>, DefaultFrom)),

    ?LOG("creating first occurrence notice"),
    
    Props = [{<<"From">>, From}
             |get_template_props(Account, Occurrence)
            ],

    CustomTxtTemplate = wh_json:get_value([<<"notifications">>, <<"first_occurrence">>, <<"email_text_template">>], Account),
    {ok, TxtBody} = notify_util:render_template(CustomTxtTemplate, ?DEFAULT_TEXT_TMPL, Props),

    CustomHtmlTemplate = wh_json:get_value([<<"notifications">>, <<"first_occurrence">>, <<"email_html_template">>], Account),
    {ok, HTMLBody} = notify_util:render_template(CustomHtmlTemplate, ?DEFAULT_HTML_TMPL, Props),

    CustomSubjectTemplate = wh_json:get_value([<<"notifications">>, <<"first_occurrence">>, <<"email_subject_template">>], Account),
    {ok, Subject} = notify_util:render_template(CustomSubjectTemplate, ?DEFAULT_SUBJ_TMPL, Props),
    
    send_init_occur_email(TxtBody, HTMLBody, Subject, To, Props),
    send_init_occur_email(TxtBody, HTMLBody, Subject, notify_util:get_rep_email(Account), Props).

%%--------------------------------------------------------------------
%% @private
%% @doc
%% create the props used by the template render function
%% @end
%%--------------------------------------------------------------------
-spec get_template_props/2 :: (wh_json:json_object(), ne_binary()) -> proplist().
get_template_props(Account, Occurrence) ->
    Admin = find_admin(wh_json:get_value(<<"pvt_account_db">>, Account)),
    [{<<"event">>, Occurrence}
     ,{<<"account">>, notify_util:json_to_template_props(Account)}
     ,{<<"admin">>, notify_util:json_to_template_props(Admin)}
     ,{<<"service">>, notify_util:get_service_props(wh_json:new(), Account, ?NOTIFY_INIT_OCCUR_CONFIG_CAT)}
    ].

%%--------------------------------------------------------------------
%% @private
%% @doc
%% process the AMQP requests
%% @end
%%--------------------------------------------------------------------
-spec send_init_occur_email/5 :: (iolist(), iolist(), iolist(), undefined | binary() | [ne_binary(),...], proplist()) -> 'ok'.
send_init_occur_email(TxtBody, HTMLBody, Subject, To, Props) when is_list(To) ->
    [send_init_occur_email(TxtBody, HTMLBody, Subject, T, Props) || T <- To],
    ok;
send_init_occur_email(TxtBody, HTMLBody, Subject, To, Props) ->
    From = props:get_value(<<"From">>, Props),
    %% Content Type, Subtype, Headers, Parameters, Body
    Email = {<<"multipart">>, <<"mixed">>
                 ,[{<<"From">>, From}
                   ,{<<"To">>, To}
                   ,{<<"Subject">>, Subject}
                  ]
             ,[]
             ,[{<<"multipart">>, <<"alternative">>, [], []
                ,[{<<"text">>, <<"plain">>, [{<<"Content-Type">>, <<"text/plain">>}], [], iolist_to_binary(TxtBody)}
                  ,{<<"text">>, <<"html">>, [{<<"Content-Type">>, <<"text/html">>}], [], iolist_to_binary(HTMLBody)}
                 ]
               }
              ]
            },
    ?LOG("sending first occurence notice to: ~p", [To]),
    notify_util:send_email(From, To, Email),
    ok.                

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Occasionally loop over accounts that still require first occurence
%% notifications and test if any should be sent.
%% @end
%%--------------------------------------------------------------------
-spec crawler_loop/0 :: () -> ok.
crawler_loop() ->
    case couch_mgr:get_all_results(?WH_ACCOUNTS_DB, <<"notify/first_occurance">>) of
        {ok, Results} ->
            [test_for_initial_occurrences(Result)
             || Result <- Results
            ];
        _ ->
            ok
    end,
    erlang:send_after(30000, self(), wakeup),
    flush(),
    erlang:hibernate(?MODULE, crawler_loop, []).

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Check if the account has yet to send an initial call/registration
%% notification. 
%% If the account has not sent the notification for calls then check
%% if there are any cdrs, and send the notice if so.
%% If the account has not sent the notification for registrations
%% then request the current registrations for the realm.  When/if
%% the response comes in a notification will be sent. 
%% @end
%%--------------------------------------------------------------------
-spec test_for_initial_occurrences/1 :: (wh_json:json_object()) -> ok.
test_for_initial_occurrences(Result) ->
    Realm = wh_json:get_value([<<"value">>, <<"realm">>], Result),
    {ok, Srv} = notify_sup:listener_proc(),
    ?LOG("testing realm '~s' for intial occurrences~n", [Realm]),
    case wh_json:is_true([<<"value">>, <<"sent_initial_registration">>], Result) of
        true -> ok;
        false ->
            Q = gen_listener:queue_name(Srv),
            Req = [{<<"Realm">>, Realm}
                   ,{<<"Fields">>, [<<"Account-ID">>]}
                   | wh_api:default_headers(Q, ?APP_NAME, ?APP_VERSION)
                  ],
            wapi_registration:publish_query_req(Req)
    end,
    case wh_json:is_true([<<"value">>, <<"sent_initial_call">>], Result) of
        true -> ok;
        false ->
            AccountDb = wh_json:get_value([<<"value">>, <<"account_db">>], Result),
            ViewOptions = [{<<"key">>, <<"cdr">>}
                           ,{<<"limit">>, <<"1">>}
                          ],
            case couch_mgr:get_results(AccountDb, <<"maintenance/listing_by_type">>, ViewOptions) of
                {ok, [_|_]} -> 
                    AccountId = wh_json:get_value(<<"id">>, Result),
                    case couch_mgr:open_doc(AccountDb, AccountId) of
                        {ok, JObj} ->
                            notify_initial_call(AccountDb, JObj);
                        _ -> ok
                    end;
                _ -> ok 
            end
    end,
    timer:sleep(1000).

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Ensure there are no messages in the process queue 
%% @end
%%--------------------------------------------------------------------
-spec flush/0 :: () -> true.
flush() ->
    receive
        _ -> flush()
    after
        0 -> true
    end.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Ensure there are no messages in the process queue 
%% @end
%%--------------------------------------------------------------------
-spec find_admin/1 :: (ne_binary()) -> wh_json:json_object().
find_admin(AccountDb) ->
    ViewOptions = [{<<"key">>, <<"user">>}
                   ,{<<"include_docs">>, true}
                  ],
    case couch_mgr:get_results(AccountDb, <<"maintenance/listing_by_type">>, ViewOptions) of
        {ok, Users} -> 
            case [User || User <- Users, wh_json:get_value([<<"doc">>, <<"priv_level">>], User) =:= <<"admin">>] of
                [] -> wh_json:new();
                Else -> wh_json:get_value(<<"doc">>, hd(Else))
            end;
        _ -> wh_json:new()
    end.
    
