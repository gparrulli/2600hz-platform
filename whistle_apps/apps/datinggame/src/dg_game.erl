%%%-------------------------------------------------------------------
%%% @author James Aimonetti <>
%%% @copyright (C) 2012, James Aimonetti
%%% @doc
%%%
%%% @end
%%% Created : 12 Jan 2012 by James Aimonetti <>
%%%-------------------------------------------------------------------
-module(dg_game).

-behaviour(gen_listener).

%% API
-export([start_link/3, handle_req/2, send_command/3]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, handle_event/2
         ,terminate/2, code_change/3]).

-include("datinggame.hrl").

-define(SERVER, ?MODULE). 

-define(RESPONDERS, [{?MODULE, [{<<"*">>, <<"*">>}]}]).
-define(QUEUE_NAME, <<>>).
-define(QUEUE_OPTIONS, []).
-define(CONSUME_OPTIONS, []).

-record(state, {
          agent = #dg_agent{} :: #dg_agent{}
         ,customer = #dg_customer{} :: #dg_customer{}
         ,recording_name = <<>> :: binary()
         ,server_pid = undefined :: undefined | pid()
         }).

%%%===================================================================
%%% API
%%%===================================================================

%%--------------------------------------------------------------------
%% @doc
%% Starts the server
%%
%% @spec start_link() -> {ok, Pid} | ignore | {error, Error}
%% @end
%%--------------------------------------------------------------------
start_link(Srv, #dg_agent{call_id=CallID}=Agent, #dg_customer{call_id=CCallID}=Customer) ->
    Bindings = [{call, [{callid, CallID}, {restrict_to, [events]}]}
                ,{call, [{callid, CCallID}], {restrict_to, [events]}}
                ,{self, []}
               ],
    gen_listener:start_link(?MODULE
                            ,[{responders, ?RESPONDERS}
                              ,{bindings, Bindings}
                              ,{queue_name, ?QUEUE_NAME}
                              ,{queue_options, ?QUEUE_OPTIONS}
                              ,{consume_options, ?CONSUME_OPTIONS}
                             ]
                            ,[Srv, Agent, Customer]).

handle_req(JObj, Props) ->
    Srv = props:get_value(server, Props),
    ?LOG("sending event to ~p", [Srv]),
    gen_listener:cast(Srv, {event, JObj}).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Initializes the server
%%
%% @spec init(Args) -> {ok, State} |
%%                     {ok, State, Timeout} |
%%                     ignore |
%%                     {stop, Reason}
%% @end
%%--------------------------------------------------------------------
init([Srv, Agent, Customer]) ->
    Self = self(),
    spawn(fun() ->
                  Queue = gen_listener:queue_name(Self),
                  dg_util:channel_status(Queue, Customer),
                  ?LOG("sent request for customer channel_status")
          end),

    ?LOG("the game is afoot"),

    {ok, #state{
       server_pid = Srv
       ,agent = Agent
       ,customer = Customer
       ,recording_name = new_recording_name()
      }}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling call messages
%%
%% @spec handle_call(Request, From, State) ->
%%                                   {reply, Reply, State} |
%%                                   {reply, Reply, State, Timeout} |
%%                                   {noreply, State} |
%%                                   {noreply, State, Timeout} |
%%                                   {stop, Reason, Reply, State} |
%%                                   {stop, Reason, State}
%% @end
%%--------------------------------------------------------------------
handle_call(_Request, _From, State) ->
    Reply = ok,
    {reply, Reply, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling cast messages
%%
%% @spec handle_cast(Msg, State) -> {noreply, State} |
%%                                  {noreply, State, Timeout} |
%%                                  {stop, Reason, State}
%% @end
%%--------------------------------------------------------------------
handle_cast({event, JObj}, #state{agent=Agent
                                  ,customer=(#dg_customer{call_id=CCID, control_queue=CtlQ})=Customer
                                  ,server_pid=Srv
                                 }=State) ->
    EvtType = wh_util:get_event_type(JObj),
    ?LOG("recv evt ~p", [EvtType]),

    case process_event(EvtType, JObj) of
        ignore ->
            ?LOG("ignoring event"),
            {noreply, State};
        {connect, CallID} ->
            ?LOG("bridge on ~s", [CallID]),
            {noreply, State};
        {hangup, CallID} ->
            %% see who hung up
            ?LOG("call-id ~s hungup", [CallID]),
            case CallID =:= CCID of
                true ->
                    ?LOG("customer hungup, freeing agent"),
                    datinggame_listener:free_agent(Srv, Agent),
                    {stop, normal, State};
                false ->
                    ?LOG("agent hungup or disconnected"),
                    send_command([{<<"Application-Name">>, <<"hangup">>}], CCID, CtlQ),
                    datinggame_listener:rm_agent(Srv, Agent),
                    {stop, normal, State}
            end;
        {channel_status, JObj} ->
            gen_listener:cast(self(), connect_call),
            {noreply, State#state{customer=update_customer(Customer, JObj)}}
    end;

handle_cast(connect_call, #state{agent=Agent, customer=Customer}=State) ->
    ok = connect_agent(Agent, Customer),
    ?LOG("sent connection request"),
    {noreply, State};

handle_cast(_Msg, State) ->
    {noreply, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling all non call/cast messages
%%
%% @spec handle_info(Info, State) -> {noreply, State} |
%%                                   {noreply, State, Timeout} |
%%                                   {stop, Reason, State}
%% @end
%%--------------------------------------------------------------------
handle_info(_Info, State) ->
    {noreply, State}.

handle_event(_, _) ->
    {reply, []}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% This function is called by a gen_server when it is about to
%% terminate. It should be the opposite of Module:init/1 and do any
%% necessary cleaning up. When it returns, the gen_server terminates
%% with Reason. The return value is ignored.
%%
%% @spec terminate(Reason, State) -> void()
%% @end
%%--------------------------------------------------------------------
terminate(_Reason, _State) ->
    ok.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Convert process state when code is changed
%%
%% @spec code_change(OldVsn, State, Extra) -> {ok, NewState}
%% @end
%%--------------------------------------------------------------------
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================
new_recording_name() ->
    <<(list_to_binary(wh_util:to_hex(crypto:rand_bytes(16))))/binary, ".mp3">>.

-spec connect_agent/2 :: (#dg_agent{}, #dg_customer{}) -> 'ok'.
connect_agent(#dg_agent{call_id=ACallID, control_queue=CtlQ}, #dg_customer{call_id=CCallID}) ->
    connect(CtlQ, ACallID, CCallID).

connect(CtlQ, ACallID, CCallID) ->
    Cmd = [{<<"Application-Name">>, <<"call_pickup">>}
            ,{<<"Insert-At">>, <<"now">>}
            ,{<<"Target-Call-ID">>, CCallID}
            ,{<<"Call-ID">>, ACallID}
           ],
    send_command(Cmd, ACallID, CtlQ).

-spec send_command/3 :: (proplist(), ne_binary(), ne_binary()) -> 'ok'.
send_command(Command, CallID, CtrlQ) ->
    Prop = Command ++ [{<<"Call-ID">>, CallID}
                       | wh_api:default_headers(<<>>, <<"call">>, <<"command">>, ?APP_NAME, ?APP_VERSION)
                      ],
    wapi_dialplan:publish_command(CtrlQ, Prop).

-spec process_event/2 :: ({ne_binary(), ne_binary()}, json_object()) -> 
                                 {'connect', ne_binary()} |
                                 {'hangup', ne_binary()} |
                                 {'channel_status', json_object()} |
                                 'ignore'.
process_event({<<"call_event">>, <<"CHANNEL_BRIDGE">>}, JObj) ->
    CallID = wh_json:get_value(<<"Call-ID">>, JObj),
    ?LOG(CallID, "bridge event received", []),
    ?LOG(CallID, "bridge other leg id: ~s", [wh_json:get_value(<<"Other-Leg-Unique-ID">>, JObj)]),
    {connect, wh_json:get_value(<<"Call-ID">>, JObj)};
process_event({<<"call_event">>, <<"CHANNEL_UNBRIDGE">>}, JObj) ->
    CallID = wh_json:get_value(<<"Call-ID">>, JObj),
    ?LOG(CallID, "unbridge event received", []),
    ?LOG(CallID, "unbridge code: ~s", [wh_json:get_value(<<"Hangup-Code">>, JObj)]),
    ?LOG(CallID, "unbridge cause: ~s", [wh_json:get_value(<<"Hangup-Cause">>, JObj)]),
    {unbridge, CallID};
process_event({<<"call_event">>, <<"CHANNEL_HANGUP">>}, JObj) ->
    CallID = wh_json:get_value(<<"Call-ID">>, JObj),
    ?LOG(CallID, "hangup event received", []),
    ?LOG(CallID, "hangup code: ~s", [wh_json:get_value(<<"Hangup-Code">>, JObj)]),
    ?LOG(CallID, "hangup cause: ~s", [wh_json:get_value(<<"Hangup-Cause">>, JObj)]),
    {hangup, CallID};
process_event({<<"call_event">>, <<"channel_status_resp">>}, JObj) ->
    ?LOG(wh_json:get_value(<<"Call-ID">>, JObj), "channel_status_resp received", []),
    {channel_status, JObj};
process_event({_EvtCat, _EvtName}, _JObj) ->
    _CallID = wh_json:get_value(<<"Call-ID">>, _JObj),
    ?LOG(_CallID, "ignoring evt ~s:~s", [_EvtCat, _EvtName]),
    ?LOG(_CallID, "media app name: ~s", [wh_json:get_value(<<"Application-Name">>, _JObj)]),
    ?LOG(_CallID, "media app response: ~s", [wh_json:get_value(<<"Application-Response">>, _JObj)]),
    ignore.

-spec update_customer/2 :: (#dg_customer{}, json_object()) -> #dg_customer{}.
update_customer(Customer, JObj) ->
    CallID = wh_json:get_value(<<"Call-ID">>, JObj),
    Hostname = wh_json:get_ne_value(<<"Switch-Hostname">>, JObj),

    ?LOG(CallID, "update customer:", []),
    ?LOG(CallID, "switch hostname: ~s", [Hostname]),

    Customer#dg_customer{
      switch_hostname=Hostname
     }.