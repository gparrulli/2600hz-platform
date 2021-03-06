-include_lib("whistle/include/wh_types.hrl").
-include_lib("whistle/include/wh_amqp.hrl").
-include_lib("whistle/include/wh_log.hrl").
-include_lib("amqp_client/include/amqp_client.hrl").

-type cf_exe_response() :: {'stop'} | {'continue'} | {'continue', integer()} | {'heartbeat'}.
-type cf_api_error() :: {'error', 'channel_hungup' | 'channel_unbridge' | 'timeout' | json_object()}.
-type cf_api_std_return() :: cf_api_error() | {'ok', json_object()}.
-type cf_api_bridge_return() :: {'error', 'timeout' | json_object()} | {'fail', json_object()} | {'ok', json_object()}.
-type cf_api_binary() :: binary() | 'undefined'.

-define(APP_NAME, <<"callflow">>).
-define(APP_VERSION, <<"0.8.2">> ).

-define(CONFIRM_FILE, <<"/opt/freeswitch/sounds/en/us/callie/ivr/8000/ivr-accept_reject_voicemail.wav">>).

-define(DIALPLAN_MAP, [{ <<"tone">>, <<"tones">> }]).

-define(LIST_BY_NUMBER, {<<"callflow">>, <<"listing_by_number">>}).
-define(LIST_BY_PATTERN, {<<"callflow">>, <<"listing_by_pattern">>}).

-define(NO_MATCH_CF, <<"no_match">>).

-define(DEFAULT_TIMEOUT, <<"20">>).
-define(ANY_DIGIT, [
                     <<"1">>, <<"2">>, <<"3">>
                    ,<<"4">>, <<"5">>, <<"6">>
                    ,<<"7">>, <<"8">>, <<"9">>
                    ,<<"*">>, <<"0">>, <<"#">>
                   ]).

-define(CF_ALERT(Error, AlertCall), 
        (fun({fail, Reason}, #cf_call{account_id=AId}) ->
                 {Cause, Code} = whapps_util:get_call_termination_reason(Reason),
                 Level = whapps_util:hangup_cause_to_alert_level(Cause),
                 ?LOG("failed to bridge: ~s:~s", [Cause, Code]),
                 Message = ["Source: ~s(~p)~n"
                            ,"Alert: failed to bridge ~p ~p~n"
                            ,"Fault: ~p~n"
                            ,"~n~s"
                           ],
                Args = [?MODULE, ?LINE, Reason, Cause, Code
                        ,cf_util:call_info_to_string(AlertCall)],
                 whapps_util:alert(Level, lists:flatten(Message), Args, AId);
            ({error, Reason}, #cf_call{account_id=AId}) ->
                 ?LOG("error: ~s", [wh_json:encode(Reason)]),
                 Message = ["Source: ~s(~p)~n"
                            ,"Alert: generic error~n"
                            ,"Fault: ~p~n"
                            ,"~n~s"
                           ],
                 Args = [?MODULE, ?LINE, Reason
                         ,cf_util:call_info_to_string(AlertCall)],
                  whapps_util:alert(error, lists:flatten(Message), Args, AId)
         end)(Error, AlertCall)).

-define(CF_ALERT(Error, Msg, AlertCall),
        (fun({error, Reason}, Msg, #cf_call{account_id=AId}) ->
                 ?LOG("~s: ~s", [Msg, wh_json:encode(Reason)]),
                 Message = ["Source: ~s(~p)~n"
                            ,"Alert: ~s~n"
                            ,"Fault: ~p~n"
                            ,"~n~s"
                           ],
                 Args = [?MODULE, ?LINE, Msg, Reason
                         ,cf_util:call_info_to_string(AlertCall)],
                 whapps_util:alert(error, lists:flatten(Message), Args, AId)
         end)(Error, Msg, AlertCall)).

-record (cf_call, {
            bdst_q = <<>> :: binary()                              %% The broadcast queue the request was recieved on
            ,cf_pid = 'undefined' :: pid() | 'undefined'                %% PID of the callflow tree processor, who we should pass control back to
            ,flow_id = 'undefined' :: binary() | 'undefined'            %% The ID of the callflow that was intially executed (does not reflect branches, or hunts)
            ,cid_name = <<>> :: binary()                            %% The CID name provided on the route req
            ,cid_number = <<>> :: binary()                          %% The CID number provided on the route req
            ,request = <<>> :: binary()                             %% The request of sip_request_user + @ + sip_request_host
            ,request_user = <<>> :: binary()                        %% SIP request user
            ,request_realm = <<>> :: binary()                       %% SIP request host
            ,from = <<>> :: binary()                                %% Result of sip_from_user + @ + sip_from_host
            ,from_user = <<>>  :: binary()                          %% SIP from user
            ,from_realm = <<>> :: binary()                          %% SIP from host
            ,to = <<>> :: binary()                                  %% Result of sip_to_user + @ + sip_to_host
            ,to_user = <<>> :: binary()                             %% SIP to user
            ,to_realm = <<>> :: binary()                            %% SIP to host
            ,no_match = false :: boolean()                          %% Boolean flag, set when the no_match callflow is used
            ,inception = 'undefined' :: binary() | 'undefined'          %% Origin of the call <<"on-net">> | <<"off-net">>
            ,account_db = 'undefined' :: binary() | 'undefined'         %% The database name of the account that authorized this call
            ,account_id = 'undefined' :: binary() | 'undefined'         %% The account id that authorized this call
            ,authorizing_id = 'undefined' :: binary() | 'undefined'     %% The ID of the record that authorized this call
            ,owner_id = 'undefined' :: binary() | 'undefined'           %% The ID of the that owns the authorizing endpoint
            ,channel_vars = 'undefined' :: json_object() | 'undefined'  %% Any custom channel vars that where provided with the route request
            ,last_action = 'undefined' :: 'undefined' | atom()          %% Previous action
            ,capture_group = 'undefined' :: 'undefined' | binary()      %% If the callflow was found using a pattern this is the capture group
            ,inception_during_transfer = 'false' :: boolean()         %% If the hunt for this callflow was intiated during transfer
           }).
