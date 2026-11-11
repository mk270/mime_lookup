%% MIME Lookup, a run-time MIME type lookup service, by Martin Keegan
%%
%% To the extent (if any) permissible by law, Copyright (C) 2020  Martin Keegan
%%
%% This programme is free software; you may redistribute and/or modify it under
%% the terms of the Apache Software Licence v2.0.

-module(mime_lookup_app).

-behaviour(application).

-export([start/2, stop/1]).

-spec start(StartType, StartArgs) -> Result
              when StartType :: application:start_type(),
                   StartArgs :: term(),
                   Result    :: {ok, pid()} | {error, term()}.
start(_StartType, _StartArgs) ->
    mime_lookup_sup:start_link().

-spec stop(State) -> Result
              when State  :: term(),
                   Result :: ok.
stop(_State) ->
    ok.

