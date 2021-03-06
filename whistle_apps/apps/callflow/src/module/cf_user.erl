%%%-------------------------------------------------------------------
%%% @author Karl Anderson <karl@2600hz.org>
%%% @copyright (C) 2011, VoIP INC
%%% @doc
%%%
%%% @end
%%% Created : 16 Nov 2011 by Karl Anderson <karl@2600hz.org>
%%%-------------------------------------------------------------------
-module(cf_user).

-include("../callflow.hrl").

-export([handle/2]).

%%--------------------------------------------------------------------
%% @public
%% @doc
%% Entry point for this module, attempts to call an endpoint as defined
%% in the Data payload.  Returns continue if fails to connect or
%% stop when successfull.
%% @end
%%--------------------------------------------------------------------
-spec handle/2 :: (json_object(), #cf_call{}) -> ok.
handle(Data, Call) ->
    UserId = wh_json:get_ne_value(<<"id">>, Data),
    Endpoints = get_endpoints(UserId, Call),
    Timeout = wh_json:get_binary_value(<<"timeout">>, Data, ?DEFAULT_TIMEOUT),
    Strategy = wh_json:get_binary_value(<<"strategy">>, Data, <<"simultaneous">>),
    ?LOG("attempting ~b user devices with strategy ~s", [length(Endpoints), Strategy]),
    case length(Endpoints) > 0 andalso cf_call_command:b_bridge(Endpoints, Timeout, Strategy, <<"true">>, Call) of
        false ->
            Error = {error, wh_json:from_list([{<<"user_id">>, UserId}])},
            ?CF_ALERT(Error, "user has no endpoints", Call),
            cf_exe:continue(Call);
        {ok, _} ->
            ?LOG("completed successful bridge to user"),
            cf_exe:stop(Call);
        {fail, _}=F ->
            ?CF_ALERT(F, Call),
            cf_util:handle_bridge_failure(F, Call);
        {error, _}=E ->
            ?CF_ALERT(E, "error bridging to user", Call),
            cf_exe:continue(Call)
    end.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Loop over the provided endpoints for the callflow and build the
%% json object used in the bridge API
%% @end
%%--------------------------------------------------------------------
-spec get_endpoints/2 :: (undefined | ne_binary(), #cf_call{}) -> json_objects().
get_endpoints(undefined, _) ->
    [];
get_endpoints(UserId, Call) ->
    lists:foldr(fun(EndpointId, Acc) ->
                        case cf_endpoint:build(EndpointId, Call) of
                            {ok, Endpoint} -> Endpoint ++ Acc;
                            {error, _} -> Acc
                        end
                end, [], cf_attributes:fetch_owned_by(UserId, device, Call)).
