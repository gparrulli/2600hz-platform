%%%-------------------------------------------------------------------
%%% @copyright (C) 2011, VoIP INC
%%% @doc
%%% Handle route requests
%%% @end
%%%-------------------------------------------------------------------
-module(stepswitch_inbound).

-export([init/0, handle_req/2]).

-include("stepswitch.hrl").

-spec init/0 :: () -> 'ok'.
init() ->
    'ok'.

-spec handle_req/2 :: (json_object(), proplist()) -> 'ok'.
handle_req(JObj, _Prop) ->
    whapps_util:put_callid(JObj),
    case wh_json:get_ne_value([<<"Custom-Channel-Vars">>, <<"Account-ID">>], JObj) of
        undefined ->
            ?LOG_START("received new inbound dialplan route request"),
            _ =  inbound_handler(JObj);
        _AcctID ->
            ok
    end.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% handle a request inbound from offnet
%% @end
%%--------------------------------------------------------------------
-spec inbound_handler/1 :: (json_object()) -> 'ok'.
-spec inbound_handler/2 :: (json_object(), ne_binary()) -> 'ok'.
inbound_handler(JObj) ->
    inbound_handler(JObj, get_dest_number(JObj)).
inbound_handler(JObj, Number) ->
    case wh_number_manager:lookup_account_by_number(Number) of
        {ok, AccountId, _} ->
            ?LOG("number associated with account ~s", [AccountId]),
            relay_route_req(
              wh_json:set_value(<<"Custom-Channel-Vars">>, custom_channel_vars(AccountId, undefined, JObj), JObj)
             );
        {error, R} ->
            whapps_util:alert(<<"alert">>, ["Source: ~s(~p)~n"
                                            ,"Alert: could not lookup ~s~n"
                                            ,"Fault: ~p~n"]
                              ,[?MODULE, ?LINE, Number, R]),
            ?LOG_END("unable to get account id ~w", [R])
    end.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% determine the e164 format of the inbound number
%% @end
%%--------------------------------------------------------------------
-spec get_dest_number/1 :: (json_object()) -> ne_binary().
get_dest_number(JObj) ->
    User = case binary:split(wh_json:get_value(<<"To">>, JObj), <<"@">>) of
               [<<"nouser">>, _] ->
                   [ReqUser, _] = binary:split(wh_json:get_value(<<"Request">>, JObj), <<"@">>),
                   ReqUser;
               [ToUser, _] ->
                   ToUser
           end,
    wh_util:to_e164(User).

%%--------------------------------------------------------------------
%% @private
%% @doc
%% build the JSON to set the custom channel vars with the calls
%% account and authorizing  ID
%% @end
%%--------------------------------------------------------------------
-spec custom_channel_vars/3 :: ('undefined' | ne_binary(), 'undefined' | ne_binary(), json_object()) -> json_object().
custom_channel_vars(AccountId, AuthId, JObj) ->
    CCVs = wh_json:get_value(<<"Custom-Channel-Vars">>, JObj, wh_json:new()),
    Vars = [{<<"Account-ID">>, AccountId}
            ,{<<"Inception">>, <<"off-net">>}
            ,{<<"Authorizing-ID">>, AuthId}
            | [Var || {K, _}=Var <- wh_json:to_proplist(CCVs)
                          ,K =/= <<"Account-ID">>
                          ,K =/= <<"Inception">>
                          ,K =/= <<"Authorizing-ID">>
              ]
           ],
    wh_json:from_list([ KV || {_, V}=KV <- Vars, V =/= undefined ]).

%%--------------------------------------------------------------------
%% @private
%% @doc
%% relay a route request once populated with the new properties
%% @end
%%--------------------------------------------------------------------
-spec relay_route_req/1 :: (json_object()) -> 'ok'.
relay_route_req(Req) ->
    wapi_route:publish_req(Req),
    ?LOG_END("relayed route request").
