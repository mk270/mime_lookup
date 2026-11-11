%% MIME Lookup, a run-time MIME type lookup service, by Martin Keegan
%%
%% To the extent (if any) permissible by law, Copyright (C) 2020  Martin Keegan
%%
%% This programme is free software; you may redistribute and/or modify it under
%% the terms of the Apache Software Licence v2.0.

%% @doc The server that owns the MIME type table.
%%
%% It is started by `mime_lookup_sup' and is not meant to be called
%% directly: use the {@link mime_lookup} module. Every lookup is a call
%% to this process, which is also the only one to write the ETS table,
%% so a reload cannot be seen half-done.
%%
%% Besides the `reload' call, the server accepts a plain `reload'
%% message (`Pid ! reload'), which does the same but only logs a
%% warning on failure.
%% @private
-module(mime_lookup_serv).
-include_lib("eunit/include/eunit.hrl").
-behaviour(gen_server).

%% API
-export([start_link/0]).

%% API
-export([lookup/1, reload/0]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3, format_status/1]).

-define(SERVER, ?MODULE).

-record(state, {}).

% A MIME type and the extensions it is known by: one line of the data file,
% such as "text/html html htm", or one extra mapping from the application's
% environment. There is at least one extension, since a type without one
% could never be looked up. (The environment writes its pairs the other way
% round, {Extension, MimeType}, and the table holds one {Extension,
% MimeType} object per extension.)
-type mime_type() :: binary().
-type extension() :: binary().
-type mapping()   :: {mime_type(), [extension(), ...]}.

%%%===================================================================
%%% API
%%%===================================================================
-spec lookup(Extension) -> Result
              when Extension :: binary(),
                   Result    :: {ok, MimeType :: binary()} | notfound.
lookup(Extension) when is_binary(Extension) ->
    gen_server:call(?SERVER, {lookup, Extension}).


% Read the data again: the MIME types file and the extra mappings in the
% application's environment. If they can't be read, the data already
% loaded stays in use and the reason is returned.
-spec reload() -> Result
              when Result :: ok | {error, Reason :: term()}.
reload() ->
    gen_server:call(?SERVER, reload).


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

% Not the usual gen_server callback: start_link/0 runs this directly under
% proc_lib, and it enters the server loop rather than returning.
-spec init(Args) -> Result
              when Args   :: [],
                   Result :: no_return().
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
handle_call(reload, _From, State) ->
    {reply, load_data(), State};
handle_call({lookup, Extension}, _From, State) ->
    {reply, do_lookup(Extension), State}.


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
    case load_data() of
        ok ->
            ok;
        {error, Reason} ->
            logger:warning("mime_lookup: reload failed: ~p", [Reason])
    end,
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


-spec format_status(Status) -> Result
              when Status :: gen_server:format_status(),
                   Result :: gen_server:format_status().
format_status(Status) ->
    Status.

%%%===================================================================
%%% Internal functions
%%%===================================================================

-spec do_lookup(Extension) -> Result
              when Extension :: binary(),
                   Result    :: {ok, MimeType :: binary()} | notfound.
do_lookup(Extension) ->
    case ets:lookup(?MODULE, Extension) of
        [] -> notfound;
        [{_, MT}] -> {ok, MT};
        [{_, MT}|_] -> {ok, MT} %oops
    end.


% (Re)build the table from the data file and the extra mappings in the
% application's environment. The data is read and parsed first, so if that
% fails the table is left as it was. The table is then emptied and refilled
% by this process, which also answers every lookup, so no lookup can see it
% half-built.
-spec load_data() -> Result
              when Result :: ok | {error, Reason :: term()}.
load_data() ->
    case read_mappings() of
        {ok, Mappings} -> install(Mappings);
        {error, _} = Error -> Error
    end.


-spec read_mappings() -> Result
              when Result :: {ok, [mapping()]} | {error, Reason :: term()}.
read_mappings() ->
    case application:get_env(mime_lookup, mime_types_path) of
        {ok, ConfigFile} ->
            case file:read_file(ConfigFile) of
                {ok, Data}      -> parse_mappings(Data);
                {error, Reason} -> {error, {cannot_read, ConfigFile, Reason}}
            end;
        undefined ->
            {error, no_mime_types_path}
    end.


-spec parse_mappings(Data) -> Result
              when Data   :: binary(),
                   Result :: {ok, [mapping()]} | {error, Reason :: term()}.
parse_mappings(Data) ->
    Lines = string:split(Data, <<"\n">>, all),
    Stripped = [ strip_comment(S) || S <- Lines ],
    Mappings = [ M || {ok, M} <- [ line_to_mapping(S2) || S2 <- Stripped ] ],
    case additional_mappings() of
        {ok, Additional} -> {ok, merge(Mappings, Additional)};
        {error, _} = Error -> Error
    end.


% The extra mappings in the application's environment (the `mime_types`
% key: a list of {Extension, MimeType} pairs), one mapping for each pair.
% Each extension and MIME type must be a non-empty binary, and the value a
% proper list; anything else is an error, not silently dropped or stored,
% since a mapping with the wrong types could never be found.
-spec additional_mappings() -> Result
              when Result :: {ok, [mapping()]} | {error, Reason :: term()}.
additional_mappings() ->
    case application:get_env(mime_lookup, mime_types, []) of
        Pairs when is_list(Pairs) -> extra_mappings(Pairs, []);
        Other -> {error, {bad_mime_types, Other}}
    end.


-spec extra_mappings(Pairs, Acc) -> Result
              when Pairs  :: term(),
                   Acc    :: [mapping()],
                   Result :: {ok, [mapping()]} | {error, Reason :: term()}.
extra_mappings([], Acc) ->
    {ok, lists:reverse(Acc)};
extra_mappings([{Extension, MimeType} | Rest], Acc)
  when is_binary(Extension), Extension =/= <<>>,
       is_binary(MimeType), MimeType =/= <<>> ->
    extra_mappings(Rest, [{MimeType, [Extension]} | Acc]);
extra_mappings([Bad | _Rest], _Acc) ->
    {error, {bad_extra_mapping, Bad}};
extra_mappings(Other, _Acc) ->
    % the tail of an improper list
    {error, {bad_mime_types, Other}}.


% The extra mappings override the data file: an extension that has an
% extra mapping is dropped from the file's mappings (and a file mapping
% left with no extension at all goes), so the table never holds two types
% for it. If the extra mappings give one extension twice, the first one in
% the list wins and the others are dropped. Duplicates within the data
% file itself are not resolved here.
-spec merge(FileMappings, Extra) -> Result
              when FileMappings :: [mapping()],
                   Extra        :: [mapping()],
                   Result       :: [mapping()].
merge(FileMappings, Extra) ->
    {Kept, Overridden} = lists:foldl(fun keep_first/2, {[], #{}}, Extra),
    Free = fun(E) -> not maps:is_key(E, Overridden) end,
    [ {MT, Es2} || {MT, Es} <- FileMappings,
                   Es2 <- [lists:filter(Free, Es)], Es2 =/= [] ]
        ++ lists:reverse(Kept).


-spec keep_first(Mapping, Acc) -> Result
              when Mapping :: mapping(),
                   Acc     :: {[mapping()], #{extension() => true}},
                   Result  :: {[mapping()], #{extension() => true}}.
keep_first({MT, Es}, {Kept, Seen}) ->
    New = [ E || E <- lists:usort(Es), not maps:is_key(E, Seen) ],
    case New of
        [] -> {Kept, Seen};
        _ -> {[{MT, New} | Kept],
              lists:foldl(fun(E, M) -> M#{E => true} end, Seen, New)}
    end.


-spec strip_comment(Line) -> Result
              when Line   :: binary(),
                   Result :: binary().
strip_comment(S) when is_binary(S) ->
    Result = string:split(S, <<"#">>, leading),
    [Stripped|_] = Result,
    Stripped.


% A line of the data file: a MIME type followed by the extensions it is
% known by. A line that names no extension, such as a blank one, maps
% nothing, so there is no mapping to return.
-spec line_to_mapping(Line) -> Result
              when Line   :: binary(),
                   Result :: {ok, mapping()} | ignore.
line_to_mapping(Line) when is_binary(Line) ->
    case string:lexemes(Line, " " ++ [$\t]) of
        [MimeType | [_ | _] = Extensions] -> {ok, {MimeType, Extensions}};
        _ -> ignore
    end.


% updating our cache of the data ...

-spec install(Mappings) -> Result
              when Mappings :: [mapping()],
                   Result   :: ok.
install(Mappings) ->
    case ets:whereis(?MODULE) of
        undefined -> _ = ets:new(?MODULE, [bag, named_table]);
        _ -> true = ets:delete_all_objects(?MODULE)
    end,
    [ ok = store_mapping(M) || M <- Mappings ],
    ok.


-spec store_mapping(Mapping) -> Result
              when Mapping :: mapping(),
                   Result  :: ok.
store_mapping({MimeType, Extensions}) ->
    [ ets:insert(?MODULE, [{E, MimeType}]) || E <- Extensions ],
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

line_to_mapping_test_data() ->
    [
     {ignore, <<"">>},
     {{ok, {<<"text/html">>, [<<"html">>, <<"htm">>]}},
      <<"text/html html htm">>},
     % a type with no extension maps nothing
     {ignore, <<"application/batch-SMTP     ">>},
     {{ok, {<<"text/plain">>, [<<"txt">>]}}, <<"text/plain\ttxt">>},
     {{ok, {<<"text/plain">>, [<<"txt">>, <<"text">>]}},
      <<"  text/plain \t txt  text ">>}
    ].

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

%% reload/0 reads the data again: new mappings appear, removed ones go,
%% nothing is duplicated, the extra mappings from the environment stay, a
%% failed reload keeps the old data, and the server is not disturbed (it
%% used to crash, since the table already existed). The server is started
%% by hand here, on a data file the test writes.
reload_test_() ->
    {setup, fun reload_setup/0, fun reload_teardown/1,
     fun(State) -> {timeout, 30, fun() -> reload_steps(State) end} end}.

reload_setup() ->
    % the server is linked to this process: trapping exits turns a crash of
    % the server into a failed test, instead of killing the test before it
    % can clean up
    process_flag(trap_exit, true),
    _ = application:load(mime_lookup),
    Unique = integer_to_list(erlang:unique_integer([positive])),
    Path = filename:absname("mime_lookup_reload_" ++ Unique ++ ".types"),
    ok = file:write_file(Path, <<"text/html html\n">>),
    OldPath = application:get_env(mime_lookup, mime_types_path),
    ok = application:set_env(mime_lookup, mime_types_path, Path),
    {ok, Pid} = start_link(),
    {Path, OldPath, Pid}.

% Cleans up even if the test failed and took the server down with it.
reload_teardown({Path, OldPath, Pid}) ->
    _ = file:delete(Path),
    case OldPath of
        {ok, Old} -> application:set_env(mime_lookup, mime_types_path, Old);
        undefined -> application:unset_env(mime_lookup, mime_types_path)
    end,
    case is_process_alive(Pid) of
        true -> ok = gen_server:stop(Pid);
        false -> ok
    end.

reload_steps({Path, _OldPath, Pid}) ->
    Write = fun(Text) -> ok = file:write_file(Path, Text) end,
    Count = fun(Ext) -> length(ets:lookup(?MODULE, Ext)) end,
    % to begin with
    ?assertEqual({ok, <<"text/html">>}, lookup(<<"html">>)),
    ?assertEqual(notfound, lookup(<<"htm">>)),
    ?assertEqual({ok, <<"text/gemini">>}, lookup(<<"gemini">>)),
    % a new mapping appears, an unchanged one is not duplicated, and the
    % extra mappings from the environment are still there
    Write(<<"text/html html htm\ntext/plain txt\n">>),
    ?assertEqual(ok, mime_lookup:reload()),
    ?assertEqual({ok, <<"text/html">>}, lookup(<<"htm">>)),
    ?assertEqual({ok, <<"text/plain">>}, lookup(<<"txt">>)),
    ?assertEqual({ok, <<"text/gemini">>}, lookup(<<"gemini">>)),
    ?assertEqual(ok, reload()),
    ?assertEqual(ok, reload()),
    ?assertEqual(1, Count(<<"html">>)),
    ?assertEqual(1, Count(<<"gemini">>)),
    % a mapping removed from the file is gone after a reload
    Write(<<"text/plain txt\n">>),
    ?assertEqual(ok, reload()),
    ?assertEqual(notfound, lookup(<<"html">>)),
    ?assertEqual(notfound, lookup(<<"htm">>)),
    ?assertEqual({ok, <<"text/plain">>}, lookup(<<"txt">>)),
    % a file that can't be read keeps the data already loaded
    application:set_env(mime_lookup, mime_types_path, Path ++ ".missing"),
    ?assertMatch({error, {cannot_read, _, enoent}}, reload()),
    ?assertEqual({ok, <<"text/plain">>}, lookup(<<"txt">>)),
    ?assertEqual({ok, <<"text/gemini">>}, lookup(<<"gemini">>)),
    % as does having no file configured
    application:unset_env(mime_lookup, mime_types_path),
    ?assertEqual({error, no_mime_types_path}, reload()),
    ?assertEqual({ok, <<"text/plain">>}, lookup(<<"txt">>)),
    application:set_env(mime_lookup, mime_types_path, Path),
    % as do extra mappings of the wrong type
    OldExtra = application:get_env(mime_lookup, mime_types),
    application:set_env(mime_lookup, mime_types, [{"gmi", "text/gemini"}]),
    ?assertMatch({error, {bad_extra_mapping, _}}, reload()),
    ?assertEqual({ok, <<"text/plain">>}, lookup(<<"txt">>)),
    ?assertEqual({ok, <<"text/gemini">>}, lookup(<<"gemini">>)),
    {ok, OldExtraValue} = OldExtra,
    application:set_env(mime_lookup, mime_types, OldExtraValue),
    % the plain message does the same job, and lookups sent after it see
    % the result
    Write(<<"text/plain txt\ntext/x-new newext\n">>),
    Pid ! reload,
    ?assertEqual({ok, <<"text/x-new">>}, lookup(<<"newext">>)),
    % and none of this disturbs the server
    [ ?assertEqual(ok, reload()) || _ <- lists:seq(1, 25) ],
    ?assertEqual(Pid, whereis(?SERVER)),
    ?assert(is_process_alive(Pid)).

%% The extra mappings override the data file, whatever order the table
%% hands them back in, and still do after a reload. The data file is a
%% temporary one, so the real /etc/mime.types does not matter.
override_test_() ->
    {setup, fun reload_setup/0, fun reload_teardown/1,
     fun(State) -> {timeout, 30, fun() -> override_steps(State) end} end}.

override_steps({Path, _OldPath, Pid}) ->
    OldExtra = application:get_env(mime_lookup, mime_types),
    Write = fun(Text) -> ok = file:write_file(Path, Text) end,
    Extra = fun(Pairs) ->
                application:set_env(mime_lookup, mime_types, Pairs)
            end,
    Write(<<"text/html html htm\ntext/plain txt\n"
            "text/x-gone gone\n">>),
    Extra([{<<"html">>, <<"text/x-mine">>},
           {<<"only">>, <<"text/x-only">>},
           {<<"gone">>, <<"text/x-new">>}]),
    ?assertEqual(ok, reload()),
    % an extra mapping beats the file's, for that extension only
    ?assertEqual({ok, <<"text/x-mine">>}, lookup(<<"html">>)),
    ?assertEqual({ok, <<"text/html">>}, lookup(<<"htm">>)),
    % file-only and extra-only extensions are as they were
    ?assertEqual({ok, <<"text/plain">>}, lookup(<<"txt">>)),
    ?assertEqual({ok, <<"text/x-only">>}, lookup(<<"only">>)),
    ?assertEqual({ok, <<"text/x-new">>}, lookup(<<"gone">>)),
    ?assertEqual(1, length(ets:lookup(?MODULE, <<"html">>))),
    % the override survives reloads, by call and by message
    ?assertEqual(ok, reload()),
    ?assertEqual({ok, <<"text/x-mine">>}, lookup(<<"html">>)),
    Write(<<"text/html html htm\ntext/plain txt\ntext/x-two html\n">>),
    Pid ! reload,
    ?assertEqual({ok, <<"text/x-mine">>}, lookup(<<"html">>)),
    ?assertEqual({ok, <<"text/plain">>}, lookup(<<"txt">>)),
    % an extension given twice in the extra mappings: the first wins
    Extra([{<<"dup">>, <<"text/x-first">>},
           {<<"dup">>, <<"text/x-second">>}]),
    ?assertEqual(ok, reload()),
    ?assertEqual({ok, <<"text/x-first">>}, lookup(<<"dup">>)),
    ?assertEqual(1, length(ets:lookup(?MODULE, <<"dup">>))),
    {ok, OldExtraValue} = OldExtra,
    Extra(OldExtraValue).

merge_test_() ->
    [?_assertEqual([{<<"a">>, [<<"y">>]}, {<<"b">>, [<<"x">>]}],
                   merge([{<<"a">>, [<<"x">>, <<"y">>]}],
                         [{<<"b">>, [<<"x">>]}])),
     % a file mapping with nothing left goes
     ?_assertEqual([{<<"b">>, [<<"x">>]}],
                   merge([{<<"a">>, [<<"x">>]}], [{<<"b">>, [<<"x">>]}]))].

%% additional_mappings/0 and what parse_mappings/1 does with it: the
%% extra mappings come out as mappings, like the lines of the data file,
%% and anything of the wrong type is an error.
additional_mappings_test_() ->
    {setup,
     fun() ->
         _ = application:load(mime_lookup),
         application:get_env(mime_lookup, mime_types)
     end,
     fun(Old) ->
         case Old of
             {ok, Value} -> application:set_env(mime_lookup,
                                                mime_types, Value);
             undefined -> application:unset_env(mime_lookup, mime_types)
         end
     end,
     fun(_) ->
         With = fun(Env) ->
                    application:set_env(mime_lookup, mime_types, Env),
                    additional_mappings()
                end,
         Bad = fun(Entry) -> {error, {bad_extra_mapping, Entry}} end,
         [?_assertEqual({ok, [{<<"text/gemini">>, [<<"gmi">>]}]},
                        With([{<<"gmi">>, <<"text/gemini">>}])),
          % in order
          ?_assertEqual({ok, [{<<"text/b">>, [<<"b">>]},
                              {<<"text/a">>, [<<"a">>]}]},
                        With([{<<"b">>, <<"text/b">>},
                              {<<"a">>, <<"text/a">>}])),
          ?_assertEqual({ok, []}, With([])),
          ?_test(begin
                     application:unset_env(mime_lookup, mime_types),
                     ?assertEqual({ok, []}, additional_mappings())
                 end),
          % the wrong types are refused, not stored or dropped
          ?_assertEqual(Bad({"gmi", "text/gemini"}),
                        With([{"gmi", "text/gemini"}])),
          ?_assertEqual(Bad({<<"gmi">>, text}),
                        With([{<<"gmi">>, text}])),
          ?_assertEqual(Bad({gmi, <<"text/gemini">>}),
                        With([{gmi, <<"text/gemini">>}])),
          ?_assertEqual(Bad({<<"gmi">>, <<"text/gemini">>, extra}),
                        With([{<<"gmi">>, <<"text/gemini">>, extra}])),
          ?_assertEqual(Bad(<<"gmi">>), With([<<"gmi">>])),
          ?_assertEqual(Bad({<<>>, <<"text/gemini">>}),
                        With([{<<>>, <<"text/gemini">>}])),
          ?_assertEqual(Bad({<<"gmi">>, <<>>}), With([{<<"gmi">>, <<>>}])),
          % the first bad entry is the one reported, wherever it is
          ?_assertEqual(Bad(oops),
                        With([{<<"a">>, <<"text/a">>}, oops,
                              {<<"b">>, <<"text/b">>}])),
          % the value as a whole must be a list
          ?_assertEqual({error, {bad_mime_types, gmi}}, With(gmi)),
          ?_assertEqual({error, {bad_mime_types, {<<"a">>, <<"b">>}}},
                        With({<<"a">>, <<"b">>})),
          ?_assertEqual({error, {bad_mime_types, tail}},
                        With(improper_list({<<"a">>, <<"text/a">>}, tail))),
          % and parse_mappings/1 adds them to the file's, or passes the
          % error on
          ?_test(begin
                     application:set_env(mime_lookup, mime_types,
                                         [{<<"gmi">>, <<"text/gemini">>}]),
                     ?assertEqual({ok, [{<<"text/html">>, [<<"html">>]},
                                        {<<"text/gemini">>, [<<"gmi">>]}]},
                                  parse_mappings(<<"text/html html\n">>))
                 end),
          ?_test(begin
                     application:set_env(mime_lookup, mime_types, [oops]),
                     ?assertEqual(Bad(oops),
                                  parse_mappings(<<"text/html html\n">>))
                 end)]
     end}.

% An improper list, on purpose: the test needs one, and dialyzer is told
% that this function is allowed to make it.
-dialyzer({no_improper_lists, improper_list/2}).
improper_list(Head, Tail) ->
    [Head | Tail].
