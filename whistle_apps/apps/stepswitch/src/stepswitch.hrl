-include_lib("whistle/include/wh_types.hrl").
-include_lib("whistle/include/wh_amqp.hrl").
-include_lib("whistle/include/wh_log.hrl").
-include_lib("whistle/include/wh_databases.hrl").
-include_lib("amqp_client/include/amqp_client.hrl").

-define(ROUTES_DB, <<"offnet">>).
-define(LIST_ROUTES_BY_NUMBER, {<<"routes">>, <<"listing_by_number">>}).
-define(LIST_ROUTE_DUPS, {<<"routes">>, <<"listing_by_assignment">>}).
-define(LIST_ROUTE_ACCOUNTS, {<<"routes">>, <<"listing_by_account">>}).

-define(RESOURCES_DB, <<"offnet">>).
-define(LIST_RESOURCES_BY_ID, {<<"resources">>, <<"listing_by_id">>}).

-define(APP_NAME, <<"stepswitch">>).
-define(APP_VERSION, <<"0.2.0">>).

-record(gateway, {
           resource_id = 'undefined'
          ,server = 'undefined'
          ,realm = 'undefined'
          ,username = 'undefined'
          ,password = 'undefined'
          ,route = whapps_config:get_binary(<<"stepswitch">>, <<"default_route">>)
          ,prefix = whapps_config:get_binary(<<"stepswitch">>, <<"default_prefix">>, <<>>)
          ,suffix = whapps_config:get_binary(<<"stepswitch">>, <<"default_suffix">>, <<>>)
          ,codecs = whapps_config:get(<<"stepswitch">>, <<"default_codecs">>, [])
          ,bypass_media = whapps_config:get_is_true(<<"stepswitch">>, <<"default_bypass_media">>, false)
          ,caller_id_type = whapps_config:get_binary(<<"stepswitch">>, <<"default_caller_id_type">>, <<"external">>)
          ,sip_headers = 'undefined'
          ,progress_timeout = whapps_config:get_integer(<<"stepswitch">>, <<"default_progress_timeout">>, 8) :: pos_integer()
         }).

-record(resrc, {
           id = <<>> :: binary()
          ,rev = <<>> :: binary()
          ,weight_cost = whapps_config:get_integer(<<"stepswitch">>, <<"default_weight">>, 1) :: 1..100
          ,grace_period = whapps_config:get_integer(<<"stepswitch">>, <<"default_weight">>, 3) :: non_neg_integer()
          ,flags = [] :: list()
          ,rules = [] :: list()
          ,gateways = [] :: list()
          ,is_emergency = 'true' :: boolean()
         }).

-type endpoint() :: {1..100, non_neg_integer(), ne_binary(), [#gateway{},...] | [], boolean()}.
-type endpoints() :: [] | [endpoint()].
