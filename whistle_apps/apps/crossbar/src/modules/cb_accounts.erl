%%%-------------------------------------------------------------------
%%% @author Karl Anderson <karl@2600hz.org>
%%% @copyright (C) 2011, VoIP INC
%%% @doc
%%% Account module
%%%
%%% Handle client requests for account documents
%%%
%%% @end
%%% Created : 05 Jan 2011 by Karl Anderson <karl@2600hz.org>
%%%-------------------------------------------------------------------
-module(cb_accounts).

-behaviour(gen_server).

%% API
-export([start_link/0, create_account/1, get_realm_from_db/1, ensure_parent_set/0]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-include("../../include/crossbar.hrl").

-define(SERVER, ?MODULE).


-define(AGG_VIEW_FILE, <<"views/accounts.json">>).
-define(AGG_VIEW_SUMMARY, <<"accounts/listing_by_id">>).
-define(AGG_VIEW_PARENT, <<"accounts/listing_by_parent">>).
-define(AGG_VIEW_CHILDREN, <<"accounts/listing_by_children">>).
-define(AGG_VIEW_DESCENDANTS, <<"accounts/listing_by_descendants">>).
-define(AGG_VIEW_REALM, <<"accounts/listing_by_realm">>).

-define(PVT_TYPE, <<"account">>).

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

-spec get_realm_from_db/1 :: (ne_binary()) -> {'ok', ne_binary()} | {'error', atom()}.
get_realm_from_db(DBName) ->
    Doc = wh_util:format_account_id(DBName, raw),
    case couch_mgr:open_doc(DBName, Doc) of
        {ok, JObj} -> {ok, wh_json:get_value(<<"realm">>, JObj)};
        {error, _}=E -> E
    end.

%% Iterate through all account docs in the accounts DB and ensure each
%% has a parent
-spec ensure_parent_set/0 :: () -> 'ok' | {'error', 'no_accounts' | atom()}.
ensure_parent_set() ->
    case couch_mgr:get_results(?WH_ACCOUNTS_DB, ?AGG_VIEW_SUMMARY, [{<<"include_docs">>, true}]) of
        {ok, []} -> {error, no_accounts};
        {ok, AcctJObjs} ->
            DefaultParentID = find_default_parent(AcctJObjs),
            ?LOG("Default Parent ID: ~s", [DefaultParentID]),
            [ ensure_parent_set(DefaultParentID, wh_json:get_value(<<"id">>, AcctJObj))
              || AcctJObj <- AcctJObjs,
                 wh_json:get_value(<<"id">>, AcctJObj) =/= DefaultParentID, % not the default parent
                 wh_json:get_value([<<"doc">>, <<"pvt_tree">>], AcctJObj, []) =:= [] % empty tree (should have at least the parent)
            ],
            ok;
        {error, _}=E -> E
    end.

-spec ensure_parent_set/2 :: (ne_binary(), ne_binary()) -> 'ok' | #cb_context{}.
ensure_parent_set(DefaultParentID, AccountID) ->
    case update_tree(AccountID, DefaultParentID, #cb_context{db_name=?WH_ACCOUNTS_DB}) of
        #cb_context{resp_status=success}=Context ->
            ?LOG("updating tree of ~s", [AccountID]),
            crossbar_doc:save(Context);
        _Context ->
            ?LOG("failed to update tree for ~s", [AccountID])
    end.

-spec find_default_parent/1 :: (json_objects()) -> ne_binary().
find_default_parent(AcctJObjs) ->
    case whapps_config:get(?CONFIG_CAT, <<"default_parent">>) of
        undefined ->
            First = hd(AcctJObjs),
            {_, OldestAcctID} = lists:foldl(fun(AcctJObj, {Created, _}=Eldest) ->
                                                    case wh_json:get_integer_value([<<"doc">>, <<"pvt_created">>], AcctJObj) of
                                                        Older when Older < Created  -> {Older, wh_json:get_value(<<"id">>, AcctJObj)};
                                                        _ -> Eldest
                                                    end
                                            end
                                            ,{wh_json:get_integer_value([<<"doc">>, <<"pvt_created">>], First), wh_json:get_value(<<"id">>, First)}
                                            ,AcctJObjs),
            whapps_config:set(?CONFIG_CAT, <<"default_parent">>, OldestAcctID),
            OldestAcctID;
        Default -> Default
    end.

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
    self() ! {rebind, all},
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
    {reply, ok, State}.

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
handle_info({binding_fired, Pid, <<"v1_resource.allowed_methods.accounts">>, Payload}, State) ->
    spawn(fun() ->
                  {Result, Payload1} = allowed_methods(Payload),
                  Pid ! {binding_result, Result, Payload1}
          end),
    {noreply, State};

handle_info({binding_fired, Pid, <<"v1_resource.resource_exists.accounts">>, Payload}, State) ->
    spawn(fun() ->
                  {Result, Payload1} = resource_exists(Payload),
                  Pid ! {binding_result, Result, Payload1}
          end),
    {noreply, State};

handle_info({binding_fired, Pid, <<"v1_resource.validate.accounts">>, [RD, #cb_context{req_nouns=[{?WH_ACCOUNTS_DB, _}]}=Context | Params]}, State) ->
    spawn(fun() ->
                  _ = crossbar_util:put_reqid(Context),
                  crossbar_util:binding_heartbeat(Pid),
                  %% Do all of our prep-work out of the agg db
                  %% later we will switch to save to the client db
                  Context1 = validate(Params, Context#cb_context{db_name=?WH_ACCOUNTS_DB}),
                  Pid ! {binding_result, true, [RD, Context1, Params]}
          end),
    {noreply, State};

handle_info({binding_fired, Pid, <<"v1_resource.validate.accounts">>, [RD, Context | Params]}, State) ->
    spawn(fun() ->
                  _ = crossbar_util:put_reqid(Context),
                  Context1 = load_account_db(Params, Context),
                  Pid ! {binding_result, true, [RD, Context1, Params]}
          end),
    {noreply, State};

handle_info({binding_fired, Pid, <<"v1_resource.execute.post.accounts">>, [RD, Context | [AccountId, <<"parent">>]=Params]}, State) ->
    spawn(fun() ->
                  _ = crossbar_util:put_reqid(Context),
                  crossbar_util:binding_heartbeat(Pid),
                  case crossbar_doc:save(Context#cb_context{db_name=wh_util:format_account_id(AccountId, encoded)}) of
                      #cb_context{resp_status=success}=Context1 ->
                          Pid ! {binding_result, true, [RD, Context1#cb_context{resp_data = wh_json:new()}, Params]};
                      Else ->
                          Pid ! {binding_result, true, [RD, Else, Params]}
                  end
          end),
    {noreply, State};

handle_info({binding_fired, Pid, <<"v1_resource.execute.post.accounts">>, [RD, #cb_context{doc=Doc}=Context | [AccountId]=Params]}, State) ->
    spawn(fun() ->
                  _ = crossbar_util:put_reqid(Context),
                  crossbar_util:binding_heartbeat(Pid),
                  %% this just got messy
                  %% since we are not replicating, the accounts rev and the account rev on
                  %% this doc can drift.... so set it to account save, then set it to
                  %% accounts for the final operation... good times
                  AccountDb = wh_util:format_account_id(AccountId, encoded),
                  AccountsRev = wh_json:get_value(<<"_rev">>, Doc, <<>>),
                  case couch_mgr:lookup_doc_rev(AccountDb, AccountId) of
                      {ok, Rev} ->
                          case crossbar_doc:save(Context#cb_context{db_name=AccountDb
                                                                    ,doc=wh_json:set_value(<<"_rev">>, Rev, Doc)
                                                                   }) of
                              #cb_context{resp_status=success, doc=Doc1}=Context1 ->
                                  couch_mgr:ensure_saved(?WH_ACCOUNTS_DB, wh_json:set_value(<<"_rev">>, AccountsRev, Doc1)),
                                  Pid ! {binding_result, true, [RD, Context1, Params]};
                              Else ->
                                  Pid ! {binding_result, true, [RD, Else, Params]}
                          end;
                      _ ->
                          case crossbar_doc:save(Context#cb_context{db_name=AccountDb
                                                                    ,doc=wh_json:delete_key(<<"_rev">>, Doc)
                                                                   }) of
                              #cb_context{resp_status=success, doc=Doc1}=Context1 ->
                                  couch_mgr:ensure_saved(?WH_ACCOUNTS_DB, wh_json:set_value(<<"_rev">>, AccountsRev, Doc1)),
                                  Pid ! {binding_result, true, [RD, Context1, Params]};
                              Else ->
                                  Pid ! {binding_result, true, [RD, Else, Params]}
                          end
                  end
          end),
    {noreply, State};

handle_info({binding_fired, Pid, <<"v1_resource.execute.put.accounts">>, [RD, Context | Params]}, State) ->
    spawn(fun() ->
                  _ = crossbar_util:put_reqid(Context),
                  crossbar_util:binding_heartbeat(Pid),
                  Context1 = create_new_account_db(Context),
                  Pid ! {binding_result, true, [RD, Context1, Params]}
          end),
    {noreply, State};

handle_info({binding_fired, Pid, <<"v1_resource.execute.delete.accounts">>, [RD, Context | [AccountId]=Params]}, State) ->
    spawn(fun() ->
                  _ = crossbar_util:put_reqid(Context),
                  %% dont use the account id in cb_context as it may not represent the db_name...
                  DbName = wh_util:format_account_id(AccountId, encoded),
                  try
                      ok = wh_number_manager:free_numbers(AccountId),

                      %% Ensure the DB that we are about to delete is an account
                      case couch_mgr:open_doc(DbName, AccountId) of
                          {ok, JObj1} ->
                              ?PVT_TYPE = wh_json:get_value(<<"pvt_type">>, JObj1),
                              ?LOG_SYS("opened ~s in ~s", [DbName, AccountId]),
                              
                              couch_mgr:db_delete(DbName),
                              
                              #cb_context{resp_status=success} = crossbar_doc:delete(Context#cb_context{db_name=DbName
                                                                                                        ,doc=JObj1
                                                                                                       }),
                              ?LOG_SYS("deleted ~s in ~s", [DbName, AccountId]);
                          _ -> ok
                      end,
                      case couch_mgr:open_doc(?WH_ACCOUNTS_DB, AccountId) of
                          {ok, JObj2} ->
                              crossbar_doc:delete(Context#cb_context{db_name=?WH_ACCOUNTS_DB
                                                                     ,doc=JObj2
                                                                    });
                          _ -> ok
                      end,
                      Pid ! {binding_result, true, [RD, Context, Params]}
                  catch
                      _:_E ->
                          ?LOG_SYS("Exception while deleting account: ~p", [_E]),
                          Pid ! {binding_result, true, [RD, crossbar_util:response_bad_identifier(AccountId, Context), Params]}
                  end
          end),
    {noreply, State};

handle_info({binding_fired, Pid, _, Payload}, State) ->
    Pid ! {binding_result, false, Payload},
    {noreply, State};

handle_info({binding_flushed, Binding}, State) ->
    ?LOG("Lost binding ~s, wait and rebind", [Binding]),
    erlang:send_after(100, self(), {rebind, Binding}),
    {noreply, State};

handle_info({rebind, all}, State) ->
    _ = bind_to_crossbar(),
    {noreply, State};

handle_info({rebind, Binding}, State) ->
    ?LOG("Rebinding ~s", [Binding]),
    _ = crossbar_bindings:bind(Binding),
    {noreply, State};

handle_info(_Info, State) ->
    ?LOG("Unhandled message: ~p", [_Info]),
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
    _ = crossbar_bindings:bind(<<"v1_resource.allowed_methods.accounts">>),
    _ = crossbar_bindings:bind(<<"v1_resource.resource_exists.accounts">>),
    _ = crossbar_bindings:bind(<<"v1_resource.validate.accounts">>),
    crossbar_bindings:bind(<<"v1_resource.execute.#.accounts">>).

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
    {true, ['GET', 'PUT', 'POST', 'DELETE']};
allowed_methods([_, <<"parent">>]) ->
    {true, ['GET', 'POST', 'DELETE']};
allowed_methods([_, Path]) ->
    Valid = lists:member(Path, [<<"ancestors">>, <<"children">>, <<"descendants">>, <<"siblings">>]),
    {Valid, ['GET']};
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
resource_exists([_, Path]) ->
    Valid = lists:member(Path, [<<"parent">>, <<"ancestors">>, <<"children">>, <<"descendants">>, <<"siblings">>]),
    {Valid, []};
resource_exists(_T) ->
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
    load_account_summary([], Context);
validate([], #cb_context{req_verb = <<"put">>}=Context) ->
    create_account(Context);
validate([ParentId], #cb_context{req_verb = <<"put">>}=Context) ->
    create_account(Context, ParentId);
validate([AccountId], #cb_context{req_verb = <<"get">>}=Context) ->
    load_account(AccountId, Context);
validate([AccountId], #cb_context{req_verb = <<"post">>}=Context) ->
    update_account(AccountId, Context);
validate([AccountId], #cb_context{req_verb = <<"delete">>}=Context) ->
    load_account(AccountId, Context);
validate([AccountId, <<"parent">>], #cb_context{req_verb = <<"get">>}=Context) ->
    load_parent(AccountId, Context);
validate([AccountId, <<"parent">>], #cb_context{req_verb = <<"post">>}=Context) ->
    update_parent(AccountId, Context);
validate([AccountId, <<"parent">>], #cb_context{req_verb = <<"delete">>}=Context) ->
    load_account(AccountId, Context);
validate([AccountId, <<"children">>], #cb_context{req_verb = <<"get">>}=Context) ->
    load_children(AccountId, Context);
validate([AccountId, <<"descendants">>], #cb_context{req_verb = <<"get">>}=Context) ->
    load_descendants(AccountId, Context);
validate([AccountId, <<"siblings">>], #cb_context{req_verb = <<"get">>}=Context) ->
    load_siblings(AccountId, Context);
validate(_, Context) ->
    crossbar_util:response_faulty_request(Context).

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Attempt to load list of accounts, each summarized.  Or a specific
%% account summary.
%% @end
%%--------------------------------------------------------------------
-spec load_account_summary/2 :: (ne_binary() | [], #cb_context{}) -> #cb_context{}.
load_account_summary([], Context) ->
    crossbar_doc:load_view(?AGG_VIEW_SUMMARY, [], Context, fun normalize_view_results/2);
load_account_summary(AccountId, Context) ->
    crossbar_doc:load_view(?AGG_VIEW_SUMMARY, [
                                               {<<"startkey">>, [AccountId]}
                                               ,{<<"endkey">>, [AccountId, wh_json:new()]}
                                              ], Context, fun normalize_view_results/2).

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Create a new account document with the data provided, if it is valid
%% @end
%%--------------------------------------------------------------------
-spec create_account/1 :: (#cb_context{}) -> #cb_context{}.
-spec create_account/2 :: (#cb_context{}, 'undefined' | ne_binary()) -> #cb_context{}.
create_account(Context) ->
    P = case whapps_config:get(?CONFIG_CAT, <<"default_parent">>) of
            undefined ->
                case couch_mgr:get_results(?WH_ACCOUNTS_DB, ?AGG_VIEW_SUMMARY, [{<<"include_docs">>, true}]) of
                    {ok, [_|_]=AcctJObjs} ->
                        ParentId = find_default_parent(AcctJObjs),
                        whapps_config:set(?CONFIG_CAT, <<"default_parent">>, ParentId),
                        ParentId;
                    _ -> undefined
                end;
            ParentId -> 
                ParentId
        end,
    create_account(Context, P).

create_account(#cb_context{req_data=Data}=Context, ParentId) ->
    UniqueRealm = is_unique_realm(undefined, Context),
    case wh_json_validator:is_valid(Data, ?WH_ACCOUNTS_DB) of
        {fail, Errors} when UniqueRealm ->
            crossbar_util:response_invalid_data(Errors, Context);
        {fail, Errors} ->
            E = wh_json:set_value([<<"realm">>, <<"unique">>], <<"Realm is not unique for this system">>, Errors),
            crossbar_util:response_invalid_data(E, Context);
        {pass, _} when not UniqueRealm ->
            E = wh_json:set_value([<<"realm">>, <<"unique">>], <<"Realm is not unique for this system">>, wh_json:new()),
            crossbar_util:response_invalid_data(E, Context);
        {pass, JObj} ->
            Context#cb_context{
              doc=set_private_fields(JObj, Context, ParentId)
              ,resp_status=success
             }
    end.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Load an account document from the database
%% @end
%%--------------------------------------------------------------------
-spec load_account/2 :: (ne_binary(), #cb_context{}) -> #cb_context{}.
load_account(AccountId, Context) ->
    crossbar_doc:load(AccountId, Context).

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Update an existing account document with the data provided, if it is
%% valid
%% @end
%%--------------------------------------------------------------------
-spec update_account/2 :: (ne_binary(), #cb_context{}) -> #cb_context{}.
update_account(AccountId, #cb_context{req_data=Data}=Context) ->
    UniqueRealm = is_unique_realm(AccountId, Context),
    case wh_json_validator:is_valid(Data, ?WH_ACCOUNTS_DB) of
        {fail, Errors} when UniqueRealm ->
            crossbar_util:response_invalid_data(Errors, Context);
        {fail, Errors} ->
            E = wh_json:set_value([<<"realm">>, <<"unique">>], <<"Realm is not unique for this system">>, Errors),
            crossbar_util:response_invalid_data(E, Context);
        {pass, _} when not UniqueRealm ->
            E = wh_json:set_value([<<"realm">>, <<"unique">>], <<"Realm is not unique for this system">>, wh_json:new()),
            crossbar_util:response_invalid_data(E, Context);
        {pass, JObj} ->
            crossbar_doc:load_merge(AccountId, JObj, Context)
    end.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Attempt to load a summary of the parent of the account
%% @end
%%--------------------------------------------------------------------
-spec load_parent/2 :: (ne_binary(), #cb_context{}) -> #cb_context{}.
load_parent(AccountId, Context) ->
    case crossbar_doc:load_view(?AGG_VIEW_PARENT, [{<<"startkey">>, AccountId}
                                                   ,{<<"endkey">>, AccountId}
                                                  ], Context) of
        #cb_context{resp_status=success, doc=[JObj|_]} ->
            Parent = wh_json:get_value([<<"value">>, <<"id">>], JObj),
            load_account_summary(Parent, Context);
        _Else ->
            crossbar_util:response_bad_identifier(AccountId, Context)
    end.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Update the tree with a new parent, cascading when necessary, if the
%% new parent is valid
%% @end
%%--------------------------------------------------------------------
-spec update_parent/2 :: (ne_binary(), #cb_context{}) -> #cb_context{}.
update_parent(AccountId, #cb_context{req_data=Data}=Context) ->
    case is_valid_parent(Data) of
        %% {false, Fields} ->
        %%     crossbar_util:response_invalid_data(Fields, Context);
        {true, []} ->
            %% OMGBBQ! NO CHECKS FOR CYCLIC REFERENCES WATCH OUT!
            ParentId = wh_json:get_value(<<"parent">>, Data),
            update_tree(AccountId, ParentId, Context)
    end.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Load a summary of the children of this account
%% @end
%%--------------------------------------------------------------------
-spec load_children/2 :: (ne_binary(), #cb_context{}) -> #cb_context{}.
load_children(AccountId, Context) ->
    crossbar_doc:load_view(?AGG_VIEW_CHILDREN, [{<<"startkey">>, [AccountId]}
                                                ,{<<"endkey">>, [AccountId, wh_json:new()]}
                                               ], Context, fun normalize_view_results/2).

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Load a summary of the descendants of this account
%% @end
%%--------------------------------------------------------------------
-spec load_descendants/2 :: (ne_binary(), #cb_context{}) -> #cb_context{}.
load_descendants(AccountId, Context) ->
    crossbar_doc:load_view(?AGG_VIEW_DESCENDANTS, [{<<"startkey">>, [AccountId]}
                                                   ,{<<"endkey">>, [AccountId, wh_json:new()]}
                                                  ], Context, fun normalize_view_results/2).

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Load a summary of the siblngs of this account
%% @end
%%--------------------------------------------------------------------
-spec load_siblings/2 :: (ne_binary(), #cb_context{}) -> #cb_context{}.
load_siblings(AccountId, Context) ->
    case crossbar_doc:load_view(?AGG_VIEW_PARENT, [{<<"startkey">>, AccountId}
                                                   ,{<<"endkey">>, AccountId}
                                                  ], Context) of
        #cb_context{resp_status=success, doc=[JObj|_]} ->
            Parent = wh_json:get_value([<<"value">>, <<"id">>], JObj),
            load_children(Parent, Context);
        _Else ->
            crossbar_util:response_bad_identifier(AccountId, Context)
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
%%
%% @end
%%--------------------------------------------------------------------
-spec is_valid_parent/1 :: (json_object()) -> {'true', []}.
is_valid_parent(_JObj) ->
    {true, []}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Updates AccountID's parent's tree with the AccountID as a descendant
%% @end
%%--------------------------------------------------------------------
-spec update_tree/3 :: (ne_binary(), ne_binary() | 'undefined', #cb_context{}) -> #cb_context{}.
update_tree(_AccountId, undefined, Context) ->
    ?LOG("Parent ID is undefined"),
    Context;
update_tree(AccountId, ParentId, Context) ->
    case crossbar_doc:load(ParentId, Context) of
        #cb_context{resp_status=success, doc=Parent} ->
            case load_descendants(AccountId, Context) of
                #cb_context{resp_status=success, doc=[]} ->
                    crossbar_util:response_bad_identifier(AccountId, Context);
                #cb_context{resp_status=success, doc=DescDocs}=Context1 when is_list(DescDocs) ->
                    Tree = wh_json:get_value(<<"pvt_tree">>, Parent, []) ++ [ParentId, AccountId],
                    Updater = fun(Desc, Acc) -> update_doc_tree(Tree, Desc, Acc) end,
                    Updates = lists:foldr(Updater, [], DescDocs),
                    Context1#cb_context{doc=Updates};
                Context1 -> Context1
            end;
        Else ->
            Else
    end.

%%--------------------------------------------------------------------
%% @private
%% @doc
%%
%% @end
%%--------------------------------------------------------------------
-spec update_doc_tree/3 :: ([ne_binary(),...], json_object(), json_objects()) -> json_objects().
update_doc_tree([_|_]=ParentTree, JObj, Acc) ->
    AccountId = wh_json:get_value(<<"id">>, JObj),
    ParentId = lists:last(ParentTree),
    case crossbar_doc:load(AccountId, #cb_context{db_name=?WH_ACCOUNTS_DB}) of
        #cb_context{resp_status=success, doc=Doc} ->
            MyTree =
                case lists:dropwhile(fun(E)-> E =/= ParentId end, wh_json:get_value(<<"pvt_tree">>, Doc, [])) of
                    [] -> ParentTree;
                    [_|List] -> ParentTree ++ List
                end,
            Trimmed = [E || E <- MyTree, E =/= AccountId],
            [wh_json:set_value(<<"pvt_tree">>, Trimmed, Doc) | Acc];
        _Else ->
            Acc
    end.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% This function returns the private fields to be added to a new account
%% document
%% @end
%%--------------------------------------------------------------------
-spec set_private_fields/3 :: (json_object(), #cb_context{}, 'undefined' | ne_binary()) -> json_object().
set_private_fields(JObj0, Context, undefined) ->
    lists:foldl(fun(Fun, JObj1) ->
                        Fun(JObj1, Context)
                end, JObj0, [fun add_pvt_type/2, fun add_pvt_api_key/2, fun add_pvt_tree/2]);
set_private_fields(JObj0, Context, ParentId) ->
    case is_binary(ParentId) andalso couch_mgr:open_doc(wh_util:format_account_id(ParentId, encoded), ParentId) of
        {ok, ParentJObj} ->
            Tree = wh_json:get_value(<<"pvt_tree">>, ParentJObj, []) ++ [ParentId],
            Enabled = wh_json:is_false(<<"pvt_enabled">>, ParentJObj) =/= true,
            AddPvtTree = fun(JObj, _) -> wh_json:set_value(<<"pvt_tree">>, Tree, JObj) end,
            AddPvtEnabled = fun(JObj, _) -> wh_json:set_value(<<"pvt_enabled">>, Enabled, JObj) end,
            lists:foldl(fun(Fun, JObj1) ->
                                Fun(JObj1, Context)
                        end, JObj0, [fun add_pvt_type/2, fun add_pvt_api_key/2, AddPvtTree, AddPvtEnabled]);
        false ->
            set_private_fields(JObj0, Context, undefined);
        _ ->
            set_private_fields(JObj0, Context, undefined)
    end.

add_pvt_type(JObj, _) ->
    wh_json:set_value(<<"pvt_type">>, ?PVT_TYPE, JObj).

add_pvt_api_key(JObj, _) ->
    wh_json:set_value(<<"pvt_api_key">>, wh_util:to_binary(wh_util:to_hex(crypto:rand_bytes(32))), JObj).

add_pvt_tree(JObj, #cb_context{auth_doc=undefined}) ->
    case whapps_config:get(?CONFIG_CAT, <<"default_parent">>) of
        undefined ->
            ?LOG("there really should be a parent unless this is the first ever account"),
            wh_json:set_value(<<"pvt_tree">>, [], JObj);
        ParentId ->
            ?LOG("setting tree to [~s]", [ParentId]),
            wh_json:set_value(<<"pvt_tree">>, [ParentId], JObj)
    end;
add_pvt_tree(JObj, #cb_context{auth_doc=Token}) ->
    AuthAccId = wh_json:get_value(<<"account_id">>, Token),
    case is_binary(AuthAccId) andalso couch_mgr:open_doc(wh_util:format_account_id(AuthAccId, encoded), AuthAccId) of
        {ok, AuthJObj} ->
            Tree = wh_json:get_value(<<"pvt_tree">>, AuthJObj, []) ++ [AuthAccId],
            Enabled = wh_json:is_false(<<"pvt_enabled">>, AuthJObj) =/= true,
            ?LOG("setting parent tree to ~p", [Tree]),
            ?LOG("setting initial pvt_enabled to ~s", [Enabled]),
            wh_json:set_value(<<"pvt_tree">>, Tree
                              ,wh_json:set_value(<<"pvt_enabled">>, Enabled, JObj));
        false ->
            add_pvt_tree(JObj, #cb_context{auth_doc=undefined});
        _ ->
            ?LOG("setting parent tree to [~s]", [AuthAccId]),
            wh_json:set_value(<<"pvt_tree">>, [AuthAccId]
                              ,wh_json:set_value(<<"pvt_enabled">>, false, JObj))
    end.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% This function will attempt to load the context with the db name of
%% for this account
%% @end
%%--------------------------------------------------------------------
-spec load_account_db/2 :: (ne_binary() | [ne_binary(),...], #cb_context{}) -> #cb_context{}.
load_account_db([AccountId|_], Context) ->
    load_account_db(AccountId, Context);
load_account_db(AccountId, Context) when is_binary(AccountId) ->
    {ok, Srv} = crossbar_sup:cache_proc(),
    AccountDb = wh_util:format_account_id(AccountId, encoded),
    ?LOG_SYS("account determined that db name: ~s", [AccountDb]),
    case wh_cache:peek_local(Srv, {crossbar, exists, AccountId}) of
        {ok, true} -> 
            ?LOG("check succeeded for db_exists on ~s", [AccountId]),
            Context#cb_context{db_name = AccountDb
                               ,account_id = AccountId
                              };
        _ ->
            case couch_mgr:db_exists(AccountDb) of
                false ->
                    ?LOG("check failed for db_exists on ~s", [AccountId]),
                    crossbar_util:response_db_missing(Context);
                true ->
                    wh_cache:store_local(Srv, {crossbar, exists, AccountId}, true, ?CACHE_TTL),
                    ?LOG("check succeeded for db_exists on ~s", [AccountId]),
                    Context#cb_context{db_name = AccountDb
                                       ,account_id = AccountId
                                      }
            end
    end.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% This function will create a new account and corresponding database
%% then spawn a short initial function
%% @end
%%--------------------------------------------------------------------
-spec create_new_account_db/1 :: (#cb_context{}) -> #cb_context{}.
create_new_account_db(#cb_context{doc=Doc}=Context) ->
    AccountId = wh_json:get_value(<<"_id">>, Doc, couch_mgr:get_uuid()),
    AccountDb = wh_util:format_account_id(AccountId, encoded),
    case couch_mgr:db_exists(?WH_ACCOUNTS_DB) of
        true -> ok;
        false ->
            couch_mgr:db_create(?WH_ACCOUNTS_DB),
            couch_mgr:revise_doc_from_file(?WH_ACCOUNTS_DB, crossbar, ?ACCOUNTS_AGG_VIEW_FILE),
            couch_mgr:revise_doc_from_file(?WH_ACCOUNTS_DB, crossbar, ?MAINTENANCE_VIEW_FILE)
    end,
    case couch_mgr:db_create(AccountDb) of
        false ->
            ?LOG_SYS("Failed to create database: ~s", [AccountDb]),
            crossbar_util:response_db_fatal(Context);
        true ->
            ?LOG_SYS("Created DB for account id ~s", [AccountId]),
            JObj = wh_json:set_value(<<"_id">>, AccountId, Doc),
            case crossbar_doc:save(Context#cb_context{db_name=AccountDb, account_id=AccountId, doc=JObj}) of
                #cb_context{resp_status=success}=Context1 ->
                    _ = crossbar_bindings:map(<<"account.created">>, Context1),
                    couch_mgr:revise_docs_from_folder(AccountDb, crossbar, "account", false),
                    couch_mgr:revise_doc_from_file(AccountDb, crossbar, ?MAINTENANCE_VIEW_FILE),
                    %% This view should be added by the callflow whapp but until refresh requests are made
                    %% via AMQP we need to do it here
                    couch_mgr:revise_views_from_folder(AccountDb, callflow),
                    _ = crossbar_doc:ensure_saved(Context1#cb_context{db_name=?WH_ACCOUNTS_DB, doc=JObj}),

                    Credit = whapps_config:get(<<"crossbar.accounts">>, <<"starting_credit">>, 0.0),
                    Units = wapi_money:dollars_to_units(wh_util:to_float(Credit)),
                    ?LOG("Putting ~p units", [Units]),
                    Transaction = wh_json:from_list([{<<"amount">>, Units}
                                                     ,{<<"pvt_type">>, <<"credit">>}
                                                     ,{<<"pvt_description">>, <<"initial account balance">>}
                                                    ]),
                    
                    case crossbar_doc:save(Context#cb_context{doc=Transaction, db_name=AccountDb}) of
                        #cb_context{resp_status=success} -> ok;
                        #cb_context{resp_error_msg=Err} -> ?LOG("failed to save credit doc: ~p", [Err])
                    end,

                    Context1;
                Else ->
                    ?LOG_SYS("Other PUT resp: ~s: ~p~n", [Else#cb_context.resp_status, Else#cb_context.doc]),
                    Else
            end
    end.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% This function will determine if the realm in the request is
%% unique or belongs to the request being made
%% @end
%%--------------------------------------------------------------------
-spec is_unique_realm/2 :: (ne_binary() | 'undefined', #cb_context{}) -> boolean().
is_unique_realm(AccountId, #cb_context{req_data=JObj}=Context) ->
    is_unique_realm(AccountId, Context, wh_json:get_value(<<"realm">>, JObj)).

is_unique_realm(_, _, undefined) -> 
    ?LOG("invalid or non-unique realm: undefined"),
    false;
is_unique_realm(undefined, _, Realm) ->
    %% unique if Realm doesn't exist in agg DB
    case couch_mgr:get_results(?WH_ACCOUNTS_DB, ?AGG_VIEW_REALM, [{<<"key">>, Realm}]) of
        {ok, []} -> 
            ?LOG("realm ~s is valid and unique", [Realm]),
            true;
        {ok, [_|_]} -> 
            ?LOG("invalid or non-unique realm: ~s", [Realm]),
            false
    end;

is_unique_realm(AccountId, Context, Realm) ->
    {ok, Doc} = couch_mgr:open_doc(?WH_ACCOUNTS_DB, AccountId),
    %% Unique if, for this account, request and account's realm are same
    %% or request Realm doesn't exist in DB (cf is_unique_realm(undefined ...)
    case wh_json:get_value(<<"realm">>, Doc) of
        Realm -> 
            ?LOG("realm ~s is valid and unique", [Realm]),
            true;
        _ -> 
            is_unique_realm(undefined, Context, Realm)
    end.

%% for testing purpose, don't forget to export !
%% is_unique_realm({AccountId, Realm}) -> is_unique_realm(AccountId, #cb_context{}, Realm).
