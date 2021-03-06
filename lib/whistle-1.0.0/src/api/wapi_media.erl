%%%-------------------------------------------------------------------
%%% @author James Aimonetti <james@2600hz.org>
%%% @copyright (C) 2011, VoIP INC
%%% @doc
%%% Media requests, responses, and errors
%%% @end
%%% Created : 17 Oct 2011 by James Aimonetti <james@2600hz.org>
%%%-------------------------------------------------------------------
-module(wapi_media).

-compile({no_auto_import, [error/1]}).

-export([req/1, resp/1, error/1, req_v/1, resp_v/1, error_v/1]).

-export([bind_q/2, unbind_q/1]).

-export([publish_req/1, publish_req/2, publish_resp/2, publish_resp/3
	 ,publish_error/2, publish_error/3]).

-include("../wh_api.hrl").

%% Media Request - when streaming is needed
-define(MEDIA_REQ_HEADERS, [<<"Media-Name">>]).
-define(OPTIONAL_MEDIA_REQ_HEADERS, [<<"Stream-Type">>, <<"Call-ID">>]).
-define(MEDIA_REQ_VALUES, [{<<"Event-Category">>, <<"media">>}
			   ,{<<"Event-Name">>, <<"media_req">>}
			   ,{<<"Stream-Type">>, [<<"new">>, <<"extant">>]}
			  ]).
-define(MEDIA_REQ_TYPES, []).

%% Media Response
-define(MEDIA_RESP_HEADERS, [<<"Media-Name">>, <<"Stream-URL">>]).
-define(OPTIONAL_MEDIA_RESP_HEADERS, []).
-define(MEDIA_RESP_VALUES, [{<<"Event-Category">>, <<"media">>}
			   ,{<<"Event-Name">>, <<"media_resp">>}
			  ]).
-define(MEDIA_RESP_TYPES, [{<<"Stream-URL">>, fun(<<"shout://", _/binary>>) -> true;
                                                 (<<"http://", _/binary>>) -> true;
                                                 (_) -> false end}]).

%% Media Error
-define(MEDIA_ERROR_HEADERS, [<<"Media-Name">>, <<"Error-Code">>]).
-define(OPTIONAL_MEDIA_ERROR_HEADERS, [<<"Error-Msg">>]).
-define(MEDIA_ERROR_VALUES, [{<<"Event-Category">>, <<"media">>}
			     ,{<<"Event-Name">>, <<"media_error">>}
			     ,{<<"Error-Code">>, [<<"not_found">>, <<"no_data">>, <<"other">>]}
			    ]).
-define(MEDIA_ERROR_TYPES, []).

%%--------------------------------------------------------------------
%% @doc Request media - see wiki
%% Takes proplist, creates JSON string or error
%% @end
%%--------------------------------------------------------------------
-spec req/1 :: (json_object() | proplist()) -> {'ok', iolist()} | {'error', string()}.
req(Prop) when is_list(Prop) ->
    case req_v(Prop) of
	true -> wh_api:build_message(Prop, ?MEDIA_REQ_HEADERS, ?OPTIONAL_MEDIA_REQ_HEADERS);
	false -> {error, "Proplist failed validation for media_req"}
    end;
req(JObj) ->
    req(wh_json:to_proplist(JObj)).

-spec req_v/1 :: (json_object() | proplist()) -> boolean().
req_v(Prop) when is_list(Prop) ->
    wh_api:validate(Prop, ?MEDIA_REQ_HEADERS, ?MEDIA_REQ_VALUES, ?MEDIA_REQ_TYPES);
req_v(JObj) ->
    req_v(wh_json:to_proplist(JObj)).

%%--------------------------------------------------------------------
%% @doc Response with media - see wiki
%% Takes proplist, creates JSON string or error
%% @end
%%--------------------------------------------------------------------
-spec resp/1 :: (json_object() | proplist()) -> {'ok', iolist()} | {'error', string()}.
resp(Prop) when is_list(Prop) ->
    case resp_v(Prop) of
	true -> wh_api:build_message(Prop, ?MEDIA_RESP_HEADERS, ?OPTIONAL_MEDIA_RESP_HEADERS);
	false -> {error, "Proplist failed validation for media_resp"}
    end;
resp(JObj) ->
    resp(wh_json:to_proplist(JObj)).

-spec resp_v/1 :: (proplist() | json_object()) -> boolean().
resp_v(Prop) when is_list(Prop) ->
    wh_api:validate(Prop, ?MEDIA_RESP_HEADERS, ?MEDIA_RESP_VALUES, ?MEDIA_RESP_TYPES);
resp_v(JObj) ->
    resp_v(wh_json:to_proplist(JObj)).

%%--------------------------------------------------------------------
%% @doc Media error - see wiki
%% Takes proplist, creates JSON string or error
%% @end
%%--------------------------------------------------------------------
-spec error/1 :: (proplist() | json_object()) -> {'ok', iolist()} | {'error', string()}.
error(Prop) when is_list(Prop) ->
    case error_v(Prop) of
	true -> wh_api:build_message(Prop, ?MEDIA_ERROR_HEADERS, ?OPTIONAL_MEDIA_ERROR_HEADERS);
	false -> {error, "Proplist failed validation for media_error"}
    end;
error(JObj) ->
    error(wh_json:to_proplist(JObj)).

-spec error_v/1 :: (proplist() | json_object()) -> boolean().
error_v(Prop) when is_list(Prop) ->
    wh_api:validate(Prop, ?MEDIA_ERROR_HEADERS, ?MEDIA_ERROR_VALUES, ?MEDIA_ERROR_TYPES);
error_v(JObj) ->
    error_v(wh_json:to_proplist(JObj)).

-spec bind_q/2 :: (binary(), proplist()) -> 'ok'.
bind_q(Queue, _Props) ->
    amqp_util:callevt_exchange(),
    amqp_util:bind_q_to_callevt(Queue, media_req),
    ok.

-spec unbind_q/1 :: (binary()) -> 'ok'.
unbind_q(Queue) ->
    amqp_util:unbind_q_from_callevt(Queue).

-spec publish_req/1 :: (api_terms()) -> 'ok'.
-spec publish_req/2 :: (api_terms(), ne_binary()) -> 'ok'.
publish_req(JObj) ->
    publish_req(JObj, ?DEFAULT_CONTENT_TYPE).
publish_req(Req, ContentType) ->
    {ok, Payload} = wh_api:prepare_api_payload(Req, ?MEDIA_REQ_VALUES, fun ?MODULE:req/1),
    amqp_util:callevt_publish(Payload, ContentType, media_req).

-spec publish_resp/2 :: (ne_binary(), api_terms()) -> 'ok'.
-spec publish_resp/3 :: (ne_binary(), api_terms(), ne_binary()) -> 'ok'.
publish_resp(Queue, JObj) ->
    publish_resp(Queue, JObj, ?DEFAULT_CONTENT_TYPE).
publish_resp(Queue, Resp, ContentType) ->
    {ok, Payload} = wh_api:prepare_api_payload(Resp, ?MEDIA_RESP_VALUES, fun ?MODULE:resp/1),
    amqp_util:targeted_publish(Queue, Payload, ContentType).

-spec publish_error/2 :: (ne_binary(), api_terms()) -> 'ok'.
-spec publish_error/3 :: (ne_binary(), api_terms(), ne_binary()) -> 'ok'.
publish_error(Queue, JObj) ->
    publish_error(Queue, JObj, ?DEFAULT_CONTENT_TYPE).
publish_error(Queue, Error, ContentType) ->
    {ok, Payload} = wh_api:prepare_api_payload(Error, ?MEDIA_ERROR_VALUES, fun ?MODULE:error/1),
    amqp_util:targeted_publish(Queue, Payload, ContentType).
