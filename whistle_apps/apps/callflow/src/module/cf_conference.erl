%%%-------------------------------------------------------------------
%%% @author Karl Anderson <karl@2600hz.org>
%%% @copyright (C) 2011, VoIP INC
%%% @doc
%%%
%%% @end
%%% Created : 16 Mar 2011 by Karl Anderson <karl@2600hz.org>
%%%-------------------------------------------------------------------
-module(cf_conference).

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
handle(Data, #cf_call{account_id=AccountId}=Call) ->
    Command = [{<<"Account-ID">>, AccountId}
               ,{<<"Call-ID">>, cf_exe:callid(Call)}
               ,{<<"Control-Queue">>, cf_exe:control_queue_name(Call)}
               ,{<<"Conference-ID">>, wh_json:get_value(<<"id">>, Data)}
               ,{<<"Moderator">>, wh_json:get_binary_boolean(<<"moderator">>, Data)}
               | wh_api:default_headers(cf_exe:queue_name(Call)
                                        ,<<"conference">>
                                        ,<<"discovery">>
                                        ,?APP_NAME
                                        ,?APP_VERSION)
              ],
    {ok, Payload} = wh_api:conference_discovery_req(Command),
    amqp_util:conference_publish(Payload, discovery),
    {ok, _} = cf_call_command:wait_for_hangup(),
    cf_exe:stop(Call).
