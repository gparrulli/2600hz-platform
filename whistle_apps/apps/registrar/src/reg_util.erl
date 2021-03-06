%%%-------------------------------------------------------------------
%%% @author James Aimonetti <james@2600hz.org>
%%% @copyright (C) 2011, VoIP INC
%%% @doc
%%% Shared functions
%%% @end
%%% Created : 19 Aug 2011 by James Aimonetti <james@2600hz.org>
%%%-------------------------------------------------------------------
-module(reg_util).

-export([lookup_auth_user/2]).
-export([cache_reg_key/1, cache_user_to_reg_key/2, cache_user_key/2]).
-export([hash_contact/1, get_expires/1]).
-export([lookup_registrations/1, lookup_registration/2, fetch_all_registrations/0]).
-include("reg.hrl").

cache_reg_key(Id) -> {?MODULE, registration, Id}.
cache_user_to_reg_key(Realm, User) -> {?MODULE, registration, Realm, User}.
cache_user_key(Realm, User) -> {?MODULE, sip_credentials, Realm, User}.

%%-----------------------------------------------------------------------------
%% @public
%% @doc
%% look up a cached registration by realm and optionally username
%% @end
%%-----------------------------------------------------------------------------
-spec lookup_registrations/1 :: (ne_binary()) -> {'ok', json_objects()}.
lookup_registrations(Realm) when not is_binary(Realm) ->
    lookup_registrations(wh_util:to_binary(Realm));
lookup_registrations(Realm) ->
    {ok, Cache} = registrar_sup:cache_proc(),
    Registrations = wh_cache:filter_local(Cache, fun({?MODULE, registration, Realm1, _}, _) when Realm =:= Realm1 ->
                                                 true;
                                            (_K, _V) ->
                                                 false
                                         end),
    {'ok', Registrations}.

-spec lookup_registration/2 :: (ne_binary(), ne_binary()) -> {'ok', json_object()} | {'error', 'not_found'}.
lookup_registration(Realm, Username) when not is_binary(Realm) ->
    lookup_registration(wh_util:to_binary(Realm), Username);
lookup_registration(Realm, Username) when not is_binary(Username) ->
    lookup_registration(Realm, wh_util:to_binary(Username));
lookup_registration(Realm, Username) ->
    {ok, Cache} = registrar_sup:cache_proc(),
    wh_cache:peek_local(Cache, cache_user_to_reg_key(Realm, Username)).

%%-----------------------------------------------------------------------------
%% @public
%% @doc
%% get a complete list of registrations in the cache
%% @end
%%-----------------------------------------------------------------------------
-spec fetch_all_registrations/0 :: () -> {'ok', json_objects()}.
fetch_all_registrations() ->
    {ok, Cache} = registrar_sup:cache_proc(),
    Registrations = wh_cache:filter_local(Cache, fun({?MODULE, registration, _, _}, _) ->
                                                 true;
                                            (_K, _V) ->
                                                 false
                                         end),
    {'ok', Registrations}.

%%-----------------------------------------------------------------------------
%% @public
%% @doc
%% calculate expiration time
%% @end
%%-----------------------------------------------------------------------------
-spec get_expires/1 :: (ne_binary()) -> binary().
get_expires(JObj) ->
    Multiplier = whapps_config:get_float(?CONFIG_CAT, <<"expires_multiplier">>, 1.25),
    Fudge = whapps_config:get_float(?CONFIG_CAT, <<"expires_fudge_factor">>, 120),
    Expiry = wh_json:get_integer_value(<<"Expires">>, JObj, 3600),
    round(Expiry * Multiplier) + Fudge.

%%-----------------------------------------------------------------------------
%% @public
%% @doc
%% hash a registration contact string
%% @end
%%-----------------------------------------------------------------------------
-spec hash_contact/1 :: (ne_binary()) -> binary().
hash_contact(Contact) ->
    wh_util:to_binary(wh_util:to_hex(erlang:md5(Contact))).

%%-----------------------------------------------------------------------------
%% @private
%% @doc
%% look up the user and realm in the database and return the result
%% @end
%%-----------------------------------------------------------------------------
-spec lookup_auth_user/2 :: (ne_binary(), ne_binary()) -> {'ok', json_object()} | {'error', 'not_found'}.
lookup_auth_user(Name, Realm) ->
    ?LOG("looking up auth creds for ~s@~s", [Name, Realm]),
    {ok, Cache} = registrar_sup:cache_proc(),
    CacheKey = cache_user_key(Realm, Name),
    case wh_cache:fetch_local(Cache, CacheKey) of
        {'error', not_found} ->
            case get_auth_user(Name, Realm) of
                {'ok', UserJObj} ->
                    case wh_util:is_account_enabled(wh_json:get_value([<<"doc">>, <<"pvt_account_id">>], UserJObj)) of
                        true -> 
                            CacheTTL = whapps_config:get_integer(?CONFIG_CAT, <<"credentials_cache_ttl">>, 300),
                            ?LOG("storing ~s@~s in cache", [Name, Realm]),
                            wh_cache:store_local(Cache, CacheKey, UserJObj, CacheTTL),
                            {'ok', UserJObj};
                        false -> 
                            {error, not_found}
                    end;
                {error, _}=E ->
                    E
            end;
        {'ok', UserJObj}=OK ->
            case wh_util:is_account_enabled(wh_json:get_value([<<"doc">>, <<"pvt_account_id">>], UserJObj)) of
                true -> 
                    ?LOG("pulling auth user from cache"),
                    OK;      
                false -> 
                    {error, not_found}
            end
    end.

-spec get_auth_user/2 :: (ne_binary(), ne_binary()) -> {'ok', json_object()} | {'error', 'not_found'}.
get_auth_user(Name, Realm) ->
    case whapps_util:get_account_by_realm(Realm) of
        {'error', E} ->
            ?LOG("failed to lookup realm ~s in accounts: ~p", [Realm, E]),
            get_auth_user_in_agg(Name, Realm);
        {'ok', []} ->
            ?LOG("failed to find realm ~s in accounts", [Realm]),
            get_auth_user_in_agg(Name, Realm);
        {'ok', AccountDB} ->
            get_auth_user_in_account(Name, Realm, AccountDB)
    end.

-spec get_auth_user_in_agg/2 :: (ne_binary(), ne_binary()) -> {'ok', json_object()} | {'error', 'not_found'}.
get_auth_user_in_agg(Name, Realm) ->
    UseAggregate = whapps_config:get_is_true(?CONFIG_CAT, <<"use_aggregate">>, false),
    ViewOptions = [{<<"key">>, [Realm, Name]}, {<<"include_docs">>, true}],
    case UseAggregate andalso couch_mgr:get_results(?WH_SIP_DB, <<"credentials/lookup">>, ViewOptions) of
        false ->
            ?LOG_END("SIP credential aggregate db is disabled"),
            {'error', 'not_found'};            
        {'error', R} ->
            ?LOG_END("failed to look up SIP credentials ~p in aggregate", [R]),
            {'error', 'not_found'};
        {'ok', []} ->
            ?LOG("~s@~s not found in aggregate", [Name, Realm]),
            {'error', 'not_found'};
        {'ok', [User|_]} ->
            ?LOG("~s@~s found in aggregate", [Name, Realm]),
            {'ok', User}
    end.

-spec get_auth_user_in_account/3 :: (ne_binary(), ne_binary(), ne_binary()) -> {'ok', json_object()} | {'error', 'not_found'}.
get_auth_user_in_account(Name, Realm, AccountDB) ->
    case couch_mgr:get_results(AccountDB, <<"devices/sip_credentials">>, [{<<"key">>, Name}, {<<"include_docs">>, true}]) of
        {'error', R} ->
            ?LOG("failed to look up SIP credentials in ~s: ~p", [AccountDB, R]),
            get_auth_user_in_agg(Name, Realm);
        {'ok', []} ->
            ?LOG("~s@~s not found in ~s", [Name, Realm, AccountDB]),
            get_auth_user_in_agg(Name, Realm);
        {'ok', [User|_]} ->
            ?LOG("~s@~s found in account db: ~s", [Name, Realm, AccountDB]),
            {'ok', User}
    end.
