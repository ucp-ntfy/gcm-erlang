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
-export([push/3, sync_push/3, sync_push/5]).

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
    gen_server:cast(Name, {send, RegIds, Message, default_trace_ref(), default_timeout()}).

sync_push(Name, RegIds, Message) ->
    sync_push(Name, RegIds, Message, default_trace_ref(), default_timeout()).

sync_push(Name, RegIds, Message, TraceRef, Timeout) ->
    gen_server:call(Name, {send, RegIds, Message, TraceRef, Timeout}, Timeout).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

init([Key, ErrorFun]) ->
    {ok, #state{key=Key, retry_after=0, error_fun=ErrorFun}}.

handle_call(stop, _From, State) ->
    {stop, normal, stopped, State};

handle_call({send, RegIds, Message, TraceRef, Timeout}, _From, #state{key=Key, error_fun=ErrorFun} = State) ->
    {reply, do_push(RegIds, Message, Key, ErrorFun, TraceRef, Timeout), State};

handle_call(_Request, _From, State) ->
    Reply = ok,
    {reply, Reply, State}.

handle_cast({send, RegIds, Message, TraceRef, Timeout}, #state{key=Key, error_fun=ErrorFun} = State) ->
    do_push(RegIds, Message, Key, ErrorFun, TraceRef, Timeout),
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
default_trace_ref() ->
    {from, self()}.

default_timeout() ->
    5000.

do_push(RegIds, Message, Key, ErrorFun, TraceRef, Timeout) ->
    ApiKey = string:concat("key=", Key),
    lager:debug("~p Timeout ~p Key ~p", [TraceRef, Timeout, erlang:adler32(Key)]),

    GCMRequest = jsonx:encode([{<<"registration_ids">>, RegIds}|Message]),

    try httpc:request(post, {?BASEURL, [{"Authorization", ApiKey}], "application/json", GCMRequest}, [{timeout, Timeout}], []) of
        {ok, {{_, 200, _}, Headers, GCMResponse}} ->
            lager:debug("~p Code:200 Headers:~p Response:~p", [TraceRef, Headers, GCMResponse]),

            Bin  = response_to_binary(GCMResponse),
            Json = jsonx:decode(Bin, [{format, proplist}]),
            if not is_list(Json) ->
                lager:error("FCM response JSON decode error. JSON = ~p", [Bin]),
                ok;
            true ->
                {_Multicast, _Success, Failure, Canonical, Results} = get_response_fields(Json),
                case to_be_parsed(Failure, Canonical) of
                    true ->
                        parse_results(Results, RegIds, ErrorFun);
                    false ->
                        ok
                end
            end;

        {ok, {{_, 401, _}, Headers, _}} ->
            lager:error("~p Code:401 Authorization. Headers:~p", [TraceRef, Headers]),
            {stop, authorization, unknown};

        {ok, {{_, Code, _}, Headers, Response}} ->
            lager:error("~p Code:~p. Headers:~p Response:~p", [TraceRef, Code, Headers, Response]),
            {noreply, unknown};

        {error, Reason} ->
            lager:error("~p error ~p", [TraceRef, Reason]),
            {error, Reason};

        OtherError ->
            lager:error("~p Other error: ~p", [TraceRef, OtherError]),
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

