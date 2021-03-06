%%%-------------------------------------------------------------------
%%% @author Karl Anderson <karl@2600hz.org>
%%% @copyright (C) 2011, VoIP INC
%%% @doc
%%% VMBoxes module
%%%
%%%
%%% Handle client requests for vmbox documents
%%%
%%% @end
%%% Created : 05 Jan 2011 by Karl Anderson <karl@2600hz.org>
%%%-------------------------------------------------------------------
-module(cb_vmboxes).

-behaviour(gen_server).

%% API
-export([start_link/0]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-include("../../include/crossbar.hrl").

-define(SERVER, ?MODULE).

-define(CB_LIST, <<"vmboxes/crossbar_listing">>).

-define(MESSAGES_RESOURCE, <<"messages">>).
-define(BIN_DATA, <<"raw">>).
-define(MEDIA_MIME_TYPES, [ "application/octet-stream"]).

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
start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

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
init(_) ->
    _ = bind_to_crossbar(),
    {ok, ok}.

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
handle_info({binding_fired, Pid, <<"v1_resource.content_types_provided.vmboxes">>, {RD, Context, Params}}, State) ->
    spawn(fun() ->
                  Context1 = content_types_provided(Params, Context),
                  Pid ! {binding_result, true, {RD, Context1, Params}}
          end),
    {noreply, State};

handle_info({binding_fired, Pid, <<"v1_resource.resource_exists.vmboxes">>, Payload}, State) ->
    spawn(fun() ->
                  {Result, Payload1} = resource_exists(Payload),
                  Pid ! {binding_result, Result, Payload1}
          end),
    {noreply, State};

handle_info({binding_fired, Pid, <<"v1_resource.allowed_methods.vmboxes">>, Payload}, State) ->
    spawn(fun() ->
                  {Result, Payload1} = allowed_methods(Payload),
                  Pid ! {binding_result, Result, Payload1}
          end),
    {noreply, State};

handle_info({binding_fired, Pid, <<"v1_resource.validate.vmboxes">>, [RD, Context | Params]}, State) ->
    spawn(fun() ->
                  _ = crossbar_util:put_reqid(Context),
                  crossbar_util:binding_heartbeat(Pid),
                  Context1 = validate(Params, Context),
                  Pid ! {binding_result, true, [RD, Context1, Params]}
          end),
    {noreply, State};

handle_info({binding_fired, Pid, <<"v1_resource.execute.get.vmboxes">>, [RD, Context | Params]}, State) ->
    case Params of
        [_VMBoxId, ?MESSAGES_RESOURCE, _MediaId, ?BIN_DATA] ->
            spawn(fun() ->
                          _ = crossbar_util:put_reqid(Context),
                          Pid ! {binding_result, true, [RD, Context, Params]}
                  end);
        _ ->
            spawn(fun() ->
                          Pid ! {binding_result, true, [RD, Context, Params]}
                  end)
    end,
    {noreply, State};

handle_info({binding_fired, Pid, <<"v1_resource.execute.post.vmboxes">>, [RD, Context | Params]}, State) ->
    spawn(fun() ->
                  _ = crossbar_util:put_reqid(Context),
                  Context1 = crossbar_doc:save(Context),
                  Pid ! {binding_result, true, [RD, Context1, Params]}
          end),
    {noreply, State};

handle_info({binding_fired, Pid, <<"v1_resource.execute.put.vmboxes">>, [RD, Context | Params]}, State) ->
    spawn(fun() ->
                  _ = crossbar_util:put_reqid(Context),
                  Context1 = crossbar_doc:save(Context),
                  Pid ! {binding_result, true, [RD, Context1, Params]}
          end),
    {noreply, State};

handle_info({binding_fired, Pid, <<"v1_resource.execute.delete.vmboxes">>, [RD, Context | Params]}, State) ->
    case Params of
        [_, ?MESSAGES_RESOURCE, _] ->
            spawn(fun() ->
                          _ = crossbar_util:put_reqid(Context),
                          Context1 = crossbar_doc:save(Context),
                          Pid ! {binding_result, true, [RD, Context1, Params]}
                  end);
        _ ->
            spawn(fun() ->
                          _ = crossbar_util:put_reqid(Context),
                          Context1 = crossbar_doc:delete(Context),
                          Pid ! {binding_result, true, [RD, Context1, Params]}
                  end)
    end,
    {noreply, State};

handle_info({binding_fired, Pid, _false, Payload}, State) ->
    Pid ! {binding_result, false, Payload},
    {noreply, State};

handle_info(_Info, State) ->
    {noreply, State}.

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
%%--------------------------------------------------------------------
%% @private
%% @doc
%% This function binds this server to the crossbar bindings server,
%% for the keys we need to consume.
%% @end
%%--------------------------------------------------------------------
-spec bind_to_crossbar/0 :: () ->  'ok' | {'error', 'exists'}.
bind_to_crossbar() ->
    _ = crossbar_bindings:bind(<<"v1_resource.content_types_provided.vmboxes">>),
    _ = crossbar_bindings:bind(<<"v1_resource.validate.vmboxes">>),
    _ = crossbar_bindings:bind(<<"v1_resource.allowed_methods.vmboxes">>),
    _ = crossbar_bindings:bind(<<"v1_resource.resource_exists.vmboxes">>),
    crossbar_bindings:bind(<<"v1_resource.execute.#.vmboxes">>).

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Add content types accepted and provided by this module
%%
%% @end
%%--------------------------------------------------------------------
-spec content_types_provided/2 :: (path_tokens(), #cb_context{}) -> #cb_context{}.
content_types_provided([_,?MESSAGES_RESOURCE, _, ?BIN_DATA], #cb_context{req_verb = <<"get">>}=Context) ->
    CTP = [{to_binary, ?MEDIA_MIME_TYPES}],
    Context#cb_context{content_types_provided=CTP};
content_types_provided(_, Context) -> Context.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% This function determines the verbs that are appropriate for the
%% given Nouns.  IE: '/accounts/' can only accept GET and PUT
%%
%% Failure here returns 405
%% @end
%%--------------------------------------------------------------------
-spec allowed_methods/1 :: (path_tokens()) -> {boolean(), http_methods()}.
allowed_methods([]) ->
    {true, ['GET', 'PUT']};
allowed_methods([_]) ->
    {true, ['GET', 'POST', 'DELETE']};
allowed_methods([_, ?MESSAGES_RESOURCE]) ->
    {true, ['GET']};
allowed_methods([_, ?MESSAGES_RESOURCE, _]) ->
    {true, ['GET', 'POST', 'DELETE']};
allowed_methods([_, ?MESSAGES_RESOURCE, _, ?BIN_DATA]) ->
    {true, ['GET']};
allowed_methods(_) ->
    {false, []}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% This function determines if the provided list of Nouns are valid.
%%
%% Failure here returns 404
%% @end
%%--------------------------------------------------------------------
-spec resource_exists/1 :: (path_tokens()) -> {boolean(), []}.
resource_exists([]) ->
    {true, []};
resource_exists([_]) ->
    {true, []};
resource_exists([_, ?MESSAGES_RESOURCE])->
    {true, []};
resource_exists([_, ?MESSAGES_RESOURCE, _])->
    {true, []};
resource_exists([_, ?MESSAGES_RESOURCE, _, ?BIN_DATA])->
    {true, []};
resource_exists(_) ->
    {false, []}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% This function determines if the parameters and content are correct
%% for this request
%%
%% Failure here returns 400
%% @end
%%--------------------------------------------------------------------
-spec validate/2 :: (path_tokens(), #cb_context{}) -> #cb_context{}.
validate([], #cb_context{req_verb = <<"get">>}=Context) ->
    load_vmbox_summary(Context);
validate([], #cb_context{req_verb = <<"put">>}=Context) ->
    create_vmbox(Context);
validate([DocId], #cb_context{req_verb = <<"get">>}=Context) ->
    load_vmbox(DocId, Context);
validate([DocId], #cb_context{req_verb = <<"post">>}=Context) ->
    update_vmbox(DocId, Context);
validate([DocId], #cb_context{req_verb = <<"delete">>}=Context) ->
    load_vmbox(DocId, Context);
validate([DocId, ?MESSAGES_RESOURCE], #cb_context{req_verb = <<"get">>}=Context) ->
    load_message_summary(DocId, Context);
validate([DocId, ?MESSAGES_RESOURCE, MediaId], #cb_context{req_verb = <<"get">>}=Context) ->
    load_message(DocId, MediaId, Context);
validate([DocId, ?MESSAGES_RESOURCE, MediaId], #cb_context{req_verb = <<"post">>}=Context) ->
    update_message(DocId, MediaId, Context);
validate([DocId, ?MESSAGES_RESOURCE, MediaId], #cb_context{req_verb = <<"delete">>}=Context) ->
    delete_message(DocId, MediaId, Context);
validate([DocId, ?MESSAGES_RESOURCE, MediaId, ?BIN_DATA], #cb_context{req_verb = <<"get">>}=Context) ->
    load_message_binary(DocId, MediaId, Context);

validate(_Other, Context) ->
    crossbar_util:response_faulty_request(Context).

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Attempt to load list of accounts, each summarized.  Or a specific
%% account summary.
%% @end
%%--------------------------------------------------------------------
-spec load_vmbox_summary/1 :: (#cb_context{}) -> #cb_context{}.
load_vmbox_summary(Context) ->
    crossbar_doc:load_view(?CB_LIST, [], Context, fun normalize_view_results/2).

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Create a new vmbox document with the data provided, if it is valid
%% @end
%%--------------------------------------------------------------------
-spec create_vmbox/1 :: (#cb_context{}) -> #cb_context{}.
create_vmbox(#cb_context{req_data=Data}=Context) ->
    case wh_json_validator:is_valid(Data, <<"vmboxes">>) of
        {fail, Errors} ->
            crossbar_util:response_invalid_data(Errors, Context);
        {pass, JObj} ->
            Context#cb_context{
              doc=wh_json:set_value(<<"pvt_type">>, <<"vmbox">>, JObj)
              ,resp_status=success
             }
    end.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Load a vmbox document from the database
%% @end
%%--------------------------------------------------------------------
-spec load_vmbox/2 :: (ne_binary(), #cb_context{}) -> #cb_context{}.
load_vmbox(DocId, Context) ->
    crossbar_doc:load(DocId, Context).

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Update an existing vmbox document with the data provided, if it is
%% valid
%% @end
%%--------------------------------------------------------------------
-spec update_vmbox/2 :: (ne_binary(), #cb_context{}) -> #cb_context{}.
update_vmbox(DocId, #cb_context{req_data=Data}=Context) ->
    case wh_json_validator:is_valid(Data, <<"vmboxes">>) of
        {fail, Errors} ->
            crossbar_util:response_invalid_data(Errors, Context);
        {pass, JObj} ->
            crossbar_doc:load_merge(DocId, JObj, Context)
    end. 

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Normalizes the resuts of a view
%% @end
%%--------------------------------------------------------------------
-spec normalize_view_results/2 :: (json_object(), json_objects()) -> json_objects().
normalize_view_results(JObj, Acc) ->
    [wh_json:get_value(<<"value">>, JObj)|Acc].

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Get messages summary for a given mailbox
%% @end
%%--------------------------------------------------------------------
-spec load_message_summary/2 :: (ne_binary(), #cb_context{}) -> #cb_context{}.
load_message_summary(DocId, Context) ->
    case load_messages(DocId, Context) of
        [] ->            
            crossbar_util:response([], Context);
        [?EMPTY_JSON_OBJECT] ->
            crossbar_util:response([], Context);
        Messages ->
            crossbar_util:response(Messages,Context)
    end.


%%--------------------------------------------------------------------
%% @private
%% @doc
%% Get associated  Messages as a List of json obj
%% @end
%%--------------------------------------------------------------------
-spec load_messages/2 :: (ne_binary(), #cb_context{}) -> json_objects().
load_messages(DocId, Context) ->
    #cb_context{resp_status=success, doc=Doc} = crossbar_doc:load(DocId, Context),
    wh_json:get_value(<<"messages">>, Doc, []).

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Get message by its media ID and its context
%% @end
%%--------------------------------------------------------------------
-spec load_message/3 :: (ne_binary(), ne_binary(), #cb_context{}) -> #cb_context{}.
load_message(DocId, MediaId, Context) ->
    case lists:filter(fun(M) -> wh_json:get_value(<<"media_id">>, M) =:= MediaId end, load_messages(DocId, Context)) of
        [M] ->
            crossbar_util:response(M,Context);
        _ ->
            crossbar_util:response_bad_identifier(MediaId, Context)
    end.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Get message binary content so it can be downloaded
%% VMBoxId is the doc id for the voicemail box document
%% VMId is the id for the voicemail document, containing the binary data
%% @end
%%--------------------------------------------------------------------
-spec load_message_binary/3 :: (ne_binary(), ne_binary(), #cb_context{}) -> #cb_context{}.
load_message_binary(VMBoxId, VMId, #cb_context{req_data=ReqData, db_name=Db, resp_headers=RespHeaders}=Context) ->
    {ok, VMJObj} = couch_mgr:open_doc(Db, VMId),
    [AttachmentId] = wh_json:get_keys(<<"_attachments">>, VMJObj),

    #cb_context{resp_data=VMMetaJObj} = load_message(VMBoxId, VMId, Context),

    {ok, VMBoxJObj} = couch_mgr:open_doc(Db, VMBoxId),

    Filename = generate_media_name(wh_json:get_value(<<"caller_id_number">>, VMMetaJObj)
                                   ,wh_json:get_value(<<"timestamp">>, VMMetaJObj)
                                   ,wh_json:get_value(<<"media_type">>, VMJObj)
                                   ,wh_json:get_value(<<"timezone">>, VMBoxJObj)
                                  ),
    ?LOG("Sending file with filename ~s", [Filename]),

    Ctx = crossbar_doc:load_attachment(VMId, AttachmentId, Context),

    _ = case wh_json:get_value(<<"folder">>, ReqData) of
            undefined -> ok;
            Folder ->
                ?LOG("Moving message to ~s", [Folder]),
                spawn(fun() ->
                              _ = crossbar_util:put_reqid(Context),
                              Context1 = update_message1(VMBoxId, VMId, Context),
                              #cb_context{resp_status=success}=crossbar_doc:save(Context1),
                              ?LOG("Saved message to new folder ~s", [Folder]),
                              update_mwi(VMBoxJObj, Db)
                      end)
        end,

    Ctx#cb_context{resp_headers = [
                                   {<<"Content-Type">>, wh_json:get_value([<<"_attachments">>, AttachmentId, <<"content_type">>], VMJObj)},
                                   {<<"Content-Disposition">>, <<"attachment; filename=", Filename/binary>>},
                                   {<<"Content-Length">> ,wh_util:to_binary(wh_json:get_value([<<"_attachments">>, AttachmentId, <<"length">>], VMJObj))}
                                   | RespHeaders
                                  ]
                  }.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% DELETE the message (set folder prop to deleted)
%% @end
%%--------------------------------------------------------------------
-spec delete_message/3 :: (ne_binary(), ne_binary(), #cb_context{}) -> #cb_context{}.
delete_message(VMBoxId, MediaId, #cb_context{db_name=Db}=Context) ->
    Context1 = #cb_context{doc=VMBox} = crossbar_doc:load(VMBoxId, Context),
    Messages = wh_json:get_value(<<"messages">>, VMBox, []),

    case get_message_index(MediaId, Messages) of
        Index when Index > 0 ->
            VMBox1 = wh_json:set_value([<<"messages">>, Index, <<"folder">>], <<"deleted">>, VMBox),

            %% let's not forget the associated private_media doc
            {ok, D} = couch_mgr:open_doc(Db, MediaId),
            couch_mgr:save_doc(Db, wh_json:set_value(<<"pvt_deleted">>, true, D)),

            _ = spawn(fun() -> _ = crossbar_util:put_reqid(Context), update_mwi(VMBox1, Db) end),

            Context1#cb_context{doc=VMBox1};
        _ ->
            crossbar_util:response_bad_identifier(MediaId, Context)
    end.

-spec update_mwi/2 :: (json_object(), ne_binary()) -> 'ok'.
update_mwi(VMBox, DB) ->
    OwnerID = wh_json:get_value(<<"owner_id">>, VMBox),
    false = wh_util:is_empty(OwnerID),

    ?LOG("Sending MWI update to devices owned by ~s", [OwnerID]),

    Messages = wh_json:get_value(<<"messages">>, VMBox, []),

    Devices = cb_module_util:get_devices_owned_by(OwnerID, DB),

    New = count_messages(Messages, <<"new">>),
    Saved = count_messages(Messages, <<"saved">>),

    ?LOG("New: ~b Saved: ~b", [New, Saved]),

    CommonHeaders = [{<<"Messages-New">>, New}
                     ,{<<"Messages-Saved">>, Saved}
                     | wh_api:default_headers(?APP_NAME, ?APP_VERSION)
                    ],

    lists:foreach(fun(Device) ->
                          User = wh_json:get_value([<<"sip">>, <<"username">>], Device),
                          Realm = wh_json:get_value([<<"sip">>, <<"realm">>], Device),

                          Command = wh_json:from_list([{<<"Notify-User">>, User}
                                                       ,{<<"Notify-Realm">>, Realm}
                                                       | CommonHeaders
                                                      ]),
                          catch wapi_notifications:publish_mwi_update(Command)
                  end, Devices).

-spec count_messages/2 :: (json_objects(), ne_binary()) -> non_neg_integer().
count_messages(Messages, Folder) ->
    lists:sum([1 || Message <- Messages, wh_json:get_value(<<"folder">>, Message) =:= Folder]).

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Initiate the recursive search of the message index
%%
%% @end
%%--------------------------------------------------------------------
-spec get_message_index/2 :: (ne_binary(), json_objects()) -> pos_integer().
get_message_index(MediaId, Messages) ->
    find_index(MediaId, Messages, 1).

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Recursively finds the index of message
%%
%% @end
%%--------------------------------------------------------------------
-spec find_index/3 :: (ne_binary(), json_objects(), pos_integer()) -> integer().
find_index(MediaId, [Message | Ms], Index) ->
    case wh_json:get_value(<<"media_id">>, Message) =:= MediaId of
        true -> Index;
        false -> find_index(MediaId, Ms, Index + 1)
    end;
find_index(_, [], _) ->
    -1.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Update the message informations
%% Only Folder prop is editable atm
%% @end
%%--------------------------------------------------------------------
-spec update_message/3 :: (ne_binary(), ne_binary(), #cb_context{}) -> #cb_context{}.
update_message(DocId, MediaId, #cb_context{req_data=Data}=Context) ->
    case wh_json_validator:is_valid(Data, <<"vmboxes">>) of
        {fail, Errors} ->
            crossbar_util:response_invalid_data(Errors, Context);
        {pass, JObj} ->
            update_message1(DocId, MediaId, Context#cb_context{doc=JObj})
    end. 

-spec update_message1/3 :: (ne_binary(), ne_binary(), #cb_context{}) -> #cb_context{}.
update_message1(VMBoxId, MediaId, #cb_context{req_data=ReqData}=Context) ->
    RequestedValue = wh_json:get_value(<<"folder">>, ReqData),

    Context1 = #cb_context{doc=VMBox} = crossbar_doc:load(VMBoxId, Context),

    Messages = wh_json:get_value(<<"messages">>, VMBox, []),

    case get_message_index(MediaId, Messages) of
        Index when Index > 0 ->
            VMBox1 = wh_json:set_value([<<"messages">>, Index, <<"folder">>], RequestedValue, VMBox),
            Context1#cb_context{doc=VMBox1};
        _Idx ->
            crossbar_util:response_bad_identifier(MediaId, Context)
    end.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% generate a media name based on CallerID and creation date
%% CallerID_YYYY-MM-DD_HH-MM-SS.ext
%% @end
%%--------------------------------------------------------------------
-spec generate_media_name/4 :: (ne_binary(), ne_binary(), ne_binary(), ne_binary()) -> ne_binary().
generate_media_name(CallerId, GregorianSeconds, Ext, Timezone) ->
    UTCDateTime = calendar:gregorian_seconds_to_datetime(wh_util:to_integer(GregorianSeconds)),
    
    LocalTime = case localtime:utc_to_local(UTCDateTime, wh_util:to_list(Timezone)) of
                    {{_,_,_},{_,_,_}}=LT -> ?LOG("Converted to TZ: ~s", [Timezone]), LT;
                    _ -> ?LOG("Bad TZ: ~p", [Timezone]), UTCDateTime
                end,

    Date = wh_util:pretty_print_datetime(LocalTime),

    case CallerId of
        undefined -> list_to_binary(["unknown_", Date, ".", Ext]);
        _ -> list_to_binary([CallerId, "_", Date, ".", Ext])
    end.
