%%%-------------------------------------------------------------------
%%% @author James Aimonetti <james@2600hz.org>
%%% @copyright (C) 2011, VoIP INC
%%% @doc
%%% Utilities shared by a subset of whapps
%%% @end
%%% Created :  3 May 2011 by James Aimonetti <james@2600hz.org>
%%%-------------------------------------------------------------------
-module(whapps_util).

-export([update_all_accounts/1]).
-export([replicate_from_accounts/2, replicate_from_account/3]).
-export([revise_whapp_views_in_accounts/1]).
-export([get_all_accounts/0, get_all_accounts/1]).
-export([get_account_by_realm/1,get_accounts_by_name/1]).
-export([calculate_cost/5]).
-export([get_event_type/1, put_callid/1]).
-export([get_call_termination_reason/1]).
-export([alert/3, alert/4]).
-export([hangup_cause_to_alert_level/1]).

-include("whistle_apps.hrl").

-define(REPLICATE_ENCODING, encoded).
-define(AGG_LIST_BY_REALM, <<"accounts/listing_by_realm">>).
-define(AGG_LIST_BY_NAME, <<"accounts/listing_by_name">>).

%%--------------------------------------------------------------------
%% @doc
%% Update a document in each crossbar account database with the
%% file contents.  This is intended for _design docs....
%%
%% @spec update_all_accounts() -> ok | error
%% @end
%%--------------------------------------------------------------------
-spec update_all_accounts/1 :: (File) -> no_return() when
      File :: binary().
update_all_accounts(File) ->
    lists:foreach(fun(AccountDb) ->
                          timer:sleep(2000),
                          couch_mgr:revise_doc_from_file(AccountDb, crossbar, File)
                  end, get_all_accounts(?REPLICATE_ENCODING)).

%%--------------------------------------------------------------------
%% @public
%% @doc
%% This function will import every .json file found in the given
%% application priv/couchdb/views/ folder into every account
%% @end
%%--------------------------------------------------------------------
-spec revise_whapp_views_in_accounts/1 :: (App) -> no_return() when
      App :: atom().
revise_whapp_views_in_accounts(App) ->
    lists:foreach(fun(AccountDb) ->
                          timer:sleep(2000),
                          couch_mgr:revise_views_from_folder(AccountDb, App)
                  end, get_all_accounts(?REPLICATE_ENCODING)).

%%--------------------------------------------------------------------
%% @public
%% @doc
%% This function will replicate the results of the filter from each
%% account db into the target database
%% @end
%%--------------------------------------------------------------------
-spec replicate_from_accounts/2 :: (TargetDb, FilterDoc) -> no_return() when
      TargetDb :: binary(),
      FilterDoc :: binary().
replicate_from_accounts(TargetDb, FilterDoc) when is_binary(FilterDoc) ->
    lists:foreach(fun(AccountDb) ->
                          timer:sleep(2000),
                          replicate_from_account(AccountDb, TargetDb, FilterDoc)
                  end, get_all_accounts(?REPLICATE_ENCODING)).

%%--------------------------------------------------------------------
%% @public
%% @doc
%% This function will replicate the results of the filter from the
%% source database into the target database
%% @end
%%--------------------------------------------------------------------
-spec replicate_from_account/3 :: (AccountDb, TargetDb, FilterDoc) -> no_return() when
      AccountDb :: binary(),
      TargetDb :: binary(),
      FilterDoc :: binary().
replicate_from_account(AccountDb, AccountDb, _) ->
    ?LOG_SYS("requested to replicate from db ~s to self, skipping", [AccountDb]),
    {error, matching_dbs};
replicate_from_account(AccountDb, TargetDb, FilterDoc) ->
    ReplicateProps = [{<<"source">>, wh_util:format_account_id(AccountDb, ?REPLICATE_ENCODING)}
                      ,{<<"target">>, TargetDb}
                      ,{<<"filter">>, FilterDoc}
                      ,{<<"create_target">>, true}
                     ],
    try
        case couch_mgr:db_replicate(ReplicateProps) of
            {ok, _} ->
                ?LOG_SYS("replicate ~s to ~s using filter ~s succeeded", [AccountDb, TargetDb, FilterDoc]);
            {error, _} ->
                ?LOG_SYS("replicate ~s to ~s using filter ~s failed", [AccountDb, TargetDb, FilterDoc])
        end
    catch
        _:_ ->
            ?LOG_SYS("replicate ~s to ~s using filter ~s error", [AccountDb, TargetDb, FilterDoc])
    end.

%%--------------------------------------------------------------------
%% @public
%% @doc
%% This function will return a list of all account database names
%% in the requested encoding
%% @end
%%--------------------------------------------------------------------
-spec get_all_accounts/0 :: () -> [binary(),...] | [].
-spec get_all_accounts/1 :: ('unencoded' | 'encoded' | 'raw') -> [binary(),...] | [].
get_all_accounts() ->
    get_all_accounts(?REPLICATE_ENCODING).

get_all_accounts(Encoding) ->
    {ok, Databases} = couch_mgr:db_info(),
    [wh_util:format_account_id(Db, Encoding) || Db <- Databases, is_acct_db(Db)].

is_acct_db(<<"account/", _/binary>>) -> true;
is_acct_db(_) -> false.

%%--------------------------------------------------------------------
%% @public
%% @doc Realms are one->one with accounts.
%% @end
%%--------------------------------------------------------------------
-spec get_account_by_realm/1 :: (ne_binary()) -> {ok, ne_binary()} | {error, not_found}.
get_account_by_realm(Realm) ->
    case couch_mgr:get_results(?WH_ACCOUNTS_DB, ?AGG_LIST_BY_REALM, [{<<"key">>, Realm}]) of
        {ok, [JObj|_]} -> 
            {ok, wh_json:get_value([<<"value">>, <<"account_db">>], JObj)};
        _ -> 
            {error, not_found}
    end.

%%--------------------------------------------------------------------
%% @public
%% @doc Names are one->many with accounts since account names are not
%% unique.
%% @end
%%--------------------------------------------------------------------
-spec get_accounts_by_name/1 :: (ne_binary()) -> {ok, [ne_binary(),...]} | {error, not_found}.
get_accounts_by_name(Name) ->
    case couch_mgr:get_results(?WH_ACCOUNTS_DB, ?AGG_LIST_BY_NAME, [{<<"key">>, Name}]) of
        {ok, JObjs} ->
            {ok, [wh_json:get_value([<<"value">>, <<"account_db">>], JObj) || JObj <- JObjs]};
        _ ->
            {error, not_found}
    end.

%%--------------------------------------------------------------------
%% @public
%% @doc
%% Given an API JSON object extract the category and name into a
%% tuple for easy processing
%% @end
%%--------------------------------------------------------------------
-spec get_event_type/1 :: (JObj) -> {binary(), binary()} when
      JObj :: json_object().
get_event_type(JObj) ->
    wh_util:get_event_type(JObj).

%%--------------------------------------------------------------------
%% @public
%% @doc
%% Given an JSON Object extracts the Call-ID into the processes
%% dictionary, failing that the Msg-ID and finally a generic
%% @end
%%--------------------------------------------------------------------
-spec put_callid/1 :: (JObj) -> binary() | 'undefined' when
      JObj :: json_object().
put_callid(JObj) ->
    wh_util:put_callid(JObj).

%%--------------------------------------------------------------------
%% @public
%% @doc
%% Given an JSON Object for a hangup event, or bridge completion
%% this returns the cause and code for the call termination
%% @end
%%--------------------------------------------------------------------
-spec get_call_termination_reason/1 :: (JObj) -> {binary(), binary()} when
      JObj :: json_object().
get_call_termination_reason(JObj) ->
    Cause = case wh_json:get_value(<<"Application-Response">>, JObj, <<>>) of
               <<>> ->
                   wh_json:get_value(<<"Hangup-Cause">>, JObj, <<>>);
               Response ->
                   Response
           end,
    Code = wh_json:get_value(<<"Hangup-Code">>, JObj, <<>>),
    {Cause, Code}.

%%--------------------------------------------------------------------
%% @public
%% @doc
%% Send an email alert to the system admin and account admin if they
%% are configured for the alert level or better
%% @end
%%--------------------------------------------------------------------
-spec alert/3 :: (Level, Format, Args) -> pid() when
      Level :: atom() | string() | binary(),
      Format :: string(),
      Args :: list().
-spec alert/4 :: (Level, Format, Args, AccountId) -> pid() when
      Level :: atom() | string() | binary(),
      Format :: string(),
      Args :: list(),
      AccountId :: undefined | binary().

alert(Level, Format, Args) ->
    alert(Level, Format, Args, undefined).
alert(Level, Format, Args, AccountId) ->
    spawn(fun() -> maybe_send_alert(Level, Format, Args, AccountId) end).

maybe_send_alert(Level, Format, Args, AccountId) ->
    AlertLevel = alert_level_to_integer(Level),
    case [To || To <- [should_alert_system_admin(AlertLevel)
                       ,should_alert_account_admin(AlertLevel, AccountId)]
                    ,To =/= undefined] of
        [] ->
            ok;
        NestedTo ->
            To = lists:flatten(NestedTo),
            Node = wh_util:to_binary(erlang:node()),
            Subject = io_lib:format("WHISTLE: ~s alert from ~s", [Level, Node]),
            From = whapps_config:get(<<"alerts">>, <<"from">>, Node),
            Alert = io_lib:format(lists:flatten(Format), Args),
            Email = {<<"text">>,<<"plain">>,
                     [{<<"From">>,wh_util:to_binary(From)},
                      {<<"To">>, hd(To)},
                      {<<"Subject">>, wh_util:to_binary(Subject)}],
                     [], wh_util:to_binary(Alert)},
            Encoded = mimemail:encode(Email),
            ?LOG_SYS("sending ~s alert email to ~p", [Level, To]),
            Relay = wh_util:to_list(whapps_config:get(<<"smtp_client">>, <<"relay">>, <<"localhost">>)),
            gen_smtp_client:send({From, To, Encoded}, [{relay, Relay}]
                                 ,fun(X) -> ?LOG("sending email to ~p resulted in ~p", [To, X]) end)
    end.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% If the system admin is configured to recieve this alert level
%% return the system admin emal address
%% @end
%%--------------------------------------------------------------------
-spec should_alert_system_admin/1 :: (AlertLevel) -> undefined | binary() when
      AlertLevel :: 0..8.
should_alert_system_admin(AlertLevel) ->
    SystemLevel = whapps_config:get(<<"alerts">>, <<"system_admin_level">>, <<"debug">>),
    case alert_level_to_integer(SystemLevel) of
        0 -> undefined;
        L when L =< AlertLevel ->
            case whapps_config:get(<<"alerts">>, <<"system_admin_email">>) of
                undefined ->
                    undefined;
                Email when is_binary(Email) ->
                    Email;
                Emails when is_list(Emails) ->
                    [wh_util:to_binary(E) || E <- Emails]
            end;
        _ -> undefined
    end.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% If the account admin is configured to recieve this alert level
%% return the account admin emal address
%% @end
%%--------------------------------------------------------------------
-spec should_alert_account_admin/2 :: (AlertLevel, AccountId) -> undefined | binary() when
      AlertLevel :: 0..8,
      AccountId :: undefined | binary().
should_alert_account_admin(_, undefined) ->
    undefined;
should_alert_account_admin(AlertLevel, AccountId) ->
    AccountDb = wh_util:format_account_id(AccountId, encoded),
    case couch_mgr:open_doc(AccountDb, AccountId) of
        {ok, JObj} ->
            AdminLevel = wh_json:get_value([<<"alerts">>, <<"level">>], JObj),
            case alert_level_to_integer(AdminLevel) of
                0 -> undefined;
                L when L =< AlertLevel ->
                    case wh_json:get_value([<<"alerts">>, <<"email">>], JObj) of
                        undefined ->
                            undefined;
                        Email when is_binary(Email) ->
                            Email;
                        Emails when is_list(Emails) ->
                            [wh_util:to_binary(E) || E <- Emails]
                    end;
                _ -> undefined
            end;
        {error, _} ->
            undefined
    end.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% convert the textual alert level to an interger value
%% @end
%%--------------------------------------------------------------------
-spec alert_level_to_integer/1 :: (Level) -> 0..8 when
      Level :: atom() | string() | binary().
alert_level_to_integer(Level) when not is_binary(Level) ->
    alert_level_to_integer(wh_util:to_binary(Level));
alert_level_to_integer(<<"emerg">>) ->
    8;
alert_level_to_integer(<<"critical">>) ->
    7;
alert_level_to_integer(<<"alert">>) ->
    6;
alert_level_to_integer(<<"error">>) ->
    5;
alert_level_to_integer(<<"warning">>) ->
    4;
alert_level_to_integer(<<"notice">>) ->
    3;
alert_level_to_integer(<<"info">>) ->
    2;
alert_level_to_integer(<<"debug">>) ->
    1;
alert_level_to_integer(_) ->
    0.

%% R :: rate, per minute, in dollars (0.01, 1 cent per minute)
%% RI :: rate increment, in seconds, bill in this increment AFTER rate minimum is taken from Secs
%% RM :: rate minimum, in seconds, minimum number of seconds to bill for
%% Sur :: surcharge, in dollars, (0.05, 5 cents to connect the call)
%% Secs :: billable seconds
-spec calculate_cost/5 :: (float() | integer(), integer(), integer(), float() | integer(), integer()) -> float().
calculate_cost(_, _, _, _, 0) -> 0.0;
calculate_cost(R, 0, RM, Sur, Secs) -> calculate_cost(R, 60, RM, Sur, Secs);
calculate_cost(R, RI, RM, Sur, Secs) ->
    case Secs =< RM of
        true -> Sur + ((RM / 60) * R);
        false -> Sur + ((RM / 60) * R) + ( wh_util:ceiling((Secs - RM) / RI) * ((RI / 60) * R))
    end.

hangup_cause_to_alert_level(<<"UNALLOCATED_NUMBER">>) ->
    <<"warning">>;
hangup_cause_to_alert_level(<<"NO_ROUTE_DESTINATION">>) ->
    <<"warning">>;
hangup_cause_to_alert_level(<<"USER_BUSY">>) ->
    <<"warning">>;
hangup_cause_to_alert_level(<<"NORMAL_UNSPECIFIED">>) ->
    <<"warning">>;
hangup_cause_to_alert_level(<<"ORIGINATOR_CANCEL">>) ->
    <<"info">>;
hangup_cause_to_alert_level(<<"NO_ANSWER">>) ->
    <<"info">>;
hangup_cause_to_alert_level(<<"LOSE_RACE">>) ->
    <<"info">>;
hangup_cause_to_alert_level(<<"ATTENDED_TRANSFER">>) ->
    <<"info">>;
hangup_cause_to_alert_level(<<"CALL_REJECTED">>) ->
    <<"info">>;
hangup_cause_to_alert_level(_) ->
    <<"error">>.
