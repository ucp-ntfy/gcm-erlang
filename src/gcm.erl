%%%-------------------------------------------------------------------
%%% @author Paolo D'Incau <paolo.dincau@gmail.com>
%%% @copyright (C) 2013, Paolo D'Incau
%%% @doc
%%%
%%% @end
%%% Created : 18 Apr 2013 by Paolo D'Incau <paolo.dincau@gmail.com>
%%%-------------------------------------------------------------------
-module(gcm).

-behaviour(gen_server).

%% API
-export([start/2, start/3, stop/1, start_link/2, start_link/3]).
-export([push/3, sync_push/3]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
	 terminate/2, code_change/3]).

-define(SERVER, ?MODULE).

-define(BASEURL, "https://fcm.googleapis.com/fcm/send").

-record(state, {key, retry_after, error_fun}).

%%%===================================================================
%%% API
%%%===================================================================
start(Name, Key) ->
    start(Name, Key, fun handle_error/2).

start(Name, Key, ErrorFun) ->
    gcm_sup:start_child(Name, Key, ErrorFun).

start_link(Name, Key) ->
    start_link(Name, Key, fun handle_error/2).

start_link(Name, Key, ErrorFun) ->
    gen_server:start_link({local, Name}, ?MODULE, [Key, ErrorFun], []).

stop(Name) ->
    gen_server:call(Name, stop).

push(Name, RegIds, Message) ->
    gen_server:cast(Name, {send, RegIds, Message}).

sync_push(Name, RegIds, Message) ->
    gen_server:call(Name, {send, RegIds, Message}).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

init([Key, ErrorFun]) ->
    {ok, #state{key=Key, retry_after=0, error_fun=ErrorFun}}.

handle_call(stop, _From, State) ->
    {stop, normal, stopped, State};

handle_call({send, RegIds, Message}, _From, #state{key=Key, error_fun=ErrorFun} = State) ->
    {reply, do_push(RegIds, Message, Key, ErrorFun), State};

handle_call(_Request, _From, State) ->
    Reply = ok,
    {reply, Reply, State}.

handle_cast({send, RegIds, Message}, #state{key=Key, error_fun=ErrorFun} = State) ->
    do_push(RegIds, Message, Key, ErrorFun),
    {noreply, State};

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================
do_push(RegIds, Message, Key, ErrorFun) ->
    lager:info("Message=~p; RegIds=~p~n", [Message, RegIds]),
    GCMRequest = jsonx:encode([{<<"registration_ids">>, RegIds}|Message]),
    ApiKey = string:concat("key=", Key),

    try httpc:request(post, {?BASEURL, [{"Authorization", ApiKey}], "application/json", GCMRequest}, [], []) of
        {ok, {{_, 200, _}, _Headers, GCMResponse}} ->
	    Json = jsonx:decode(response_to_binary(GCMResponse), [{format, proplist}]),
	    {_Multicast, _Success, Failure, Canonical, Results} = get_response_fields(Json),
            case to_be_parsed(Failure, Canonical) of
                true ->
                    parse_results(Results, RegIds, ErrorFun);
                false ->
                    ok
            end;
        {error, Reason} ->
            {error, Reason};
        {ok, {{_, 401, _}, _, _}} ->
	    {stop, authorization, unknown};
	{ok, {{_, Code, _}, _, _}} ->
	    lager:error("Error response with status code ~p", [Code]),
	    {noreply, unknown};
	OtherError ->
            lager:error("Other error: ~p~n", [OtherError]),
	    {noreply, unknown}
    catch
        Exception ->
            {error, Exception}
    end.

response_to_binary(Json) when is_binary(Json) ->
    Json;

response_to_binary(Json) when is_list(Json) ->
    list_to_binary(Json).

get_response_fields(Json) ->
    {
        proplists:get_value(<<"multicast_id">>, Json),
        proplists:get_value(<<"success">>, Json),
        proplists:get_value(<<"failure">>, Json),
        proplists:get_value(<<"canonical_ids">>, Json),
        proplists:get_value(<<"results">>, Json)
    }.

to_be_parsed(0, 0) -> false;

to_be_parsed(_Failure, _Canonical) -> true.

parse_results([Result|Results], [RegId|RegIds], ErrorFun) ->
    case {
        proplists:get_value(<<"error">>, Result),
        proplists:get_value(<<"message_id">>, Result),
        proplists:get_value(<<"registration_id">>, Result)
    } of
        {Error, undefined, undefined} when Error =/= undefined ->
            ErrorFun(Error, RegId),
            parse_results(Results, RegIds, ErrorFun);
        {undefined, MessageId, undefined} when MessageId =/= undefined ->
            parse_results(Results, RegIds, ErrorFun);
        {undefined, MessageId, NewRegId} when MessageId =/= undefined andalso NewRegId =/= undefined ->
            ErrorFun(<<"NewRegistrationId">>, {RegId, NewRegId}),
            parse_results(Results, RegIds, ErrorFun)
    end;

parse_results([], [], _ErrorFun) ->
    ok.

handle_error(Error, RegId) ->
    lager:error("GCM error ~p, ID ~p~n", [Error, RegId]),
    ok.

