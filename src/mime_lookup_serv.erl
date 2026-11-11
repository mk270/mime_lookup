%% MIME Lookup, a run-time MIME type lookup service, by Martin Keegan
%%
%% To the extent (if any) permissible by law, Copyright (C) 2020  Martin Keegan
%%
%% This programme is free software; you may redistribute and/or modify it under
%% the terms of the Apache Software Licence v2.0.

-module(mime_lookup_serv).
-include_lib("eunit/include/eunit.hrl").
-behaviour(gen_server).

%% API
-export([start_link/0]).

%% API
-export([lookup/1]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3, format_status/2]).

-define(SERVER, ?MODULE).

-record(state, {}).

%%%===================================================================
%%% API
%%%===================================================================
-spec lookup(Extension) -> Result
              when Extension :: binary(),
                   Result    :: {ok, MimeType :: binary()} | notfound.
lookup(MimeType) when is_binary(MimeType) ->
    gen_server:call(?SERVER, {lookup, MimeType}).


-spec start_link() -> Result
              when Result :: {ok, Pid :: pid()}
                           | {error, Error :: {already_started, pid()}}
                           | {error, Error :: term()}
                           | ignore.
start_link() ->
    proc_lib:start_link(?MODULE, init, [[]]).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

-spec init(Args) -> Result
              when Args   :: term(),
                   Result :: {ok, State :: term()}
                           | {ok, State :: term(), Timeout :: timeout()}
                           | {ok, State :: term(), hibernate}
                           | {stop, Reason :: term()}
                           | ignore.
init([]) ->
    % The server is ready when start_link/0 returns: the data is loaded and
    % the name is registered before this process says it has started, so
    % a caller can look something up the moment the application is up. If
    % loading fails, start_link/0 returns the error.
    ok = load_data(),
    register(?SERVER, self()),
    proc_lib:init_ack({ok, self()}),
    gen_server:enter_loop(?MODULE, [], #state{}).


-spec handle_call(Request, From, State) -> Result
              when Request :: term(),
                   From    :: {pid(), term()},
                   State   :: term(),
                   Result  :: {reply, Reply :: term(), NewState :: term()}
                            | {reply, Reply :: term(), NewState :: term(),
                               Timeout :: timeout()}
                            | {reply, Reply :: term(), NewState :: term(),
                               hibernate}
                            | {noreply, NewState :: term()}
                            | {noreply, NewState :: term(),
                               Timeout :: timeout()}
                            | {noreply, NewState :: term(), hibernate}
                            | {stop, Reason :: term(), Reply :: term(),
                               NewState :: term()}
                            | {stop, Reason :: term(), NewState :: term()}.
handle_call({lookup, MimeType}, _From, State) ->
    Reply = case ets:lookup(?MODULE, MimeType) of
                [] -> notfound;
                [{_, MT}] -> {ok, MT};
                [{_, MT}|_] -> {ok, MT} %oops
            end,
    {reply, Reply, State}.


-spec handle_cast(Request, State) -> Result
              when Request :: term(),
                   State   :: term(),
                   Result  :: {noreply, NewState :: term()}
                            | {noreply, NewState :: term(),
                               Timeout :: timeout()}
                            | {noreply, NewState :: term(), hibernate}
                            | {stop, Reason :: term(), NewState :: term()}.
handle_cast(_Request, State) ->
    {noreply, State}.


-spec handle_info(Info, State) -> Result
              when Info   :: timeout() | term(),
                   State  :: term(),
                   Result :: {noreply, NewState :: term()}
                           | {noreply, NewState :: term(),
                              Timeout :: timeout()}
                           | {noreply, NewState :: term(), hibernate}
                           | {stop, Reason :: normal | term(),
                              NewState :: term()}.
handle_info(reload, State) ->
    ok = load_data(),
    {noreply, State};
handle_info(_Info, State) ->
    {noreply, State}.


-spec terminate(Reason, State) -> Result
              when Reason :: normal | shutdown | {shutdown, term()} | term(),
                   State  :: term(),
                   Result :: any().
terminate(_Reason, _State) ->
    ok.


-spec code_change(OldVsn, State, Extra) -> Result
              when OldVsn :: term() | {down, term()},
                   State  :: term(),
                   Extra  :: term(),
                   Result :: {ok, NewState :: term()}
                           | {error, Reason :: term()}.
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.


-spec format_status(Opt, Status) -> Result
              when Opt    :: normal | terminate,
                   Status :: list(),
                   Result :: term().
format_status(_Opt, Status) ->
    Status.

%%%===================================================================
%%% Internal functions
%%%===================================================================

-spec load_data() -> Result
              when Result :: ok.
load_data() ->
    {ok, ConfigFile} = application:get_env(mime_lookup, mime_types_path),
    {ok, Data} = file:read_file(ConfigFile),
    ok = load_data(Data).


-spec load_data(Data) -> Result
              when Data   :: binary(),
                   Result :: ok.
load_data(Data) ->
    Lines = string:split(Data, <<"\n">>, all),
    ets:new(?MODULE, [bag, named_table]),
    Stripped = [ strip_comment(S) || S <- Lines ],
    Mappings = [ line_to_mapping(S2) || S2 <- Stripped ],
    [ ok = store_mapping(M) || M <- Mappings ],
    {ok, Additional} = application:get_env(mime_lookup, mime_types),
    [ ok = store_mapping([V, K]) || {K, V} <- Additional],
    ok.

%%%===================================================================
%%% Testing
%%%===================================================================

strip_comment_test_data() ->
    [
     {<<>>, <<"# a comment line">>},
     {<<"hello">>, <<"hello#there">>},
     {<<"text/html  html htm">>, <<"text/html  html htm#optional">>}
    ].

strip_comment(S) when is_binary(S) ->
    Result = string:split(S, <<"#">>, leading),
    [Stripped|_] = Result,
    Stripped.

line_to_mapping_test_data() ->
    [
     {[], <<"">>},
     {[<<"text/html">>, <<"html">>, <<"htm">>], <<"text/html html htm">>},
     {[<<"application/batch-SMTP">>], <<"application/batch-SMTP     ">>}
    ].

line_to_mapping(Line) when is_binary(Line) ->
    string:lexemes(Line, " " ++ [$\t]).

store_mapping([]) -> ok; %ignored
store_mapping([_Key]) -> ok; %ignored
store_mapping([Key|Values]) ->
    [ ets:insert(?MODULE, [{V, Key}]) || V <- Values],
    ok.

strip_comment_test_() ->
    [ ?_assertEqual(Expected, strip_comment(Observed)) ||
        {Expected, Observed} <- strip_comment_test_data() ].

line_to_mapping_test_() ->
    [ ?_assertEqual(Expected, line_to_mapping(Observed)) ||
        {Expected, Observed} <- line_to_mapping_test_data() ].

%% start_link/0 must not return until the server is ready: data loaded
%% and name registered. A caller that starts the application and at
%% once looks something up would otherwise sometimes get noproc.
%% The data file is written here, so the test doesn't depend on the
%% system's /etc/mime.types; the extra mappings come from the app's env.
start_link_returns_a_ready_server_test_() ->
    {setup,
     fun() ->
         _ = application:load(mime_lookup),
         Unique = integer_to_list(erlang:unique_integer([positive])),
         Path = filename:absname("mime_lookup_test_" ++ Unique ++ ".types"),
         ok = file:write_file(Path, <<"# a comment\ntext/html html htm\n">>),
         OldPath = application:get_env(mime_lookup, mime_types_path),
         ok = application:set_env(mime_lookup, mime_types_path, Path),
         {Path, OldPath}
     end,
     fun({Path, OldPath}) ->
         ok = file:delete(Path),
         case OldPath of
             {ok, Old} -> application:set_env(mime_lookup,
                                              mime_types_path, Old);
             undefined -> application:unset_env(mime_lookup,
                                                mime_types_path)
         end
     end,
     fun(_) ->
         {timeout, 30,
          fun() ->
              % many times over, since the failure was a race
              [ ready_after_start_link() || _ <- lists:seq(1, 50) ]
          end}
     end}.

ready_after_start_link() ->
    {ok, Pid} = start_link(),
    ?assertEqual(Pid, whereis(?SERVER)),
    ?assertEqual({ok, <<"text/html">>}, lookup(<<"html">>)),
    ?assertEqual({ok, <<"text/html">>}, lookup(<<"htm">>)),
    ?assertEqual({ok, <<"text/gemini">>}, lookup(<<"gemini">>)),
    ?assertEqual(notfound, lookup(<<"no-such-extension">>)),
    ok = gen_server:stop(Pid).
